# CLAUDE.md

Read `GOALS.md` first. It defines what this repo creates, what is out of scope
and the definition of done. When a choice is unclear, pick the option that makes
the "backups you can prove restore, with measured numbers" story clearer.

## Context

- This repo (joheee/PgPhysicalBackup) is portfolio project #3: physical
  PostgreSQL 17 backups with pgBackRest to Amazon S3, plus a throwaway
  `restore` container that runs the restore scenarios in GOALS.md (latest,
  point-in-time, integrity, failure alerting, extras) and reports pass/fail,
  restore time and RPO. The demo runs locally with Docker Compose.
- The Compose kit (`pg`, `backup` cron container, `start.sh`, `restore.sh`,
  `configs/*.conf.tmpl`) already works. Change it carefully and keep
  `start.sh` and `restore.sh` working the way the README describes.
- Three services: `pg` (Postgres with pgBackRest inside, archives WAL),
  `backup` (cron, shares `pg-data` and the socket) and `restore` (Compose
  profile, run on demand, exits when done). There is no always-on second
  database.
- The drill (`drill/run.sh`) is self-contained: it seeds its own data on a
  throwaway stanza under `drill/<run-id>/` and never touches the real stanza.
  Don't make anything depend on a long-running server, DigitalOcean (paused)
  or project 4's EC2.
- Reuse the Terraform and OIDC patterns from joheee/TicTacToeInfra and
  joheee/AwsEcsFoundationTerraform. The GitHub OIDC provider already exists
  in the account; look it up with a data source, don't create it.
- Region `ap-southeast-2` only (org SCP). The SCP also denies
  `ec2:DescribeInstances`; don't add anything that needs it.

## Layout

- Repo root: the Compose kit (`docker-compose.yml`, `start.sh`, `restore.sh`,
  `.env.example`, `pg/`, `backup/`, `restore/`, `configs/`).
- `terraform/`: S3 bucket for the pgBackRest repo, stanza-scoped IAM policy,
  IAM user for the local demo (access key made by hand, never in state),
  outputs. The GitHub OIDC drill role is a stretch goal. S3 backend with `use_lockfile = true` (state
  bucket made by hand, `backend.hcl.example` committed). Applied locally.
- `drill/`: `run.sh` (all scenarios, or one with `--scenario`), sample
  schema and canary SQL, checks and report template.
- `docs/`: `benchmark.md`, `reports/` (sample reports), runbooks if the
  README gets long.
- `.github/workflows/`: `checks.yml` (lint and validate, no AWS). Optional
  stretch: `restore-drill.yml` (weekly and manual against S3 through OIDC).
  No MinIO.

## Working rules

- Never commit secrets, `.env`, `*.tfstate`, `.terraform/`, generated
  `configs/*.conf`, `pg-data/` or real tfvars. Commit `*.example` files.
- No AWS access keys in the repo or GitHub. Locally, the scoped IAM user's
  key lives only in the git-ignored mode-600 `.env`; on EC2 use an instance
  profile; CI (if added) uses OIDC. The drill uses a random cipher
  passphrase per run. A real stanza's passphrase never enters the repo or
  Actions logs; mask anything sensitive with `::add-mask::`.
- Don't write secrets into world-readable files or command lines (cron
  files, `ps` output, logs).
- Least privilege: scope IAM to the bucket and prefix (`drill/*` for CI, one
  stanza prefix per host). Explain any `"*"` resource in a comment. OIDC
  trust pins this exact repo and the `master` branch (or a PR subject for
  read-only work); never `repo:joheee/*`.
- Tag every AWS resource with `project`, `environment` and
  `managed_by = terraform` through the provider's `default_tags`.
- Pin Terraform (>= 1.10) and provider versions in `versions.tf`; commit
  `.terraform.lock.hcl`. Pin image tags and the pgBackRest package version.
- Restore targets must be empty: never let `initdb` run before a restore,
  and never wipe a data directory without a confirmation or `--yes`. A
  restored copy runs with `archive_mode=off` so it can't write into the
  source stanza; PITR uses `--target-action=promote`.
- Never put S3 lifecycle rules on live stanza paths; pgBackRest retention
  owns them. Lifecycle rules only cover `drill/` and noncurrent versions.
- Backup jobs fail loudly: non-zero exit, output in `docker logs`, webhook
  alert, dead-man's switch ping on success.
- Cost: flag anything that adds standing cost. Drill objects expire through
  the lifecycle rule; the 10 GB benchmark runs once, by hand.
- Run `shellcheck`, `hadolint`, `actionlint`, `docker compose config`,
  `terraform fmt -recursive`, `terraform validate` and `tflint` before every
  commit.
- Never run `terraform apply`/`destroy`, delete a stanza or delete S3
  objects without being asked; show the plan or the exact command first.
- Commits: author `joheee <johevinblesstowi07@gmail.com>`, no Co-Authored-By
  trailer. Ask before committing or pushing.
- Tick the boxes in the GOALS.md "Definition of done" as items are finished.
