# Fixes, for the Remediation tab. The first, and so far only, fix removes sharing links.
#
# Each fix is a folder under the results folder's "fixes" folder. fix.json says what to
# do and where. The Preview step goes through those sites and lists every sharing link it
# finds, and which of them would be removed, without changing anything (preview.json and
# preview.csv). The Remove step then removes exactly the links the preview listed, and
# nothing else (removed.json and removed.csv); a link already gone by then is skipped.
# Like a scan, each step runs in a hidden PowerShell window (Start.ps1 -RunFix) and keeps
# progress.json up to date for the window to follow. A stop.request file stops it.
#
# Access given straight to a person, and owners' and members' access, are never touched:
# only sharing links are looked at.

$script:NoShareId = '00000000-0000-0000-0000-000000000000'

# How often Remove saves how far it has got for the window (every link's result is written as it happens).
$script:ProgressEverySeconds = 2

# How many of the people on one link are named in "Shared with"; past that it says how many more.
$script:MaxLinkMembers = 100

# The words each link type is shown with, in the window and the spreadsheets.
$script:LinkTypeWords = [ordered]@{
    Anyone         = 'Anyone'
    Organization   = 'People in your organization'
    SpecificPeople = 'Specific people'
    Other          = 'Other link'
}

# The link types that can be picked for removal, one tick box each.
$script:LinkTypes = @('Anyone', 'Organization', 'SpecificPeople', 'Other')

function Get-CrLinkTypes {
    <# The link types a fix removes: Options.links, a list of types, in the order of $script:LinkTypes. #>
    param([Parameter(Mandatory)] $Options)
    $picked = @($Options.links | ForEach-Object { "$_" })
    @($script:LinkTypes | Where-Object { $picked -contains $_ })
}

function Get-CrLinkTypeWord {
    param([string] $Type)
    if ($script:LinkTypeWords.Contains($Type)) { $script:LinkTypeWords[$Type] } else { $Type }
}

function Get-CrFixRoot {
    <# Where fixes are kept: a "fixes" folder inside the results folder, which the scan lists ignore. #>
    param([Parameter(Mandatory)] [string] $ResultsRoot)
    Join-Path $ResultsRoot 'fixes'
}

# How long the list of Teams and channel sites is kept before it's read again; Refresh on the Tenant tab reads it at once.
$script:TeamsMarksDays = 7

function Read-CrTeamsMarks {
    <#
      Which SharePoint sites belong to a Team ('Team') or to a private or shared channel
      ('Channel'), from the admin center's list of sites: address -> mark. The admin center
      leaves channel sites out of its list unless they're asked for by their own kinds
      (TEAMCHANNEL#0 private, TEAMCHANNEL#1 shared), so those are asked for too. Uses its own
      connection, so the main one is left alone.
    #>
    param([Parameter(Mandatory)] $Settings)
    $admin = Get-CrAdminUrl $Settings.sharePointUrl
    $connection = Invoke-CrCertificateWait { Connect-PnPOnline -Url $admin -ClientId $Settings.app.clientId -Tenant $Settings.tenant -Thumbprint $Settings.app.thumbprint -ReturnConnection -ErrorAction Stop }
    $marks = [ordered]@{}
    foreach ($t in Get-PnPTenantSite -Connection $connection -ErrorAction Stop) {
        $mark = if ($t.IsTeamsChannelConnected -or "$($t.Template)" -like 'TEAMCHANNEL#*') { 'Channel' } elseif ($t.IsTeamsConnected) { 'Team' } else { $null }
        if ($mark) { $marks["$($t.Url)".TrimEnd('/').ToLowerInvariant()] = $mark }
    }
    foreach ($template in 'TEAMCHANNEL#0', 'TEAMCHANNEL#1') {
        try { foreach ($t in Get-PnPTenantSite -Connection $connection -Template $template -ErrorAction Stop) { $marks["$($t.Url)".TrimEnd('/').ToLowerInvariant()] = 'Channel' } }
        catch { Write-Verbose "Couldn't list $template sites: $($_.Exception.Message)" }
    }
    $marks
}

function Get-CrTeamsMarks {
    <#
      The Teams and channel marks (Read-CrTeamsMarks), kept in the results folder so the window
      doesn't list every site in the tenant each time it opens. Read again once they're a week
      old, or with -Refresh; if they can't be read then, the saved ones are used. Returns
      address -> mark.
    #>
    param([Parameter(Mandatory)] $Settings, [Parameter(Mandatory)] [string] $ResultsRoot, [switch] $Refresh)
    $path = Join-Path $ResultsRoot ("teams-sites-{0}.json" -f (Get-CrTenantFileName $Settings.tenant))
    $kept = Get-CrKeptCopy -Path $path -MaxAgeDays $script:TeamsMarksDays -Refresh:$Refresh -Read { Read-CrTeamsMarks $Settings }
    if ($kept.Problem) { Write-Host "Couldn't read which sites belong to Teams just now, so using the list from before: $($kept.Problem)" }
    $marks = @{}
    $read = ConvertTo-CrDictionary $kept.Value
    foreach ($k in $read.Keys) { $marks[$k] = "$($read[$k])" }
    $marks
}

function Add-CrTeamsKinds {
    <#
      Marks each site with the Teams and channel marks (Get-CrTeamsMarks): teams = 'Team' or
      'Channel', or nothing for other sites.
    #>
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Sites, [Parameter(Mandatory)] [hashtable] $Marks)
    foreach ($s in $Sites) { $s | Add-Member -NotePropertyName teams -NotePropertyValue $Marks["$($s.url)".TrimEnd('/').ToLowerInvariant()] -Force }
}

function Get-CrSitePlace {
    <# SharePoint, Team, Channel or OneDrive: the filter a site is listed under on the Remediation tab. #>
    param([Parameter(Mandatory)] $Site)
    if ($Site.kind -eq 'OneDrive') { return 'OneDrive' }
    # A fix's own list of sites carries the place already.
    if ($Site.PSObject.Properties['place'] -and "$($Site.place)" -in 'SharePoint', 'Team', 'Channel', 'OneDrive') { return "$($Site.place)" }
    $teams = if ($Site.PSObject.Properties['teams']) { "$($Site.teams)" } else { '' }
    if ($teams -in 'Team', 'Channel') { return $teams }
    'SharePoint'
}

