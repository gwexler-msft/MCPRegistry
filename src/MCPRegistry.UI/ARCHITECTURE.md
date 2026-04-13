# MCP Registry — Architecture

## System Overview

The MCP Registry is a self-hosted implementation of the Model Context Protocol Server Registry API, consisting of two applications and a SQL database:

```
┌─────────────────────────────────────────────────────────────────────┐
│                    Azure Container Apps Environment                 │
│                                                                     │
│  ┌─────────────────────┐        ┌─────────────────────┐            │
│  │  Management UI      │        │  Registry API       │            │
│  │  (Blazor Server)    │──────► │  (ASP.NET Core 10)  │            │
│  │  ca-mcpreg-ui-xxx   │ HTTP   │  ca-mcpreg-xxx      │            │
│  │  Port 8080          │        │  Port 8080          │            │
│  └─────────────────────┘        └──────────┬──────────┘            │
│                                             │                       │
└─────────────────────────────────────────────┼───────────────────────┘
                                              │ Managed Identity
                                              │ (Entra-only auth)
                                    ┌─────────▼─────────┐
                                    │   Azure SQL DB    │
                                    │   (Serverless)    │
                                    │   MCPRegistry     │
                                    └───────────────────┘
```

## Components

### Registry API (`src/MCPRegistry/`)

| Attribute | Value |
|-----------|-------|
| Runtime | ASP.NET Core 10 |
| Pattern | REST API with Controllers |
| Data Access | Dapper (raw SQL with parameterized queries) |
| Database | Azure SQL (Serverless GP_S_Gen5) |
| Auth to SQL | Managed Identity (Entra-only, no passwords) |
| Hosting | Azure Container Apps (Consumption) |
| API Spec | MCP Registry v0.1 |

### Management UI (`src/MCPRegistry.UI/`)

| Attribute | Value |
|-----------|-------|
| Runtime | ASP.NET Core 10 |
| Framework | Blazor Server (Interactive Server rendering) |
| API Communication | HttpClient → Registry API |
| Hosting | Azure Container Apps (Consumption) |
| Configuration | `ApiBaseUrl` set via environment variable |

### Database (`src/MCPRegistryDatabase/`)

| Attribute | Value |
|-----------|-------|
| Project Type | SQL Database Project (SDK-style, Microsoft.Build.Sql) |
| Target Platform | Azure SQL Database (SqlAzureV12) |
| Schema Management | dacpac via sqlpackage |
| Table | `dbo.Servers` (ServerName + Version composite PK, JSON in Value column) |

## Technology Selection

### Why Blazor Server for the UI?

| | **Blazor Server** | **Blazor WASM** | **React + TS** | **Plain HTML/JS** |
|---|---|---|---|---|
| **Language** | C# | C# | TypeScript | JavaScript |
| **Stays in .NET ecosystem** | ✅ Yes | ✅ Yes | ❌ No | ❌ No |
| **Server-side rendering** | ✅ Yes | ❌ No | ❌ No | ❌ No |
| **No JS framework needed** | ✅ Yes | ✅ Yes | ❌ npm/webpack | ✅ Yes |
| **Shared models with API** | ✅ Same project refs | ✅ Same project refs | ❌ Separate types | ❌ Manual |
| **Bundle size** | Tiny (server-side) | ~10MB (.NET runtime) | ~200KB | ~0KB |
| **Real-time updates** | ✅ SignalR built-in | ❌ Manual | ❌ Manual | ❌ Manual |
| **Offline capable** | ❌ Needs connection | ✅ Yes | ✅ Yes | ✅ Yes |
| **Deploy as Container App** | ✅ Same pattern | ✅ Static + nginx | ✅ Container | ✅ Static |
| **Dev complexity** | Low | Low | Medium | Lowest |
| **Best for internal tools** | ⭐ **Selected** | Good | Overkill | Too basic |

**Decision:** Blazor Server was selected because:
1. Same C#/.NET ecosystem as the API — no additional toolchain
2. Server-side rendering means no large client downloads
3. Can share model types via project references in the future
4. SignalR connection is acceptable for an internal management tool
5. Deploys as a standard Container App with the same Dockerfile pattern

## Data Flow

### Read (List/Search Servers)
```
User → Blazor UI (SignalR) → McpRegistryClient → HTTP GET → Registry API → Dapper → SQL
                                                                                      ↓
User ← Blazor UI (SignalR) ← McpRegistryClient ← JSON ← Registry API ← Dapper ← SQL
```

### Write (Add Server)
```
User → Blazor UI Form → McpRegistryClient → HTTP POST → Registry API → Dapper → SQL INSERT
```

### Delete (Soft-Delete)
```
User → Confirm Modal → McpRegistryClient → HTTP DELETE → Registry API → Dapper → SQL UPDATE (status='deleted')
```

## Infrastructure (Azure)

All resources are provisioned via Bicep using Azure Verified Modules (AVM):

| Resource | AVM Module | Purpose |
|----------|-----------|---------|
| Container App (API) | `avm/res/app/container-app` | Hosts the Registry API |
| Container App (UI) | `avm/res/app/container-app` | Hosts the Management UI |
| Container Apps Env | `avm/res/app/managed-environment` | Shared environment for both apps |
| Azure SQL Server | `avm/res/sql/server` | Database server (Entra-only auth) |
| Container Registry | `avm/res/container-registry/registry` | Docker image storage |
| Log Analytics | `avm/res/operational-insights/workspace` | Centralized logging |
| Managed Identity | `avm/res/managed-identity/user-assigned-identity` | API → SQL auth |

### Resource Naming

Resources follow Azure CAF naming conventions: `{prefix}-{workload}-{suffix}`

| Resource | Default Name | UI Resource |
|----------|-------------|-------------|
| Container App (API) | `ca-mcpreg-{suffix}` | — |
| Container App (UI) | — | `ca-mcpreg-ui-{suffix}` |
| SQL Server | `sql-mcpreg-{suffix}` | Shared |
| Container Registry | `crmcpreg{suffix}` | Shared |
| Log Analytics | `log-mcpreg-{suffix}` | Shared |

### Deployment

```
azd up (from azd/ folder)
  ├── azd provision
  │   ├── Bicep deployment (all resources)
  │   └── postprovision hooks
  │       ├── deploy-db.ps1 (dacpac → SQL schema)
  │       └── grant-sql-access.ps1 (managed identity → SQL)
  └── azd deploy
      ├── Build + push API image → ACR → Container App (web)
      └── Build + push UI image → ACR → Container App (ui)
```

## Security

| Layer | Mechanism |
|-------|-----------|
| SQL Authentication | Microsoft Entra ID only (no SQL passwords) |
| API → SQL | User-assigned Managed Identity with db_datareader + db_datawriter |
| SQL Public Access | Enabled with AllowAzureServices firewall rule |
| Container App Ingress | HTTPS only (TLS termination at platform level) |
| ACR | Admin credentials for Container App pull |
| Secrets | No hardcoded secrets — all via managed identity or azd env vars |

## MCP Specification Compliance

| Requirement | Implementation |
|-------------|---------------|
| Server metadata is immutable | No PUT/PATCH endpoints; add new versions via POST |
| Status field is mutable | DELETE sets status to "deleted" (soft-delete) |
| Status values | `active`, `deprecated`, `deleted` (enforced by CHECK constraint) |
| Version format | Semver validated via regex in controller |
| Server name format | `domain/name` enforced by CHECK constraint |
