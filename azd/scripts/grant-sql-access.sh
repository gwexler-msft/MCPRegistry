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

# Add temporary firewall rule for deployer's IP and force Proxy connection policy
MY_IP=$(curl -s --max-time 10 https://api.ipify.org || true)
FIREWALL_RULE_NAME=""
PROBE_RULE_NAME=""

cleanup_firewall() {
    echo "Restoring connection policy and removing temporary firewall rule(s)..."
    az sql server conn-policy update --server "$AZURE_SQL_SERVER_NAME" --resource-group "$AZURE_RESOURCE_GROUP" --connection-type Default --output none 2>/dev/null || true
    if [ -n "$FIREWALL_RULE_NAME" ]; then
        az sql server firewall-rule delete --resource-group "$AZURE_RESOURCE_GROUP" --server "$AZURE_SQL_SERVER_NAME" --name "$FIREWALL_RULE_NAME" --output none 2>/dev/null || true
    fi
    if [ -n "$PROBE_RULE_NAME" ]; then
        az sql server firewall-rule delete --resource-group "$AZURE_RESOURCE_GROUP" --server "$AZURE_SQL_SERVER_NAME" --name "$PROBE_RULE_NAME" --output none 2>/dev/null || true
    fi
}
trap cleanup_firewall EXIT

if [ -n "$MY_IP" ]; then
    FIREWALL_RULE_NAME="azd-grant-${MY_IP//./-}"
    az sql server firewall-rule create --resource-group "$AZURE_RESOURCE_GROUP" --server "$AZURE_SQL_SERVER_NAME" --name "$FIREWALL_RULE_NAME" --start-ip-address "$MY_IP" --end-ip-address "$MY_IP" --output none 2>/dev/null || true
    az sql server conn-policy update --server "$AZURE_SQL_SERVER_NAME" --resource-group "$AZURE_RESOURCE_GROUP" --connection-type Proxy --output none 2>/dev/null || true
fi

# Probe to detect the IP that SQL actually sees from this client. Outbound
# traffic may egress through a different NAT than api.ipify.org reports
# (e.g., corp VPN routed via Azure). Without this, the firewall rule we just
# added may not match. We catch the sqlcmd error and parse the blocked IP,
# then open a /24 around it (NAT pools commonly span a /24).
if command -v sqlcmd >/dev/null 2>&1; then
    PROBE_OUTPUT=$(sqlcmd -S "$SQL_FQDN" -d master --authentication-method=ActiveDirectoryDefault -Q "SELECT 1" -t 15 2>&1 || true)
    PROBE_IP=$(echo "$PROBE_OUTPUT" | grep -oE "Client with IP address '[^']+'" | grep -oE "[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" | head -n1 || true)

    if [ -n "$PROBE_IP" ] && [ "$PROBE_IP" != "$MY_IP" ]; then
        IFS='.' read -r O1 O2 O3 _ <<< "$PROBE_IP"
        RANGE_START="${O1}.${O2}.${O3}.0"
        RANGE_END="${O1}.${O2}.${O3}.255"
        echo "SQL sees connections from $PROBE_IP (different from $MY_IP); allowing $RANGE_START-$RANGE_END temporarily..."
        PROBE_RULE_NAME="azd-grant-actual-${O1}-${O2}-${O3}"
        az sql server firewall-rule create --resource-group "$AZURE_RESOURCE_GROUP" --server "$AZURE_SQL_SERVER_NAME" --name "$PROBE_RULE_NAME" --start-ip-address "$RANGE_START" --end-ip-address "$RANGE_END" --output none 2>/dev/null || true
        sleep 5
    fi
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
