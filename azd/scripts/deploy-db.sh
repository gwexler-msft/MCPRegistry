#!/bin/bash
# Deploy the database schema using the dacpac produced by the SQL project.
# Runs as a postprovision hook or standalone.
set -euo pipefail

echo "Deploying database schema via dacpac..."

if [ -z "${1:-}" ] || [ -z "${2:-}" ]; then
    eval "$(azd env get-values)"
    SERVER_NAME="${1:-${AZURE_SQL_SERVER_NAME:-}}"
    DATABASE_NAME="${2:-${AZURE_SQL_DATABASE_NAME:-}}"
else
    SERVER_NAME="$1"
    DATABASE_NAME="$2"
fi

if [ -z "$SERVER_NAME" ] || [ -z "$DATABASE_NAME" ]; then
    echo "ERROR: Missing SQL server or database name."
    exit 1
fi

case "$SERVER_NAME" in
    *.database.windows.net) SQL_FQDN="$SERVER_NAME" ;;
    *) SQL_FQDN="${SERVER_NAME}.database.windows.net" ;;
esac

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DACPAC_PATH="$SCRIPT_DIR/../../src/MCPRegistryDatabase/bin/Release/MCPRegistryDatabase.dacpac"

if [ ! -f "$DACPAC_PATH" ]; then
    echo "Dacpac not found, building..."
    dotnet build "$SCRIPT_DIR/../../src/MCPRegistryDatabase/MCPRegistryDatabase.sqlproj" -c Release
fi

echo "Server: $SQL_FQDN"
echo "Database: $DATABASE_NAME"
echo "Dacpac: $DACPAC_PATH"

TOKEN=$(az account get-access-token --resource "https://database.windows.net/" --query accessToken -o tsv)
if [ -z "$TOKEN" ]; then
    echo "ERROR: Failed to get SQL access token."
    exit 1
fi

sqlpackage /Action:Publish \
    /SourceFile:"$DACPAC_PATH" \
    /TargetServerName:"$SQL_FQDN" \
    /TargetDatabaseName:"$DATABASE_NAME" \
    /AccessToken:"$TOKEN" \
    /p:BlockOnPossibleDataLoss=False

echo "Database schema deployed successfully."
