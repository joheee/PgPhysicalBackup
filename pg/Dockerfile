FROM postgres:17.11-bookworm@sha256:665dc7b37ac52a17e298511414c21d23ffa4e6a6ef6225b3e5d59c7afb35e994

# pgBackRest is pinned; the other packages follow the digest-pinned base image.
ARG PGBACKREST_VERSION=2.60.0-1.pgdg12+1

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# hadolint ignore=DL3008
RUN apt-get update && \
    apt-get install -y --no-install-recommends curl ca-certificates gnupg && \
    curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | \
      gpg --dearmor -o /usr/share/keyrings/pgdg.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/pgdg.gpg] http://apt.postgresql.org/pub/repos/apt bookworm-pgdg main" \
      > /etc/apt/sources.list.d/pgdg.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends "pgbackrest=${PGBACKREST_VERSION}" && \
    rm -rf /var/lib/apt/lists/*

RUN mkdir -p /var/spool/pgbackrest && \
    chmod 750 /var/spool/pgbackrest && \
    chown postgres:postgres /var/spool/pgbackrest && \
    mkdir -p /var/log/pgbackrest && \
    chmod 750 /var/log/pgbackrest && \
    chown postgres:postgres /var/log/pgbackrest
