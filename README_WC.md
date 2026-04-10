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
| **Git** | Latest | https://git-scm.com/ |

### Verify installations

```powershell
dotnet --version          # Should show 10.x
sqllocaldb info           # Should list MSSQLLocalDB
az --version              # Azure CLI version
azd version               # Azure Developer CLI version
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
├── azure.yaml                        # Azure Developer CLI configuration
├── data/
│   ├── sample-seed-data.json         # Sample MCP servers for seeding
│   └── new-version-data.json         # Example payload for adding new versions
├── infra/
│   ├── main.bicep                    # Bicep entry point (subscription-scoped)
│   ├── main.parameters.json          # Parameter bindings for azd
│   └── modules/
│       └── resources.bicep           # All Azure resources (Container Apps, SQL, ACR, etc.)
├── scripts/
│   ├── grant-sql-access.ps1          # Post-provision: grants managed identity SQL access (Windows)
│   ├── grant-sql-access.sh           # Post-provision: grants managed identity SQL access (Linux/macOS)
│   └── DeploySchema/                 # .NET tool to deploy database schema to Azure SQL
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
│   └── MCPRegistryDatabase/          # SQL Server Database Project (SDK-style)
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
| `PUT` | `/v0.1/servers/{serverName}/versions/{version}` | Update a server version | `ServerDetail` (JSON object) | `200 OK` |
| `DELETE` | `/v0.1/servers/{serverName}/versions/{version}` | Soft-delete a server version | — | `200 OK` |

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

### Example: Update a server (PUT)

```bash
PUT /v0.1/servers/com.example%2Fmy-mcp-server/versions/1.0.0
Content-Type: application/json

{
  "name": "com.example/my-mcp-server",
  "version": "1.0.0",
  "description": "Updated description for my MCP server",
  "title": "My MCP Server (Updated)"
}
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

```powershell
azd init -e <environment-name>
```

Replace `<environment-name>` with your desired name (e.g., `mcpregistry-prod`).

### Step 3: Configure environment variables

```powershell
# Set Azure subscription and region
azd env set AZURE_SUBSCRIPTION_ID "<your-subscription-id>"
azd env set AZURE_LOCATION "<region>"   # e.g., centralus, eastus2

# Set your Entra ID principal for SQL admin
azd env set AZURE_PRINCIPAL_ID $(az ad signed-in-user show --query id -o tsv)
azd env set AZURE_PRINCIPAL_NAME $(az ad signed-in-user show --query displayName -o tsv)
```

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

The database is created empty. Deploy the schema using the included tool:

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

# Get an access token and deploy schema
$token = az account get-access-token --resource "https://database.windows.net/" --query accessToken -o tsv
$env:SQL_TOKEN = $token
$env:SQL_SERVER = "<sql-server-name>.database.windows.net"
$env:SQL_DB = "MCPRegistry"

dotnet run --project scripts/DeploySchema
```

### Step 7: Grant managed identity SQL access

```powershell
# Get the managed identity name from the Container App
$identityResource = az containerapp show `
  --name <container-app-name> `
  --resource-group rg-<environment-name> `
  --query "identity.userAssignedIdentities | keys(@) | [0]" -o tsv
$identityName = ($identityResource -split '/')[-1]

# Run the schema tool with SQL_IDENTITY set
$env:SQL_IDENTITY = $identityName
$token = az account get-access-token --resource "https://database.windows.net/" --query accessToken -o tsv
$env:SQL_TOKEN = $token
dotnet run --project scripts/DeploySchema
```

### Step 8: Seed data (optional)

```powershell
$json = Get-Content "data\sample-seed-data.json" -Raw | ConvertFrom-Json
$token = az account get-access-token --resource "https://database.windows.net/" --query accessToken -o tsv
$conn = New-Object System.Data.SqlClient.SqlConnection
$conn.ConnectionString = "Server=tcp:<sql-server-name>.database.windows.net,1433;Database=MCPRegistry;Encrypt=True;TrustServerCertificate=True;"
$conn.AccessToken = $token
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

### Code changes only

```powershell
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

### Container App fails with MANIFEST_UNKNOWN during first provision

The initial `azd provision` may fail because the Container App references an image that hasn't been pushed yet. The Bicep uses a placeholder image (`mcr.microsoft.com/azuredocs/containerapps-helloworld:latest`) for the first provisioning. If you see this error, run `azd provision` again.

### TLS pre-login handshake errors connecting to Azure SQL

This happens when connecting from outside Azure with the Default connection policy. Temporarily switch to Proxy mode:
```powershell
az sql server conn-policy update --server <sql-server> --resource-group <rg> --connection-type Proxy
```
Remember to switch back to Default after completing your operation.

### Database auto-paused (serverless)

The Azure SQL Serverless database auto-pauses after 60 minutes of inactivity. The first request after a pause may take 30-60 seconds to resume. This is by design for cost optimization.

### ConnectionString property not initialized

Ensure `appsettings.Development.json` has the `DefaultConnection` string set for local development. For Azure, the connection string is injected via the Container App environment variables in Bicep.

### Invalid column name errors

If you see `Invalid column name 'CreatedAt'` or similar, ensure you're using the latest code. The table uses `AddedAt` (not `CreatedAt`).

---

## Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| **Entra-only SQL auth** | No passwords to manage or rotate; managed identity handles auth automatically |
| **Serverless SQL** | Auto-pauses when idle — cost-effective for dev/POC workloads |
| **Container Apps** | Scales to zero, no infrastructure management, built-in ingress/TLS |
| **Dapper (not EF Core)** | Lightweight data access — the JSON is stored as-is in the `Value` column |
| **SDK-style sqlproj** | Enables `dotnet build` without Visual Studio or SSDT installed |
