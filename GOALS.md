# Project goals: PostgreSQL backups you can prove restore

This repo (joheee/PgPhysicalBackup) is portfolio project #3 for my Upwork
DevOps profile. The point is the **proof**: a client should look at it and
think "this person doesn't just set up backups, they show me every week that
the backup actually restores, how long it takes and how much data I'd lose".

It starts from what this repo already has (built Aug–Sep 2026): PostgreSQL 17
and pgBackRest in Docker Compose, WAL archived continuously to Amazon S3,
scheduled full and differential backups from a cron container, client-side
AES-256 encryption, and `restore.sh` to rebuild a host from the latest backup.
That is the first half. This project adds the half clients actually pay for:
an automated restore drill with checks and a report, the AWS side in
Terraform, CI, and measured numbers.

## The pitch (what a client buys)

> "PostgreSQL backups with a weekly restore test, 2–3 days." Physical backups
> and point-in-time recovery with pgBackRest to S3 (encrypted, with
> retention), plus a scheduled GitHub Actions job that restores the latest
> backup into a throwaway container, runs integrity and row-count checks,
> recovers to a point in time before a simulated mistake, and posts a
> pass/fail report with restore time and data-loss window (RPO). You get the
> runbook and the measured restore time for your database size.

It matches jobs like "Postgres freezes + backups" ($5,000), "Medusa backups
with restore demo", "AWS backup and delete" and "Laravel VPS launch with
restore test".

## Where the database runs

The kit runs on any Linux host with Docker (EC2, a VPS, a laptop). The proof
must not depend on a server staying up, because DigitalOcean (project 2) is
paused and project 4's EC2 costs money while running. So the **restore drill
is self-contained**: each run starts a source database in CI, loads sample
data, backs it up to S3, makes changes, then restores and checks. Nothing runs
between drills; S3 storage is the only standing cost.

Pointing the kit at the tic-tac-toe app's database (joheee/TicTacToeCICD) is a
stretch goal, done in that repo, not a requirement here.

## Objectives

1. **Harden the existing kit.** Default region `ap-southeast-2`. Data
   checksums on at `initdb` (`--data-checksums`) so pgBackRest verifies pages
   during backup. Stop writing the cipher passphrase and AWS keys into the
   world-readable `/etc/cron.d` file (use an env file with mode 600 that the
   cron jobs read). Bind Postgres and pgAdmin to `127.0.0.1` and pin the
   pgAdmin image (or drop pgAdmin). Make `archive-timeout` follow `.env`.
   Make `restore.sh` ask before it wipes `pg-data` (`--yes` to skip). Pin the
   pgBackRest package version. Backup cron failures exit non-zero and are
   visible in `docker logs`.
2. **AWS side in Terraform (`terraform/`).** One S3 bucket for the pgBackRest
   repo: public access blocked, SSE-S3, versioning with noncurrent versions
   expired after 7 days (a deleted backup can be recovered for a week),
   abort incomplete uploads, and a short expiry on the `drill/` prefix.
   An IAM role for GitHub Actions through OIDC (existing account OIDC
   provider, looked up with a data source), trusted only for this repo's
   `master` branch, with read/write on `drill/*` only. An IAM policy for a
   real host (EC2 instance profile) scoped to that host's stanza prefix.
   S3 backend with `use_lockfile = true`, state bucket made by hand, applied
   locally.
3. **Restore drill script (`drill/`).** One script, run the same way locally
   and in CI:
   - Start a source Postgres from this repo's image with a sample schema
     (pgbench tables plus a small `orders`-style table) and a `canary` table
     that gets a timestamped row every few seconds.
   - Create a fresh stanza under `drill/<run-id>/` with a random per-run
     cipher passphrase, take a full backup, keep writing, take a
     differential, then record a timestamp T and run a "mistake"
     (`DELETE FROM orders`).
   - **Latest restore:** restore into a new, empty container, wait for WAL
     replay, promote, then check: `pg_is_in_recovery() = false`, `amcheck` on
     indexes, row counts equal the counts the source recorded after its last
     archived WAL switch, and the newest canary row gives the RPO.
   - **Point-in-time restore:** restore again with `--type=time` to T and
     check the deleted rows are back.
   - Time every step and write a Markdown and JSON report (backup size, backup
     time, restore time, WAL replay time, RPO, each check pass/fail). Exit
     non-zero if any check fails.
