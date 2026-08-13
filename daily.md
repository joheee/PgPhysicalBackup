# Daily Log — 2026-08-13

Reference for the next session. Covers what the repo is, what we debugged, and what's still open.

---

## 1. What this repo is

PostgreSQL physical backup / DR setup using **pgBackRest** with **S3** as the repo, orchestrated by Docker Compose. Two near-identical deployments plus an optional pgAdmin:

| Dir | Role | Stanza | PG host port |
|---|---|---|---|
| `prod/` | **active** primary VM (`ROLE=active`) | `pg-prod` | 5434 |
| `backup/` | **standby** DR VM (`ROLE=standby`) | `pg-backup` | 5433 |
| `pgadmin/` | optional pgAdmin UI | — | 5435 |

The two VMs cross-archive to *different stanzas* in the **same S3 bucket**, so they act as mutual standbys:
- `prod` archives WAL → stanza `pg-prod`
- `backup` archives WAL → stanza `pg-backup`
- each VM's `restore` container pulls the *other* VM's stanza (`REMOTE_STANZA`)

### Per-VM services (`docker-compose.yml`)
| Service | Role | Runs |
|---|---|---|
| `pg` | PostgreSQL 17 + pgBackRest (WAL `archive-push`) | always |
| `backup` | cron: full (Sun 02:07) / diff (Mon–Sat 02:07) / check (07:17) | active VM only |
| `restore` | cron: `sync.sh` delta-restore every 30 min + manual `promote.sh` | standby VM only |

### Flow
1. `start.sh` sources `.env`, `sed`-substitutes `configs/*.conf.tmpl` → real `.conf`, `mkdir`+`chown 999:999` the data dirs, builds images, starts `pg`, then starts `backup` **or** `restore` based on `ROLE`.
2. `backup/entrypoint.sh` writes a cron entry with the correct `--stanza`.
3. `restore/entrypoint.sh` runs `sync.sh` (stop PG → `pgbackrest --delta restore` → start PG in recovery).
4. `promote.sh` = manual failover (`--target-action=promote`), never cron-triggered.
5. Encryption: client-side AES-256-CBC via `PGBACKREST_CIPHER_PASS`; S3 auth via IAM instance profile (`repo1-s3-key-type=auto`).

---

## 2. S3 connectivity (resolved ✅)

**Question asked:** prove the EC2 can reach S3 (role policy `AmazonS3FullAccess`, IAM instance profile).

**Decision:** do NOT install AWS CLI into the pg image. pgBackRest is already the S3 client and is what actually needs S3.

**Simplest tests (no image changes):**
```bash
docker exec -u postgres pg pgbackrest --stanza=pg-backup info          # read proof
docker exec -u postgres pg pgbackrest --stanza=pg-backup stanza-create # write proof
docker exec -u postgres pg pgbackrest repo-ls /pgbackrest              # raw listing (≥2.47)
```
For literal `aws s3 ls`, a throwaway container using the same IAM role via IMDS:
```bash
docker run --rm amazon/aws-cli s3 ls s3://<BUCKET>/pgbackrest/
```

**Result:** S3 access **confirmed working**. The `archive-push` error in the pg log was a `FileMissingError` (missing `archive.info`), *not* an auth/network error — meaning IAM role + endpoint + region + encryption all work. The only missing piece was `stanza-create` (see §5).

---

## 3. pgAdmin `/sessions` write error (resolved ✅)

**Symptom:** pgAdmin couldn't write to `/sessions`.

**Cause:** `dpage/pgadmin4` runs as non-root UID:GID **5050:5050**; the host mount `./pgadmin-data` was created root-owned by Docker.

**Fix:**
```bash
sudo chown -R 5050:5050 ./pgadmin-data
chmod -R 700 ./pgadmin-data     # ownership is what matters; 750 also fine
docker compose restart pgadmin
```
(Matches the pre-approved command in `.claude/settings.local.json`.)

---

## 4. Docker build failure: `groupmod: GID '999' already exists` (resolved ✅)

**Symptom:** `restore` (and `backup`) image build failed at `groupmod -g 999 postgres`.

**Cause:** `docker.io` (restore image) and `cron` (backup image) create their own system groups (`docker` / `crontab`) during install, and Debian hands out GID **999** to the first system group — so GID 999 was already taken when the Dockerfile tried to renumber `postgres` to 999.

**Fix:** add `-o` (non-unique) to both `groupmod` and `usermod`. Applied to 4 files:
- `backup/backup/Dockerfile`
- `backup/restore/Dockerfile`
- `prod/backup/Dockerfile`
- `prod/restore/Dockerfile`

```dockerfile
RUN groupmod -o -g 999 postgres && \
    usermod -o -u 999 postgres && \
    ...
```

**Follow-up head-up:** the `restore` container runs `docker stop/start pg` through the mounted `/var/run/docker.sock`. If that later fails with `permission denied`, the container's group GID must match the **host** `docker` group GID (often 999 on Debian). Not hit yet — revisit only if `sync.sh`/`promote.sh` error.

---

## 5. `archive-push` failing: `archive.info` missing (the key open item)

**Symptom (pg log):**
```
ERROR: [103]: unable to find a valid repository:
  repo1: [FileMissingError] unable to load info file '/pgbackrest/archive/pg-backup/archive.info'
  HINT: has a stanza-create been performed?
```

**Root cause:** `archive.info` is created by `pgbackrest stanza-create`, and **nothing in the repo runs it**. `start.sh`, the entrypoints, and the cron jobs all assume the stanza already exists.

**Immediate fix (manual, once per stanza):**
```bash
# backup VM
docker exec -u postgres pg pgbackrest --stanza=pg-backup stanza-create
docker exec -u postgres pg pgbackrest --stanza=pg-backup info      # verify

# prod VM
docker exec -u postgres pg pgbackrest --stanza=pg-prod stanza-create
docker exec -u postgres pg pgbackrest --stanza=pg-prod info
```
`stanza-create` only needs read access to `pg1-path` + write access to S3 (DB need not be running). Postgres auto-retries `archive-push`; force an immediate flush with:
```bash
docker exec -u postgres pg psql -c "SELECT pg_switch_wal();"
```

**Status:** the backup VM's `stanza-create` was *suggested* but **not yet confirmed run**. The prod VM still needs `pg-prod` stanza-create too.

**Proposed automation (not yet applied):** add idempotent stanza-create to both `start.sh` files:
```bash
docker compose exec -T -u postgres pg pgbackrest --stanza="$MY_STANZA" info >/dev/null 2>&1 \
  || docker compose exec -T -u postgres pg pgbackrest --stanza="$MY_STANZA" stanza-create
```

---

## Open / next steps

- [ ] Run `stanza-create` on the **backup VM** (`pg-backup`) — confirm `info` returns successfully.
- [ ] Run `stanza-create` on the **prod VM** (`pg-prod`).
- [ ] Decide whether to bake idempotent `stanza-create` into `prod/start.sh` + `backup/start.sh`.
- [ ] (only if it bites) docker.sock group-GID matching for the `restore` container's `docker stop/start pg`.
- [ ] Note: `prod/` and `backup/` are full duplicates — DRY/maintenance concern if logic ever diverges.

---

## Files changed today

- `backup/backup/Dockerfile` — `-o` on groupmod/usermod
- `backup/restore/Dockerfile` — `-o` on groupmod/usermod
- `prod/backup/Dockerfile` — `-o` on groupmod/usermod
- `prod/restore/Dockerfile` — `-o` on groupmod/usermod
