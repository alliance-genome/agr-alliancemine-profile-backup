#!/bin/bash

# PostgreSQL Automated Backup System - Main Script
# Usage: ./postgres_backup.sh [daily|weekly]
# This script is part of an organized backup system

set -e  # Exit on any error

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
    echo "Please run the setup script first or create the configuration file."
    exit 1
fi

# Script variables
BACKUP_TYPE=${1:-daily}
DATE=$(date +%Y%m%d_%H%M%S)
LOG_FILE="$BACKUP_DATA_DIR/logs/backup.log"

# Retention settings (can be overridden in config)
DAILY_RETENTION_DAYS=${DAILY_RETENTION_DAYS:-7}
WEEKLY_RETENTION_DAYS=${WEEKLY_RETENTION_DAYS:-90}
BACKUP_COMPRESSION_LEVEL=${BACKUP_COMPRESSION_LEVEL:-9}
CONNECTION_TIMEOUT=${CONNECTION_TIMEOUT:-10}

# S3 settings (optional)
S3_BUCKET=${S3_BUCKET:-""}
S3_PREFIX=${S3_PREFIX:-""}
S3_STORAGE_CLASS=${S3_STORAGE_CLASS:-"STANDARD"}
S3_REGION=${S3_REGION:-""}
S3_ENDPOINT=${S3_ENDPOINT:-""}
KEEP_LOCAL_BACKUPS=${KEEP_LOCAL_BACKUPS:-"true"}

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"
}

error() {
    echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR:${NC} $1" | tee -a "$LOG_FILE"
}

warning() {
    echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] WARNING:${NC} $1" | tee -a "$LOG_FILE"
}

info() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')] INFO:${NC} $1" | tee -a "$LOG_FILE"
}

# System information
show_system_info() {
    log "=== SYSTEM INFORMATION ==="
    info "Backup System Directory: $BACKUP_SYSTEM_DIR"
    info "Backup Type: $BACKUP_TYPE"
    info "Target Database: $DB_NAME on $DB_HOST"
    info "Retention Policy: Daily($DAILY_RETENTION_DAYS days), Weekly($WEEKLY_RETENTION_DAYS days)"
    info "Compression Level: $BACKUP_COMPRESSION_LEVEL"
    log "=========================="
}

# Validate input parameters
validate_input() {
    if [[ "$BACKUP_TYPE" != "daily" && "$BACKUP_TYPE" != "weekly" ]]; then
        error "Invalid backup type: $BACKUP_TYPE"
        echo "Usage: $0 [daily|weekly]"
        echo ""
        echo "Examples:"
        echo "  $0 daily   # Create daily backup"
        echo "  $0 weekly  # Create weekly backup"
        exit 1
    fi
}

# Check required configuration
validate_configuration() {
    local missing_config=false
    
    if [ -z "$DB_HOST" ]; then
        error "DB_HOST not configured"
        missing_config=true
    fi
    
    if [ -z "$DB_NAME" ]; then
        error "DB_NAME not configured"
        missing_config=true
    fi
    
    if [ -z "$DB_USER" ]; then
        error "DB_USER not configured"
        missing_config=true
    fi
    
    if [ "$missing_config" = true ]; then
        error "Missing required configuration. Please check $CONFIG_DIR/backup_config.env"
        exit 1
    fi
    
    log "Configuration validation passed"
}

# Check system dependencies
check_dependencies() {
    log "Checking system dependencies..."
    
    local missing_deps=false
    
    if ! command -v pg_dump &> /dev/null; then
        error "pg_dump not found. Please install PostgreSQL client tools."
        missing_deps=true
    fi
    
    if ! command -v pg_isready &> /dev/null; then
        error "pg_isready not found. Please install PostgreSQL client tools."
        missing_deps=true
    fi
    
    if ! command -v gzip &> /dev/null; then
        error "gzip not found."
        missing_deps=true
    fi
    
    # Check AWS CLI if S3 is configured
    if [ -n "$S3_BUCKET" ]; then
        if ! command -v aws &> /dev/null; then
            error "AWS CLI not found but S3_BUCKET is configured. Please install AWS CLI."
            missing_deps=true
        else
            info "AWS CLI found - S3 uploads enabled"
        fi
    fi
    
    if [ "$missing_deps" = true ]; then
        error "Missing required dependencies. Please install them and try again."
        exit 1
    fi
    
    log "All dependencies satisfied"
}

