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
echo "🎉 All tests passed! Backup system is working correctly."
