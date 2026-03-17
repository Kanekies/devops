#!/usr/bin/env bash

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
REPORT_DIR="/var/tmp/ops_reports"

show_help() {
    cat <<EOF
Usage:
  $SCRIPT_NAME --help
  $SCRIPT_NAME --report
  $SCRIPT_NAME --users [--user USERNAME]
  $SCRIPT_NAME --proc [--pid PID]
  $SCRIPT_NAME --find DIRECTORY PATTERN
  $SCRIPT_NAME --log LOGFILE [--follow]
  $SCRIPT_NAME --pid PID --signal TERM|KILL|STOP|CONT
  $SCRIPT_NAME --pid PID --renice PRIORITY

Examples:
  $SCRIPT_NAME --users
  $SCRIPT_NAME --users --user test1
  $SCRIPT_NAME --report
  $SCRIPT_NAME --proc
  $SCRIPT_NAME --proc --pid 1234
  $SCRIPT_NAME --find /etc "*ssh*"
  $SCRIPT_NAME --log /var/log/syslog
  $SCRIPT_NAME --log /var/log/auth.log --follow
  $SCRIPT_NAME --pid 1234 --signal TERM
  $SCRIPT_NAME --pid 1234 --renice 5
EOF
}


set_mode() {
    local new_mode="$1"

    if [[ -n "$MODE" && "$MODE" != "$new_mode" ]]; then
        echo "Error: use only one main mode at a time."
        exit 1
    fi

    MODE="$new_mode"
}

ensure_linux() {
    local kernel_name
    kernel_name="$(uname -s)"

    if [[ "$kernel_name" != "Linux" ]]; then
        echo "Error: this script supports Linux only. Detected system: $kernel_name"
        exit 1
    fi
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

is_positive_integer() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

is_integer() {
    [[ "$1" =~ ^-?[0-9]+$ ]]
}

validate_args() {
    if [[ -z "$MODE" && -z "$TARGET_PID" ]]; then
        echo "Error: no mode or PID action provided."
        show_help
        exit 1
    fi

    if [[ -n "$TARGET_USER" && "$MODE" != "users" ]]; then
        echo "Error: --user can only be used with --users."
        exit 1
    fi

    if [[ -n "$SIGNAL_NAME" && -n "$RENICE_VALUE" ]]; then
        echo "Error: use either --signal or --renice, not both."
        exit 1
    fi

    if [[ -n "$SIGNAL_NAME"  && -n "$RENICE_VALUE" ]]; then
        if [[ -z "$TARGET_PID" ]]; then
            echo "Error: --signal and --renice require --pid."
            exit 1
        fi
    fi

    if [[ -n "$MODE" && ( -n "$SIGNAL_NAME" || -n "$RENICE_VALUE" ) ]]; then
        echo "Error: PID actions cannot be combined with main modes like --users, --proc, --find, --log, or --report."
        exit 1
    fi

    if [[ -n "$TARGET_PID" ]]; then
        if ! is_positive_integer "$TARGET_PID"; then
            echo "Error: PID must be a positive integer."
            exit 1
        fi
    fi

    if [[ -n "$RENICE_VALUE" ]]; then
        if ! is_integer "$RENICE_VALUE"; then
            echo "Error: renice value must be an integer."
            exit 1
        fi
    fi

    if [[ -n "$SIGNAL_NAME" ]]; then
        case "$SIGNAL_NAME" in
            TERM|KILL|STOP|CONT)
                ;;
            *)
                echo "Error: unsupported signal. Allowed: TERM, KILL, STOP, CONT."
                exit 1
                ;;
        esac
    fi

    if [[ "$MODE" == "find" ]]; then
        if [[ -z "$FIND_DIR"  && -z "$FIND_PATTERN" ]]; then
            echo "Error: --find requires DIRECTORY and PATTERN."
            exit 1
        fi
    fi

    if [[ "$MODE" == "log" ]]; then
        if [[ -z "$LOG_FILE" ]]; then
            echo "Error: --log requires a logfile path."
            exit 1
        fi
    fi
}

show_regular_users() {
    echo "=== Regular users ==="

    if [[ ! -f /etc/passwd ]]; then
        echo "Error: /etc/passwd not found."
        return 1
    fi

    awk -F: '$3 >= 1000 && $3 != 65534 { print $1 }' /etc/passwd
    echo
}

show_logged_in_users() {
    echo "=== Currently logged-in users ==="

    who

    echo
    echo "=== Detailed login activity (w) ==="

        w

    echo
}

