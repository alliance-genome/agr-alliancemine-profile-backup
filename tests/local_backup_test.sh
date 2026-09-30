#!/bin/bash
# End-to-end check of scripts/postgres_backup.sh against a throwaway
# PostgreSQL cluster (initdb in a temp dir, unix socket only, no TCP).
# Needs initdb/pg_ctl/pg_dump/pg_restore on PATH. Does not touch any
# existing database or the repo's backups/ directory.
#
# Usage: tests/local_backup_test.sh

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

for cmd in initdb pg_ctl createdb psql pg_dump pg_restore pg_isready; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "SKIP: $cmd not found"
        exit 0
    fi
done

WORK="$(mktemp -d)"
PGDATA_DIR="$WORK/pgdata"
SOCK_DIR="$WORK/sock"
PORT="${TEST_PGPORT:-55439}"
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

# Copy the system into a sandbox so config and backups/ are isolated.
SYS="$WORK/system"
mkdir -p "$SYS/config"
cp -R "$REPO_DIR/scripts" "$SYS/scripts"
cat > "$SYS/config/backup_config.env" <<CONF
export DB_HOST="$SOCK_DIR"
export DB_NAME=backup_test
export DB_USER=postgres
export DAILY_RETENTION_DAYS=7
export WEEKLY_RETENTION_DAYS=90
export BACKUP_COMPRESSION_LEVEL=6
export CONNECTION_TIMEOUT=5
CONF

echo "== daily backup"
bash "$SYS/scripts/postgres_backup.sh" daily > "$WORK/backup.out" 2>&1 \
    || { cat "$WORK/backup.out"; fail "postgres_backup.sh daily exited non-zero"; }

backup_file="$(find "$SYS/backups/daily" -name 'postgres_daily_*.sql.gz' | head -1)"
[ -n "$backup_file" ] || fail "no daily backup file created"
gzip -t "$backup_file" || fail "backup is not valid gzip"
gunzip -c "$backup_file" | pg_restore --list >/dev/null || fail "pg_restore cannot read backup"
grep -Eq "integer (expression )?expected" "$WORK/backup.out" && fail "cleanup count is not an integer"

echo "== restore into a new database"
createdb -h "$SOCK_DIR" -U postgres restore_test
echo y | bash "$SYS/scripts/postgres_restore.sh" "$(basename "$backup_file")" restore_test \
    > "$WORK/restore.out" 2>&1 || { cat "$WORK/restore.out"; fail "postgres_restore.sh exited non-zero"; }
rows="$(psql -At -h "$SOCK_DIR" -U postgres -d restore_test -c 'SELECT count(*) FROM t')"
[ "$rows" = "1000" ] || fail "expected 1000 restored rows, got $rows"

echo "PASS"
