FROM debian:bookworm-slim@sha256:734a72b3d6142a71993b4bc580ca01d8ca687f77a2c422d96a961d3376b179bc

# pgBackRest is pinned; the other packages follow the digest-pinned base image.
ARG PGBACKREST_VERSION=2.60.0-1.pgdg12+1

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# hadolint ignore=DL3008
RUN apt-get update && \
    apt-get install -y --no-install-recommends curl ca-certificates gnupg cron jq && \
    curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | \
      gpg --dearmor -o /usr/share/keyrings/pgdg.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/pgdg.gpg] http://apt.postgresql.org/pub/repos/apt bookworm-pgdg main" \
      > /etc/apt/sources.list.d/pgdg.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends "pgbackrest=${PGBACKREST_VERSION}" && \
    rm -rf /var/lib/apt/lists/*

# Match postgres UID 999 so it can read PG data and socket
RUN groupmod -o -g 999 postgres && \
    usermod -o -u 999 postgres && \
    mkdir -p /var/log/pgbackrest && \
    chmod 750 /var/log/pgbackrest && \
    chown postgres:postgres /var/log/pgbackrest && \
    mkdir -p /var/spool/pgbackrest && \
    chmod 750 /var/spool/pgbackrest && \
    chown postgres:postgres /var/spool/pgbackrest

# Crontab and the job env file are written at container start by the
# entrypoint, because the schedules and secrets come from env vars.
COPY entrypoint.sh run-job.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/run-job.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["cron", "-f"]