function Get-CrLinkType {
    <#
      A sharing link's type from SharePoint's details of it: Anyone, Organization,
      SpecificPeople, or Other for anything else (such as "People with existing access").
      LinkKind 2 and 3 are company-wide view and edit links, 4 and 5 Anyone view and edit,
      and 6 the newer kind whose Scope says who it is for (0 Anyone, 1 company, 2 specific people).
    #>
    param([Parameter(Mandatory)] $Details)
    $kind = [int]$Details.LinkKind
    if ($kind -in 2, 3) { return 'Organization' }
    if ($kind -in 4, 5) { return 'Anyone' }
    if ($kind -eq 6) {
        switch ([int]$Details.Scope) {
            0 { return 'Anyone' }
            1 { return 'Organization' }
            2 { return 'SpecificPeople' }
        }
    }
    'Other'
}

function Get-CrFixCutoff {
    <#
      The date a link must be made before to be removed, or nothing when any age goes.
      Options.age is Any, OlderThan (Options.days before Now) or Before (Options.before,
      a yyyy-MM-dd date, from the start of that day on this PC).
    #>
    param([Parameter(Mandatory)] $Options, [Parameter(Mandatory)] [DateTimeOffset] $Now)
    switch ($Options.age) {
        'OlderThan' { return $Now.AddDays(-[int]$Options.days) }
        'Before' {
            $day = [DateTime]::ParseExact("$($Options.before)", 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
            return [DateTimeOffset]::new($day)
        }
        default { return $null }
    }
}

function Get-CrLinkDecision {
    <#
      Whether a link goes: Remove (true or false) and, when it stays, Why in plain words.
      Created is when the link was made, or nothing when SharePoint didn't say; such a link
      is kept whenever an age was chosen, since its age can't be known.
    #>
    param(
        [Parameter(Mandatory)] [string] $Type,
        [Nullable[DateTimeOffset]] $Created,
        [Parameter(Mandatory)] $Options,
        [Nullable[DateTimeOffset]] $Cutoff
    )
    if ($Type -notin (Get-CrLinkTypes $Options)) {
        return [pscustomobject]@{ Remove = $false; Why = 'Not one of the link types chosen' }
    }
    if ($Options.age -eq 'Any') { return [pscustomobject]@{ Remove = $true; Why = '' } }
    if ($null -eq $Created) { return [pscustomobject]@{ Remove = $false; Why = 'Date made unknown' } }
    if ($Created -lt $Cutoff) { return [pscustomobject]@{ Remove = $true; Why = '' } }
    [pscustomobject]@{ Remove = $false; Why = "Made on or after $($Cutoff.ToLocalTime().ToString('MMM d, yyyy'))" }
}

function Get-CrLinkKey {
    <# One link of a preview, as text that names it: its site, list, item and link. #>
    param([Parameter(Mandatory)] $Link)
    "$($Link.site)|$($Link.listId)|$($Link.itemId)|$($Link.shareId)"
}

function ConvertTo-CrLinkDate {
    <# SharePoint's date text as a date, or nothing when it is empty or unreadable. #>
    param([string] $Text)
    $d = [DateTimeOffset]::MinValue
    if ($Text -and [DateTimeOffset]::TryParse($Text, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$d)) { return $d }
    $null
}

# ── A fix's folder ──────────────────────────────────────────────────────────

function New-CrFix {
    <#
      Creates a fix's folder with what to do (Options: links, a list of link types; age, days,
      before) and where
      (Sites, each with url, title, kind and teams). Returns the folder.
    #>
    param(
        [Parameter(Mandatory)] [string] $ResultsRoot,
        [Parameter(Mandatory)] [string] $Tenant,
        [Parameter(Mandatory)] [object[]] $Sites,
        [Parameter(Mandatory)] $Options
    )
    $now = [DateTimeOffset]::UtcNow
    # Down to the millisecond, so the newest fix is always the last by name (see Get-CrLatestFix).
    $fixId = "$($now.ToString('yyyyMMdd''T''HHmmssfff'))-$([guid]::NewGuid().ToString('N').Substring(0, 4))"
    $folder = Join-Path (Get-CrFixRoot $ResultsRoot) $fixId
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
    Write-CrJson (Join-Path $folder 'fix.json') ([pscustomobject][ordered]@{
            fixId       = $fixId
            tenant      = $Tenant
            action      = 'RemoveLinks'
            options     = [pscustomobject][ordered]@{ links = @(Get-CrLinkTypes $Options); fullCheck = [bool]$Options.fullCheck; age = "$($Options.age)"; days = [int]$Options.days; before = "$($Options.before)" }
            requestedBy = "$([Environment]::UserName) on $([Environment]::MachineName)"
            createdAt   = $now.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
            sites       = @($Sites | ForEach-Object {
                    [pscustomobject][ordered]@{ url = "$($_.url)"; title = "$($_.title)"; kind = "$($_.kind)"; place = (Get-CrSitePlace $_) }
                })
        })
    $folder
}

function Write-CrFixProgress {
    <#
      Writes progress.json for a fix: which process, which step (Preview or Remove), its
      state, how far along (Done of Total), what it is on now, the counts so far, and any
      sites that couldn't be checked.
    #>
    param(
        [Parameter(Mandatory)] [string] $Folder,
        [Parameter(Mandatory)] [ValidateSet('Preview', 'Remove')] [string] $Step,
        [Parameter(Mandatory)] [string] $State,
        [int] $Total,
        [int] $Done,
        [string] $Current,
        [hashtable] $Counts = @{},
        [object[]] $Problems = @(),
        [string] $ErrorText,
        [System.Diagnostics.Process] $Process = (Get-Process -Id $PID)
    )
    Write-CrJson (Join-Path $Folder 'progress.json') ([pscustomobject][ordered]@{
            pid              = $Process.Id
            processStartedAt = Get-CrProcessStamp $Process
            step             = $Step
            state            = $State
            total            = $Total
            done             = $Done
            current          = $Current
            found            = [int]$Counts.found
            toRemove         = [int]$Counts.toRemove
            removed          = [int]$Counts.removed
            gone             = [int]$Counts.gone
            skipped          = [int]$Counts.skipped
            pace             = (Get-CrThrottle).Pace
            failed           = [int]$Counts.failed
            problems         = @($Problems)
            error            = $ErrorText
            updatedAt        = [DateTimeOffset]::UtcNow.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        })
}

