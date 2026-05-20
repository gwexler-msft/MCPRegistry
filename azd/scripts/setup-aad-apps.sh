#!/usr/bin/env bash
# Idempotent creation/refresh of the AAD app registrations that back Easy Auth
# on the MCP Registry API and UI container apps.
#
# See setup-aad-apps.ps1 for the full explanation of what this does and why.
# This bash port mirrors the PowerShell version 1:1.

set -euo pipefail

echo "Setting up AAD app registrations for Easy Auth..."

envName=$(azd env get-value AZURE_ENV_NAME 2>/dev/null || true)
if [ -z "$envName" ]; then
    echo "ERROR: AZURE_ENV_NAME is not set in the azd env. Run 'azd env new <name>' first." >&2
    exit 1
fi

tenantId=$(az account show --query tenantId -o tsv)
if [ -z "$tenantId" ]; then
    echo "ERROR: Could not read tenantId from az CLI. Run 'az login'." >&2
    exit 1
fi
azd env set AZURE_TENANT_ID "$tenantId" >/dev/null

adminGroupId=$(azd env get-value AZURE_ADMIN_GROUP_ID 2>/dev/null || true)
if [ -z "$adminGroupId" ]; then
    echo "WARNING: AZURE_ADMIN_GROUP_ID is not set. Members of this Entra ID security group are the only ones authorized to write to the API and use the UI." >&2
    echo "WARNING: Set it now with: azd env set AZURE_ADMIN_GROUP_ID <object-id-of-admin-group>" >&2
    echo "WARNING: Continuing with an empty admin group \u2014 NO users will have admin access until you set this and re-run 'azd provision'." >&2
fi

apiAppName="mcp-registry-api-$envName"
uiAppName="mcp-registry-ui-$envName"

get_or_create_app() {
    local displayName="$1"
    local appJson
    appJson=$(az ad app list --display-name "$displayName" --query "[?displayName=='$displayName'] | [0]" -o json)
    if [ "$appJson" != "null" ] && [ -n "$appJson" ]; then
        echo "$appJson"
        return
    fi
    az ad app create --display-name "$displayName" --sign-in-audience AzureADMyOrg -o json
    # Service principal in this tenant so admin consent + role assignments work.
    local appId
    appId=$(az ad app list --display-name "$displayName" --query "[0].appId" -o tsv)
    az ad sp create --id "$appId" -o none 2>/dev/null || true
}

# --- API app registration ---------------------------------------------------
echo "[1/2] API app registration: $apiAppName"
apiApp=$(get_or_create_app "$apiAppName")
apiAppId=$(echo "$apiApp" | jq -r '.appId')
apiObjectId=$(echo "$apiApp" | jq -r '.id')
echo "  Reusing/created app reg (appId=$apiAppId)"

# Preserve existing mcp.access scope ID if present, else generate a new one.
scopeId=$(echo "$apiApp" | jq -r '.api.oauth2PermissionScopes[]? | select(.value == "mcp.access") | .id' | head -n 1)
if [ -z "$scopeId" ]; then
    scopeId=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || python3 -c 'import uuid; print(uuid.uuid4())')
fi

apiPatch=$(jq -nc \
    --arg appId "$apiAppId" \
    --arg scopeId "$scopeId" \
    '{
        identifierUris: ["api://" + $appId],
        api: {
            requestedAccessTokenVersion: 2,
            oauth2PermissionScopes: [{
                id: $scopeId,
                adminConsentDescription: "Allow the application to access the MCP Registry API on behalf of the signed-in user.",
                adminConsentDisplayName: "Access MCP Registry API",
                userConsentDescription: "Allow the application to access the MCP Registry API on your behalf.",
                userConsentDisplayName: "Access MCP Registry API",
                value: "mcp.access",
                type: "User",
                isEnabled: true
            }]
        },
        optionalClaims: {
            idToken: [{ name: "groups", essential: false }],
            accessToken: [{ name: "groups", essential: false }],
            saml2Token: []
        },
        groupMembershipClaims: "SecurityGroup"
    }')

az rest --method PATCH \
    --uri "https://graph.microsoft.com/v1.0/applications/$apiObjectId" \
    --headers "Content-Type=application/json" \
    --body "$apiPatch" >/dev/null

azd env set AZURE_API_APP_CLIENT_ID "$apiAppId" >/dev/null
echo "  API app clientId: $apiAppId"
echo "  Exposed scope:    api://$apiAppId/mcp.access"

