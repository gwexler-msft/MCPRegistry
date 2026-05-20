#!/usr/bin/env pwsh
# Grant the managed identity data-plane access to the SQL database.
# Runs as a postprovision hook after azd provision.

Write-Host "Granting SQL data-plane access to managed identity..."

$envValues = azd env get-values --output json | ConvertFrom-Json
$sqlServer = $envValues.AZURE_SQL_SERVER_NAME
$sqlDatabase = $envValues.AZURE_SQL_DATABASE_NAME
$resourceGroup = $envValues.AZURE_RESOURCE_GROUP
$subscriptionId = $envValues.AZURE_SUBSCRIPTION_ID
$managedIdentityDisplayName = $envValues.AZURE_MANAGED_IDENTITY_NAME

if (-not $sqlServer -or -not $sqlDatabase -or -not $resourceGroup -or -not $subscriptionId) {
    Write-Error "Missing required azd env values (AZURE_SQL_SERVER_NAME, AZURE_SQL_DATABASE_NAME, AZURE_RESOURCE_GROUP, AZURE_SUBSCRIPTION_ID)."
    exit 1
}

if (-not $managedIdentityDisplayName) {
    Write-Error "Missing AZURE_MANAGED_IDENTITY_NAME in azd env. Re-run 'azd provision' after pulling the latest infra outputs."
    exit 1
}

# Pin az CLI to the same subscription azd is using; the user's default may differ.
az account set --subscription $subscriptionId --output none

$sqlFqdn = "${sqlServer}.database.windows.net"

Write-Host "SQL Server: $sqlFqdn"
Write-Host "Database: $sqlDatabase"
Write-Host "Identity: $managedIdentityDisplayName"

$token = az account get-access-token --resource "https://database.windows.net/" --query accessToken -o tsv
if (-not $token) {
    Write-Error "Failed to get SQL access token. Ensure you are logged in with 'az login'."
    exit 1
}

# When PNA=Disabled (often enforced by Azure Policy), public-path connection
# attempts return "Deny Public Network Access is set to Yes" regardless of
# firewall rules. Try a best-effort toggle to Enabled; if Policy blocks the
# toggle, skip the public-path grant with clear operator instructions
# rather than failing the azd pipeline.
$pnaState = az sql server show --resource-group $resourceGroup --name $sqlServer --query publicNetworkAccess -o tsv 2>$null
$pnaRestoreNeeded = $false
if ($pnaState -eq 'Disabled') {
    Write-Host "SQL server has publicNetworkAccess=Disabled; attempting temporary toggle to Enabled..."
    az sql server update --resource-group $resourceGroup --name $sqlServer --enable-public-network true --output none 2>$null
    $pnaState = az sql server show --resource-group $resourceGroup --name $sqlServer --query publicNetworkAccess -o tsv 2>$null
    if ($pnaState -eq 'Enabled') {
        $pnaRestoreNeeded = $true
        Write-Host "PNA toggled to Enabled for the duration of the grant."
    }
    else {
        Write-Warning "Unable to enable public network access on $sqlServer (likely blocked by Azure Policy)."
        Write-Warning "Skipping data-plane grant. To grant manually, run this script from a host with private-endpoint access (in-VNet ACI, VPN, or jump box):"
        Write-Warning "  ./scripts/grant-sql-access.ps1"
        Write-Warning "Or temporarily exempt the server from the Policy and rerun."
        exit 0
    }
}

# Add temporary firewall rule and set Proxy connection policy
$myIp = (Invoke-RestMethod -Uri "https://api.ipify.org" -TimeoutSec 10)
$firewallRuleName = "azd-grant-$($myIp.Replace('.', '-'))"
az sql server firewall-rule create --resource-group $resourceGroup --server $sqlServer --name $firewallRuleName --start-ip-address $myIp --end-ip-address $myIp --output none 2>$null
az sql server conn-policy update --server $sqlServer --resource-group $resourceGroup --connection-type Proxy --output none 2>$null

# Probe to detect the IP that SQL actually sees from this client. Outbound
# traffic may egress through a different NAT than api.ipify.org reports
# (e.g., corp VPN routed via Azure). Without this, the firewall rule we just
# added may not match. We catch the SqlException and parse the blocked IP.
Add-Type -AssemblyName System.Data
$probeIp = $null
$probeRuleName = $null
try {
    $probeCs = "Server=tcp:${sqlFqdn},1433;Database=master;Encrypt=True;TrustServerCertificate=False;Connection Timeout=15"
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
    # The probe and grant connection may egress on different IPs from the same NAT
    # pool (e.g., Microsoft corp NAT spans a /24). Allow the full /24 around
    # the probed IP for the duration of the operation.
    $octets = $probeIp.Split('.')
    $rangeStart = "$($octets[0]).$($octets[1]).$($octets[2]).0"
    $rangeEnd = "$($octets[0]).$($octets[1]).$($octets[2]).255"
    Write-Host "SQL sees connections from $probeIp (different from $myIp); allowing $rangeStart-$rangeEnd temporarily..."
    $probeRuleName = "azd-grant-actual-$($octets[0])-$($octets[1])-$($octets[2])"
    az sql server firewall-rule create --resource-group $resourceGroup --server $sqlServer --name $probeRuleName --start-ip-address $rangeStart --end-ip-address $rangeEnd --output none 2>$null
    Start-Sleep -Seconds 5
}

# Grant access using SqlClient with token auth
$grantSql = @"
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = '$managedIdentityDisplayName')
BEGIN
    CREATE USER [$managedIdentityDisplayName] FROM EXTERNAL PROVIDER;
END
ALTER ROLE db_datareader ADD MEMBER [$managedIdentityDisplayName];
ALTER ROLE db_datawriter ADD MEMBER [$managedIdentityDisplayName];
"@

$connStr = "Server=tcp:${sqlFqdn},1433;Database=${sqlDatabase};Encrypt=True;TrustServerCertificate=False;Connection Timeout=60;"
$conn = New-Object System.Data.SqlClient.SqlConnection($connStr)
$conn.AccessToken = $token
try {
    $conn.Open()
    $cmd = $conn.CreateCommand()
    $cmd.CommandText = $grantSql
    $cmd.ExecuteNonQuery() | Out-Null
    Write-Host "Granted db_datareader + db_datawriter to $managedIdentityDisplayName"
}
catch {
    Write-Error "Failed to grant SQL access: $_"
    exit 1
}
finally {
    $conn.Close()
}

# Restore and clean up
az sql server conn-policy update --server $sqlServer --resource-group $resourceGroup --connection-type Default --output none 2>$null
az sql server firewall-rule delete --resource-group $resourceGroup --server $sqlServer --name $firewallRuleName --output none 2>$null
if ($probeRuleName) {
    az sql server firewall-rule delete --resource-group $resourceGroup --server $sqlServer --name $probeRuleName --output none 2>$null
}
if ($pnaRestoreNeeded) {
    Write-Host "Reverting publicNetworkAccess to Disabled..."
    az sql server update --resource-group $resourceGroup --name $sqlServer --enable-public-network false --output none 2>$null
}

Write-Host "SQL data-plane access granted successfully."