4. **Drill in GitHub Actions (`restore-drill.yml`).** On every pull request
   the drill runs against MinIO in the job (no AWS, no secrets). Weekly on a
   schedule and on manual dispatch it runs against the real S3 bucket through
   OIDC. The report goes to the job summary and as an artifact. A failed
   scheduled drill opens (or comments on) a GitHub issue, so the failure
   reaches email; a Slack webhook is optional through a secret.
5. **Checks in CI (`checks.yml`).** `shellcheck`, `hadolint`, `actionlint`,
   `docker compose config`, and `terraform fmt -check`, `validate`, `tflint`
   on every pull request and push.
6. **Measured restore time at 10 GB.** One recorded run with pgbench at
   about scale 680 (≈10 GB): backup time, compressed size in S3, restore time
   and WAL replay time, with the machine size noted (GitHub runner or local).
   Results table in `docs/benchmark.md`.
7. **Client-style README.** Architecture diagram, quick start, disaster
   recovery and PITR runbooks, the drill explained, a real report pasted in,
   links to the green scheduled drill run and the PR run, the benchmark
   table, the outputs table, monthly cost, and "how to use this on your own
   database" (EC2 instance profile or VPS with scoped keys).

## Out of scope

- `pg_dump` logical backups. Project 4/2 cover a nightly `pg_dump`; this
  project is physical backups and PITR. The README can say when `pg_dump` is
  enough (small databases, cross-version moves).
- Replicas, failover, Patroni or high availability. The repo history once had
  a standby; this project is backup and restore only.
- Amazon RDS. RDS has its own snapshots and PITR; this kit is for
  self-managed Postgres on a VM or VPS.
- A long-running source server. The drill builds its own source each run.
- S3 Object Lock, a second repo (`repo2`) or cross-region copies. Possible
  stretch, listed in the README as next steps.
- Running the kit on the tic-tac-toe production database (stretch, done in
  TicTacToeCICD).
- A screen recording. As in projects 1 and 4, the logged drill runs and the
  reports are the proof.

## Constraints

- Region `ap-southeast-2` only (org SCP). The SCP also denies
  `ec2:DescribeInstances`; nothing here needs it.
- No DigitalOcean. AWS is used only for S3 and IAM.
- Cost: S3 storage is under $1 a month with retention. Each scheduled drill
  downloads its own backup from S3 to a GitHub runner (data transfer out,
  about $0.11 per GB in `ap-southeast-2`); the small drill is a few MB, the
  one-off 10 GB benchmark a few GB. Run the 10 GB benchmark once, not on a
  schedule, and expire its objects.
- No AWS access keys anywhere in GitHub; CI uses OIDC. The pgBackRest cipher
  passphrase for a real stanza never goes in the repo.

## Plan (3 days)

| Day | Work |
|---|---|
| 1 | Harden the kit (objective 1). `terraform/` bucket, OIDC drill role and host policy, applied. `checks.yml` green. |
| 2 | `drill/` script with latest and PITR restores, checks and report. `restore-drill.yml` on PRs (MinIO) and weekly against S3, issue on failure. First green scheduled run. |
| 3 | 10 GB benchmark run and `docs/benchmark.md`. README handover with diagram, report, run links and cost. Upwork portfolio entry. |

## Tools and software

PostgreSQL 17 · pgBackRest · Amazon S3 · AWS IAM + GitHub OIDC · Terraform
(>= 1.10) with the AWS provider 6.x · Docker + Compose · MinIO (CI) ·
GitHub Actions (scheduled) · Bash · pgbench · amcheck · shellcheck ·
hadolint · actionlint · tflint · Mermaid

## Definition of done

- [ ] Kit hardened: `ap-southeast-2` default, data checksums, no secrets in cron files, ports on localhost, `restore.sh` asks before wiping, versions pinned.
- [ ] `terraform/` creates the bucket (encrypted, private, versioned, lifecycle rules), the OIDC drill role and the host policy, scoped to prefixes.
- [ ] `checks.yml` runs shellcheck, hadolint, actionlint, compose config, fmt, validate and tflint on every PR (green).
- [ ] The drill restores the latest backup and a point in time, runs the checks and writes a Markdown/JSON report with timings and RPO.
- [ ] The drill runs on every PR against MinIO and weekly against S3 through OIDC; a failed scheduled drill opens an issue.
- [ ] A scheduled drill run against S3 is green and linked from the README.
- [ ] `docs/benchmark.md` has measured backup and restore times for a ~10 GB database.
- [ ] No AWS keys or cipher passphrases in the repo or in GitHub Actions.
- [ ] README has the diagram, runbooks, a real report, run links, benchmark, outputs table and monthly cost.
