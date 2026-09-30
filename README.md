# PostgreSQL Backup System

## Directory Structure
```
postgres-backup-system/
├── scripts/                    # All executable scripts
│   ├── postgres_backup.sh      # Main backup script
│   ├── postgres_restore.sh     # Restoration script  
│   ├── backup_status.sh        # Status monitoring
│   ├── setup_pgpass.sh        # Password configuration
│   └── test_backup.sh         # System testing
├── config/                    # Configuration files
│   └── backup_config.env      # Main configuration
├── backups/                   # Backup data storage
│   ├── daily/                 # Daily backups (7 day retention)
│   ├── weekly/                # Weekly backups (3 month retention)  
│   └── logs/                  # Log files
└── README.md                  # This file
```

## Quick Start
1. Configure: `nano config/backup_config.env`
2. Setup auth: `scripts/setup_pgpass.sh`
3. Test: `scripts/test_backup.sh`
4. Run: `scripts/postgres_backup.sh daily`

## Commands
- `scripts/postgres_backup.sh daily|weekly` - Create backup
- `scripts/backup_status.sh` - Check status
- `scripts/postgres_restore.sh backup_file` - Restore backup
- `scripts/test_backup.sh` - Test system

## Configuration
Edit `config/backup_config.env` with your database details:
- DB_HOST: Your PostgreSQL server hostname
- DB_NAME: Database name to backup
- DB_USER: Database username
- Retention settings for daily/weekly backups

## restic backend (optional)
Set `BACKUP_BACKEND=restic` to stream `pg_dump` straight into a
[restic](https://restic.net) repository (restic >= 0.17) instead of writing
gzipped files under `backups/`. restic encrypts, deduplicates and compresses
the dump; `DAILY_RETENTION_DAYS`/`WEEKLY_RETENTION_DAYS` are applied with
`restic forget --keep-within` + `restic prune`. Configure `RESTIC_REPOSITORY`
and `RESTIC_PASSWORD_FILE` (and `AWS_*` for `s3:` repositories) in
`.env.local` - see `.env.example`.

- Restore: `scripts/postgres_restore.sh restic:latest [target_db]` or `restic:<snapshot-id>`
- List: `restic snapshots --tag postgres`
- Test: `tests/restic_backend_test.sh` (throwaway cluster + local repo)

Run `scripts/setup_pgpass.sh` to configure secure password authentication
instead of storing passwords in environment variables.

## Automation
The system can be automated with cron jobs:
```bash
# Daily backup at 2 AM
0 2 * * * cd /path/to/postgres-backup-system/scripts && ./postgres_backup.sh daily

# Weekly backup on Sunday at 3 AM
0 3 * * 0 cd /path/to/postgres-backup-system/scripts && ./postgres_backup.sh weekly
```

## Monitoring
- Check `scripts/backup_status.sh` for system health
- View logs in `backups/logs/backup.log`
- Test system with `scripts/test_backup.sh`

## Features
- Automatic retention management (7 days daily, 3 months weekly)
- Compressed backups (70-80% size reduction)
- Integrity verification
- Detailed logging
- Optional notifications (Slack/Email)
- Easy restoration
