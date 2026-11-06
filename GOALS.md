# Project goals: PostgreSQL backups you can prove restore

This repo (joheee/PgPhysicalBackup) is portfolio project #3 for my Upwork
DevOps profile. The point is the **proof**: a client should look at it and
think "this person doesn't just set up backups, they show me the backup
actually restores, how long it takes and how much data I'd lose".

It starts from what this repo already has (built Aug–Sep 2026): PostgreSQL 17
and pgBackRest in Docker Compose, WAL archived continuously to Amazon S3,
scheduled full and differential backups from a cron container, client-side
AES-256 encryption, and `restore.sh` to rebuild a host from the latest backup.
That is the first half. This project adds the half clients actually pay for:
a restore container that tests every common recovery case, checks and a
report with measured numbers, alerts when a backup fails, and a documented,
least-privilege S3 and IAM setup.

## The pitch (what a client buys)

> "PostgreSQL backups with a tested restore, 2–3 days." Physical backups and
> point-in-time recovery with pgBackRest to S3 (encrypted, with retention),
> alerts when a backup fails or doesn't run, and a restore container that
> rebuilds the database from S3, checks it and reports the restore time and
> the data-loss window (RPO). You get the runbooks for each recovery case and
> the measured restore time for your database size.

It matches jobs like "Postgres freezes + backups" ($5,000), "Medusa backups
with restore demo", "AWS backup and delete" and "Laravel VPS launch with
restore test".

## How it runs

The demo runs on my laptop with Docker Compose. S3 and IAM are the only parts
in AWS, so nothing costs money between demos except S3 storage. The same
Compose kit runs unchanged on a client's EC2 instance or VPS.

Three services:

