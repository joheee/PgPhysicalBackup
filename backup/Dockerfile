FROM debian:bookworm-slim

RUN apt-get update && \
    apt-get install -y curl ca-certificates gnupg && \
    curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | \
      gpg --dearmor -o /usr/share/keyrings/pgdg.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/pgdg.gpg] http://apt.postgresql.org/pub/repos/apt bookworm-pgdg main" \
      > /etc/apt/sources.list.d/pgdg.list && \
    apt-get update && \
    apt-get install -y pgbackrest && \
    rm -rf /var/lib/apt/lists/*

# Match postgres UID (999) from official image so it can read data dirs
# pgbackrest package already created postgres user/group — just fix the IDs
RUN groupmod -g 999 postgres && \
    usermod -u 999 postgres && \
    mkdir -p -m 750 /var/lib/pgbackrest && \
    chown postgres:postgres /var/lib/pgbackrest && \
    mkdir -p -m 750 /var/log/pgbackrest && \
    chown postgres:postgres /var/log/pgbackrest && \
    mkdir -p -m 750 /var/spool/pgbackrest && \
    chown postgres:postgres /var/spool/pgbackrest && \
    mkdir -p /etc/pgbackrest/conf.d

COPY pgbackrest-conf/pgbackrest.conf /etc/pgbackrest/pgbackrest.conf
RUN chmod 640 /etc/pgbackrest/pgbackrest.conf && \
    chown postgres:postgres /etc/pgbackrest/pgbackrest.conf

CMD ["sleep", "infinity"]
