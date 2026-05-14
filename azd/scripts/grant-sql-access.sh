#!/bin/bash
# Grant the managed identity data-plane access to the SQL database.
# Runs as a postprovision hook after azd provision.
set -euo pipefail

echo "Granting SQL data-plane access to managed identity..."

eval "$(azd env get-values)"

if [ -z "${AZURE_SQL_SERVER_NAME:-}" ] || [ -z "${AZURE_SQL_DATABASE_NAME:-}" ] || [ -z "${AZURE_RESOURCE_GROUP:-}" ] || [ -z "${AZURE_SUBSCRIPTION_ID:-}" ]; then
    echo "ERROR: Missing required azd env values (AZURE_SQL_SERVER_NAME, AZURE_SQL_DATABASE_NAME, AZURE_RESOURCE_GROUP, AZURE_SUBSCRIPTION_ID)."
    exit 1
fi

MANAGED_IDENTITY_DISPLAY_NAME="${AZURE_MANAGED_IDENTITY_NAME:-}"
if [ -z "$MANAGED_IDENTITY_DISPLAY_NAME" ]; then
    echo "ERROR: Missing AZURE_MANAGED_IDENTITY_NAME in azd env. Re-run 'azd provision' after pulling the latest infra outputs."
    exit 1
fi

# Pin az CLI to the same subscription azd is using; the user's default may differ.
az account set --subscription "$AZURE_SUBSCRIPTION_ID" --output none

SQL_FQDN="${AZURE_SQL_SERVER_NAME}.database.windows.net"

echo "SQL Server: $SQL_FQDN"
echo "Database: $AZURE_SQL_DATABASE_NAME"
echo "Identity: $MANAGED_IDENTITY_DISPLAY_NAME"

TOKEN=$(az account get-access-token --resource "https://database.windows.net/" --query accessToken -o tsv)
if [ -z "$TOKEN" ]; then
    echo "ERROR: Failed to get SQL access token."
    exit 1
fi

SQL_CMD="
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = '$MANAGED_IDENTITY_DISPLAY_NAME')
BEGIN
    CREATE USER [$MANAGED_IDENTITY_DISPLAY_NAME] FROM EXTERNAL PROVIDER;
END
ALTER ROLE db_datareader ADD MEMBER [$MANAGED_IDENTITY_DISPLAY_NAME];
ALTER ROLE db_datawriter ADD MEMBER [$MANAGED_IDENTITY_DISPLAY_NAME];
"

sqlcmd -S "$SQL_FQDN" -d "$AZURE_SQL_DATABASE_NAME" --authentication-method=ActiveDirectoryDefault -Q "$SQL_CMD"

echo "SQL data-plane access granted successfully."
