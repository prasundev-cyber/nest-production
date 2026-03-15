#!/bin/bash
# scripts/backup.sh — Daily DB backup to MinIO / S3
# Add to crontab: 0 2 * * * /opt/app/scripts/backup.sh >> /var/log/backup.log 2>&1

set -euo pipefail

source /opt/app/.env

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="postgres_${POSTGRES_DB}_${TIMESTAMP}.sql.gz"
RETENTION_DAYS=30

echo "[$(date)] Starting backup..."

# Dump from running container, compress inline
docker exec postgres pg_dump \
  -U "${POSTGRES_USER}" \
  -d "${POSTGRES_DB}" \
  --no-owner \
  --no-acl \
  | gzip -9 > "/tmp/${BACKUP_FILE}"

echo "[$(date)] Dump complete. Uploading..."

# Upload to MinIO
docker run --rm \
  --network internal \
  -v /tmp/${BACKUP_FILE}:/data/${BACKUP_FILE}:ro \
  minio/mc:latest \
  sh -c "
    mc alias set myminio http://minio:9000 \
      ${MINIO_ACCESS_KEY} ${MINIO_SECRET_KEY} && \
    mc mb --ignore-existing myminio/backups && \
    mc cp /data/${BACKUP_FILE} myminio/backups/${BACKUP_FILE}
  "

# Clean local temp
rm -f "/tmp/${BACKUP_FILE}"

# Remove old backups (older than RETENTION_DAYS)
docker run --rm \
  --network internal \
  minio/mc:latest \
  sh -c "
    mc alias set myminio http://minio:9000 \
      ${MINIO_ACCESS_KEY} ${MINIO_SECRET_KEY} && \
    mc rm --recursive --force --older-than ${RETENTION_DAYS}d \
      myminio/backups
  " 2>/dev/null || true

echo "[$(date)] Backup complete: ${BACKUP_FILE}"
