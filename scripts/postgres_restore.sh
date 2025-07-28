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

# Load local configuration overrides if available
if [ -f "$BACKUP_SYSTEM_DIR/.env.local" ]; then
    source "$BACKUP_SYSTEM_DIR/.env.local"
fi

# S3 settings (optional)
S3_BUCKET=${S3_BUCKET:-""}
S3_PREFIX=${S3_PREFIX:-""}
S3_REGION=${S3_REGION:-""}
S3_ENDPOINT=${S3_ENDPOINT:-""}

BACKUP_FILE="$1"
TARGET_DB="${2:-$DB_NAME}"

# List S3 backups
list_s3_backups() {
    if [ -z "$S3_BUCKET" ]; then
        return 0
    fi
    
    # Build base S3 path
    local s3_base="s3://$S3_BUCKET"
    if [ -n "$S3_PREFIX" ]; then
        s3_base="$s3_base/$S3_PREFIX"
    fi
    
    # Build AWS CLI command
    local aws_cmd="aws s3 ls --recursive"
    if [ -n "$S3_REGION" ]; then
        aws_cmd="$aws_cmd --region $S3_REGION"
    fi
    if [ -n "$S3_ENDPOINT" ]; then
        aws_cmd="$aws_cmd --endpoint-url $S3_ENDPOINT"
    fi
    
    # List both daily and weekly backups
    for backup_type in daily weekly; do
        local s3_path="$s3_base/$backup_type/"
        eval "$aws_cmd \"$s3_path\"" 2>/dev/null | grep "postgres_${backup_type}_.*\.sql\.gz" | while read -r line; do
            local date_part=$(echo "$line" | awk '{print $1}')
            local time_part=$(echo "$line" | awk '{print $2}')
            local size=$(echo "$line" | awk '{print $3}' | numfmt --to=iec)
            local filename=$(echo "$line" | awk '{print $4}' | sed "s|.*/||")
            echo "$date_part $time_part - s3://$filename ($size)"
        done
    done | sort -r
}

# Download backup from S3
download_from_s3() {
    local s3_file="$1"
    local local_file="$2"
    
    echo "Downloading from S3: $s3_file"
    
    # Build AWS CLI command
    local aws_cmd="aws s3 cp \"$s3_file\" \"$local_file\""
    if [ -n "$S3_REGION" ]; then
        aws_cmd="$aws_cmd --region $S3_REGION"
    fi
    if [ -n "$S3_ENDPOINT" ]; then
        aws_cmd="$aws_cmd --endpoint-url $S3_ENDPOINT"
    fi
    
    if eval "$aws_cmd"; then
        echo "S3 download completed: $local_file"
        return 0
    else
        echo "Error: Failed to download from S3"
        return 1
    fi
}

if [ -z "$BACKUP_FILE" ]; then
    echo "Usage: $0 <backup_file> [target_database]"
    echo
    echo "Available local backups:"
    echo "======================="
    find "$BACKUP_DATA_DIR" -name "*.sql.gz" -printf "%T@ %p\n" 2>/dev/null | sort -nr | head -20 | while read timestamp path; do
        size=$(du -h "$path" | cut -f1)
        date=$(date -d "@$timestamp" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || date -r "$timestamp" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "Unknown date")
        echo "$date - $(basename "$path") ($size)"
    done
    
    # Show S3 backups if configured
    if [ -n "$S3_BUCKET" ] && command -v aws &> /dev/null; then
        echo
        echo "Available S3 backups (use s3:// prefix):"
        echo "========================================"
        list_s3_backups | head -20
    fi
    exit 1
fi

# Handle S3 files or local paths
TEMP_FILE=""
if [[ "$BACKUP_FILE" == s3://* ]]; then
    # S3 file - need to download first
    if [ -z "$S3_BUCKET" ]; then
        echo "Error: S3 file specified but S3_BUCKET not configured"
        exit 1
    fi
    
    if ! command -v aws &> /dev/null; then
        echo "Error: AWS CLI not found but S3 file specified"
        exit 1
    fi
    
    # Create temp file for download
    TEMP_FILE="/tmp/$(basename "$BACKUP_FILE")_$$"
    
    # Build full S3 path
    local s3_full_path
    if [[ "$BACKUP_FILE" == s3://* ]]; then
        # Remove s3:// prefix and build full path
        local filename=$(echo "$BACKUP_FILE" | sed 's|s3://||')
        s3_full_path="s3://$S3_BUCKET"
        if [ -n "$S3_PREFIX" ]; then
            s3_full_path="$s3_full_path/$S3_PREFIX"
        fi
        
        # Try to find the file in daily or weekly directories
        for backup_type in daily weekly; do
            local test_path="$s3_full_path/$backup_type/$filename"
            if aws s3 ls "$test_path" >/dev/null 2>&1; then
                s3_full_path="$test_path"
                break
            fi
        done
    fi
    
    if ! download_from_s3 "$s3_full_path" "$TEMP_FILE"; then
        exit 1
    fi
    
    BACKUP_FILE="$TEMP_FILE"
elif [[ "$BACKUP_FILE" != /* ]]; then
    # Handle relative paths for local files
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

# Cleanup temp file if downloaded from S3
if [ -n "$TEMP_FILE" ] && [ -f "$TEMP_FILE" ]; then
    echo "Cleaning up temporary file..."
    rm -f "$TEMP_FILE"
fi
