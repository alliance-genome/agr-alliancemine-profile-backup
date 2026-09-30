#!/bin/bash
# Checks how scripts/postgres_backup.sh calls Apprise, using a stub
# `apprise` on PATH that records its arguments. No network, no database.
#
# Usage: tests/notifications_test.sh

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

SYS="$WORK/system"
mkdir -p "$SYS/config" "$SYS/backups/logs" "$WORK/bin"
cp -R "$REPO_DIR/scripts" "$SYS/scripts"
cat > "$SYS/config/backup_config.env" <<'CONF'
export DB_HOST=db.example.org
export DB_NAME=exampledb
export DB_USER=backup
CONF

cat > "$WORK/bin/apprise" <<'STUB'
#!/bin/bash
for a in "$@"; do printf '%s\n' "$a"; done > "$APPRISE_ARGS_FILE"
exit "${APPRISE_STUB_EXIT:-0}"
STUB
chmod +x "$WORK/bin/apprise"

failures=0
check() {
    local name="$1"; shift
    if "$@"; then echo "ok   - $name"; else echo "FAIL - $name"; failures=$((failures + 1)); fi
}

# Runs send_notifications in a subshell with the given env assignments.
# shellcheck disable=SC2016  # single quotes are intentional (inner bash -c)
run_notify() {
    rm -f "$WORK/args" "$WORK/out"
    env -i HOME="$HOME" PATH="$WORK/bin:/usr/bin:/bin" APPRISE_ARGS_FILE="$WORK/args" "$@" \
        bash -c 'args=("$@"); set -- daily; source "$0/scripts/postgres_backup.sh"; send_notifications "${args[@]}"' \
        "$SYS" "${STATUS:-success}" postgres_daily_20250101_000000.sql.gz 12M 42 > "$WORK/out" 2>&1
}

STATUS=success run_notify APPRISE_URLS="json://localhost/a mailto://u:p@example.com"
check "success calls apprise" test -f "$WORK/args"
check "success type" grep -qx -- "success" "$WORK/args"
check "title names backup type" grep -qx -- "PostgreSQL daily backup completed" "$WORK/args"
check "body has file and size" grep -q -- "File: postgres_daily_20250101_000000.sql.gz (12M)" "$WORK/args"
check "both URLs passed as separate args" bash -c "grep -qx 'json://localhost/a' '$WORK/args' && grep -qx 'mailto://u:p@example.com' '$WORK/args'"
check "URLs not written to output" bash -c "! grep -q 'mailto://' '$WORK/out'"

STATUS=failure run_notify SLACK_WEBHOOK_URL="https://hooks.slack.com/services/T000/B000/XXXX"
check "failure type" grep -qx -- "failure" "$WORK/args"
check "legacy SLACK_WEBHOOK_URL forwarded" grep -qx -- "https://hooks.slack.com/services/T000/B000/XXXX" "$WORK/args"

run_notify APPRISE_CONFIG="/etc/apprise.yml"
check "config file passed" bash -c "grep -qx -- '--config' '$WORK/args' && grep -qx '/etc/apprise.yml' '$WORK/args'"

run_notify
check "nothing configured: apprise not called" test ! -f "$WORK/args"

run_notify EMAIL_RECIPIENT="ops@example.com"
check "EMAIL_RECIPIENT warns" grep -q "EMAIL_RECIPIENT is no longer used" "$WORK/out"

run_notify APPRISE_URLS="json://localhost/a" APPRISE_STUB_EXIT=1
check "delivery failure is a warning, not fatal" grep -q "Notification delivery failed" "$WORK/out"

rm -f "$WORK/bin/apprise"
run_notify APPRISE_URLS="json://localhost/a"
check "missing apprise warns" grep -q "apprise is not installed" "$WORK/out"

if [ "$failures" -gt 0 ]; then
    echo "$failures check(s) failed"
    exit 1
fi
echo "PASS"
