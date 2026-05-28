#!/usr/bin/env pwsh
# Idempotently enable ACR artifact streaming (overlaybd) on the api and ui
# repos. New repos default to convertPushedImages=false, so without this hook
# the first images pushed to a fresh env never get the streaming format.
#
# Safe to re-run: az acr artifact-streaming update is idempotent (just sets
# the desired state). Only flips when the current value differs.

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$envValues = azd env get-values --output json | ConvertFrom-Json
$registryName = $envValues.AZURE_CONTAINER_REGISTRY_NAME
$envName = $envValues.AZURE_ENV_NAME

if (-not $registryName -or -not $envName) {
    Write-Error "Missing AZURE_CONTAINER_REGISTRY_NAME or AZURE_ENV_NAME from azd env."
    exit 1
}

$repos = @("mcpregistry/api-$envName", "mcpregistry/ui-$envName")

foreach ($repo in $repos) {
    Write-Host "Checking streaming on ${registryName}/${repo}..." -ForegroundColor Cyan
    $exists = az acr repository show --name $registryName --repository $repo 2>$null
    if (-not $exists) {
        Write-Host "  Repo not yet pushed - skipping." -ForegroundColor Yellow
        continue
    }
    $current = az acr artifact-streaming show --name $registryName --repository $repo --only-show-errors 2>$null | ConvertFrom-Json
    if ($current.convertPushedImages -eq $true) {
        Write-Host "  Already enabled." -ForegroundColor Green
        continue
    }
    Write-Host "  Enabling auto-conversion..." -ForegroundColor Yellow
    az acr artifact-streaming update --name $registryName --repository $repo --enable-streaming true --only-show-errors -o none
    Write-Host "  Done." -ForegroundColor Green
}
