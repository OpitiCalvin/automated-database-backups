# environment params
DB_USER=""
DB_NAME=""
BACKUP_FILE=""
TABLE_NAME=""
GLOBAL_FILE=""

# 1. Restoring a complete database, overwriting a database entirely with the backup data

# --clean drops existing database objects (tables, views, etc) before recreating them, ensuring no 'duplicate key' errors
# --if-exists prevents the script from throwing annoying errors if it tries to drop a table that doesn't exist yet in the  target database
pg_restore -h localhost -U "$DB_USER" -d "$DB_NAME" --clean --if-exists "$BACKUP_FILE"

# 2. Restoring to a brand new (clean) database

# create the empty database
psql -h localhost -U "$DB_USER" -c "CREATE DATABASE $DB_NAME;"

# Run the restore without --clean flag
pg_restore -h localhost -U "$DB_USER" -d "$DB_NAME" "$BACKUP_FILE"

# 3. High Speed Parallel Restore (for Large Databases)

# use the -j (jobs) flag to speed up the restore process by utilizing multiple CPU cores simultaneously
pg_restore -h localhost -U "$DB_USER" -d "$DB_NAME" -j 4 "$BACKUP_FILE"

# 5. Restoring a Single Specific Table
pg_restore -h localhost -U "$DB_USER" -d "$DB_NAME" -t "$TABLE_NAME" "$BACKUP_FILE"

# IMPORTANT: Restore GLOBAL OBJECTS (if rstoring to a new PostgreSQL Server)
gunzip -c /path/to/backup/directory/globals_20260912_040000.sql.gz | psql -h localhost -U "$DB_USER" -d postgres
