#!/usr/bin/env pwsh
# Idempotent creation/refresh of the AAD app registrations that back Easy Auth
# on the MCP Registry API and UI container apps.
#
# Runs as a preprovision hook so that AZURE_API_APP_CLIENT_ID, AZURE_UI_APP_CLIENT_ID,
# AZURE_UI_APP_CLIENT_SECRET, AZURE_TENANT_ID, and AZURE_ADMIN_GROUP_ID exist in
# the azd env before Bicep needs them. Bicep wires these into authConfigs +
# container app secrets so the apps come up authenticated on first deploy.
#
# What this does (all idempotent):
#   1. API app reg 'mcp-registry-api-${env}':
#      - exposes scope 'mcp.access' (delegated, admin+user consent)
#      - groups optional claim on access tokens and id tokens
#      - requestedAccessTokenVersion = 2
#   2. UI app reg 'mcp-registry-ui-${env}':
#      - web platform with redirect URI placeholder (real URI is patched in
#        postprovision once we know the UI FQDN)
#      - API permission for mcp-registry-api-${env}/mcp.access (delegated) +
#        admin consent (so users don't get a consent prompt on first sign-in)
#      - groups optional claim
#      - id-token issuance enabled
#      - rotating 18-month client secret if AZURE_UI_APP_CLIENT_SECRET is not
#        already in the azd env
#   3. Stores client IDs / secret back into the azd env. The secret is marked
#      @secure() in Bicep so it flows as a secure parameter; .azure/<env>/.env
#      is gitignored.
#
# Pre-reqs: az CLI logged in, has Application.ReadWrite.All in the tenant.
# Set AZURE_ADMIN_GROUP_ID up front (object ID of the admin security group):
#   azd env set AZURE_ADMIN_GROUP_ID <object-id>

$ErrorActionPreference = 'Stop'

# CI escape hatch: when client IDs / secret are pre-seeded via GH secrets the
# preprovision hook has nothing to do and the workflow SP doesn't need
# Application.ReadWrite.All. Set MCPREG_SKIP_AAD_SETUP=1 to bail early.
if ($env:MCPREG_SKIP_AAD_SETUP -eq '1') {
    Write-Host "MCPREG_SKIP_AAD_SETUP=1 — skipping AAD app registration setup." -ForegroundColor Yellow
    exit 0
}

# On Windows, `az rest --body <json-string>` is fragile because cmd.exe
# argument parsing eats quotes. Write the JSON to a temp file and pass
# --body "@$tmpFile" instead.
function Invoke-GraphPatch {
    param(
        [Parameter(Mandatory)] [string] $Uri,
        [Parameter(Mandatory)] [hashtable] $Body
    )
    $tmp = [System.IO.Path]::GetTempFileName()
    try {
        ($Body | ConvertTo-Json -Depth 10 -Compress) | Set-Content -Path $tmp -Encoding utf8 -NoNewline
        az rest --method PATCH `
            --uri $Uri `
            --headers "Content-Type=application/json" `
            --body "@$tmp" | Out-Null
    } finally {
        Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
    }
}

function Invoke-GraphPost {
    param(
        [Parameter(Mandatory)] [string] $Uri,
        [Parameter(Mandatory)] [hashtable] $Body
    )
    $tmp = [System.IO.Path]::GetTempFileName()
    try {
        ($Body | ConvertTo-Json -Depth 10 -Compress) | Set-Content -Path $tmp -Encoding utf8 -NoNewline
        az rest --method POST `
            --uri $Uri `
            --headers "Content-Type=application/json" `
            --body "@$tmp" | Out-Null
    } finally {
        Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
    }
}

Write-Host "Setting up AAD app registrations for Easy Auth..." -ForegroundColor Cyan

$envValues = azd env get-values --output json | ConvertFrom-Json
$envName = $envValues.AZURE_ENV_NAME
if (-not $envName) {
    Write-Error "AZURE_ENV_NAME is not set in the azd env. Run 'azd env new <name>' first."
    exit 1
}

$tenantId = az account show --query tenantId -o tsv
if (-not $tenantId) {
    Write-Error "Could not read tenantId from az CLI. Run 'az login'."
    exit 1
}
azd env set AZURE_TENANT_ID $tenantId | Out-Null

