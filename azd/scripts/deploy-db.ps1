#!/usr/bin/env pwsh
# Deploy the database schema using the dacpac produced by the SQL project.
# Runs as a postprovision hook or standalone.
# SQL target platform (DSP) reference:
# https://learn.microsoft.com/en-us/sql/tools/sql-database-projects/concepts/target-platform?view=sql-server-ver17&pivots=sq1-command-line

param(
    [string]$ServerName,
    [string]$DatabaseName,
    [string]$TargetPlatform
)

Write-Host "Deploying database schema via dacpac..."

$resourceGroup = $null
if (-not $ServerName -or -not $DatabaseName) {
    $envValues = azd env get-values --output json | ConvertFrom-Json
    if (-not $ServerName) { $ServerName = $envValues.AZURE_SQL_SERVER_NAME }
    if (-not $DatabaseName) { $DatabaseName = $envValues.AZURE_SQL_DATABASE_NAME }
    if (-not $TargetPlatform) { $TargetPlatform = $envValues.SQL_TARGET_PLATFORM }
    $resourceGroup = $envValues.AZURE_RESOURCE_GROUP
}

if (-not $TargetPlatform) {
    $TargetPlatform = $env:SQL_TARGET_PLATFORM
}

if (-not $TargetPlatform) {
    $TargetPlatform = "Microsoft.Data.Tools.Schema.Sql.SqlAzureV12DatabaseSchemaProvider"
}

if (-not $ServerName -or -not $DatabaseName) {
    Write-Error "Missing SQL server or database name. Provide via parameters or azd env."
    exit 1
}

if (-not $resourceGroup) {
    $resourceGroup = az sql server show --name $ServerName --query resourceGroup -o tsv 2>$null
}

$sqlFqdn = if ($ServerName -like '*.database.windows.net') { $ServerName } else { "${ServerName}.database.windows.net" }

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot (Join-Path ".." ".."))).Path
$dacpacPath = Join-Path $repoRoot "src\MCPRegistryDatabase\bin\Release\MCPRegistryDatabase.dacpac"
if ($TargetPlatform) {
    Write-Host "Using SQL target platform (DSP): $TargetPlatform"
}

$shouldBuildDacpac = (-not (Test-Path $dacpacPath)) -or [bool]$TargetPlatform
if ($shouldBuildDacpac) {
    if (Test-Path $dacpacPath) {
        Write-Host "Target platform override provided, rebuilding dacpac..."
    }
    else {
        Write-Host "Dacpac not found, building..."
    }

    $buildArgs = @(
        (Join-Path $repoRoot "src\MCPRegistryDatabase\MCPRegistryDatabase.sqlproj"),
        "-c",
        "Release"
    )
    if ($TargetPlatform) {
        $buildArgs += "/p:DSP=$TargetPlatform"
    }

    dotnet build @buildArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to build SQL project."
        exit 1
    }
}

# Add temporary firewall rule for deployer's IP
$myIp = (Invoke-RestMethod -Uri "https://api.ipify.org" -TimeoutSec 10)
$firewallRuleName = "azd-deploy-$($myIp.Replace('.', '-'))"

# When PNA=Disabled (often enforced by Azure Policy), public-path connection
# attempts return "Deny Public Network Access is set to Yes" regardless of
# firewall rules. Try a best-effort toggle to Enabled; if Policy blocks the
# toggle, skip the public-path deploy with clear operator instructions
# rather than failing the entire azd pipeline.
$pnaState = az sql server show --resource-group $resourceGroup --name $ServerName --query publicNetworkAccess -o tsv 2>$null
$pnaRestoreNeeded = $false
if ($pnaState -eq 'Disabled') {
    Write-Host "SQL server has publicNetworkAccess=Disabled; attempting temporary toggle to Enabled..."
    $toggleResult = az sql server update --resource-group $resourceGroup --name $ServerName --enable-public-network true 2>&1
    $pnaState = az sql server show --resource-group $resourceGroup --name $ServerName --query publicNetworkAccess -o tsv 2>$null
    if ($pnaState -eq 'Enabled') {
        $pnaRestoreNeeded = $true
        Write-Host "PNA toggled to Enabled for the duration of the deploy."
    }
    else {
        Write-Warning "Unable to enable public network access on $ServerName (likely blocked by Azure Policy)."
        Write-Warning "Skipping dacpac deploy. To apply the schema, run sqlpackage from a host with private-endpoint access (in-VNet ACI, VPN, or jump box):"
        Write-Warning "  sqlpackage /Action:Publish /SourceFile:$dacpacPath /TargetServerName:$sqlFqdn /TargetDatabaseName:$DatabaseName /UniversalAuthentication:True"
        Write-Warning "Or temporarily exempt the server from the Policy and rerun this script."
        exit 0
    }
}

