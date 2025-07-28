#!/bin/bash

# Backup Testing Script
# Tests backup creation and restoration to verify system works

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

TEST_DB="backup_test_$(date +%Y%m%d_%H%M%S)"

echo "=== Backup System Test ==="
echo "Test database: $TEST_DB"
echo

# Test 1: Create a daily backup
echo "🧪 Test 1: Creating daily backup..."
if "$SCRIPT_DIR/postgres_backup.sh" daily; then
    echo "✅ Daily backup creation: PASSED"
else
    echo "❌ Daily backup creation: FAILED"
    exit 1
fi

echo

# Test 2: Find the latest backup
echo "🧪 Test 2: Finding latest backup..."
LATEST_BACKUP=$(find "$BACKUP_DATA_DIR/daily" -name "postgres_daily_*.sql.gz" | head -1)
if [ -f "$LATEST_BACKUP" ]; then
    echo "✅ Latest backup found: $(basename "$LATEST_BACKUP")"
else
    echo "❌ No backup found"
    exit 1
fi

echo

# Test 3: Test backup integrity
echo "🧪 Test 3: Testing backup file integrity..."
if gzip -t "$LATEST_BACKUP"; then
    echo "✅ Backup file integrity: PASSED"
else
    echo "❌ Backup file integrity: FAILED"
    exit 1
fi

echo

# Test 4: Test restoration (optional - creates temporary database)
read -p "Test restoration? This will create a temporary database '$TEST_DB' (y/N): " test_restore
if [[ $test_restore == [yY] ]]; then
    echo "🧪 Test 4: Testing backup restoration..."
    
    # Create test database
    if createdb -h "$DB_HOST" -U "$DB_USER" "$TEST_DB" 2>/dev/null; then
        echo "   Test database created: $TEST_DB"
        
        # Restore backup
        if gunzip -c "$LATEST_BACKUP" | pg_restore -h "$DB_HOST" -U "$DB_USER" -d "$TEST_DB" --verbose >/dev/null 2>&1; then
            echo "✅ Backup restoration: PASSED"
            
            # Cleanup test database
            dropdb -h "$DB_HOST" -U "$DB_USER" "$TEST_DB" 2>/dev/null
            echo "   Test database cleaned up"
        else
            echo "❌ Backup restoration: FAILED"
            dropdb -h "$DB_HOST" -U "$DB_USER" "$TEST_DB" 2>/dev/null
            exit 1
        fi
    else
        echo "❌ Could not create test database"
        exit 1
    fi
else
    echo "⏭️  Restoration test skipped"
fi

echo

# Test S3 functionality if configured
if [ -n "$S3_BUCKET" ] && command -v aws &> /dev/null; then
    echo "🧪 Test 5: Testing S3 functionality..."
    
    # Build S3 path for the latest backup
    local s3_base="s3://$S3_BUCKET"
    if [ -n "$S3_PREFIX" ]; then
        s3_base="$s3_base/$S3_PREFIX"
    fi
    local s3_backup_path="$s3_base/daily/$(basename "$LATEST_BACKUP")"
    
    # Build AWS CLI command
    local aws_cmd="aws s3 ls \"$s3_backup_path\""
    if [ -n "$S3_REGION" ]; then
        aws_cmd="$aws_cmd --region $S3_REGION"
    fi
    if [ -n "$S3_ENDPOINT" ]; then
        aws_cmd="$aws_cmd --endpoint-url $S3_ENDPOINT"
    fi
    
    # Check if backup exists in S3
    if eval "$aws_cmd" >/dev/null 2>&1; then
        echo "✅ S3 backup verification: PASSED"
        echo "   Backup found in S3: $(basename "$LATEST_BACKUP")"
        
        # Optional: Test S3 download
        read -p "Test S3 download? This will download the backup to verify it works (y/N): " test_download
        if [[ $test_download == [yY] ]]; then
            local temp_download="/tmp/s3_test_$(basename "$LATEST_BACKUP")"
            
            local download_cmd="aws s3 cp \"$s3_backup_path\" \"$temp_download\""
            if [ -n "$S3_REGION" ]; then
                download_cmd="$download_cmd --region $S3_REGION"
            fi
            if [ -n "$S3_ENDPOINT" ]; then
                download_cmd="$download_cmd --endpoint-url $S3_ENDPOINT"
            fi
            
            if eval "$download_cmd" >/dev/null 2>&1; then
                echo "✅ S3 download test: PASSED"
                rm -f "$temp_download"
            else
                echo "❌ S3 download test: FAILED"
                exit 1
            fi
        else
            echo "⏭️  S3 download test skipped"
        fi
    else
        echo "❌ S3 backup verification: FAILED"
        echo "   Backup not found in S3 or S3 access failed"
        exit 1
    fi
    
    echo
elif [ -n "$S3_BUCKET" ]; then
    echo "⚠️  S3 configured but AWS CLI not available - S3 tests skipped"
    echo
fi

echo "🎉 All tests passed! Backup system is working correctly."
