<#
.SYNOPSIS
  Checks the Remediation tab's link removal against a pretend tenant, with no network:
  which links each choice picks, the preview, removing exactly what the preview listed,
  links already gone, a removal that fails, a site that refuses access, and stopping.
  Exits 1 if anything is off.

.EXAMPLE
  pwsh -File pnp/tests/Test-Remediation.ps1
#>
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\CopilotReadiness\CopilotReadiness.psm1') -Force
$module = Get-Module CopilotReadiness

$work = Join-Path ([IO.Path]::GetTempPath()) "cr-remediation-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
New-Item -ItemType Directory -Path $work | Out-Null

$problems = [System.Collections.Generic.List[string]]::new()
function Check([string] $what, [bool] $ok) { if (-not $ok) { $problems.Add($what) } }

# ── The pretend tenant ──────────────────────────────────────────────────────
$sp = 'https://contoso.sharepoint.com'
$fin = "$sp/sites/finance"
$locked = "$sp/sites/locked"
$od = 'https://contoso-my.sharepoint.com/personal/dana_contoso_com'
$old = '2025-01-10T09:00:00Z'      # well over 180 days before the test's "now"
$new = (Get-Date).ToUniversalTime().AddDays(-5).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")

function Link([string] $id, [int] $kind, [int] $scope, [string] $created, [switch] $Inherited, [string[]] $members = @()) {
    @{ isInherited = [bool]$Inherited; linkMembers = @($members | ForEach-Object { @{ email = $_; name = $_ } })
        linkDetails = @{ ShareId = $id; LinkKind = $kind; Scope = $scope; Created = $created; IsEditLink = $kind -in 3, 5; Expiration = ''; CreatedBy = @{ email = 'dana@contoso.com'; name = 'Dana' }; Invitations = @() }
    }
}
$fake = @{
    Calls   = [System.Collections.Generic.List[object]]::new()
    Gone    = [System.Collections.Generic.HashSet[string]]::new()   # links removed so far
    FailOn  = 'l-fail'                                              # removing this one fails
    # Microsoft's list of changes: item numbers changed in each library since its last bookmark,
    # and libraries whose bookmark Microsoft no longer accepts.
    Changes = @{}
    Expired = [System.Collections.Generic.HashSet[string]]::new()
    Marks   = @{ N = 0 }
    Lists   = @{
        $fin = @(@{ Id = 'L1'; Title = 'Documents'; Hidden = $false; ItemCount = 4; BaseType = 1 }, @{ Id = 'L9'; Title = 'Empty'; Hidden = $false; ItemCount = 0; BaseType = 1 })
        $od  = @(@{ Id = 'D1'; Title = 'Documents'; Hidden = $false; ItemCount = 2; BaseType = 1 })
    }
    Items   = @{
        "$fin|L1" = @(
            @{ Id = 1; FileRef = '/sites/finance/Shared Documents/budget.xlsx'; FSObjType = 0; HasUniqueRoleAssignments = $true },
            @{ Id = 2; FileRef = '/sites/finance/Shared Documents/plain.docx'; FSObjType = 0; HasUniqueRoleAssignments = $false },
            @{ Id = 3; FileRef = '/sites/finance/Shared Documents/Payroll'; FSObjType = 1; HasUniqueRoleAssignments = $true },
            @{ Id = 4; FileRef = '/sites/finance/Shared Documents/Payroll/june.xlsx'; FSObjType = 0; HasUniqueRoleAssignments = $true }
        )
        "$od|D1"  = @(@{ Id = 7; FileRef = '/personal/dana_contoso_com/Documents/cv.docx'; FSObjType = 0; HasUniqueRoleAssignments = $true })
    }
    Links   = @{
        "$fin|L1|1" = @(
            (Link 'l-org-old' 2 1 $old),                 # company-wide, old: goes
            (Link 'l-org-new' 3 1 $new),                 # company-wide, new: stays
            (Link 'l-anyone-old' 6 0 $old),              # Anyone (newer kind), old: goes
            (Link 'l-people-old' 6 2 $old -members 'raj@tailspin.com'),   # Specific people: stays unless chosen
            (Link $null 3 -1 ''),                        # an empty place SharePoint lists: never a link
            (Link '00000000-0000-0000-0000-000000000000' 2 1 '')
        )
        "$fin|L1|3" = @((Link 'l-fail' 4 0 $old), (Link 'l-nodate' 2 1 ''))   # Anyone that fails to go; a link with no date
        "$fin|L1|4" = @((Link 'l-fail' 4 0 $old -Inherited))                  # comes from the folder: listed there, not here
        "$od|D1|7"  = @((Link 'l-od-old' 2 1 $old), (Link 'l-gone' 5 0 $old))
    }
}
& $module {
    param($fake)
    $script:Fake = $fake
    function script:Invoke-CrGet {
        param([string] $Url, [switch] $AdvancedQuery, [string] $Method = 'GET', $Body, [hashtable] $ExtraHeaders = @{}, [switch] $SafeToRetry)
        Assert-CrNotStopped
        $script:Fake.Calls.Add([pscustomobject]@{ Method = $Method; Url = $Url; Body = $Body; Prefer = "$($ExtraHeaders.Prefer)" })
        function Fail([int] $status) { $ex = [System.Net.Http.HttpRequestException]::new("HTTP $status from $Url"); $ex.Data['Status'] = $status; throw $ex }
        if ($Url -like 'https://contoso.sharepoint.com/sites/locked/*') { Fail 403 }
        # Microsoft Graph: a site's ID, a library's drive, and the drive's list of changes.
        if ($Url -match '^https://graph\.microsoft\.com/v1\.0/sites/[^/]+/lists/([^/]+)/drive') { return [pscustomobject]@{ id = "drv-$($Matches[1])" } }
        if ($Url -match '^https://graph\.microsoft\.com/v1\.0/sites/') { return [pscustomobject]@{ id = 'graph-site' } }
        if ($Url -match '^https://graph\.microsoft\.com/v1\.0/drives/([^/]+)/root/delta\?token=([^&]+)') {
            $drive = $Matches[1]; $token = $Matches[2]
            $script:Fake.Marks.N++
            $next = "https://graph.microsoft.com/v1.0/drives/$drive/root/delta?token=b$($script:Fake.Marks.N)"
            if ($token -eq 'latest') { return [pscustomobject]@{ value = @(); '@odata.deltaLink' = $next } }
            if ($script:Fake.Expired.Contains($drive)) { Fail 410 }
            $changed = @($script:Fake.Changes[$drive] | Sort-Object -Unique)
            $script:Fake.Changes[$drive] = @()
            # The library's own top folder comes back too, with no item number.
            $items = @([pscustomobject]@{ id = 'root'; sharepointIds = [pscustomobject]@{ listItemId = $null } }) + @($changed | ForEach-Object { [pscustomobject]@{ id = "i$_"; sharepointIds = [pscustomobject]@{ listItemId = "$_" } } })
            return [pscustomobject]@{ value = $items; '@odata.deltaLink' = $next }
        }
        if ($Url -match "^(.+?)/_api/web/lists\(guid'([^']+)'\)/items\((\d+)\)\?") {
            $one = @($script:Fake.Items["$($Matches[1])|$($Matches[2])"] | Where-Object { $_.Id -eq [int]$Matches[3] }) | Select-Object -First 1
            if (-not $one) { Fail 404 }
            return [pscustomobject]$one
        }
        if ($Url -match '^(.+?)/_api/web/lists\?') { return [pscustomobject]@{ value = @($script:Fake.Lists[$Matches[1]] | ForEach-Object { [pscustomobject]$_ }) } }
        if ($Url -match "^(.+?)/_api/web/lists\(guid'([^']+)'\)/items\?") { return [pscustomobject]@{ value = @($script:Fake.Items["$($Matches[1])|$($Matches[2])"] | ForEach-Object { [pscustomobject]$_ }) } }
        if ($Url -match "^(.+?)/_api/web/lists\(guid'([^']+)'\)/GetItemById\((\d+)\)/GetSharingInformation") {
            $links = @($script:Fake.Links["$($Matches[1])|$($Matches[2])|$($Matches[3])"] | Where-Object { -not $script:Fake.Gone.Contains("$($_.linkDetails.ShareId)") })
            return ([pscustomobject]@{ permissionsInformation = @{ links = $links } } | ConvertTo-Json -Depth 10 | ConvertFrom-Json -DateKind String)
        }
        if ($Url -match "lists\(guid'([^']+)'\)/GetItemById\((\d+)\)/UnshareLink$") {
            if ($Body.shareId -eq $script:Fake.FailOn) { Fail 500 }
            [void]$script:Fake.Gone.Add($Body.shareId)
            # Done, but the answer never arrives (and, if asked, Stop is pressed at that moment).
            if ($Body.shareId -eq $script:Fake.Lost) {
                if ($script:Fake.StopOnLost) { Set-Content -LiteralPath $script:StopFile -Value 'stop' }
                Fail 504
            }
            # Removing a link changes the file, so it turns up in its library's list of changes.
            $script:Fake.Changes["drv-$($Matches[1])"] = @($script:Fake.Changes["drv-$($Matches[1])"]) + [int]$Matches[2]
            return [pscustomobject]@{}
        }
        throw "The pretend tenant has no answer for $Method $Url"
    }
} $fake