function Start-CrBackgroundFix {
    <#
      Runs Start.ps1 -RunFix for a fix's folder and step in a hidden PowerShell window, so
      it carries on if the window is closed. What it prints goes to <step>-<time>.log in the folder.
      Pace (Gentle, Normal or Fast, as for a scan) caps its requests a minute.
    #>
    param(
        [Parameter(Mandatory)] [string] $Folder,
        [Parameter(Mandatory)] [ValidateSet('Preview', 'Remove')] [string] $Step,
        [Parameter(Mandatory)] [string] $StartScript,
        [Parameter(Mandatory)] [string] $SettingsPath,
        [ValidateSet('Gentle', 'Normal', 'Fast')] [string] $Pace = 'Normal'
    )
    if (Test-CrScanRunning $Folder) { throw 'This is already running.' }
    Remove-Item -LiteralPath (Join-Path $Folder 'stop.request') -ErrorAction SilentlyContinue
    # Each run its own log, so running a step again never writes over the record of an earlier one.
    $log = Join-Path $Folder "$($Step.ToLowerInvariant())-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    $arguments = '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$StartScript`"", '-RunFix', "`"$Folder`"", '-FixStep', $Step, '-FixPace', $Pace, '-SettingsPath', "`"$SettingsPath`""
    # 'Starting' is written before the step is launched, as this window's, and the step then writes its
    # own; nothing here writes after it starts, so its own report (even an error straight away) always stands.
    Write-CrFixProgress -Folder $Folder -Step $Step -State Starting
    Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $arguments -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput "$log.log" -RedirectStandardError "$log-errors.log"
}

function Update-CrFixPace {
    <#
      Takes up a new pace asked for from the window while a fix runs: a pace.request file in
      its folder holding Gentle, Normal or Fast, as for a scan. Called every couple of seconds.
    #>
    param([Parameter(Mandatory)] [string] $Folder)
    $file = Join-Path $Folder 'pace.request'
    if (-not [System.IO.File]::Exists($file)) { return }
    try {
        $asked = "$(Get-Content -LiteralPath $file -Raw)".Trim()
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
        $pace = Get-CrPace $asked
        if ($pace.Id -ne (Get-CrThrottle).Pace) {
            Set-CrThrottlePace -Throttle (Get-CrThrottle) -Pace $pace -Paced -Sites 1
            Write-Host "$(Get-Date -Format s) Pace changed to $($pace.Name)"
        }
    }
    catch { }   # half written: picked up next time
}

function Test-CrRemoveStarted {
    <# Whether a Remove of this fix has dealt with any link: its journal has a line, or its record exists. #>
    param([Parameter(Mandatory)] [string] $Folder)
    if (Test-Path -LiteralPath (Join-Path $Folder 'removed.json')) { return $true }
    $journal = Join-Path $Folder 'remove-journal.jsonl'
    [System.IO.File]::Exists($journal) -and ([System.IO.FileInfo]::new($journal)).Length -gt 0
}

function Read-CrRemoveJournal {
    <# What an interrupted Remove did, link by link, from its journal (each with its result). #>
    param([Parameter(Mandatory)] [string] $Folder)
    $journal = Join-Path $Folder 'remove-journal.jsonl'
    if (-not [System.IO.File]::Exists($journal)) { return @() }
    $stream = [System.IO.File]::Open($journal, 'Open', 'Read', [System.IO.FileShare]'ReadWrite, Delete')
    try { $lines = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8).ReadToEnd() -split "`r?`n" }
    finally { $stream.Dispose() }
    # A line cut off halfway by the stop is skipped.
    @(foreach ($line in $lines) { if ($line.Trim()) { try { $line | ConvertFrom-Json -DateKind String } catch { } } })
}

function Get-CrLatestFix {
    <#
      The newest fix of this tenant, or nothing: its Folder, Step (Preview or Remove), Progress,
      Running (a process is on it now), Previewed (its preview finished and none of its links
      have been removed, so Remove can still be pressed), PreviewedAt (when that preview
      finished), RemoveProblem (why a Remove that changed nothing didn't finish, if one
      was tried: say the sign-in failed) and Interrupted (a Remove was cut off without ending,
      as when the PC restarts, after dealing with some links; its journal says which). A
      Remove that dealt with any link leaves its journal, so a preview without one has had
      nothing removed.
    #>
    param([Parameter(Mandatory)] [string] $ResultsRoot, [Parameter(Mandatory)] [string] $Tenant)
    $root = Get-CrFixRoot $ResultsRoot
    if (-not (Test-Path -LiteralPath $root)) { return }
    foreach ($dir in Get-ChildItem -LiteralPath $root -Directory | Sort-Object Name -Descending) {
        try {
            if ((Read-CrJson (Join-Path $dir.FullName 'fix.json')).tenant -ne $Tenant) { continue }
            $progress = Read-CrProgress $dir.FullName
            $running = Test-CrScanRunning $dir.FullName
            $previewFile = Join-Path $dir.FullName 'preview.json'
            $started = Test-CrRemoveStarted $dir.FullName
            $previewed = -not $running -and (Test-Path -LiteralPath $previewFile) -and -not $started -and $progress -and $progress.state -ne 'Starting'
            # Cut off: it dealt with links but never wrote its ending, and nothing is working on it now.
            $interrupted = -not $running -and $started -and -not (Test-Path -LiteralPath (Join-Path $dir.FullName 'removed.json'))
            $at = if ($previewed) { [DateTimeOffset]::Parse((Read-CrJson $previewFile).finishedAt, [Globalization.CultureInfo]::InvariantCulture) }
            $removeProblem = if ($previewed -and $progress.step -eq 'Remove') {
                if ($progress.error) { "$($progress.error)" } else { 'it stopped before removing anything' }
            }
            return [pscustomobject]@{
                Folder        = $dir.FullName
                Step          = if ($previewed) { 'Preview' } elseif ($progress -and $progress.step -eq 'Remove') { 'Remove' } else { 'Preview' }
                Progress      = $progress
                Running       = $running
                Previewed     = [bool]$previewed
                PreviewedAt   = $at
                RemoveProblem = $removeProblem
                Interrupted   = [bool]$interrupted
            }
        }
        catch { continue }   # a folder that isn't a fix, or is half written
    }
}

# ── Finding links ───────────────────────────────────────────────────────────

function Get-CrSharingInfo {
    <#
      SharePoint's sharing details of one file, folder or list item, with its links and up to
      MaxLinkMembers of the people on each (each link also says how many there are in all).
      SharePoint asks for this as a POST, but it only reads, so it is sent again after a network error.
    #>
    param([Parameter(Mandatory)] [string] $SiteUrl, [Parameter(Mandatory)] [string] $ListId, [Parameter(Mandatory)] [int] $ItemId)
    Invoke-CrPost "$SiteUrl/_api/web/lists(guid'$ListId')/GetItemById($ItemId)/GetSharingInformation?`$expand=permissionsInformation" `
        @{ request = @{ maxPrincipalsToReturn = 10; maxLinkMembersToReturn = $script:MaxLinkMembers } } -SafeToRetry
}

