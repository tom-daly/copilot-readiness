# Results of a finished scan. sites.json and findings.json hold the results for other tools. The CSV
# files open in Excel; report.html is the report people read, and links to the CSV files.

function Export-CrResults {
    param(
        [Parameter(Mandatory)] [string] $Folder,
        [Parameter(Mandatory)] $Scan,
        [object[]] $Sites = @(),
        [object[]] $Findings = @(),
        # Every file, folder and list item with its own permissions (Standard and Deep scans).
        [object[]] $UniqueItems = @()
    )
    $book = Get-CrRuleBook
    $rank = @{}
    for ($i = 0; $i -lt $book.severities.Count; $i++) { $rank[$book.severities[$i]] = $i }
    $sorted = @($Findings | Sort-Object -Stable { $rank[$_.severity] }, siteUrl, path)
    $sitesSorted = @($Sites | Sort-Object -Stable { if ($null -eq $_.score) { 101 } else { [int]$_.score } }, url)

    Write-CrJson (Join-Path $Folder 'sites.json') $sitesSorted
    Write-CrJson (Join-Path $Folder 'findings.json') $sorted

    $titles = @{}
    $kinds = @{}
    # A site with no title (such as the search site) goes by its address.
    foreach ($s in $Sites) { $titles[$s.siteId] = if ($s.title) { $s.title } else { $s.url }; $kinds[$s.siteId] = if ($s.kind) { $s.kind } else { 'SharePoint' } }
    $checkNames = @{}
    foreach ($c in $book.checks) { $checkNames[$c.id] = $c.name }
    $rules = @{}
    foreach ($r in $book.rules) { $rules[$r.id] = $r }

    # Excel opens UTF-8 with a byte order mark without mangling accents. The same rows go in the report's Table view.
    $findingRows = @($sorted | ForEach-Object {
        [pscustomobject][ordered]@{
            'Severity'     = $_.severity
            'Area'         = $checkNames[$_.check]
            'Issue'        = $rules[$_.rule].name
            'Site'         = $titles[$_.siteId]
            'Site URL'     = $_.siteUrl
            'Kind'         = $kinds[$_.siteId]
            'Location'     = Get-CrItemPlace $_
            'Type'         = $_.objectType
            'Who'          = $_.principal
            'Permission'   = $_.permission
            'Detail'       = $_.detail
            'What to do'   = $rules[$_.rule].advice
            'Finding ID'   = $_.id
            'Checked at'   = $_.verifiedAt
            'Link'         = Get-CrItemUrl $_
        }
    })
    $findingRows | Export-Csv -LiteralPath (Join-Path $Folder 'findings.csv') -NoTypeInformation -Encoding utf8BOM

    # One spreadsheet per OneDrive with findings, so each owner can be handed just their own.
    $oneDriveRows = @{}
    for ($i = 0; $i -lt $sorted.Count; $i++) {
        $siteId = $sorted[$i].siteId
        if ($kinds[$siteId] -ne 'OneDrive') { continue }
        if (-not $oneDriveRows.ContainsKey($siteId)) { $oneDriveRows[$siteId] = [System.Collections.Generic.List[object]]::new() }
        $oneDriveRows[$siteId].Add($findingRows[$i])
    }
    $oneDriveFiles = @{}
    if ($oneDriveRows.Count) {
        $oneDriveFolder = Join-Path $Folder 'onedrives'
        New-Item -ItemType Directory -Path $oneDriveFolder -Force | Out-Null
        $usedNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($siteId in @($oneDriveRows.Keys | Sort-Object)) {
            $file = Get-CrOneDriveFileName -Title $titles[$siteId] -SiteId $siteId -Used $usedNames
            $oneDriveRows[$siteId] | Export-Csv -LiteralPath (Join-Path $oneDriveFolder $file) -NoTypeInformation -Encoding utf8BOM
            $oneDriveFiles[$siteId] = "onedrives/$([uri]::EscapeDataString($file))"
        }
    }

    $siteRows = @($sitesSorted | ForEach-Object {
        [pscustomobject][ordered]@{
            'Site'                       = if ($_.title) { $_.title } else { $_.url }
            'URL'                        = $_.url
            'Kind'                       = if ($_.kind) { $_.kind } else { 'SharePoint' }
            'Status'                     = $_.status
            'Score'                      = $_.score
            'High'                       = $_.findingCounts.High
            'Medium'                     = $_.findingCounts.Medium
            'Low'                        = $_.findingCounts.Low
            'Microsoft 365 group'        = if ($_.isGroupConnected) { 'Yes' } else { 'No' }
            'Sensitivity label'          = $_.sensitivityLabel
            'Last activity'              = $_.lastActivityAt
            'Owners'                     = $_.ownerCount
            'Guests'                     = $_.guestCount
            'Subsites'                   = $_.subsiteCount
            'Items with own permissions' = $_.uniqueItemCount
            'Error'                      = $_.error
        }
    })
    $siteRows | Export-Csv -LiteralPath (Join-Path $Folder 'sites.csv') -NoTypeInformation -Encoding utf8BOM

    $uniqueSorted = @($UniqueItems | Sort-Object -Stable siteUrl, library, path)
    $uniqueRows = @()
    if ($Scan.level -ne 'Quick') {
        $types = @{ File = 'File'; Folder = 'Folder'; Item = 'List item' }
        $uniqueRows = @($uniqueSorted | ForEach-Object {
                [pscustomobject][ordered]@{
                    'Site'                 = $titles[$_.siteId]
                    'Site URL'             = $_.siteUrl
                    'Library or list'      = Get-CrLibraryName $_
                    'Location'             = Get-CrItemPlace $_
                    'Type'                 = $types["$($_.objectType)"]
                    'Who has access'       = if ($Scan.level -eq 'Deep') { $_.access } else { 'Run a Deep scan to see' }
                    'Link'                 = Get-CrItemUrl $_
                }
            })
        $uniqueRows | Export-Csv -LiteralPath (Join-Path $Folder 'unique-permissions.csv') -NoTypeInformation -Encoding utf8BOM
    }

    # The Table view: the spreadsheets' own columns. Links say which column holds the address a cell opens;
    # Hidden columns start hidden (people can show them); Columns is used when a table has no rows.
    $tables = @(
        [pscustomobject]@{ Id = 'findings'; Name = 'Findings'; File = 'findings.csv'; Rows = $findingRows
            Columns = @('Severity', 'Area', 'Issue', 'Site', 'Site URL', 'Kind', 'Location', 'Type', 'Who', 'Permission', 'Detail', 'What to do', 'Finding ID', 'Checked at', 'Link')
            Links = @{ Site = 'Site URL'; Location = 'Link' }; Hidden = @('Site URL', 'What to do', 'Finding ID', 'Checked at', 'Link') },
        [pscustomobject]@{ Id = 'sites'; Name = 'Sites'; File = 'sites.csv'; Rows = $siteRows
            Columns = @('Site', 'URL', 'Kind', 'Status', 'Score', 'High', 'Medium', 'Low', 'Microsoft 365 group', 'Sensitivity label', 'Last activity', 'Owners', 'Guests', 'Subsites', 'Items with own permissions', 'Error')
            Links = @{ Site = 'URL' }; Hidden = @('URL') }
    )
    if ($Scan.level -ne 'Quick') {
        $tables += [pscustomobject]@{ Id = 'own'; Name = 'Items with their own permissions'; File = 'unique-permissions.csv'; Rows = $uniqueRows
            Columns = @('Site', 'Site URL', 'Library or list', 'Location', 'Type', 'Who has access', 'Link')
            Links = @{ Site = 'Site URL'; Location = 'Link' }; Hidden = @('Site URL', 'Link') }
    }

    $scope = Read-CrJson (Join-Path $Folder 'scope.json')
    New-CrReportHtml -Scan $Scan -Scope $scope -Sites $sitesSorted -Findings $sorted -UniqueItems $uniqueSorted -Tables $tables -OneDriveFiles $oneDriveFiles |
        Set-Content -LiteralPath (Join-Path $Folder 'report.html') -Encoding utf8
}

