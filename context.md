# 2026-08-08T10:03+00:00 — Mount Configuration & Restore Flow

## Volume Layout

All data lives under project root — no Docker-managed named volumes.

| Host Directory | pg1 Container | pg2 Container | Backup Container |
|---|---|---|---|
| `./pg1-data` | `/var/lib/postgresql/data` | — | `/var/lib/postgresql/data` |
| `./pg2-data` | — | `/var/lib/postgresql/data` | `/var/lib/postgresql/pg2-data` |
| `./pg1-socket` | `/var/run/postgresql` | — | `/var/run/pg1-socket` |
| `./pg2-socket` | — | `/var/run/postgresql` | `/var/run/pg2-socket` |
| `./pgbackrest-repo` | `/var/lib/pgbackrest` | `/var/lib/pgbackrest` | `/var/lib/pgbackrest` |
| `./pgadmin-data` | — | — | — (pgadmin at `/var/lib/pgadmin`) |

## pg1-path Mismatch (Why sed Fix Is Needed)

pgBackRest validates `pg1-path` in config matches what the running cluster reports via socket.

- **pg1** reports `/var/lib/postgresql/data` → backup container must mount pg1-data at that exact path
- **pg2** data mounts at `/var/lib/postgresql/pg2-data` in the backup container (can't use `/var/lib/postgresql/data` — already taken by pg1)

During restore, `--pg1-path=/var/lib/postgresql/pg2-data` gets baked into `postgresql.auto.conf`. Inside the pg2 container, that path doesn't exist (pg2 sees its data at `/var/lib/postgresql/data`). Fix with:

```bash
docker exec pgbackrest sed -i \
  's|--pg1-path=/var/lib/postgresql/pg2-data|--pg1-path=/var/lib/postgresql/data|g' \
  /var/lib/postgresql/pg2-data/postgresql.auto.conf
```

## pgBackRest Config Files

### backup container (`backup/pgbackrest-conf/pgbackrest.conf`)
```ini
[pg1]
pg1-path=/var/lib/postgresql/data
pg1-socket-path=/var/run/pg1-socket

[pg2]
pg1-path=/var/lib/postgresql/pg2-data
pg1-socket-path=/var/run/pg2-socket

[global]
repo1-path=/var/lib/pgbackrest
repo1-retention-full=2
repo1-retention-full-type=count
compress-type=zst
start-fast=y
process-max=2
log-level-console=info
log-level-file=detail
log-path=/var/log/pgbackrest
```

### pg2 container (`pgbackrest-conf-pg2/pgbackrest.conf`)
```ini
[pg1]
pg1-path=/var/lib/postgresql/data

[pg2]
pg1-path=/var/lib/postgresql/data

[global]
repo1-path=/var/lib/pgbackrest
compress-type=zst
process-max=2
log-level-console=info
log-level-file=detail
log-path=/var/log/pgbackrest
```
Note: `[pg1]` stanza required for pg2 to run `archive-get` during recovery. Settings match backup container for compatibility.

### pg1 container (`pgbackrest-conf-pg1/pgbackrest.conf`)
```ini
[pg1]
pg1-path=/var/lib/postgresql/data

[global]
repo1-path=/var/lib/pgbackrest
log-level-console=info
log-path=/var/log/pgbackrest
```

# 2026-08-08T10:03+00:00 — Backup & Restore Commands

## Backup pg1

```bash
# Full (or auto-converts if no prior full)
docker exec -u postgres pgbackrest pgbackrest --stanza=pg1 --type=full backup

# Differential (changes since last full)
docker exec -u postgres pgbackrest pgbackrest --stanza=pg1 --type=diff backup

# List backups
docker exec -u postgres pgbackrest pgbackrest --stanza=pg1 info
docker exec -u postgres pgbackrest pgbackrest --stanza=pg1 --output=json info
```

## Restore pg1 Backup → pg2

Full flow (no prior pg2 data clearing needed with `--delta`):

```bash
# 1. Stop pg2
docker stop pg2

# 2. Delta restore (uses latest backup; auto-resolves diff/incr chain)
docker exec -u postgres pgbackrest pgbackrest \
  --stanza=pg1 \
  --pg1-path=/var/lib/postgresql/pg2-data \
  --type=immediate \
  --target-action=promote \
  --delta \
  restore

# 3. Fix pg1-path for pg2 container's filesystem view
docker exec pgbackrest sed -i \
  's|--pg1-path=/var/lib/postgresql/pg2-data|--pg1-path=/var/lib/postgresql/data|g' \
  /var/lib/postgresql/pg2-data/postgresql.auto.conf

# 4. If pg2 container is stale (was in restart loop), remove and recreate
# docker rm pg2
# docker compose up -d pg2

# Otherwise just start:
docker start pg2
```

## Recovery Options

| Flag | Effect |
|---|---|
| `--type=immediate` | Stops recovery at earliest consistent point. Writes `recovery_target='immediate'` in auto.conf. |
| `--target-action=promote` | Promotes to read-write after recovery. |
| `--delta` | Hash-compares existing files; only restores mismatches. Much faster for re-restores. |
| `--set=<label>` | Restore a specific backup instead of latest. |
| `--type=time --target="<ts>"` | PITR to a specific timestamp. |

# 2026-08-08T10:03+00:00 — Troubleshooting

## pg2 Restart Loop After Restore

**Root cause found**: Stale container state. After repeated failed restart attempts, `archive-get` inside the container fails in ~6ms (impossibly fast — points to lock file / spool corruption). Manual `docker run` with same config works fine (50-80ms).

**Fix**: `docker stop pg2 && docker rm pg2 && docker compose up -d pg2`

## archive-get "unable to find" WAL

If `archive-get` says it can't find a WAL segment that exists in the repo:
1. Verify the file is actually there: `ls pgbackrest-repo/archive/pg1/17-1/...`
2. Test manually from the container: `docker exec -u postgres pg2 pgbackrest --stanza=pg1 archive-get <segment> /dev/null`
3. If manual works but PostgreSQL's `restore_command` fails: stale container — recreate it
4. Check that `[pg1]` stanza exists in the container's `pgbackrest.conf`
5. Check that `compress-type=zst` and `process-max` match the backup container's settings

## pg1 check Fails With Path Mismatch

```
ERROR: [058]: path '/var/lib/postgresql/data' queried from cluster
  does not match '/var/lib/postgresql/pg1-data' from config
```

pgBackRest validates that the config's `pg1-path` matches what PostgreSQL reports. The backup container must mount pg1-data at the same path pg1 reports (`/var/lib/postgresql/data`).

## Full Backup Requires WAL Replay Too

Even a full backup writes `backup_label` + `recovery.signal` and requires `restore_command` to fetch WAL. Removing `backup_label` corrupts the cluster (`pg_control` has backup marker `0xDEAD`). Always fix `restore_command` path — never delete recovery files.

# 2026-08-08T10:03+00:00 — Infrastructure

## Containers

| Container | Image | Port |
|---|---|---|
| pg1 | `pg-physical-backup-pg1` (postgres:17 + pgbackrest) | 5434→5432 |
| pg2 | `pg-physical-backup-pg2` (postgres:17 + pgbackrest) | 5435→5432 |
| pgbackrest | `pg-physical-backup-backup` (dedicated backup) | — |
| pgadmin | `dpage/pgadmin4:latest` | 5436→80 |

## PostgreSQL Config (via docker-compose command)

```
archive_mode=on
archive_command='pgbackrest --stanza=<pg1|pg2> archive-push %p'
wal_level=replica
```

## pg2 Stanza Not Created

The `pg2` stanza was never `stanza-create`d. pg2's `archive_command` produces expected errors:
```
ERROR: [103]: unable to find archive.info for stanza pg2
```
Non-critical — pg2 serves as a restore target, not a backup source.

## pgBackRest Repo Structure

```
pgbackrest-repo/
├── archive/pg1/17-1/<timeline>/<segments>.gz
├── backup/pg1/
│   ├── backup.info
│   ├── <label>F/          # Full backup manifest + data
│   ├── <label>F_<label>D/  # Differential
│   └── <label>F_<label>I/  # Incremental
└── backup.history/
```
