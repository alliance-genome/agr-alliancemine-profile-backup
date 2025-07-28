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

# S3 settings (optional)
S3_BUCKET=${S3_BUCKET:-""}
S3_PREFIX=${S3_PREFIX:-""}
S3_REGION=${S3_REGION:-""}
S3_ENDPOINT=${S3_ENDPOINT:-""}

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

# S3 status if configured
if [ -n "$S3_BUCKET" ] && command -v aws &> /dev/null; then
    echo "☁️  S3 BACKUP STATUS:"
    echo "   Bucket: $S3_BUCKET"
    if [ -n "$S3_PREFIX" ]; then
        echo "   Prefix: $S3_PREFIX"
    fi
    
    # Build base S3 path
    local s3_base="s3://$S3_BUCKET"
    if [ -n "$S3_PREFIX" ]; then
        s3_base="$s3_base/$S3_PREFIX"
    fi
    
    # Build AWS CLI command
    local aws_cmd="aws s3 ls"
    if [ -n "$S3_REGION" ]; then
        aws_cmd="$aws_cmd --region $S3_REGION"
    fi
    if [ -n "$S3_ENDPOINT" ]; then
        aws_cmd="$aws_cmd --endpoint-url $S3_ENDPOINT"
    fi
    
    # Count S3 backups
    local s3_daily_count=$(eval "$aws_cmd \"$s3_base/daily/\"" 2>/dev/null | grep -c "postgres_daily_" || echo "0")
    local s3_weekly_count=$(eval "$aws_cmd \"$s3_base/weekly/\"" 2>/dev/null | grep -c "postgres_weekly_" || echo "0")
    
    echo "   Daily backups in S3: $s3_daily_count"
    echo "   Weekly backups in S3: $s3_weekly_count"
    
    # Show latest S3 backup
    local latest_s3=$(eval "$aws_cmd --recursive \"$s3_base/\"" 2>/dev/null | grep "postgres_.*\.sql\.gz" | tail -1)
    if [ -n "$latest_s3" ]; then
        echo "   Latest S3 backup:"
        echo "   $(echo "$latest_s3" | awk '{print "   " $4 " (" $3 " bytes) - " $1 " " $2}')"
    else
        echo "   No S3 backups found"
    fi
    
    echo
elif [ -n "$S3_BUCKET" ]; then
    echo "☁️  S3 CONFIGURED BUT AWS CLI NOT AVAILABLE"
    echo "   Bucket: $S3_BUCKET (AWS CLI not found)"
    echo
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
