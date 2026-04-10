# MCP Registry — Developer Onboarding & Deployment Guide

## Table of Contents

1. [Overview](#overview)
2. [Prerequisites](#prerequisites)
3. [Repository Structure](#repository-structure)
4. [Local Development Setup](#local-development-setup)
5. [Building & Running Locally](#building--running-locally)
6. [API Endpoints](#api-endpoints)
7. [Azure Deployment](#azure-deployment)
8. [Post-Deployment: Schema & Data](#post-deployment-schema--data)
9. [Redeployment & Updates](#redeployment--updates)
10. [Troubleshooting](#troubleshooting)

---

## Overview

MCP Registry is a self-hosted implementation of the [Model Context Protocol (MCP) Server Registry API](https://docs.github.com/en/copilot/how-tos/administer-copilot/manage-mcp-usage/configure-mcp-registry#option-1-self-hosting-an-mcp-registry).

- **Runtime:** ASP.NET Core 10 (.NET 10)
- **Database:** SQL Server (LocalDB for dev, Azure SQL Serverless for production)
- **Hosting:** Azure Container Apps (containerized)
- **Infrastructure as Code:** Bicep via Azure Developer CLI (azd)
- **Authentication:** Microsoft Entra ID (no SQL passwords — managed identity only)

---

## Prerequisites

Install the following before starting:

| Tool | Version | Install |
|------|---------|---------|
| **.NET SDK** | 10.0+ | https://dotnet.microsoft.com/download/dotnet/10.0 |
| **SQL Server LocalDB** | Included with Visual Studio, or install separately | https://learn.microsoft.com/sql/database-engine/configure-windows/sql-server-express-localdb |
| **Azure CLI** | Latest | `winget install Microsoft.AzureCLI` |
| **Azure Developer CLI (azd)** | Latest | `winget install Microsoft.Azd` |
| **sqlpackage** | Latest | `dotnet tool install -g microsoft.sqlpackage` |
| **Git** | Latest | https://git-scm.com/ |

### Verify installations

```powershell
dotnet --version          # Should show 10.x
sqllocaldb info           # Should list MSSQLLocalDB
az --version              # Azure CLI version
azd version               # Azure Developer CLI version
sqlpackage /version       # Should show sqlpackage version
```

> **Note:** After installing `azd` via winget, you may need to restart your terminal or run:
> ```powershell
> $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
> ```

---

## Repository Structure

```
MCPRegistry/
├── MCPRegistry.slnx                  # Solution file
├── azd/                              # Azure Developer CLI deployment (run azd from here)
│   ├── azure.yaml                    # azd configuration
│   ├── infra/
│   │   ├── main.bicep                # Bicep entry point (subscription-scoped)
│   │   ├── main.parameters.json      # Parameter bindings for azd
│   │   └── modules/
│   │       ├── naming.bicep          # CAF naming convention functions
│   │       └── resources.bicep       # All Azure resources (AVM modules)
│   └── scripts/
│       ├── deploy-db.ps1             # Post-provision: deploy schema via dacpac (Windows)
│       ├── deploy-db.sh              # Post-provision: deploy schema via dacpac (Linux/macOS)
│       ├── grant-sql-access.ps1      # Post-provision: grant managed identity SQL access (Windows)
│       └── grant-sql-access.sh       # Post-provision: grant managed identity SQL access (Linux/macOS)
├── data/
│   ├── sample-seed-data.json         # Sample MCP servers for seeding
│   └── new-version-data.json         # Example payload for adding new versions
├── scripts/
│   └── DeploySchema/                 # Standalone .NET tool for schema deployment (non-azd)
│       ├── DeploySchema.csproj
│       └── Program.cs
├── src/
│   ├── MCPRegistry/                  # ASP.NET Core Web API
│   │   ├── MCPRegistry.csproj
│   │   ├── Program.cs
│   │   ├── Dockerfile
│   │   ├── .dockerignore
│   │   ├── appsettings.json
│   │   ├── appsettings.Development.json
│   │   ├── MCPRegistry.http          # REST Client test file
│   │   ├── Controllers/
│   │   ├── Data/
│   │   ├── Models/
│   │   └── Services/
│   └── MCPRegistryDatabase/          # SQL Server Database Project (SDK-style, produces .dacpac)
│       ├── MCPRegistryDatabase.sqlproj
│       ├── Tables/
│       │   └── dbo.Servers.sql
│       └── Triggers/
│           └── dbo.TRG_Servers_UpdateUpdatedAt.sql
```

---

## Local Development Setup

### 1. Clone the repository

```powershell
git clone <repo-url>
cd MCPRegistry
```

### 2. Start LocalDB

```powershell
sqllocaldb start MSSQLLocalDB
```

### 3. Create the local database

```powershell
sqlcmd -S "(localdb)\MSSQLLocalDB" -Q "IF DB_ID('MCPRegistry') IS NULL CREATE DATABASE MCPRegistry;"
```

### 4. Deploy the schema

Run the table creation script:

```powershell
sqlcmd -S "(localdb)\MSSQLLocalDB" -d MCPRegistry -Q "
IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'Servers')
BEGIN
    CREATE TABLE Servers (
        ServerName NVARCHAR(255) NOT NULL,
        [Version] NVARCHAR(255) NOT NULL,
        [Status] NVARCHAR(50) NOT NULL DEFAULT 'active',
        AddedAt DATETIMEOFFSET NOT NULL DEFAULT SYSDATETIMEOFFSET(),
        UpdatedAt DATETIMEOFFSET NOT NULL DEFAULT SYSDATETIMEOFFSET(),
        IsLatest BIT NOT NULL DEFAULT 1,
        [Value] NVARCHAR(MAX) NULL,
        CONSTRAINT PK_Servers PRIMARY KEY (ServerName, [Version]),
        CONSTRAINT CHK_Servers_Status CHECK ([Status] IN ('active', 'deprecated', 'deleted')),
        CONSTRAINT CHK_Servers_ServerNameFormat CHECK (ServerName LIKE '[a-zA-Z0-9]%/[a-zA-Z0-9]%'),
        CONSTRAINT CHK_Servers_VersionNotEmpty CHECK (LEN(LTRIM(RTRIM([Version]))) > 0)
    );
END"
```

Create indexes:

```powershell
sqlcmd -S "(localdb)\MSSQLLocalDB" -d MCPRegistry -Q "
SET QUOTED_IDENTIFIER ON;
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IDX_Servers_ServerName') CREATE INDEX IDX_Servers_ServerName ON Servers(ServerName);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IDX_Servers_ServerNameVersion') CREATE INDEX IDX_Servers_ServerNameVersion ON Servers(ServerName, [Version]);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IDX_Servers_ServerNameLatest') CREATE INDEX IDX_Servers_ServerNameLatest ON Servers(ServerName, IsLatest) WHERE IsLatest = 1;
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IDX_Servers_Status') CREATE INDEX IDX_Servers_Status ON Servers([Status]);"
```

Create the update trigger:

```powershell
sqlcmd -S "(localdb)\MSSQLLocalDB" -d MCPRegistry -i "src\MCPRegistryDatabase\Triggers\dbo.TRG_Servers_UpdateUpdatedAt.sql"
```

### 5. Seed sample data

```powershell
$json = Get-Content "data\sample-seed-data.json" -Raw | ConvertFrom-Json
$connStr = "Server=(localdb)\MSSQLLocalDB;Database=MCPRegistry;Trusted_Connection=True;TrustServerCertificate=True;"
$conn = New-Object System.Data.SqlClient.SqlConnection($connStr)
$conn.Open()
foreach ($item in $json) {
    $cmd = $conn.CreateCommand()
    $cmd.CommandText = "IF NOT EXISTS (SELECT 1 FROM Servers WHERE ServerName=@Name AND Version=@Ver) INSERT INTO Servers (ServerName, Version, [Value], IsLatest) VALUES (@Name, @Ver, @Val, 1)"
    $cmd.Parameters.AddWithValue("@Name", $item.name) | Out-Null
    $cmd.Parameters.AddWithValue("@Ver", $item.version) | Out-Null
    $cmd.Parameters.AddWithValue("@Val", ($item | ConvertTo-Json -Depth 20 -Compress)) | Out-Null
    $cmd.ExecuteNonQuery() | Out-Null
    Write-Host "Inserted: $($item.name) v$($item.version)"
}
$conn.Close()
```

### 6. Verify the connection string

The local connection string is configured in `src/MCPRegistry/appsettings.Development.json`:

```json
{
  "ConnectionStrings": {
    "DefaultConnection": "Server=(localdb)\\MSSQLLocalDB;Database=MCPRegistry;Trusted_Connection=True;TrustServerCertificate=True;"
  }
}
```

> **Do not** commit secrets or production connection strings to this file.

---

## Building & Running Locally

### Build the solution

```powershell
dotnet build
```

### Run the API

```powershell
dotnet run --project src/MCPRegistry
```

The API will be available at:
- **HTTP:** http://localhost:5103
- **HTTPS:** https://localhost:7160
- **Swagger UI:** http://localhost:5103/swagger

### Test with REST Client

Open `src/MCPRegistry/MCPRegistry.http` in VS Code with the REST Client extension to execute test requests.

### Test with curl/PowerShell

```powershell
# List all servers
Invoke-RestMethod http://localhost:5103/v0.1/servers

# Search for servers
Invoke-RestMethod "http://localhost:5103/v0.1/servers?search=azure"

# Get versions for a server (URL-encode the / as %2F)
Invoke-RestMethod http://localhost:5103/v0.1/servers/com.microsoft%2Fazure/versions

# Get latest version
Invoke-RestMethod http://localhost:5103/v0.1/servers/com.microsoft%2Fazure/versions/latest
```

---

## API Endpoints

All endpoints are prefixed with `/v0.1`. Swagger UI is available at `/swagger` on any deployed instance.

> **Important:** Server names contain `/` (e.g., `com.microsoft/azure`). When used in URL paths, encode as `%2F`.

| Method | Path | Description | Request Body | Response |
|--------|------|-------------|-------------|----------|
| `GET` | `/v0.1/servers` | List all servers | — | `ServerList` |
| `GET` | `/v0.1/servers?search={term}` | Search servers by name, title, or description | — | `ServerList` |
| `GET` | `/v0.1/servers?version=latest` | List only latest versions | — | `ServerList` |
| `GET` | `/v0.1/servers?limit={n}&cursor={c}` | Paginate results | — | `ServerList` with `nextCursor` |
| `GET` | `/v0.1/servers?updated_since={iso8601}` | Filter by update time | — | `ServerList` |
| `GET` | `/v0.1/servers/{serverName}/versions` | List all versions of a server | — | `ServerList` |
| `GET` | `/v0.1/servers/{serverName}/versions/{version}` | Get a specific version | — | `ServerResponse` |
| `GET` | `/v0.1/servers/{serverName}/versions/latest` | Get the latest version | — | `ServerResponse` |
| `POST` | `/v0.1/servers` | Add one or more servers | `ServerDetail[]` (JSON array) | `201 Created` |
| `DELETE` | `/v0.1/servers/{serverName}/versions/{version}` | Soft-delete a server version (sets status to "deleted") | — | `200 OK` |

> **Note on immutability:** Per the [MCP registry specification](https://modelcontextprotocol.io), server metadata is immutable except for the `status` field. To publish changes, add a new version. Use `DELETE` to mark a version as "deleted" (spam, malware, or policy violation). Aggregators should keep status in sync.

### Example: Add a server (POST)

```bash
POST /v0.1/servers
Content-Type: application/json

[
  {
    "name": "com.example/my-mcp-server",
    "version": "1.0.0",
    "description": "My custom MCP server",
    "title": "My MCP Server"
  }
]
```

---

## Azure Deployment

### Architecture

| Resource | Service | SKU |
|----------|---------|-----|
| API | Azure Container Apps | Consumption (scales to zero) |
| Database | Azure SQL Database | Serverless GP_S_Gen5 (auto-pauses after 60 min) |
| Container Registry | Azure Container Registry | Basic |
| Logging | Log Analytics Workspace | Per-GB |
| Auth | User-Assigned Managed Identity | Entra-only SQL auth |

### Step 1: Log in to Azure

```powershell
az login
azd auth login
```

### Step 2: Initialize the azd environment

All `azd` commands are run from the `azd/` folder:

```powershell
cd azd
azd init -e <environment-name>
```

Replace `<environment-name>` with your desired name (e.g., `mcpregistry-prod`).

> **Note:** The `azd/` folder contains all Azure deployment files (Bicep, scripts, azure.yaml). The application source code remains in `src/`. Customers who don't use azd can use the Bicep templates in `azd/infra/` directly with `az deployment` or other tooling.

### Step 3: Configure environment variables

```powershell
# Set Azure subscription and region
azd env set AZURE_SUBSCRIPTION_ID "<your-subscription-id>"
azd env set AZURE_LOCATION "<region>"   # e.g., centralus, eastus2

# Set your Entra ID principal for SQL admin
azd env set AZURE_PRINCIPAL_ID $(az ad signed-in-user show --query id -o tsv)
azd env set AZURE_PRINCIPAL_NAME $(az ad signed-in-user show --query displayName -o tsv)
```

### Step 3b: Customize resource names (optional)

By default, all resources are named using [Azure CAF naming conventions](https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/ready/azure-best-practices/resource-abbreviations) with the pattern `{prefix}-{workload}-{suffix}`. You can customize the workload identifier or override individual resource names to meet your organization's naming policies.

**Change the workload identifier** (affects all default names):

```powershell
azd env set AZURE_WORKLOAD_NAME "myregistry"
# Results in names like: log-myregistry-a34srx, sql-myregistry-a34srx, etc.
```

**Override individual resource names** (for full control):

| Environment Variable | Resource | Default Pattern | Example Override |
|---------------------|----------|-----------------|------------------|
| `AZURE_RESOURCE_GROUP_NAME` | Resource Group | `rg-{envName}` | `rg-prod-mcpregistry-eastus2` |
| `AZURE_LOG_ANALYTICS_NAME` | Log Analytics Workspace | `log-{workload}-{suffix}` | `log-prod-registry-01` |
| `AZURE_CONTAINER_REGISTRY_NAME` | Container Registry | `cr{workload}{suffix}` | `crprodregistry01` |
| `AZURE_MANAGED_IDENTITY_NAME` | Managed Identity | `id-{workload}-{suffix}` | `id-prod-registry-01` |
| `AZURE_CONTAINER_APPS_ENV_NAME` | Container Apps Environment | `cae-{workload}-{suffix}` | `cae-prod-registry-01` |
| `AZURE_SQL_SERVER_NAME` | SQL Server | `sql-{workload}-{suffix}` | `sql-prod-registry-01` |
| `AZURE_SQL_DATABASE_NAME` | SQL Database | `MCPRegistry` | `McpRegistryProd` |
| `AZURE_CONTAINER_APP_NAME` | Container App | `ca-{workload}-{suffix}` | `ca-prod-registry-01` |

```powershell
# Example: override specific resource names
azd env set AZURE_RESOURCE_GROUP_NAME "rg-prod-mcpregistry"
azd env set AZURE_SQL_SERVER_NAME "sql-prod-mcpregistry-01"
azd env set AZURE_CONTAINER_APP_NAME "ca-prod-mcpregistry-01"
```

> **Note:** Container Registry names must be alphanumeric only (no dashes), 5-50 characters. SQL Server names must be globally unique.

### Step 4: Provision Azure resources

```powershell
azd provision
```

This creates:
- Resource group `rg-<environment-name>`
- Azure SQL Server + Database (Entra-only auth, serverless)
- Container Registry
- Container Apps Environment + Container App
- User-assigned Managed Identity
- Log Analytics Workspace
- SQL firewall rule for Azure services

### Step 5: Deploy the application

```powershell
azd deploy
```

This builds the Docker image, pushes it to ACR, and updates the Container App.

The API URL will be printed at the end, e.g.:
```
Endpoint: https://ca-mcpreg-xxxxxx.xxxxxxxx.centralus.azurecontainerapps.io/
```

### Step 6: Deploy the database schema

The database is created empty by `azd provision`. The schema is deployed using the SQL project's `.dacpac` and `sqlpackage`.

> **Prerequisite:** Install `sqlpackage` if not already installed:
> ```powershell
> dotnet tool install -g microsoft.sqlpackage
> ```

```powershell
# Add your IP to the SQL firewall (required for local access)
$myIp = (Invoke-RestMethod -Uri "https://api.ipify.org")
az sql server firewall-rule create `
  --resource-group rg-<environment-name> `
  --server <sql-server-name> `
  --name AllowMyIP `
  --start-ip-address $myIp `
  --end-ip-address $myIp

# If connecting from outside Azure fails with TLS errors, temporarily set Proxy mode:
az sql server conn-policy update `
  --server <sql-server-name> `
  --resource-group rg-<environment-name> `
  --connection-type Proxy

# Build the dacpac and deploy (run from repo root)
dotnet build src/MCPRegistryDatabase/MCPRegistryDatabase.sqlproj -c Release

$token = az account get-access-token --resource "https://database.windows.net/" --query accessToken -o tsv

sqlpackage /Action:Publish `
  /SourceFile:"src/MCPRegistryDatabase/bin/Release/MCPRegistryDatabase.dacpac" `
  /TargetServerName:"<sql-server-name>.database.windows.net" `
  /TargetDatabaseName:"MCPRegistry" `
  /AccessToken:"$token" `
  /p:BlockOnPossibleDataLoss=False
```

> **Tip:** The `azd/scripts/deploy-db.ps1` script automates the above steps and is also called automatically by `azd provision` via the postprovision hook.

### Step 7: Grant managed identity SQL access

This is handled automatically by the postprovision hook in `azd/azure.yaml`. To run manually:

```powershell
./azd/scripts/grant-sql-access.ps1
```

### Step 8: Seed data (optional)

Once the app is deployed and running, seed sample servers using the POST API and the included sample data file:

```powershell
$base = "<your-container-app-url>"   # e.g., https://ca-mcpreg-xxxxx.xxxxxxxx.centralus.azurecontainerapps.io
$body = Get-Content "data/sample-seed-data.json" -Raw
Invoke-RestMethod -Method POST -Uri "$base/v0.1/servers" -Body $body -ContentType "application/json"
```

You can also add your own servers by creating a JSON array following the same format as `data/sample-seed-data.json` or `data/new-version-data.json`:

```powershell
$body = @'
[
  {
    "name": "com.example/my-mcp-server",
    "version": "1.0.0",
    "description": "My custom MCP server",
    "title": "My MCP Server"
  }
]
'@
Invoke-RestMethod -Method POST -Uri "$base/v0.1/servers" -Body $body -ContentType "application/json"
```

### Step 9: Restore connection policy and clean up firewall

```powershell
# Restore Default connection policy (better performance from within Azure)
az sql server conn-policy update `
  --server <sql-server-name> `
  --resource-group rg-<environment-name> `
  --connection-type Default

# Optionally remove your IP from the firewall
az sql server firewall-rule delete `
  --resource-group rg-<environment-name> `
  --server <sql-server-name> `
  --name AllowMyIP
```

---

## Redeployment & Updates

All `azd` commands should be run from the `azd/` folder.

### Code changes only

```powershell
cd azd
azd deploy
```

### Infrastructure changes (Bicep modifications)

```powershell
azd provision
azd deploy
```

### Full redeploy (provision + deploy)

```powershell
azd up
```

### Tear down all Azure resources

```powershell
azd down --purge
```

> **Warning:** This deletes all resources including the database. Make sure to back up data first.

---

## Troubleshooting

### azd not recognized after install

Restart your terminal or run:
```powershell
$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
```

### azd must run from the `azd/` folder

All `azd` commands (`azd init`, `azd up`, `azd deploy`, `azd provision`) must be run from the `azd/` directory, not the repo root. If you see `ERROR: no project exists`, you're in the wrong folder.

```powershell
cd azd
azd up
```

### Container App fails with MANIFEST_UNKNOWN during first provision

The initial `azd provision` may fail because the Container App references an image that hasn't been pushed yet. The Bicep uses a placeholder image (`mcr.microsoft.com/azuredocs/containerapps-helloworld:latest`) for the first provisioning. If you see this error, run `azd provision` again.

### Container App fails with UNAUTHORIZED pulling from ACR

If the Container App can't pull images from ACR, the registry credentials may not be configured correctly. The Bicep uses ACR admin credentials. Verify admin user is enabled:
```powershell
az acr update --name <acr-name> --admin-enabled true
```
Then re-provision: `azd provision`

### TLS pre-login handshake errors connecting to Azure SQL

This happens when connecting from outside Azure with the **Default** connection policy. The `deploy-db.ps1` script handles this automatically by temporarily switching to **Proxy** mode. If running manually:
```powershell
az sql server conn-policy update --server <sql-server> --resource-group <rg> --connection-type Proxy
```
Remember to switch back to **Default** after your operation (Proxy has higher latency).

### dacpac deployment fails with "target platform" error

If you see: *"A project which specifies SQL Server 2025 as the target platform cannot be published to Microsoft Azure SQL Database v12"*

The SQL project's `DSP` must be set to Azure SQL Database:
```xml
<DSP>Microsoft.Data.Tools.Schema.Sql.SqlAzureV12DatabaseSchemaProvider</DSP>
```
Not `Sql170DatabaseSchemaProvider` (which targets on-premises SQL Server 2022+).

### Database auto-paused (serverless) — slow first connection

The Azure SQL Serverless database auto-pauses after 60 minutes of inactivity. The first connection after a pause may take **30-90 seconds** to resume. This affects:
- The dacpac deployment (`Initializing deployment` appears to hang)
- The first API request after idle

This is by design for cost optimization. The `deploy-db.ps1` script has retry logic built in.

### SQL firewall blocks connections

The `deploy-db.ps1` and `grant-sql-access.ps1` scripts automatically add and remove temporary firewall rules for your IP. If running manually, add your IP first:
```powershell
$myIp = (Invoke-RestMethod -Uri "https://api.ipify.org")
az sql server firewall-rule create --resource-group <rg> --server <sql-server> `
  --name AllowMyIP --start-ip-address $myIp --end-ip-address $myIp
```

### PowerShell 5 vs PowerShell 7 warnings

The azd hooks detect `pwsh` (PS7) syntax in scripts. If only PowerShell 5.1 is installed, azd falls back to `powershell`. Our scripts are compatible with PS5, but be aware of these PS5 limitations:
- `Join-Path` only accepts 2 arguments (not multiple like PS7)
- `Invoke-Sqlcmd` is not available (we use `sqlpackage` and `DeploySchema` tool instead)

Install PS7 to avoid these warnings: `winget install Microsoft.PowerShell`

### ConnectionString property not initialized

Ensure `appsettings.Development.json` has the `DefaultConnection` string set for local development. For Azure, the connection string is injected via the Container App environment variables in Bicep.

### Invalid column name errors

If you see `Invalid column name 'CreatedAt'` or similar, ensure you're using the latest code. The table uses `AddedAt` (not `CreatedAt`).

### Post-provision hooks fail but infrastructure succeeds

The postprovision hooks (dacpac deploy + SQL grant) may fail while the Azure resources are provisioned correctly. You can re-run just the hooks with:
```powershell
cd azd
azd provision    # re-triggers postprovision hooks
```
Or run the scripts manually:
```powershell
./azd/scripts/deploy-db.ps1
./azd/scripts/grant-sql-access.ps1
```

---

## Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| **Entra-only SQL auth** | No passwords to manage or rotate; managed identity handles auth automatically |
| **Serverless SQL** | Auto-pauses when idle — cost-effective for dev/POC workloads |
| **Container Apps** | Scales to zero, no infrastructure management, built-in ingress/TLS |
| **Dapper (not EF Core)** | Lightweight data access — the JSON is stored as-is in the `Value` column |
| **SDK-style sqlproj** | Enables `dotnet build` and dacpac output without Visual Studio or SSDT |
| **Azure Verified Modules (AVM)** | Standardized, tested Bicep modules maintained by Microsoft — preferred over raw ARM resources |
| **CAF naming conventions** | Default resource names follow Azure Cloud Adoption Framework; customers can override any name |
| **azd/ folder isolation** | Azure deployment files are separate from application code; customers not using azd can use Bicep directly |
| **dacpac for schema deployment** | Idempotent, declarative schema management via the SQL project — no manual migration scripts |
| **Immutable server metadata** | Per MCP spec: metadata is immutable except status. New versions are added via POST, not updated |
| **Temporary firewall rules** | Auto-added/removed during deployment — no persistent client IP exposure on SQL Server |

---

## MCP Registry Specification Notes

Per the [Model Context Protocol registry specification](https://modelcontextprotocol.io):

- **Server metadata is immutable** except for the `status` field (`active`, `deprecated`, `deleted`)
- To publish changes, add a new version via `POST /v0.1/servers`
- The `DELETE` endpoint sets status to `"deleted"` (soft-delete) — it does not remove data
- `"deleted"` status indicates a server violated moderation policy (spam, malware, illegal)
- Aggregators should keep their copy of each server's status up to date
