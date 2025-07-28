#!/bin/bash

# Backup Status and Monitoring Script

# Get script directory and setup paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_SYSTEM_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_DIR="$BACKUP_SYSTEM_DIR/config"
BACKUP_DATA_DIR="$BACKUP_SYSTEM_DIR/backups"

# Load configuration
if [ -f "$CONFIG_DIR/backup_config.env" ]; then
    source "$CONFIG_DIR/backup_config.env"
else
    echo "Error: Configuration file not found at $CONFIG_DIR/backup_config.env"
    exit 1
fi

echo "=== PostgreSQL Backup Status ==="
echo "Date: $(date)"
echo "System Directory: $BACKUP_SYSTEM_DIR"
echo "Backup Directory: $BACKUP_DATA_DIR"
echo

# Check if backup directory exists
if [ ! -d "$BACKUP_DATA_DIR" ]; then
    echo "❌ Backup directory does not exist!"
    exit 1
fi

# Daily backups status
echo "📅 DAILY BACKUPS (Last 7 days):"
daily_count=$(find "$BACKUP_DATA_DIR/daily" -name "postgres_daily_*.sql.gz" -mtime -7 2>/dev/null | wc -l)
echo "   Found: $daily_count backups"

if [ "$daily_count" -gt 0 ]; then
    echo "   Latest:"
    find "$BACKUP_DATA_DIR/daily" -name "postgres_daily_*.sql.gz" -exec ls -lh {} \; | tail -1 | awk '{print "   " $9 " (" $5 ") - " $6 " " $7 " " $8}'
fi

echo

# Weekly backups status
echo "📊 WEEKLY BACKUPS (Last 3 months):"
weekly_count=$(find "$BACKUP_DATA_DIR/weekly" -name "postgres_weekly_*.sql.gz" -mtime -90 2>/dev/null | wc -l)
echo "   Found: $weekly_count backups"

if [ "$weekly_count" -gt 0 ]; then
    echo "   Latest:"
    find "$BACKUP_DATA_DIR/weekly" -name "postgres_weekly_*.sql.gz" -exec ls -lh {} \; | tail -1 | awk '{print "   " $9 " (" $5 ") - " $6 " " $7 " " $8}'
fi

echo

# Disk usage
echo "💾 DISK USAGE:"
echo "   Total backup size: $(du -sh "$BACKUP_DATA_DIR" | cut -f1)"
du -sh "$BACKUP_DATA_DIR"/* 2>/dev/null | sed 's/^/   /' || echo "   No data yet"

echo

# Check last backup status
echo "📋 LAST BACKUP LOG (last 10 lines):"
if [ -f "$BACKUP_DATA_DIR/logs/backup.log" ]; then
    tail -10 "$BACKUP_DATA_DIR/logs/backup.log" | sed 's/^/   /'
else
    echo "   No log file found."
fi

# Health check
echo
echo "🏥 HEALTH CHECK:"

# Check database connectivity
if pg_isready -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" -t 5 >/dev/null 2>&1; then
    echo "   ✅ Database connection: OK"
else
    echo "   ❌ Database connection: FAILED"
fi

# Check recent backup
recent_backup=$(find "$BACKUP_DATA_DIR" -name "postgres_daily_*.sql.gz" -mtime -1 2>/dev/null | wc -l)
if [ "$recent_backup" -gt 0 ]; then
    echo "   ✅ Recent backup (24h): OK"
else
    echo "   ⚠️  Recent backup (24h): MISSING"
fi

echo