# Test database connection
test_connection() {
    log "Testing database connection..."
    
    info "Connecting to $DB_HOST as $DB_USER..."
    
    if pg_isready -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" -t "$CONNECTION_TIMEOUT"; then
        log "Database connection successful"
        
        # Get database size for planning
        local db_size=$(psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" -t -c "SELECT pg_size_pretty(pg_database_size('$DB_NAME'))" 2>/dev/null || echo "Unknown")
        info "Database size: $db_size"
    else
        error "Cannot connect to database. Please check:"
        error "  1. Database host and credentials in $CONFIG_DIR/backup_config.env"
        error "  2. Network connectivity to $DB_HOST"
        error "  3. PostgreSQL authentication (consider using ~/.pgpass)"
        exit 1
    fi
}

# Create backup directory if needed
ensure_directories() {
    local backup_dir="$BACKUP_DATA_DIR/$BACKUP_TYPE"
    
    if [ ! -d "$backup_dir" ]; then
        log "Creating backup directory: $backup_dir"
        mkdir -p "$backup_dir"
    fi
    
    if [ ! -d "$BACKUP_DATA_DIR/logs" ]; then
        mkdir -p "$BACKUP_DATA_DIR/logs"
    fi
}

# Create the actual backup
create_backup() {
    local backup_dir="$BACKUP_DATA_DIR/$BACKUP_TYPE"
    local backup_filename="postgres_${BACKUP_TYPE}_${DATE}.sql.gz"
    local backup_path="$backup_dir/$backup_filename"
    local temp_backup="/tmp/postgres_backup_${BACKUP_TYPE}_${DATE}.sql"
    
    log "Starting $BACKUP_TYPE backup creation..."
    info "Target file: $backup_filename"
    
    # Check available disk space
    local available_space=$(df "$backup_dir" | tail -1 | awk '{print $4}')
    info "Available disk space: $(echo $available_space | awk '{print int($1/1024/1024)" GB"}')"
    
    # Create backup with error handling
    local start_time=$(date +%s)
    
    if pg_dump -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" \
        --no-password \
        --verbose \
        --format=custom \
        --compress="$BACKUP_COMPRESSION_LEVEL" \
        --file="$temp_backup" 2>> "$LOG_FILE"; then
        
        # Compress the backup
        info "Compressing backup file..."
        if gzip -"$BACKUP_COMPRESSION_LEVEL" "$temp_backup"; then
            mv "${temp_backup}.gz" "$backup_path"
        else
            error "Failed to compress backup file"
            rm -f "$temp_backup" 2>/dev/null
            exit 1
        fi
        
        # Calculate backup time and size
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        local file_size=$(du -h "$backup_path" | cut -f1)
        
        log "Backup completed successfully!"
        info "Backup file: $backup_filename"
        info "File size: $file_size"
        info "Duration: ${duration} seconds"
        
        # Verify backup integrity
        if verify_backup_integrity "$backup_path"; then
            log "Backup integrity verification passed"
        else
            error "Backup integrity verification failed!"
            exit 1
        fi
        
        # Upload to S3 if configured
        if ! upload_to_s3 "$backup_path"; then
            error "S3 upload failed, but local backup is available"
            # Don't exit - local backup is still valid
        fi
        
        # Send notifications if configured
        send_notifications "success" "$backup_filename" "$file_size" "$duration"
        
    else
        error "Backup creation failed!"
        rm -f "$temp_backup" 2>/dev/null
        send_notifications "failure" "$backup_filename" "" ""
        exit 1
    fi
}

# Verify backup file integrity
verify_backup_integrity() {
    local backup_file="$1"
    
    info "Verifying backup integrity..."
    
    # Test gzip integrity
    if ! gzip -t "$backup_file"; then
        error "Backup file is corrupted (gzip test failed)"
        return 1
    fi
    
    # Test PostgreSQL backup format
    if ! pg_restore --list "$backup_file" >/dev/null 2>&1; then
        error "Backup file is corrupted (pg_restore test failed)"
        return 1
    fi
    
    return 0
}

# Upload backup to S3
upload_to_s3() {
    local backup_file="$1"
    local backup_filename="$(basename "$backup_file")"
    
    if [ -z "$S3_BUCKET" ]; then
        info "S3_BUCKET not configured - skipping S3 upload"
        return 0
    fi
    
    log "Uploading backup to S3..."
    info "S3 Bucket: $S3_BUCKET"
    info "File: $backup_filename"
    
    # Build S3 path
    local s3_path="s3://$S3_BUCKET"
    if [ -n "$S3_PREFIX" ]; then
        s3_path="$s3_path/$S3_PREFIX"
    fi
    s3_path="$s3_path/$BACKUP_TYPE/$backup_filename"
    
    info "S3 destination: $s3_path"
    
    # Build AWS CLI command
    local aws_cmd="aws s3 cp \"$backup_file\" \"$s3_path\" --storage-class $S3_STORAGE_CLASS"
    
    # Add region if specified
    if [ -n "$S3_REGION" ]; then
        aws_cmd="$aws_cmd --region $S3_REGION"
    fi
    
    # Add custom endpoint if specified
    if [ -n "$S3_ENDPOINT" ]; then
        aws_cmd="$aws_cmd --endpoint-url $S3_ENDPOINT"
    fi
    
    # Execute upload with progress
    local upload_start_time=$(date +%s)
    
    if eval "$aws_cmd"; then
        local upload_end_time=$(date +%s)
        local upload_duration=$((upload_end_time - upload_start_time))
        
        log "S3 upload completed successfully!"
        info "Upload duration: ${upload_duration} seconds"
        
        # Verify S3 upload
        if verify_s3_upload "$s3_path" "$backup_file"; then
            log "S3 upload verification passed"
            
            # Remove local backup if configured
            if [ "$KEEP_LOCAL_BACKUPS" = "false" ]; then
                info "Removing local backup file (KEEP_LOCAL_BACKUPS=false)..."
                rm -f "$backup_file"
                log "Local backup file removed"
            fi
        else
            error "S3 upload verification failed!"
            return 1
        fi
    else
        error "S3 upload failed!"
        return 1
    fi
}

# Verify S3 upload integrity
verify_s3_upload() {
    local s3_path="$1"
    local local_file="$2"
    
    info "Verifying S3 upload integrity..."
    
    # Get local file size
    local local_size=$(stat -f%z "$local_file" 2>/dev/null || stat -c%s "$local_file" 2>/dev/null)
    
    # Get S3 file size
    local aws_ls_cmd="aws s3 ls \"$s3_path\""
    if [ -n "$S3_REGION" ]; then
        aws_ls_cmd="$aws_ls_cmd --region $S3_REGION"
    fi
    if [ -n "$S3_ENDPOINT" ]; then
        aws_ls_cmd="$aws_ls_cmd --endpoint-url $S3_ENDPOINT"
    fi
    
    local s3_size=$(eval "$aws_ls_cmd" | awk '{print $3}')
    
    if [ -n "$s3_size" ] && [ "$local_size" = "$s3_size" ]; then
        return 0
    else
        error "Size mismatch - Local: $local_size bytes, S3: $s3_size bytes"
        return 1
    fi
}

# Clean old S3 backups based on retention policy
cleanup_s3_backups() {
    if [ -z "$S3_BUCKET" ]; then
        return 0
    fi
    
    log "Starting S3 cleanup process..."
    
    # Build base S3 path
    local s3_base="s3://$S3_BUCKET"
    if [ -n "$S3_PREFIX" ]; then
        s3_base="$s3_base/$S3_PREFIX"
    fi
    
    # Build AWS CLI command base
    local aws_base_cmd="aws s3 ls"
    if [ -n "$S3_REGION" ]; then
        aws_base_cmd="$aws_base_cmd --region $S3_REGION"
    fi
    if [ -n "$S3_ENDPOINT" ]; then
        aws_base_cmd="$aws_base_cmd --endpoint-url $S3_ENDPOINT"
    fi
    
    # Clean daily backups from S3
    local daily_cutoff_date=$(date -d "$DAILY_RETENTION_DAYS days ago" +%Y%m%d 2>/dev/null || date -v-${DAILY_RETENTION_DAYS}d +%Y%m%d 2>/dev/null)
    if [ -n "$daily_cutoff_date" ]; then
        info "Cleaning S3 daily backups older than $daily_cutoff_date..."
        local daily_s3_path="$s3_base/daily/"
        
        # List and filter old daily backups
        eval "$aws_base_cmd \"$daily_s3_path\"" | awk '{if ($4 ~ /postgres_daily_/) print $4}' | while read -r filename; do
            if [[ "$filename" =~ postgres_daily_([0-9]{8})_ ]]; then
                local file_date="${BASH_REMATCH[1]}"
                if [ "$file_date" -lt "$daily_cutoff_date" ]; then
                    info "Removing old S3 daily backup: $filename"
                    local aws_rm_cmd="aws s3 rm \"$daily_s3_path$filename\""
                    if [ -n "$S3_REGION" ]; then
                        aws_rm_cmd="$aws_rm_cmd --region $S3_REGION"
                    fi
                    if [ -n "$S3_ENDPOINT" ]; then
                        aws_rm_cmd="$aws_rm_cmd --endpoint-url $S3_ENDPOINT"
                    fi
                    eval "$aws_rm_cmd"
                fi
            fi
        done
    fi
    
    # Clean weekly backups from S3
    local weekly_cutoff_date=$(date -d "$WEEKLY_RETENTION_DAYS days ago" +%Y%m%d 2>/dev/null || date -v-${WEEKLY_RETENTION_DAYS}d +%Y%m%d 2>/dev/null)
    if [ -n "$weekly_cutoff_date" ]; then
        info "Cleaning S3 weekly backups older than $weekly_cutoff_date..."
        local weekly_s3_path="$s3_base/weekly/"
        
        # List and filter old weekly backups
        eval "$aws_base_cmd \"$weekly_s3_path\"" | awk '{if ($4 ~ /postgres_weekly_/) print $4}' | while read -r filename; do
            if [[ "$filename" =~ postgres_weekly_([0-9]{8})_ ]]; then
                local file_date="${BASH_REMATCH[1]}"
                if [ "$file_date" -lt "$weekly_cutoff_date" ]; then
                    info "Removing old S3 weekly backup: $filename"
                    local aws_rm_cmd="aws s3 rm \"$weekly_s3_path$filename\""
                    if [ -n "$S3_REGION" ]; then
                        aws_rm_cmd="$aws_rm_cmd --region $S3_REGION"
                    fi
                    if [ -n "$S3_ENDPOINT" ]; then
                        aws_rm_cmd="$aws_rm_cmd --endpoint-url $S3_ENDPOINT"
                    fi
                    eval "$aws_rm_cmd"
                fi
            fi
        done
    fi
}

# Clean old backups based on retention policy
cleanup_old_backups() {
    log "Starting cleanup process..."
    
    # Clean daily backups
    local daily_dir="$BACKUP_DATA_DIR/daily"
    if [ -d "$daily_dir" ]; then
        local daily_files=$(find "$daily_dir" -name "postgres_daily_*.sql.gz" -mtime +$DAILY_RETENTION_DAYS 2>/dev/null)
        local daily_count=$(echo "$daily_files" | grep -c . 2>/dev/null || echo 0)
        
        if [ "$daily_count" -gt 0 ]; then
            info "Removing $daily_count daily backup(s) older than $DAILY_RETENTION_DAYS days..."
            echo "$daily_files" | xargs rm -f
            log "Daily backup cleanup completed"
        else
            info "No daily backups require cleanup"
        fi
    fi
    
    # Clean weekly backups
    local weekly_dir="$BACKUP_DATA_DIR/weekly"
    if [ -d "$weekly_dir" ]; then
        local weekly_files=$(find "$weekly_dir" -name "postgres_weekly_*.sql.gz" -mtime +$WEEKLY_RETENTION_DAYS 2>/dev/null)
        local weekly_count=$(echo "$weekly_files" | grep -c . 2>/dev/null || echo 0)
        
        if [ "$weekly_count" -gt 0 ]; then
            info "Removing $weekly_count weekly backup(s) older than $WEEKLY_RETENTION_DAYS days..."
            echo "$weekly_files" | xargs rm -f
            log "Weekly backup cleanup completed"
        else
            info "No weekly backups require cleanup"
        fi
    fi
    
    # Clean old log files (keep last 30 days)
    local old_logs=$(find "$BACKUP_DATA_DIR/logs" -name "*.log" -mtime +30 2>/dev/null)
    if [ -n "$old_logs" ]; then
        info "Cleaning old log files..."
        echo "$old_logs" | xargs rm -f
    fi
}

# Generate backup report
generate_report() {
    log "Generating backup report..."
    
    echo "=== BACKUP REPORT ===" >> "$LOG_FILE"
    echo "Date: $(date)" >> "$LOG_FILE"
    echo "Type: $BACKUP_TYPE" >> "$LOG_FILE"
    echo "System: $BACKUP_SYSTEM_DIR" >> "$LOG_FILE"
    echo "" >> "$LOG_FILE"
    
    # Count and size of backups by type
    for type in daily weekly; do
        local dir="$BACKUP_DATA_DIR/$type"
        if [ -d "$dir" ]; then
            local count=$(find "$dir" -name "postgres_${type}_*.sql.gz" 2>/dev/null | wc -l)
            local total_size=$(du -sh "$dir" 2>/dev/null | cut -f1 || echo "0B")
            echo "$type backups: $count files, $total_size total" >> "$LOG_FILE"
        fi
    done
    
    # Overall system size
    local system_size=$(du -sh "$BACKUP_DATA_DIR" 2>/dev/null | cut -f1 || echo "0B")
    echo "Total backup system size: $system_size" >> "$LOG_FILE"
    echo "" >> "$LOG_FILE"
}

# Send notifications (if configured)
send_notifications() {
    local status="$1"
    local filename="$2"
    local filesize="$3"
    local duration="$4"
    
    local message=""
    if [ "$status" = "success" ]; then
        message="✅ PostgreSQL $BACKUP_TYPE backup completed successfully!\nFile: $filename ($filesize)\nDuration: ${duration}s\nDatabase: $DB_NAME on $DB_HOST"
    else
        message="❌ PostgreSQL $BACKUP_TYPE backup FAILED!\nDatabase: $DB_NAME on $DB_HOST\nCheck logs: $LOG_FILE"
    fi
    
    # Slack notification
    if [ -n "$SLACK_WEBHOOK_URL" ]; then
        curl -X POST -H 'Content-type: application/json' \
            --data "{\"text\":\"$message\"}" \
            "$SLACK_WEBHOOK_URL" 2>/dev/null || true
    fi
    
    # Email notification
    if [ -n "$EMAIL_RECIPIENT" ] && command -v mail &> /dev/null; then
        echo -e "$message" | mail -s "PostgreSQL Backup $status - $BACKUP_TYPE" "$EMAIL_RECIPIENT" 2>/dev/null || true
    fi
}

# Main execution function
main() {
    # Initial setup
    validate_input
    show_system_info
    validate_configuration
    ensure_directories
    
    # Pre-backup checks
    check_dependencies
    test_connection
    
    # Execute backup
    create_backup
    
    # Post-backup tasks
    cleanup_old_backups
    cleanup_s3_backups
    generate_report
    
    log "=== Backup process completed successfully ==="
    
    # Final status summary
    local total_backups=$(find "$BACKUP_DATA_DIR" -name "postgres_*.sql.gz" | wc -l)
    local total_size=$(du -sh "$BACKUP_DATA_DIR" | cut -f1)
    info "Total backups in system: $total_backups files ($total_size)"
    
    return 0
}

# Error handling and cleanup
cleanup_on_exit() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        error "Backup process failed with exit code $exit_code"
        # Cleanup any temporary files
        rm -f /tmp/postgres_backup_${BACKUP_TYPE}_*.sql 2>/dev/null || true
    fi
    exit $exit_code
}

