#!/usr/bin/env pwsh
# Diagnostic: test both <app>.internal.<envDomain> and <app>.<envDomain>
# forms from inside snet-aci, plus direct IP TCP probe.
[CmdletBinding()]
param([int]$TimeoutSeconds = 240)

$ErrorActionPreference = 'Stop'
$envValues = azd env get-values --output json | ConvertFrom-Json
$rg        = $envValues.AZURE_RESOURCE_GROUP
$aciSubnetId = $envValues.AZURE_ACI_SUBNET_ID
$envDomain = $envValues.AZURE_CONTAINER_APPS_ENVIRONMENT_DEFAULT_DOMAIN
$apiName   = $envValues.SERVICE_API_NAME
$uiName    = $envValues.SERVICE_UI_NAME
$staticIp  = az containerapp env show --name $envValues.AZURE_CONTAINER_APPS_ENVIRONMENT_NAME --resource-group $rg --query 'properties.staticIp' -o tsv

$apiI = "$apiName.internal.$envDomain"
$apiB = "$apiName.$envDomain"
$uiI  = "$uiName.internal.$envDomain"
$uiB  = "$uiName.$envDomain"

$aciName = "diag-$(Get-Date -Format HHmmss)"
$yamlPath = Join-Path ([System.IO.Path]::GetTempPath()) "$aciName.yaml"

Write-Host "=== Diagnostic FQDN test ==="
Write-Host "envDomain: $envDomain"
Write-Host "staticIp:  $staticIp"
Write-Host ""

$bash = @'
set +e
echo '--- nslookup ---'
for h in __APII__ __APIB__ __UII__ __UIB__; do
  echo "host: $h"
  getent hosts "$h" || echo "  RESOLVE FAIL"
done
echo ''
echo '--- TCP 443 to static IP __IP__ ---'
timeout 5 sh -c "echo > /dev/tcp/__IP__/443" 2>&1 && echo "  TCP443 OK" || echo "  TCP443 FAIL"
echo ''
for url in https://__APII__/health https://__APIB__/health https://__UII__/ https://__UIB__/; do
  echo "=== $url ==="
  code=$(curl -k -sS -o /tmp/body -w "%{http_code}" --max-time 20 "$url")
  echo "http_code=$code"
  head -c 200 /tmp/body
  echo ''
  echo ''
done
echo '--- with --resolve override over IP ---'
for h in __APII__ __APIB__; do
  echo "Host=$h"
  curl -k -sS -o /tmp/b -w "http_code=%{http_code}\n" --max-time 15 --resolve "$h:443:__IP__" "https://$h/health"
  head -c 200 /tmp/b
  echo ''
done
echo ''
echo '--- HEAD with full response headers (api bare) ---'
curl -k -sS -D - -o /dev/null --max-time 15 https://__APIB__/health
echo ''
echo '--- HEAD with totally random host (sanity) ---'
curl -k -sS -D - -o /dev/null --max-time 15 --resolve nonexistent.__ENVD__:443:__IP__ https://nonexistent.__ENVD__/
echo '=== DONE ==='
'@
$bash = $bash.Replace('__APII__', $apiI).Replace('__APIB__', $apiB).Replace('__UII__', $uiI).Replace('__UIB__', $uiB).Replace('__IP__', $staticIp).Replace('__ENVD__', $envDomain)
# Indent every line by 12 spaces for inclusion in YAML block scalar
$indented = ($bash -split "`n" | ForEach-Object { '            ' + $_ }) -join "`n"

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
    - name: diag
      properties:
        image: mcr.microsoft.com/azure-cli:latest
        resources:
          requests:
            cpu: 0.5
            memoryInGB: 1.0
        command:
          - sh
          - -c
          - |
$indented
type: Microsoft.ContainerInstance/containerGroups
"@

Set-Content -Path $yamlPath -Value $yaml -Encoding UTF8

try {
    az container create --resource-group $rg --file $yamlPath --output none
    if ($LASTEXITCODE -ne 0) { throw "az container create failed." }
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        Start-Sleep -Seconds 5
        $state = az container show --resource-group $rg --name $aciName --query 'instanceView.state' -o tsv 2>$null
        Write-Host "  state: $state"
    } while ($state -notin @('Succeeded','Failed') -and (Get-Date) -lt $deadline)

    Write-Host ""
    Write-Host "=== logs ==="
    az container logs --resource-group $rg --name $aciName
    Write-Host "=== end logs ==="
}
finally {
    az container delete --resource-group $rg --name $aciName --yes --output none 2>$null
    Remove-Item -Path $yamlPath -ErrorAction SilentlyContinue
}