$adminGroupId = $envValues.AZURE_ADMIN_GROUP_ID
if (-not $adminGroupId) {
    Write-Warning "AZURE_ADMIN_GROUP_ID is not set. Members of this Entra ID security group are the only ones authorized to write to the API and use the UI."
    Write-Warning "Set it now with: azd env set AZURE_ADMIN_GROUP_ID <object-id-of-admin-group>"
    Write-Warning "Continuing with an empty admin group \u2014 NO users will have admin access until you set this and re-run 'azd provision'."
}

$apiAppName = "mcp-registry-api-$envName"
$uiAppName = "mcp-registry-ui-$envName"

function Get-OrCreateApp {
    param([string]$DisplayName)

    $existing = az ad app list --display-name $DisplayName --query "[?displayName=='$DisplayName'] | [0]" -o json | ConvertFrom-Json
    if ($existing) {
        Write-Host "  Reusing existing app reg '$DisplayName' (appId=$($existing.appId))" -ForegroundColor DarkGray
        return $existing
    }

    Write-Host "  Creating app reg '$DisplayName'..." -ForegroundColor Yellow
    $created = az ad app create --display-name $DisplayName --sign-in-audience AzureADMyOrg -o json | ConvertFrom-Json
    # Service principal in this tenant so admin consent + role assignments work.
    az ad sp create --id $created.appId -o none 2>$null
    return $created
}

# --- API app registration ---------------------------------------------------
Write-Host "[1/2] API app registration: $apiAppName" -ForegroundColor Green
$apiApp = Get-OrCreateApp -DisplayName $apiAppName
$apiAppId = $apiApp.appId
$apiObjectId = $apiApp.id

# Expose the mcp.access scope. Build the patch via Graph PATCH so we get
# stable scope IDs (otherwise `az ad app update --identifier-uris` resets them).
$scopeId = $apiApp.api.oauth2PermissionScopes | Where-Object { $_.value -eq 'mcp.access' } | Select-Object -First 1 -ExpandProperty id
if (-not $scopeId) {
    $scopeId = [guid]::NewGuid().ToString()
}

$apiPatch = @{
    identifierUris = @("api://$apiAppId")
    api = @{
        requestedAccessTokenVersion = 2
        oauth2PermissionScopes = @(@{
            id = $scopeId
            adminConsentDescription = "Allow the application to access the MCP Registry API on behalf of the signed-in user."
            adminConsentDisplayName = "Access MCP Registry API"
            userConsentDescription  = "Allow the application to access the MCP Registry API on your behalf."
            userConsentDisplayName  = "Access MCP Registry API"
            value = 'mcp.access'
            type = 'User'
            isEnabled = $true
        })
    }
    optionalClaims = @{
        idToken = @(@{ name = 'groups'; essential = $false })
        accessToken = @(@{ name = 'groups'; essential = $false })
        saml2Token = @()
    }
    groupMembershipClaims = 'SecurityGroup'
}

# Use Graph PATCH directly; `az ad app update` doesn't surface
# requestedAccessTokenVersion or groupMembershipClaims cleanly.
Invoke-GraphPatch -Uri "https://graph.microsoft.com/v1.0/applications/$apiObjectId" -Body $apiPatch

azd env set AZURE_API_APP_CLIENT_ID $apiAppId | Out-Null
Write-Host "  API app clientId: $apiAppId" -ForegroundColor DarkGray
Write-Host "  Exposed scope:    api://$apiAppId/mcp.access" -ForegroundColor DarkGray

# --- UI app registration ----------------------------------------------------
Write-Host "[2/2] UI app registration: $uiAppName" -ForegroundColor Green
$uiApp = Get-OrCreateApp -DisplayName $uiAppName
$uiAppId = $uiApp.appId
$uiObjectId = $uiApp.id

# Web platform with id-token issuance. Real redirect URI is patched in
# postprovision (once we know the UI's .internal FQDN). For now we leave
# whatever's there; Easy Auth itself accepts the actual request host.
$uiPatch = @{
    web = @{
        implicitGrantSettings = @{
            enableIdTokenIssuance = $true
            enableAccessTokenIssuance = $false
        }
    }
    optionalClaims = @{
        idToken = @(@{ name = 'groups'; essential = $false })
        accessToken = @()
        saml2Token = @()
    }
    groupMembershipClaims = 'SecurityGroup'
    requiredResourceAccess = @(@{
        resourceAppId = $apiAppId
        resourceAccess = @(@{
            id = $scopeId
            type = 'Scope'
        })
    })
}

Invoke-GraphPatch -Uri "https://graph.microsoft.com/v1.0/applications/$uiObjectId" -Body $uiPatch

