#!/usr/bin/env pwsh
# Patches the UI AAD app registration's web redirect URI to the actual UI
# container app FQDN, now that provisioning has completed and we know the URL.
#
# Runs as a postprovision hook. The UI uses Microsoft.Identity.Web (OIDC)
# instead of Container Apps Easy Auth, so the redirect URI must match
# Microsoft.Identity.Web's default CallbackPath:
#   https://<ui-fqdn>/signin-oidc
# and the sign-out callback:
#   https://<ui-fqdn>/signout-callback-oidc
#
# Idempotent: only patches if the current redirectUris list doesn't already
# include the expected callback URL.

$ErrorActionPreference = 'Stop'

Write-Host "Patching UI app registration redirect URI..." -ForegroundColor Cyan

$envValues = azd env get-values --output json | ConvertFrom-Json
$uiAppId = $envValues.AZURE_UI_APP_CLIENT_ID
$uiUrl = $envValues.UI_URL

if (-not $uiAppId) {
    Write-Error "AZURE_UI_APP_CLIENT_ID not set in azd env. Did the preprovision hook run?"
    exit 1
}
if (-not $uiUrl) {
    Write-Error "UI_URL not set in azd env. Did 'azd provision' succeed?"
    exit 1
}

$callbackUrl = "$uiUrl/signin-oidc"
$signoutCallbackUrl = "$uiUrl/signout-callback-oidc"
$logoutUrl = "$uiUrl/MicrosoftIdentity/Account/SignedOut"
Write-Host "  UI app:                $uiAppId"
Write-Host "  Sign-in callback:      $callbackUrl"
Write-Host "  Sign-out callback:     $signoutCallbackUrl"

$uiApp = az ad app show --id $uiAppId -o json | ConvertFrom-Json
$existingRedirects = @($uiApp.web.redirectUris)

$hasSignin = $existingRedirects -contains $callbackUrl
$hasSignout = $existingRedirects -contains $signoutCallbackUrl

if ($hasSignin -and $hasSignout) {
    Write-Host "  Redirect URIs already present. Nothing to patch." -ForegroundColor DarkGray
    exit 0
}

$newRedirects = @(($existingRedirects + $callbackUrl + $signoutCallbackUrl) | Select-Object -Unique)
$patch = @{
    web = @{
        # @(...) wrapper around the array forces ConvertTo-Json to emit
        # JSON [array] even when there is only one element, otherwise pwsh
        # serializes a single-element array as a primitive string and Graph
        # rejects it with: 'unexpected PrimitiveValue node ... StartArray expected'.
        redirectUris = $newRedirects
        logoutUrl = $logoutUrl
        implicitGrantSettings = @{
            enableIdTokenIssuance = $true
            enableAccessTokenIssuance = $false
        }
    }
}

# `az rest --body <jsonString>` on Windows pwsh mangles the JSON via cmd.exe
# argument quoting. Write the JSON to a temp file and pass --body "@<file>"
# so az picks up the raw payload from disk.
$tmp = [System.IO.Path]::GetTempFileName()
try {
    ($patch | ConvertTo-Json -Depth 10 -Compress) | Set-Content -Path $tmp -Encoding utf8 -NoNewline
    az rest --method PATCH `
        --uri "https://graph.microsoft.com/v1.0/applications/$($uiApp.id)" `
        --headers "Content-Type=application/json" `
        --body "@$tmp" | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to patch UI app registration redirect URI (Graph PATCH exit code $LASTEXITCODE)."
        exit 1
    }
} finally {
    Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
}

Write-Host "  Redirect URIs added." -ForegroundColor Green