| Service | What it does |
|---|---|
| `pg` | The main PostgreSQL 17, with pgBackRest installed. Postgres itself pushes every WAL segment to S3 (`archive_command = pgbackrest archive-push`), which is what makes point-in-time recovery possible. |
| `backup` | The cron container. Shares `pg-data` and the socket with `pg` (pgBackRest has to read the data directory). Runs the full, differential and `check` jobs, and alerts on failure. |
| `restore` | A throwaway container, started only on demand (`docker compose run --rm restore`, Compose profile so `up` doesn't start it). It restores from S3 into an **empty** data directory, starts Postgres with `archive_mode=off`, waits for recovery to finish, runs the checks, writes a report and exits. |

Why a single throwaway `restore` container instead of an always-on "backup
database": a restore needs an empty data directory and Postgres stopped, so a
standing second database would fight the restore. And the restored copy must
never archive into the main stanza, or its WAL gets mixed into the main
database's archive. `archive_mode=off` stops that.

`restore.sh` stays as the "rebuild this host" disaster recovery script. The
`restore` service is the "prove it, without touching the main database" path.

## Best practice this kit follows

- **Continuous WAL archiving** to S3 with `archive_timeout=60`, so a quiet
  database still ships WAL and the worst-case data loss is about a minute.
- **Schedule:** full backup every Sunday, differential every other night,
  `pgbackrest check` daily. `repo1-retention-full=2` (count), so pgBackRest
  removes old backups and the WAL they need by itself.
- **No S3 lifecycle rules on live stanza paths.** pgBackRest owns retention
  there; expiring objects underneath it breaks the backup chain. Lifecycle
  rules only touch the `drill/` prefix and old object versions.
- **Encryption:** client-side `aes-256-cbc` plus SSE-S3 on the bucket.
- **Data checksums** on at `initdb` (`--data-checksums`), so pgBackRest checks
  every page during backup.
- **Secrets out of world-readable files:** pgBackRest does not expand `${VAR}`
  in its config, so the passphrase reaches it as the `PGBACKREST_REPO1_CIPHER_PASS`
  environment variable and never sits in a `.conf`. In the backup container the
  cron jobs read a root-only mode-600 env file (`/etc/pgbackrest-job.env`);
  `/etc/cron.d` holds schedules only. Static S3 keys live in the git-ignored
  mode-600 `.env` and a generated mode-600 `configs/s3-keys.env`
  (`repo1-s3-key-type=shared`). Nothing secret is on a command line or in a
  log. On EC2, use an instance profile (`repo1-s3-key-type=auto`) and no keys.
- **No overlapping jobs:** pgBackRest's stanza lock stops two backups running
  at once; a job that finds the lock held logs it and exits non-zero.
- **Failures are loud:** every job goes through `backup/run-job.sh`, which
  exits non-zero on failure, shows its output in `docker logs` ("Full backup:
  started", "finished OK in 4m 12s" or "FAILED after ... (exit code N)"), and
  posts to a webhook (Slack or similar). Each successful backup pings a
  dead-man's switch (Healthchecks.io free tier), and a failure pings `/fail`, so
  a backup that silently stops running also raises an alert. The
  webhook and switch are optional (URLs in `.env`).
- **Readable logs of the backup container:** a startup table of the next
  full, differential and check runs, a `[countdown] Label [HH:MM:SS]` line every
  second (`COUNTDOWN_INTERVAL_SECONDS`, 0 = off), a `[scheduler] next:` line after
  every job, and the per-file `backup file` noise filtered out. Extra
  commands: `status.sh` (next run times) and `countdown.sh --live` (one line
  that redraws in place and stores nothing). Docker rotates the log by size,
  not time: `local` driver, `max-size 37m` (about 3 days at one line a second),
  `max-file 2`, rotated files compressed, so disk use peaks near 38 MiB.
- **Restore safety:** restores go into an empty data directory, `initdb` never
  runs before a restore, nothing wipes data without a prompt or `--yes`,
  PITR uses `--target-action=promote`, and the restored copy runs with
  `archive_mode=off`.
- **A backup counts only once it has restored.** The scenarios below are run
  and reported, not just documented.

## Restore scenarios

Each scenario is one `restore` run plus checks, and each records restore
time, WAL replay time, RPO where it applies, and pass or fail.

**Must-have**

1. **Latest restore (server lost).** `docker kill pg` (a crash, not a clean
   shutdown), restore the latest backup plus all archived WAL. Check
   `pg_is_in_recovery() = false`, row counts against what the source recorded,
   and measure RPO from the newest `canary` row.
2. **Point-in-time recovery (human mistake).** Record time T, run
   `DELETE FROM orders`, restore with `--type=time --target="<T> +00"
   --target-action=promote`. The deleted rows are back.
3. **Integrity checks.** `pgbackrest verify` on the repository, and
   `pg_amcheck --all` (amcheck) on the restored database's indexes and tables.
   Shows the backups aren't silently corrupt.
4. **Failure is caught.** Break the S3 credentials (and, separately, stop
   archiving). The backup or `check` job exits non-zero, the webhook alert
   fires, and the dead-man's switch alerts when the next ping doesn't arrive.

**Extras** (cheap, and good for Upwork)

5. **Named restore point (before a risky migration).**
   `SELECT pg_create_restore_point('pre_migration')`, apply a bad migration,
   restore with `--type=name --target=pre_migration`.
6. **Older backup set (corruption noticed days later).** `--set=<label>` from
   `pgbackrest info` to restore last week's full backup.
7. **Single database.** `--db-include=appdb` when one database is damaged and
   the others must stay as they are. (The other databases come back as empty
   placeholders and have to be dropped; the runbook says so.)
8. **Delta restore (fast repair).** `--delta` onto an existing but damaged
   data directory, which only fetches changed files. Timed against a full
   restore of the same backup.

Sample data for every scenario: pgbench tables, a small `orders` table and a
`canary` table that gets a timestamped row every few seconds while backups
run.

## Objectives

1. **Harden the existing kit.** Default region `ap-southeast-2`. Data
   checksums at `initdb`. Secrets moved from `/etc/cron.d` into a mode-600 env
   file. Postgres bound to `127.0.0.1`; pgAdmin dropped or moved behind a
   Compose profile with a pinned image. `archive-timeout` follows `.env`.
   `restore.sh` asks before it wipes `pg-data` (`--yes` to skip). Image tags
   and the pgBackRest package version pinned. Cron job output in
   `docker logs`, non-zero exits, webhook alert on failure and a dead-man's
   switch ping on success (URLs in `.env`, optional).
2. **AWS side, set up by hand and documented (README "AWS setup").** One S3
   bucket for the pgBackRest repo, made in the console or CLI with: public
   access blocked, bucket-owner-enforced ownership, SSE-S3, versioning with
   noncurrent versions expired after 7 days (a deleted backup can be recovered
   for a week), abort incomplete multipart uploads, and an expiry rule on the
   `drill/` prefix only. An IAM policy scoped to one stanza prefix (the JSON is
   in the README: `s3:ListBucket` on the bucket limited to the
   `pgbackrest/` and `drill/` prefixes, and `GetObject`, `PutObject`,
   `DeleteObject` on those prefixes only; no `DeleteObjectVersion`, so a
   leaked key can't destroy the noncurrent versions), attached to an IAM user for the local demo (its
   access key is kept only in the mode-600 `.env`, and deactivated after
   demos) and usable as an EC2 instance profile policy for a real host. The
   README lists the exact settings so anyone can repeat them; no AWS infrastructure
   code is part of this project.
3. **`restore` service and drill (`drill/`).** The `restore` service in
   Compose, plus `drill/run.sh`, which runs the scenarios end to end on a
   throwaway stanza under `drill/<run-id>/` with a random cipher passphrase
   (seed data, full backup, keep writing, differential, mistake, restores,
   checks), so a demo never touches the real stanza. `drill/run.sh
   --scenario <name>` runs one scenario; no argument runs the must-haves.
4. **Report.** Each run writes a Markdown and JSON report: backup size and
   time, restore time, WAL replay time, RPO, each check pass/fail, pgBackRest
   and Postgres versions, machine size. Exits non-zero if any check fails.
   Sample reports saved in `docs/reports/`.
5. **Checks in CI (`checks.yml`).** `shellcheck`, `hadolint`, `actionlint`,
   and `docker compose config` on every pull request and push. No AWS access needed.
6. **Measured restore time at 10 GB.** One recorded local run with pgbench at
   about scale 680 (≈10 GB): backup time, compressed size in S3, restore time
   and WAL replay time, with the machine and upload/download speed noted.
   Results table in `docs/benchmark.md`.
7. **Client-style README.** Architecture diagram, quick start, the best
   practice list, a runbook per scenario (exact commands), a real report and a
   short terminal log pasted in, the benchmark table, alerting setup,
   monthly cost, and "how to use this on your own database"
   (EC2 instance profile or VPS with a scoped IAM user), and the AWS setup
   steps.

## Stretch

- **Weekly public drill in GitHub Actions (`restore-drill.yml`).** Runs the
  same `drill/run.sh` on a GitHub runner, weekly and on manual dispatch,
  against S3 through an OIDC role (the existing account OIDC provider, role made
  by hand) trusted only for this repo's `master` branch and
  scoped to `drill/*`. Report in the job summary; a failed run opens an issue.
  Gives a public green run to link. MinIO in PR CI is not planned.
- `restore` as a scheduled cron entry in the client's server (monthly restore
  test next to the real database).
- S3 Object Lock, a second repo (`repo2`) or a cross-region copy.
- Pointing the kit at the tic-tac-toe app's database (done in
  joheee/TicTacToeCICD).

