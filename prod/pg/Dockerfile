FROM postgres:17

RUN apt-get update && \
    apt-get install -y curl ca-certificates gnupg && \
    curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | \
      gpg --dearmor -o /usr/share/keyrings/pgdg.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/pgdg.gpg] http://apt.postgresql.org/pub/repos/apt bookworm-pgdg main" \
      > /etc/apt/sources.list.d/pgdg.list && \
    apt-get update && \
    apt-get install -y pgbackrest && \
    rm -rf /var/lib/apt/lists/*

RUN mkdir -p -m 750 /var/spool/pgbackrest && \
    chown postgres:postgres /var/spool/pgbackrest && \
    mkdir -p -m 750 /var/log/pgbackrest && \
    chown postgres:postgres /var/log/pgbackrest
