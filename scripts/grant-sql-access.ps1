#!/usr/bin/env pwsh
# Grant the managed identity data-plane access to the SQL database.
# Runs as a postprovision hook after azd provision.

Write-Host "Granting SQL data-plane access to managed identity..."

$envValues = azd env get-values --output json | ConvertFrom-Json
$sqlServer = $envValues.AZURE_SQL_SERVER_NAME
$sqlDatabase = $envValues.AZURE_SQL_DATABASE_NAME
$resourceGroup = $envValues.AZURE_RESOURCE_GROUP

if (-not $sqlServer -or -not $sqlDatabase -or -not $resourceGroup) {
    Write-Error "Missing required azd env values (AZURE_SQL_SERVER_NAME, AZURE_SQL_DATABASE_NAME, AZURE_RESOURCE_GROUP)."
    exit 1
}

$identityName = $envValues.SERVICE_WEB_NAME
if (-not $identityName) {
    Write-Error "Missing SERVICE_WEB_NAME in azd env."
    exit 1
}

$managedIdentityName = az containerapp show --name $identityName --resource-group $resourceGroup --query "identity.userAssignedIdentities | keys(@) | [0]" -o tsv
$managedIdentityDisplayName = ($managedIdentityName -split '/')[-1]

$sqlFqdn = "${sqlServer}.database.windows.net"

Write-Host "SQL Server: $sqlFqdn"
Write-Host "Database: $sqlDatabase"
Write-Host "Identity: $managedIdentityDisplayName"

$token = az account get-access-token --resource "https://database.windows.net/" --query accessToken -o tsv
if (-not $token) {
    Write-Error "Failed to get SQL access token. Ensure you are logged in with 'az login'."
    exit 1
}

$sqlCmd = @"
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = '$managedIdentityDisplayName')
BEGIN
    CREATE USER [$managedIdentityDisplayName] FROM EXTERNAL PROVIDER;
END
ALTER ROLE db_datareader ADD MEMBER [$managedIdentityDisplayName];
ALTER ROLE db_datawriter ADD MEMBER [$managedIdentityDisplayName];
"@

Invoke-Sqlcmd -ServerInstance $sqlFqdn -Database $sqlDatabase -AccessToken $token -Query $sqlCmd
if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne $null) {
    Write-Error "Failed to grant SQL access."
    exit 1
}

Write-Host "SQL data-plane access granted successfully."
