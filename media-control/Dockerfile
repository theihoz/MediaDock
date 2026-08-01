FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app
COPY pyproject.toml ./
COPY src ./src
RUN pip install --no-cache-dir .
COPY docker-entrypoint.sh /usr/local/bin/media-control-entrypoint
RUN chmod 0755 /usr/local/bin/media-control-entrypoint && useradd --uid 1000 --create-home media-control

USER media-control
EXPOSE 11444
ENTRYPOINT ["media-control-entrypoint"]