Write-Host "Adding temporary firewall rule for $myIp..."
az sql server firewall-rule create --resource-group $resourceGroup --server $ServerName --name $firewallRuleName --start-ip-address $myIp --end-ip-address $myIp --output none 2>$null

# Also set connection policy to Proxy to avoid TLS redirect issues from outside Azure
az sql server conn-policy update --server $ServerName --resource-group $resourceGroup --connection-type Proxy --output none 2>$null

Write-Host "Server: $sqlFqdn"
Write-Host "Database: $DatabaseName"
Write-Host "Dacpac: $dacpacPath"

$token = az account get-access-token --resource "https://database.windows.net/" --query accessToken -o tsv
if (-not $token) {
    Write-Error "Failed to get SQL access token. Ensure you are logged in with 'az login'."
    exit 1
}

# Probe to detect the IP that SQL actually sees from this client. Outbound
# traffic may egress through a different NAT than api.ipify.org reports
# (e.g., corp VPN routed via Azure). Without this, the firewall rule we just
# added may not match. We catch the SqlException and parse the blocked IP.
Add-Type -AssemblyName System.Data
$probeIp = $null
$probeRuleName = $null
try {
    $probeCs = "Server=tcp:$sqlFqdn,1433;Database=master;Encrypt=True;TrustServerCertificate=False;Connection Timeout=15"
    $probeConn = New-Object System.Data.SqlClient.SqlConnection($probeCs)
    $probeConn.AccessToken = $token
    $probeConn.Open()
    $probeConn.Close()
}
catch [System.Data.SqlClient.SqlException] {
    if ($_.Exception.Message -match "Client with IP address '([^']+)' is not allowed") {
        $probeIp = $Matches[1]
    }
    else {
        Write-Warning "SQL probe failed with unexpected error: $($_.Exception.Message)"
    }
}

if ($probeIp -and $probeIp -ne $myIp) {
    # The probe and sqlpackage may egress on different IPs from the same NAT
    # pool (e.g., Microsoft corp NAT spans a /24). Allow the full /24 around
    # the probed IP for the duration of the deploy, then remove it.
    $octets = $probeIp.Split('.')
    $rangeStart = "$($octets[0]).$($octets[1]).$($octets[2]).0"
    $rangeEnd = "$($octets[0]).$($octets[1]).$($octets[2]).255"
    Write-Host "SQL sees connections from $probeIp (different from $myIp); allowing $rangeStart-$rangeEnd temporarily..."
    $probeRuleName = "azd-deploy-actual-$($octets[0])-$($octets[1])-$($octets[2])"
    az sql server firewall-rule create --resource-group $resourceGroup --server $ServerName --name $probeRuleName --start-ip-address $rangeStart --end-ip-address $rangeEnd --output none 2>$null
    Start-Sleep -Seconds 5
}

sqlpackage /Action:Publish `
    /SourceFile:"$dacpacPath" `
    /TargetServerName:"$sqlFqdn" `
    /TargetDatabaseName:"$DatabaseName" `
    /AccessToken:"$token" `
    /p:BlockOnPossibleDataLoss=False

$deployResult = $LASTEXITCODE

# Restore connection policy, remove temporary firewall rules, and revert PNA
Write-Host "Restoring connection policy and removing temporary firewall rule..."
az sql server conn-policy update --server $ServerName --resource-group $resourceGroup --connection-type Default --output none 2>$null
az sql server firewall-rule delete --resource-group $resourceGroup --server $ServerName --name $firewallRuleName --output none 2>$null
if ($probeRuleName) {
    az sql server firewall-rule delete --resource-group $resourceGroup --server $ServerName --name $probeRuleName --output none 2>$null
}
if ($pnaRestoreNeeded) {
    Write-Host "Reverting publicNetworkAccess to Disabled..."
    az sql server update --resource-group $resourceGroup --name $ServerName --enable-public-network false --output none 2>$null
}

if ($deployResult -ne 0) {
    Write-Error "dacpac deployment failed."
    exit 1
}

Write-Host "Database schema deployed successfully."
