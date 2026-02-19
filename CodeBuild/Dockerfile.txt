FROM nginx:latest
COPY ./CodeBuild/app/index.html /usr/share/nginx/html
