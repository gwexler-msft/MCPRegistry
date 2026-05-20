# MCPRegistry.IntegrationTests

End-to-end smoke tests against a **deployed** MCP Registry API. These tests verify
that the auth chain (`Microsoft.Identity.Web` JwtBearer + ASP.NET Core
authorization policies) is wired up correctly against the live Entra tenant and
the live Container App.

They are **skipped by default** — running `dotnet test` from the repo root will
not fail on a fresh clone. The tests only run when the required env vars are
present.

## Required env vars

| Variable | Source |
|---|---|
| `MCPREG_API_URL` | `azd env get-value API_URL` |
| `MCPREG_API_APP_CLIENT_ID` | `azd env get-value AZURE_API_APP_CLIENT_ID` |
| `MCPREG_TENANT_ID` | `azd env get-value AZURE_TENANT_ID` |
| `MCPREG_ADMIN_GROUP_ID` *(optional)* | `azd env get-value AZURE_ADMIN_GROUP_ID` — enables the POST/admin check |

## Run

```powershell
cd src/MCPRegistry.IntegrationTests

$env:MCPREG_API_URL              = (azd env get-value API_URL)
$env:MCPREG_API_APP_CLIENT_ID    = (azd env get-value AZURE_API_APP_CLIENT_ID)
$env:MCPREG_TENANT_ID            = (azd env get-value AZURE_TENANT_ID)
$env:MCPREG_ADMIN_GROUP_ID       = (azd env get-value AZURE_ADMIN_GROUP_ID)

# First time only: log in so DefaultAzureCredential can mint a token
az login --tenant $env:MCPREG_TENANT_ID --scope "api://$($env:MCPREG_API_APP_CLIENT_ID)/.default"

dotnet test
```

## What's tested

The contract here matches the MCP Registry v0.1 spec: reads are anonymous, writes require admin.

1. **Anonymous GET returns 200** — `GET /v0.1/servers` is anonymous per spec; required so spec-compliant clients (e.g. GitHub Copilot Enterprise's "MCP registry URL" org policy) can list servers without prior credential exchange.
2. **Valid bearer GET returns 200** — A token presented against an anonymous endpoint must still succeed.
3. **Anonymous POST returns 401** — Writes still require an authenticated admin token.
4. **POST with a non-admin token returns 403** — `RequireAdmin` policy enforces group membership.
   This test accepts either `403` (caller isn't in admin group) or `201` (caller happens to be admin)
   — the failure mode it catches is `401` (auth broken) or `500` (server crash).

## Why not WebApplicationFactory?

`WebApplicationFactory<TStartup>` runs the API in-process and bypasses
forwarded-headers / TLS / Entra. The bugs we found while landing
[architecture Option D](../../docs/architecture-option-d.md) (Easy Auth
`allowedApplications` + v2 tokens, SQL connection-policy Redirect with PE,
forwarded-headers misconfiguration) only manifest against the real deployed
stack — so these tests intentionally call the production endpoint.

For pure controller / repository / service unit tests, see
[../MCPRegistry.Tests](../MCPRegistry.Tests).

## Known caveats

- **First-run consent required for `az` CLI.** If `az account get-access-token`
  returns `AADSTS65001: consent_required`, run
  `az login --tenant <tenant> --scope "api://<api-app-id>/.default"` once.
  `DefaultAzureCredential` uses the same token cache afterwards.
- **Some Windows laptops fail TLS handshakes to ACA ingress via schannel.** If
  `dotnet test` or `curl` reports `SSL/TLS connection failed` against the API
  FQDN but a browser loads the UI fine, the laptop has a schannel / ALPN
  negotiation issue (commonly seen on devices with corp network filter
  drivers). Run these tests from a Linux CI runner, WSL, or from inside Azure
  instead.
- **`DefaultAzureCredential` order matters in CI.** On a build agent without
  developer credentials, set `AZURE_CLIENT_ID` (and friends) to a service
  principal or workload identity that has been granted the `mcp.access` scope.