## Out of scope

- `pg_dump` logical backups. Project 4/2 cover a nightly `pg_dump`; this
  project is physical backups and PITR. The README can say when `pg_dump` is
  enough (small databases, cross-version moves).
- Replicas, failover, Patroni or high availability. The repo history once had
  a standby; this project is backup and restore only.
- Amazon RDS. RDS has its own snapshots and PITR; this kit is for
  self-managed Postgres on a VM or VPS.
- A long-running server for the demo. Everything runs locally and is torn
  down after.
- A screen recording. As in projects 1 and 4, the saved reports and logs are
  the proof.

## Constraints

- Region `ap-southeast-2` only (org SCP). The SCP also denies
  `ec2:DescribeInstances`; nothing here needs it.
- No DigitalOcean. AWS is used only for S3 and IAM.
- Cost: S3 storage is under $1 a month with retention. Restores download from
  S3 to the laptop; the first 100 GB a month of data out to the internet is
  free, so the small drills and the one-off 10 GB benchmark cost nothing
  extra. Run the 10 GB benchmark once, by hand, under `drill/` so it expires.
- No AWS access keys in the repo or GitHub. The local IAM user's key lives
  only in `.env` (mode 600, git-ignored). The cipher passphrase of a real
  stanza never goes in the repo.

## Progress (updated 2026-11-07)

