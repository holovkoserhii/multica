#!/bin/bash
# Back up Multica state on the GCP VM (run ON the VM, from ~/multica):
#   - the Neon database, via pg_dump (custom format, compressed)
#   - the backend_uploads Docker volume (attachments), as a tar.gz
# deploy.sh calls this automatically before every update.
#
# Backups go to ~/backups; the newest $KEEP of each kind are kept.
# Copy them off the VM now and then — they share its disk:
#   scp -i ~/.ssh/personal 'ubuntu@<ip>:backups/*' ./
#
# Restore the database (overwrites objects that exist in the dump):
#   docker run --rm -i -e DATABASE_URL postgres:17-alpine \
#     sh -c 'pg_restore --clean --if-exists --no-owner -d "$DATABASE_URL"' < ~/backups/db-<stamp>.dump
# Restore uploads:
#   docker run --rm -v multica_backend_uploads:/data -v ~/backups:/b alpine \
#     sh -c 'rm -rf /data/* && tar xzf /b/uploads-<stamp>.tar.gz -C /data'
set -euo pipefail
cd "$(dirname "$0")/../.."

PG_IMAGE=postgres:17-alpine   # must match the Neon server major version (17)
DIR="$HOME/backups"; KEEP="${KEEP:-5}"
STAMP=$(date -u +%Y%m%d-%H%M%S)
mkdir -p "$DIR" && chmod 700 "$DIR"

export DATABASE_URL
DATABASE_URL="$(grep '^DATABASE_URL=' .env | cut -d= -f2-)"
[[ -n "$DATABASE_URL" ]] || { echo "DATABASE_URL missing in .env" >&2; exit 1; }

# Database: write to a temp file first so a failed dump never looks like a backup.
docker run --rm -e DATABASE_URL "$PG_IMAGE" \
  sh -c 'pg_dump --format=custom --no-owner --no-privileges -d "$DATABASE_URL"' > "$DIR/.db-$STAMP.tmp"
docker run --rm -i "$PG_IMAGE" pg_restore --list < "$DIR/.db-$STAMP.tmp" > /dev/null   # sanity check
mv "$DIR/.db-$STAMP.tmp" "$DIR/db-$STAMP.dump"

# Uploads volume (skipped if it does not exist yet).
if docker volume inspect multica_backend_uploads >/dev/null 2>&1; then
  docker run --rm -v multica_backend_uploads:/data:ro -v "$DIR":/b alpine sh -c \
    "tar czf /b/uploads-$STAMP.tar.gz -C /data . && chown $(id -u):$(id -g) /b/uploads-$STAMP.tar.gz"
fi
chmod 600 "$DIR"/*-"$STAMP".* 2>/dev/null || true

# Retention.
for kind in db uploads; do
  ls -1t "$DIR"/$kind-* 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm -f
done

echo "Backup done: $(ls -1 "$DIR"/*-"$STAMP".* | xargs -n1 basename | tr '\n' ' ')"
du -sh "$DIR" | cut -f1 | sed 's/^/Backups total: /'
