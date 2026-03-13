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

    if ! command_exists who; then
        echo "Error: command 'who' is not available."
        return 1
    fi

    who

    echo
    echo "=== Detailed login activity (w) ==="

    if command_exists w; then
        w
    else
        echo "Command 'w' is not available."
    fi

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

    if ! command_exists ps; then
        echo "Error: command 'ps' is not available."
        return 1
    fi

    ps -eo pid,ppid,user,stat,%cpu,%mem,comm --sort=-%cpu | head -n 11
    echo
}

show_process_states() {
    echo "=== Processes in states R, S, D, T, Z ==="

    if ! command_exists ps; then
        echo "Error: command 'ps' is not available."
        return 1
    fi

    ps -eo pid,user,stat,comm --no-headers | awk '
    {
        state = substr($3, 1, 1)
        if (state == "R"  state == "S"  state == "D"  state == "T"  state == "Z") {
            print $0
            counts[state]++
        }
    }
    END {
        print ""
        print "=== State summary ==="
        print "R (running): " 0 + counts["R"]
        print "S (sleeping): " 0 + counts["S"]
        print "D (uninterruptible sleep): " 0 + counts["D"]
        print "T (stopped/traced): " 0 + counts["T"]
        print "Z (zombie): " 0 + counts["Z"]
    }'

    echo
}

show_pid_details() {
    local pid="$1"
    local owner
    local ppid
    local state
    local command_line

    echo "=== Details for PID: $pid ==="

    if ! command_exists ps; then
        echo "Error: command 'ps' is not available."
        return 1
    fi

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
    "")
        if [[ -n "$TARGET_PID" ]]; then
            echo "PID action mode is not implemented yet."
        else
            echo "No mode selected."
        fi
        ;;
    *)
        echo "Mode '$MODE' is not implemented yet."
        ;;
esac
