# Deploying Behind a Corporate Firewall (Self-Signed CA)

This guide walks through configuring `azd up` and the Docker build/runtime stack to trust a corporate root CA bundle. Use it when deployment fails with errors like:

- `unable to get local issuer certificate`
- `self signed certificate in certificate chain`
- `SSL: CERTIFICATE_VERIFY_FAILED`
- `x509: certificate signed by unknown authority`

It is tailored to this repo (`azd` + .NET 10 containers) and also covers the Node/Python tooling cases your infosec team called out.

---

## Background — three layers that need trust

When `azd up` runs, TLS-protected calls happen at **three distinct layers**. Adding the cert to only one of them is the most common mistake.

| Layer | What talks TLS | Where the cert must be installed |
|---|---|---|
| **Host machine** (dev laptop / CI agent) | `azd`, `az`, `dotnet`, `git`, `nuget`, `npm`, `docker push` | OS trust store of the host |
| **Docker daemon** | Pulling base images (e.g. `mcr.microsoft.com/dotnet/sdk:10.0`) | Docker Desktop trust store / Linux docker config |
| **Image build stage & runtime image** | `dotnet restore` (NuGet), app outbound HTTPS at runtime | Inside the image (Dockerfile) |

---

## Step 1 — Place the cert bundle in the repo

1. Save the bundle from infosec as `corp-ca-bundle.pem` at the **repo root**:
   ```
   c:\Source\MCPRegistry\corp-ca-bundle.pem
   ```
2. Verify it's PEM-encoded (each cert wrapped in `-----BEGIN CERTIFICATE-----` … `-----END CERTIFICATE-----`).
3. Decide whether to commit it. CA root certs are not secrets, so committing is fine and the easiest distribution path. If your org policy forbids it, distribute via a shared secure location and have each dev drop it in the same path; add it to `.gitignore`.

---

## Step 2 — Trust the cert on the host machine

This unblocks `azd`, `az`, `dotnet restore` (when run outside Docker), `git clone`, and the Docker push to ACR.

### Windows (PowerShell, Admin)
```powershell
Import-Certificate `
  -FilePath "C:\Source\MCPRegistry\corp-ca-bundle.pem" `
  -CertStoreLocation Cert:\LocalMachine\Root
```

If the bundle contains multiple certs, split them first or run:
```powershell
certutil -addstore -f "Root" corp-ca-bundle.pem
```

### macOS
```bash
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain corp-ca-bundle.pem
```

### Linux (Debian/Ubuntu)
```bash
sudo cp corp-ca-bundle.pem /usr/local/share/ca-certificates/corp-ca-bundle.crt
sudo update-ca-certificates
```

### Also set env vars (covers Node/Python tooling that ignores the OS store)
Add to your shell profile (or to your CI pipeline env):

```powershell
# PowerShell profile
$env:NODE_EXTRA_CA_CERTS  = "C:\Source\MCPRegistry\corp-ca-bundle.pem"
$env:REQUESTS_CA_BUNDLE   = "C:\Source\MCPRegistry\corp-ca-bundle.pem"
$env:SSL_CERT_FILE        = "C:\Source\MCPRegistry\corp-ca-bundle.pem"
$env:CURL_CA_BUNDLE       = "C:\Source\MCPRegistry\corp-ca-bundle.pem"
```

```bash
# bash/zsh profile
export NODE_EXTRA_CA_CERTS=$PWD/corp-ca-bundle.pem
export REQUESTS_CA_BUNDLE=$PWD/corp-ca-bundle.pem
export SSL_CERT_FILE=$PWD/corp-ca-bundle.pem
export CURL_CA_BUNDLE=$PWD/corp-ca-bundle.pem
```

---

## Step 3 — Trust the cert in the Docker daemon

Required so Docker can pull `mcr.microsoft.com/dotnet/sdk:10.0` etc. through the corp proxy.

- **Docker Desktop (Win/Mac)**: it inherits the OS trust store. After Step 2, **fully quit and restart Docker Desktop** (system tray → Quit, then relaunch).
- **Linux docker engine**:
  ```bash
  sudo cp corp-ca-bundle.pem /etc/docker/certs.d/mcr.microsoft.com/ca.crt
  sudo systemctl restart docker
  ```

---

## Step 4 — Bake the cert into the container images

Edit both Dockerfiles in this repo so `dotnet restore` succeeds inside the build stage **and** the running app trusts the corp CA for outbound HTTPS.

### [src/MCPRegistry/Dockerfile](../src/MCPRegistry/Dockerfile)

