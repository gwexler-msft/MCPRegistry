#!/bin/bash
# Deploy the database schema using the dacpac produced by the SQL project.
# Runs as a postprovision hook or standalone.
# SQL target platform (DSP) reference:
# https://learn.microsoft.com/en-us/sql/tools/sql-database-projects/concepts/target-platform?view=sql-server-ver17&pivots=sq1-command-line
set -euo pipefail

echo "Deploying database schema via dacpac..."

RESOURCE_GROUP=""
SUBSCRIPTION_ID=""
if [ -z "${1:-}" ] || [ -z "${2:-}" ]; then
    eval "$(azd env get-values)"
    SERVER_NAME="${1:-${AZURE_SQL_SERVER_NAME:-}}"
    DATABASE_NAME="${2:-${AZURE_SQL_DATABASE_NAME:-}}"
    TARGET_PLATFORM="${3:-${SQL_TARGET_PLATFORM:-}}"
    RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-}"
    SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID:-}"
else
    SERVER_NAME="$1"
    DATABASE_NAME="$2"
    TARGET_PLATFORM="${3:-${SQL_TARGET_PLATFORM:-}}"
fi

if [ -z "$SERVER_NAME" ] || [ -z "$DATABASE_NAME" ]; then
    echo "ERROR: Missing SQL server or database name."
    exit 1
fi

# Pin az CLI to the same subscription azd is using; the user's default may differ.
if [ -n "$SUBSCRIPTION_ID" ]; then
    az account set --subscription "$SUBSCRIPTION_ID" --output none
fi

if [ -z "$RESOURCE_GROUP" ]; then
    RESOURCE_GROUP=$(az sql server show --name "$SERVER_NAME" --query resourceGroup -o tsv 2>/dev/null || true)
fi

case "$SERVER_NAME" in
    *.database.windows.net) SQL_FQDN="$SERVER_NAME" ;;
    *) SQL_FQDN="${SERVER_NAME}.database.windows.net" ;;
esac

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DACPAC_PATH="$SCRIPT_DIR/../../src/MCPRegistryDatabase/bin/Release/MCPRegistryDatabase.dacpac"

if [ -n "${TARGET_PLATFORM:-}" ]; then
    echo "Using SQL target platform (DSP): $TARGET_PLATFORM"
fi

if [ -z "${TARGET_PLATFORM:-}" ]; then
    TARGET_PLATFORM="Microsoft.Data.Tools.Schema.Sql.SqlAzureV12DatabaseSchemaProvider"
    echo "Defaulting SQL target platform (DSP): $TARGET_PLATFORM"
fi

if [ ! -f "$DACPAC_PATH" ] || [ -n "${TARGET_PLATFORM:-}" ]; then
    if [ -f "$DACPAC_PATH" ] && [ -n "${TARGET_PLATFORM:-}" ]; then
        echo "Target platform override provided, rebuilding dacpac..."
    else
        echo "Dacpac not found, building..."
    fi

    BUILD_ARGS=(-c Release)
    if [ -n "${TARGET_PLATFORM:-}" ]; then
        BUILD_ARGS+=("/p:DSP=$TARGET_PLATFORM")
    fi

    dotnet build "$SCRIPT_DIR/../../src/MCPRegistryDatabase/MCPRegistryDatabase.sqlproj" "${BUILD_ARGS[@]}"
fi

# Add temporary firewall rule for deployer's IP
MY_IP=$(curl -s --max-time 10 https://api.ipify.org || true)
FIREWALL_RULE_NAME=""
PROBE_RULE_NAME=""

cleanup_firewall() {
    if [ -n "$RESOURCE_GROUP" ] && [ -n "$SERVER_NAME" ]; then
        echo "Restoring connection policy and removing temporary firewall rule(s)..."
        az sql server conn-policy update --server "$SERVER_NAME" --resource-group "$RESOURCE_GROUP" --connection-type Default --output none 2>/dev/null || true
        if [ -n "$FIREWALL_RULE_NAME" ]; then
            az sql server firewall-rule delete --resource-group "$RESOURCE_GROUP" --server "$SERVER_NAME" --name "$FIREWALL_RULE_NAME" --output none 2>/dev/null || true
        fi
        if [ -n "$PROBE_RULE_NAME" ]; then
            az sql server firewall-rule delete --resource-group "$RESOURCE_GROUP" --server "$SERVER_NAME" --name "$PROBE_RULE_NAME" --output none 2>/dev/null || true
        fi
    fi
}
trap cleanup_firewall EXIT

if [ -n "$MY_IP" ] && [ -n "$RESOURCE_GROUP" ]; then
    FIREWALL_RULE_NAME="azd-deploy-${MY_IP//./-}"
    echo "Adding temporary firewall rule for $MY_IP..."
    az sql server firewall-rule create --resource-group "$RESOURCE_GROUP" --server "$SERVER_NAME" --name "$FIREWALL_RULE_NAME" --start-ip-address "$MY_IP" --end-ip-address "$MY_IP" --output none 2>/dev/null || true
    az sql server conn-policy update --server "$SERVER_NAME" --resource-group "$RESOURCE_GROUP" --connection-type Proxy --output none 2>/dev/null || true
fi

echo "Server: $SQL_FQDN"
echo "Database: $DATABASE_NAME"
echo "Dacpac: $DACPAC_PATH"

TOKEN=$(az account get-access-token --resource "https://database.windows.net/" --query accessToken -o tsv)
if [ -z "$TOKEN" ]; then
    echo "ERROR: Failed to get SQL access token."
    exit 1
fi

# Probe to detect the IP that SQL actually sees from this client. Outbound
# traffic may egress through a different NAT than api.ipify.org reports
# (e.g., corp VPN routed via Azure). Without this, the firewall rule we just
# added may not match. We catch the sqlcmd error and parse the blocked IP,
# then open a /24 around it (NAT pools commonly span a /24).
if [ -n "$RESOURCE_GROUP" ] && command -v sqlcmd >/dev/null 2>&1; then
    PROBE_OUTPUT=$(sqlcmd -S "$SQL_FQDN" -d master --authentication-method=ActiveDirectoryDefault -Q "SELECT 1" -t 15 2>&1 || true)
    PROBE_IP=$(echo "$PROBE_OUTPUT" | grep -oE "Client with IP address '[^']+'" | grep -oE "[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" | head -n1 || true)

    if [ -n "$PROBE_IP" ] && [ "$PROBE_IP" != "$MY_IP" ]; then
        IFS='.' read -r O1 O2 O3 _ <<< "$PROBE_IP"
        RANGE_START="${O1}.${O2}.${O3}.0"
        RANGE_END="${O1}.${O2}.${O3}.255"
        echo "SQL sees connections from $PROBE_IP (different from $MY_IP); allowing $RANGE_START-$RANGE_END temporarily..."
        PROBE_RULE_NAME="azd-deploy-actual-${O1}-${O2}-${O3}"
        az sql server firewall-rule create --resource-group "$RESOURCE_GROUP" --server "$SERVER_NAME" --name "$PROBE_RULE_NAME" --start-ip-address "$RANGE_START" --end-ip-address "$RANGE_END" --output none 2>/dev/null || true
        sleep 5
    fi
fi

sqlpackage /Action:Publish \
    /SourceFile:"$DACPAC_PATH" \
    /TargetServerName:"$SQL_FQDN" \
    /TargetDatabaseName:"$DATABASE_NAME" \
    /AccessToken:"$TOKEN" \
    /p:BlockOnPossibleDataLoss=False

echo "Database schema deployed successfully."