show_user_details() { 
    local username="$1"
    local passwd_line
    local user_home
    local user_shell

    echo "=== Details for user: $username ==="

    if ! id "$username" >/dev/null 2>&1; then
        echo "Error: user '$username' does not exist."
        return 1
    fi

    echo "UID: $(id -u "$username")"
    echo "GID: $(id -g "$username")"
    echo "Groups: $(groups "$username")"

    passwd_line="$(grep "^${username}:" /etc/passwd || true)"

    if [[ -z "$passwd_line" ]]; then
        echo "Error: could not read user entry from /etc/passwd."
        return 1
    fi

    user_home="$(echo "$passwd_line" | cut -d: -f6)"
    user_shell="$(echo "$passwd_line" | cut -d: -f7)"

    echo "Home directory: $user_home"
    echo "Login shell: $user_shell"
    echo
}

run_users_mode() {
    show_regular_users
    show_logged_in_users

    if [[ -n "$TARGET_USER" ]]; then
        show_user_details "$TARGET_USER"
    fi
}

show_top_processes() {
    echo "=== Top running processes by CPU usage ==="

    ps -eo pid,ppid,user,stat,%cpu,%mem,comm --sort=-%cpu | head -n 11
    echo
}

show_process_states() {
    echo "=== Processes in states R, S, D, T, Z ==="

    local r=0
    local s=0
    local d=0
    local t=0
    local z=0
    local pid
    local user
    local stat
    local comm
    local state

    while read -r pid user stat comm; do
        state="${stat:0:1}"

        case "$state" in
            R)
                echo "$pid $user $stat $comm"
                ((++r))
                ;;
            S)
                echo "$pid $user $stat $comm"
                ((++s))
                ;;
            D)
                echo "$pid $user $stat $comm"
                ((++d))
                ;;
            T)
                echo "$pid $user $stat $comm"
                ((++t))
                ;;
            Z)
                echo "$pid $user $stat $comm"
                ((++z))
                ;;
        esac
    done < <(ps -eo pid,user,stat,comm --no-headers)

    echo
    echo "=== State summary ==="
    echo "R (running): $r"
    echo "S (sleeping): $s"
    echo "D (uninterruptible sleep): $d"
    echo "T (stopped/traced): $t"
    echo "Z (zombie): $z"
    echo
}

show_pid_details() {
    local pid="$1"
    local owner
    local ppid
    local state
    local command_line

    echo "=== Details for PID: $pid ==="

    if ! ps -p "$pid" >/dev/null 2>&1; then
        echo "Error: PID '$pid' does not exist."
        return 1
    fi

    owner="$(ps -p "$pid" -o user=)"
    ppid="$(ps -p "$pid" -o ppid= | xargs)"
    state="$(ps -p "$pid" -o stat= | xargs)"
    command_line="$(ps -p "$pid" -o args=)"

    echo "Owner: $owner"
    echo "PID: $pid"
    echo "PPID: $ppid"
    echo "State: $state"
    echo "Command: $command_line"
    echo

    echo "=== Parent process chain ==="

    if command_exists pstree; then
        pstree -sp "$pid"
    else
        echo "Command 'pstree' is not available."
    fi

    echo
}

run_proc_mode() {
    show_top_processes
    show_process_states

    if [[ -n "$TARGET_PID" ]]; then
        show_pid_details "$TARGET_PID"
    fi
}

show_find_results() {
    echo "=== Search results ==="

    if ! command_exists find; then
        echo "Error: command 'find' is not available."
        return 1
    fi

    if [[ ! -d "$FIND_DIR" ]]; then
        echo "Error: directory '$FIND_DIR' does not exist."
        return 1
    fi

    find "$FIND_DIR" -name "$FIND_PATTERN"
    echo
}

show_found_object_types() {
    echo "=== Types of found objects ==="

    local found_any="false"
    local found_path

    while IFS= read -r found_path; do
        found_any="true"
        file "$found_path"
    done < <(find "$FIND_DIR" -name "$FIND_PATTERN")

    if [[ "$found_any" == "false" ]]; then
        echo "No matching files or directories found."
    fi

    echo
}

show_directory_tree() {
    echo "=== Directory tree (depth 2) ==="

    if [[ ! -d "$FIND_DIR" ]]; then
        echo "Error: directory '$FIND_DIR' does not exist."
        return 1
    fi

    if command_exists tree; then
        tree -L 2 "$FIND_DIR"
    else
        echo "Command 'tree' is not installed. Skipping directory tree view."
    fi

    echo
}

run_find_mode() {
    show_find_results
    show_found_object_types
    show_directory_tree
}

show_log_line_count() {
    echo "=== Log file line count ==="

    if [[ ! -f "$LOG_FILE" ]]; then
        echo "Error: log file '$LOG_FILE' does not exist."
        return 1
    fi

    wc -l < "$LOG_FILE"
    echo
}