function Get-CrOneDriveFileName {
    <# A safe file name from the owner's name. Two owners with the same name get separate files. #>
    param([string] $Title, [string] $SiteId, [System.Collections.Generic.HashSet[string]] $Used)
    $name = (($Title -replace '[<>:"/\\|?*\x00-\x1f]', ' ') -replace '\s+', ' ').Trim()
    if ($name.Length -gt 80) { $name = $name.Substring(0, 80) }
    $name = $name.Trim().TrimEnd('.').Trim()
    $key = Get-CrSiteKey $SiteId
    if (-not $name) { $name = $key }
    if ($name -match '^(CON|PRN|AUX|NUL|COM\d|LPT\d)$') { $name = "OneDrive $name" }
    if (-not $Used.Add($name)) { $name = "$name ($key)"; $null = $Used.Add($name) }
    "$name.csv"
}

function Get-CrItemUrl {
    <# The address to open a finding's site, library, folder or file in the browser. #>
    param($Finding)
    if (-not $Finding.path) { return $Finding.siteUrl }
    $origin = ([uri]$Finding.siteUrl).GetLeftPart([UriPartial]::Authority)
    # A list item's path is its display form, e.g. /sites/x/Lists/Tasks/DispForm.aspx?ID=7; keep the ?ID= as it is.
    $path, $query = $Finding.path.Split('?', 2)
    $origin + (($path -split '/' | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/') + $(if ($query) { "?$query" })
}

function Get-CrLibraryName {
    <#
      A library or list's name as people know it ("Documents"), with the subsite it is in,
      if any ("Tasks (in projects)"). Results saved before names were kept fall back to the
      last part of its address ("Requests"), and to "Documents" for the standard library.
    #>
    param($Item)
    $parts = @((Get-CrItemPlace ([pscustomobject]@{ siteUrl = $Item.siteUrl; path = $Item.library })) -split '/')
    # Every site's standard library lives at "Shared Documents" but is called "Documents".
    $name = if ($Item.libraryName) { $Item.libraryName } elseif ($parts[-1] -eq 'Shared Documents') { 'Documents' } else { $parts[-1] }
    $web = @($parts | Select-Object -SkipLast 1 | Where-Object { $_ -and $_ -ne 'Lists' })
    if ($web.Count) { "$name (in $($web -join '/'))" } else { $name }
}
function Get-CrItemPlace {
    <# Where a finding is, in words: the whole site, the group, or the path inside the site. #>
    param($Finding)
    if (-not $Finding.path) { if ($Finding.objectType -eq 'Group') { return 'Microsoft 365 group' } else { return 'Whole site' } }
    $sitePath = [uri]::UnescapeDataString(([uri]$Finding.siteUrl).AbsolutePath).TrimEnd('/')
    $place = if ($sitePath -and $Finding.path.StartsWith("$sitePath/", [StringComparison]::OrdinalIgnoreCase)) { $Finding.path.Substring($sitePath.Length + 1) } else { $Finding.path }
    if ($place -match '^(.*)/DispForm\.aspx\?ID=(\d+)$') { return "$($Matches[1]), item $($Matches[2])" }
    $place
}

function New-CrReportHtml {
    <#
      The report people read: the score, then every issue two ways (by kind of issue and
      by site), each in a section that opens on a click, with links to the site, library,
      folder or file. A search box and filters narrow it down. One file, works offline.
    #>
    param($Scan, $Scope, [object[]] $Sites, [object[]] $Findings, [object[]] $UniqueItems = @(), [object[]] $Tables = @(), [hashtable] $OneDriveFiles = @{})

    # Past these, a section points to findings.csv rather than listing everything.
    $maxPerIssue = 300
    $maxPerSite = 200

    $book = Get-CrRuleBook
    function Enc([object] $s) { [System.Net.WebUtility]::HtmlEncode("$s") }
    # The OneDrive score; scans from before OneDrive had one work it out from the OneDrives' scores.
    $odScore = if ($Scan.PSObject.Properties['oneDriveScore'] -and $null -ne $Scan.oneDriveScore) { $Scan.oneDriveScore } else { Get-CrTenantScore @($Sites | Where-Object { $_.kind -eq 'OneDrive' -and $_.status -eq 'Done' -and $null -ne $_.score } | ForEach-Object { [int]$_.score }) }
    function Ring($score, $name) {
        "<div class='ring'><div class='score $(Band $score)'><b>$(if ($null -eq $score) { '&mdash;' } else { $score })</b><span>out of 100</span></div><div>$name</div></div>"
    }
    function Band($score) {
        if ($null -eq $score) { 'none' } elseif ($score -ge $book.score.bands.good) { 'good' } elseif ($score -ge $book.score.bands.fair) { 'fair' } else { 'poor' }
    }

    $level = Get-CrScanLevels | Where-Object Id -EQ $Scan.level
    $spSites = @($Sites | Where-Object { $_.kind -ne 'OneDrive' })
    $odSites = @($Sites | Where-Object { $_.kind -eq 'OneDrive' })
    $spTotal = @($Scope.sites | Where-Object { $_.kind -ne 'OneDrive' }).Count
    $odTotal = @($Scope.sites | Where-Object { $_.kind -eq 'OneDrive' }).Count
    $done = @($spSites | Where-Object status -EQ 'Done').Count
    $failed = @($Sites | Where-Object status -EQ 'Failed')
    $skipped = @($Sites | Where-Object status -EQ 'Skipped')
    $when = ([DateTimeOffset]::Parse($Scan.completedAt, [Globalization.CultureInfo]::InvariantCulture)).ToLocalTime().ToString('MMMM d, yyyy, h:mm tt')
    $sitesById = @{}
    foreach ($s in $Sites) { $sitesById[$s.siteId] = $s }
    $rules = @{}
    foreach ($r in $book.rules) { $rules[$r.id] = $r }
    $checkNames = @{}
    foreach ($c in $book.checks) { $checkNames[$c.id] = $c.name }
    $rank = @{}
    for ($i = 0; $i -lt $book.severities.Count; $i++) { $rank[$book.severities[$i]] = $i }

    function FindingRow($f, [switch] $ShowSite) {
        $site = $sitesById[$f.siteId]
        $siteCell = if ($ShowSite) {
            $key = Get-CrSiteKey $f.siteId
            "<td><a href='#site-$key' class='jump'>$(Enc $(if ($site.title) { $site.title } else { $f.siteUrl }))</a></td>"
        }
        $what = if ($ShowSite) { '' } else { "<td><span class='pill $($f.severity)'>$($f.severity)</span> $(Enc $rules[$f.rule].name)</td>" }
        $detail = if ($f.detail) { "<div class='muted'>$(Enc $f.detail)</div>" } else { '' }
        "<tr data-sev='$($f.severity)' data-check='$($f.check)' data-kind='$(if ($site.kind) { $site.kind } else { 'SharePoint' })'>$what$siteCell" +
        "<td class='path'><a href='$(Enc (Get-CrItemUrl $f))' target='_blank' rel='noopener'>$(Enc (Get-CrItemPlace $f))</a>$detail</td>" +
        "<td>$(Enc $f.principal)</td><td>$(Enc $f.permission)</td></tr>"
    }

    $sb = [System.Text.StringBuilder]::new()
    $null = $sb.Append(@'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Copilot Readiness report</title>
<style>
:root { --bg:#f7f7f5; --card:#fff; --text:#1f2328; --muted:#5f6670; --line:#e3e3df; --accent:#0969da; --good:#1a7f37; --fair:#b35900; --poor:#c62828; --none:#6e7781; --high:#c62828; --medium:#b35900; --low:#5f6670; --chip:#eef1f4; }
@media (prefers-color-scheme: dark) { :root { --bg:#16181b; --card:#1f2226; --text:#e6e6e3; --muted:#a0a6ad; --line:#33373c; --accent:#58a6ff; --good:#4ac26b; --fair:#e3a33b; --poor:#ff6b6b; --none:#8b949e; --high:#ff6b6b; --medium:#e3a33b; --low:#a0a6ad; --chip:#2a2e33; } }
* { box-sizing: border-box; }
body { margin:0; background:var(--bg); color:var(--text); font:15px/1.5 "Segoe UI", system-ui, sans-serif; }
main { margin:0; padding:32px 32px 64px; }
@media (max-width: 700px) { main { padding:24px 16px 48px; } }
a { color:var(--accent); }
h1 { font-size:26px; margin:0 0 4px; }
h2 { font-size:19px; margin:40px 0 6px; }
.muted { color:var(--muted); }
.top { display:flex; gap:24px; align-items:center; flex-wrap:wrap; margin-top:24px; }
.top > div:last-child { flex:1; min-width:260px; }
.score { width:132px; height:132px; border-radius:50%; border:8px solid currentColor; display:flex; flex-direction:column; align-items:center; justify-content:center; }
.score b { font-size:40px; line-height:1; }
.score span { font-size:12px; color:var(--muted); }
.rings { display:flex; gap:20px; }
.ring { display:flex; flex-direction:column; align-items:center; gap:6px; }
.ring > div:last-child { font-size:13px; font-weight:600; color:var(--muted); }
.good { color:var(--good); } .fair { color:var(--fair); } .poor { color:var(--poor); } .none { color:var(--none); }
.files { display:flex; gap:8px; flex-wrap:wrap; margin-top:10px; }
.files a { text-decoration:none; background:var(--card); border:1px solid var(--line); border-radius:6px; padding:4px 10px; font-size:13px; }
.files a:hover { border-color:var(--accent); }
.cards { display:grid; grid-template-columns:repeat(auto-fit, minmax(230px, 1fr)); gap:12px; }
.card { background:var(--card); border:1px solid var(--line); border-radius:8px; padding:14px 16px; cursor:pointer; text-align:left; font:inherit; color:inherit; display:flex; flex-direction:column; justify-content:flex-start; }
.card:hover { border-color:var(--accent); }
.card.active { border-color:var(--accent); box-shadow:0 0 0 2px var(--accent) inset; }
.card h3 { margin:0 0 4px; font-size:15px; }
.card p { margin:0 0 10px; font-size:13px; color:var(--muted); }
.pills { display:flex; gap:6px; flex-wrap:wrap; }
.pill { display:inline-block; font-size:12px; line-height:18px; border-radius:999px; padding:0 9px; border:1px solid currentColor; white-space:nowrap; }
.High { color:var(--high); } .Medium { color:var(--medium); } .Low { color:var(--low); }
.toolbar { position:sticky; top:0; z-index:2; background:var(--bg); display:flex; gap:8px; flex-wrap:wrap; align-items:center; padding:10px 0; margin-top:28px; border-bottom:1px solid var(--line); }
.toolbar input { flex:1; min-width:200px; font:inherit; padding:6px 10px; border:1px solid var(--line); border-radius:6px; background:var(--card); color:var(--text); }
.toolbar button { font:inherit; font-size:13px; padding:5px 12px; border:1px solid var(--line); border-radius:999px; background:var(--card); color:var(--text); cursor:pointer; }
.toolbar button[aria-pressed="false"] { opacity:.45; text-decoration:line-through; }
.toolbar .sep { width:1px; align-self:stretch; background:var(--line); margin:0 4px; }
#filter-note { width:100%; font-size:13px; color:var(--muted); }
details.group { background:var(--card); border:1px solid var(--line); border-radius:8px; margin:8px 0; }
details.group > summary { list-style:none; cursor:pointer; padding:12px 16px; display:flex; gap:10px; align-items:center; flex-wrap:wrap; }
details.group > summary::-webkit-details-marker { display:none; }
details.group > summary::before { content:"\25B8"; color:var(--muted); width:12px; transition:transform .15s; }
details.group[open] > summary::before { transform:rotate(90deg); }
details.group > summary .name { font-weight:600; }
details.group > summary .right { margin-left:auto; display:flex; gap:6px; align-items:center; flex-wrap:wrap; }
.body { padding:0 16px 14px 38px; }
.body p { margin:0 0 10px; }
.facts { display:flex; gap:6px 16px; flex-wrap:wrap; font-size:13px; color:var(--muted); margin-bottom:10px; }
.table { overflow-x:auto; }
table { border-collapse:collapse; width:100%; font-size:13px; }
th, td { text-align:left; padding:7px 10px; border-bottom:1px solid var(--line); vertical-align:top; }
th { color:var(--muted); font-weight:600; white-space:nowrap; }
tr:last-child td { border-bottom:0; }
.path { word-break:break-word; }
.badge { font-weight:700; min-width:34px; text-align:right; }
.more { font-size:13px; color:var(--muted); margin-top:8px; }
.empty { color:var(--muted); font-size:13px; }
@media print { .toolbar, .files, .views { display:none; } details.group { break-inside:avoid; } }
.views { display:inline-flex; margin-top:24px; border:1px solid var(--line); border-radius:8px; overflow:hidden; }
.views button { font:inherit; padding:7px 20px; border:0; background:var(--card); color:var(--text); cursor:pointer; }
.views button + button { border-left:1px solid var(--line); }
.views button[aria-pressed="true"] { background:var(--accent); color:#fff; }
.ttabs { display:flex; gap:8px; flex-wrap:wrap; margin:20px 0 10px; }
.ttabs button { font:inherit; font-size:14px; padding:6px 14px; border:1px solid var(--line); border-radius:999px; background:var(--card); color:var(--text); cursor:pointer; }
.ttabs button[aria-pressed="true"] { border-color:var(--accent); box-shadow:0 0 0 1px var(--accent) inset; font-weight:600; }
.tbar { display:flex; gap:10px; align-items:center; flex-wrap:wrap; margin-bottom:8px; font-size:13px; }
.tbar .grow { flex:1; color:var(--muted); }
.tbar button, .tbar summary { font:inherit; font-size:13px; padding:4px 12px; border:1px solid var(--line); border-radius:6px; background:var(--card); color:var(--text); cursor:pointer; list-style:none; }
.tbar summary::-webkit-details-marker { display:none; }
.cols { position:relative; }
.cols > div { position:absolute; right:0; z-index:5; background:var(--card); border:1px solid var(--line); border-radius:6px; padding:8px 12px; margin-top:4px; max-height:320px; overflow:auto; white-space:nowrap; box-shadow:0 4px 16px rgba(0,0,0,.12); }
.cols label { display:block; padding:2px 0; cursor:pointer; }
#view-table .table { max-height:75vh; overflow:auto; border:1px solid var(--line); border-radius:8px; background:var(--card); }
#t thead { position:sticky; top:0; z-index:1; background:var(--card); }
#t th.sort { cursor:pointer; user-select:none; }
#t th.sort:hover { color:var(--accent); }
#t tr.filters th { padding:4px 6px 8px; }
#t tr.filters input, #t tr.filters select { width:100%; min-width:80px; font:inherit; font-size:12px; padding:3px 6px; border:1px solid var(--line); border-radius:4px; background:var(--bg); color:var(--text); }
#t td.High { color:var(--high); font-weight:600; } #t td.Medium { color:var(--medium); font-weight:600; }
#t td.short { white-space:nowrap; }
#t td.wide { min-width:240px; }
</style>
</head>
<body>
<main>
'@)

    $null = $sb.Append(@"
<h1>Copilot Readiness report</h1>
<div class='muted'>$(Enc $Scope.tenant) &middot; $(Enc $level.Name) scan ($(Enc $level.Summary.ToLowerInvariant())) &middot; $(Enc $when)</div>
<div class='top'>
  <div class='rings'>$(if ($spTotal) { Ring $Scan.score 'SharePoint sites' })$(if ($odTotal) { Ring $odScore 'OneDrive' })</div>
  <div>
    <div>$(if ($spTotal) { "<b>$done</b> of $spTotal SharePoint sites checked" })$(if ($spTotal -and $odTotal) { ' &middot; ' })$(if ($odTotal) { "<b>$(@($odSites | Where-Object status -EQ 'Done').Count)</b> of $odTotal OneDrives checked" })$(if ($failed.Count) { ", <a href='#failed'><b>$($failed.Count)</b> could not be read</a>" })$(if ($skipped.Count) { ", <a href='#skipped'><b>$($skipped.Count)</b> left out</a>" })</div>
    <div><b>$($Scan.findingsTotal)</b> findings</div>
    <div class='muted'>Higher is more ready. Each site starts at $($book.score.start) and loses $($book.score.penalty.High) per High, $($book.score.penalty.Medium) per Medium and $($book.score.penalty.Low) per Low finding. $(if ($spTotal) { 'The SharePoint score is the average of the sites.' })$(if ($odTotal) { ' Each OneDrive is scored the same way, and the OneDrive score is the average of the OneDrives, kept apart from the SharePoint score.' })</div>
    <div class='files'>
      <a href='findings.csv' download>Every finding (findings.csv)</a>
      <a href='sites.csv' download>Every site (sites.csv)</a>
      <a href='findings.json' download>findings.json</a>
      <a href='sites.json' download>sites.json</a>
      $(if ($Scan.level -ne 'Quick') { "<a href='unique-permissions.csv' download>Every item with its own permissions (unique-permissions.csv)</a>" })
    </div>
  </div>
</div>
$(if ($Tables.Count) { "<div class='views' role='group' aria-label='View'><button type='button' data-view='report' aria-pressed='true'>Report</button><button type='button' data-view='table' aria-pressed='false'>Table</button></div>" })
<div id='view-report'>
<h2>By area</h2>
<p class='muted'>Click an area to show only its issues below.</p>
<div class='cards'>
"@)

    foreach ($c in $book.checks) {
        $byCheck = $Scan.counts.($c.id)
        $null = $sb.Append("<button type='button' class='card' data-area='$($c.id)'><h3>$(Enc $c.name)</h3><p>$(Enc $c.description)</p><div class='pills'>")
        foreach ($s in $book.severities) { $null = $sb.Append("<span class='pill $s'>$([int]$byCheck.$s) $s</span>") }
        $null = $sb.Append('</div></button>')
    }
    $null = $sb.Append('</div>')

    $null = $sb.Append(@"
<div class='toolbar'>
  <input id='q' type='search' placeholder='Search sites, files, people...' aria-label='Search'>
  $(($book.severities | ForEach-Object { "<button type='button' class='$_' data-sev='$_' aria-pressed='true'>$_</button>" }) -join '')
  $(if ($spTotal -and $odTotal) { "<span class='sep'></span><button type='button' data-kind='SharePoint' aria-pressed='true'>SharePoint</button><button type='button' data-kind='OneDrive' aria-pressed='true'>OneDrive</button>" })
  <span class='sep'></span>
  <button type='button' id='open-all'>Open all</button>
  <button type='button' id='close-all'>Close all</button>
  <div id='filter-note'></div>
</div>
"@)

    # ── Issues, one section per kind ──
    $null = $sb.Append("<h2 id='issues'>Issues by type</h2><p class='muted'>What was found, worst first. Open one to see where, and follow the links to fix it.</p>")
    $byRule = $Findings | Group-Object rule
    $ordered = @($book.rules | Where-Object { $_.id -in $byRule.Name } | Sort-Object -Stable { $rank[$_.severity] })
    if (-not $ordered.Count) { $null = $sb.Append("<p class='empty'>No issues found.</p>") }
    foreach ($r in $ordered) {
        $items = @(($byRule | Where-Object Name -CEQ $r.id).Group | Sort-Object -Stable { $rank[$_.severity] }, siteUrl, path)
        $siteN = @($items.siteId | Sort-Object -Unique).Count
        $open = if ($r.severity -eq 'High') { ' open' } else { '' }
        $null = $sb.Append("<details class='group' data-group id='issue-$($r.id)'$open><summary><span class='pill $($r.severity)'>$($r.severity)</span><span class='name'>$(Enc $r.name)</span>" +
            "<span class='right muted'>$($items.Count) found on $siteN $(if ($siteN -eq 1) { 'site' } else { 'sites' }) &middot; $(Enc $checkNames[$r.check])</span></summary><div class='body'>" +
            "<p>$(Enc $r.advice)</p><div class='table'><table><thead><tr><th>Site</th><th>Where</th><th>Who</th><th>Permission</th></tr></thead><tbody>")
        foreach ($f in $items | Select-Object -First $maxPerIssue) { $null = $sb.Append((FindingRow $f -ShowSite)) }
        $null = $sb.Append('</tbody></table></div>')
        if ($items.Count -gt $maxPerIssue) { $null = $sb.Append("<div class='more'>Showing the first $maxPerIssue of $($items.Count). <a href='findings.csv' download>findings.csv</a> has them all.</div>") }
        $null = $sb.Append('</div></details>')
    }

    # ── Sites, one section each, lowest score first ──
    $bySite = @{}
    foreach ($g in $Findings | Group-Object siteId) { $bySite[$g.Name] = $g.Group }
    if ($spTotal) { $null = $sb.Append("<h2 id='sites'>Sites</h2><p class='muted'>Lowest scores first. Open a site to see its details and every issue on it.</p>") }
    foreach ($s in $spSites | Where-Object status -NotIn 'Failed', 'Skipped') {
        $key = Get-CrSiteKey $s.siteId
        $items = @($bySite[$s.siteId] | Where-Object { $_ } | Sort-Object -Stable { $rank[$_.severity] }, path)
        $pills = ($book.severities | Where-Object { [int]$s.findingCounts.$_ } | ForEach-Object { "<span class='pill $_'>$($s.findingCounts.$_) $_</span>" }) -join ''
        $facts = @(
            $(if ($s.isGroupConnected) { 'Microsoft 365 group' } else { 'No Microsoft 365 group' }),
            $(if ($s.sensitivityLabel) { "Label: $($s.sensitivityLabel)" } else { 'No label' }),
            "$($s.ownerCount) $(if ($s.ownerCount -eq 1) { 'owner' } else { 'owners' })",
            "$($s.guestCount) $(if ($s.guestCount -eq 1) { 'guest' } else { 'guests' })",
            $(if ($s.lastActivityAt) { "Last changed $(([DateTimeOffset]::Parse($s.lastActivityAt, [Globalization.CultureInfo]::InvariantCulture)).ToLocalTime().ToString('MMM d, yyyy'))" }),
            $(if ($s.subsiteCount) { "$($s.subsiteCount) $(if ($s.subsiteCount -eq 1) { 'subsite' } else { 'subsites' })" })
        ) | Where-Object { $_ }
        $ownLink = if ($s.uniqueItemCount) { "<a href='#perm-$key'>$($s.uniqueItemCount) $(if ($s.uniqueItemCount -eq 1) { 'item' } else { 'items' }) with their own permissions</a>" } else { '' }

        $null = $sb.Append("<details class='group' data-group id='site-$key'><summary><span class='badge $(Band $s.score)'>$($s.score)</span>" +
            "<span class='name'>$(Enc $s.title)</span><span class='muted path'>$(Enc $s.url)</span><span class='right'>$pills</span></summary><div class='body'>" +
            "<div class='facts'><a href='$(Enc $s.url)' target='_blank' rel='noopener'>Open site</a>$(($facts | ForEach-Object { "<span>$(Enc $_)</span>" }) -join '')$ownLink</div>")
        if ($items.Count) {
            $null = $sb.Append("<div class='table'><table><thead><tr><th>Issue</th><th>Where</th><th>Who</th><th>Permission</th></tr></thead><tbody>")
            foreach ($f in $items | Select-Object -First $maxPerSite) { $null = $sb.Append((FindingRow $f)) }
            $null = $sb.Append('</tbody></table></div>')
            if ($items.Count -gt $maxPerSite) { $null = $sb.Append("<div class='more'>Showing the first $maxPerSite of $($items.Count). <a href='findings.csv' download>findings.csv</a> has them all.</div>") }
        }
        else {
            $null = $sb.Append("<p class='empty'>No issues found on this site.</p>")
        }
        $null = $sb.Append('</div></details>')
    }

    # ── Every item with its own permissions, one section per site, for people to go through ──
    if ($spTotal -and $Scan.level -ne 'Quick') {
        $deep = $Scan.level -eq 'Deep'
        $typeNames = @{ File = 'File'; Folder = 'Folder'; Item = 'List item' }
        $null = $sb.Append("<h2 id='own-permissions'>Files and folders with their own permissions</h2><p class='muted'>Every file, folder and list item that doesn't follow its library's permissions, " +
            "so you can decide whether each one should. These don't change the score: each library already loses points for having them. " +
            "$(if ($deep) { 'Who has access is listed for each.' } else { 'Run a Deep scan to see who has access to each.' }) " +
            "<a href='unique-permissions.csv' download>unique-permissions.csv</a> has them all.</p>")
        $byOwnSite = @{}
        foreach ($g in $UniqueItems | Group-Object siteId) { $byOwnSite[$g.Name] = $g.Group }
        $withOwn = @($spSites | Where-Object { $byOwnSite[$_.siteId] } | Sort-Object -Stable @{ Expression = { @($byOwnSite[$_.siteId]).Count }; Descending = $true }, title)
        if (-not $withOwn.Count) { $null = $sb.Append("<p class='empty'>None found.</p>") }
        foreach ($s in $withOwn) {
            $key = Get-CrSiteKey $s.siteId
            $items = @($byOwnSite[$s.siteId])
            $null = $sb.Append("<details class='group' data-perm id='perm-$key'><summary><span class='name'>$(Enc $s.title)</span><span class='muted path'>$(Enc $s.url)</span>" +
                "<span class='right muted'>$($items.Count) $(if ($items.Count -eq 1) { 'item' } else { 'items' })</span></summary><div class='body'>" +
                "<div class='table'><table><thead><tr><th>Library or list</th><th>Where</th><th>Type</th>$(if ($deep) { '<th>Who has access</th>' })</tr></thead><tbody>")
            foreach ($u in $items | Select-Object -First $maxPerSite) {
                $library = Get-CrLibraryName $u
                $null = $sb.Append("<tr><td>$(Enc $library)</td><td class='path'><a href='$(Enc (Get-CrItemUrl $u))' target='_blank' rel='noopener'>$(Enc (Get-CrItemPlace $u))</a></td>" +
                    "<td>$(Enc $typeNames["$($u.objectType)"])</td>$(if ($deep) { "<td>$(Enc $u.access)</td>" })</tr>")
            }
            $null = $sb.Append('</tbody></table></div>')
            if ($items.Count -gt $maxPerSite) { $null = $sb.Append("<div class='more'>Showing the first $maxPerSite of $($items.Count). <a href='unique-permissions.csv' download>unique-permissions.csv</a> has them all.</div>") }
            $null = $sb.Append('</div></details>')
        }
    }

    # OneDrive: only the ones with something shared too widely get a section; the rest are counted.
    if ($odTotal) {
        $withIssues = @($odSites | Where-Object { $_.status -eq 'Done' -and $bySite[$_.siteId] } |
                Sort-Object -Stable @{ Expression = { [int]$_.findingCounts.High }; Descending = $true }, @{ Expression = { @($bySite[$_.siteId]).Count }; Descending = $true }, title)
        $clean = @($odSites | Where-Object { $_.status -eq 'Done' }).Count - $withIssues.Count
        $null = $sb.Append("<h2 id='onedrive'>OneDrive</h2><p class='muted'>People's OneDrives with files shared too widely, most serious first. " +
            "$(if ($clean -gt 0) { "$clean $(if ($clean -eq 1) { 'OneDrive has' } else { 'OneDrives have' }) nothing shared too widely. " })OneDrive is checked only for ""Everyone"" access, ""Anyone"" links, company-wide links and guests, and has a score of its own. Each one below has its own spreadsheet, also saved in the onedrives folder next to this report.</p>")
        foreach ($s in $withIssues) {
            $key = Get-CrSiteKey $s.siteId
            $ownCsv = $OneDriveFiles[$s.siteId]
            $items = @($bySite[$s.siteId] | Sort-Object -Stable { $rank[$_.severity] }, path)
            $pills = ($book.severities | Where-Object { [int]$s.findingCounts.$_ } | ForEach-Object { "<span class='pill $_'>$($s.findingCounts.$_) $_</span>" }) -join ''
            $null = $sb.Append("<details class='group' data-group id='site-$key'><summary><span class='badge $(Band $s.score)'>$($s.score)</span><span class='name'>$(Enc $s.title)</span><span class='muted path'>$(Enc $s.url)</span><span class='right'>$pills</span></summary><div class='body'>" +
                "<div class='facts'><a href='$(Enc $s.url)' target='_blank' rel='noopener'>Open OneDrive</a>$(if ($ownCsv) { "<a href='$(Enc $ownCsv)' download>Download this OneDrive's findings (CSV)</a>" })<span>Owner: $(Enc $s.title)</span>" +
                "$(if ($s.lastActivityAt) { "<span>Last changed $(([DateTimeOffset]::Parse($s.lastActivityAt, [Globalization.CultureInfo]::InvariantCulture)).ToLocalTime().ToString('MMM d, yyyy'))</span>" })</div>" +
                "<div class='table'><table><thead><tr><th>Issue</th><th>Where</th><th>Who</th><th>Permission</th></tr></thead><tbody>")
            foreach ($f in $items | Select-Object -First $maxPerSite) { $null = $sb.Append((FindingRow $f)) }
            $null = $sb.Append('</tbody></table></div>')
            if ($items.Count -gt $maxPerSite) { $null = $sb.Append("<div class='more'>Showing the first $maxPerSite of $($items.Count). <a href='$(Enc $(if ($ownCsv) { $ownCsv } else { 'findings.csv' }))' download>The spreadsheet</a> has them all.</div>") }
            $null = $sb.Append('</div></details>')
        }
    }

    if ($failed.Count) {
        $null = $sb.Append("<h2 id='failed'>Sites that could not be read</h2><p class='muted'>Run the scan again to retry them. If they keep failing, the reason is below.</p>" +
            "<div class='table'><table><thead><tr><th>Site</th><th>Reason</th></tr></thead><tbody>")
        foreach ($s in $failed) { $null = $sb.Append("<tr><td><a href='$(Enc $s.url)' target='_blank' rel='noopener'>$(Enc $s.url)</a></td><td class='path'>$(Enc $s.error)</td></tr>") }
        $null = $sb.Append('</tbody></table></div>')
    }

    if ($skipped.Count) {
        # Archived or locked sites, which nobody can open, and sites the rule book sets aside on purpose, such as the app catalog.
        $null = $sb.Append("<h2 id='skipped'>Sites left out</h2><p class='muted'>These sites weren't checked or scored. Each one says why. " +
            "An archived or locked site carries no Copilot risk while it stays that way; scan it again if it is brought back.</p>" +
            "<div class='table'><table><thead><tr><th>Site</th><th>Address</th><th>Why it was left out</th></tr></thead><tbody>")
        foreach ($s in $skipped) {
            # A set-aside site's reason starts with its kind ("App catalog: ..."); show the kind on its own line.
            $why = if ("$($s.error)" -match '^([^:.]+): (.*)$') { "<b>$(Enc $Matches[1])</b><div class='muted'>$(Enc $Matches[2])</div>" } else { Enc $s.error }
            $null = $sb.Append("<tr><td>$(Enc $(if ($s.title) { $s.title } else { $s.url }))</td><td class='path'>$(Enc $s.url)</td><td>$why</td></tr>")
        }
        $null = $sb.Append('</tbody></table></div>')
    }

    $null = $sb.Append('</div>')

    # ── Table view: the spreadsheets' rows, to sort and filter in the page ──
    if ($Tables.Count) {
        $tableData = @(foreach ($tb in $Tables) {
                $cols = @($tb.Columns)
                [ordered]@{
                    id = $tb.Id; name = $tb.Name; file = $tb.File; columns = $cols; hidden = @($tb.Hidden); links = $tb.Links
                    rows = @(foreach ($row in $tb.Rows) {
                            , @(foreach ($c in $cols) {
                                    $v = $row.$c
                                    if ($null -eq $v) { '' } elseif ($v -is [int] -or $v -is [long] -or $v -is [double] -or $v -is [decimal]) { $v } else { "$v" }
                                })
                        })
                }
            })
        # Inside a script tag, "</" would end it early.
        $json = (ConvertTo-Json -InputObject $tableData -Depth 6 -Compress).Replace('</', '<\/')
        $null = $sb.Append("<div id='view-table' hidden><p class='muted' style='margin-top:20px'>The same rows as the spreadsheets. Click a column heading to sort by it, and type or pick under a heading to filter. " +
            "<b>Download these rows</b> saves just what you see, in the order you see it.</p>" +
            "<div class='ttabs' id='t-tabs'></div><div class='tbar'><span class='grow' id='t-count'></span><button type='button' id='t-clear'>Clear filters</button>" +
            "<details class='cols'><summary>Columns</summary><div id='t-cols'></div></details><button type='button' id='t-csv'>Download these rows</button></div>" +
            "<div class='table'><table id='t'><thead></thead><tbody></tbody></table></div><div class='more' id='t-more'></div></div>" +
            "<script type='application/json' id='table-data'>$json</script>")
    }

    $null = $sb.Append("<p class='muted' style='margin-top:40px'>Scan $(Enc $Scan.scanId), rule book version $(Enc $Scope.rulebook).</p></main>")
    $null = $sb.Append(@'
<script>
(function () {
  var sev = { High: true, Medium: true, Low: true }, kind = { SharePoint: true, OneDrive: true }, area = null, q = '';
  var note = document.getElementById('filter-note');
  function filtering() { return q || area || !sev.High || !sev.Medium || !sev.Low || !kind.SharePoint || !kind.OneDrive; }
  function apply() {
    document.querySelectorAll('tr[data-sev]').forEach(function (tr) {
      tr.hidden = !(sev[tr.dataset.sev] && kind[tr.dataset.kind] !== false && (!area || tr.dataset.check === area) && (!q || tr.textContent.toLowerCase().indexOf(q) >= 0));
    });
    var shown = 0;
    document.querySelectorAll('details[data-group]').forEach(function (d) {
      var rows = d.querySelectorAll('tr[data-sev]'), any = false;
      rows.forEach(function (r) { if (!r.hidden) any = true; });
      var nameHit = q && d.querySelector('summary').textContent.toLowerCase().indexOf(q) >= 0 && !area;
      d.hidden = filtering() && !any && !nameHit;
      if (!d.hidden) shown++;
      if (q && any) d.open = true;
    });
    var parts = [];
    if (area) parts.push('only ' + document.querySelector('.card[data-area="' + area + '"] h3').textContent);
    ['High', 'Medium', 'Low'].forEach(function (s) { if (!sev[s]) parts.push('hiding ' + s); });
    ['SharePoint', 'OneDrive'].forEach(function (k) { if (!kind[k]) parts.push('hiding ' + k); });
    if (q) parts.push('matching "' + q + '"');
    note.textContent = filtering() ? 'Filtered: ' + parts.join(', ') + '. ' + shown + (shown === 1 ? ' section' : ' sections') + ' shown.' : '';
  }
  document.getElementById('q').addEventListener('input', function (e) { q = e.target.value.trim().toLowerCase(); apply(); });
  document.querySelectorAll('.toolbar button[data-sev]').forEach(function (b) {
    b.addEventListener('click', function () { sev[b.dataset.sev] = !sev[b.dataset.sev]; b.setAttribute('aria-pressed', sev[b.dataset.sev]); apply(); });
  });
  document.querySelectorAll('.toolbar button[data-kind]').forEach(function (b) {
    b.addEventListener('click', function () { kind[b.dataset.kind] = !kind[b.dataset.kind]; b.setAttribute('aria-pressed', kind[b.dataset.kind]); apply(); });
  });
  document.querySelectorAll('.card[data-area]').forEach(function (c) {
    c.addEventListener('click', function () {
      area = area === c.dataset.area ? null : c.dataset.area;
      document.querySelectorAll('.card').forEach(function (x) { x.classList.toggle('active', x.dataset.area === area); });
      apply();
      if (area) document.getElementById('issues').scrollIntoView({ behavior: 'smooth' });
    });
  });
  document.getElementById('open-all').addEventListener('click', function () { document.querySelectorAll('details[data-group]:not([hidden]), details[data-perm]').forEach(function (d) { d.open = true; }); });
  document.getElementById('close-all').addEventListener('click', function () { document.querySelectorAll('details[data-group], details[data-perm]').forEach(function (d) { d.open = false; }); });
  // A link to a section (#site-...) opens it. Viewers that lock the report in a frame, such as
  // OneDrive's, won't let a link or script change the address, so the page moves itself.
  function openTarget(hash) {
    var t = hash && document.getElementById(hash.slice(1));
    if (t) {
      if (t.tagName === 'DETAILS') { t.hidden = false; t.open = true; }
      t.scrollIntoView();
    }
    if (hash === '#all') document.querySelectorAll('details[data-group]').forEach(function (d) { d.open = true; });
  }
  document.addEventListener('click', function (e) {
    var a = e.target.closest("a[href^='#']");
    if (!a) return;
    e.preventDefault();
    var hash = a.getAttribute('href');
    try { history.pushState(null, '', hash); } catch (err) { }
    openTarget(hash);
  });
  window.addEventListener('hashchange', function () { openTarget(location.hash); });
  openTarget(location.hash);
})();
</script>
<script>
// The Table view: sort by any column, filter under each heading, show or hide columns, download what is shown.
(function () {
  var dataEl = document.getElementById('table-data');
  if (!dataEl) return;
  var tables = JSON.parse(dataEl.textContent);
  var reportView = document.getElementById('view-report'), tableView = document.getElementById('view-table');
  var head = document.querySelector('#t thead'), body = document.querySelector('#t tbody');
  var countEl = document.getElementById('t-count'), moreEl = document.getElementById('t-more'), colsEl = document.getElementById('t-cols'), tabsEl = document.getElementById('t-tabs');
  var rank = { High: 0, Medium: 1, Low: 2 }, states = {}, current = null, timer = null;

  function esc(s) { return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]; }); }
  function fmt(n) { return n.toLocaleString('en-US'); }

  function state(t) {
    if (!states[t.id]) {
      // Columns with only a few different values get a pick list; the rest a text box.
      var picks = t.columns.map(function (c, i) {
        var seen = {}, n = 0;
        for (var r = 0; r < t.rows.length; r++) {
          var v = String(t.rows[r][i]);
          if (v !== '' && !seen.hasOwnProperty(v)) { seen[v] = 1; if (++n > 15) return null; }
        }
        var list = Object.keys(seen);
        return list.length ? list.sort(function (a, b) { return c === 'Severity' ? rank[a] - rank[b] : a.localeCompare(b, 'en', { numeric: true }); }) : null;
      });
      states[t.id] = { sort: -1, dir: 1, filters: {}, hidden: t.hidden.slice(), limit: 200, picks: picks };
    }
    return states[t.id];
  }
  function visible(t, s) { return t.columns.map(function (c, i) { return i; }).filter(function (i) { return s.hidden.indexOf(t.columns[i]) < 0; }); }

  function shown(t, s) {
    var keys = Object.keys(s.filters).filter(function (i) { return s.filters[i] !== ''; });
    var rows = t.rows.filter(function (row) {
      for (var k = 0; k < keys.length; k++) {
        var i = keys[k], f = s.filters[i], v = String(row[i]);
        if (s.picks[i] ? v !== f : v.toLowerCase().indexOf(f.toLowerCase()) < 0) return false;
      }
      return true;
    });
    if (s.sort >= 0) {
      var i = s.sort, sev = t.columns[i] === 'Severity';
      rows = rows.slice().sort(function (a, b) {
        var x = a[i], y = b[i];
        if (x === '' || x == null) return (y === '' || y == null) ? 0 : 1;
        if (y === '' || y == null) return -1;
        var d = sev ? rank[x] - rank[y] : (typeof x === 'number' && typeof y === 'number') ? x - y : String(x).localeCompare(String(y), 'en', { numeric: true, sensitivity: 'base' });
        return d * s.dir;
      });
    }
    return rows;
  }

  function cell(t, row, i) {
    var name = t.columns[i], v = row[i], link = t.links[name];
    var text = typeof v === 'number' ? fmt(v) : esc(v);
    if (link) {
      var href = row[t.columns.indexOf(link)];
      if (href) text = "<a href='" + esc(href) + "' target='_blank' rel='noopener'>" + text + '</a>';
    }
    // Short values stay on one line; long ones get room to wrap.
    var kind = ['Severity', 'Area', 'Issue', 'Kind', 'Type', 'Permission', 'Status', 'Score', 'High', 'Medium', 'Low', 'Owners', 'Guests', 'Subsites', 'Microsoft 365 group'].indexOf(name) >= 0 ? 'short'
      : ['Location', 'Detail', 'Who', 'Who has access', 'What to do', 'Error', 'Library or list'].indexOf(name) >= 0 ? 'wide path' : '';
    if (name === 'Severity') kind += ' ' + esc(v);
    return '<td' + (kind ? " class='" + kind + "'" : '') + '>' + text + '</td>';
  }

  function renderBody() {
    var t = current, s = state(t), rows = shown(t, s), vis = visible(t, s), html = [];
    for (var r = 0; r < Math.min(s.limit, rows.length); r++) html.push('<tr>' + vis.map(function (i) { return cell(t, rows[r], i); }).join('') + '</tr>');
    body.innerHTML = html.join('') || "<tr><td colspan='" + vis.length + "' class='empty'>No rows match.</td></tr>";
    var filtered = rows.length !== t.rows.length;
    countEl.textContent = (rows.length > s.limit ? 'Showing ' + fmt(s.limit) + ' of ' + fmt(rows.length) : fmt(rows.length)) + (rows.length === 1 ? ' row' : ' rows') + (filtered ? ' (filtered from ' + fmt(t.rows.length) + ')' : '');
    moreEl.innerHTML = rows.length > s.limit ? "<button type='button' data-more='200'>Show 200 more</button> <button type='button' data-more='all'>Show all</button>" : '';
  }

  function renderHead() {
    var t = current, s = state(t), vis = visible(t, s);
    var top = vis.map(function (i) {
      var arrow = s.sort === i ? (s.dir > 0 ? ' \u25B2' : ' \u25BC') : '';
      return "<th class='sort' data-i='" + i + "' title='Sort by this column'>" + esc(t.columns[i]) + arrow + '</th>';
    }).join('');
    var filters = vis.map(function (i) {
      var f = s.filters[i] || '';
      if (s.picks[i]) return "<th><select data-i='" + i + "' aria-label='Filter " + esc(t.columns[i]) + "'><option value=''>All</option>" +
        s.picks[i].map(function (v) { return "<option" + (v === f ? ' selected' : '') + ">" + esc(v) + '</option>'; }).join('') + '</select></th>';
      return "<th><input type='search' data-i='" + i + "' value='" + esc(f) + "' placeholder='Filter' aria-label='Filter " + esc(t.columns[i]) + "'></th>";
    }).join('');
    head.innerHTML = '<tr>' + top + "</tr><tr class='filters'>" + filters + '</tr>';
    colsEl.innerHTML = t.columns.map(function (c) {
      return "<label><input type='checkbox' data-col='" + esc(c) + "'" + (s.hidden.indexOf(c) < 0 ? ' checked' : '') + '> ' + esc(c) + '</label>';
    }).join('');
  }

  function pick(id) {
    current = tables.filter(function (t) { return t.id === id; })[0] || tables[0];
    Array.prototype.forEach.call(tabsEl.children, function (b) { b.setAttribute('aria-pressed', b.dataset.table === current.id); });
    renderHead(); renderBody();
  }

  tabsEl.innerHTML = tables.map(function (t) { return "<button type='button' data-table='" + esc(t.id) + "' aria-pressed='false'>" + esc(t.name) + ' (' + fmt(t.rows.length) + ')</button>'; }).join('');
  tabsEl.addEventListener('click', function (e) { var b = e.target.closest('button'); if (b) pick(b.dataset.table); });
  head.addEventListener('click', function (e) {
    var th = e.target.closest('th.sort'); if (!th) return;
    var s = state(current), i = +th.dataset.i;
    if (s.sort === i) s.dir = -s.dir; else { s.sort = i; s.dir = 1; }
    renderHead(); renderBody();
  });
  head.addEventListener('input', function (e) {
    var el = e.target; if (!el.dataset.i) return;
    var s = state(current); s.filters[el.dataset.i] = el.value; s.limit = 200;
    // A pick applies at once; typing waits for a pause.
    clearTimeout(timer);
    if (el.tagName === 'SELECT') renderBody(); else timer = setTimeout(renderBody, 150);
  });
  colsEl.addEventListener('change', function (e) {
    var c = e.target.dataset.col, s = state(current), at = s.hidden.indexOf(c);
    if (e.target.checked && at >= 0) s.hidden.splice(at, 1); else if (!e.target.checked && at < 0) s.hidden.push(c);
    renderHead(); renderBody();
  });
  moreEl.addEventListener('click', function (e) {
    var b = e.target.closest('button'); if (!b) return;
    var s = state(current); s.limit = b.dataset.more === 'all' ? Infinity : s.limit + 200; renderBody();
  });
  document.getElementById('t-clear').addEventListener('click', function () { var s = state(current); s.filters = {}; s.limit = 200; renderHead(); renderBody(); });
  document.getElementById('t-csv').addEventListener('click', function () {
    var t = current, rows = shown(t, state(t));
    var q = function (v) { v = String(v == null ? '' : v); return /[",\r\n]/.test(v) ? '"' + v.replace(/"/g, '""') + '"' : v; };
    var csv = '\uFEFF' + [t.columns.map(q).join(',')].concat(rows.map(function (r) { return r.map(q).join(','); })).join('\r\n');
    var a = document.createElement('a');
    a.href = URL.createObjectURL(new Blob([csv], { type: 'text/csv;charset=utf-8' }));
    a.download = t.file.replace(/\.csv$/, '') + '-filtered.csv';
    document.body.appendChild(a); a.click(); a.remove();
  });

  // Report or Table; #table in the address opens the Table view.
  function showView(v) {
    reportView.hidden = v !== 'report'; tableView.hidden = v !== 'table';
    document.querySelectorAll('.views button').forEach(function (b) { b.setAttribute('aria-pressed', b.dataset.view === v); });
    if (v === 'table' && !current) pick(tables[0].id);
  }
  document.querySelectorAll('.views button').forEach(function (b) {
    b.addEventListener('click', function () {
      showView(b.dataset.view);
      // Only remembers the view in the address; some viewers refuse, and the view has already changed.
      try { history.replaceState(null, '', b.dataset.view === 'table' ? '#table' : location.pathname); } catch (err) { }
    });
  });
  if (location.hash === '#table') showView('table');
})();
</script>
</body>
</html>
'@)
    $sb.ToString()
}
