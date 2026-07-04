<#
.SYNOPSIS
    Collector for the "windows-catalog" product type.

    Queries the Microsoft Update Catalog (via the pinned MSCatalogLTS module) for the
    latest updates for each supported build of a Windows product, resolves each update's
    direct download URL + SHA1, looks up the build's end-of-servicing date, and writes
    per-build + combined JSON feeds under docs/<product-id>/.

    This file defines functions only; it is dot-sourced by scripts/Update-Feed.ps1.

    Update types collected per build (see README for cadence notes — they publish on
    different schedules, so we always take the MOST RECENT available of each):
      cu              Cumulative Update (the anchor — mandatory; run fails if missing)
      net             .NET Framework Cumulative Update            (best-effort)
      dynamic.safeos  Safe OS Dynamic Update (WinRE)              (best-effort)
      dynamic.setup   Setup Dynamic Update (setup binaries)       (best-effort)
      defender        Microsoft Defender antimalware platform     (best-effort, global)

    HASHES: the Microsoft Update Catalog only exposes a base64 SHA1 digest per file —
    there is NO SHA256 upstream. We publish `sha1` (hex). Verified: the digest matches
    the hex suffix embedded in each update's filename.
#>

Set-StrictMode -Version Latest

# --- Module bootstrap -------------------------------------------------------------

$script:MSCatalogImported = $false

