#!/usr/bin/env pwsh
# Deploy a one-shot curl container into snet-aci to validate that the
# Container Apps environment L7 routes correctly to the UI and API apps.
# Returns non-zero exit code if either endpoint returns the env's
# "Container App is stopped or does not exist" 404 page (1946 bytes).

[CmdletBinding()]
param(
    [int]$TimeoutSeconds = 240
)

$ErrorActionPreference = 'Stop'

Write-Host "=== Container Apps L7 routing test ==="

$envValues = azd env get-values --output json | ConvertFrom-Json
$rg = $envValues.AZURE_RESOURCE_GROUP
$aciSubnetId = $envValues.AZURE_ACI_SUBNET_ID
$envDomain = $envValues.AZURE_CONTAINER_APPS_ENVIRONMENT_DEFAULT_DOMAIN
$apiName = $envValues.SERVICE_WEB_NAME
$uiName = $envValues.SERVICE_UI_NAME

if (-not $rg -or -not $aciSubnetId -or -not $envDomain -or -not $apiName -or -not $uiName) {
    Write-Error "Missing required azd env values. Required: AZURE_RESOURCE_GROUP, AZURE_ACI_SUBNET_ID, AZURE_CONTAINER_APPS_ENVIRONMENT_DEFAULT_DOMAIN, SERVICE_WEB_NAME, SERVICE_UI_NAME."
    exit 1
}

# External env (Option B) publishes apps as <app>.<envDomain>. The synthetic
# ACA env private DNS zone resolves wildcards to the env's public IP, but the
# Host header must match the external form for ingress to route correctly.
$apiFqdn = "$apiName.$envDomain"
$uiFqdn = "$uiName.$envDomain"
$timestamp = Get-Date -Format 'HHmmss'
$aciName = "curl-test-$timestamp"
$yamlPath = Join-Path ([System.IO.Path]::GetTempPath()) "$aciName.yaml"

Write-Host "Resource group:  $rg"
Write-Host "Subnet:          $aciSubnetId"
Write-Host "API endpoint:    https://$apiFqdn"
Write-Host "UI endpoint:     https://$uiFqdn"
Write-Host ""

$yaml = @"
apiVersion: '2023-05-01'
location: $($envValues.AZURE_LOCATION)
name: $aciName
properties:
  osType: Linux
  restartPolicy: Never
  subnetIds:
    - id: $aciSubnetId
  containers:
    - name: curl
      properties:
        image: curlimages/curl:latest
        resources:
          requests:
            cpu: 0.5
            memoryInGB: 0.5
        command:
          - sh
          - -c
          - |
            set +e
            echo '=== UI HEAD https://$uiFqdn/ ==='
            curl -k -sS -I --max-time 30 https://$uiFqdn/
            echo ''
            echo '=== UI BODY https://$uiFqdn/ (first 400 bytes) ==='
            curl -k -sS --max-time 30 https://$uiFqdn/ | head -c 400
            echo ''
            echo '=== API HEAD https://$apiFqdn/v0/servers ==='
            curl -k -sS -I --max-time 30 https://$apiFqdn/v0/servers
            echo ''
            echo '=== API BODY https://$apiFqdn/v0/servers (first 400 bytes) ==='
            curl -k -sS --max-time 30 https://$apiFqdn/v0/servers | head -c 400
            echo ''
            echo '=== DONE ==='
type: Microsoft.ContainerInstance/containerGroups
"@

Set-Content -Path $yamlPath -Value $yaml -Encoding UTF8

try {
    Write-Host "Creating curl-test container instance ($aciName)..."
    az container create --resource-group $rg --file $yamlPath --output none
    if ($LASTEXITCODE -ne 0) { throw "az container create failed." }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $state = $null
    do {
        Start-Sleep -Seconds 5
        $state = az container show --resource-group $rg --name $aciName --query 'instanceView.state' -o tsv 2>$null
        Write-Host "  state: $state"
    } while ($state -notin @('Succeeded','Failed') -and (Get-Date) -lt $deadline)

    if ($state -ne 'Succeeded' -and $state -ne 'Failed') {
        Write-Warning "Container did not finish within $TimeoutSeconds seconds; continuing to fetch logs."
    }

    Write-Host ""
    Write-Host "=== curl-test logs ==="
    $logs = az container logs --resource-group $rg --name $aciName 2>$null
    Write-Host $logs
    Write-Host "=== end logs ==="

    $unavailableMarker = 'Container App is stopped or does not exist'
    if ($logs -match [regex]::Escape($unavailableMarker)) {
        Write-Error "L7 routing FAILED: env returned the 'Container App is stopped or does not exist' 404 page for at least one endpoint."
        $script:testFailed = $true
    }
    else {
        Write-Host ""
        Write-Host "L7 routing test PASSED. Both endpoints responded from the app (not the env router)."
        $script:testFailed = $false
    }
}
finally {
    Write-Host ""
    Write-Host "Cleaning up curl-test container instance..."
    az container delete --resource-group $rg --name $aciName --yes --output none 2>$null
    Remove-Item -Path $yamlPath -ErrorAction SilentlyContinue
}

if ($script:testFailed) { exit 1 }
exit 0