# Set up error handling
trap cleanup_on_exit EXIT
trap 'error "Backup process interrupted"; exit 1' INT TERM

# Help function
show_help() {
    echo "PostgreSQL Automated Backup System"
    echo ""
    echo "Usage: $0 [daily|weekly] [options]"
    echo ""
    echo "Backup Types:"
    echo "  daily   Create daily backup (retained for $DAILY_RETENTION_DAYS days)"
    echo "  weekly  Create weekly backup (retained for $WEEKLY_RETENTION_DAYS days)"
    echo ""
    echo "Options:"
    echo "  -h, --help     Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 daily       # Create daily backup"
    echo "  $0 weekly      # Create weekly backup"
    echo ""
    echo "Configuration:"
    echo "  Config file: $CONFIG_DIR/backup_config.env"
    echo "  Backup storage: $BACKUP_DATA_DIR"
    echo "  Logs: $BACKUP_DATA_DIR/logs/"
    echo ""
    echo "Related Commands:"
    echo "  $(dirname "$0")/backup_status.sh     # Check backup status"
    echo "  $(dirname "$0")/postgres_restore.sh  # Restore from backup"
    echo "  $(dirname "$0")/test_backup.sh       # Test backup system"
}

# Handle command line arguments
case "${1:-}" in
    -h|--help)
        show_help
        exit 0
        ;;
    "")
        # Default to daily if no argument provided
        set -- "daily"
        ;;
esac

# Run if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
