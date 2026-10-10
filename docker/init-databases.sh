#!/usr/bin/env bash
set -euo pipefail

SQLCMD=/opt/mssql-tools18/bin/sqlcmd
SQLSERVER_HOST=sqlserver

database_exists() {
  local database_name="$1"
  "$SQLCMD" \
    -S "$SQLSERVER_HOST" \
    -U sa \
    -P "$MSSQL_SA_PASSWORD" \
    -C \
    -h -1 \
    -W \
    -Q "SET NOCOUNT ON; SELECT COUNT(*) FROM sys.databases WHERE name = N'$database_name';" \
    | tr -d '[:space:]'
}

initialize_database() {
  local database_name="$1"
  local script_path="$2"

  if [[ "$(database_exists "$database_name")" == "1" ]]; then
    echo "$database_name already exists; leaving its data unchanged."
    return
  fi

  echo "Creating $database_name from $script_path ..."
  "$SQLCMD" \
    -S "$SQLSERVER_HOST" \
    -U sa \
    -P "$MSSQL_SA_PASSWORD" \
    -C \
    -b \
    -i "$script_path"
}

initialize_database "MyDatabase" "/seed/init-sqlserver-mydatabase.sql"
initialize_database "SalesDB" "/seed/init-sqlserver-salesdb.sql"

echo "SQL Server databases are ready."
