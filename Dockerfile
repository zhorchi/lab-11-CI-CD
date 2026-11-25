FROM python:3.12-slim-bookworm
ARG APP_VERSION=v1
ENV APP_VERSION=${APP_VERSION}
WORKDIR /app
COPY app.py .
EXPOSE 8000
CMD ["python", "app.py"]
