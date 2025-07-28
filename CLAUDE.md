# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## System Overview

This is a PostgreSQL backup system built with Bash scripts that provides automated database backups with retention management, integrity verification, and restoration capabilities. The system supports both daily and weekly backup schedules with configurable retention policies, and can optionally upload backups to Amazon S3 or S3-compatible storage.

## Architecture

The system is organized into distinct functional layers:

- **Configuration Layer**: `config/backup_config.env` centralizes all database connection, retention, and S3 settings
- **Core Scripts**: `scripts/` directory contains all executable functionality
- **Storage Layer**: `backups/` directory with separate subdirectories for daily/weekly backups and logs
- **S3 Integration**: Optional cloud storage with automatic upload, retention management, and download capabilities
- **Authentication**: Uses PostgreSQL's `.pgpass` file for secure password-less connections and AWS CLI for S3 access

Key design patterns:
- All scripts source the same configuration file for consistency
- Comprehensive logging with colored output and log file persistence
- Error handling with cleanup on script interruption or failure
- Modular functions for testing, validation, and monitoring

## Common Commands

### Primary Operations
- `scripts/postgres_backup.sh daily` - Create daily backup (7 day retention)
- `scripts/postgres_backup.sh weekly` - Create weekly backup (90 day retention)
- `scripts/postgres_restore.sh <backup_file>` - Restore from backup file
- `scripts/backup_status.sh` - Display comprehensive system status

### Setup and Testing
- `scripts/setup_pgpass.sh` - Configure secure authentication
- `scripts/test_backup.sh` - Run full system test including optional restoration test

### Configuration
- Edit `config/backup_config.env` to set database connection details and retention policies
- Required variables: `DB_HOST`, `DB_NAME`, `DB_USER`
- Optional variables: `DAILY_RETENTION_DAYS`, `WEEKLY_RETENTION_DAYS`, `BACKUP_COMPRESSION_LEVEL`
- S3 variables (optional): `S3_BUCKET`, `S3_PREFIX`, `S3_STORAGE_CLASS`, `S3_REGION`, `S3_ENDPOINT`, `KEEP_LOCAL_BACKUPS`

### Secure S3 Configuration
For security, avoid storing S3 bucket details in the repository:
- **Option 1**: Use environment variables: `export S3_BUCKET="your-bucket"` 
- **Option 2**: Create `.env.local` file with S3 settings (automatically sourced, ignored by git)

### S3 Integration
When `S3_BUCKET` is configured, the system will:
- Upload backups to S3 after successful local creation and verification
- Apply retention policies to both local and S3 backups
- Support restoration from S3 backups using `s3://filename` syntax
- Show S3 backup status in monitoring output
- Optionally remove local backups after successful S3 upload (if `KEEP_LOCAL_BACKUPS=false`)

## Key System Behaviors

### Backup Process Flow
1. **Validation**: Input parameters, configuration completeness, system dependencies (including AWS CLI if S3 enabled)
2. **Pre-backup**: Database connectivity test, directory creation, disk space check
3. **Backup Creation**: pg_dump with custom format, gzip compression, integrity verification
4. **S3 Upload**: Upload to S3 if configured, with size verification and optional local file removal
5. **Post-backup**: Local and S3 retention cleanup, report generation, optional notifications

### File Naming Convention
- Daily: `postgres_daily_YYYYMMDD_HHMMSS.sql.gz`
- Weekly: `postgres_weekly_YYYYMMDD_HHMMSS.sql.gz`

### Error Handling
- All scripts use `set -e` for immediate exit on errors
- Trap handlers for cleanup on script interruption
- Comprehensive error messages with suggested remediation steps
- Temporary file cleanup on failure

### Notification Support
The backup script supports optional notifications via:
- Slack webhooks (configure `SLACK_WEBHOOK_URL`)
- Email (configure `EMAIL_RECIPIENT`, requires `mail` command)

## Security Considerations

- Uses `.pgpass` file instead of environment variables for database passwords
- All backup files created with appropriate permissions
- No sensitive information logged or displayed in output
- Connection timeouts prevent hanging connections

## Testing Strategy

The `test_backup.sh` script provides comprehensive system testing:
1. Creates actual backup using main script
2. Verifies backup file integrity (gzip and pg_restore validation)
3. Optional restoration test using temporary database
4. S3 functionality validation (if configured) - checks upload and optional download test
5. Automatic cleanup of test resources

Run tests before deploying to production or after configuration changes.

## S3 Requirements

For S3 functionality:
- AWS CLI must be installed and configured with appropriate credentials
- S3 bucket must exist and be accessible
- Required permissions: `s3:PutObject`, `s3:GetObject`, `s3:ListBucket`, `s3:DeleteObject`
- For restoration from S3: use `scripts/postgres_restore.sh s3://backup_filename.sql.gz`