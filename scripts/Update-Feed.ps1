#!/usr/bin/env pwsh
<#
.SYNOPSIS
    wufeed orchestrator. Reads config.json, runs the collector for each product, and
    writes the root feed catalog (docs/index.json).

.DESCRIPTION
    Product-namespaced by design: every product declares a `collector` type and its own
    builds in config.json, and its output lands under docs/<id>/. Adding a new product
    later is a config entry plus (if it needs a new source) a collector script and a
    dispatch case below — not a reshape.

    Fail-loud: any collector that can't produce a complete feed throws, aborting the run
    with a non-zero exit code so stale data is never published.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$DocsRoot = Join-Path $RepoRoot 'docs'

# Load config.
$configPath = Join-Path $RepoRoot 'config.json'
if (-not (Test-Path $configPath)) { throw "config.json not found at $configPath" }
$config = Get-Content -Path $configPath -Raw | ConvertFrom-Json

# Dot-source collectors.
. (Join-Path $PSScriptRoot 'collectors/Get-WindowsCatalogFeed.ps1')

New-Item -ItemType Directory -Path $DocsRoot -Force | Out-Null

$feeds = @()
foreach ($product in $config.products) {
    Write-Host "### Product: $($product.name) [$($product.id)] via '$($product.collector)'"
    switch ($product.collector) {
        'windows-catalog' {
            $feeds += Get-WindowsCatalogFeed -Product $product -Config $config -DocsRoot $DocsRoot
        }
        default {
            throw "Unknown collector '$($product.collector)' for product '$($product.id)'. " +
                  "Add a dispatch case in Update-Feed.ps1 and a matching collector script."
        }
    }
}

if ($feeds.Count -eq 0) {
    throw "No product feeds were produced; refusing to write an empty catalog."
}

# Root feed catalog: docs/index.json
$index = [ordered]@{
    generated = (Get-Date).ToString('yyyy-MM-dd')
    feeds     = $feeds
}
$indexPath = Join-Path $DocsRoot 'index.json'
$index | ConvertTo-Json -Depth 5 | Out-File -FilePath $indexPath -Encoding utf8
Write-Host "Wrote $indexPath"

Write-Host "Done. Produced $($feeds.Count) product feed(s)."
