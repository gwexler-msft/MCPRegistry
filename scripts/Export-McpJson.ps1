<#
.SYNOPSIS
    Query the MCP Registry and emit a VS Code `.vscode/mcp.json` file.

.DESCRIPTION
    VS Code does not consume MCP Registry APIs directly — it reads
    `.vscode/mcp.json` (or the user-profile equivalent). This script bridges
    the two: it pulls server records from a registry, picks the best transport
    for each (preferring `remotes` over `packages` when both exist), and
    writes a VS Code-compatible mcp.json.

    Authentication: GET /v0.1/servers is anonymous per the MCP Registry v0.1
    specification, so this script does NOT require a token by default. Pass
    -ApiAppClientId (or set it in your azd env) only when your deployment has
    been explicitly hardened to require auth on reads.

.PARAMETER ApiUrl
    Base URL of the registry (e.g. https://ca-mcpreg-xxx.<env>.azurecontainerapps.io).
    Defaults to azd env value API_URL.

.PARAMETER ApiAppClientId
    Optional. Entra ID app reg client ID that exposes the `mcp.access` scope.
    When supplied, the script attaches a bearer token from `az account
    get-access-token`. Defaults to azd env value AZURE_API_APP_CLIENT_ID.

.PARAMETER TenantId
    Optional. Entra ID tenant ID, used only when ApiAppClientId is set.
    Defaults to azd env value AZURE_TENANT_ID.

.PARAMETER OutputPath
    Where to write mcp.json. Defaults to `.vscode/mcp.json` in the current
    working directory.

.PARAMETER Filter
    Optional case-insensitive substring filter against the server name.
    Pass e.g. -Filter "microsoft" to only include servers whose name contains
    "microsoft".

.PARAMETER Merge
    If set, preserve any existing servers in OutputPath that aren't in the
    registry. Without this, the output file is fully replaced.

.EXAMPLE
    # From repo root, after azd up:
    ./scripts/Export-McpJson.ps1

.EXAMPLE
    # Explicit values, write to user profile mcp.json:
    ./scripts/Export-McpJson.ps1 `
        -ApiUrl https://ca-mcpreg-n7g26r.<env>.azurecontainerapps.io `
        -ApiAppClientId d09ab391-576b-4834-bfd4-4d66d2b72ff6 `
        -TenantId b72e1df9-690f-4d59-a424-95c54a242def `
        -OutputPath "$env:APPDATA/Code/User/mcp.json" `
        -Merge
#>
[CmdletBinding()]
param(
    [string]$ApiUrl,
    [string]$ApiAppClientId,
    [string]$TenantId,
    [string]$OutputPath = ".vscode/mcp.json",
    [string]$Filter,
    [switch]$Merge
)

$ErrorActionPreference = 'Stop'

function Get-AzdEnvValue {
    param([string]$Key)
    $azdRoot = Join-Path $PSScriptRoot '..' 'azd'
    if (-not (Test-Path $azdRoot)) { return $null }
    Push-Location $azdRoot
    try {
        $line = azd env get-values 2>$null | Select-String -Pattern "^$Key="
        if (-not $line) { return $null }
        return ($line -replace "^$Key=", '' -replace '^"', '' -replace '"$', '')
    }
    finally { Pop-Location }
}

if (-not $ApiUrl)          { $ApiUrl          = Get-AzdEnvValue 'API_URL' }
if (-not $ApiAppClientId)  { $ApiAppClientId  = Get-AzdEnvValue 'AZURE_API_APP_CLIENT_ID' }
if (-not $TenantId)        { $TenantId        = Get-AzdEnvValue 'AZURE_TENANT_ID' }

if (-not $ApiUrl) {
    throw "Missing ApiUrl. Pass -ApiUrl or run from a repo with an azd env that has API_URL set."
}

Write-Host "Registry: $ApiUrl" -ForegroundColor Cyan

$headers = @{}
if ($ApiAppClientId -and $TenantId) {
    Write-Host "Tenant:   $TenantId" -ForegroundColor Cyan
    Write-Host "Acquiring bearer token (auth requested)..." -ForegroundColor Cyan
    $token = az account get-access-token `
        --resource "api://$ApiAppClientId" `
        --tenant $TenantId `
        --query accessToken -o tsv 2>$null
    if ($token) {
        $headers['Authorization'] = "Bearer $token"
    } else {
        Write-Warning "Token acquisition failed; falling back to anonymous (spec-compliant) request."
    }
} else {
    Write-Host "Auth:     anonymous (MCP Registry v0.1 spec)" -ForegroundColor Cyan
}

