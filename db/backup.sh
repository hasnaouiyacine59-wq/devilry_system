#!/bin/bash
# Database backup script

set -e

BACKUP_DIR="/backups"
DATE=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="$BACKUP_DIR/${POSTGRES_DB}_$DATE.sql.gz"
RETENTION_DAYS=7

echo "Starting backup of database: $POSTGRES_DB"

# Create backup
pg_dump -h localhost -U $POSTGRES_USER $POSTGRES_DB | gzip > $BACKUP_FILE

if [ $? -eq 0 ]; then
    echo "Backup created successfully: $BACKUP_FILE"
    
    # Set permissions
    chmod 600 $BACKUP_FILE
    
    # Remove old backups
    find $BACKUP_DIR -name "*.sql.gz" -mtime +$RETENTION_DAYS -delete
    
    echo "Old backups cleaned up (older than $RETENTION_DAYS days)"
else
    echo "Backup failed!"
    exit 1
fi