function Get-CrItemLinks {
    <#
      The sharing links made on an item itself (not ones it gets from a folder above it, which
      are listed, and removed, at that folder). Skips the empty places SharePoint lists for
      link kinds that haven't been made.
    #>
    param([Parameter(Mandatory)] $Info)
    @($Info.permissionsInformation.links | Where-Object {
            $_ -and $_.linkDetails -and -not $_.isInherited -and "$($_.linkDetails.ShareId)" -and "$($_.linkDetails.ShareId)" -ne $script:NoShareId
        })
}

function New-CrLinkRecord {
    <#
      One link as a preview keeps it, before deciding what happens to it: where it is (Url, a
      full address), what kind it is, when it was made and who it is for, and what SharePoint
      needs to remove it (list, item, share ID and kind).
    #>
    param(
        [Parameter(Mandatory)] $Site,
        [Parameter(Mandatory)] [string] $ListId,
        [Parameter(Mandatory)] [int] $ItemId,
        [Parameter(Mandatory)] [string] $Url,
        [bool] $IsFolder,
        [Parameter(Mandatory)] $Link
    )
    $d = $Link.linkDetails
    $created = ConvertTo-CrLinkDate "$($d.Created)"
    $people = @(@($Link.linkMembers) + @($d.Invitations | ForEach-Object { $_.invitee }) | Where-Object { $_ } |
            ForEach-Object { if ($_.email) { "$($_.email)" } elseif ($_.name) { "$($_.name)" } } | Where-Object { $_ } | Select-Object -Unique)
    # SharePoint names only so many of the people on a link; it says how many there are in all, so the rest are counted.
    $named = @($Link.linkMembers | Where-Object { $_ }).Count
    $more = [int]$Link.totalLinkMembersCount - $named
    if ($more -gt 0) { $people += "and $more more" }
    $by = if ($d.CreatedBy) { if ($d.CreatedBy.email) { "$($d.CreatedBy.email)" } else { "$($d.CreatedBy.name)" } } else { '' }
    [pscustomobject][ordered]@{
        site       = "$($Site.url)".TrimEnd('/')
        siteTitle  = "$($Site.title)"
        place      = Get-CrSitePlace $Site
        url        = $Url
        isFolder   = $IsFolder
        type       = Get-CrLinkType $d
        access     = if ($d.IsEditLink -or [int]$d.LinkKind -in 3, 5) { 'Edit' } else { 'View' }
        created    = if ($created) { $created.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") } else { '' }
        createdBy  = $by
        sharedWith = $people -join '; '
        expires    = "$($d.Expiration)"
        listId     = $ListId
        itemId     = $ItemId
        shareId    = "$($d.ShareId)"
        linkKind   = [int]$d.LinkKind
    }
}

function Add-CrLinkDecision {
    <# A link record (New-CrLinkRecord) with what happens to it under Options and Cutoff: remove and why. #>
    param([Parameter(Mandatory)] $Record, [Parameter(Mandatory)] $Options, [Nullable[DateTimeOffset]] $Cutoff)
    $decision = Get-CrLinkDecision -Type $Record.type -Created (ConvertTo-CrLinkDate "$($Record.created)") -Options $Options -Cutoff $Cutoff
    $row = [ordered]@{}
    foreach ($p in $Record.PSObject.Properties) { if ($p.Name -notin 'remove', 'why') { $row[$p.Name] = $p.Value } }
    $row.remove = $decision.Remove
    $row.why = $decision.Why
    [pscustomobject]$row
}

function Get-CrItemLinkRecords {
    <# The links made on one file, folder or list item, or none if it's gone. #>
    param([Parameter(Mandatory)] $Site, [Parameter(Mandatory)] [string] $ListId, [Parameter(Mandatory)] [int] $ItemId, [Parameter(Mandatory)] [string] $Url, [bool] $IsFolder)
    try { $info = Get-CrSharingInfo "$($Site.url)".TrimEnd('/') $ListId $ItemId }
    catch {
        if ((Get-CrStatus $_) -eq 404) { return }   # deleted since it was listed
        throw
    }
    foreach ($l in Get-CrItemLinks $info) { New-CrLinkRecord -Site $Site -ListId $ListId -ItemId $ItemId -Url $Url -IsFolder $IsFolder -Link $l }
}

# ── Only what changed: Microsoft's list of changes ─────────────────────────
#
# A preview keeps what it found on each site (the link cache, in the results folder) with a
# bookmark for each library from Microsoft Graph's list of changes. The next preview of that
# site asks only for what changed since the bookmark, sharing changes included, whoever made
# them, and asks SharePoint again about just those files and folders. Lists that aren't
# libraries have no list of changes and are always read in full; so is any library whose
# bookmark Microsoft no longer accepts.

$script:DeltaPrefer = 'deltashowsharingchanges, hierarchicalsharing, deltatraversepermissiongaps, deltashowremovedasdeleted'

function Get-CrLinkCachePath {
    <# Where what a preview found on a site is kept for the next preview: one file per site, under the results folder. #>
    param([Parameter(Mandatory)] [string] $ResultsRoot, [Parameter(Mandatory)] [string] $Tenant, [Parameter(Mandatory)] [string] $SiteUrl)
    $hash = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($SiteUrl.TrimEnd('/').ToLowerInvariant())))
    Join-Path $ResultsRoot (Join-Path 'link-cache' (Join-Path (Get-CrTenantFileName $Tenant) "$($hash.Substring(0, 24).ToLowerInvariant()).json"))
}