show_log_tail() {
    echo "=== Last 20 lines of log file ==="

    if [[ ! -f "$LOG_FILE" ]]; then
        echo "Error: log file '$LOG_FILE' does not exist."
        return 1
    fi

    if ! command_exists tail; then
        echo "Error: command 'tail' is not available."
        return 1
    fi

    tail -n 20 "$LOG_FILE"
    echo
}

follow_log_file() {
    echo "=== Live log monitoring (tail -f) ==="
    echo "Press Ctrl+C to stop."
    echo

    if [[ ! -f "$LOG_FILE" ]]; then
        echo "Error: log file '$LOG_FILE' does not exist."
        return 1
    fi

    tail -f "$LOG_FILE"
}

run_log_mode() {
    show_log_line_count
    show_log_tail

    if [[ "$FOLLOW_MODE" == "true" ]]; then
        follow_log_file
    fi
}

require_root_for_process_action() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        echo "Error: this action requires root or sudo."
        exit 1
    fi
}

ensure_pid_exists() {
    local pid="$1"

    if ! ps -p "$pid" >/dev/null 2>&1; then
        echo "Error: PID '$pid' does not exist."
        return 1
    fi
}

run_signal_action() {
    local pid="$1"
    local signal_name="$2"


    if [[ "$pid" == "1" ]]; then
        echo "Error: refusing to operate on PID 1."
        return 1
    fi

    require_root_for_process_action
    ensure_pid_exists "$pid"  return 1

    echo "About to send signal '$signal_name' to PID $pid."

    if ! kill -s "$signal_name" "$pid"; then
        echo "Error: failed to send signal '$signal_name' to PID $pid."
        return 1
    fi

    echo "Success: signal '$signal_name' was sent to PID $pid."
    echo
}

run_renice_action() {
    local pid="$1"
    local priority="$2"

    if ! command_exists renice; then
        echo "Error: command 'renice' is not available."
        return 1
    fi

    if [[ "$pid" == "1" ]]; then
        echo "Error: refusing to operate on PID 1."
        return 1
    fi

    require_root_for_process_action
    ensure_pid_exists "$pid"  return 1

    echo "About to change priority of PID $pid to $priority."

    if ! renice -n "$priority" -p "$pid"; then
        echo "Error: failed to change priority of PID $pid."
        return 1
    fi

    echo "Success: priority of PID $pid was changed to $priority."
    echo
}

run_pid_action_mode() {
    if [[ -n "$SIGNAL_NAME" ]]; then
        run_signal_action "$TARGET_PID" "$SIGNAL_NAME"
        return
    fi

    if [[ -n "$RENICE_VALUE" ]]; then
        run_renice_action "$TARGET_PID" "$RENICE_VALUE"
        return
    fi

    echo "Error: no PID action specified."
    return 1
}

get_root_status_text() {
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
        if [[ -n "${SUDO_USER:-}" ]]; then
            echo "Yes (via sudo, original user: $SUDO_USER)"
        else
            echo "Yes (running as root)"
        fi
    else
        echo "No"
    fi
}

get_cpu_report_block() {
    echo "=== CPU information from /proc ==="

    if [[ ! -f /proc/cpuinfo ]]; then
        echo "Error: /proc/cpuinfo not found."
        echo
        return 1
    fi

    echo "CPU model: $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | xargs)"
    echo "CPU cores (logical): $(grep -c '^processor' /proc/cpuinfo)"
    echo
}

get_memory_report_block() {
    echo "=== Memory information from /proc ==="

    if [[ ! -f /proc/meminfo ]]; then
        echo "Error: /proc/meminfo not found."
        echo
        return 1
    fi

    grep -E '^(MemTotal|MemAvailable|SwapTotal|SwapFree):' /proc/meminfo
    echo
}

get_process_anomaly_block() {
    echo "=== Zombie or stopped processes ==="

    local found_any="false"
    local pid
    local user
    local stat
    local comm
    local state

    while read -r pid user stat comm; do
        state="${stat:0:1}"

        case "$state" in
            Z|T)
                echo "$pid $user $stat $comm"
                found_any="true"
                ;;
        esac
    done < <(ps -eo pid,user,stat,comm --no-headers)

    if [[ "$found_any" == "false" ]]; then
        echo "No zombie or stopped processes found."
    fi

    echo
}

calculate_final_status() {
    local root_disk_used
    local mem_available_mb
    local zombie_count
    local stopped_count

    root_disk_used="$(df -P / | awk 'NR==2 {gsub("%", "", $5); print $5}')"
    mem_available_mb="$(awk '/^MemAvailable:/ {print int($2 / 1024)}' /proc/meminfo)"
    zombie_count="$(ps -eo stat= | grep -c '^Z' || true)"
    stopped_count="$(ps -eo stat= | grep -c '^T' || true)"

    if [[ -z "$root_disk_used" ]]; then
        root_disk_used=0
    fi

    if [[ -z "$mem_available_mb" ]]; then
        mem_available_mb=0
    fi

    if [[ "$root_disk_used" -ge 95 || "$mem_available_mb" -lt 200 ]]; then
        echo "CRITICAL"
        return
    fi

    if [[ "$root_disk_used" -ge 85  || "$mem_available_mb" -lt 500 || "$zombie_count" -gt 0 || "$stopped_count" -gt 0 ]]; then
        echo "WARNING"
        return
    fi

    echo "OK"
}

