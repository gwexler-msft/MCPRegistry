# MCP Registry — Developer Onboarding & Deployment Guide

## Table of Contents

1. [Overview](#overview)
2. [Prerequisites](#prerequisites)
3. [Repository Structure](#repository-structure)
4. [Local Development Setup](#local-development-setup)
5. [Building & Running Locally](#building--running-locally)
6. [API Endpoints](#api-endpoints)
7. [Calling the API as a Client](#calling-the-api-as-a-client)
8. [Azure Deployment](#azure-deployment)
9. [Post-Deployment: Schema & Data](#post-deployment-schema--data)
10. [Redeployment & Updates](#redeployment--updates)
11. [Troubleshooting](#troubleshooting)
12. [Key Design Decisions](#key-design-decisions)
13. [MCP Registry Specification Notes](#mcp-registry-specification-notes)
14. [Production Hardening](#production-hardening)

---

## Overview

MCP Registry is a self-hosted implementation of the [Model Context Protocol (MCP) Server Registry API](https://docs.github.com/en/copilot/how-tos/administer-copilot/manage-mcp-usage/configure-mcp-registry#option-1-self-hosting-an-mcp-registry).

- **Runtime:** ASP.NET Core 10 (.NET 10)
- **Database:** SQL Server (Docker container for dev, Azure SQL Serverless for production)
- **Hosting:** Azure Container Apps (containerized)
- **Infrastructure as Code:** Bicep via Azure Developer CLI (azd)
- **Authentication:** Microsoft Entra ID (no SQL passwords — managed identity only)

---

## Prerequisites

Install the following before starting:

| Tool | Version | Install |
|------|---------|---------|
| **.NET SDK** | 10.0+ | https://dotnet.microsoft.com/download/dotnet/10.0 |
| **Docker** | Latest | https://docs.docker.com/get-docker/ |
| **Azure CLI** | Latest | `winget install Microsoft.AzureCLI` |
| **Azure Developer CLI (azd)** | Latest | `winget install Microsoft.Azd` |
| **sqlpackage** | Latest | `dotnet tool install -g microsoft.sqlpackage` |
| **Git** | Latest | https://git-scm.com/ |

### Verify installations

```powershell
dotnet --version          # Should show 10.x
docker --version          # Docker version
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

### 2. Start SQL Server via Docker

```powershell
docker run -e "ACCEPT_EULA=Y" -e "MSSQL_SA_PASSWORD=YourStrong!Passw0rd" -p 1433:1433 --name mcpregistry-sql -d mcr.microsoft.com/mssql/server:2022-latest
```

### 3. Deploy the schema via dacpac

Build the SQL Database Project and publish it to the local Docker SQL Server:

```powershell
dotnet build src/MCPRegistryDatabase/MCPRegistryDatabase.sqlproj -c Release

sqlpackage /Action:Publish `
  /SourceFile:"src/MCPRegistryDatabase/bin/Release/MCPRegistryDatabase.dacpac" `
  /TargetServerName:"localhost,1433" `
  /TargetDatabaseName:"MCPRegistry" `
  /TargetUser:"sa" `
  /TargetPassword:"YourStrong!Passw0rd" `
  /TargetTrustServerCertificate:True
```

### 4. Seed sample data

```powershell
$json = Get-Content "data\sample-seed-data.json" -Raw | ConvertFrom-Json
$connStr = "Server=localhost,1433;Database=MCPRegistry;User Id=sa;Password=YourStrong!Passw0rd;TrustServerCertificate=True;"
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

### 5. Verify the connection string

Update the local connection string in `src/MCPRegistry/appsettings.Development.json` to point to the Docker SQL Server:

```json
{
  "ConnectionStrings": {
    "DefaultConnection": "Server=localhost,1433;Database=MCPRegistry;User Id=sa;Password=YourStrong!Passw0rd;TrustServerCertificate=True;"
  }
}
```

> **Do not** commit secrets or production connection strings to this file.

---

## Building & Running Locally

### Run the API

```powershell
dotnet run --project src/MCPRegistry
```

The API will be available at:
- **HTTP:** http://localhost:5103
- **HTTPS:** https://localhost:7160
- **Swagger UI:** http://localhost:5103/swagger

### Test with REST Client

Open `src/MCPRegistry/MCPRegistry.http` in Visual Studio or VS Code (with the REST Client extension) to execute test requests.

### Test with PowerShell

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

Server names follow the `domain/name` format per the [MCP registry naming convention](https://modelcontextprotocol.io). You can use any domain that makes sense for your setup (e.g., `io.github.myorg/my-server`, `com.mycompany/tool-name`).

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

## Calling the API as a Client

Read endpoints are **anonymous** (MCP Registry v0.1 spec). Write endpoints require a Microsoft Entra ID bearer token validated by `Microsoft.Identity.Web.AddMicrosoftIdentityWebApi`. (Architecture: [Option D](architecture-option-d.md).)

### What you need

For anonymous reads, only `API_URL` is required. For writes, capture the auth values too (the azd preprovision hook writes them all into the env):

```powershell
azd env get-values | Select-String 'AZURE_TENANT_ID|AZURE_API_APP_CLIENT_ID|AZURE_ADMIN_GROUP_ID|API_URL'
```

| Variable | Used as |
|---|---|
| `API_URL` | Base URL — `https://ca-mcpreg-<suffix>.<env-default-domain>` |
| `AZURE_TENANT_ID` | Authority — `https://login.microsoftonline.com/<tenant>/v2.0` (writes only) |
| `AZURE_API_APP_CLIENT_ID` | Audience / resource — the API app registration that exposes `mcp.access` (writes only) |
| `AZURE_ADMIN_GROUP_ID` | Object ID of the group whose members can call write endpoints |

### Authorization rules

| Endpoint | Required claim |
|---|---|
| `GET /v0.1/servers` (+ variants) | None — anonymous |
| `POST /v0.1/servers` | Token must include `groups` claim containing `AZURE_ADMIN_GROUP_ID` |
| `DELETE /v0.1/servers/{name}/versions/{version}` | Same as POST |

Anonymous write → `401`. Authenticated but missing admin group on a write → `403`.

### Acquiring a token interactively (Azure CLI)

The first time you call the API from `az`, the CLI needs admin consent for the scope. Do this once per user/tenant:

```powershell
$tenant   = $(azd env get-value AZURE_TENANT_ID)
$apiAppId = $(azd env get-value AZURE_API_APP_CLIENT_ID)

az login --tenant $tenant --scope "api://$apiAppId/.default"
```

After that, get a token with:

```powershell
$token = az account get-access-token --resource "api://$apiAppId" --query accessToken -o tsv
```

### Acquiring a token from .NET (MSAL public client)

For a console app or VS Code extension running on a user's machine:

```csharp
using Microsoft.Identity.Client;

var app = PublicClientApplicationBuilder
    .Create("<your-public-client-app-id>")        // separate AAD app reg, "Mobile and desktop" platform
    .WithTenantId("<AZURE_TENANT_ID>")
    .WithDefaultRedirectUri()                       // http://localhost loopback
    .Build();

var scopes = new[] { "api://<AZURE_API_APP_CLIENT_ID>/mcp.access" };

AuthenticationResult result;
try
{
    var accounts = await app.GetAccountsAsync();
    result = await app.AcquireTokenSilent(scopes, accounts.FirstOrDefault())
                      .ExecuteAsync();
}
catch (MsalUiRequiredException)
{
    result = await app.AcquireTokenInteractive(scopes).ExecuteAsync();
}

var bearer = result.AccessToken;
```

The public-client app reg needs `requiredResourceAccess` for `api://<AZURE_API_APP_CLIENT_ID>/mcp.access` and admin consent granted in the tenant. The provisioned `mcp-registry-ui` app reg is *not* a public client — it is a confidential web app — so you cannot reuse its client ID here.

### Acquiring a token from Node / JavaScript (MSAL Node)

```javascript
const { PublicClientApplication } = require('@azure/msal-node');

const pca = new PublicClientApplication({
  auth: {
    clientId: '<public-client-app-id>',
    authority: 'https://login.microsoftonline.com/<AZURE_TENANT_ID>',
  },
});

const scopes = ['api://<AZURE_API_APP_CLIENT_ID>/mcp.access'];
// device-code flow is simplest for first run:
const result = await pca.acquireTokenByDeviceCode({
  scopes,
  deviceCodeCallback: r => console.log(r.message),
});
const bearer = result.accessToken;
```

### Example: list servers (curl / PowerShell)

```powershell
$apiUrl   = $(azd env get-value API_URL)
$apiAppId = $(azd env get-value AZURE_API_APP_CLIENT_ID)
$token    = az account get-access-token --resource "api://$apiAppId" --query accessToken -o tsv

Invoke-RestMethod -Uri "$apiUrl/v0.1/servers" -Headers @{ Authorization = "Bearer $token" }
```

Or with curl:

```bash
curl -H "Authorization: Bearer $TOKEN" "$API_URL/v0.1/servers"
```

### Pointing VS Code at the registry

This registry implements the [MCP Registry v0.1 specification](https://registry.modelcontextprotocol.io/docs), so `GET /v0.1/servers*` is **anonymous** and works with any spec-compliant client. Write endpoints (`POST` / `DELETE`) still require an admin token — see [Authentication & Authorization](#authentication--authorization).

#### Option 0 — GitHub Copilot Enterprise org policy (recommended)

GitHub Copilot Enterprise admins can pin every Copilot client in the org to a single MCP registry. Once configured, end users do **not** edit `mcp.json` themselves — Copilot pulls the server list from your registry on their behalf.

1. Open <https://github.com/organizations/&lt;your-org&gt;/settings/copilot/policies>.
2. Under **MCP servers in Copilot**, set the policy to **Enabled**.
3. In **MCP registry URL (optional) [Preview]**, paste your registry base URL (the value of `azd env get-value API_URL`, e.g. `https://ca-mcpreg-xxx.<env>.azurecontainerapps.io`). It must be a [spec-compliant MCP registry](https://registry.modelcontextprotocol.io/docs) — this implementation is.
4. Under **Restrict MCP access to registry servers [Preview]**, choose **Registry only** to block any MCP server not published in your registry.

That's it. GitHub Copilot will call `GET <API_URL>/v0.1/servers` anonymously from its own backend; no per-user token plumbing is required.

> **Network reachability:** GitHub Copilot's backend runs in GitHub-owned infrastructure, **not** inside your VNet. The default deployment in this repo sets `publicNetworkAccess: 'Disabled'` on the Container Apps environment, which makes the registry reachable **only** through the env's private endpoint inside the VNet (and any peer VNets linked to its private DNS zone). For GitHub Copilot's "MCP registry URL" policy to work, the URL you paste must be reachable from the public internet. Pick one of:
> - Set `publicNetworkAccess: 'Enabled'` on the `Microsoft.App/managedEnvironments` resource (`azd/infra/modules/resources.bicep`) and `ingressExternal: true` on the API container app. Anonymous reads are intentional per the MCP Registry spec; writes still require an admin token, so the security posture is unchanged.
> - Or front the registry with **Azure API Management** / **Azure Front Door** with a public hostname, route to the private API, and (optionally) IP-allowlist the [GitHub Actions `hookshot` IP ranges](https://api.github.com/meta) at the edge.
>
> Keeping the data plane private + exposing only `GET /v0.1/servers*` through a public edge is the most defensible posture.

#### Option 1 — Manual workspace mcp.json

Useful for one-off testing or when you need a server that's not (yet) in the registry.

1. Browse the registry (UI or `curl $API_URL/v0.1/servers`) and pick the server you want.
2. Translate its `packages[]` or `remotes[]` entry into a VS Code `mcp.json` entry by hand. See the [MCP configuration reference](https://code.visualstudio.com/docs/copilot/reference/mcp-configuration) for the field schema.
3. Save to `.vscode/mcp.json` (workspace) or run `MCP: Open User Configuration` (user profile).

#### Option 2 — Generate `mcp.json` from the registry (`scripts/Export-McpJson.ps1`)

A PowerShell helper that pulls every server from the registry and emits a VS Code-compatible `mcp.json`. It maps `remotes[]` to `{ "type": "http" \| "sse", "url": ... }` and `packages[]` to `{ "type": "stdio", "command": "npx" \| "docker" \| "uvx", ... }`. Since reads are anonymous, no `az login` is required.

```powershell
# Run from the repo root — auto-reads ApiUrl from the azd env
./scripts/Export-McpJson.ps1

# Or write to your user-profile mcp.json, keep entries that aren't in the registry
./scripts/Export-McpJson.ps1 `
    -OutputPath "$env:APPDATA/Code/User/mcp.json" `
    -Merge
```

Reload VS Code (or run `MCP: List Servers`) — the servers from your registry appear in the Extensions view under `MCP SERVERS - INSTALLED`. VS Code prompts to trust each one on first start.

Re-run the script whenever the registry catalog changes.

#### Option 3 — Browse-and-install from the UI (manual copy)

Open the management UI in a browser, find the server you want, and copy the suggested `mcp.json` snippet from its detail page into your `.vscode/mcp.json`. *(Snippet rendering on detail pages is a future enhancement — see [Known gaps](architecture-option-d.md#known-gaps--future-hardening).)*

### Example: workload (no user) calling the API

For anonymous reads you can call `GET /v0.1/servers*` directly — no token, no app registration. The remainder of this section applies only to **writes** (publishing servers, deleting versions) which require an admin token:

1. Add an **app role** (not a delegated scope) named `Mcp.Admin` to `mcp-registry-api`.
2. Assign the role to the workload's SPN/MI from the API app reg's *Roles and administrators* blade, and add the same identity to the admin AAD group whose object ID is wired into `RequireAdmin`.
3. Acquire a token with the client-credentials flow:

   ```powershell
   $token = az account get-access-token --resource "api://$apiAppId" --tenant $tenant --query accessToken -o tsv
   ```

   when running as the workload identity (e.g., from a Container App with `AZURE_CLIENT_ID` pointing to the user-assigned MI).

The `RequireAdmin` policy checks `RequireAuthenticatedUser()` plus a `groups` claim matching the configured admin group object ID.

---

## Azure Deployment

This guide uses [Azure Developer CLI (azd)](https://learn.microsoft.com/azure/developer/azure-developer-cli/) for deployment. You can also deploy using standard Azure CLI (`az deployment`) or the Azure Portal by targeting `azd/infra/main.bicep` directly — adjust `main.parameters.json` to supply parameter values manually instead of relying on azd environment variables.

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
# Override DSP to target Azure SQL Database (the project defaults to SQL Server 2022)
dotnet build src/MCPRegistryDatabase/MCPRegistryDatabase.sqlproj -c Release /p:DSP="Microsoft.Data.Tools.Schema.Sql.SqlAzureV12DatabaseSchemaProvider"

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

The initial `azd provision` may fail because the Container App references an image that hasn't been pushed yet. The Bicep parameters `apiContainerImage` and `uiContainerImage` default to a placeholder image for the first provisioning. If you see this error, run `azd provision` again. For classic (non-azd) deployments, set these parameters to your actual ACR image paths.

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

The SQL project's `DSP` defaults to `Sql170DatabaseSchemaProvider` (SQL Server 2022) for local development. When deploying to Azure SQL, override it at build time:
```powershell
dotnet build src/MCPRegistryDatabase/MCPRegistryDatabase.sqlproj -c Release /p:DSP="Microsoft.Data.Tools.Schema.Sql.SqlAzureV12DatabaseSchemaProvider"
```
The `deploy-db.ps1` and `deploy-db.sh` scripts handle this automatically.

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
| **SDK-style sqlproj** | Enables `dotnet build` and dacpac output without Visual Studio or SSDT. The project targets SQL Server 2022 (`Sql170`) by default for local dev; deploy scripts override to `SqlAzureV12DatabaseSchemaProvider` for Azure SQL |
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

---

## Production Hardening

The default deployment uses public endpoints with Entra-only auth and `AllowAzureServices` firewall rules, which is appropriate for POC/dev. For production environments, follow the Azure Well-Architected Framework and Cloud Adoption Framework guidance:

- [Azure Well-Architected Framework](https://learn.microsoft.com/azure/well-architected/)
- [Cloud Adoption Framework — Azure landing zones](https://learn.microsoft.com/azure/cloud-adoption-framework/ready/landing-zone/)
- [Container Apps landing zone accelerator](https://learn.microsoft.com/azure/cloud-adoption-framework/scenarios/app-platform/container-apps/landing-zone-accelerator)
- [Azure SQL security best practices](https://learn.microsoft.com/azure/azure-sql/database/security-best-practice)