function Get-CrLinkCacheTime {
    <#
      When a preview last finished on a site, from its link cache, or nothing if it has none.
      A site with one is brought up to date from Microsoft's list of changes next time. Read
      from the file's time, not its contents, so the window can ask for hundreds of sites.
    #>
    param([Parameter(Mandatory)] [string] $ResultsRoot, [Parameter(Mandatory)] [string] $Tenant, [Parameter(Mandatory)] [string] $SiteUrl)
    $file = Get-CrLinkCachePath -ResultsRoot $ResultsRoot -Tenant $Tenant -SiteUrl $SiteUrl
    if ([System.IO.File]::Exists($file)) { [System.IO.File]::GetLastWriteTime($file) }
}

function Get-CrGraphSiteId {
    <# A site's ID in Microsoft Graph, from its address. #>
    param([Parameter(Mandatory)] [string] $SiteUrl)
    $u = [uri]$SiteUrl
    $path = $u.AbsolutePath.TrimEnd('/')
    $ref = if ($path) { "$($u.Host):$path" } else { $u.Host }
    "$((Invoke-CrGraph "sites/$ref`?`$select=id").id)"
}

function Get-CrLibraryBookmark {
    <# A bookmark in a library's list of changes, as it is now: DriveId and DeltaLink. Asked from later, it gives only what changed since. #>
    param([string] $GraphSiteId, [Parameter(Mandatory)] [string] $ListId, [string] $DriveId)
    if (-not $DriveId) { $DriveId = "$((Invoke-CrGraph "sites/$GraphSiteId/lists/$ListId/drive?`$select=id").id)" }
    $latest = Invoke-CrGet "https://graph.microsoft.com/v1.0/drives/$DriveId/root/delta?token=latest&`$select=id,deleted,sharepointIds" -ExtraHeaders @{ Prefer = $script:DeltaPrefer }
    if (-not $latest.'@odata.deltaLink') { throw "Microsoft gave no bookmark for the library $ListId." }
    [pscustomobject]@{ driveId = $DriveId; deltaLink = "$($latest.'@odata.deltaLink')" }
}

function Get-CrLibraryChanges {
    <# The files and folders changed since a bookmark, sharing changes included, and the bookmark for next time. #>
    param([Parameter(Mandatory)] [string] $DeltaLink)
    $items = [System.Collections.Generic.List[object]]::new()
    $next = $DeltaLink
    while ($true) {
        $page = Invoke-CrGet $next -ExtraHeaders @{ Prefer = $script:DeltaPrefer }
        foreach ($it in @($page.value)) { if ($it) { $items.Add($it) } }
        if ($page.'@odata.nextLink') { $next = "$($page.'@odata.nextLink')"; continue }
        if (-not $page.'@odata.deltaLink') { throw 'Microsoft gave no bookmark for next time.' }
        return [pscustomobject]@{ Items = $items.ToArray(); DeltaLink = "$($page.'@odata.deltaLink')" }
    }
}

function Get-CrSiteLinkInventory {
    <#
      Every sharing link on one site or OneDrive, as link records, before deciding what happens
      to them. Only items with their own permissions can carry a link, so only those are asked
      about: one request per few thousand items, then one per such item.

      With Saved (what this returned for the site last time, from the link cache), a library
      with a bookmark is brought up to date from its list of changes instead: only files and
      folders changed since are asked about, and the rest of its links are taken from Saved.
      A library whose changes can't be read is read in full. OnItem runs before each item is
      asked about, so progress can be shown.

      Returns Links, Libraries (each library's bookmark for next time), Changed (how many files
      and folders were asked about again from the list of changes), Mode: Full, Changes (every
      library from its list of changes) or Mixed, and Resync: how many libraries Microsoft asked
      to be read in full again, which it does once a folder's sharing has changed.
    #>
    param([Parameter(Mandatory)] $Site, $Saved, [scriptblock] $OnItem)
    $url = "$($Site.url)".TrimEnd('/')
    $origin = ([uri]$url).GetLeftPart([UriPartial]::Authority)
    $links = [System.Collections.Generic.List[object]]::new()
    $bookmarks = [ordered]@{}
    $tally = @{ Changed = 0; ByChanges = 0; InFull = 0; GraphSite = $null; Resync = 0 }
    $lists = Get-CrAll "$url/_api/web/lists?`$select=Id,Title,Hidden,ItemCount,BaseType&`$filter=Hidden eq false"
    # The saved links by library, sorted once, rather than going through them all for each library.
    $savedByList = @{}
    foreach ($old in @($Saved.links)) {
        if (-not $old) { continue }
        $k = "$($old.listId)"
        if (-not $savedByList.ContainsKey($k)) { $savedByList[$k] = [System.Collections.Generic.List[object]]::new() }
        $savedByList[$k].Add($old)
    }
    foreach ($list in $lists) {
        if ([int]$list.BaseType -notin 0, 1) { continue }
        $listId = "$($list.Id)"
        $isLibrary = [int]$list.BaseType -eq 1
        $prior = if ($Saved -and $Saved.libraries -and $Saved.libraries.PSObject.Properties[$listId]) { $Saved.libraries.$listId }

        if ($isLibrary -and $prior -and $prior.deltaLink) {
            try {
                $changes = Get-CrLibraryChanges "$($prior.deltaLink)"
                # By item number; the library's own top folder has none and carries no links.
                $touched = [ordered]@{}
                foreach ($it in $changes.Items) { $n = "$($it.sharepointIds.listItemId)"; if ($n) { $touched[$n] = $it } }
                $kept = @(foreach ($old in @($savedByList[$listId])) { if ($old -and -not $touched.Contains("$($old.itemId)")) { $old } })
                # Microsoft's list doesn't always say which item a deleted file was, so the files whose links
                # are carried over are checked to still be there: a few dozen to a request.
                $alive = [System.Collections.Generic.HashSet[string]]::new()
                $ids = @($kept | ForEach-Object { [int]$_.itemId } | Sort-Object -Unique)
                for ($i = 0; $i -lt $ids.Count; $i += 40) {
                    $chunk = $ids[$i..([Math]::Min($i + 39, $ids.Count - 1))]
                    $filter = [uri]::EscapeDataString((@($chunk | ForEach-Object { "Id eq $_" }) -join ' or '))
                    # Get-CrAll hands back the whole list as one value, so it's held first and then gone through.
                    $there = Get-CrAll "$url/_api/web/lists(guid'$listId')/items?`$select=Id&`$filter=$filter&`$top=100"
                    foreach ($it in $there) { [void]$alive.Add("$($it.Id)") }
                }
                $fresh = [System.Collections.Generic.List[object]]::new()
                foreach ($old in $kept) { if ($alive.Contains("$($old.itemId)")) { $fresh.Add($old) } }
                foreach ($n in $touched.Keys) {
                    if ($OnItem) { & $OnItem }
                    # Where it is now (it may have moved), and whether it still has its own permissions.
                    try { $item = Invoke-CrGet "$url/_api/web/lists(guid'$listId')/items($n)?`$select=Id,FileRef,FSObjType,HasUniqueRoleAssignments" }
                    catch {
                        if ((Get-CrStatus $_) -eq 404) { continue }   # deleted
                        throw
                    }
                    if (-not $item.HasUniqueRoleAssignments) { continue }
                    foreach ($r in Get-CrItemLinkRecords -Site $Site -ListId $listId -ItemId ([int]$n) -Url "$origin$($item.FileRef)" -IsFolder ([int]$item.FSObjType -eq 1)) { $fresh.Add($r) }
                }
                $links.AddRange([object[]]$fresh.ToArray())
                $bookmarks[$listId] = [pscustomobject]@{ driveId = "$($prior.driveId)"; deltaLink = $changes.DeltaLink }
                $tally.Changed += $touched.Count
                $tally.ByChanges++
                continue
            }
            catch {
                if ($_.Exception -is [System.OperationCanceledException]) { throw }
                # Microsoft asks for everything to be read again once a folder's sharing has changed
                # (a folder's sharing reaches everything in it); anything else is a real problem.
                if ((Get-CrStatus $_) -eq 410) { $tally.Resync++ }
                Write-Host "$(Get-Date -Format s) Couldn't read the changes to '$($list.Title)' on $url, so reading all of it: $($_.Exception.Message)"
            }
        }

        # Read in full. A library's bookmark is taken first, so anything changed while it's read is caught next time.
        if ($isLibrary) {
            $tally.InFull++
            try {
                $driveId = if ($prior) { "$($prior.driveId)" } else { '' }
                if (-not $driveId -and -not $tally.GraphSite) { $tally.GraphSite = Get-CrGraphSiteId $url }
                $bookmarks[$listId] = Get-CrLibraryBookmark -GraphSiteId $tally.GraphSite -ListId $listId -DriveId $driveId
            }
            catch {
                if ($_.Exception -is [System.OperationCanceledException]) { throw }
                Write-Host "$(Get-Date -Format s) No list of changes for '$($list.Title)' on $url, so it will be read in full next time too: $($_.Exception.Message)"
            }
        }
        if ([int]$list.ItemCount -le 0) { continue }
        $next = "$url/_api/web/lists(guid'$listId')/items?`$select=Id,FileRef,FSObjType,HasUniqueRoleAssignments&`$top=$script:ItemPageSize"
        while ($next) {
            $page = Get-CrPage $next
            foreach ($item in $page.Items) {
                if (-not $item.HasUniqueRoleAssignments) { continue }
                if ($OnItem) { & $OnItem }
                foreach ($r in Get-CrItemLinkRecords -Site $Site -ListId $listId -ItemId ([int]$item.Id) -Url "$origin$($item.FileRef)" -IsFolder ([int]$item.FSObjType -eq 1)) { $links.Add($r) }
            }
            $next = $page.Next
        }
    }
    $mode = if (-not $tally.ByChanges) { 'Full' } elseif (-not $tally.InFull) { 'Changes' } else { 'Mixed' }
    [pscustomobject]@{ Links = $links.ToArray(); Libraries = $bookmarks; Changed = $tally.Changed; Mode = $mode; Resync = $tally.Resync }
}

# ── The two steps ───────────────────────────────────────────────────────────

function Export-CrFixCsv {
    <# A fix's links as a spreadsheet, in plain words. With -Results, each row's Result too. #>
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Rows, [Parameter(Mandatory)] [string] $Path, [switch] $Results)
    $out = foreach ($r in $Rows) {
        $created = ConvertTo-CrLinkDate $r.created
        $row = [ordered]@{
            'Site'           = if ($r.siteTitle) { $r.siteTitle } else { $r.site }
            'Where'          = $r.place
            'File or folder' = $r.url
            'Link'           = Get-CrLinkTypeWord $r.type
            'Access'         = $r.access
            'Made on'        = if ($created) { $created.ToLocalTime().ToString('yyyy-MM-dd') } else { 'Unknown' }
            'Made by'        = $r.createdBy
            'Shared with'    = $r.sharedWith
            'Expires'        = $r.expires
            'What happens'   = if ($r.remove) { 'Remove' } else { "Keep: $($r.why)" }
        }
        if ($Results) { $row['Result'] = $r.result }
        [pscustomobject]$row
    }
    @($out) | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding utf8BOM
}