**Built and tested**
- Kit hardened (objective 1 except the alerting URLs): `ap-southeast-2`
  default, data checksums (verified `on`), localhost-only ports (`pg` on
  `127.0.0.1:5434`, pgAdmin behind the `pgadmin` profile on `127.0.0.1:5435`),
  pinned images (digests) and pgBackRest `2.60.0-1.pgdg12+1`, secrets out of
  cron files, `restore.sh` asks before wiping (`--yes` to skip).
- Found and fixed: the cipher passphrase was never applied (`${...}` is not
  expanded), and empty S3-key variables are an error in pgBackRest.
- `backup/run-job.sh` failure path tested: non-zero exit, `docker logs`
  output, webhook JSON alert and `/fail` ping all fired against a stand-in
  listener. Readable logs and countdown built (see best practice above).
- Real S3: bucket and scoped IAM user created by hand, `stanza-create`, `check`
  and a first full backup (`20261106-183638F`) succeeded.

**Still to do**
- Set real `ALERT_WEBHOOK_URL` and `HEALTHCHECK_URL_*` and see a success ping and
  a failure alert arrive; then tick the alerting box.
- Check that your real bucket's settings match the README "AWS setup" section
  (versioning, SSE-S3, lifecycle on `drill/` and noncurrent only), then tick
  the AWS box. The README is written; `checks.yml` is written and passes locally,
  and needs a first green run on GitHub before its box is ticked.
- Day 2: `restore` service, `drill/run.sh`, must-have scenarios, reports.
- Day 3: extra scenarios, 10 GB benchmark, README rewrite.

## Plan (3 days)

| Day | Work |
|---|---|
| 1 | Harden the kit and add alerting (objective 1). Bucket, IAM policy and user made by hand and written up in the README. `checks.yml` green. |
| 2 | `restore` service and `drill/run.sh` with the four must-have scenarios, checks and report. |
| 3 | Extra scenarios 5–8, 10 GB benchmark and `docs/benchmark.md`. README handover with diagram, runbooks, report and cost. Upwork portfolio entry. |

## Tools and software

PostgreSQL 17 · pgBackRest · Amazon S3 · AWS IAM · Docker + Compose · Bash · pgbench · amcheck
(`pg_amcheck`) · Healthchecks.io (dead-man's switch) · GitHub Actions
(checks) · shellcheck · hadolint · actionlint · Mermaid

## Definition of done

- [x] Kit hardened: `ap-southeast-2` default, data checksums, no secrets in cron files, ports on localhost, `restore.sh` asks before wiping, versions pinned.
- [ ] Backup jobs exit non-zero on failure, log to `docker logs`, alert through a webhook, and ping a dead-man's switch on success.
- [ ] The S3 bucket (encrypted, private, versioned, lifecycle only on `drill/` and old versions) and the stanza-scoped IAM policy and user exist, and the README "AWS setup" section records the exact settings.
- [ ] `checks.yml` runs shellcheck, hadolint, actionlint, and compose config on every PR (green).
- [ ] The `restore` service restores into an empty directory with `archive_mode=off`, runs the checks and writes a Markdown/JSON report.
- [ ] Must-have scenarios pass and are reported: latest restore with RPO, PITR before a `DELETE`, `pgbackrest verify` + `pg_amcheck`, failure alert.
- [ ] Extra scenarios pass and are reported: named restore point, older set, single database, delta restore.
- [ ] `docs/benchmark.md` has measured backup and restore times for a ~10 GB database.
- [ ] No AWS keys or cipher passphrases in the repo or in GitHub.
- [ ] README has the diagram, best practice list, a runbook per scenario, a real report, benchmark, monthly cost and the AWS setup steps.
