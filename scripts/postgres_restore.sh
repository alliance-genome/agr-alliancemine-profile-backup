#!/bin/bash

# PostgreSQL Restore Script
# Usage: ./postgres_restore.sh <backup_file> [target_database]

set -e

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

BACKUP_FILE="$1"
TARGET_DB="${2:-$DB_NAME}"

if [ -z "$BACKUP_FILE" ]; then
    echo "Usage: $0 <backup_file> [target_database]"
    echo
    echo "Available backups:"
    echo "=================="
    find "$BACKUP_DATA_DIR" -name "*.sql.gz" -printf "%T@ %p\n" 2>/dev/null | sort -nr | head -20 | while read timestamp path; do
        size=$(du -h "$path" | cut -f1)
        date=$(date -d "@$timestamp" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || date -r "$timestamp" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "Unknown date")
        echo "$date - $(basename "$path") ($size)"
    done
    exit 1
fi

# Handle relative paths
if [[ "$BACKUP_FILE" != /* ]]; then
    # If not absolute path, assume it's in backup directory
    if [ -f "$BACKUP_DATA_DIR/$BACKUP_FILE" ]; then
        BACKUP_FILE="$BACKUP_DATA_DIR/$BACKUP_FILE"
    elif [ -f "$BACKUP_DATA_DIR/daily/$BACKUP_FILE" ]; then
        BACKUP_FILE="$BACKUP_DATA_DIR/daily/$BACKUP_FILE"
    elif [ -f "$BACKUP_DATA_DIR/weekly/$BACKUP_FILE" ]; then
        BACKUP_FILE="$BACKUP_DATA_DIR/weekly/$BACKUP_FILE"
    fi
fi

if [ ! -f "$BACKUP_FILE" ]; then
    echo "Error: Backup file not found: $BACKUP_FILE"
    exit 1
fi

echo "Restoring from: $BACKUP_FILE"
echo "Target database: $TARGET_DB"
echo "Target host: $DB_HOST"

read -p "Continue? (y/N): " confirm
if [[ $confirm != [yY] ]]; then
    echo "Restore cancelled."
    exit 0
fi

echo "Starting restore..."
gunzip -c "$BACKUP_FILE" | pg_restore -h "$DB_HOST" -U "$DB_USER" -d "$TARGET_DB" --verbose --clean --if-exists

echo "Restore completed successfully!"