$response = Invoke-RestMethod -Uri "$($ApiUrl.TrimEnd('/'))/v0.1/servers" -Headers $headers

if (-not $response.servers) {
    throw "Registry returned no 'servers' property. Raw: $($response | ConvertTo-Json -Depth 4)"
}

function ConvertTo-VsCodeServerName {
    param([string]$RegistryName)
    # VS Code recommends camelCase, no special chars. Strip namespace prefix, kebab → camel.
    $leaf = ($RegistryName -split '/')[-1]
    $parts = $leaf -split '[-_.]'
    $head = $parts[0].ToLowerInvariant()
    $tail = @($parts | Select-Object -Skip 1 | ForEach-Object {
        if ($_.Length -gt 0) { $_.Substring(0,1).ToUpperInvariant() + $_.Substring(1).ToLowerInvariant() }
    })
    return ($head + ($tail -join ''))
}

function ConvertTo-VsCodeServerEntry {
    param($Server)

    # Prefer hosted/remote transports — VS Code can connect without any local install.
    if ($Server.remotes -and $Server.remotes.Count -gt 0) {
        $remote = $Server.remotes[0]
        $type = if ($remote.type -eq 'sse') { 'sse' } else { 'http' }
        return [ordered]@{
            type = $type
            url  = $remote.url
        }
    }

    if ($Server.packages -and $Server.packages.Count -gt 0) {
        # Pick the first package; favor npm with runtimeHint=npx (most common in VS Code mcp.json examples).
        $pkg = $Server.packages | Where-Object { $_.registryType -eq 'npm' } | Select-Object -First 1
        if (-not $pkg) { $pkg = $Server.packages[0] }

        switch ($pkg.registryType) {
            'npm' {
                $args = @('-y', $pkg.identifier)
                if ($pkg.packageArguments) {
                    $args += @($pkg.packageArguments | Where-Object { $_.type -eq 'positional' -and $_.value } | ForEach-Object { $_.value })
                }
                return [ordered]@{
                    type    = 'stdio'
                    command = 'npx'
                    args    = $args
                }
            }
            'docker' {
                return [ordered]@{
                    type    = 'stdio'
                    command = 'docker'
                    args    = @('run', '-i', '--rm', $pkg.identifier)
                }
            }
            'pypi' {
                return [ordered]@{
                    type    = 'stdio'
                    command = 'uvx'
                    args    = @($pkg.identifier)
                }
            }
            default {
                # Skip — caller can't represent this server in VS Code yet.
                return $null
            }
        }
    }

    return $null
}

$emitted = [ordered]@{}
$skipped = @()

foreach ($server in $response.servers) {
    if ($Filter -and ($server.name -notlike "*$Filter*")) { continue }

    $entry = ConvertTo-VsCodeServerEntry -Server $server
    if (-not $entry) {
        $skipped += $server.name
        continue
    }

    $key = ConvertTo-VsCodeServerName -RegistryName $server.name
    while ($emitted.Contains($key)) { $key = "$key$([System.Random]::new().Next(100))" }
    $emitted[$key] = $entry
}

$output = [ordered]@{ servers = [ordered]@{} }

if ($Merge -and (Test-Path $OutputPath)) {
    $existing = Get-Content $OutputPath -Raw | ConvertFrom-Json -AsHashtable
    if ($existing.servers) {
        foreach ($k in $existing.servers.Keys) { $output.servers[$k] = $existing.servers[$k] }
    }
}

foreach ($k in $emitted.Keys) { $output.servers[$k] = $emitted[$k] }

$outDir = Split-Path -Parent $OutputPath
if ($outDir -and -not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

$output | ConvertTo-Json -Depth 10 | Set-Content -Path $OutputPath -Encoding utf8

Write-Host ""
Write-Host "Wrote $($emitted.Count) server(s) to $OutputPath" -ForegroundColor Green
if ($skipped.Count -gt 0) {
    Write-Host "Skipped (unsupported registryType): $($skipped -join ', ')" -ForegroundColor Yellow
}
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  1. Reload VS Code (or run 'MCP: List Servers' from the command palette)"
Write-Host "  2. VS Code will prompt to trust each server on first start"
