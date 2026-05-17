# MCP Registry — Architecture (Option B: External env + IP Allowlist)

> **Why this exists.** Our original lockdown used `internal: true` on the Container Apps environment. That path is blocked by an open Microsoft platform bug ([microsoft/azure-container-apps#1714](https://github.com/microsoft/azure-container-apps/issues/1714)) where the internal load balancer returns `404 Container App is stopped or does not exist` for healthy replicas, even with Microsoft's own hello-world sample. Option B is the **minimal-change workaround**: keep the env external (which works), but restrict every app's ingress to the VNet CIDR via `ipSecurityRestrictions`. The public FQDN exists and resolves on the internet, but only requests sourced from inside our VNet (or peered VNets) get past the L7.

---

## Design goals

- **Get unblocked fast.** This is the lowest-risk, lowest-cost change to escape the platform bug.
- **No app traffic accepted from the public internet.** Enforced by per-app IP allowlist (default-deny).
- **No public data plane to the database.** Application → SQL still flows over a private endpoint.
- **No SQL passwords anywhere.** Same Entra-only auth as before.
- **Operator-friendly.** Same DACPAC + grant pattern as today.

> **Honest caveat.** This design **does** expose a public DNS name and a public IP for the Container Apps env. We mitigate with default-deny + VNet-CIDR allowlist. That is a *compensating control*, not a true private-only surface. If your security baseline forbids any public listener for the app, pick [Option A](architecture-option-a.md) instead.

---

## Resource inventory & lockdown state

| Resource | Type | Public access | Notes |
|---|---|---|---|
| `vnet-mcpreg-<suffix>` | Virtual Network (10.100.0.0/16) | n/a | Subnets: `snet-aca` (10.100.0.0/23, delegated `Microsoft.App/environments`), `snet-pe` (10.100.2.0/24), `snet-aci` (10.100.3.0/27, delegated `Microsoft.ContainerInstance/containerGroups`) |
| `cae-mcpreg-<suffix>` | Container Apps Environment | **Enabled** | `internal: false`, `publicNetworkAccess: Enabled`, `workloadProfiles: [Consumption]`, `infrastructureSubnetResourceId = snet-aca` |
| `ca-mcpreg-<suffix>` | Container App (API) | **Public FQDN, IP-restricted** | `ingressExternal: true`, `ipSecurityRestrictions: [Allow 10.100.0.0/16, default Deny]` |
| `ca-mcpreg-ui-<suffix>` | Container App (UI) | **Public FQDN, IP-restricted** | Same allowlist |
| `sql-mcpreg-<suffix>` | Azure SQL Server | **Enabled (firewall = empty)** | Private endpoint `sql-mcpreg-<suffix>-pe` in `snet-pe`. Postprovision scripts add a temporary firewall rule from the laptop's egress /24. |
| `MCPRegistry` | SQL Database (Serverless GP_S_Gen5) | n/a | Auto-pause 60 min, 0.5–2 vCore |
| `crmcpreg<suffix>` | Container Registry | **Public (Basic SKU)** | MI AcrPull only, admin user disabled |
| `id-mcpreg-<suffix>` | User-Assigned Managed Identity | n/a | Used by both apps for ACR + SQL |
| `log-mcpreg-<suffix>` | Log Analytics Workspace | n/a | App logs sink |
| `privatelink.database.windows.net` | Private DNS Zone | n/a | Linked to the VNet; A record bound to the SQL PE NIC |
| `privatelink.<region>.azurecontainerapps.io` | Private DNS Zone | n/a | **Not created in the base design.** See [DNS approach](#dns-approach) below for when to add it as an opt-in hardening step. |

> **Difference from internal-only design**: `internal` flips from `true` to `false`; `publicNetworkAccess` flips from `Disabled` to `Enabled`; apps flip `ingressExternal` from `false` to `true` and gain `ipSecurityRestrictions`. The synthetic ACA env private DNS zone goes away — we use the platform-provided public DNS for the env. SQL design is unchanged.

---

## Network topology

```mermaid
flowchart TB
    Internet["Public Internet"]
    subgraph Subscription["Azure Subscription"]
        subgraph RG["Resource Group: rg-mcpregistry-test"]
            subgraph VNET["VNet vnet-mcpreg (10.100.0.0/16)"]
                subgraph SNET_ACA["snet-aca (10.100.0.0/23)<br/>delegated: Microsoft.App/environments"]
                    CAE["Container Apps Environment<br/>cae-mcpreg<br/>internal: false<br/>publicAccess: Enabled<br/>Public IP + FQDN"]
                    APP_API["Container App: ca-mcpreg<br/>ingressExternal: true<br/>ipRestrict: Allow 10.100/16, Deny *"]
                    APP_UI["Container App: ca-mcpreg-ui<br/>ingressExternal: true<br/>ipRestrict: Allow 10.100/16, Deny *"]
                end
                subgraph SNET_PE["snet-pe (10.100.2.0/24)"]
                    PE_SQL["Private Endpoint<br/>sql-mcpreg-pe<br/>NIC: 10.100.2.x"]
                end
                subgraph SNET_ACI["snet-aci (10.100.3.0/27)<br/>delegated: Microsoft.ContainerInstance"]
                    ACI["Ephemeral probe ACI<br/>(curl-test postdeploy hook)"]
                end
            end
            DNSZONE_SQL["Private DNS Zone<br/>privatelink.database.windows.net<br/>A: sql-mcpreg → 10.100.2.x"]
            SQL["Azure SQL Server<br/>sql-mcpreg<br/>publicAccess: Enabled<br/>firewall: empty<br/>azureADOnlyAuth: true"]
            SQLDB[("SQL Database<br/>MCPRegistry<br/>GP_S_Gen5 serverless")]
            ACR["Azure Container Registry<br/>crmcpreg (Basic, public)<br/>admin user: disabled"]
            MI["User-Assigned MI<br/>id-mcpreg"]
            LAW["Log Analytics<br/>log-mcpreg"]
        end
    end

    Internet -.attempted, rejected by ipSecurityRestrictions.-> CAE
    CAE -.hosts.-> APP_API
    CAE -.hosts.-> APP_UI
    PE_SQL --tunnels to--> SQL
    SQL --contains--> SQLDB
    DNSZONE_SQL -.linked to.-> VNET
    APP_API -.uses.-> MI
    APP_UI -.uses.-> MI
    CAE --logs to--> LAW

    classDef sub fill:#e3f2fd,stroke:#1976d2
    classDef priv fill:#c8e6c9,stroke:#2e7d32
    classDef pub fill:#ffe0b2,stroke:#e65100
    classDef ext fill:#ffcdd2,stroke:#c62828
    class SNET_ACA,SNET_PE,SNET_ACI,VNET sub
    class APP_API,APP_UI,PE_SQL,DNSZONE_SQL,ACI priv
    class SQL,ACR,CAE pub
    class Internet ext
```

Green = private-only. Orange = public listener (env has one, apps' ingress IS that listener, gated by IP filter). Red = untrusted network. Blue = network containers.

---

## Traffic flow #1 — UI request from inside the VNet

In-VNet callers hit the env's public IP through Azure-internal paths; the per-app IP allowlist permits the connection because the source IP is inside `10.100.0.0/16`.

```mermaid
sequenceDiagram
    autonumber
    participant Client as Client<br/>(in-VNet)
    participant DNS as Azure-provided DNS<br/>(168.63.129.16)
    participant LB as Env Public Frontend<br/>(public IP)
    participant Filter as Per-app IP filter<br/>(ipSecurityRestrictions)
    participant UI as ca-mcpreg-ui<br/>(Blazor Server)
    participant API as ca-mcpreg<br/>(REST API)
    participant ZoneSql as privatelink.database<br/>.windows.net
    participant PE_SQL as SQL Private Endpoint<br/>(10.100.2.x)
    participant SQL as Azure SQL Database<br/>MCPRegistry

    Client->>DNS: Resolve ca-mcpreg-ui.<env>.azurecontainerapps.io
    DNS-->>Client: A record → env public IP
    Client->>LB: HTTPS :443 (source IP = 10.100.x.x)
    LB->>Filter: forward with X-Forwarded-For = 10.100.x.x
    Filter-->>LB: ALLOW (matches 10.100.0.0/16 rule)
    LB->>UI: route to UI replica
    UI->>DNS: Resolve ca-mcpreg.<env>.azurecontainerapps.io
    DNS-->>UI: env public IP
    UI->>LB: HTTPS :443
    LB->>Filter: forward
    Filter-->>LB: ALLOW (source IP still in VNet CIDR)
    LB->>API: route to API replica
    API->>DNS: Resolve sql-mcpreg.database.windows.net
    DNS->>ZoneSql: VNet-linked private zone hit
    ZoneSql-->>DNS: CNAME → A 10.100.2.x
    API->>PE_SQL: TCP 1433 + TLS
    PE_SQL->>SQL: tunneled to SQL gateway
    SQL-->>API: query results
    API-->>UI: JSON response
    UI-->>Client: rendered HTML
```

Key points:
- `ipSecurityRestrictions` evaluates the **caller's source IP** as the env sees it. In-VNet traffic to the env's public IP is routed through Azure's fabric and preserves the private source IP — the rule matches.
- Public-internet callers reach the same FQDN/IP but are rejected at the per-app filter with `HTTP 403`.
- Inter-app calls (UI → API) hit the env's public IP from the UI replica's private IP — still in-CIDR, still allowed.
- SQL data plane is **untouched** by Option B; still PE-only.

---

## Traffic flow #2 — Identity / authentication

Unchanged from the internal-env design. Both apps share a single user-assigned MI.

```mermaid
flowchart LR
    subgraph App["ca-mcpreg / ca-mcpreg-ui"]
        Code["App code<br/>Microsoft.Data.SqlClient"]
    end
    IMDS["Container Apps IMDS<br/>(per-replica)"]
    MI["User-Assigned MI<br/>id-mcpreg"]
    AAD["Microsoft Entra ID"]
    SQL["Azure SQL"]
    ACR["ACR"]

    Code --1. fetch token--> IMDS
    IMDS --2. assertion--> AAD
    AAD --3. token--> IMDS
    IMDS --4. token--> Code
    Code --5. AccessToken=<token>--> SQL
    SQL --6. validates against MI principal--> AAD

    ACR --image pull at startup<br/>using same MI--> App

    classDef id fill:#e1bee7,stroke:#6a1b9a
    class MI,IMDS,AAD id
```

How auth is wired (unchanged):
- Connection string uses `Authentication=Active Directory Default;User Id=<MI client ID>`.
- MI is added as a SQL principal by [azd/scripts/grant-sql-access.ps1](../azd/scripts/grant-sql-access.ps1) with `db_datareader` + `db_datawriter`.
- Same MI has `AcrPull` on the registry.
- `azureADOnlyAuthentication: true` blocks SQL logins.

---

## Traffic flow #3 — `azd up` provisioning

```mermaid
sequenceDiagram
    autonumber
    participant Dev as Developer laptop
    participant ARM as Azure Resource Manager
    participant ACRTasks as ACR Tasks
    participant CAE as Container Apps Env
    participant SQL as Azure SQL

    Dev->>ARM: azd provision → deploy main.bicep
    ARM->>ARM: Create RG, VNet, subnets, SQL DNS zone
    ARM->>ARM: Create SQL server + PE + DB
    ARM->>ARM: Create ACR, MI, role assignments
    ARM->>CAE: Create env (internal=false, workload-profiles)
    ARM->>CAE: Create container apps (external + ipRestrictions, placeholder image)
    ARM-->>Dev: Outputs (public FQDNs, MI name)

    Note over Dev: postprovision hook fires
    Dev->>SQL: deploy-db.ps1 → DACPAC publish
    Dev->>SQL: grant-sql-access.ps1 → CREATE USER + role membership

    Note over Dev: azd deploy
    Dev->>ACRTasks: upload source + build context
    ACRTasks->>ACRTasks: docker build + push to ACR
    Dev->>ARM: update Container App → image=<new digest>
    ARM->>CAE: rollout new revision
    CAE->>ACRTasks: pull image (MI AcrPull)

    Note over Dev: postdeploy curl-test hook
    Dev->>ARM: create ephemeral ACI in snet-aci
    ACI->>CAE: HTTPS to public FQDN (source IP = 10.100.3.x)
    CAE-->>ACI: 200 OK (allowlist match)
```

All operator traffic is to the ARM control plane. The operator's laptop **cannot** reach the deployed apps (its public IP is not in the allowlist) — see "Adding inbound access".

---

## Traffic flow #4 — Postprovision DACPAC and grant scripts

**Unchanged from the internal-env design.** The SQL lockdown is identical; the laptop adds a temporary firewall /24, runs DACPAC + grant, then cleans up.

See the full sequence in [docs/architecture.md](architecture.md#traffic-flow-4--postprovision-dacpac-and-grant-scripts).

---

## Traffic flow #5 — App outbound to internet

Unchanged.

```mermaid
flowchart LR
    APP["ca-mcpreg<br/>ca-mcpreg-ui"] --DNS lookup--> AzDNS["168.63.129.16"]
    APP --HTTPS pull image at start--> ACR["crmcpreg.azurecr.io<br/>(public Basic ACR)"]
    APP --AAD token requests--> AAD["login.microsoftonline.com"]
    APP --telemetry--> LAW["Log Analytics<br/>(via env)"]
    APP -.optional outbound.-> Internet["Internet<br/>(no NSG block)"]
```

---

## DNS approach

The base Option B design **does not create a private DNS zone for `containerapps.io`**. In-VNet callers resolve the app FQDN via public Azure DNS, which returns the env's public IP. Traffic from the VNet to that public IP stays on the Azure backbone (it never traverses the public internet), and the security boundary is enforced at L7 by `ipSecurityRestrictions`.

```mermaid
flowchart LR
    Client["In-VNet client"] --1. Resolve ca-mcpreg.&lt;envDomain&gt;.azurecontainerapps.io--> AzDNS["Public Azure DNS"]
    AzDNS --2. A record → env public IP--> Client
    Client --3. HTTPS to public IP<br/>(source = 10.100.x.x)--> ENV["Env public frontend"]
    ENV --4. ipSecurityRestrictions check--> Filter["ALLOW (in 10.100.0.0/16)"]
    Filter --5. forward to app--> APP["ca-mcpreg replica"]
```

Why no private zone is needed:
- There is **no internal LB and no PE NIC** to anchor a private A record against. The env's `staticIp` for an external Workload Profiles env is its public IP, so overriding DNS to point at it provides no isolation benefit.
- The IP allowlist is the actual security control; DNS doesn't influence it (Container Apps `ipSecurityRestrictions` evaluates the caller's source IP, not the DNS name used).
- Skipping the zone keeps the Bicep minimal and avoids drift between public and private records.

### Optional hardening — add the privatelink zone if you also add a PE

If you later decide you want **DNS-level isolation** on top of the IP allowlist (e.g., to ensure no leaked DNS resolution to the public IP, or to defense-in-depth your way to an Option-A-like posture), the change is additive:

1. Add a `privateEndpoints` block to the env (same as [Option A](architecture-option-a.md#what-changes-in-bicep-vs-internal-env-design)) targeting `managedEnvironments` in `snet-pe`.
2. Add the `privatelink.<region>.azurecontainerapps.io` private DNS zone in `network.bicep` and link it to the VNet — the PE's `privateDnsZoneGroup` will auto-create the A record for `<envDomain>`.
3. Leave `publicNetworkAccess: Enabled` (so external callers in your allowlist still work) and **keep** `ipSecurityRestrictions` (so the public IP is still gated).
4. In-VNet callers will now resolve via the private zone to the PE NIC; external allowlisted callers continue to resolve via public DNS to the env's public IP.

At that point you're paying ~$7/mo for the PE in exchange for stronger DNS isolation. If you go one step further and flip `publicNetworkAccess: Disabled` + drop `ipSecurityRestrictions`, you have Option A.

---

## Reachability matrix

| Source | API ingress | UI ingress | SQL data plane | ACR | Azure ARM (mgmt) |
|---|---|---|---|---|---|
| Public internet | ❌ blocked (ipSecurityRestrictions default-deny) | ❌ same | ❌ rejected (firewall = empty) | ✅ public | ✅ public, AAD-auth |
| Inside `vnet-mcpreg` (in-env replicas, ACI, etc.) | ✅ via env public IP (allowlist hit) | ✅ same | ✅ via SQL PE | ✅ public + MI auth | n/a |
| Peered VNet (when configured) | ✅ if peer CIDR is added to allowlist | ✅ same | ✅ via SQL PE | ✅ public | ✅ |
| Operator laptop | ❌ unless their /24 is temporarily added to allowlist | ❌ same | ✅ during postprovision (temp /24 firewall rule) | ✅ public via az push | ✅ |

---

## What changes in Bicep (vs. internal-env design)

[azd/infra/modules/resources.bicep](../azd/infra/modules/resources.bicep):

```diff
 module containerAppsEnv 'br/public:avm/res/app/managed-environment:0.13.1' = {
   params: {
-    internal: true
+    internal: false
     infrastructureSubnetResourceId: acaSubnetId
-    publicNetworkAccess: 'Disabled'
+    publicNetworkAccess: 'Enabled'
     workloadProfiles: [
       { name: 'Consumption', workloadProfileType: 'Consumption' }
     ]
   }
 }

 module containerApp 'br/public:avm/res/app/container-app:0.22.0' = {
   params: {
-    ingressExternal: false
+    ingressExternal: true
     ingressTargetPort: 8080
+    ipSecurityRestrictions: [
+      {
+        name: 'allow-vnet'
+        action: 'Allow'
+        ipAddressRange: '10.100.0.0/16'
+        description: 'Allow only callers from inside vnet-mcpreg'
+      }
+    ]
   }
 }
```

Same change on `containerAppUi`. The synthetic `aca-dns.bicep` module (which built a fake private zone for `<envDomain>` pointed at `staticIp`) is **deleted** — Azure's public DNS is used directly.

No changes to [azd/infra/modules/network.bicep](../azd/infra/modules/network.bicep) beyond the snet-aci subnet already added (for the curl-test ACI). No new private DNS zones for ACA.

The VNet CIDR `10.100.0.0/16` is parameterized in `main.bicep` already; we pass it into `resources.bicep` so the allowlist is auto-generated and stays in sync if the CIDR ever changes.

---

## Adding inbound access (post-deploy)

Two patterns, both simple:

1. **Add a peer VNet to the allowlist:**
   ```bicep
   ipSecurityRestrictions: [
     { name: 'allow-vnet',  action: 'Allow', ipAddressRange: '10.100.0.0/16' }
     { name: 'allow-peer',  action: 'Allow', ipAddressRange: '10.200.0.0/16' }
   ]
   ```
   No DNS work required — public DNS already resolves the app FQDNs.

2. **Add an operator's egress IP temporarily** (the same trick we use for SQL):
   ```powershell
   $myIp = (Invoke-RestMethod https://api.ipify.org)
   az containerapp ingress access-restriction set -g rg-mcpregistry-test -n ca-mcpreg `
     --rule-name my-laptop --ip-address "$myIp/32" --action Allow
   # ... do work ...
   az containerapp ingress access-restriction remove -g rg-mcpregistry-test -n ca-mcpreg `
     --rule-name my-laptop
   ```

---

## Trade-offs vs. Option A (PE-only)

| Dimension | Option A (PE-only) | Option B (this doc) |
|---|---|---|
| Public reachability | None (PE-only) | Public FQDN exists; IP-restricted |
| Inbound DDoS surface | Effectively none | Public IP exposed; relies on IP filter |
| Cost | +PE (~$7/mo) + privatelink zone (free) | $0 extra |
| Setup complexity | Higher (env PE, DNS group) | Lower (just `ipSecurityRestrictions`) |
| In-VNet latency | One extra PE hop | Goes out to public LB and back |
| Failure mode if rule misconfigured | Hard-fail (no path) | Soft-fail (could over-allow) — review rules in PRs |
| Audit posture | Cleanest — env is genuinely unreachable from public internet | Compensating control on a public surface |

Option B is the **minimum-cost, minimum-change** workaround. Pick it when "good enough" beats "perfectly private" and you want the simplest possible Bicep diff.

---

## Known gaps and possible future hardening

- **`ipSecurityRestrictions` is the only thing standing between the internet and the apps.** Any drift (someone widens the rule, or a 0.0.0.0/0 Allow sneaks in) breaks the security model. Mitigations: review rules in PRs; add an Azure Policy denying any Allow with CIDR `>/16`; alert on rule changes via Activity Log.
- **No WAF / DDoS Std.** Public exposure means basic Azure DDoS Basic only. Add Front Door Premium + WAF if the public IP needs L7 protections, even with the allowlist.
- **ACR is public.** Same as Option A.
- **SQL public listener stays on** for operator convenience. Same as Option A.
- **Microsoft platform bug context.** This design exists because [microsoft/azure-container-apps#1714](https://github.com/microsoft/azure-container-apps/issues/1714) makes `internal: true` envs unusable. If MS ships a fix, we can revisit a true internal env and drop the IP allowlist.
