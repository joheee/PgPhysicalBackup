# Tools
- pgbackrest [https://pgbackrest.org/user-guide.html]

---

# Backup Commands (pg1)

```bash
# Full backup
sudo docker exec -u postgres pgbackrest pgbackrest --stanza=pg1 --type=full backup

# Differential backup (changes since last full)
sudo docker exec -u postgres pgbackrest pgbackrest --stanza=pg1 --type=diff backup

# Incremental backup (changes since last backup of any type)
sudo docker exec -u postgres pgbackrest pgbackrest --stanza=pg1 --type=incr backup

# Backup with annotation
sudo docker exec -u postgres pgbackrest pgbackrest --stanza=pg1 --type=full \
  --annotation=description='pre-migration-snapshot' backup
```

# Listing & Info

```bash
# List all backups for stanza
sudo docker exec -u postgres pgbackrest pgbackrest --stanza=pg1 info

# JSON output (machine-readable)
sudo docker exec -u postgres pgbackrest pgbackrest --stanza=pg1 --output=json info

# Info for a specific backup
sudo docker exec -u postgres pgbackrest pgbackrest --stanza=pg1 --set=20260808-050642F info
```

# Stanza Management

```bash
# Create stanza (required before first backup)
sudo docker exec -u postgres pgbackrest pgbackrest --stanza=pg1 --log-level-console=info stanza-create

# Check config + archiving (forces pg_switch_wal)
sudo docker exec -u postgres pgbackrest pgbackrest --stanza=pg1 check

# Upgrade stanza after PostgreSQL major version upgrade
sudo docker exec -u postgres pgbackrest pgbackrest --stanza=pg1 stanza-upgrade

# Delete stanza (stop cluster first, or --force)
sudo docker exec -u postgres pgbackrest pgbackrest --stanza=pg1 --repo=1 stanza-delete
```

# Restore pg1 Backup → pg2

```bash
# 1. Stop pg2
sudo docker stop pg2

# 2. Delta restore (latest backup; auto-resolves full/diff/incr chain)
sudo docker exec -u postgres pgbackrest pgbackrest \
  --stanza=pg1 \
  --pg1-path=/var/lib/postgresql/pg2-data \
  --type=immediate \
  --target-action=promote \
  --delta \
  restore

# 3. Fix pg1-path in auto.conf (backup container path ≠ pg2 container path)
sudo docker exec pgbackrest sed -i \
  's|--pg1-path=/var/lib/postgresql/pg2-data|--pg1-path=/var/lib/postgresql/data|g' \
  /var/lib/postgresql/pg2-data/postgresql.auto.conf

# 4. Start pg2
sudo docker start pg2
```

## Restore Variants

```bash
# Restore a specific backup set
sudo docker exec -u postgres pgbackrest pgbackrest \
  --stanza=pg1 --pg1-path=/var/lib/postgresql/pg2-data \
  --set=20260808-050642F --type=immediate --target-action=promote restore

# Restore without recovery (default: replays all available WAL)
sudo docker exec -u postgres pgbackrest pgbackrest \
  --stanza=pg1 --pg1-path=/var/lib/postgresql/pg2-data restore

# Selective restore (specific databases only; others become sparse/zeroed)
sudo docker exec -u postgres pgbackrest pgbackrest \
  --stanza=pg1 --pg1-path=/var/lib/postgresql/pg2-data \
  --db-include=mydb --type=immediate restore
```

# Point-in-Time Recovery (PITR)

```bash
# 1. Record the exact time from PostgreSQL
sudo docker exec -u postgres pg1 psql -Atc "select current_timestamp"

# 2. Restore to that timestamp
sudo docker exec -u postgres pgbackrest pgbackrest \
  --stanza=pg1 \
  --pg1-path=/var/lib/postgresql/pg2-data \
  --type=time --target="2026-08-08 14:30:00+00" \
  --target-action=promote \
  restore
```

# Maintenance

```bash
# Manual expire (runs automatically after each backup)
sudo docker exec -u postgres pgbackrest pgbackrest --stanza=pg1 expire

# Dry-run expire (see what would be removed)
sudo docker exec -u postgres pgbackrest pgbackrest --stanza=pg1 --dry-run expire

# Expire a specific backup set
sudo docker exec -u postgres pgbackrest pgbackrest --stanza=pg1 --set=20260807-200247F expire

# Modify backup annotations
sudo docker exec -u postgres pgbackrest pgbackrest --stanza=pg1 \
  --set=20260808-050642F --annotation=status=verified annotate

# Remove an annotation (empty value)
sudo docker exec -u postgres pgbackrest pgbackrest --stanza=pg1 \
  --set=20260808-050642F --annotation=status= annotate
```

# Retention (configured in backup/pgbackrest-conf/pgbackrest.conf)

```ini
repo1-retention-full=2            # Keep 2 full backups (count-based)
repo1-retention-full-type=count   # "count" (default) or "time"
repo1-retention-diff=4            # Differentials to retain per full backup
```