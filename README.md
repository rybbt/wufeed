# wufeed — Update Feed

A machine-readable feed of the latest Windows updates per build and architecture,
regenerated after each Patch Tuesday and published to GitHub Pages. Feeds are namespaced
by product under `docs/<product>/`.

## Feed URLs

| Feed | URL |
| --- | --- |
| Index (all products) | `https://wufeed.rybbt.com/index.json` |
| Windows 11 (all builds) | `https://wufeed.rybbt.com/win11/updates.json` |
| Windows 11 24H2 | `https://wufeed.rybbt.com/win11/24H2.json` |
| Windows 11 25H2 | `https://wufeed.rybbt.com/win11/25H2.json` |

`index.json` lists every product feed:

```json
{
  "generated": "2026-07-09",
  "feeds": [
    { "id": "win11", "name": "Windows 11",
      "url": "https://wufeed.rybbt.com/win11/updates.json",
      "architectures": ["x64", "arm64"] }
  ]
}
```

## Update types

Per build and architecture (`x64`, `arm64`), the most recently published update of each
type:

- `cu` — Cumulative Update
- `net` — Cumulative Update for .NET Framework
- `dynamic.safeos` — Safe OS Dynamic Update (WinRE recovery environment)
- `dynamic.setup` — Setup Dynamic Update (Windows Setup binaries)
- `defender` — Microsoft Defender antimalware platform update

Each type carries its own `release_date`; types are published on independent schedules.
Sources: the [Microsoft Update Catalog](https://www.catalog.update.microsoft.com/) (via
[MSCatalogLTS](https://github.com/Marco-online/MSCatalogLTS)) for updates, and the
[Windows release-health](https://learn.microsoft.com/en-us/windows/release-health/windows11-release-information)
page for `eol_date`.

## JSON schema

### Per-build (e.g. `win11/24H2.json`)

```json
{
  "os": "Windows 11",
  "build": "24H2",
  "build_number": "26100",
  "supported": true,
  "eol_date": "2026-10-13",
  "generated": "2026-07-09",
  "architectures": ["x64", "arm64"],
  "updates": {
    "x64": {
      "cu": {
        "kb": "KB5094126",
        "title": "2026-06 Cumulative Update for Windows 11, version 24H2 for x64-based Systems (KB5094126) (26100.8655)",
        "release_notes": "https://support.microsoft.com/help/5094126",
        "catalog_url": "https://www.catalog.update.microsoft.com/ScopedViewInline.aspx?updateid=...",
        "download_url": "https://catalog.sf.dl.delivery.mp.microsoft.com/.../windows11.0-kb5094126-x64_....msu",
        "sha1": "1b7fae96...",
        "size_mb": 5384,
        "release_date": "2026-06-09"
      },
      "net": { "...": "..." },
      "dynamic": {
        "safeos": { "kb": "KB5095615", "size_mb": 145, "...": "..." },
        "setup":  { "kb": "KB5102558", "size_mb": 17,  "...": "..." }
      },
      "defender": { "...": "..." }
    },
    "arm64": { "...": "..." }
  }
}
```

`updates` is keyed by architecture; each architecture holds the five types with the same
leaf shape. A type absent from the catalog is `null`.

Fields:

- `kb` — KB number (e.g. `KB5094126`).
- `title` — catalog title.
- `release_notes` — `https://support.microsoft.com/help/<kb>`.
- `catalog_url` — Microsoft Update Catalog detail page.
- `download_url` — direct download link for the file.
- `sha1` — hex SHA1 of the file; verify with `Get-FileHash -Algorithm SHA1`.
- `size_mb` — file size in MB.
- `release_date` — catalog last-updated date (`yyyy-MM-dd`).
- `eol_date` — end of servicing for Home/Pro editions; `null` if unavailable.

### Combined (`win11/updates.json`)

```json
{
  "product": "win11",
  "os": "Windows 11",
  "generated": "2026-07-09",
  "feed_url": "https://wufeed.rybbt.com/win11/updates.json",
  "architectures": ["x64", "arm64"],
  "builds": {
    "24H2": { "...": "..." },
    "25H2": { "...": "..." }
  }
}
```

`builds.<build>` holds the same object as the per-build file.

## Consume it

Path: `builds[<build>].updates[<arch>].<type>`.

PowerShell (Windows 11 24H2, x64):

```powershell
$feed = Invoke-RestMethod https://wufeed.rybbt.com/win11/updates.json
$cu   = $feed.builds.'24H2'.updates.x64.cu
Invoke-WebRequest $cu.download_url -OutFile ($cu.title.Replace(' ', '_') + '.msu')
(Get-FileHash .\*.msu -Algorithm SHA1).Hash -eq $cu.sha1.ToUpper()
```

curl + jq (arm64 CU download URL):

```bash
curl -s https://wufeed.rybbt.com/win11/24H2.json | jq -r '.updates.arm64.cu.download_url'
```

## How it works

1. `.github/workflows/update-feed.yml` runs on a schedule (Wed 18:00 UTC) and on demand.
2. `scripts/Update-Feed.ps1` reads `config.json` and dispatches each product to its
   collector (`scripts/collectors/Get-WindowsCatalogFeed.ps1` for `windows-catalog`).
3. The collector queries the catalog, resolves download URLs + SHA1, looks up EOL dates,
   and writes `docs/<product>/`. The orchestrator writes `docs/index.json`.
4. A missing Cumulative Update aborts the run (non-zero exit, no commit) and opens a
   failure issue; other types are recorded as `null` when absent.

## Configuration

`config.json`:

```json
{
  "github_username": "rybbt",
  "repo_name": "wufeed",
  "feed_base_url": "https://wufeed.rybbt.com",
  "mscataloglts_version": "2.1.0.2",
  "products": [
    {
      "id": "win11",
      "name": "Windows 11",
      "collector": "windows-catalog",
      "architectures": ["x64", "arm64"],
      "builds": [
        { "name": "24H2", "build_number": "26100", "supported": true },
        { "name": "25H2", "build_number": "26200", "supported": true }
      ]
    }
  ]
}
```

- **Build**: add or edit a product's `builds`; set `"supported": false` at EOL.
- **Architecture**: edit a product's `architectures`; each becomes a key under `updates`.
- **Product**: add a `products` entry with `id`, `name`, `collector`, `architectures`,
  `builds`. A new data source needs a collector script under `scripts/collectors/` and a
  dispatch case in `scripts/Update-Feed.ps1`. Output lands at `docs/<id>/` and is listed
  in `index.json`.
- **Module version**: `mscataloglts_version` is pinned and updated by editing the field.
  `check-module-version.yml` runs weekly and opens an issue when a newer version is on
  the PowerShell Gallery.

## Licence

[MIT](LICENSE).