function Invoke-CrFix {
    <#
      Runs one step of a fix, signed in already: Preview or Remove. Keeps progress.json up
      to date and stops cleanly when a stop.request file appears in the folder.
    #>
    param([Parameter(Mandatory)] [string] $Folder, [Parameter(Mandatory)] [ValidateSet('Preview', 'Remove')] [string] $Step)
    Set-CrStopFile (Join-Path $Folder 'stop.request')
    $fix = Read-CrJson (Join-Path $Folder 'fix.json')
    if ($Step -eq 'Preview') { Invoke-CrLinkPreview -Folder $Folder -Fix $fix }
    else { Invoke-CrLinkRemove -Folder $Folder }
}

function Invoke-CrLinkPreview {
    <#
      The Preview step: lists every link on the fix's sites and what would happen to it.
      Changes nothing. A site previewed before is brought up to date from Microsoft's list of
      changes (see Get-CrSiteLinkInventory), unless the fix's options ask for fullCheck; what
      was found is kept in the link cache, under the results folder, for next time.
    #>
    param([Parameter(Mandatory)] [string] $Folder, [Parameter(Mandatory)] $Fix)
    $now = [DateTimeOffset]::UtcNow
    $cutoff = Get-CrFixCutoff $Fix.options $now
    $sites = @($Fix.sites)
    $rows = [System.Collections.Generic.List[object]]::new()
    $problems = [System.Collections.Generic.List[object]]::new()
    $counts = @{ found = 0; toRemove = 0 }
    # The results folder: a fix's folder is <results>\fixes\<fix>.
    $resultsRoot = Split-Path (Split-Path $Folder)
    $fullCheck = [bool]$Fix.options.fullCheck
    # How each site was checked: in full, or only what changed (since when, and how many files and folders).
    # resync: sites read in full because Microsoft asked, after a folder's sharing changed there.
    $checked = @{ full = 0; changes = 0; changedItems = 0; since = $null; resync = 0 }
    $at = @{ Done = 0; Current = ''; Written = [DateTime]::MinValue }
    $report = {
        param([string] $State = 'Running', [string] $ErrorText)
        Update-CrFixPace $Folder
        Write-CrFixProgress -Folder $Folder -Step Preview -State $State -Total $sites.Count -Done $at.Done -Current $at.Current -Counts $counts -Problems $problems.ToArray() -ErrorText $ErrorText
        $at.Written = [DateTime]::UtcNow
    }
    # Every couple of seconds while a big site is gone through, not for every file.
    $onItem = { if (([DateTime]::UtcNow - $at.Written).TotalSeconds -ge 2) { & $report } }

    try {
        foreach ($site in $sites) {
            $at.Current = if ($site.title) { "$($site.title)" } else { "$($site.url)" }
            & $report
            Write-Host "$(Get-Date -Format s) Checking $($site.url)"
            try {
                $cacheFile = Get-CrLinkCachePath -ResultsRoot $resultsRoot -Tenant "$($Fix.tenant)" -SiteUrl "$($site.url)"
                $saved = $null
                if (-not $fullCheck -and (Test-Path -LiteralPath $cacheFile)) {
                    try { $saved = Read-CrJson $cacheFile } catch { $saved = $null }   # unreadable: read the site in full
                }
                $found = Get-CrSiteLinkInventory -Site $site -Saved $saved -OnItem $onItem
                # Kept only once the whole site is done, so a stopped preview never leaves half a site behind.
                New-Item -ItemType Directory -Path (Split-Path $cacheFile) -Force | Out-Null
                Write-CrJson $cacheFile ([pscustomobject][ordered]@{
                        site      = "$($site.url)"
                        savedAt   = [DateTimeOffset]::UtcNow.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
                        libraries = [pscustomobject]$found.Libraries
                        links     = @($found.Links)
                    })
                if ($found.Resync) { $checked.resync++ }
                if ($found.Mode -eq 'Full') { $checked.full++ }
                else {
                    $checked.changes++
                    $checked.changedItems += $found.Changed
                    if ($saved.savedAt -and (-not $checked.since -or "$($saved.savedAt)" -lt $checked.since)) { $checked.since = "$($saved.savedAt)" }
                }
                Write-Host "$(Get-Date -Format s) $(if ($found.Mode -eq 'Full') { 'Read in full' } else { "Checked $($found.Changed) changed file(s) and folder(s)" }): $($site.url)"
                foreach ($record in $found.Links) {
                    $row = Add-CrLinkDecision -Record $record -Options $Fix.options -Cutoff $cutoff
                    $rows.Add($row)
                    $counts.found++
                    if ($row.remove) { $counts.toRemove++ }
                }
            }
            catch [System.OperationCanceledException] { throw }
            catch {
                Write-Host "$(Get-Date -Format s) Couldn't check $($site.url): $($_.Exception.Message)"
                $problems.Add([pscustomobject]@{ site = "$($site.url)"; title = "$($site.title)"; error = $_.Exception.Message })
            }
            $at.Done++
        }
    }
    catch [System.OperationCanceledException] {
        $at.Current = ''
        & $report 'Cancelled'
        return
    }

    # Links to remove first, then what stays; each group by site and file.
    $ordered = @($rows | Sort-Object @{ Expression = { -not $_.remove } }, site, url)
    Write-CrJson (Join-Path $Folder 'preview.json') ([pscustomobject][ordered]@{
            finishedAt = [DateTimeOffset]::UtcNow.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
            cutoff     = if ($cutoff) { $cutoff.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") } else { $null }
            sites      = $sites.Count
            checked    = [pscustomobject]$checked
            problems   = $problems.ToArray()
            links      = $ordered
        })
    Export-CrFixCsv -Rows $ordered -Path (Join-Path $Folder 'preview.csv')
    $at.Current = ''
    & $report 'Completed'
    Write-Host "$(Get-Date -Format s) Preview done: $($counts.found) links found, $($counts.toRemove) to remove."
}

function Invoke-CrLinkRemove {
    <#
      The Remove step: removes exactly the links the preview said to remove, except any
      unticked in the window, which skip.json lists (by Get-CrLinkKey) and which are left as
      they are. Each file is asked about again first, and a link no longer there is counted
      as already gone. Each result is written to remove-journal.jsonl as it happens, and the
      whole record to removed.json and removed.csv at the end, however it ends.
    #>
    param([Parameter(Mandatory)] [string] $Folder)
    $previewFile = Join-Path $Folder 'preview.json'
    if (-not (Test-Path -LiteralPath $previewFile)) { throw 'There is no finished preview to remove links from.' }
    if (Test-Path -LiteralPath (Join-Path $Folder 'removed.json')) { throw 'The links in this preview have already been removed.' }
    if (Test-CrRemoveStarted $Folder) { throw 'A Remove of this preview already started and was cut off. Preview again to remove the rest.' }
    $preview = Read-CrJson $previewFile
    $skipFile = Join-Path $Folder 'skip.json'
    $skip = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    if (Test-Path -LiteralPath $skipFile) { foreach ($k in @(Read-CrJson $skipFile)) { if ($k) { [void]$skip.Add("$k") } } }
    $done = [System.Collections.Generic.List[object]]::new()
    $todo = [System.Collections.Generic.List[object]]::new()
    $skipped = 0
    foreach ($link in @($preview.links | Where-Object remove)) {
        if ($skip.Contains((Get-CrLinkKey $link))) {
            $copy = $link | Select-Object *
            $copy | Add-Member -NotePropertyName result -NotePropertyValue 'Not removed: unticked'
            $done.Add($copy)
            $skipped++
        }
        else { $todo.Add($link) }
    }
    $counts = @{ toRemove = $todo.Count; removed = 0; gone = 0; failed = 0; skipped = $skipped }
    # The record of what was removed, written however the step ends: removing can't be undone, so
    # this matters most. Links it never got to are listed too, as not removed. Each part is written
    # on its own, so one that fails (a file held open by a sync tool, say) doesn't stop the others;
    # every link's result is also in this run's own log as it happens.
    $finish = {
        param([string] $State, [string] $ErrorText)
        $tried = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($d in $done) { [void]$tried.Add((Get-CrLinkKey $d)) }
        $attempted = $done.Count - $skipped
        # Stopped, or failed, before dealing with a single link: nothing was changed, so no record is
        # written and the preview stays as it was, for Remove to be pressed again.
        if ($attempted -eq 0 -and $State -ne 'Completed') {
            try { Write-CrFixProgress -Folder $Folder -Step Remove -State $State -Total $todo.Count -Done 0 -Counts $counts -ErrorText $ErrorText }
            catch { Write-Host "$(Get-Date -Format s) Couldn't save progress.json: $($_.Exception.Message)" }
            return
        }
        foreach ($link in $todo) {
            if ($tried.Contains((Get-CrLinkKey $link))) { continue }
            $copy = $link | Select-Object *
            $copy | Add-Member -NotePropertyName result -NotePropertyValue 'Not removed: it stopped before getting to this one'
            $done.Add($copy)
        }
        $all = $done.ToArray()
        try {
            Write-CrJson (Join-Path $Folder 'removed.json') ([pscustomobject][ordered]@{
                    finishedAt = [DateTimeOffset]::UtcNow.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
                    state      = $State
                    error      = $ErrorText
                    links      = $all
                })
        }
        catch { Write-Host "$(Get-Date -Format s) Couldn't save removed.json: $($_.Exception.Message)" }
        try { Export-CrFixCsv -Rows $all -Path (Join-Path $Folder 'removed.csv') -Results }
        catch { Write-Host "$(Get-Date -Format s) Couldn't save removed.csv: $($_.Exception.Message)" }
        try { Write-CrFixProgress -Folder $Folder -Step Remove -State $State -Total $todo.Count -Done $attempted -Counts $counts -ErrorText $ErrorText }
        catch { Write-Host "$(Get-Date -Format s) Couldn't save progress.json: $($_.Exception.Message)" }
    }

    $ended = 'Failed'
    $problem = $null
    # A line per link as it's done, flushed straight to disk, so even a run that is killed outright
    # (the PC restarts, the user signs out) leaves a record of what it removed (see Get-CrLatestFix).
    $journal = [System.IO.StreamWriter]::new((Join-Path $Folder 'remove-journal.jsonl'), $true, [System.Text.UTF8Encoding]::new($false))
    $journal.AutoFlush = $true
    # Progress is saved every couple of seconds, as the preview does, not for every file.
    $lastSaved = [DateTime]::MinValue
    $stopAfter = $false
    try {
        foreach ($group in $todo | Group-Object site, listId, itemId) {
            $first = $group.Group[0]
            if (([DateTime]::UtcNow - $lastSaved).TotalSeconds -ge $script:ProgressEverySeconds) {
                Update-CrFixPace $Folder
                Write-CrFixProgress -Folder $Folder -Step Remove -State Running -Total $todo.Count -Done ($done.Count - $skipped) -Current $first.url -Counts $counts
                $lastSaved = [DateTime]::UtcNow
            }
            $present = $null
            try { $present = @(Get-CrItemLinks (Get-CrSharingInfo $first.site $first.listId $first.itemId) | ForEach-Object { "$($_.linkDetails.ShareId)" }) }
            catch {
                if ($_.Exception -is [System.OperationCanceledException]) { throw }
                if ((Get-CrStatus $_) -eq 404) { $present = @() }   # the file itself is gone
                else { $present = $null; $askError = $_.Exception.Message }
            }
            foreach ($link in $group.Group) {
                $result = if ($null -eq $present) { "Failed: $askError" }
                elseif ($present -notcontains $link.shareId) { 'Already gone' }
                else {
                    try {
                        $null = Invoke-CrPost "$($link.site)/_api/web/lists(guid'$($link.listId)')/GetItemById($($link.itemId))/UnshareLink" @{ linkKind = [int]$link.linkKind; shareId = "$($link.shareId)" }
                        'Removed'
                    }
                    catch {
                        if ($_.Exception -is [System.OperationCanceledException]) { throw }
                        $why = $_.Exception.Message
                        # The answer can be lost after SharePoint has done it (a timeout, say): look before calling it failed.
                        # Stop pressed while looking: the result is written down as not known, then it stops.
                        $stillThere = try { @(Get-CrItemLinks (Get-CrSharingInfo $link.site $link.listId $link.itemId) | ForEach-Object { "$($_.linkDetails.ShareId)" }) -contains $link.shareId }
                        catch { if ($_.Exception -is [System.OperationCanceledException]) { $stopAfter = $true; $null } else { $true } }
                        if ($stopAfter) { "Not known: SharePoint's answer was lost and it stopped before it could check. Look at this file's sharing" }
                        elseif ($stillThere) { "Failed: $why" } else { 'Removed' }
                    }
                }
                switch -Wildcard ($result) { 'Removed' { $counts.removed++ } 'Already gone' { $counts.gone++ } 'Failed*' { $counts.failed++ } 'Not known*' { $counts.failed++ } }
                Write-Host "$(Get-Date -Format s) $result  $($link.url)"
                $copy = $link | Select-Object *
                $copy | Add-Member -NotePropertyName result -NotePropertyValue $result
                $done.Add($copy)
                $journal.WriteLine((ConvertTo-Json -InputObject $copy -Compress -Depth 5))
                if ($stopAfter) { throw [System.OperationCanceledException]::new('Stopped.') }
            }
        }
        $ended = 'Completed'
    }
    catch [System.OperationCanceledException] { $ended = 'Cancelled' }
    catch { $problem = $_.Exception.Message; throw }
    finally {
        $journal.Dispose()
        & $finish $ended $problem
    }
    Write-Host "$(Get-Date -Format s) Remove $(if ($ended -eq 'Completed') { 'done' } else { 'stopped' }): $($counts.removed) removed, $($counts.gone) already gone, $($counts.failed) failed, $skipped left as unticked."
}