generate_report_content() {
    echo "Ops First Aid Report"
    echo "===================="
    echo

    echo "=== Basic system information ==="
    echo "Current user: $(whoami)"
    echo "Running as root / via sudo: $(get_root_status_text)"
    echo "Hostname: $(hostname)"
    echo "Current date and time: $(date)"
    echo "Uptime: $(uptime)"
    echo

    get_cpu_report_block
    get_memory_report_block

    echo "=== Mounted file systems and disk usage ==="
        df -h
    echo

    echo "=== Currently logged-in users ==="
        who
    echo

    echo "=== Top 5 processes by CPU usage ==="
        ps -eo pid,ppid,user,stat,%cpu,%mem,comm --sort=-%cpu | head -n 6
    echo

    echo "=== Top 5 processes by memory usage ==="
        ps -eo pid,ppid,user,stat,%cpu,%mem,comm --sort=-%mem | head -n 6
    echo

    get_process_anomaly_block
    echo "=== Final status summary ==="
    echo "Threshold rules used by this script:"
    echo "- CRITICAL: root filesystem >= 95% OR MemAvailable < 200 MB"
    echo "- WARNING: root filesystem >= 85% OR MemAvailable < 500 MB OR zombie/stopped processes exist"
    echo "- OK: none of the above"
    echo
    echo "Status: $(calculate_final_status)"
    echo
}

run_report_mode() {
    local timestamp
    local report_file

    timestamp="$(date '+%Y-%m-%d_%H-%M-%S')"
    report_file="$REPORT_DIR/report_$timestamp.txt"

    mkdir -p "$REPORT_DIR"

    generate_report_content | tee "$report_file"

    echo "Report saved to: $report_file"
}

MODE=""
TARGET_USER=""
TARGET_PID=""
SIGNAL_NAME=""
RENICE_VALUE=""
LOG_FILE=""
FOLLOW_MODE="false"
FIND_DIR=""
FIND_PATTERN=""

if [[ $# -eq 0 ]]; then
    show_help
    exit 1
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help)
            show_help
            exit 0
            ;;
        --report)
            set_mode "report"
            shift
            ;;
        --users)
            set_mode "users"
            shift
            ;;
        --user)
	    if [[ $# -lt 2 ]]; then
	    	echo "Error: --user requires a username."
		exit 1
	    fi
            TARGET_USER="$2"
            shift 2
            ;;
        --proc)
            set_mode "proc"
            shift
            ;;
        --pid)
	    if [[ $# -lt 2 ]]; then
	    	echo "Error: --pid requires a PID value."
		exit 1
	    fi
            TARGET_PID="$2"
            shift 2
            ;;
        --signal)
	    if [[ $# -lt 2 ]]; then
	    	echo "Error: --signal requires a signal name."
		exit 1
	    fi
            SIGNAL_NAME="$2"
            shift 2
            ;;
        --renice)
	    if [[ $# -lt 2 ]]; then
	    	echo "Error: --renice require a priority value."
		exit 1
            fi
            RENICE_VALUE="$2"
            shift 2
            ;;
        --find)
            set_mode "find"
	    if [[ $# -lt 3 ]]; then
	    	echo "Error: --find requires DIRECTORY and PATTERN."
		exit 1
	    fi
            FIND_DIR="$2"
            FIND_PATTERN="$3"
            shift 3
            ;;
        --log)
            set_mode "log"
	    if [[ $# -lt 2 ]]; then
	    	echo "Error: --log reqiures a logfile path."
		exit 1
	    fi
	    LOG_FILE="$2"
            shift 2
            ;;
        --follow)
            FOLLOW_MODE="true"
            shift
            ;;
        *)
            echo "Error: unknown argument: $1"
            show_help
            exit 1
            ;;
    esac
done

ensure_linux
validate_args

case "$MODE" in
    users)
        run_users_mode
        ;;
    proc)
        run_proc_mode
        ;;
    find)
        run_find_mode
        ;;
    log)
        run_log_mode
        ;;
    report)
        run_report_mode
        ;;
    "")
        if [[ -n "$TARGET_PID" ]]; then
            run_pid_action_mode
        else
            echo "No mode selected."
        fi
        ;;
    *)
        echo "Mode '$MODE' is not implemented yet."
        ;;
esac
