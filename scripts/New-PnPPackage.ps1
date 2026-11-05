<#
.SYNOPSIS
  Builds the zip a client gets to run Copilot Readiness themselves with PnP PowerShell.

.DESCRIPTION
  Copies the pnp folder, leaving out tests and anything from a local run (settings,
  certificates, results), and puts the rule book next to the module so the package
  works on its own. The rule book itself stays in one place, rules/rulebook.json.
  Also adds START HERE.html: the guide's pages in docs/ joined into one web page with the
  pictures inside, so it opens with a double-click and needs nothing else.

.EXAMPLE
  ./New-PnPPackage.ps1
  # -> dist/CopilotReadiness-PnP-20261023.zip

.EXAMPLE
  ./New-PnPPackage.ps1 -Version 1.0.0
  # -> dist/CopilotReadiness-PnP-1.0.0.zip, the name a release uses
#>
param(
    [string] $OutFolder = (Join-Path $PSScriptRoot '..\dist'),
    # Names the zip for a release. Without it, the zip is named with today's date.
    [string] $Version
)

$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..')
$pnp = Join-Path $root 'pnp'

# Don't ship anything that fails its tests.
& pwsh -NoProfile -File (Join-Path $pnp 'tests\Invoke-AllTests.ps1')
if ($LASTEXITCODE) { throw 'The tests failed; fix them before packaging.' }

$stage = Join-Path ([IO.Path]::GetTempPath()) "cr-pnp-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
$target = Join-Path $stage 'CopilotReadiness-PnP'
New-Item -ItemType Directory -Path $target | Out-Null

try {
    Copy-Item (Join-Path $pnp 'README.md'), (Join-Path $pnp 'Start.ps1'), (Join-Path $pnp 'Start.cmd') $target
    Copy-Item (Join-Path $pnp 'CopilotReadiness') $target -Recurse
    Copy-Item (Join-Path $root 'rules\rulebook.json') (Join-Path $target 'CopilotReadiness')

    # Links between pages become links within the one page. Each page's file name is also its heading's id.
    $docs = Join-Path $root 'docs'
    # Don't ship a broken picture.
    Add-Type -AssemblyName System.Drawing
    foreach ($picture in Get-ChildItem -LiteralPath (Join-Path $docs 'pictures') -Filter '*.png') {
        $image = [System.Drawing.Image]::FromFile($picture.FullName)
        $width = $image.Width; $height = $image.Height
        $image.Dispose()
        if ($width -lt 400 -or $height -lt 100) { throw "$($picture.Name) is only $width by $height. Retake it with scripts/New-GuidePictures.ps1." }
    }
    $pages = 'install', 'setting-it-up', 'running-the-scripts', 'the-reports', 'if-something-goes-wrong', 'more-detail'
    $contents = ($pages | ForEach-Object {
            $heading = (Get-Content -LiteralPath (Join-Path $docs "$_.md") -TotalCount 1 -Encoding utf8) -replace '^#\s*', ''
            "<li><a href=`"#$_`">$heading</a></li>"
        }) -join ''
    $body = ($pages | ForEach-Object { (ConvertFrom-Markdown -LiteralPath (Join-Path $docs "$_.md")).Html }) -join "`n"
    $body = [regex]::Replace($body, 'src="(pictures/[^"]+)"', {
            param($m)
            'src="data:image/png;base64,' + [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $docs $m.Groups[1].Value))) + '"'
        })
    $body = [regex]::Replace($body, 'href="([a-z-]+)\.md(#[^"]+)?"', {
            param($m)
            'href="' + $(if ($m.Groups[2].Success) { $m.Groups[2].Value } else { "#$($m.Groups[1].Value)" }) + '"'
        })
    $page = @"
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Copilot Readiness: how to start</title>
<style>
body { font:16px/1.55 'Segoe UI',system-ui,sans-serif; color:#1f2328; background:#fff; max-width:860px; margin:0 auto; padding:24px 16px 64px; }
h1 { font-size:30px; margin-top:56px; border-bottom:2px solid #d8dde3; padding-bottom:6px; } h1.title { margin-top:0; border:0; } h2 { font-size:20px; margin-top:32px; }
img { max-width:100%; height:auto; border:1px solid #d8dde3; border-radius:6px; margin:8px 0; box-shadow:0 1px 4px rgba(0,0,0,.12); }
code { background:#f2f4f6; padding:1px 5px; border-radius:4px; font-size:14px; } pre { background:#f2f4f6; padding:12px 14px; border-radius:6px; overflow-x:auto; } pre code { padding:0; }
table { border-collapse:collapse; width:100%; display:block; overflow-x:auto; } th,td { border:1px solid #d8dde3; padding:8px 10px; text-align:left; vertical-align:top; } th { background:#f6f7f8; }
a { color:#0f6cbd; }
</style></head><body>
<h1 class="title">Copilot Readiness: how to start</h1>
<p>Follow these in order. You only need the first two once.</p>
<ol>$contents</ol>
$body
</body></html>
"@
    Set-Content -LiteralPath (Join-Path $target 'START HERE.html') -Value $page -Encoding utf8

    New-Item -ItemType Directory -Path $OutFolder -Force | Out-Null
    $zip = Join-Path (Resolve-Path $OutFolder) "CopilotReadiness-PnP-$(if ($Version) { $Version } else { Get-Date -Format yyyyMMdd }).zip"
    Compress-Archive -Path $target -DestinationPath $zip -Force
    Write-Host "Package: $zip"
}
finally {
    Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
}
