# pg-physical-backup

[![checks](https://github.com/joheee/PgPhysicalBackup/actions/workflows/checks.yml/badge.svg)](https://github.com/joheee/PgPhysicalBackup/actions/workflows/checks.yml)

Physical PostgreSQL 17 backups with **pgBackRest → Amazon S3**, run by Docker Compose: continuous WAL archiving, scheduled full and differential backups, client-side AES-256 encryption, alerts when a job fails or stops running, and a script to rebuild a host from the latest backup.

The goal of the project is **backups you can prove restore, with measured numbers**. A throwaway `restore` container restores from S3, checks the result and writes a report, and `drill/run.sh` runs every recovery scenario end to end on a throwaway stanza. See [Status](#status).

## Status

| Area | State |
|---|---|
| WAL archiving to S3, scheduled full / diff / `check` jobs, encryption | Built. First real full backup and `check` succeeded on S3. |
| Hardening (region, data checksums, localhost ports, pinned versions, no secrets in cron files, confirmed wipes) | Built and tested. |
| Failure alerts (non-zero exit, webhook, dead-man's switch) | Built. Tested against a stand-in listener; not yet seen with a real Slack / Healthchecks.io endpoint. |
| Readable logs (schedule table, countdown, live view) | Built and tested. |
| CI (`checks.yml`: shellcheck, hadolint, actionlint, compose config) | Built and green on GitHub (no AWS access needed). |
| `restore` container: latest, point-in-time, named restore point, older set and delta restores into an empty directory with `archive_mode=off`, checks, Markdown + JSON report | Built and run against the real S3 stanza. The real stanza has no user database, so single-database is covered by the drill's `appdb` (see [Drill results](#drill-results-against-s3)). |
| `drill/run.sh`: self-contained drill on a throwaway stanza with seeded data (RPO, row-count checks, `verify`, failure alerts, all 7 restore and failure scenarios) | Built and **run against S3** (run `20261109T003021Z`): every scenario passes. Results in [Drill results](#drill-results-against-s3). |
| 10 GB benchmark | **Done and passing** (run `20261111T200536Z`: full restore 195 s, delta 85 s, RPO 10 s). Results in [Benchmark](#benchmark-10-gb). Only `latest` and `delta` ran at this size. |

Smaller measured runs: a 22 MB test database ([Measured so far](#measured-so-far)) and the all-scenario drill on a 52 MB database ([Drill results](#drill-results-against-s3)).

## Architecture

```mermaid
flowchart LR
    subgraph HOST["Docker host (laptop, VPS or EC2)"]
        PG[("pg<br/>PostgreSQL 17 + pgBackRest")]
        BK["pg-cron-backup<br/>cron: full / diff / check<br/>run-job.sh wrapper"]
        RS["restore container<br/>(on demand)"]
        PG ---|"unix socket + pg-data"| BK
    end

    S3[("Amazon S3<br/>pgBackRest repo<br/>AES-256-CBC + SSE-S3")]
    WH["Webhook<br/>(Slack or similar)"]
    HC["Healthchecks.io<br/>dead-man's switch"]

    PG -->|"archive-push (every WAL segment)"| S3
    BK -->|"backup / check"| S3
    BK -->|"on failure"| WH
    BK -->|"ping on success, /fail on failure"| HC
    S3 -.->|"restore into empty dir<br/>archive_mode=off"| RS
```

| Component | Role |
|---|---|
| `pg` | PostgreSQL 17 with pgBackRest. `archive_mode=on`, so every WAL segment goes to S3. Data checksums are on. |
| `pg-cron-backup` | Debian + cron + pgBackRest. Runs the jobs through `run-job.sh` and prints the schedule and countdown. Shares `pg-data` (read-only) and the socket with `pg`. |
| S3 bucket | The pgBackRest repository: base backups and WAL archive, encrypted client-side and with SSE-S3. |
| `pgadmin` (optional) | Web UI behind the `pgadmin` Compose profile, localhost only. |

## Repository layout

```
.
├── docker-compose.yml          # project "pgdemo": pg, backup, restore / pgadmin / drill (profiles)
├── start.sh                    # generate configs, build, start pg + backup, create stanza
├── restore.sh                  # DR: rebuild this host from the latest backup
├── .env.example                # all configuration (copy to .env, chmod 600)
├── pg/Dockerfile               # postgres:17.11 (digest-pinned) + pgBackRest 2.60.0
├── drill/
│   ├── run.sh                  # the restore drill: throwaway source + stanza, every scenario, summary
│   ├── seed.sql                # orders, canary and schema_migrations tables
│   └── listener.py             # stand-in webhook / dead-man's switch for the failure scenario
├── restore/
│   ├── Dockerfile              # same base + pgBackRest, plus jq
│   ├── entrypoint.sh           # preflight → restore → start → wait → checks → report → clean up
│   ├── checks.sh               # generic checks and the EXPECT_FILE checks
│   └── report.sh               # JSON + Markdown report
├── reports/                    # restore reports (git-ignored; keepers are summarised in this README)
├── backup/
│   ├── Dockerfile
│   ├── entrypoint.sh           # root-only job env file, schedule-only crontab, startup table
│   ├── run-job.sh              # wraps every job: logs, duration, webhook alert, health ping
│   ├── status.sh               # next run times
│   └── countdown.sh            # countdown lines for docker logs, or --live
├── configs/
│   ├── pg-pgbackrest.conf.tmpl     # archive-push / archive-get
│   └── backup-pgbackrest.conf.tmpl # backup, retention, compression
└── .github/workflows/checks.yml
```

`configs/*.conf` and `configs/s3-keys.env` are generated by `start.sh` and git-ignored.

## Quick start

You need Docker with Compose, plus an S3 bucket and IAM credentials ([AWS setup](#aws-setup)).

```bash
cp .env.example .env
chmod 600 .env           # it holds the passphrase and the S3 keys
$EDITOR .env             # bucket, keys, passphrase, passwords
./start.sh
```

`start.sh` refuses to run while `PGBACKREST_CIPHER_PASS` is still `changeme`. Generate a real one with `openssl rand -base64 48` and keep it safe: **without it the backups cannot be read**.

`start.sh` generates the configs, builds the images, starts `pg`, creates the stanza if it doesn't exist, then starts the backup container. Verify and take the first backup:

```bash
docker exec pg psql -U postgres -c "SHOW data_checksums;"                 # on
docker exec -u postgres pg pgbackrest --stanza=pg check                   # WAL reaches S3
docker exec -u postgres pg-cron-backup pgbackrest --stanza=pg --type=full backup
docker exec -u postgres pg pgbackrest --stanza=pg info                    # backup listed
```

`POSTGRES_PASSWORD` and the data checksum setting apply only when `pg-data` is first created. See [Troubleshooting](#troubleshooting) to change a password later.

## AWS setup

Everything runs locally; AWS is used only for S3 and IAM, in `ap-southeast-2`. The bucket and IAM user are created by hand (there is no infrastructure code in this repo). Set `BUCKET` to a globally unique name and run these with admin credentials in your own account.

### 1. Bucket

Required settings: public access blocked, bucket-owner-enforced ownership, SSE-S3, versioning on, and lifecycle rules **only** for old versions, incomplete uploads and the `drill/` prefix. Never add an expiry rule to the live repository path (`pgbackrest/`): pgBackRest owns retention there and expiring files under it breaks the backup chain.

```bash
BUCKET=my-unique-pgbackrest-bucket
REGION=ap-southeast-2

aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
  --create-bucket-configuration LocationConstraint="$REGION"
aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws s3api put-bucket-ownership-controls --bucket "$BUCKET" \
  --ownership-controls 'Rules=[{ObjectOwnership=BucketOwnerEnforced}]'
aws s3api put-bucket-encryption --bucket "$BUCKET" --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
aws s3api put-bucket-versioning --bucket "$BUCKET" --versioning-configuration Status=Enabled
aws s3api put-bucket-tagging --bucket "$BUCKET" \
  --tagging 'TagSet=[{Key=project,Value=pg-physical-backup},{Key=environment,Value=demo}]'
aws s3api put-bucket-lifecycle-configuration --bucket "$BUCKET" --lifecycle-configuration file://lifecycle.json
```

`lifecycle.json`:

```json
{
  "Rules": [
    { "ID": "noncurrent-versions", "Status": "Enabled", "Filter": {},
      "NoncurrentVersionExpiration": { "NoncurrentDays": 7 } },
    { "ID": "abort-incomplete-multipart-uploads", "Status": "Enabled", "Filter": {},
      "AbortIncompleteMultipartUpload": { "DaysAfterInitiation": 7 } },
    { "ID": "expired-delete-markers", "Status": "Enabled", "Filter": {},
      "Expiration": { "ExpiredObjectDeleteMarker": true } },
    { "ID": "expire-drill-prefix", "Status": "Enabled", "Filter": { "Prefix": "drill/" },
      "Expiration": { "Days": 7 } }
  ]
}
```

Versioning plus the 7-day noncurrent rule means a deleted backup file stays recoverable for a week. Optionally also deny non-TLS requests with a bucket policy on `aws:SecureTransport = false`.

### 2. IAM policy and user

pgBackRest needs four S3 actions. This policy grants them on the two prefixes only:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ListRepoPrefixes",
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::YOUR-BUCKET",
      "Condition": {
        "StringLike": { "s3:prefix": ["pgbackrest", "pgbackrest/*", "drill", "drill/*"] }
      }
    },
    {
      "Sid": "ReadWriteRepoObjects",
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
      "Resource": [
        "arn:aws:s3:::YOUR-BUCKET/pgbackrest/*",
        "arn:aws:s3:::YOUR-BUCKET/drill/*"
      ]
    }
  ]
}
```

It deliberately omits `s3:DeleteObjectVersion`: on a versioned bucket `DeleteObject` only adds a delete marker, so a leaked key cannot permanently destroy backups within the 7-day window. It also grants nothing on the bucket configuration, IAM or EC2. The `s3:prefix` condition on `ListBucket` is the part most likely to need loosening if pgBackRest lists a path the condition doesn't cover; if you see `AccessDenied` on a list call, widen it first.

```bash
USER=pg-physical-backup-demo
aws iam create-user --user-name "$USER" \
  --tags Key=project,Value=pg-physical-backup Key=environment,Value=demo
aws iam put-user-policy --user-name "$USER" --policy-name pgbackrest-repo \
  --policy-document file://iam-policy.json          # the JSON above, with your bucket name
aws iam create-access-key --user-name "$USER"       # the secret is shown once
```

Put the access key pair only in `.env` (mode 600). Never in the repo, a ticket or a chat. Deactivate it when you aren't running demos:

```bash
aws iam update-access-key --user-name "$USER" --access-key-id AKIA... --status Inactive
```

### 3. On EC2 instead of a laptop

Attach the same policy to an **instance profile role** and leave `PGBACKREST_AWS_ACCESS_KEY_ID` / `PGBACKREST_AWS_SECRET_ACCESS_KEY` unset. `start.sh` then selects `repo1-s3-key-type=auto` and no keys exist anywhere. Off EC2, `auto` hangs probing the instance metadata endpoint, so use static keys there.

### Cost

S3 storage only, under about $1 a month for the demo databases with the default retention (2 full and 4 differential backups, WAL expired by pgBackRest). There is no always-on compute: the demo runs on your machine. Restores download from S3 and the first 100 GB a month of data out to the internet is free.

For your own database, monthly cost is roughly the repository size (see `pgbackrest info`) times the S3 Standard price per GB-month in `ap-southeast-2`, plus request charges. With versioning on, files that pgBackRest deletes stay as noncurrent versions for 7 days before they expire, so expect the bill to run a little above the live repository size. Drill objects under `drill/` expire after 7 days. The 10 GB benchmark is a one-off.

## Configuration (`.env`)

| Variable | Default | Purpose |
|---|---|---|
| `PGBACKREST_STANZA` | `pg` | Stanza name (one database = one stanza) |
| `POSTGRES_USER` / `POSTGRES_PASSWORD` | `postgres` / `changeme` | Superuser. The password applies on first init only. |
| `PGBACKREST_S3_BUCKET` | — | Repo bucket (required) |
| `PGBACKREST_AWS_DEFAULT_REGION` | `ap-southeast-2` | S3 region |
| `PGBACKREST_S3_ENDPOINT` | `s3.ap-southeast-2.amazonaws.com` | S3 endpoint |
| `PGBACKREST_AWS_ACCESS_KEY_ID` / `..._SECRET_ACCESS_KEY` | — | Static IAM user keys (laptop, VPS). Unset on EC2. |
| `PGBACKREST_CIPHER_PASS` | `changeme` (refused) | AES-256-CBC passphrase. Required, same on every host that touches the repo. |
| `PGBACKREST_RETENTION_FULL` / `_DIFF` | `2` / `4` | Retention by count |
| `PGBACKREST_ARCHIVE_TIMEOUT` | `60` | Postgres `archive_timeout` and pgBackRest `archive-timeout` (seconds) |
| `PGBACKREST_BACKUP_FULL_CRON` | `"07 2 * * 0"` | Full backup, Sunday 02:07 **UTC** |
| `PGBACKREST_BACKUP_DIFF_CRON` | `"07 2 * * 1-6"` | Differential, Monday to Saturday 02:07 UTC |
| `PGBACKREST_BACKUP_CHECK_CRON` | `"17 7 * * *"` | `pgbackrest check`, daily 07:17 UTC |
| `ALERT_WEBHOOK_URL` | unset | Failure alert target (Slack-compatible `{"text": ...}`) |
| `HEALTHCHECK_URL_FULL` / `_DIFF` / `_CHECK` | unset | One Healthchecks.io check per job |
| `COUNTDOWN_INTERVAL_SECONDS` | `1` | Seconds between countdown lines in `docker logs`; `0` = off |
| `PGADMIN_DEFAULT_EMAIL` / `_PASSWORD` | `admin@test.com` / unset | pgAdmin login (profile `pgadmin`) |
| `PGBACKREST_COMPRESS_LEVEL`, `_COMPRESS_LEVEL_NETWORK`, `_PROCESS_MAX` | `6`, `3`, `4` | Optional tuning. `_PROCESS_MAX` is also the worker count of the restore container. |
| `RESTORE_*`, `EXPECT_FILE` | unset | Restore container scenarios, see [Restore container](#restore-container) |

Cron values contain spaces, so keep them **quoted** (`start.sh` sources the file). All cron times are UTC.

## Running it

### Logs and countdown

```bash
docker logs -f pg-cron-backup
```

At start the container prints the next run of each job, then a countdown line every second, and after every job a result line:

```
Next scheduled jobs (now: Fri 2026-11-06 19:25 UTC):
  Differential backup  [06:41:24]  Sat 2026-11-07 02:07 UTC
  Health check         [11:51:24]  Sat 2026-11-07 07:17 UTC
  Full backup          [30:41:24]  Sun 2026-11-08 02:07 UTC
...
2026-11-06T19:25:39Z [countdown] Differential backup [06:41:21] | Health check [11:51:21] | Full backup [30:41:21]
2026-11-06T19:58:08Z [check] Health check: finished OK in 0m 5s
2026-11-06T19:58:08Z [scheduler] next: Differential backup [06:41:19] | ...
```

Extra commands:

```bash
docker exec -it pg-cron-backup countdown.sh --live   # one line that redraws in place; stores nothing; Ctrl-C quits
docker exec pg-cron-backup status.sh                 # next run times
docker logs pg-cron-backup 2>&1 | grep -v '\[countdown\]'   # job output without the countdown
```

Docker logs can only append lines, so the in-place redraw lives in `--live`, not in the log pane. Log storage is capped: the `local` driver, `max-size: 37m` (about 3 days at one line per second), `max-file: 2`, rotated files compressed, so disk use peaks near 38 MiB. Docker rotates by size, not time: if you change `COUNTDOWN_INTERVAL_SECONDS`, change `max-size` in proportion (interval `10` → `370m`). The per-file `backup file` lines pgBackRest prints are filtered out of the log.

### Alerts

Every job runs through `backup/run-job.sh`. On failure it exits non-zero, writes the error to `docker logs`, posts the last lines of output to `ALERT_WEBHOOK_URL`, and pings `<healthcheck-url>/fail`. On success it pings the check URL, so a job that silently stops running is caught by the missed ping.

1. Create three checks at [healthchecks.io](https://healthchecks.io) (free tier): one for each job, with periods that match the schedule (daily for `diff` and `check`, weekly for `full`) and a grace time. Put the ping URLs in `HEALTHCHECK_URL_FULL`, `_DIFF`, `_CHECK`.
2. Create an incoming webhook in Slack (or a Slack-compatible one such as Discord's `/slack` endpoint) and set `ALERT_WEBHOOK_URL`.
3. `docker compose up -d backup` to pick up the new values.

Both are optional; with neither set, failures appear only in `docker logs`, and the container prints a warning at start. The failure path (non-zero exit, log output, webhook JSON, `/fail` ping) has been tested against a stand-in listener, not against a real Slack or Healthchecks.io endpoint. To try it with your own, run a job with broken credentials:

```bash
docker exec pg-cron-backup /usr/local/bin/run-job.sh check check     # note the exit code
```

### Routine commands

```bash
docker exec -u postgres pg pgbackrest --stanza=pg info          # backups and WAL range
docker exec -u postgres pg pgbackrest --stanza=pg check         # archive and repo sanity
docker exec -u postgres pg-cron-backup pgbackrest --stanza=pg --type=full backup
docker exec pg psql -U postgres -c "SELECT pg_switch_wal();"    # force a WAL segment out
```

### pgAdmin (optional)

```bash
docker compose --profile pgadmin up -d pgadmin      # http://localhost:5435
```

Set `PGADMIN_DEFAULT_PASSWORD` in `.env` first. Register the server with **host `pg`, port `5432`**, user `postgres` and your `POSTGRES_PASSWORD`. Not `localhost`: inside the pgAdmin container that is pgAdmin itself. From tools on your machine use `127.0.0.1:5434`. The `pgadmin-data` directory must be owned by uid 5050.

### Restore container

Proves a backup restores, without touching the running database. It never mounts `pg-data`: it restores into its own named volume (`pgdemo_restore-data`), starts Postgres on a unix socket only with `archive_mode=off`, waits for recovery to finish, runs the checks, writes a report and exits. Needs `./start.sh` to have run once (it generates the config and creates `reports/`).

```bash
docker compose run --rm restore                 # latest backup of the real stanza
```

The container exists only while a run is in progress (about 1.5 minutes for the test database) and is deleted afterwards (`--rm`); it never shows in `docker compose ps`. What stays: the `pgdemo-restore` image, the (emptied) volume and `./reports/`.

Scenarios are chosen with environment variables:

```bash
RESTORE_TYPE=time RESTORE_TARGET="2026-11-06 20:04:01+00" docker compose run --rm restore   # point-in-time
RESTORE_TYPE=name RESTORE_TARGET=pre_migration            docker compose run --rm restore   # named restore point
RESTORE_SET=20261106-183638F                              docker compose run --rm restore   # older backup set
RESTORE_DB_INCLUDE=appdb                                  docker compose run --rm restore   # one user database
RESTORE_KEEP=1 docker compose run --rm restore            # keep the restored data...
RESTORE_DELTA=1 docker compose run --rm restore           # ...then repair it, fetching changed files only
RESTORE_VERIFY=1 docker compose run --rm restore          # also run `pgbackrest verify` on the whole repo
```

| Variable | Meaning |
|---|---|
| `RESTORE_TYPE` / `RESTORE_TARGET` | `time` (a timestamp with a zone, such as `2026-11-06 20:04:01+00`) or `name` (a restore point). `immediate` (no target) stops as soon as the backup is consistent, which with `RESTORE_SET` gives that backup exactly as it was. Always `--target-action=promote`. |
| `RESTORE_SET` | A backup label from `pgbackrest info` |
| `RESTORE_DB_INCLUDE` | A **user** database. pgBackRest always restores system databases, and the container rejects `postgres`, `template0` and `template1`. The other user databases come back as empty placeholders and must be dropped. |
| `RESTORE_DELTA` | `1` restores onto an existing directory and only fetches changed files |
| `RESTORE_KEEP` | `1` keeps the restored data after the run (clear it with `docker volume rm pgdemo_restore-data`) |
| `RESTORE_VERIFY` | `1` also runs `pgbackrest verify` (downloads the whole repository) |
| `EXPECT_FILE` | JSON of facts from the source (row counts, canary table, failure time, RPO limit); see `restore/checks.sh`. The drill supplies it. |
| `PGBACKREST_STANZA` / `PGBACKREST_REPO1_PATH` | Point at another stanza or repository path (the drill uses these) |
| `PGBACKREST_PROCESS_MAX` | Parallel download workers (default `4`) |
| `RESTORE_DATA_VOLUME` | The volume to restore into (default `restore-data`; the drill uses `drill-restore-data`) |

**Checks:** the backup was found; the restore succeeded; recovery finished; `archive_mode` is `off`; data checksums are on; the server answers queries; `pg_amcheck --all` finds no corruption; for a targeted restore, Postgres's own log line showing where it stopped (for example `recovery stopping before commit of transaction 754` or `recovery stopping at restore point "restore_test_1"`); and, with an `EXPECT_FILE`, the row counts and RPO. The exit code is non-zero if any check fails, and a report that cannot be built also fails the run.

**Safety:** the target must be empty (a plain run onto leftover data exits with code 2 and changes nothing); `initdb` never runs; the container only clears a directory that it found empty and restored into itself, never after a delta run; and it has no way to write into the stanza, because archiving is off.

Each run saves `reports/<run-id>-<scenario>.json` and `.md`, for example:

```
| Backup restored | 20261106-183638F (full), 22.1 MB database, 2.9 MB in the repository |
| Restore time | 59s (4 parallel workers) |
| WAL replay time | 11.7s (Postgres start until recovery finished) |
| Repository | upwork-pgbackrest /pgbackrest stanza pg |
| Versions | PostgreSQL 17.11, pgBackRest 2.60.0 |
```

#### Measured so far

From the real stanza, on one laptop against S3 in `ap-southeast-2`, restoring a **22.1 MB database (966 files)**. This is a tiny test database, not a benchmark; the 10 GB run is in [Benchmark](#benchmark-10-gb).

| Run | Restore time | WAL replay |
|---|---|---|
| Latest, 1 worker | 239.8 s | not recorded (report bug, since fixed) |
| Latest, 4 workers | 59.0 s | 11.7 s |
| Point-in-time (target 3 s before a commit) | 60.3 s | 13.7 s |
| Named restore point | 64.4 s | 15.2 s |
| Older set (explicit label) | 65.1 s | 17.7 s |
| Delta onto the previous restore | 7.7 s | 15.7 s |

Why a small database is slow: pgBackRest fetches every file with its own S3 request, and a cluster has about a thousand small files, so latency dominates, not size. Parallel workers gave about 4x here. Delta restore skips files that already match and was about 8x faster than a full restore. pgBackRest's `repo1-bundle` option groups small files at backup time and would cut the per-file requests; it applies only to new backups and has not been tried here.

### Restore drill (`drill/run.sh`)

Runs the recovery scenarios end to end and reports pass/fail, restore time and RPO. It never touches `pg`, `pg-data` or the real stanza: it starts a throwaway `drill-source` Postgres (Compose profile `drill`) that archives to its own stanza, `drill`, under `drill/<run-id>/` in the same bucket, with a random cipher passphrase for the run. Needs `./start.sh` to have run once (or `./start.sh gen-configs`), and `jq` on the host.

```bash
drill/run.sh                          # must-haves: latest (+ verify), pitr, failure
drill/run.sh --scenario all           # all scenarios (about 10 minutes for the small default data set)
drill/run.sh --scenario pitr,delta    # only these; the seed and backups always run
drill/run.sh --keep                   # keep the drill containers and volumes for a look afterwards
```

What one run does:

1. Starts `drill-source` (no ports, unix socket only) and a stand-in webhook listener, creates the `drill` stanza.
2. Seeds `appdb` (pgbench at `DRILL_PGBENCH_SCALE`, 1000 `orders`, `schema_migrations`) and `reportsdb`, and starts a canary that commits one row a second.
3. Full backup, `pgbench` for `DRILL_PGBENCH_SECONDS`, 500 more orders, differential backup.
4. Failure scenario (below).
5. The mistakes, in order: `pg_create_restore_point('drill_pre_migration')`, a bad migration (zeroes every amount, deletes a third of the orders), 200 more orders, a recorded time T, `DELETE FROM orders`, 50 new orders. It waits until that WAL is in the repository, then `docker kill`s the source a few seconds later (a crash, not a clean shutdown).
6. Writes an `EXPECT_FILE` per scenario with what the source knew (exact row counts, canary count, the kill time, the RPO limit) and runs the restore container once per scenario into its own `drill-restore-data` volume.
7. Writes `reports/drill-<run-id>/summary.md` and `summary.json` (backups with size and duration, one row per scenario) next to each scenario's JSON and Markdown report and its logs. Exit code 1 if any check fails.

| Scenario | Restore | What must be true afterwards |
|---|---|---|
| `latest` | Latest backup plus all archived WAL, and `pgbackrest verify` on the repository | Final row counts match the source; RPO (kill time minus the newest restored canary row) is under `DRILL_RPO_MAX_SECONDS` (default `2 x archive_timeout + 10`) |
| `pitr` | `--type=time --target=T` | Postgres stopped before the first commit after T; the orders deleted after T are back |
| `failure` | none | `run-job.sh check` with fake S3 keys and, separately, with archiving stopped (`pgbackrest stop` on the source), exits non-zero, posts the webhook and pings `/fail`; once archiving is back the same job passes and sends the success ping only |
| `named-point` | `--type=name --target=drill_pre_migration` | Orders as before the bad migration, no migration row |
| `older-set` | `--set=<full backup> --type=immediate` | Exactly the full backup: 1000 orders, empty `pgbench_history` |
| `single-db` | `--db-include=appdb` | `appdb` matches the source; `reportsdb` comes back as an empty placeholder (drop it) |
| `delta` | After `latest` (kept), the `orders` table file is removed from the copy, then `--delta` | The table is back and every count matches; the report shows the delta time next to the full restore |

`pg_amcheck` and the generic checks (recovery finished, `archive_mode=off`, data checksums, queryable) run in every restore scenario.

| Variable | Default | Meaning |
|---|---|---|
| `DRILL_PGBENCH_SCALE` | `1` | pgbench scale (1 gives a cluster of about 50 MB; 680 is about 10 GB) |
| `DRILL_PGBENCH_SECONDS` | `15` | pgbench run between the full and the differential backup |
| `DRILL_ARCHIVE_TIMEOUT` | `10` | `archive_timeout` of the drill source, which bounds the RPO |
| `DRILL_RPO_MAX_SECONDS` | `2 x archive_timeout + 10` | RPO limit for the `latest`, `single-db` and `delta` checks |
| `DRILL_ARCHIVE_DRAIN_TIMEOUT` | `3600` | Seconds to wait after seeding for the WAL archive to catch up. A large seed (about 8 GB of WAL at scale 680) is written in under a minute but archived one segment at a time; without the wait, `pgbackrest check` times out with `[082]`. |

**Cleanup:** at the end (pass or fail) the drill removes its own containers and volumes (`drill-source`, `drill-listener`, `pgdemo_drill-source-data`, `pgdemo_drill-socket`, `pgdemo_drill-restore-data`), never anything else. If those volumes already exist when it starts (a `--keep` run or a crash), it refuses and prints the commands to remove them. The drill's objects stay in S3 under `drill/<run-id>/` and expire through the bucket's `drill/` lifecycle rule; nothing deletes them by hand.

**Secrets:** the random passphrase reaches the containers only through environment variables, never a command line or a file, and pgBackRest prints it as `<redacted>`. The failure scenario uses AWS's documented example key ID, which can never be valid.

### Drill results against S3

One `drill/run.sh --scenario all` run against the real bucket, `ap-southeast-2`, run id `20261109T003021Z`, on a 16-CPU / 15.7 GB laptop with 4 restore workers. PostgreSQL 17.11, pgBackRest 2.60.0, pgbench scale 1 (about 52 MB database), `archive_timeout` 10 s. **Result: PASS, 81 checks passed, none failed.** This is a small data set: it shows the scenarios work end to end, not how long a large restore takes (that is the [10 GB benchmark](#benchmark-10-gb)).

| Backup | Type | Database | In repository | Took |
|---|---|---|---|---|
| `20261109-003119F` | full | 51.8 MB | 5.1 MB | 116 s |
| `20261109-003119F_20261109-003347D` | diff | 53.7 MB | 5.8 MB | 18 s |

| Scenario | Result | Restore | WAL replay | Total | RPO |
|---|---|---|---|---|---|
| `latest` (crash, `docker kill`) | PASS | 101.2 s | 19.7 s | 130.2 s | 10 s |
| `pitr` (before `DELETE FROM orders`) | PASS | 100.7 s | 13.3 s | 123.6 s | |
| `failure` (alerts) | PASS | | | | |
| `named-point` (before bad migration) | PASS | 103.5 s | 13.0 s | 126.4 s | |
| `older-set` (the full backup) | PASS | 103.6 s | 4.3 s | 134.0 s | |
| `single-db` (`--db-include=appdb`) | PASS | 80.7 s | 18.3 s | 106.2 s | 10 s |
| `delta` (`--delta`) | PASS | 16.8 s | 18.4 s | 45.4 s | 10 s |

Every restore scenario also passed these checks: recovery finished (`pg_is_in_recovery() = false`), `archive_mode = off`, data checksums on, queryable, `pg_amcheck --all` found no corruption, and the row counts matched what the source recorded. `latest` also ran `pgbackrest verify` on the repository (pass). Delta was about 6x faster than a full restore of the same backup (16.8 s against 101.2 s).

| Failure check | Result | Detail |
|---|---|---|
| Broken S3 keys: job fails | PASS | `run-job.sh` exited 39 |
| Broken S3 keys: webhook alert | PASS | webhook got the FAILED message |
| Broken S3 keys: `/fail` ping | PASS | dead-man's switch got `/fail` |
| Archiving stopped: job fails | PASS | exited 82, `WAL segment ... was not archived before the 15000ms timeout` |
| Archiving stopped: alert and `/fail` ping | PASS | both received |
| Healthy again: job passes | PASS | exited 0 |
| Healthy again: success ping, no alert | PASS | ping received, no alert sent |

The alert and ping targets in this run were the drill's stand-in listener, not a real Slack or Healthchecks.io endpoint.

### Benchmark (10 GB)

One recorded run of the same drill with a ~10 GB database, to show how restore time scales beyond the 50 MB runs above. It is run once, by hand, against the real bucket (objects under `drill/<run-id>/` expire after 7 days).

```bash
DRILL_PGBENCH_SCALE=680 drill/run.sh --scenario latest,delta
```

Scale 680 gives about 10 GB; `latest` gives the full restore and WAL replay time and RPO, and `delta` gives the repair time to compare against. Everything in the table comes from `reports/drill-<run-id>/summary.md` and `info.json`.

Run `20261111T200536Z` (2026-11-11), real bucket in `ap-southeast-2`, 16-CPU / 15.7 GB laptop, 4 workers, PostgreSQL 17.11, pgBackRest 2.60.0, pgbench scale 680, `archive_timeout` 10 s. **Result: PASS.** All 14 `latest` checks passed (including `pgbackrest verify` on the repository and `pg_amcheck --all`), and the delta run passed too.

| | Value |
|---|---|
| Database size | 10,205 MB (68,000,000 `pgbench_accounts` rows) |
| Full backup | 290 s, 464 MB in the repository |
| Differential backup | 250 s, 470 MB in the repository |
| Restore, `latest` (4 workers) | 195.4 s, plus 7.7 s WAL replay, 247.2 s in total |
| Restore, `delta` (4 workers) | 84.6 s, plus 8.0 s WAL replay, 137.0 s in total |
| RPO | 10 s |
| S3 under `drill/<run-id>/` | 1.06 GB: 0.98 GB of backups, 0.08 GB of WAL |
| Network | upload and download speed were not recorded for this run |

How to read these numbers:

- **The data compresses about 22 to 1** (10.2 GB became 0.46 GB), because pgbench data is very regular. The restore therefore downloaded under 0.5 GB, and the 195 s is mostly writing and decompressing 10 GB, not network time. A real database compresses less, so a real restore of the same size would be more network-bound and slower. Treat these as a measured example for this workload, not a promise for yours.
- **Delta was 2.3x faster** than the full restore here, against 6 to 8x on the 22 to 52 MB runs. A delta restore has to checksum every file already on disk, and that costs more at 10 GB.
- **The differential backup was nearly as large as the full one.** pgbench updates touch every 1 GB table segment and pgBackRest copies whole changed files.
- **Only `latest` and `delta` ran at this size.** The other scenarios were proven at 52 MB (see [Drill results](#drill-results-against-s3)).
- **Archiving can lag a bulk load.** Seeding wrote about 8 GB of WAL in under a minute, but `archive_command` pushes one segment at a time. `drill/run.sh` now waits for the archive to catch up before `check` and before each backup (`DRILL_ARCHIVE_DRAIN_TIMEOUT`); without that wait the first attempts failed with `[082]`. A client with a heavy write load would want asynchronous archiving (`archive-async`), which needs `archive-push-queue-max` raised first because pgBackRest discards WAL past that limit. This kit has not tested that.

The drill's objects expire through the bucket's `drill/` lifecycle rule (7 days, plus 7 more days as noncurrent versions).

### Disaster recovery (`restore.sh`)

On a fresh or replacement host, with the same `PGBACKREST_S3_BUCKET`, `PGBACKREST_CIPHER_PASS` and `PGBACKREST_STANZA` as the source in `.env`:

```bash
./restore.sh          # asks you to type the stanza name before wiping pg-data
./restore.sh --yes    # no prompt (required when there is no terminal)
```

It asks first, then stops `pg` and `backup`, wipes `pg-data` from a throwaway root container, restores the latest backup into the empty directory, and starts `pg`, which replays WAL and comes up as the primary. The restore keeps the database's system identifier, so archiving to the same stanza keeps working. Confirm with `SELECT pg_is_in_recovery();` (expect `f`).

## Runbooks

One entry per recovery case. Every restore below goes into the **restore container's own volume** (`pgdemo_restore-data`), never into `pg-data`, and runs with `archive_mode=off`, so it is safe to try while the real database is running. Each run writes `reports/<run-id>-<scenario>.md` and `.json` and exits non-zero if a check fails. Commands use the real stanza; the drill runs the same scenarios on a throwaway one (see [Restore drill](#restore-drill-drillrunsh)).

Two things only `restore.sh` does: it wipes and rebuilds `pg-data`, and it restores the **latest** backup only. Getting a *different* point back onto the production host is not scripted. The usual route is to recover into the restore container with `RESTORE_KEEP=1`, copy out the rows or tables you need, and load them into production. Restoring a target time straight into an empty `pg-data` with `pgbackrest restore --type=time` by hand uses the same options, but this repo has not tested that on `pg-data`.

| # | Situation | Command | Expected result |
|---|---|---|---|
| 1 | **Server lost** (crash, dead disk) | Prove it: `docker compose run --rm restore`. Rebuild this host: `./restore.sh` | Recovery finished, `archive_mode=off`, `pg_amcheck` clean. RPO is the age of the newest archived WAL, at most about `archive_timeout`. |
| 2 | **Human mistake** (`DELETE FROM orders` at time T) | `RESTORE_TYPE=time RESTORE_TARGET="YYYY-MM-DD HH:MM:SS+00" docker compose run --rm restore` | Postgres stops before the first commit after T, so the deleted rows are back. The target needs a commit after T in the archived WAL, or Postgres refuses to finish: run `SELECT txid_current();`, `SELECT pg_switch_wal();` and `pgbackrest check` first. |
| 3 | **Are the backups silently corrupt?** | `RESTORE_VERIFY=1 docker compose run --rm restore` | `pgbackrest verify` passes on the whole repository (downloads all of it) and `pg_amcheck --all` finds nothing on the restored copy. |
| 4 | **Is a failing backup noticed?** | Break the credentials, then `docker exec pg-cron-backup /usr/local/bin/run-job.sh check check` | Non-zero exit, `FAILED` in `docker logs`, webhook alert, `/fail` ping. See [Alerts](#alerts). The drill runs this against a stand-in listener: `drill/run.sh --scenario failure`. |
| 5 | **Before a risky migration** | `SELECT pg_create_restore_point('pre_migration');` then later `RESTORE_TYPE=name RESTORE_TARGET=pre_migration docker compose run --rm restore` | The data as it was at the restore point. |
| 6 | **Corruption noticed days later** | `docker exec -u postgres pg pgbackrest --stanza=pg info`, then `RESTORE_SET=<label> docker compose run --rm restore` | That older backup. Add `RESTORE_TYPE=immediate` to get it exactly as backed up, without replaying later WAL. |
| 7 | **One database is damaged** | `RESTORE_DB_INCLUDE=<database> docker compose run --rm restore` | That user database is restored; the other user databases come back as empty placeholders and must be dropped. System databases are always restored. |
| 8 | **Fast repair of a damaged copy** | `RESTORE_KEEP=1 docker compose run --rm restore`, then `RESTORE_DELTA=1 docker compose run --rm restore` | Only changed files are fetched. About 6 to 8x faster than a full restore on the small test databases, 2.3x at 10 GB (see [Benchmark](#benchmark-10-gb)). |

After a run with `RESTORE_KEEP=1`, clear the volume with `docker volume rm pgdemo_restore-data` before the next full restore, or the container exits with code 2 and changes nothing.

## Use this on your own database

The kit is the same on a laptop, a VPS or an EC2 instance.

1. **AWS side:** one bucket and one stanza prefix per host ([AWS setup](#aws-setup)). On EC2, attach the policy to an instance profile and set no keys. On a VPS, use a dedicated IAM user scoped to that bucket and prefix (never an admin user), with its key only in the mode-600 `.env`.
2. **Configuration:** set `PGBACKREST_STANZA`, `PGBACKREST_S3_BUCKET` and a fresh `PGBACKREST_CIPHER_PASS` (`openssl rand -base64 48`; store it somewhere other than the server, since without it the backups cannot be read), then `./start.sh`. Set `ALERT_WEBHOOK_URL` and the `HEALTHCHECK_URL_*` values so a failure or a silent stop reaches a person.
3. **Your data:** the kit runs its own PostgreSQL 17 in Compose. To bring existing data in, load it into that instance (for a small database `pg_dump` and `pg_restore` is enough; physical backups are for the case where you need point-in-time recovery or the database is large). Backing up a Postgres you already run on the host needs pgBackRest installed there with `archive_command = pgbackrest ... archive-push`; the config templates in `configs/` show the settings, but that route has not been tested in this repo.
4. **Prove it:** run `docker compose run --rm restore` and read the report. Run the scenarios from [Runbooks](#runbooks) that matter to you, and time a restore of *your* data volume: the 22 MB and 52 MB runs above are dominated by per-file S3 latency, and a large database behaves differently (see the [benchmark](#benchmark-10-gb)).
5. **Repeat it:** a monthly restore test, run by hand or from cron, is what keeps the claim true.

## Best practice this kit follows

- **Continuous WAL archiving** with `archive_timeout=60`: a quiet database still ships WAL, so worst-case data loss is about a minute.
- **Schedule:** full backup every Sunday, differential every other night, `pgbackrest check` daily, `repo1-retention-full=2`.
- **Retention owned by pgBackRest.** No S3 lifecycle rules on the live repository path.
- **Encryption:** client-side `aes-256-cbc` plus SSE-S3.
- **Data checksums** from `initdb`, so pgBackRest checks every page during a backup.
- **Secrets stay out of world-readable places.** pgBackRest does not expand `${VAR}` in its config, so the passphrase reaches it as the `PGBACKREST_REPO1_CIPHER_PASS` environment variable and never sits in a `.conf`. Cron jobs read a root-only (mode 600) env file inside the container; `/etc/cron.d` holds schedules only; nothing secret is on a command line or in a log. Static S3 keys live in `.env` (mode 600) and a generated mode-600 `configs/s3-keys.env`.
- **Localhost-only ports** (`127.0.0.1:5434`, `127.0.0.1:5435`), pgAdmin off by default.
- **Pinned versions:** images by tag and digest, pgBackRest by package version.
- **Safe restores:** into an empty directory only, `initdb` never runs first, nothing is wiped without a prompt or `--yes`. The restore container restores into its own volume, with archiving off, so it cannot write into the stanza.
- **No overlapping jobs:** pgBackRest's stanza lock stops two backups at once; the job logs it and exits non-zero.
- **Failures are loud:** non-zero exit, output in `docker logs`, a webhook alert, and a dead-man's switch that also catches a job that silently stops running (see [Alerts](#alerts)).
- **Readable logs:** schedule table, countdown and per-job result lines; the `backup file` noise is filtered out (see [Logs and countdown](#logs-and-countdown)).
- **A backup counts only once it has restored.** The scenarios are run and reported, not just documented.

## Core concepts (read before debugging)

**WAL archive ≠ base backup.** A stanza holds WAL segments (from `archive-push`) and base backups (from `pgbackrest backup`). `pgbackrest info` lists *base* backups, so a stanza can have WAL and still show no backups.

**A stanza is bound to the database's `system_identifier`.** It is generated once at `initdb` and survives backups, restores and promotion. pgBackRest rejects WAL or backups whose ID doesn't match.

**A restore preserves the system ID; `initdb` does not.** Restoring reproduces the same ID, so archiving to the same stanza keeps working. Starting Postgres on an *empty* data directory runs `initdb`, creating a new ID and causing `ArchiveMismatchError`. Hence the golden rule: **never let `initdb` run before a restore.**

**Reconciling a stale stanza.** If a data directory was re-initialised, delete and recreate the stanza (this removes the repository's history for it, so be sure):

```bash
docker exec -u postgres pg pgbackrest --stanza=pg stop
docker exec -u postgres pg pgbackrest --stanza=pg stanza-delete --force
docker exec -u postgres pg pgbackrest --stanza=pg stanza-create
```

## Troubleshooting

| Symptom | Meaning | Fix |
|---|---|---|
| `[055] FileMissingError … archive.info`, "has a stanza-create been performed?" | The stanza doesn't exist yet | `stanza-create` (`start.sh` does it) |
| `ERROR: [032] environment variable 'repo1-s3-key' must have a value` | An S3 key variable is set but empty | Leave both keys unset (EC2) or set both. `start.sh` writes `configs/s3-keys.env` only when both are set. |
| `check` or a job hangs for a long time | `repo1-s3-key-type=auto` on a host with no EC2 metadata | Set the static IAM user keys |
| `AccessDenied` from S3 | IAM policy or wrong bucket / region | Check bucket name, region, and the `s3:prefix` condition |
| pgAdmin can't log in to Postgres: `password authentication failed` | `POSTGRES_PASSWORD` in `.env` differs from the one the cluster was created with | Reset the role's password, see below the table |
| `localhost:5435` doesn't answer, logs say `Permission denied: /var/lib/pgadmin/sessions` | `pgadmin-data` is owned by root | Give it to uid 5050, see below the table |
| `ArchiveMismatchError` / `[028] info files exist but do not match` | Stanza bound to a different database instance | `stanza-delete --force` + `stanza-create` |
| `[040] unable to restore … contains files` | Restore target is not empty | Wipe the data directory first (`restore.sh` does) |
| `[055] stop file does not exist` | `stanza-delete` needs `stop` first | Run `pgbackrest … stop` first |
| `[038] postmaster.pid exists` | Postgres is running during `stanza-delete` | Add `--force` |
| `drill/run.sh`: `volume pgdemo_drill-... is left over` | An earlier drill ran with `--keep` or crashed | Run the two commands it prints |
| Restore container exits with code 2: `... is not empty` | A previous run kept its data (`RESTORE_KEEP=1` or a delta run) | `docker volume rm pgdemo_restore-data`, or run with `RESTORE_DELTA=1` |
| Restore takes minutes for a tiny database | One S3 request per file, one worker | Raise `PGBACKREST_PROCESS_MAX`; consider `repo1-bundle` for new backups |
| `[081] system databases (template0, postgres, etc.) are included by default` | `RESTORE_DB_INCLUDE` named a system database | Name a user database |
| `invalid option 'backup-full-cron'` warnings | The schedule variables are visible to a manual `docker exec` | Harmless; the cron jobs don't see them |
| Edited `.env` but nothing changed | Containers keep the environment they started with | `./start.sh` or `docker compose up -d` |

Reset the Postgres password to the value in `.env` (the value is read inside the container, so it never appears on a command line):

```bash
printf '%s\n' '\set pw `printenv POSTGRES_PASSWORD`' "ALTER USER postgres PASSWORD :'pw';" \
  | docker exec -i pg sh -c 'psql -U "$POSTGRES_USER" -d postgres'
```

Fix the `pgadmin-data` owner, then restart pgAdmin:

```bash
docker compose --profile pgadmin stop pgadmin
docker run --rm -v "$PWD/pgadmin-data:/d" --entrypoint sh pgdemo-pg -c 'chown 5050:5050 /d'
docker compose --profile pgadmin up -d pgadmin
```

## Checks (CI)

`.github/workflows/checks.yml` runs on every pull request and push to `master`, with no AWS access and no secrets: `shellcheck` on every `*.sh`, `hadolint` on every `Dockerfile`, `actionlint` on the workflows, and `docker compose config` (also with the `pgadmin` and `restore` profiles). To run the same steps locally:

```bash
git ls-files '*.sh' | xargs shellcheck
for f in $(git ls-files '*Dockerfile'); do docker run --rm -i hadolint/hadolint:v2.15.1 < "$f"; done
docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:1.7.12
docker compose --env-file .env.example --profile pgadmin --profile restore --profile drill config -q
```

## Roadmap

Done: the `restore` container (see [Restore container](#restore-container)), `drill/run.sh` run against S3 (see [Drill results](#drill-results-against-s3)), the scoped IAM user, and the [10 GB benchmark](#benchmark-10-gb). Still planned, in order (see `GOALS.md` for the full definition of done):

1. **Real alert endpoints:** set `ALERT_WEBHOOK_URL` and `HEALTHCHECK_URL_*` and see a real alert and ping arrive.
2. **Benchmark extras:** record the upload and download speed for the [10 GB run](#benchmark-10-gb), and paste a short terminal log of a drill run here.

Stretch: a weekly GitHub Actions drill against S3 over OIDC, and a monthly restore test on the client's server.