function Initialize-MSCatalog {
    param([Parameter(Mandatory)][string] $Version)

    if ($script:MSCatalogImported) { return }

    $installed = Get-Module -ListAvailable -Name MSCatalogLTS |
        Where-Object { $_.Version.ToString() -eq $Version }

    if (-not $installed) {
        Write-Host "Installing MSCatalogLTS $Version from PSGallery..."
        Install-Module -Name MSCatalogLTS -RequiredVersion $Version `
            -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
    }

    Import-Module -Name MSCatalogLTS -RequiredVersion $Version -Force -ErrorAction Stop
    $script:MSCatalogImported = $true
}

# --- EOL lookup (cached; one page fetch per run) ----------------------------------

$script:EolCache = @{}
$script:ReleaseHealthUrl =
    'https://learn.microsoft.com/en-us/windows/release-health/windows11-release-information'

function Get-Win11EolDate {
    <#
        Scrapes the "current versions by servicing option" table on the release-health
        page. Row layout: Version | Servicing option | Availability date |
        End of updates: Home/Pro | End of updates: Enterprise | ...
        Returns the Home/Pro column (index 3) for the General Availability Channel row,
        or $null (with a warning) if it can't be parsed — EOL is metadata, so a page
        change must not kill the whole feed.
    #>
    param([Parameter(Mandatory)][string] $BuildName)

    if ($script:EolCache.ContainsKey($BuildName)) { return $script:EolCache[$BuildName] }

    $eol = $null
    try {
        $html = (Invoke-WebRequest -Uri $script:ReleaseHealthUrl -UseBasicParsing -ErrorAction Stop).Content
        foreach ($row in [regex]::Matches($html, '(?s)<tr[^>]*>(.*?)</tr>')) {
            $cells = @([regex]::Matches($row.Groups[1].Value, '(?s)<td[^>]*>(.*?)</td>') |
                ForEach-Object { (($_.Groups[1].Value -replace '<[^>]+>', '') -replace '&nbsp;', ' ').Trim() })
            if ($cells.Count -ge 4 -and $cells[0] -eq $BuildName -and $cells[1] -match 'General Availability') {
                if ($cells[3] -match '\d{4}-\d{2}-\d{2}') { $eol = $Matches[0] }
                break
            }
        }
    } catch {
        Write-Warning "Failed to fetch release-health page for EOL lookup: $($_.Exception.Message)"
    }

    if (-not $eol) {
        Write-Warning "Could not determine EOL date for build '$BuildName' (page format may have changed)."
    }
    $script:EolCache[$BuildName] = $eol
    return $eol
}

# --- Download URL + SHA1 (replicates the module's private DownloadDialog POST) -----

function Get-CatalogDownloadInfo {
    <#
        Resolves an update's direct download URL and file digest (base64 SHA1 -> hex).
        Regex only; no HtmlAgilityPack. For checkpoint cumulative updates the dialog
        returns MULTIPLE files (target LCU + checkpoint baseline) in a non-deterministic
        order, so we prefer the file whose name contains the update's own KB number,
        then a .msu, then the first file. Returns [pscustomobject]@{ Url; Sha1 } or $null.
    #>
    param(
        [Parameter(Mandatory)][string] $Guid,
        [string] $KbDigits,
        [string] $Arch = 'x64'
    )

    # Filename token for the requested architecture (Defender packages ship all arches
    # under one GUID; CU/.NET/dynamic are already arch-specific but this stays correct).
    $archPattern = if ($Arch -eq 'arm64') { 'arm64' } else { 'amd64|x64' }

    $post = @{ size = 0; languages = ''; uidInfo = $Guid; updateID = $Guid } | ConvertTo-Json -Compress
    $body = @{ updateIDs = "[$post]" }

    try {
        $resp = Invoke-WebRequest -Uri 'https://www.catalog.update.microsoft.com/DownloadDialog.aspx' `
            -Method Post -Body $body -ContentType 'application/x-www-form-urlencoded' `
            -UseBasicParsing -ErrorAction Stop
    } catch {
        Write-Warning "DownloadDialog request failed for $Guid : $($_.Exception.Message)"
        return $null
    }

    $content = $resp.Content -replace 'www\.download\.windowsupdate', 'download.windowsupdate'

    $urlMatches = @([regex]::Matches($content, "downloadInformation\[(\d+)\]\.files\[(\d+)\]\.url\s*=\s*'([^']*)'"))
    if ($urlMatches.Count -eq 0) {
        Write-Warning "No download links found for $Guid."
        return $null
    }

    # info_file -> base64 digest (SHA1)
    $digestMap = @{}
    foreach ($m in [regex]::Matches($content, "downloadInformation\[(\d+)\]\.files\[(\d+)\]\.digest\s*=\s*'([^']*)'")) {
        $digestMap["$($m.Groups[1].Value)_$($m.Groups[2].Value)"] = $m.Groups[3].Value
    }

    # Deterministically pick the best file. Some updates return multiple files:
    # checkpoint CUs (target LCU + baseline) and the Defender package (amd64/arm64/x86).
    # Score: matching KB (+4) > requested arch (+2) > .msu/.cab (+1). Highest wins.
    $chosen = $urlMatches | Sort-Object -Descending -Stable {
        $u = $_.Groups[3].Value
        $s = 0
        if ($KbDigits -and $u -match "kb$KbDigits\b") { $s += 4 }
        if ($u -match $archPattern) { $s += 2 }
        if ($u -match '\.(msu|cab)(\?|$)') { $s += 1 }
        $s
    } | Select-Object -First 1

    $sha1 = ''
    $key = "$($chosen.Groups[1].Value)_$($chosen.Groups[2].Value)"
    if ($digestMap.ContainsKey($key) -and $digestMap[$key]) {
        try {
            $bytes = [Convert]::FromBase64String($digestMap[$key])
            $sha1 = ([BitConverter]::ToString($bytes) -replace '-', '').ToLower()
        } catch {
            Write-Warning "Could not decode SHA1 digest for $Guid."
        }
    }

    [pscustomobject]@{ Url = $chosen.Groups[3].Value; Sha1 = $sha1 }
}

# --- Record shaping ---------------------------------------------------------------

function ConvertTo-UpdateRecord {
    <# One MSCatalogUpdate -> feed record ([ordered] hashtable). $null if no download. #>
    param(
        [Parameter(Mandatory)] $Update,
        [string] $Arch = 'x64'
    )

    $kb = $null; $kbDigits = $null
    if ($Update.Title -match 'KB(\d+)') { $kbDigits = $Matches[1]; $kb = "KB$kbDigits" }

    $dl = Get-CatalogDownloadInfo -Guid $Update.Guid -KbDigits $kbDigits -Arch $Arch
    if (-not $dl) { return $null }

    $sizeMb = $null
    if ($Update.SizeInBytes) { $sizeMb = [math]::Round([int64]$Update.SizeInBytes / 1MB) }

    [ordered]@{
        kb            = $kb
        title         = $Update.Title
        release_notes = if ($kbDigits) { "https://support.microsoft.com/help/$kbDigits" } else { $null }
        catalog_url   = "https://www.catalog.update.microsoft.com/ScopedViewInline.aspx?updateid=$($Update.Guid)"
        download_url  = $dl.Url
        sha1          = $dl.Sha1
        size_mb       = $sizeMb
        release_date  = $Update.LastUpdated.ToString('yyyy-MM-dd')
    }
}

function Get-BuildUpdate {
    <#
        Runs one catalog query, optionally filters by a title regex, takes the most
        recent, and shapes it into a record. Mandatory updates throw on absence
        (fail-loud); best-effort updates return $null with a warning.
    #>
    param(
        [Parameter(Mandatory)][hashtable] $Query,
        [Parameter(Mandatory)][string]    $Label,
        [string]                          $TitleMustMatch,
        [string]                          $Arch = 'x64',
        [switch]                          $Mandatory
    )

    $raw = @(Get-MSCatalogUpdate @Query)
    if ($TitleMustMatch) { $raw = @($raw | Where-Object { $_.Title -match $TitleMustMatch }) }
    # Select-Object -First 1 (not [0]) so an empty result is $null, never a StrictMode
    # out-of-bounds throw — best-effort misses must degrade to null, not abort the run.
    $update = $raw | Sort-Object LastUpdated -Descending | Select-Object -First 1

    if (-not $update) {
        if ($Mandatory) { throw "No catalog results for mandatory update '$Label'." }
        Write-Warning "No catalog results for '$Label'; recording null."
        return $null
    }

    $record = ConvertTo-UpdateRecord -Update $update -Arch $Arch
    if (-not $record) {
        if ($Mandatory) { throw "Could not resolve download info for mandatory '$Label' ($($update.Title))." }
        Write-Warning "Could not resolve download info for '$Label'; recording null."
        return $null
    }

    Write-Host "  $Label -> $($record.kb) [$($record.release_date)]"
    return $record
}

function Get-ArchUpdates {
    <# Collects all update types for one build + architecture. Returns [ordered] updates. #>
    param(
        [Parameter(Mandatory)][string] $BuildName,
        [Parameter(Mandatory)][string] $Arch
    )
    $h = $BuildName

    # Cumulative Update — the anchor. Mandatory (fail-loud).
    $cu = Get-BuildUpdate -Mandatory -Arch $Arch -Label "$h/$Arch/cu" `
        -Query @{ OperatingSystem = 'Windows 11'; Version = $h; Architecture = $Arch; UpdateType = 'Cumulative Updates'; ExcludeFramework = $true }

    # .NET Framework CU — best-effort (skips some months).
    $net = Get-BuildUpdate -Arch $Arch -Label "$h/$Arch/net" `
        -Query @{ GetFramework = $true; OperatingSystem = 'Windows 11'; Version = $h; Architecture = $Arch }

    # Dynamic Updates — Safe OS + Setup, filtered to this build+arch catalog row. Best-effort.
    $safeos = Get-BuildUpdate -Arch $Arch -Label "$h/$Arch/dynamic.safeos" `
        -Query @{ Search = 'Safe OS Dynamic Update'; IncludeDynamic = $true } `
        -TitleMustMatch "version $h for $Arch"

    $setup = Get-BuildUpdate -Arch $Arch -Label "$h/$Arch/dynamic.setup" `
        -Query @{ Search = 'Setup Dynamic Update'; IncludeDynamic = $true } `
        -TitleMustMatch "version $h for $Arch"

    # Defender antimalware platform — one GUID carries all arches; the file is picked
    # by $Arch. Best-effort.
    $defender = Get-BuildUpdate -Arch $Arch -Label "$h/$Arch/defender" `
        -Query @{ Search = 'Microsoft Defender Antivirus antimalware platform' }

    [ordered]@{
        cu       = $cu
        net      = $net
        dynamic  = [ordered]@{ safeos = $safeos; setup = $setup }
        defender = $defender
    }
}

# --- Main entry point -------------------------------------------------------------

function Get-WindowsCatalogFeed {
    <#
        Builds the feed for one "windows-catalog" product and writes its JSON files.
        Returns the docs/index.json catalog entry for this product.
    #>
    param(
        [Parameter(Mandatory)] $Product,   # config.products[] entry
        [Parameter(Mandatory)] $Config,    # full config object
        [Parameter(Mandatory)][string] $DocsRoot
    )

    Initialize-MSCatalog -Version $Config.mscataloglts_version

    $generated  = (Get-Date).ToString('yyyy-MM-dd')
    $osName     = $Product.name
    $productDir = Join-Path $DocsRoot $Product.id
    New-Item -ItemType Directory -Path $productDir -Force | Out-Null

    $architectures = @($Product.architectures)
    if ($architectures.Count -eq 0) { $architectures = @('x64') }

    $buildsOut = [ordered]@{}

    foreach ($build in $Product.builds) {
        if (-not $build.supported) { Write-Host "Skipping unsupported build $($build.name)."; continue }

        $h = $build.name
        Write-Host "== $osName $h ($($build.build_number)) =="

        $eol = Get-Win11EolDate -BuildName $h

        # Collect every update type per architecture, nested as updates.<arch>.<type>.
        $archUpdates = [ordered]@{}
        foreach ($arch in $architectures) {
            Write-Host "  -- $arch --"
            $archUpdates[$arch] = Get-ArchUpdates -BuildName $h -Arch $arch
        }

        $buildObj = [ordered]@{
            os            = $osName
            build         = $h
            build_number  = $build.build_number
            supported     = [bool]$build.supported
            eol_date      = $eol
            generated     = $generated
            architectures = $architectures
            updates       = $archUpdates
        }

        $buildPath = Join-Path $productDir "$h.json"
        $buildObj | ConvertTo-Json -Depth 9 | Out-File -FilePath $buildPath -Encoding utf8
        Write-Host "  wrote $buildPath"

        $buildsOut[$h] = $buildObj
    }

    if ($buildsOut.Count -eq 0) {
        throw "Product '$($Product.id)' has no supported builds; refusing to publish an empty feed."
    }

    $feedUrl = "$($Config.feed_base_url.TrimEnd('/'))/$($Product.id)/updates.json"

    $combined = [ordered]@{
        product       = $Product.id
        os            = $osName
        generated     = $generated
        feed_url      = $feedUrl
        architectures = $architectures
        builds        = $buildsOut
    }
    $combinedPath = Join-Path $productDir 'updates.json'
    $combined | ConvertTo-Json -Depth 11 | Out-File -FilePath $combinedPath -Encoding utf8
    Write-Host "  wrote $combinedPath"

    [ordered]@{ id = $Product.id; name = $Product.name; url = $feedUrl; architectures = $architectures }
}