azd env set AZURE_UI_APP_CLIENT_ID $uiAppId | Out-Null
Write-Host "  UI app clientId:  $uiAppId" -ForegroundColor DarkGray

# Grant admin consent to the API permission so users skip the consent prompt.
# This needs the caller to have privileges to consent on behalf of the tenant
# (Cloud Application Admin / Application Admin / Global Admin). If it fails
# we warn but don't block \u2014 individual users will see a consent prompt instead.
$uiSp = az ad sp show --id $uiAppId -o json 2>$null | ConvertFrom-Json
$apiSp = az ad sp show --id $apiAppId -o json 2>$null | ConvertFrom-Json
if ($uiSp -and $apiSp) {
    Write-Host "  Granting admin consent for UI \u2192 API delegated permission..." -ForegroundColor DarkGray
    $grantBody = @{
        clientId = $uiSp.id
        consentType = 'AllPrincipals'
        resourceId = $apiSp.id
        scope = 'mcp.access'
    }

    # Check for an existing grant first to keep this idempotent.
    $existingGrant = az rest --method GET `
        --uri "https://graph.microsoft.com/v1.0/oauth2PermissionGrants?`$filter=clientId eq '$($uiSp.id)' and resourceId eq '$($apiSp.id)'" `
        -o json 2>$null | ConvertFrom-Json

    if ($existingGrant -and $existingGrant.value.Count -gt 0) {
        Write-Host "  Admin consent grant already present." -ForegroundColor DarkGray
    } else {
        # az rest writes errors to stderr but doesn't throw, so check $LASTEXITCODE.
        $tmpGrant = [System.IO.Path]::GetTempFileName()
        try {
            ($grantBody | ConvertTo-Json -Depth 10 -Compress) | Set-Content -Path $tmpGrant -Encoding utf8 -NoNewline
            az rest --method POST `
                --uri "https://graph.microsoft.com/v1.0/oauth2PermissionGrants" `
                --headers "Content-Type=application/json" `
                --body "@$tmpGrant" 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Host "  Admin consent granted." -ForegroundColor DarkGray
            } else {
                Write-Warning "  Could not grant admin consent (caller likely lacks Cloud Application Administrator role). Non-blocking: an admin from the AZURE_ADMIN_GROUP_ID group will see a one-time consent prompt on first sign-in, or grant consent manually in the Entra portal under Enterprise applications \u2192 $uiAppName \u2192 Permissions."
            }
        } finally {
            Remove-Item -LiteralPath $tmpGrant -ErrorAction SilentlyContinue
        }
    }
}

# --- UI client secret -------------------------------------------------------
# Easy Auth's auth-code flow needs a confidential-client secret. We generate
# one only if AZURE_UI_APP_CLIENT_SECRET isn't already in the azd env, so
# subsequent provisions don't churn the secret.
$existingSecret = $envValues.AZURE_UI_APP_CLIENT_SECRET
if (-not $existingSecret) {
    Write-Host "  Generating UI app client secret (18 months)..." -ForegroundColor Yellow
    $endDate = (Get-Date).AddMonths(18).ToString('yyyy-MM-ddTHH:mm:ssZ')
    $secretResp = az ad app credential reset `
        --id $uiAppId `
        --display-name "easy-auth-$envName" `
        --end-date $endDate `
        --append `
        -o json | ConvertFrom-Json

    if (-not $secretResp.password) {
        Write-Error "Failed to generate UI app client secret."
        exit 1
    }

    # Marked @secure() in Bicep so azd flows it as a secure parameter.
    # .azure/<env>/.env is gitignored so the on-disk copy stays local.
    azd env set AZURE_UI_APP_CLIENT_SECRET $secretResp.password | Out-Null
    Write-Host "  UI client secret generated and stored in azd env." -ForegroundColor DarkGray
} else {
    Write-Host "  Reusing existing AZURE_UI_APP_CLIENT_SECRET from azd env." -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "AAD app registrations ready." -ForegroundColor Cyan
Write-Host "  AZURE_TENANT_ID         = $tenantId"
Write-Host "  AZURE_API_APP_CLIENT_ID = $apiAppId"
Write-Host "  AZURE_UI_APP_CLIENT_ID  = $uiAppId"
if (-not $adminGroupId) {
    Write-Host "  AZURE_ADMIN_GROUP_ID    = (not set \u2014 set with: azd env set AZURE_ADMIN_GROUP_ID <group-object-id>)" -ForegroundColor Yellow
} else {
    Write-Host "  AZURE_ADMIN_GROUP_ID    = $adminGroupId"
}