# --- UI app registration ----------------------------------------------------
echo "[2/2] UI app registration: $uiAppName"
uiApp=$(get_or_create_app "$uiAppName")
uiAppId=$(echo "$uiApp" | jq -r '.appId')
uiObjectId=$(echo "$uiApp" | jq -r '.id')
echo "  Reusing/created app reg (appId=$uiAppId)"

uiPatch=$(jq -nc \
    --arg apiAppId "$apiAppId" \
    --arg scopeId "$scopeId" \
    '{
        web: {
            implicitGrantSettings: {
                enableIdTokenIssuance: true,
                enableAccessTokenIssuance: false
            }
        },
        optionalClaims: {
            idToken: [{ name: "groups", essential: false }],
            accessToken: [],
            saml2Token: []
        },
        groupMembershipClaims: "SecurityGroup",
        requiredResourceAccess: [{
            resourceAppId: $apiAppId,
            resourceAccess: [{
                id: $scopeId,
                type: "Scope"
            }]
        }]
    }')

az rest --method PATCH \
    --uri "https://graph.microsoft.com/v1.0/applications/$uiObjectId" \
    --headers "Content-Type=application/json" \
    --body "$uiPatch" >/dev/null

azd env set AZURE_UI_APP_CLIENT_ID "$uiAppId" >/dev/null
echo "  UI app clientId:  $uiAppId"

# Admin consent for UI -> API delegated scope (idempotent).
uiSpId=$(az ad sp show --id "$uiAppId" --query id -o tsv 2>/dev/null || true)
apiSpId=$(az ad sp show --id "$apiAppId" --query id -o tsv 2>/dev/null || true)
if [ -n "$uiSpId" ] && [ -n "$apiSpId" ]; then
    existingGrant=$(az rest --method GET \
        --uri "https://graph.microsoft.com/v1.0/oauth2PermissionGrants?\$filter=clientId eq '$uiSpId' and resourceId eq '$apiSpId'" \
        -o json 2>/dev/null | jq '.value | length')
    if [ "${existingGrant:-0}" -gt 0 ]; then
        echo "  Admin consent grant already present."
    else
        grantBody=$(jq -nc \
            --arg clientId "$uiSpId" \
            --arg resourceId "$apiSpId" \
            '{ clientId: $clientId, consentType: "AllPrincipals", resourceId: $resourceId, scope: "mcp.access" }')
        if az rest --method POST \
            --uri "https://graph.microsoft.com/v1.0/oauth2PermissionGrants" \
            --headers "Content-Type=application/json" \
            --body "$grantBody" >/dev/null 2>&1; then
            echo "  Admin consent granted."
        else
            echo "WARNING: Could not grant admin consent (need Cloud Application Administrator role). Users will see a one-time consent prompt on first sign-in." >&2
        fi
    fi
fi

# --- UI client secret -------------------------------------------------------
existingSecret=$(azd env get-value AZURE_UI_APP_CLIENT_SECRET 2>/dev/null || true)
if [ -z "$existingSecret" ]; then
    echo "  Generating UI app client secret (18 months)..."
    endDate=$(date -u -d "+18 months" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || python3 -c 'from datetime import datetime, timedelta; print((datetime.utcnow() + timedelta(days=540)).strftime("%Y-%m-%dT%H:%M:%SZ"))')
    secretResp=$(az ad app credential reset \
        --id "$uiAppId" \
        --display-name "easy-auth-$envName" \
        --end-date "$endDate" \
        --append \
        -o json)
    secretValue=$(echo "$secretResp" | jq -r '.password')
    if [ -z "$secretValue" ] || [ "$secretValue" = "null" ]; then
        echo "ERROR: Failed to generate UI app client secret." >&2
        exit 1
    fi
    azd env set AZURE_UI_APP_CLIENT_SECRET "$secretValue" >/dev/null
    echo "  UI client secret generated and stored in azd env."
else
    echo "  Reusing existing AZURE_UI_APP_CLIENT_SECRET from azd env."
fi

echo ""
echo "AAD app registrations ready."
echo "  AZURE_TENANT_ID         = $tenantId"
echo "  AZURE_API_APP_CLIENT_ID = $apiAppId"
echo "  AZURE_UI_APP_CLIENT_ID  = $uiAppId"
if [ -z "$adminGroupId" ]; then
    echo "  AZURE_ADMIN_GROUP_ID    = (not set \u2014 set with: azd env set AZURE_ADMIN_GROUP_ID <group-object-id>)"
else
    echo "  AZURE_ADMIN_GROUP_ID    = $adminGroupId"
fi