$sites = @(
    [pscustomobject]@{ url = $fin; title = 'Finance'; kind = 'SharePoint'; teams = 'Team' },
    [pscustomobject]@{ url = $locked; title = 'Locked'; kind = 'SharePoint'; teams = $null },
    [pscustomobject]@{ url = $od; title = 'Dana'; kind = 'OneDrive' }
)

try {
    # ── Link types and choices ──
    Check 'kind 2 is company-wide' ((Get-CrLinkType @{ LinkKind = 2 }) -eq 'Organization')
    Check 'kind 5 is Anyone' ((Get-CrLinkType @{ LinkKind = 5 }) -eq 'Anyone')
    Check 'kind 6 scope 2 is Specific people' ((Get-CrLinkType @{ LinkKind = 6; Scope = 2 }) -eq 'SpecificPeople')
    Check 'kind 6 scope 3 is some other link' ((Get-CrLinkType @{ LinkKind = 6; Scope = 3 }) -eq 'Other')
    Check 'places: Team, Channel, OneDrive, SharePoint' ((Get-CrSitePlace $sites[0]) -eq 'Team' -and (Get-CrSitePlace ([pscustomobject]@{ kind = 'SharePoint'; teams = 'Channel' })) -eq 'Channel' -and
        (Get-CrSitePlace $sites[2]) -eq 'OneDrive' -and (Get-CrSitePlace $sites[1]) -eq 'SharePoint')

    $now = [DateTimeOffset]::new(2026, 11, 5, 12, 0, 0, [TimeSpan]::Zero)
    $wide180 = [pscustomobject]@{ links = @('Anyone', 'Organization'); age = 'OlderThan'; days = 180; before = '' }
    $cut = Get-CrFixCutoff $wide180 $now
    Check '180 days before now' ($cut -eq $now.AddDays(-180))
    $oldDate = [DateTimeOffset]::new(2025, 1, 10, 0, 0, 0, [TimeSpan]::Zero)
    Check 'old company-wide link goes' (Get-CrLinkDecision -Type Organization -Created $oldDate -Options $wide180 -Cutoff $cut).Remove
    Check 'new company-wide link stays' (-not (Get-CrLinkDecision -Type Organization -Created $now.AddDays(-5) -Options $wide180 -Cutoff $cut).Remove)
    Check 'a link with no date stays when an age is chosen' (-not (Get-CrLinkDecision -Type Anyone -Created $null -Options $wide180 -Cutoff $cut).Remove)
    Check 'Specific people stays when not ticked' (-not (Get-CrLinkDecision -Type SpecificPeople -Created $oldDate -Options $wide180 -Cutoff $cut).Remove)
    $peopleAny = [pscustomobject]@{ links = @('Anyone', 'Organization', 'SpecificPeople'); age = 'Any'; days = 180; before = '' }
    Check 'Specific people goes when chosen, any age' (Get-CrLinkDecision -Type SpecificPeople -Created $null -Options $peopleAny -Cutoff $null).Remove
    Check 'Other links only go when ticked' (-not (Get-CrLinkDecision -Type Other -Created $null -Options $peopleAny -Cutoff $null).Remove -and
        (Get-CrLinkDecision -Type Other -Created $null -Options ([pscustomobject]@{ links = @('Anyone', 'Organization', 'SpecificPeople', 'Other'); age = 'Any' }) -Cutoff $null).Remove)
    $anyoneOnly = [pscustomobject]@{ links = @('Anyone'); age = 'Any' }
    Check 'only Anyone ticked: company-wide links stay' ((Get-CrLinkDecision -Type Anyone -Created $null -Options $anyoneOnly -Cutoff $null).Remove -and -not (Get-CrLinkDecision -Type Organization -Created $null -Options $anyoneOnly -Cutoff $null).Remove)
    Check 'Specific people alone can be picked' ((Get-CrLinkDecision -Type SpecificPeople -Created $null -Options ([pscustomobject]@{ links = @('SpecificPeople'); age = 'Any' }) -Cutoff $null).Remove -and -not (Get-CrLinkDecision -Type Anyone -Created $null -Options ([pscustomobject]@{ links = @('SpecificPeople'); age = 'Any' }) -Cutoff $null).Remove)
    $beforeOpt = [pscustomobject]@{ links = @('Anyone', 'Organization'); age = 'Before'; days = 0; before = '2025-06-01' }
    $bcut = Get-CrFixCutoff $beforeOpt $now
    Check 'made before a date: from the start of that day here' ($bcut.LocalDateTime -eq [DateTime]::new(2025, 6, 1))

    # ── Preview: lists every link, changes nothing ──
    $folder = New-CrFix -ResultsRoot $work -Tenant 'contoso.onmicrosoft.com' -Sites $sites -Options $wide180
    Check 'fixes live in their own folder' ((Split-Path $folder) -eq (Join-Path $work 'fixes'))
    Invoke-CrFix -Folder $folder -Step Preview
    $p = Read-CrProgress $folder
    $preview = Read-CrJson (Join-Path $folder 'preview.json')
    $byId = @{}; foreach ($l in $preview.links) { $byId[$l.shareId] = $l }
    Check "preview finished (state $($p.state))" ($p.state -eq 'Completed' -and $p.done -eq 3)
    Check 'nothing changed by the preview' (-not @($fake.Calls | Where-Object Url -like '*UnshareLink').Count)
    Check "every real link found once ($(@($preview.links).Count): $($byId.Keys -join ', '))" (@($preview.links).Count -eq 8 -and $byId.Count -eq 8)
    Check 'empty and inherited places are not links' (-not $byId.ContainsKey('00000000-0000-0000-0000-000000000000') -and @($preview.links | Where-Object { $_.url -like '*june.xlsx' }).Count -eq 0)
    Check 'the right links would go' ((@($preview.links | Where-Object remove | ForEach-Object shareId | Sort-Object) -join ',') -eq 'l-anyone-old,l-fail,l-gone,l-od-old,l-org-old')
    Check 'removals listed first' ((@($preview.links)[0..4] | Where-Object { -not $_.remove }).Count -eq 0)
    Check 'why each is kept' ($byId['l-org-new'].why -like 'Made on or after*' -and $byId['l-nodate'].why -eq 'Date made unknown' -and $byId['l-people-old'].why -eq 'Not one of the link types chosen')
    Check 'who a Specific people link is for' ($byId['l-people-old'].sharedWith -eq 'raj@tailspin.com')
    Check 'full address and place' ($byId['l-org-old'].url -eq "$sp/sites/finance/Shared Documents/budget.xlsx" -and $byId['l-org-old'].place -eq 'Team' -and $byId['l-od-old'].place -eq 'OneDrive')
    Check 'the locked site is reported, not fatal' (@($preview.problems).Count -eq 1 -and $preview.problems[0].site -eq $locked)

    # ── Progress while one big site is read ──
    Check 'the counts for the site being read are cleared when it finishes' ([int]$p.itemsRead -eq 0 -and [int]$p.itemsTotal -eq 0 -and [int]$p.siteLinks -eq 0)
    $live = @{}
    $seen = [System.Collections.Generic.List[int]]::new()
    $finSite = @($sites | Where-Object url -eq $fin)[0]
    $read = Get-CrSiteLinkInventory -Site $finSite -OnItem { $seen.Add([int]$live.itemsRead) }.GetNewClosure() -Live $live
    Check "files read, out of how many ($($live.itemsRead) of $($live.itemsTotal))" ($live.itemsTotal -eq 4 -and $live.itemsRead -eq 4)
    Check "files with their own sharing ($($live.itemsShared))" ($live.itemsShared -eq 3)
    Check "links counted as they are found ($($live.siteLinks) of $(@($read.Links).Count))" ($live.siteLinks -eq @($read.Links).Count -and $live.siteLinks -gt 0)
    Check "progress is reported as it goes, and after a page ($($seen -join ','))" ($seen.Count -ge 4 -and $seen[0] -lt $seen[-1] -and $seen[-1] -eq 4)

    Check 'progress counts' ($p.found -eq 8 -and $p.toRemove -eq 5)
    $latest = Get-CrLatestFix -ResultsRoot $work -Tenant 'contoso.onmicrosoft.com'
    Check 'a finished preview comes back when the window opens' ($latest.Folder -eq $folder -and $latest.Previewed -and -not $latest.Running -and $latest.Step -eq 'Preview' -and $latest.PreviewedAt)
    Check "another tenant's fixes don't come back" (-not (Get-CrLatestFix -ResultsRoot $work -Tenant 'fabrikam.onmicrosoft.com'))
    $csv = @(Import-Csv (Join-Path $folder 'preview.csv'))
    Check 'spreadsheet in plain words' ($csv.Count -eq 8 -and $csv[0].'What happens' -eq 'Remove' -and ($csv | Where-Object { $_.'Link' -eq 'People in your organization' }))

    # ── Remove: exactly what the preview listed ──
    [void]$fake.Gone.Add('l-gone')          # someone removed this one by hand since the preview
    $fake.Calls.Clear()
    # One link unticked in the window: it is left as it is.
    Write-CrJson (Join-Path $folder 'skip.json') @(Get-CrLinkKey $byId['l-od-old'])
    Invoke-CrFix -Folder $folder -Step Remove
    $p = Read-CrProgress $folder
    $done = Read-CrJson (Join-Path $folder 'removed.json')
    $result = @{}; foreach ($l in $done.links) { $result[$l.shareId] = $l.result }
    $unshared = @($fake.Calls | Where-Object Url -like '*UnshareLink' | ForEach-Object { $_.Body.shareId } | Sort-Object)
    Check "removed only the preview's links ($($unshared -join ','))" (($unshared -join ',') -eq 'l-anyone-old,l-fail,l-org-old')
    Check 'results per link' ($result['l-org-old'] -eq 'Removed' -and $result['l-gone'] -eq 'Already gone' -and $result['l-fail'] -like 'Failed*' -and $result['l-od-old'] -eq 'Not removed: unticked' -and $result.Count -eq 5)
    Check 'kept and unticked links untouched' (-not $fake.Gone.Contains('l-org-new') -and -not $fake.Gone.Contains('l-people-old') -and -not $fake.Gone.Contains('l-nodate') -and -not $fake.Gone.Contains('l-od-old'))
    Check "remove counts (state $($p.state))" ($p.state -eq 'Completed' -and $p.removed -eq 2 -and $p.gone -eq 1 -and $p.failed -eq 1 -and $p.skipped -eq 1 -and $p.total -eq 4 -and $p.done -eq 4)
    Check 'removed spreadsheet has results' (@(Import-Csv (Join-Path $folder 'removed.csv') | Where-Object Result -EQ 'Removed').Count -eq 2)
    $latest = Get-CrLatestFix -ResultsRoot $work -Tenant 'contoso.onmicrosoft.com'
    Check 'once removed, the preview no longer comes back to be removed again' ($latest.Folder -eq $folder -and -not $latest.Previewed -and $latest.Step -eq 'Remove')
    $again = try { Invoke-CrFix -Folder $folder -Step Remove; $false } catch { $_.Exception.Message -like '*already been removed*' }
    Check 'the same preview cannot be removed twice' $again

    # ── The next preview: only what changed since the last one ──
    # Since the first preview: the Remove above changed budget.xlsx (item 1), someone shared plain.docx
    # (item 2), and someone removed a link from Dana's cv.docx (item 7). Payroll (item 3) is untouched.
    $fake.Items["$fin|L1"][1].HasUniqueRoleAssignments = $true
    $fake.Links["$fin|L1|2"] = @((Link 'l-new-old' 2 1 $old))
    $fake.Changes['drv-L1'] = @($fake.Changes['drv-L1']) + 2
    $fake.Changes['drv-D1'] = @(7)
    $fake.Calls.Clear()
    $quick = New-CrFix -ResultsRoot $work -Tenant 'contoso.onmicrosoft.com' -Sites $sites -Options $wide180
    Invoke-CrFix -Folder $quick -Step Preview
    $qp = Read-CrJson (Join-Path $quick 'preview.json')
    $ids = @($qp.links | ForEach-Object shareId | Sort-Object) -join ','
    $asked = @($fake.Calls | Where-Object Url -like '*GetSharingInformation*' | ForEach-Object { if ($_.Url -match '(finance|dana)\S*GetItemById\((\d+)\)') { "$($Matches[1])$($Matches[2])" } } | Sort-Object) -join ','
    Check "the next preview finds the same links as reading everything would ($ids)" ($ids -eq 'l-fail,l-new-old,l-nodate,l-od-old,l-org-new,l-people-old')
    Check "only changed files are asked about again ($asked)" ($asked -eq 'dana7,finance1,finance2')
    # (Checking that files with saved links still exist asks for just those items, by number.)
    Check 'no library is read in full' (-not @($fake.Calls | Where-Object { $_.Url -match "lists\(guid'(L1|D1|L9)'\)/items\?" -and $_.Url -notmatch 'filter=' }).Count)
    Check 'Microsoft is asked for sharing changes too' (@($fake.Calls | Where-Object { $_.Url -like '*root/delta*' -and $_.Prefer -like '*deltashowsharingchanges*' }).Count -ge 3)
    Check "how it checked is reported (changes $($qp.checked.changes), full $($qp.checked.full), items $($qp.checked.changedItems))" ([int]$qp.checked.changes -eq 2 -and [int]$qp.checked.full -eq 0 -and [int]$qp.checked.changedItems -eq 3 -and $qp.checked.since)
    Check 'decisions are made again with the current choices' (@($qp.links | Where-Object { $_.shareId -eq 'l-new-old' -and $_.remove }).Count -eq 1 -and @($qp.links | Where-Object { $_.shareId -eq 'l-people-old' -and -not $_.remove }).Count -eq 1)

    # Asked to, it reads everything again.
    $fake.Calls.Clear()
    $full = New-CrFix -ResultsRoot $work -Tenant 'contoso.onmicrosoft.com' -Sites $sites -Options ([pscustomobject]@{ links = @('Anyone', 'Organization'); age = 'OlderThan'; days = 180; before = ''; fullCheck = $true })
    Invoke-CrFix -Folder $full -Step Preview
    $fp = Read-CrJson (Join-Path $full 'preview.json')
    Check 'Check every file again reads every library in full' ([int]$fp.checked.full -eq 2 -and [int]$fp.checked.changes -eq 0 -and @($fake.Calls | Where-Object { $_.Url -match "lists\(guid'L1'\)/items\?" }).Count -ge 1)
    Check 'and finds the same links' ((@($fp.links | ForEach-Object shareId | Sort-Object) -join ',') -eq $ids)

    # A bookmark Microsoft no longer accepts: that library is read in full, the rest from their changes.
    [void]$fake.Expired.Add('drv-D1')
    $fake.Calls.Clear()
    $mixed = New-CrFix -ResultsRoot $work -Tenant 'contoso.onmicrosoft.com' -Sites $sites -Options $wide180
    Invoke-CrFix -Folder $mixed -Step Preview
    $mp = Read-CrJson (Join-Path $mixed 'preview.json')
    Check "an expired bookmark means reading that library in full, and says why (changes $($mp.checked.changes), full $($mp.checked.full), resync $($mp.checked.resync))" ([int]$mp.checked.changes -eq 1 -and [int]$mp.checked.full -eq 1 -and [int]$mp.checked.resync -eq 1 -and
        @($fake.Calls | Where-Object { $_.Url -match "lists\(guid'D1'\)/items\?" }).Count -ge 1 -and -not @($fake.Calls | Where-Object { $_.Url -match "lists\(guid'L1'\)/items\?" -and $_.Url -notmatch 'filter=' }).Count)
    Check 'still the same links' ((@($mp.links | ForEach-Object shareId | Sort-Object) -join ',') -eq $ids)
    [void]$fake.Expired.Remove('drv-D1')

    # A file deleted since, which Microsoft's list of changes doesn't name: its links don't linger.
    $payroll = $fake.Items["$fin|L1"] | Where-Object { $_.Id -eq 3 }
    $fake.Items["$fin|L1"] = @($fake.Items["$fin|L1"] | Where-Object { $_.Id -ne 3 })
    $ghost = New-CrFix -ResultsRoot $work -Tenant 'contoso.onmicrosoft.com' -Sites $sites -Options $wide180
    Invoke-CrFix -Folder $ghost -Step Preview
    $gp = Read-CrJson (Join-Path $ghost 'preview.json')
    Check "links on a deleted file are dropped ($(@($gp.links | ForEach-Object shareId | Sort-Object) -join ','))" ([int]$gp.checked.changes -eq 2 -and -not @($gp.links | Where-Object { $_.shareId -in 'l-fail', 'l-nodate' }).Count -and @($gp.links | Where-Object shareId -EQ 'l-new-old').Count -eq 1)
    $fake.Items["$fin|L1"] = @($fake.Items["$fin|L1"]) + $payroll

    # ── Stop: a preview stopped part way says so and leaves no preview behind ──
    $stopped = New-CrFix -ResultsRoot $work -Tenant 'contoso.onmicrosoft.com' -Sites $sites -Options $wide180
    New-Item -ItemType File -Path (Join-Path $stopped 'stop.request') | Out-Null
    Invoke-CrFix -Folder $stopped -Step Preview
    Check 'stopped preview says Cancelled' ((Read-CrProgress $stopped).state -eq 'Cancelled' -and -not (Test-Path (Join-Path $stopped 'preview.json')))
    $noPreview = try { Invoke-CrFix -Folder $stopped -Step Remove; $false } catch { $_.Exception.Message -like '*no finished preview*' }
    Check 'no remove without a finished preview' $noPreview

    # ── The pace can be changed while a fix runs ──
    Set-Content -LiteralPath (Join-Path $stopped 'pace.request') -Value 'Gentle'
    Update-CrFixPace $stopped
    Check 'a running fix takes up a new pace' ((Get-CrThrottle).Pace -eq 'Gentle' -and [int](Get-CrThrottle).PerMinute -eq 60 -and -not (Test-Path (Join-Path $stopped 'pace.request')))
    Set-CrThrottle (New-CrThrottle)   # back to unpaced for the rest

    # ── The window can tell which sites were checked before ──
    Check 'sites previewed before are known' ((Get-CrLinkCacheTime -ResultsRoot $work -Tenant 'contoso.onmicrosoft.com' -SiteUrl $od) -and -not (Get-CrLinkCacheTime -ResultsRoot $work -Tenant 'contoso.onmicrosoft.com' -SiteUrl $locked))

    # ── A Remove that fails part way still records what it removed ──
    # Saving progress fails the second time a file is reached (say a sync tool holds the file open).
    $broken = New-CrFix -ResultsRoot $work -Tenant 'contoso.onmicrosoft.com' -Sites @($sites[0], $sites[2]) -Options ([pscustomobject]@{ links = @('Anyone', 'Organization', 'SpecificPeople'); age = 'Any' })
    Invoke-CrFix -Folder $broken -Step Preview
    $toGo = @((Read-CrJson (Join-Path $broken 'preview.json')).links | Where-Object remove).Count
    & $module {
        $script:ProgressEverySeconds = 0   # save progress at every file, so the second save comes after a removal
        $script:RealProgress = ${function:Write-CrFixProgress}
        $script:ProgressCalls = 0
        function script:Write-CrFixProgress {
            param([string] $Folder, [string] $Step, [string] $State, [int] $Total, [int] $Done, [string] $Current, [hashtable] $Counts, [object[]] $Problems, [string] $ErrorText, $Process)
            if ($State -eq 'Running' -and ++$script:ProgressCalls -eq 2) { throw [System.IO.IOException]::new('The file is in use by another process.') }
            & $script:RealProgress @PSBoundParameters
        }
    }
    $threw = try { Invoke-CrFix -Folder $broken -Step Remove; $false } catch { $_.Exception.Message -like '*in use*' }
    & $module { Set-Item function:script:Write-CrFixProgress $script:RealProgress; $script:ProgressEverySeconds = 2 }
    $rec = Read-CrJson (Join-Path $broken 'removed.json')
    $removedFirst = @($rec.links | Where-Object result -EQ 'Removed').Count
    $notReached = @($rec.links | Where-Object { $_.result -like 'Not removed: it stopped*' }).Count
    Check "the problem still stops it, and is reported (threw $threw)" $threw
    Check "the record is kept: what was removed, and what it never got to ($removedFirst removed, $notReached not reached, of $toGo)" ($rec.state -eq 'Failed' -and $rec.error -like '*in use*' -and $removedFirst -ge 1 -and $notReached -ge 1 -and @($rec.links).Count -eq $toGo)
    Check 'the spreadsheet of results is written too' (Test-Path (Join-Path $broken 'removed.csv'))
    $bp = Read-CrProgress $broken
    Check "the window is told it failed, with the counts ($($bp.state), removed $($bp.removed))" ($bp.state -eq 'Failed' -and [int]$bp.removed -eq $removedFirst -and $bp.error -like '*in use*')
    Check 'that preview is not offered for Remove again' (-not (Get-CrLatestFix -ResultsRoot $work -Tenant 'contoso.onmicrosoft.com').Previewed)

    Check 'each link is written down as it is dealt with' (@(Read-CrRemoveJournal $broken).Count -eq $removedFirst)

    # ── A Remove cut off outright (the PC restarts): never offered again as untouched ──
    $fake.Links["$od|D1|7"] = @((Link 'l-cut' 2 1 $old))
    $cut = New-CrFix -ResultsRoot $work -Tenant 'contoso.onmicrosoft.com' -Sites @($sites[2]) -Options ([pscustomobject]@{ links = @('Anyone', 'Organization', 'SpecificPeople'); age = 'Any' })
    Invoke-CrFix -Folder $cut -Step Preview
    $firstLink = @((Read-CrJson (Join-Path $cut 'preview.json')).links | Where-Object remove)[0] | Select-Object *
    $firstLink | Add-Member -NotePropertyName result -NotePropertyValue 'Removed'
    Set-Content -LiteralPath (Join-Path $cut 'remove-journal.jsonl') -Value ((ConvertTo-Json $firstLink -Compress) + "`n" + '{"half a li') -Encoding utf8
    Write-CrFixProgress -Folder $cut -Step Remove -State Running -Total 2 -Done 1   # as the killed process left it
    $l = Get-CrLatestFix -ResultsRoot $work -Tenant 'contoso.onmicrosoft.com'
    Check 'a Remove cut off part way is seen as such, not as untouched' ($l.Folder -eq $cut -and $l.Interrupted -and -not $l.Previewed -and $l.Step -eq 'Remove')
    Check 'its journal says what it did, skipping a half-written line' (@(Read-CrRemoveJournal $cut).Count -eq 1 -and (Read-CrRemoveJournal $cut)[0].result -eq 'Removed')
    $again = try { Invoke-CrFix -Folder $cut -Step Remove; $false } catch { $_.Exception.Message -like '*cut off*' }
    Check 'and Remove is not run on it again' $again

    # ── A removal whose answer was lost after SharePoint had done it counts as removed ──
    $fake.Links["$od|D1|7"] = @((Link 'l-lost' 2 1 $old))
    $fake.Lost = 'l-lost'
    $lost = New-CrFix -ResultsRoot $work -Tenant 'contoso.onmicrosoft.com' -Sites @($sites[2]) -Options ([pscustomobject]@{ links = @('Organization'); age = 'Any'; fullCheck = $true })
    Invoke-CrFix -Folder $lost -Step Preview
    Invoke-CrFix -Folder $lost -Step Remove
    $lr = @((Read-CrJson (Join-Path $lost 'removed.json')).links | Where-Object shareId -EQ 'l-lost')
    Check "a lost answer is checked, not counted as failed ($($lr.result))" ($lr.Count -eq 1 -and $lr[0].result -eq 'Removed')

    # The same, but Stop is pressed at that moment: it still looks (so the record is definite), then stops.
    $fake.Links["$od|D1|7"] = @((Link 'l-lost' 2 1 $old), (Link 'l-after' 2 1 $old))
    [void]$fake.Gone.Remove('l-lost')
    $fake.StopOnLost = $true
    $lost2 = New-CrFix -ResultsRoot $work -Tenant 'contoso.onmicrosoft.com' -Sites @($sites[2]) -Options ([pscustomobject]@{ links = @('Organization'); age = 'Any'; fullCheck = $true })
    Invoke-CrFix -Folder $lost2 -Step Preview
    Invoke-CrFix -Folder $lost2 -Step Remove
    $l2 = @{}; foreach ($x in (Read-CrJson (Join-Path $lost2 'removed.json')).links) { $l2[$x.shareId] = $x.result }
    Check "Stop during the look: still checked and found removed, the rest not reached ($($l2['l-lost']) / $($l2['l-after']))" ($l2['l-lost'] -eq 'Removed' -and $l2['l-after'] -like 'Not removed: it stopped*' -and (Read-CrProgress $lost2).state -eq 'Cancelled')
    $fake.StopOnLost = $false
    $fake.Lost = $null

    # ── Stop pressed before a single link is touched: the preview is still there to remove from ──
    $fake.Links["$od|D1|7"] = @((Link 'l-early' 2 1 $old))
    $early = New-CrFix -ResultsRoot $work -Tenant 'contoso.onmicrosoft.com' -Sites @($sites[2]) -Options ([pscustomobject]@{ links = @('Organization'); age = 'Any'; fullCheck = $true })
    Invoke-CrFix -Folder $early -Step Preview
    New-Item -ItemType File -Path (Join-Path $early 'stop.request') | Out-Null
    Invoke-CrFix -Folder $early -Step Remove
    $l = Get-CrLatestFix -ResultsRoot $work -Tenant 'contoso.onmicrosoft.com'
    Check 'stopped before touching anything: no record, preview kept' (-not (Test-Path (Join-Path $early 'removed.json')) -and $l.Folder -eq $early -and $l.Previewed -and (Read-CrProgress $early).state -eq 'Cancelled' -and -not $fake.Gone.Contains('l-early'))
    Remove-Item -LiteralPath (Join-Path $early 'stop.request')
    Invoke-CrFix -Folder $early -Step Remove
    Check 'and Remove can be pressed again' ($fake.Gone.Contains('l-early') -and (Read-CrProgress $early).state -eq 'Completed')

    # ── "Shared with" says when SharePoint named only some of the people on a link ──
    $many = Link 'l-many' 6 2 $old -members 'a@contoso.com', 'b@contoso.com'
    $many.totalLinkMembersCount = 5
    $rec = New-CrLinkRecord -Site $sites[2] -ListId 'D1' -ItemId 7 -Url 'x' -Link ([pscustomobject]$many | ConvertTo-Json -Depth 6 | ConvertFrom-Json)
    Check "the rest are counted ($($rec.sharedWith))" ($rec.sharedWith -eq 'a@contoso.com; b@contoso.com; and 3 more')
    # Someone invited who isn't a member yet is named, but doesn't count against the members; case doesn't matter.
    $many.linkDetails.Invitations = @(@{ invitee = @{ email = 'guest@fabrikam.com' } }, @{ invitee = @{ email = 'A@CONTOSO.COM' } })
    $rec = New-CrLinkRecord -Site $sites[2] -ListId 'D1' -ItemId 7 -Url 'x' -Link ([pscustomobject]$many | ConvertTo-Json -Depth 6 | ConvertFrom-Json)
    Check "invitees named apart from the count ($($rec.sharedWith))" ($rec.sharedWith -eq 'a@contoso.com; b@contoso.com; guest@fabrikam.com; and 3 more')

    # ── A step just launched, before it reports: the fix counts as busy ──
    $busy = New-CrFix -ResultsRoot $work -Tenant 'contoso.onmicrosoft.com' -Sites @($sites[2]) -Options $wide180
    Invoke-CrFix -Folder $busy -Step Preview
    Set-Content -LiteralPath (Join-Path $busy 'launching') -Value 'Remove' -NoNewline
    $l = Get-CrLatestFix -ResultsRoot $work -Tenant 'contoso.onmicrosoft.com'
    Check 'a step being launched counts as running, not as a preview ready to remove from' ($l.Folder -eq $busy -and $l.Running -and -not $l.Previewed -and $l.Step -eq 'Remove')
    (Get-Item (Join-Path $busy 'launching')).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(-3)
    $l = Get-CrLatestFix -ResultsRoot $work -Tenant 'contoso.onmicrosoft.com'
    Check 'a launch that never reported stops counting after two minutes' ($l.Folder -eq $busy -and -not $l.Running -and $l.Previewed)
    Remove-Item -LiteralPath (Join-Path $busy 'launching')

    # ── Link caches carry their version in their names ──
    Check 'cache file names carry the version' ((Get-CrLinkCachePath -ResultsRoot $work -Tenant 'contoso.onmicrosoft.com' -SiteUrl $od) -like '*-v2.json')

    # ── A Remove that stops before removing anything keeps its preview ──
    $unstarted = New-CrFix -ResultsRoot $work -Tenant 'contoso.onmicrosoft.com' -Sites @($sites[2]) -Options $wide180
    Invoke-CrFix -Folder $unstarted -Step Preview
    Write-CrFixProgress -Folder $unstarted -Step Remove -State Failed -ErrorText 'Sign-in failed'
    $l = Get-CrLatestFix -ResultsRoot $work -Tenant 'contoso.onmicrosoft.com'
    Check "a Remove that never started keeps its preview, and says why ($($l.RemoveProblem))" ($l.Folder -eq $unstarted -and $l.Previewed -and $l.Step -eq 'Preview' -and $l.RemoveProblem -eq 'Sign-in failed')

    # ── Which sites belong to Teams and channels: kept for a week, read again on Refresh ──
    & $module {
        $script:MarkReads = 0
        function script:Read-CrTeamsMarks { $script:MarkReads++; [ordered]@{ 'https://contoso.sharepoint.com/sites/finance' = 'Team'; 'https://contoso.sharepoint.com/sites/finance-payroll' = 'Channel' } }
    }
    $tenantSettings = [pscustomobject]@{ tenant = 'contoso.onmicrosoft.com'; sharePointUrl = $sp }
    $m1 = Get-CrTeamsMarks -Settings $tenantSettings -ResultsRoot $work
    $m2 = Get-CrTeamsMarks -Settings $tenantSettings -ResultsRoot $work
    $reads = & $module { $script:MarkReads }
    Check "the Teams list is read once, then kept (read $reads time(s))" ($reads -eq 1 -and $m2['https://contoso.sharepoint.com/sites/finance-payroll'] -eq 'Channel')
    $null = Get-CrTeamsMarks -Settings $tenantSettings -ResultsRoot $work -Refresh
    Check 'Refresh reads it again' ((& $module { $script:MarkReads }) -eq 2)
    & $module { function script:Read-CrTeamsMarks { throw 'The admin center is unreachable.' } }
    $m3 = Get-CrTeamsMarks -Settings $tenantSettings -ResultsRoot $work -Refresh
    Check 'a refresh that fails keeps the list from before' ($m3['https://contoso.sharepoint.com/sites/finance'] -eq 'Team')
    # A copy saved by the version before (its marks under "marks") still counts.
    $oldPath = Join-Path $work 'teams-sites-fabrikam.onmicrosoft.com.json'
    Set-Content -LiteralPath $oldPath -Value ('{"tenant":"fabrikam.onmicrosoft.com","readAt":"' + [DateTimeOffset]::UtcNow.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") + '","marks":{"https://fabrikam.sharepoint.com/sites/hr":"Channel"}}')
    $m4 = Get-CrTeamsMarks -Settings ([pscustomobject]@{ tenant = 'fabrikam.onmicrosoft.com' }) -ResultsRoot $work
    Check "a copy saved the old way is still used ($($m4.Count) mark)" ($m4['https://fabrikam.sharepoint.com/sites/hr'] -eq 'Channel')
    # A link cache from before "Shared with" counted everyone is read in full once.
    $oldCache = Get-CrLinkCachePath -ResultsRoot $work -Tenant 'contoso.onmicrosoft.com' -SiteUrl $od
    $c = Read-CrJson $oldCache; $c.version = 1; Write-CrJson $oldCache $c
    $fake.Calls.Clear()
    $again = New-CrFix -ResultsRoot $work -Tenant 'contoso.onmicrosoft.com' -Sites @($sites[2]) -Options $wide180
    Invoke-CrFix -Folder $again -Step Preview
    Check 'an older link cache is read in full once' ([int](Read-CrJson (Join-Path $again 'preview.json')).checked.full -eq 1 -and [int](Read-CrJson $oldCache).version -eq 2)
    $marked = @([pscustomobject]@{ url = 'https://contoso.sharepoint.com/sites/Finance-Payroll'; kind = 'SharePoint' }, [pscustomobject]@{ url = 'https://contoso.sharepoint.com/sites/other'; kind = 'SharePoint' })
    Add-CrTeamsKinds $marked $m1
    Check 'marks match whatever the case of the address' ((Get-CrSitePlace $marked[0]) -eq 'Channel' -and (Get-CrSitePlace $marked[1]) -eq 'SharePoint')

    # ── The scan lists ignore the fixes folder ──
    Check 'past scans ignore fixes' (-not @(Get-CrPastScans $work).Count -and -not (Get-CrUnfinishedScan $work) -and -not (Get-CrRunningScan $work))
}
finally {
    Set-CrStopFile $null
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

if ($problems.Count) {
    Write-Host "Remediation test FAILED:" -ForegroundColor Red
    $problems | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
Write-Host 'Remediation test passed' -ForegroundColor Green
