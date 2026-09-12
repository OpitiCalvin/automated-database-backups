#!/bin/bash

# --- CONFIGURATION---
DB_USER=""
BACKUP_DIR=""
LOG_DIR=""
DAYS_TO_KEEP=120
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG_FILE="$LOG_DIR/backup_${TIMESTAMP}.log"

# Create or ensure backup and log directories exist
mkdir -p "$BACKUP_DIR"
mkdir -p "$LOG_DIR"

# --- LOGGING FUNCTION ---
# This function prints to the terminal AND appends to the log file with a timestamp
log_message() {
    local LOG_LEVEL="$1"
    local MESSAGE="$2"
    local TIME=$(date +"%Y-%m-%d %H:%M:%S")
    echo "[$TIME] [$LOG_LEVEL] $MESSAGE" | tee -a "$LOG_FILE"
}

# --- RESOLVE THE MATCHING CLIENT BINARIES ---
# Deliberately NOT using bare pg_dump/pg_restore/psql: if this host has more
# than one PostgreSQL client version installed, the distro's multi-version
# wrapper (e.g. postgresql-client-common) can resolve them inconsistently -
# pg_dump gets a -h/-p hint to pick the right cluster, but pg_restore -l
# (given only a local file) has no such hint and can land on a different
# version. That produces dumps one version writes that another can't read
# ("unsupported version (x.x) in file header"), failing every validation.
SERVER_VERSION_NUM=$(psql -h localhost -U "$DB_USER" -d postgres -tAc "SHOW server_version_num;")
SERVER_MAJOR=$(( SERVER_VERSION_NUM / 10000 ))

if [ -x "/usr/lib/postgresql/$SERVER_MAJOR/bin/pg_dump" ]; then
    PG_BIN_DIR="/usr/lib/postgresql/$SERVER_MAJOR/bin"
elif [ -x "/usr/pgsql-$SERVER_MAJOR/bin/pg_dump" ]; then
    PG_BIN_DIR="/usr/pgsql-$SERVER_MAJOR/bin"
else
    echo "ERROR: Could not find PostgreSQL $SERVER_MAJOR client binaries (checked /usr/lib/postgresql/$SERVER_MAJOR/bin and /usr/pgsql-$SERVER_MAJOR/bin)." >&2
    exit 1
fi

PG_DUMP="$PG_BIN_DIR/pg_dump"
PG_DUMPALL="$PG_BIN_DIR/pg_dumpall"
PG_RESTORE="$PG_BIN_DIR/pg_restore"
PSQL="$PG_BIN_DIR/psql"

log_message "INFO" "=== Starting Hybrid PostgreSQL Backup Process ==="
log_message "INFO" "Logs are being written to: $LOG_FILE"
log_message "INFO" "pg_dump: $("$PG_DUMP" --version) | pg_restore: $("$PG_RESTORE" --version)"

# 1. Backup Global Objects (Roles, Permissions, Tablespaces)
GLOBAL_FILE="$BACKUP_DIR/globals_$TIMESTAMP.sql.gz"
log_message "INFO" "Backing up global cluster objects..."
"$PG_DUMPALL" -h localhost -U "$DB_USER" --globals-only | gzip > "$GLOBAL_FILE"

if [ ${PIPESTATUS[0]} -eq 0 ]; then
    log_message "INFO" "Global cluster objects backed up successfully."
else
    log_message "ERROR" "Failed to back up global cluster objects."
fi

# 2. Get a list of all user databases (excluding system templates)
log_message "INFO" "Fetching database list..."
DB_LIST=$("$PSQL" -h localhost -U "$DB_USER" -d postgres -t -A -c "SELECT datname FROM pg_database WHERE datistemplate = false AND datallowconn = true;")

# 3. Loop through each database and perform an individual custom-format backup
for DB in $DB_LIST; do
    log_message "INFO" "----------------------------------------"
    log_message "INFO" "Starting backup for database: $DB"
    BACKUP_FILE="$BACKUP_DIR/${DB}_$TIMESTAMP.dump"

    # Using Custom format (-F c) which compresses automatically and allows flexible restores
    "$PG_DUMP" -h localhost -U "$DB_USER" -F c -b -v -f "$BACKUP_FILE" "$DB"

    if [ $? -eq 0 ]; then
        log_message "INFO" "Backup file created for $DB. Running validation check..."

        # --- VALIDATION STEP ---
        # pg_restore -l lists the contents; capture stderr so a failure tells us *why*.
        RESTORE_CHECK_OUTPUT=$("$PG_RESTORE" -l "$BACKUP_FILE" 2>&1 >/dev/null)
        RESTORE_CHECK_STATUS=$?

        if [ $RESTORE_CHECK_STATUS -eq 0 ]; then
            log_message "SUCCESS" "VALIDATION PASSED: $BACKUP_FILE is healthy."
        else
            log_message "CRITICAL" "VALIDATION FAILED: $BACKUP_FILE appears to be corrupted! pg_restore said: $RESTORE_CHECK_OUTPUT"
            # Optional: Rename the bad backup so you know it's broken
            mv "$BACKUP_FILE" "${BACKUP_FILE}.CORRUPT"
        fi
    
    else
        # echo "❌ ERROR: Backup generation failed for database $DB" >&2
        log_message "ERROR" "Backup generation failed for database: $DB"
    fi
done

log_message "INFO" "----------------------------------------"

# 4. Clean up backups older than specified days
log_message "INFO" "Cleaning up database backups older than $DAYS_TO_KEEP days..."
find "$BACKUP_DIR" -type f \( -name "globals_*.sql.gz" -o -name "*.dump" \) -mtime +$DAYS_TO_KEEP -delete

# 5. Clean up old log files (keep logs for 30 days as well)
log_message "INFO" "Cleaning up log files older than $DAYS_TO_KEEP days..."
find "$LOG_DIR" -type f -name "backup_*.log" -mtime +$DAYS_TO_KEEP -delete

log_message "INFO" "=== Backup Process Completed ==="