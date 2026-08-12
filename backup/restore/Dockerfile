FROM debian:bookworm-slim

RUN apt-get update && \
    apt-get install -y curl ca-certificates gnupg cron docker.io && \
    curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | \
      gpg --dearmor -o /usr/share/keyrings/pgdg.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/pgdg.gpg] http://apt.postgresql.org/pub/repos/apt bookworm-pgdg main" \
      > /etc/apt/sources.list.d/pgdg.list && \
    apt-get update && \
    apt-get install -y pgbackrest && \
    rm -rf /var/lib/apt/lists/*

# Match postgres UID 999
RUN groupmod -g 999 postgres && \
    usermod -u 999 postgres && \
    mkdir -p -m 750 /var/log/pgbackrest && \
    chown postgres:postgres /var/log/pgbackrest && \
    mkdir -p -m 750 /var/spool/pgbackrest && \
    chown postgres:postgres /var/spool/pgbackrest

COPY sync.sh /usr/local/bin/sync.sh
COPY promote.sh /usr/local/bin/promote.sh
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/sync.sh /usr/local/bin/promote.sh /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["cron", "-f"]