```dockerfile
FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS base
WORKDIR /app

# Trust corporate root CA at runtime (outbound HTTPS from the app)
COPY corp-ca-bundle.pem /usr/local/share/ca-certificates/corp-ca-bundle.crt
RUN update-ca-certificates
ENV SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
ENV SSL_CERT_DIR=/etc/ssl/certs

FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
ARG BUILD_CONFIGURATION=Release
WORKDIR /src

# Trust corporate root CA so `dotnet restore` (NuGet over HTTPS) works
COPY corp-ca-bundle.pem /usr/local/share/ca-certificates/corp-ca-bundle.crt
RUN update-ca-certificates
ENV SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
ENV SSL_CERT_DIR=/etc/ssl/certs

COPY ["MCPRegistry.csproj", "./"]
RUN dotnet restore
COPY . .
RUN dotnet publish -c $BUILD_CONFIGURATION -o /app/publish

FROM base AS final
WORKDIR /app
EXPOSE 8080
COPY --from=build /app/publish .
ENTRYPOINT ["dotnet", "MCPRegistry.dll"]
```

> Place the `COPY corp-ca-bundle.pem` line **before** the first `RUN dotnet restore` — that's the call that fails first.

### [src/MCPRegistry.UI/Dockerfile](../src/MCPRegistry.UI/Dockerfile)

The UI build context is the **repo root** ([azd/azure.yaml](../azd/azure.yaml) sets `context: ../`), so the `COPY` source path is just `corp-ca-bundle.pem`. Apply the same pattern as above.

### Build-context note

The API build uses the project folder as context ([src/MCPRegistry/](../src/MCPRegistry/)), not the repo root. Either:
- **(Recommended)** copy `corp-ca-bundle.pem` into [src/MCPRegistry/](../src/MCPRegistry/) too, **or**
- change [azd/azure.yaml](../azd/azure.yaml) to use `context: ../../` for the `web` service so both Dockerfiles share one bundle at the repo root.

### Why both stages?

- **`build` stage** — needed so `dotnet restore` can reach `nuget.org` through the proxy.
- **`final` stage** — needed so the running container (calling Azure SQL, Key Vault, MSI endpoints, etc.) trusts proxied TLS too.

### Why both `update-ca-certificates` AND `SSL_CERT_FILE`?

- `update-ca-certificates` is the canonical mechanism for .NET on Linux (it uses OpenSSL's trust store) and for `curl`/`apt` inside the image.
- `SSL_CERT_FILE` is the belt-and-suspenders fallback that Python's `ssl`, the AWS SDK, and other tools honor.

---

## Step 5 — Equivalents for other runtimes (per infosec's note)

If your team adds Node.js or Python sidecars/services, use the snippet infosec provided verbatim:

### Node.js Dockerfile
```dockerfile
COPY corp-ca-bundle.pem /usr/local/share/ca-certificates/corp-ca-bundle.crt
RUN update-ca-certificates
ENV NODE_EXTRA_CA_CERTS=/usr/local/share/ca-certificates/corp-ca-bundle.crt
```

### Python Dockerfile
```dockerfile
COPY corp-ca-bundle.pem /usr/local/share/ca-certificates/corp-ca-bundle.crt
RUN update-ca-certificates
ENV REQUESTS_CA_BUNDLE=/usr/local/share/ca-certificates/corp-ca-bundle.crt
ENV SSL_CERT_FILE=/usr/local/share/ca-certificates/corp-ca-bundle.crt
```

---

## Step 6 — Verify before running `azd up`

Run these from a fresh shell to confirm each layer:

```powershell
# Host trust (should print: "verify return code: 0 (ok)")
openssl s_client -connect login.microsoftonline.com:443 -showcerts < $null

# Azure CLI through the proxy
az account show

# Docker daemon trust (should pull successfully)
docker pull mcr.microsoft.com/dotnet/sdk:10.0

# Build stage trust (should restore without 'unable to get local issuer certificate')
docker build -f src/MCPRegistry/Dockerfile src/MCPRegistry/

# Full deploy
azd up
```

---

## Common pitfalls

1. **Forgot to restart Docker Desktop** after importing the cert — Step 3 silently fails until restart.
2. **Bundle has multiple certs** but Windows `Import-Certificate` only imported the first — use `certutil -addstore -f "Root" corp-ca-bundle.pem` instead.
3. **NuGet uses a separate cert config** — usually unnecessary, but if `dotnet restore` still fails on the host, set `nuget config -set http_proxy=...` or use the env vars above.
4. **`dotnet dev-certs https`** generates a localhost cert — do **not** confuse this with the corp CA; they're orthogonal.
5. **Cert rotation** — when infosec rotates the CA, every dev image must be rebuilt. Consider a `CORP_CA_BUNDLE_VERSION` build arg to bust Docker layer cache.
