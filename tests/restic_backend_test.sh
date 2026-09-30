#!/bin/bash
# End-to-end check of BACKUP_BACKEND=restic: a throwaway PostgreSQL cluster
# (initdb in a temp dir, unix socket only) and a throwaway local restic
# repository. Needs initdb/pg_ctl/pg_dump/pg_restore and restic >= 0.17 on
# PATH; skips otherwise. Touches no existing database or repository.
#
# Usage: tests/restic_backend_test.sh

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The shipped config must not clobber BACKUP_BACKEND set in the environment
# (e.g. `BACKUP_BACKEND=restic scripts/postgres_backup.sh daily`).
# shellcheck disable=SC2016  # $1 is expanded by the inner bash
backend="$(BACKUP_BACKEND=restic bash -c "source \"\$1\"; echo \"\$BACKUP_BACKEND\"" _ "$REPO_DIR/config/backup_config.env")"
[ "$backend" = "restic" ] || { echo "FAIL: config/backup_config.env overrides BACKUP_BACKEND from the environment (got $backend)"; exit 1; }
backend="$(env -u BACKUP_BACKEND bash -c "source \"\$1\"; echo \"\$BACKUP_BACKEND\"" _ "$REPO_DIR/config/backup_config.env")"
[ "$backend" = "file" ] || { echo "FAIL: default BACKUP_BACKEND should be file (got $backend)"; exit 1; }

for cmd in initdb pg_ctl createdb psql pg_dump pg_restore pg_isready restic; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "SKIP: $cmd not found"
        exit 0
    fi
done

WORK="$(mktemp -d)"
PGDATA_DIR="$WORK/pgdata"
SOCK_DIR="$WORK/sock"
PORT="${TEST_PGPORT:-55440}"
mkdir -p "$SOCK_DIR"

cleanup() {
    pg_ctl -D "$PGDATA_DIR" -m immediate stop >/dev/null 2>&1 || true
    rm -rf "$WORK"
}
trap cleanup EXIT

fail() { echo "FAIL: $*"; exit 1; }

initdb -D "$PGDATA_DIR" -U postgres --auth=trust >/dev/null
pg_ctl -D "$PGDATA_DIR" -l "$WORK/pg.log" -w \
    -o "-p $PORT -k $SOCK_DIR -c listen_addresses=''" start >/dev/null

export PGPORT="$PORT"
createdb -h "$SOCK_DIR" -U postgres backup_test
psql -q -h "$SOCK_DIR" -U postgres -d backup_test \
    -c "CREATE TABLE t (id int primary key, v text); INSERT INTO t SELECT g, md5(g::text) FROM generate_series(1, 1000) g;"

export RESTIC_REPOSITORY="$WORK/restic-repo"
export RESTIC_PASSWORD_FILE="$WORK/restic-pass"
head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$RESTIC_PASSWORD_FILE"
restic init >/dev/null

SYS="$WORK/system"
mkdir -p "$SYS/config" "$SYS/backups/logs"
cp -R "$REPO_DIR/scripts" "$SYS/scripts"
cat > "$SYS/config/backup_config.env" <<CONF
export DB_HOST="$SOCK_DIR"
export DB_NAME=backup_test
export DB_USER=postgres
export DAILY_RETENTION_DAYS=7
export WEEKLY_RETENTION_DAYS=90
export CONNECTION_TIMEOUT=5
export BACKUP_BACKEND=restic
CONF

snapshot_count() {
    restic snapshots --tag "postgres,$1,db:backup_test" --json | grep -o '"short_id"' | wc -l | tr -d ' '
}

echo "== seed an old daily snapshot (outside the 7 day window)"
echo "old" | restic backup --stdin --stdin-filename postgres_backup_test.dump \
    --tag "postgres,daily,db:backup_test" --time "2020-01-01 00:00:00" >/dev/null
[ "$(snapshot_count daily)" = "1" ] || fail "seed snapshot missing"

echo "== daily backup"
bash "$SYS/scripts/postgres_backup.sh" daily > "$WORK/backup.out" 2>&1 \
    || { cat "$WORK/backup.out"; fail "postgres_backup.sh daily exited non-zero"; }
grep -q "Backup integrity verification passed" "$WORK/backup.out" || fail "snapshot was not verified"
[ "$(snapshot_count daily)" = "1" ] || fail "expected old snapshot forgotten and 1 daily snapshot left, got $(snapshot_count daily)"
find "$SYS/backups" -name '*.sql.gz' | grep -q . && fail "restic backend must not write local dump files"

echo "== weekly backup keeps daily snapshots"
bash "$SYS/scripts/postgres_backup.sh" weekly > "$WORK/weekly.out" 2>&1 \
    || { cat "$WORK/weekly.out"; fail "postgres_backup.sh weekly exited non-zero"; }
[ "$(snapshot_count weekly)" = "1" ] || fail "expected 1 weekly snapshot"
[ "$(snapshot_count daily)" = "1" ] || fail "weekly run removed daily snapshots"

echo "== restore restic:latest into a new database"
createdb -h "$SOCK_DIR" -U postgres restore_latest
echo y | bash "$SYS/scripts/postgres_restore.sh" restic:latest restore_latest > "$WORK/restore.out" 2>&1 \
    || { cat "$WORK/restore.out"; fail "restore from restic:latest failed"; }
rows="$(psql -At -h "$SOCK_DIR" -U postgres -d restore_latest -c 'SELECT count(*) FROM t')"
[ "$rows" = "1000" ] || fail "expected 1000 restored rows, got $rows"

echo "== restore an explicit snapshot id"
snap_id="$(restic snapshots --tag "postgres,daily,db:backup_test" --json | grep -o '"short_id":"[0-9a-f]*"' | head -1 | cut -d'"' -f4)"
[ -n "$snap_id" ] || fail "could not read daily snapshot id"
createdb -h "$SOCK_DIR" -U postgres restore_by_id
echo y | bash "$SYS/scripts/postgres_restore.sh" "restic:$snap_id" restore_by_id > "$WORK/restore_id.out" 2>&1 \
    || { cat "$WORK/restore_id.out"; fail "restore from restic:$snap_id failed"; }
rows="$(psql -At -h "$SOCK_DIR" -U postgres -d restore_by_id -c 'SELECT count(*) FROM t')"
[ "$rows" = "1000" ] || fail "expected 1000 rows from snapshot $snap_id, got $rows"

echo "== pg_dump failure fails the run and adds no snapshot"
before="$(snapshot_count daily)"
sed -i.bak 's/DB_NAME=backup_test/DB_NAME=no_such_db/' "$SYS/config/backup_config.env"
# pg_isready succeeds for any db name, so the failure comes from pg_dump inside restic
if bash "$SYS/scripts/postgres_backup.sh" daily > "$WORK/fail.out" 2>&1; then
    fail "backup of a missing database should fail"
fi
grep -q "restic backup failed" "$WORK/fail.out" || fail "pg_dump failure not reported as a restic backup failure"
mv "$SYS/config/backup_config.env.bak" "$SYS/config/backup_config.env"
[ "$(snapshot_count daily)" = "$before" ] || fail "failed pg_dump still created a snapshot"

echo "== misconfiguration is rejected"
if (unset RESTIC_REPOSITORY; bash "$SYS/scripts/postgres_backup.sh" daily > "$WORK/cfg.out" 2>&1); then
    fail "missing RESTIC_REPOSITORY should fail"
fi
grep -q "RESTIC_REPOSITORY not configured" "$WORK/cfg.out" || fail "missing RESTIC_REPOSITORY not reported"

echo "PASS"
