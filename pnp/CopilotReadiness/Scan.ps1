# Walks the tenant: sites,
# subsites, lists as well as libraries, and OneDrive. Several sites are scanned at
# once. Each finished site is saved to its own file right away, so a scan that stops
# (Ctrl+C, a closed window, a lost connection) continues from where it stopped.

$script:EmptyGuid = '00000000-0000-0000-0000-000000000000'

# Tenant-role claims SharePoint adds as admins on every site; they are not owners.
$script:TenantAdminTitles = 'Company Administrator', 'Global Administrator', 'SharePoint Administrator', 'SharePoint Service Administrator'

# Libraries SharePoint uses for its own plumbing. Most are also marked as system lists.
$script:SystemLibraries = 'Style Library', 'Form Templates', 'FormServerTemplates', 'Site Assets', 'SiteAssets', 'Preservation Hold Library',
'Site Collection Documents', 'Site Collection Images'

# List items read per request when walking a library or list, and the most findings kept for one of them.
$script:ItemPageSize = 2000
$script:MaxFindingsPerLibrary = 500

$script:Labels = $null

# ── How far along a site's scan is ──────────────────────────────────────────
#
# Each site being scanned has a step note: which stage it is at (site settings,
# subsites, libraries and lists), which library and how many of its items are done, and
# how many items the whole site has. The progress window shows these notes.

$script:Step = $null

function New-CrStepNote {
    <# A step note for a site about to be scanned. Safe to read from another thread. #>
    param([Parameter(Mandatory)] $Site)
    [hashtable]::Synchronized(@{
            url = $Site.url; title = $Site.title; kind = $Site.kind; since = [DateTimeOffset]::UtcNow.UtcDateTime.ToString('o')
            doing = 'Starting'; library = $null; libraryNumber = 0; libraryCount = 0; libraryItemsDone = 0; libraryItems = 0
            itemsDone = 0; items = 0; walkSince = $null
        })
}

function Set-CrStepNote {
    <# The note this thread's scan writes to (nothing to stop writing). #>
    param($Note)
    $script:Step = $Note
}

function Set-CrStep {
    <# What the scan is doing now. Items starts the count of a site's items to check. #>
    param([Parameter(Mandatory)] [string] $Doing, [long] $Items = -1)
    Assert-CrNotStopped
    if (-not $script:Step) { return }
    $script:Step.doing = $Doing
    if ($Items -ge 0) {
        $script:Step.items = $Items
        $script:Step.itemsDone = 0
        $script:Step.walkSince = [DateTimeOffset]::UtcNow.UtcDateTime.ToString('o')
    }
}

function Set-CrStepLibrary {
    <# Starting library or list Number of Count. #>
    param([Parameter(Mandatory)] $Library, [int] $Number, [int] $Count)
    if (-not $script:Step) { return }
    $script:Step.doing = 'Checking items'
    $script:Step.library = $Library.title
    $script:Step.libraryNumber = $Number
    $script:Step.libraryCount = $Count
    $script:Step.libraryItemsDone = 0
    $script:Step.libraryItems = [long]$Library.itemCount
}

function New-CrFinishedNote {
    <# A finished site for the Finished list: its name, how it went, what it found, and when it started and ended. #>
    param([Parameter(Mandatory)] $Note, [Parameter(Mandatory)] $Site)
    [pscustomobject][ordered]@{
        title  = if ($Site.title) { "$($Site.title)" } else { "$($Site.url)" }
        url    = $Site.url
        status = $Site.status
        counts = $Site.findingCounts
        error  = $Site.error
        since  = $Note.since
        ended  = [DateTimeOffset]::UtcNow.UtcDateTime.ToString('o')
    }
}

function Get-CrStepText {
    <#
      A step note in words: Doing ("3 of 7 libraries and lists: Documents"), HowFar
      ("4,000 of 12,345 items"), Percent of the site's items checked (-1 before that
      starts), and Left, the seconds the site's items should take to finish (-1 if unknown).
    #>
    param([Parameter(Mandatory)] $Note, [DateTimeOffset] $Now = [DateTimeOffset]::UtcNow)
    $walking = "$($Note.doing)" -eq 'Checking items' -and $Note.library
    $doing = if ($walking) { "$($Note.libraryNumber) of $($Note.libraryCount) libraries and lists: $($Note.library)" } else { "$($Note.doing)" }
    $howFar = if ($walking -and [long]$Note.libraryItems -gt 0) { '{0:N0} of {1:N0} {2}' -f [Math]::Min([long]$Note.libraryItemsDone, [long]$Note.libraryItems), [long]$Note.libraryItems, $(if ([long]$Note.libraryItems -eq 1) { 'item' } else { 'items' }) } else { '' }
    $percent = if ([long]$Note.items -gt 0) { [int](100 * [Math]::Min(1.0, [double]$Note.itemsDone / [long]$Note.items)) } else { -1 }
    $left = -1
    if ($Note.walkSince -and [long]$Note.itemsDone -gt 0 -and [long]$Note.items -gt [long]$Note.itemsDone) {
        $walked = ($Now - [DateTimeOffset]::Parse($Note.walkSince, [Globalization.CultureInfo]::InvariantCulture)).TotalSeconds
        if ($walked -ge 10) { $left = $walked / [long]$Note.itemsDone * ([long]$Note.items - [long]$Note.itemsDone) }
    }
    [pscustomobject]@{ Doing = $doing; HowFar = $howFar; Percent = $percent; Left = $left }
}

function Add-CrStepItems {
    param([int] $Count = 1)
    Assert-CrNotStopped
    if (-not $script:Step) { return }
    $script:Step.itemsDone += $Count
    $script:Step.libraryItemsDone += $Count
}

function Get-CrScanLevels {
    <# The three scan levels the control window offers, lightest first. They apply to SharePoint sites. #>
    @(
        [pscustomobject]@{
            Id          = 'Quick'
            Name        = 'Quick'
            Summary     = 'Sites, libraries and lists'
            Description = 'Who each site, subsite, library and list is shared with, public teams, guests, missing site labels, and sites with no owner or no recent use. Does not open individual files.'
            PerSite     = 'a few seconds per site'
        },
        [pscustomobject]@{
            Id          = 'Standard'
            Name        = 'Standard'
            Summary     = 'Adds files with their own permissions'
            Description = 'Everything in Quick, plus a list of every file, folder and list item that has its own permissions, and a count of files with no sensitivity label.'
            PerSite     = 'up to a minute per site with many files'
        },
        [pscustomobject]@{
            Id          = 'Deep'
            Name        = 'Deep'
            Summary     = 'Checks every file'
            Description = 'Everything in Standard, plus who has access to each of those files, folders and list items, and which of them have "Anyone" links, company-wide links or guests.'
            PerSite     = 'hours on a large tenant'
        }
    )
}

function Get-CrPaces {
    <#
      How hard a scan works the tenant. Microsoft gives each app an allowance per tenant;
      the smallest (under 1,000 licenses) is 1,250 resource units a minute, roughly 600
      requests. The same numbers are used for every tenant, sized against that smallest
      allowance so no tenant is pushed near its limits: Gentle about a tenth, Normal about
      a quarter, Fast about half. Even Fast running for a whole day stays under Microsoft's
      daily limit. All three wait whenever Microsoft says to. The pace can be changed while
      a scan runs (pace.request, see Invoke-CrScan).
    #>
    @(
        [pscustomobject]@{ Id = 'Gentle'; Name = 'Gentle'; Sites = 2; PerMinute = 60
            Description = '2 sites at a time, at most 60 requests a minute, about a tenth of what Microsoft allows even the smallest tenants. For a busy tenant during the working day.' },
        [pscustomobject]@{ Id = 'Normal'; Name = 'Normal'; Sites = 3; PerMinute = 150
            Description = '3 sites at a time, at most 150 requests a minute, about a quarter of what Microsoft allows even the smallest tenants.' },
        [pscustomobject]@{ Id = 'Fast'; Name = 'Fast'; Sites = 4; PerMinute = 300
            Description = '4 sites at a time, at most 300 requests a minute, about half of what Microsoft allows even the smallest tenants. For nights and weekends.' }
    )
}
function Get-CrPace {
    <# One pace by its id; Normal for anything else, such as a scan from before paces existed. #>
    param([string] $Id)
    $all = Get-CrPaces
    $found = $all | Where-Object Id -EQ $Id
    if ($found) { $found } else { $all | Where-Object Id -EQ 'Normal' }
}

# ── Tenant ──────────────────────────────────────────────────────────────────

function Get-CrSites {
    <#
      Every site of the kinds asked for: SharePoint sites, OneDrives, or Both. Each has a
      kind. getAllSites is the supported way to list sites app-only, OneDrives included;
      search is a fallback for tenants where it fails.
    #>
    param([ValidateSet('SharePoint', 'OneDrive', 'Both')] [string] $Include = 'SharePoint')
    try {
        $raw = Get-CrGraphAll 'sites/getAllSites?$select=id,webUrl,displayName,isPersonalSite&$top=999'
    }
    catch {
        Write-Warning "Listing all sites failed ($($_.Exception.Message)); falling back to site search"
        $raw = Get-CrGraphAll 'sites?search=*&$select=id,webUrl,displayName,isPersonalSite&$top=999'
    }

    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $raw |
        ForEach-Object {
            $url = "$($_.webUrl)".TrimEnd('/')
            $kind = if ($_.isPersonalSite -or $url -match '-my\.sharepoint\.') { 'OneDrive' } else { 'SharePoint' }
            [pscustomobject]@{ siteId = "$($_.id)"; url = $url; title = "$($_.displayName)"; kind = $kind }
        } |
        Where-Object { $_.siteId -and $_.url -and ($Include -eq 'Both' -or $_.kind -eq $Include) -and $seen.Add($_.url) } |
        Sort-Object kind, url
}

function Get-CrLabels {
    <# Sensitivity label id -> name. Empty when the tenant has none or the permission is missing. #>
    if ($null -eq $script:Labels) {
        $map = @{}
        try {
            foreach ($l in Get-CrGraphAll 'security/informationProtection/sensitivityLabels?$select=id,name') {
                if ($l.id) { $map["$($l.id)"] = if ($l.name) { "$($l.name)" } else { "$($l.id)" } }
            }
        }
        catch {
            Write-Warning "Could not read sensitivity labels: $($_.Exception.Message)"
        }
        $script:Labels = $map
    }
    $script:Labels
}

# ── One site ────────────────────────────────────────────────────────────────

function ConvertTo-CrAssignment {
    <# A SharePoint role assignment as the rules expect it. #>
    param($RoleAssignment)
    $m = $RoleAssignment.Member
    [pscustomobject]@{
        principalId   = [int]$m.Id
        loginName     = "$($m.LoginName)"
        title         = "$($m.Title)"
        principalType = if ($null -ne $m.PrincipalType) { [int]$m.PrincipalType } else { 1 }
        roles         = @($RoleAssignment.RoleDefinitionBindings | ForEach-Object { [pscustomobject]@{ name = "$($_.Name)"; kind = [int]$_.RoleTypeKind } })
    }
}

function Get-CrAccessText {
    <#
      Who has access to an item, in words, for the list of items with their own permissions:
      each person, group or link with its permission level, such as "Raj (guest): Contribute"
      or "Anyone with the link: Edit". Limited access and system accounts are left out.
    #>
    param([object[]] $Assignments = @(), [hashtable] $LinkGroups = @{})
    @(foreach ($ra in $Assignments) {
            $roles = @(Get-CrEffectiveRoles $ra.roles)
            if (-not $roles.Count) { continue }
            $kind = Get-CrPrincipalKind $ra.loginName $ra.title $ra.principalType
            $who = switch ($kind) {
                'System' { $null }
                'Everyone' { 'Everyone' }
                'EveryoneExceptExternal' { 'Everyone except external users' }
                'AnyoneLink' { 'Anyone with the link' }
                'OrganizationLink' { 'People in your organization with the link' }
                'SpecificPeopleLink' {
                    $link = $LinkGroups[$ra.principalId]
                    $n = if ($link) { [int]$link.memberCount } else { 0 }
                    "Link for specific people$(if ($n) { " ($n $(if ($n -eq 1) { 'person' } else { 'people' }))" })"
                }
                'Guest' { "$($ra.title) (guest)" }
                default { "$($ra.title)" }
            }
            if (-not $who) { continue }
            $permission = if ($kind -in 'AnyoneLink', 'OrganizationLink', 'SpecificPeopleLink') { Get-CrLinkPermission $ra.loginName } else { Get-CrHighestRole $roles }
            "$($who): $permission"
        }) -join '; '
}

function Get-CrGroupInsight {
    <# What a SharePoint group's members tell us: a broad claim inside it, its guests, how many members. #>
    param([string] $Url, [int] $GroupId, [string] $Title)
    try {
        $members = Get-CrAll "$Url/_api/web/sitegroups/getbyid($GroupId)/users?`$select=Id,LoginName,Title,PrincipalType&`$top=5000"
        $broad = $null
        $guests = [System.Collections.Generic.List[object]]::new()
        foreach ($m in $members) {
            $type = if ($null -ne $m.PrincipalType) { [int]$m.PrincipalType } else { 1 }
            $kind = Get-CrPrincipalKind "$($m.LoginName)" "$($m.Title)" $type
            if ($kind -in 'Everyone', 'EveryoneExceptExternal') { if (-not $broad) { $broad = $kind } }
            elseif ($kind -eq 'Guest') { $guests.Add([pscustomobject]@{ login = "$($m.LoginName)"; name = "$($m.Title)" }) }
        }
        [pscustomobject]@{ title = $Title; broadClaim = $broad; guests = $guests.ToArray(); memberCount = $members.Count }
    }
    catch {
        # Some groups hide their membership; record what we can see.
        if ((Get-CrStatus $_) -notin 401, 403, 404) { throw }
        [pscustomobject]@{ title = $Title; broadClaim = $null; guests = @(); memberCount = 0 }
    }
}

function Add-CrGroupInsights {
    <# Looks inside every SharePoint group and "specific people" link among the assignments that hasn't been looked at yet. #>
    param([string] $Url, [object[]] $Assignments, [hashtable] $Insights)
    foreach ($ra in $Assignments) {
        if ($Insights.ContainsKey($ra.principalId)) { continue }
        if ((Get-CrPrincipalKind $ra.loginName $ra.title $ra.principalType) -in 'SharePointGroup', 'SpecificPeopleLink') {
            $Insights[$ra.principalId] = Get-CrGroupInsight $Url $ra.principalId $ra.title
        }
    }
}

function Get-CrSiteLabel {
    <#
      Label on a site that has no Microsoft 365 group. The property name has varied over
      time, so try the known ones; if none answer, the label is "unknown", not "missing".
    #>
    param([string] $Url)
    foreach ($prop in 'SensitivityLabelId', 'SensitivityLabel') {
        try {
            $s = Invoke-CrGet "$Url/_api/site?`$select=$prop"
            $id = "$($s.$prop)"
            if (-not $id -or $id -eq $script:EmptyGuid) { return @{ Label = $null; Known = $true } }
            $labels = Get-CrLabels
            return @{ Label = $(if ($labels.ContainsKey($id)) { $labels[$id] } else { $id }); Known = $true }
        }
        catch {
            # Property not supported here; try the next name.
            if ((Get-CrStatus $_) -notin 400, 404) { throw }
        }
    }
    @{ Label = $null; Known = $false }
}

function Get-CrClassicOwnerCount {
    <# Distinct people (or directory groups) who are site admins or in the Owners group. #>
    param([string] $Url, [Nullable[int]] $OwnersGroupId)
    $people = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $admins = Get-CrAll "$Url/_api/web/siteusers?`$filter=IsSiteAdmin eq true&`$select=LoginName,Title,PrincipalType"
    $owners = if ($null -ne $OwnersGroupId) {
        Get-CrAll "$Url/_api/web/sitegroups/getbyid($OwnersGroupId)/users?`$select=LoginName,Title,PrincipalType&`$top=5000"
    }
    else { @() }

    foreach ($u in @($admins) + @($owners)) {
        $title = "$($u.Title)"
        if ($script:TenantAdminTitles -contains $title) { continue }
        $type = if ($null -ne $u.PrincipalType) { [int]$u.PrincipalType } else { 1 }
        $kind = Get-CrPrincipalKind "$($u.LoginName)" $title $type
        if ($kind -in 'System', 'Everyone', 'EveryoneExceptExternal') { continue }
        [void]$people.Add("$($u.LoginName)")
    }
    $people.Count
}

function Get-CrOwnersGroupId {
    <# The web's Owners group, or nothing when it has none. #>
    param([string] $WebUrl)
    try {
        $og = Invoke-CrGet "$WebUrl/_api/web/AssociatedOwnerGroup?`$select=Id"
        if ($null -ne $og.Id -and [int]$og.Id -ge 0) { return [int]$og.Id }
    }
    catch {
        if ((Get-CrStatus $_) -ne 404) { throw }
    }
    $null
}

function Get-CrWebs {
    <# Every subsite under a web, at any depth. #>
    param([string] $WebUrl)
    $webs = Get-CrAll "$WebUrl/_api/web/webs?`$select=Title,Url,ServerRelativeUrl,HasUniqueRoleAssignments"
    foreach ($w in $webs) {
        [pscustomobject]@{ title = "$($w.Title)"; url = "$($w.Url)".TrimEnd('/'); path = "$($w.ServerRelativeUrl)"; hasUnique = [bool]$w.HasUniqueRoleAssignments }
        Get-CrWebs "$($w.Url)".TrimEnd('/')
    }
}

function Get-CrLists {
    <#
      A web's libraries and lists people put content in: not hidden, not SharePoint's own
      system lists or catalogs. Each records whether it is a library and which web owns it.
    #>
    param([string] $WebUrl)
    $lists = Get-CrAll ("$WebUrl/_api/web/lists?`$filter=Hidden eq false" +
        "&`$select=Id,Title,ItemCount,BaseType,HasUniqueRoleAssignments,IsSiteAssetsLibrary,IsSystemList,IsCatalog,RootFolder/ServerRelativeUrl&`$expand=RootFolder&`$top=500")
    foreach ($l in $lists) {
        $title = "$($l.Title)"
        if ($l.IsSiteAssetsLibrary -or $l.IsSystemList -or $l.IsCatalog -or $script:SystemLibraries -contains $title) { continue }
        [pscustomobject]@{
            id        = "$($l.Id)"
            title     = $title
            path      = "$($l.RootFolder.ServerRelativeUrl)"
            itemCount = [int]$l.ItemCount
            isLibrary = [int]$l.BaseType -eq 1
            hasUnique = [bool]$l.HasUniqueRoleAssignments
            webUrl    = $WebUrl
        }
    }
}

function Get-CrListGrantFindings {
    <# Findings for the lists and libraries among these that have their own permissions. #>
    param($Site, [object[]] $Lists, [hashtable] $Insights, [Nullable[int]] $OwnersGroupId, [string] $SiteGroupId, [DateTimeOffset] $Now)
    foreach ($list in $Lists | Where-Object hasUnique) {
        $ras = Get-CrAll "$($list.webUrl)/_api/web/lists(guid'$($list.id)')/RoleAssignments?`$expand=Member,RoleDefinitionBindings"
        $assignments = @($ras | ForEach-Object { ConvertTo-CrAssignment $_ })
        Add-CrGroupInsights $Site.url $assignments $Insights
        Get-CrGrantFindings -Site $Site -ObjectType $(if ($list.isLibrary) { 'Library' } else { 'List' }) -Path $list.path `
            -Assignments $assignments -Scope Item -Groups $Insights -OwnersGroupId $OwnersGroupId -SiteGroupId $SiteGroupId -Now $Now
    }
}

function Invoke-CrSiteSettingsScan {
    <#
      Site-level checks: who the root web and each subsite with its own permissions is
      shared with (looking inside SharePoint groups), whether the Microsoft 365 group is
      public or has guests, the site's sensitivity label, its owners, when content last
      changed, and libraries and lists that have their own permissions. Returns findings,
      a summary, and the libraries and lists for the item-level pass.
    #>
    param([Parameter(Mandatory)] $Site, [Parameter(Mandatory)] [int] $StaleDays, [Parameter(Mandatory)] [DateTimeOffset] $Now)

    $url = $Site.url
    $findings = [System.Collections.Generic.List[object]]::new()

    # Site collection: Microsoft 365 group and label
    Set-CrStep 'Reading the site''s settings'
    $siteProps = Invoke-CrGet "$url/_api/site?`$select=Id,GroupId"
    $groupId = "$($siteProps.GroupId)"
    if (-not $groupId -or $groupId -eq $script:EmptyGuid) { $groupId = $null }

    $isPublic = $false
    $label = $null
    $labelKnown = $false
    $groupGuests = @()
    $owners = 0
    $ownersKnown = $false

    if ($groupId) {
        try {
            $group = Invoke-CrGraph "groups/$groupId`?`$select=id,visibility,assignedLabels"
            $isPublic = "$($group.visibility)" -eq 'Public'
            $label = @($group.assignedLabels | ForEach-Object { "$($_.displayName)" } | Where-Object { $_ }) | Select-Object -First 1
            $labelKnown = $true

            $ownerObjects = Get-CrGraphAll "groups/$groupId/owners/microsoft.graph.user?`$select=id,accountEnabled"
            $owners = @($ownerObjects | Where-Object { $_.accountEnabled -ne $false }).Count
            $ownersKnown = $true

            $guests = Get-CrGraphAll "groups/$groupId/members/microsoft.graph.user?`$filter=userType eq 'Guest'&`$count=true&`$select=id,displayName,userPrincipalName,mail" -AdvancedQuery -Max 200
            $groupGuests = @($guests | ForEach-Object {
                    [pscustomobject]@{
                        login = if ($_.userPrincipalName) { "$($_.userPrincipalName)" } elseif ($_.id) { "$($_.id)" } else { '' }
                        name  = if ($_.displayName) { "$($_.displayName)" } elseif ($_.mail) { "$($_.mail)" } else { '' }
                    }
                })
        }
        catch {
            # A deleted group can leave its site behind; treat the site as having no group.
            if ((Get-CrStatus $_) -ne 404) { throw }
            Write-Verbose "Group $groupId for $url not found"
            $groupId = $null
        }
    }

    if (-not $groupId) {
        $l = Get-CrSiteLabel $url
        $label = $l.Label
        $labelKnown = $l.Known
    }

    # Root web: grants, owners group, last change
    Set-CrStep 'Checking who the site is shared with'
    $web = Invoke-CrGet "$url/_api/web?`$select=Title,LastItemUserModifiedDate&`$expand=RoleAssignments/Member,RoleAssignments/RoleDefinitionBindings"
    $assignments = @($web.RoleAssignments | ForEach-Object { ConvertTo-CrAssignment $_ })
    $lastChange = ConvertTo-CrDate $web.LastItemUserModifiedDate
    $ownersGroupId = Get-CrOwnersGroupId $url

    $insights = @{}
    Add-CrGroupInsights $url $assignments $insights

    if (-not $groupId) {
        $owners = Get-CrClassicOwnerCount $url $ownersGroupId
        $ownersKnown = $true
    }

    $findings.AddRange([object[]]@(Get-CrGrantFindings -Site $Site -ObjectType Site -Path '' -Assignments $assignments -Scope Site `
                -Groups $insights -OwnersGroupId $ownersGroupId -SiteGroupId $groupId -Now $Now))

    $facts = [pscustomobject]@{
        isGroupConnected  = [bool]$groupId
        isPublicGroup     = $isPublic
        sensitivityLabel  = $label
        labelKnown        = $labelKnown
        lastContentChange = $lastChange
        ownerCount        = $owners
        ownersKnown       = $ownersKnown
        groupGuests       = $groupGuests
    }
    $findings.AddRange([object[]]@(Get-CrSiteFindings -Site $Site -Facts $facts -StaleDays $StaleDays -Now $Now))

    # Subsites with their own permissions are checked like the root web, with their own Owners group.
    Set-CrStep 'Finding subsites'
    $webs = @(Get-CrWebs $url)
    $ownWebs = @($webs | Where-Object hasUnique)
    $number = 0
    foreach ($w in $ownWebs) {
        $number++
        Set-CrStep "Checking subsite $number of $($ownWebs.Count): $($w.title)"
        $ras = Get-CrAll "$($w.url)/_api/web/RoleAssignments?`$expand=Member,RoleDefinitionBindings"
        $subAssignments = @($ras | ForEach-Object { ConvertTo-CrAssignment $_ })
        Add-CrGroupInsights $url $subAssignments $insights
        $findings.AddRange([object[]]@(Get-CrGrantFindings -Site $Site -ObjectType Subsite -Path $w.path -Assignments $subAssignments -Scope Site `
                    -Groups $insights -OwnersGroupId (Get-CrOwnersGroupId $w.url) -SiteGroupId $groupId -Now $Now))
    }

    # Libraries and lists, in the root web and every subsite
    Set-CrStep 'Finding libraries and lists'
    $lists = @(Get-CrLists $url) + @(foreach ($w in $webs) { Get-CrLists $w.url })
    Set-CrStep "Checking who $(@($lists | Where-Object hasUnique).Count) of $($lists.Count) libraries and lists are shared with"
    $findings.AddRange([object[]]@(Get-CrListGrantFindings -Site $Site -Lists $lists -Insights $insights -OwnersGroupId $ownersGroupId -SiteGroupId $groupId -Now $Now))

    $guestCount = @($findings | Where-Object check -EQ 'ExternalGuests' | ForEach-Object { $_.principalLogin.ToLowerInvariant() } | Sort-Object -Unique).Count

    [pscustomobject]@{
        Findings  = $findings.ToArray()
        Libraries = $lists
        Summary   = [pscustomobject]@{
            isGroupConnected = [bool]$groupId
            sensitivityLabel = $label
            lastActivityAt   = $lastChange
            ownerCount       = $owners
            guestCount       = $guestCount
            subsiteCount     = $webs.Count
        }
    }
}

function Invoke-CrOneDriveSettingsScan {
    <#
      A OneDrive: who the whole OneDrive and each of its libraries is shared with. Its
      files are checked one by one afterwards. Owners, labels and activity are not
      judged; the rule book says which rules apply to OneDrive.
    #>
    param([Parameter(Mandatory)] $Site, [Parameter(Mandatory)] [DateTimeOffset] $Now)

    $url = $Site.url
    $findings = [System.Collections.Generic.List[object]]::new()
    Set-CrStep 'Checking who the OneDrive is shared with'
    $web = Invoke-CrGet "$url/_api/web?`$select=Title,LastItemUserModifiedDate&`$expand=RoleAssignments/Member,RoleAssignments/RoleDefinitionBindings"
    $assignments = @($web.RoleAssignments | ForEach-Object { ConvertTo-CrAssignment $_ })
    $insights = @{}
    Add-CrGroupInsights $url $assignments $insights
    $findings.AddRange([object[]]@(Get-CrGrantFindings -Site $Site -ObjectType Site -Path '' -Assignments $assignments -Scope Site -Groups $insights -Now $Now))

    Set-CrStep 'Finding libraries'
    $lists = @(Get-CrLists $url)
    $findings.AddRange([object[]]@(Get-CrListGrantFindings -Site $Site -Lists $lists -Insights $insights -Now $Now))

    [pscustomobject]@{
        Findings  = $findings.ToArray()
        Libraries = $lists
        Summary   = [pscustomobject]@{
            isGroupConnected = $false
            sensitivityLabel = $null
            lastActivityAt   = ConvertTo-CrDate $web.LastItemUserModifiedDate
            ownerCount       = 1
            guestCount       = 0
            subsiteCount     = 0
        }
    }
}

# ── One library or list ─────────────────────────────────────────────────────

function Get-CrLinkMembers {
    <# Guests inside a "specific people" sharing link's hidden group. #>
    param([string] $Url, [int] $GroupId, [string] $Title)
    try {
        $members = Get-CrAll "$Url/_api/web/sitegroups/getbyid($GroupId)/users?`$select=LoginName,Title,PrincipalType"
        $guests = @($members | Where-Object {
                $type = if ($null -ne $_.PrincipalType) { [int]$_.PrincipalType } else { 1 }
                (Get-CrPrincipalKind "$($_.LoginName)" "$($_.Title)" $type) -eq 'Guest'
            } | ForEach-Object { [pscustomobject]@{ login = "$($_.LoginName)"; name = "$($_.Title)" } })
        [pscustomobject]@{ title = $Title; broadClaim = $null; guests = $guests; memberCount = $members.Count }
    }
    catch {
        if ((Get-CrStatus $_) -notin 401, 403, 404) { throw }
        [pscustomobject]@{ title = $Title; broadClaim = $null; guests = @(); memberCount = 0 }
    }
}

function Get-CrItemLabel {
    <# SharePoint returns fields whose names start with an underscore with "OData_" in front. #>
    param($Item)
    foreach ($name in 'OData__IpLabelId', '_IpLabelId') {
        if ($Item.PSObject.Properties[$name]) { return "$($Item.$name)" }
    }
    ''
}

function Invoke-CrLibraryScan {
    <#
      Walks one library or list a page at a time. Reading items by ID page (rather than
      folder by folder) is one request per few thousand items and is not blocked by the
      5,000-item list view threshold. With -Deep, each item that has its own permissions
      costs one more request, to read who it is shared with. Lists have no file labels.
      With -ListUnique, every item with its own permissions is returned in UniqueList
      (where it is, and with -Deep who has access), for people to go through themselves.

      Big libraries take a while, so after each page OnPage is given where the walk has got
      to (the next page and everything counted and found so far); passed back as Resume,
      the walk picks up from there instead of the first page.
    #>
    param(
        [Parameter(Mandatory)] $Site,
        [Parameter(Mandatory)] $Library,
        [switch] $Deep,
        [switch] $ListUnique,
        [Parameter(Mandatory)] [hashtable] $LinkGroups,
        [Parameter(Mandatory)] [DateTimeOffset] $Now,
        $Resume,
        [scriptblock] $OnPage
    )
    $webUrl = $Library.webUrl
    $base = "$webUrl/_api/web/lists(guid'$($Library.id)')/items?`$select=Id,FileRef,FSObjType,HasUniqueRoleAssignments"
    $labelsKnown = [bool]$Library.isLibrary
    $files = 0
    $unique = 0
    $unlabeled = 0
    $walked = 0
    $findings = [System.Collections.Generic.List[object]]::new()
    $uniqueList = [System.Collections.Generic.List[object]]::new()

    if ($Resume) {
        $labelsKnown = [bool]$Resume.labelsKnown
        $files = [long]$Resume.files; $unique = [long]$Resume.unique; $unlabeled = [long]$Resume.unlabeled; $walked = [long]$Resume.walked
        foreach ($f in @($Resume.findings)) { if ($f) { $findings.Add($f) } }
        foreach ($u in @($Resume.uniqueList)) { if ($u) { $uniqueList.Add($u) } }
        Add-CrStepItems -Count $walked
        $page = Get-CrPage $Resume.next
    }
    elseif ($labelsKnown) {
        try {
            $page = Get-CrPage "$base,_IpLabelId&`$top=$script:ItemPageSize"
        }
        catch {
            # No sensitivity label column in this library: scan without it and don't judge labels.
            if ((Get-CrStatus $_) -ne 400) { throw }
            Write-Verbose "Library $($Library.title) on $webUrl has no label column; skipping label check"
            $labelsKnown = $false
            $page = Get-CrPage "$base&`$top=$script:ItemPageSize"
        }
    }
    else {
        $page = Get-CrPage "$base&`$top=$script:ItemPageSize"
    }

    while ($true) {
        $pageFindings = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $page.Items) {
            Add-CrStepItems
            $walked++
            $isFolder = [int]$item.FSObjType -eq 1
            if (-not $isFolder) {
                $files++
                if ($labelsKnown -and -not (Get-CrItemLabel $item)) { $unlabeled++ }
            }
            if (-not $item.HasUniqueRoleAssignments) { continue }
            $unique++
            # A list item's FileRef isn't something a browser can open; its display form is.
            $objectType, $path = if ($isFolder) { 'Folder', "$($item.FileRef)" }
            elseif ($Library.isLibrary) { 'File', "$($item.FileRef)" }
            else { 'Item', "$($Library.path)/DispForm.aspx?ID=$($item.Id)" }
            $entry = if ($ListUnique) { [pscustomobject][ordered]@{ library = $Library.path; libraryName = $Library.title; path = $path; objectType = $objectType; access = $null } }
            if ($entry) { $uniqueList.Add($entry) }
            if (-not $Deep) { continue }

            try {
                $raw = Get-CrAll "$webUrl/_api/web/lists(guid'$($Library.id)')/items($($item.Id))/RoleAssignments?`$expand=Member,RoleDefinitionBindings"
            }
            catch {
                if ((Get-CrStatus $_) -eq 404) { continue } # deleted since the page was read
                throw
            }
            $assignments = @($raw | ForEach-Object { ConvertTo-CrAssignment $_ })

            # Look inside "specific people" link groups so guests reached by link are seen.
            foreach ($ra in $assignments) {
                if ((Get-CrPrincipalKind $ra.loginName $ra.title $ra.principalType) -eq 'SpecificPeopleLink' -and -not $LinkGroups.ContainsKey($ra.principalId)) {
                    $LinkGroups[$ra.principalId] = Get-CrLinkMembers $Site.url $ra.principalId $ra.title
                }
            }
            if ($entry) { $entry.access = Get-CrAccessText $assignments $LinkGroups }

            $pageFindings.AddRange([object[]]@(Get-CrGrantFindings -Site $Site -ObjectType $objectType -Path $path `
                        -Assignments $assignments -Scope Item -Groups $LinkGroups -OwnersGroupId $null -SiteGroupId $null -Now $Now))
        }

        # Keep the results readable on badly overshared libraries: past the cap, only the totals record it.
        $room = [Math]::Max(0, $script:MaxFindingsPerLibrary - $findings.Count)
        $rank = @{ High = 0; Medium = 1; Low = 2 }
        $findings.AddRange([object[]]@($pageFindings | Sort-Object -Stable { $rank[$_.severity] } | Select-Object -First $room))

        if (-not $page.Next) { break }
        if ($OnPage) {
            & $OnPage ([pscustomobject][ordered]@{
                    next = $page.Next; labelsKnown = $labelsKnown; files = $files; unique = $unique; unlabeled = $unlabeled; walked = $walked
                    findings = $findings.ToArray(); uniqueList = $uniqueList.ToArray()
                })
        }
        $page = Get-CrPage $page.Next
    }

    $bi = Get-CrBrokenInheritanceFinding $Site $Library.path $unique $Now -ObjectType $(if ($Library.isLibrary) { 'Library' } else { 'List' })
    if ($bi) { $findings.Add($bi) }
    if ($labelsKnown) {
        $fu = Get-CrFilesUnlabeledFinding $Site $Library.path $unlabeled $files $Now
        if ($fu) { $findings.Add($fu) }
    }

    [pscustomobject]@{ Findings = $findings.ToArray(); UniqueItems = $unique; UniqueList = $uniqueList.ToArray(); Walked = $walked }
}

$script:BlockedReason = 'Archived or locked by an admin. Nobody can open it, Copilot included, until it is brought back; scan it again then.'

function Test-CrSiteBlocked {
    <#
      Whether a site is archived (Microsoft 365 Archive) or locked so that nobody can open
      it. SharePoint only answers 403 for those; Microsoft Graph says 423, "resource locked".
    #>
    param([Parameter(Mandatory)] $Site)
    try {
        $null = Invoke-CrGraph "sites/$($Site.siteId)?`$select=id"
        $false
    }
    catch { (Get-CrStatus $_) -eq 423 }
}

# Save a site's place every this many seconds while it walks a library (always after each library).
$script:CheckpointSeconds = 30

function Save-CrCheckpoint {
    <#
      Writes where a site's walk has got to (see Invoke-CrSiteScan): the libraries it has
      finished and what they found, and Current, the library it is partway through. Within
      a library it saves at most every CheckpointSeconds; -Now saves straight away.
    #>
    param([Parameter(Mandatory)] $Place, $Current, [switch] $Now)
    if (-not $Place.Path) { return }
    if (-not $Now -and ([DateTimeOffset]::UtcNow - $Place.SavedAt).TotalSeconds -lt $script:CheckpointSeconds) { return }
    Write-CrJson $Place.Path ([pscustomobject][ordered]@{
            level         = $Place.Level
            savedAt       = [DateTimeOffset]::UtcNow.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
            doneLibraries = $Place.DoneLibraries.ToArray()
            findings      = @($Place.Findings.Values)
            uniqueItems   = $Place.UniqueItems
            uniqueList    = $Place.UniqueList.ToArray()
            walked        = $Place.Walked
            linkGroups    = @(foreach ($k in @($Place.LinkGroups.Keys)) { [pscustomobject]@{ id = [int]$k; group = $Place.LinkGroups[$k] } })
            current       = $Current
        })
    $Place.SavedAt = [DateTimeOffset]::UtcNow
}
function Invoke-CrSiteScan {
    <#
      One site at the chosen level; a OneDrive always has its shared files checked one by
      one, since that is where its risk is. Only rules that apply to the site's kind are
      kept. Never throws: a site that fails is recorded as Failed with its error.

      With Checkpoint (a file path), a site whose libraries are being walked keeps its place
      in that file: after each library, and every so often within a big one. If the scan
      stops partway, the next run of the site re-reads its settings (a few requests) and
      then picks up the walk where the file says, rather than from the first item. The
      caller deletes the file once the site's result is saved.
    #>
    param(
        [Parameter(Mandatory)] $Site,
        [Parameter(Mandatory)] [ValidateSet('Quick', 'Standard', 'Deep')] [string] $Level,
        [Parameter(Mandatory)] [int] $StaleDays,
        [string] $Checkpoint
    )
    $now = [DateTimeOffset]::UtcNow
    $kind = if ($Site.kind) { $Site.kind } else { 'SharePoint' }
    # Upsert by id: the same issue found twice is one finding.
    $byId = [ordered]@{}
    $summary = $null
    $uniqueItems = 0
    $uniqueList = [System.Collections.Generic.List[object]]::new()
    $status = 'Done'
    $errorText = $null

    try {
        # Sites the rule book leaves out on purpose, such as the app catalog: recorded with the reason, nothing checked.
        $setAside = if ($kind -ne 'OneDrive') { Get-CrSetAside (Invoke-CrGet "$($Site.url)/_api/web?`$select=WebTemplate").WebTemplate }
        if ($setAside) {
            $status = 'Skipped'
            $errorText = "$($setAside.name): $($setAside.reason)"
        }
        else {
            $settings = if ($kind -eq 'OneDrive') { Invoke-CrOneDriveSettingsScan -Site $Site -Now $now }
            else { Invoke-CrSiteSettingsScan -Site $Site -StaleDays $StaleDays -Now $now }
            $summary = $settings.Summary
            foreach ($f in $settings.Findings) { $byId[$f.id] = $f }

            $walk = $kind -eq 'OneDrive' -or $Level -ne 'Quick'
            if ($walk) {
                $linkGroups = @{}
                # Where an earlier run of this site got to: libraries finished, what they found, and the one it was partway through.
                $place = [pscustomobject]@{ Path = $Checkpoint; Level = $Level; DoneLibraries = [System.Collections.Generic.List[string]]::new(); Findings = [ordered]@{}
                    UniqueItems = 0L; UniqueList = $uniqueList; Walked = 0L; LinkGroups = $linkGroups; SavedAt = [DateTimeOffset]::MinValue }
                $saved = if ($Checkpoint -and (Test-Path -LiteralPath $Checkpoint)) { try { Read-CrJson $Checkpoint } catch { $null } } else { $null }
                $current = $null
                if ($saved -and $saved.level -eq $Level) {
                    foreach ($id in @($saved.doneLibraries)) { if ($id) { $place.DoneLibraries.Add("$id") } }
                    foreach ($f in @($saved.findings)) { if ($f) { $place.Findings[$f.id] = $f; $byId[$f.id] = $f } }
                    foreach ($u in @($saved.uniqueList)) { if ($u) { $uniqueList.Add($u) } }
                    foreach ($g in @($saved.linkGroups)) { if ($g) { $linkGroups[[int]$g.id] = $g.group } }
                    $place.UniqueItems = [long]$saved.uniqueItems
                    $place.Walked = [long]$saved.walked
                    $current = $saved.current
                    $uniqueItems = $place.UniqueItems
                }

                $toWalk = @($settings.Libraries | Where-Object itemCount -GT 0)
                Set-CrStep 'Checking items' -Items ([long]($toWalk | Measure-Object itemCount -Sum).Sum)
                if ($place.Walked) { Add-CrStepItems -Count $place.Walked }
                $number = 0
                foreach ($lib in $toWalk) {
                    $number++
                    $libraryId = "$($lib.id)"
                    if ($place.DoneLibraries.Contains($libraryId)) { continue }
                    Set-CrStepLibrary $lib $number $toWalk.Count
                    $resume = if ($current -and "$($current.libraryId)" -eq $libraryId) { $current.walk } else { $null }
                    # The library's own findings and list so far travel with its walk until it's done, so nothing is counted twice.
                    $onPage = { param($walk) Save-CrCheckpoint $place ([pscustomobject]@{ libraryId = $libraryId; walk = $walk }) }.GetNewClosure()
                    # SharePoint sites list every item with its own permissions, for people to go through; a OneDrive's are its shared files, judged by the rules alone.
                    $result = Invoke-CrLibraryScan -Site $Site -Library $lib -Deep:($kind -eq 'OneDrive' -or $Level -eq 'Deep') -ListUnique:($kind -ne 'OneDrive') -LinkGroups $linkGroups -Now $now `
                        -Resume $resume -OnPage $onPage
                    $uniqueItems += $result.UniqueItems
                    $uniqueList.AddRange([object[]]$result.UniqueList)
                    foreach ($f in $result.Findings) { $byId[$f.id] = $f; $place.Findings[$f.id] = $f }
                    $place.UniqueItems = $uniqueItems
                    $place.Walked += [long]$result.Walked
                    $place.DoneLibraries.Add($libraryId)
                    Save-CrCheckpoint $place $null -Now
                }
            }
        }
    }
    catch {
        # Stopped partway: nothing is saved for this site, so continuing starts it again.
        if ($_.Exception -is [System.OperationCanceledException]) { throw }
        $status = 'Failed'
        $errorText = $_.Exception.Message
        # An archived or locked site refuses everyone, Copilot included: nothing to retry, nothing at risk.
        if ((Get-CrStatus $_) -in 403, 423 -and (Test-CrSiteBlocked $Site)) {
            $status = 'Skipped'
            $errorText = $script:BlockedReason
            $byId.Clear()
            $uniqueList.Clear()
        }
    }

    $findings = @(Select-CrApplicable -Kind $kind -Findings @($byId.Values))
    $counts = New-CrCounts
    Add-CrCounts $counts $findings
    $totals = Get-CrSeverityTotals $counts

    [pscustomobject]@{
        Site     = [pscustomobject][ordered]@{
            siteId           = $Site.siteId
            url              = $Site.url
            title            = $Site.title
            kind             = $kind
            status           = $status
            isGroupConnected = if ($summary) { $summary.isGroupConnected } else { $false }
            sensitivityLabel = if ($summary) { $summary.sensitivityLabel } else { $null }
            lastActivityAt   = if ($summary -and $summary.lastActivityAt) { $summary.lastActivityAt.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") } else { $null }
            ownerCount       = if ($summary) { $summary.ownerCount } else { 0 }
            guestCount       = if ($summary) { $summary.guestCount } else { 0 }
            subsiteCount     = if ($summary) { $summary.subsiteCount } else { 0 }
            uniqueItemCount  = $uniqueItems
            score            = if ($status -eq 'Done') { Get-CrSiteScore $totals } else { $null }
            findingCounts    = $totals
            error            = $errorText
        }
        Counts      = $counts
        Findings    = $findings
        UniqueItems = $uniqueList.ToArray()
    }
}

# ── A whole scan ────────────────────────────────────────────────────────────

function Write-CrJson {
    <#
      Writes JSON through a temporary file, so a stopped scan never leaves half a file behind.
      The progress window, or a virus checker, may be reading the old file at that moment,
      and Windows then refuses to replace it; so it tries again for a few seconds.
    #>
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] $Value)
    $temp = "$Path.tmp"
    # Passed whole, not piped, so an empty list is written as [] and a list of one stays a list.
    ConvertTo-Json -InputObject $Value -Depth 20 | Set-Content -LiteralPath $temp -Encoding utf8
    for ($attempt = 1; ; $attempt++) {
        try { [System.IO.File]::Move($temp, $Path, $true); return }
        catch [System.IO.IOException], [System.UnauthorizedAccessException] {
            if ($attempt -ge 50) { throw }
            Start-Sleep -Milliseconds 100
        }
    }
}

function Read-CrJson {
    <# Reads JSON letting others read and write meanwhile; the file is open only for a moment. #>
    param([Parameter(Mandatory)] [string] $Path)
    $stream = [System.IO.File]::Open($Path, 'Open', 'Read', [System.IO.FileShare]'ReadWrite, Delete')
    try { $text = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8).ReadToEnd() }
    finally { $stream.Dispose() }
    $text | ConvertFrom-Json -DateKind String
}

function New-CrScan {
    <# Creates a scan folder: what to scan and how, and an empty summary. Returns the folder. #>
    param(
        [Parameter(Mandatory)] [string] $ResultsRoot,
        [Parameter(Mandatory)] [ValidateSet('Quick', 'Standard', 'Deep')] [string] $Level,
        [Parameter(Mandatory)] [object[]] $Sites,
        [Parameter(Mandatory)] [string] $Tenant,
        [int] $StaleDays = (Get-CrRuleBook).thresholds.staleDays,
        [ValidateSet('Gentle', 'Normal', 'Fast')] [string] $Pace = 'Normal'
    )
    $now = [DateTimeOffset]::UtcNow
    $scanId = "$($now.ToString('yyyyMMdd''T''HHmmss'))-$([guid]::NewGuid().ToString('N').Substring(0, 4))"
    $folder = Join-Path $ResultsRoot $scanId
    New-Item -ItemType Directory -Path (Join-Path $folder 'sites') -Force | Out-Null
    $kinds = @($Sites | ForEach-Object { if ($_.kind) { $_.kind } else { 'SharePoint' } } | Sort-Object -Unique)
    $include = if ($kinds.Count -gt 1) { 'Both' } elseif ($kinds) { $kinds[0] } else { 'SharePoint' }

    Write-CrJson (Join-Path $folder 'scope.json') ([pscustomobject][ordered]@{
            scanId    = $scanId
            tenant    = $Tenant
            level     = $Level
            include   = $include
            pace      = $Pace
            staleDays = $StaleDays
            rulebook  = (Get-CrRuleBook).version
            sites     = @($Sites | ForEach-Object {
                    [pscustomobject][ordered]@{ siteId = $_.siteId; url = $_.url; title = $_.title; kind = $(if ($_.kind) { $_.kind } else { 'SharePoint' }) }
                })
        })

    Write-CrJson (Join-Path $folder 'scan.json') ([pscustomobject][ordered]@{
            scanId        = $scanId
            status        = 'Running'
            requestedBy   = "$([Environment]::UserName) on $([Environment]::MachineName)"
            startedAt     = $now.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
            completedAt   = $null
            includeFiles  = $Level -ne 'Quick'
            level         = $Level
            include       = $include
            sitesTotal    = @($Sites).Count
            sitesDone     = 0
            score         = $null
            oneDriveScore = $null
            findingsTotal = 0
            counts        = New-CrCounts
            error         = $null
        })
    $folder
}

function Get-CrUnfinishedScan {
    <# The newest scan in the results folder that never finished (of this tenant, if given), or nothing. #>
    param([Parameter(Mandatory)] [string] $ResultsRoot, [string] $Tenant)
    if (-not (Test-Path -LiteralPath $ResultsRoot)) { return }
    Get-ChildItem -LiteralPath $ResultsRoot -Directory | Sort-Object Name -Descending | ForEach-Object {
        $file = Join-Path $_.FullName 'scan.json'
        if (Test-Path -LiteralPath $file) {
            $scan = Read-CrJson $file
            if ($scan.status -in 'Running', 'Cancelled') {
                $scope = Read-CrJson (Join-Path $_.FullName 'scope.json')
                if (-not $Tenant -or $scope.tenant -eq $Tenant) { [pscustomobject]@{ Folder = $_.FullName; Scan = $scan; Scope = $scope } }
            }
        }
    } | Select-Object -First 1
}

function Get-CrPastScans {
    <#
      Every scan in the results folder (of this tenant, if given), newest first: when it
      started, how far it got, how it ended and what it found. State is Completed, Running
      (a process is on it now) or Stopped (it can be continued).
    #>
    param([Parameter(Mandatory)] [string] $ResultsRoot, [string] $Tenant)
    if (-not (Test-Path -LiteralPath $ResultsRoot)) { return }
    $severities = (Get-CrRuleBook).severities
    foreach ($dir in Get-ChildItem -LiteralPath $ResultsRoot -Directory | Sort-Object Name -Descending) {
        try {
            $scanFile = Join-Path $dir.FullName 'scan.json'
            $scopeFile = Join-Path $dir.FullName 'scope.json'
            if (-not (Test-Path -LiteralPath $scanFile) -or -not (Test-Path -LiteralPath $scopeFile)) { continue }
            $scope = Read-CrJson $scopeFile
            if ($Tenant -and $scope.tenant -ne $Tenant) { continue }
            $scan = Read-CrJson $scanFile
            $state = if ($scan.status -eq 'Completed') { 'Completed' } elseif (Test-CrScanRunning $dir.FullName) { 'Running' } else { 'Stopped' }
            $done = if ($state -eq 'Completed') { [int]$scan.sitesDone } else { @(Get-ChildItem -LiteralPath (Join-Path $dir.FullName 'sites') -Filter '*.json').Count }
            $found = [ordered]@{}
            foreach ($s in $severities) { $found[$s] = 0 }
            if ($scan.counts) { foreach ($check in $scan.counts.PSObject.Properties) { foreach ($s in $severities) { $found[$s] += [int]$check.Value.$s } } }
            $report = Join-Path $dir.FullName 'report.html'
            [pscustomobject]@{
                Folder    = $dir.FullName
                StartedAt = [DateTimeOffset]::Parse($scan.startedAt, [Globalization.CultureInfo]::InvariantCulture)
                Level     = $scope.level
                Include   = $scope.include
                Total     = @($scope.sites).Count
                Done      = $done
                State     = $state
                Score     = $scan.score
                OneDriveScore = $(if ($scan.PSObject.Properties['oneDriveScore']) { $scan.oneDriveScore } else { $null })
                Findings  = $(if ($state -eq 'Completed') { $found } else { $null })
                Report    = $(if (Test-Path -LiteralPath $report) { $report } else { $null })
            }
        }
        catch { continue }   # a folder that isn't a scan, or is half written
    }
}

function Remove-CrScan {
    <#
      Removes a past scan's folder: to the Recycle Bin, so it can be got back, unless
      -Permanently. A scan running now is left alone. Returns whether it was removed.
    #>
    param([Parameter(Mandatory)] [string] $Folder, [switch] $Permanently)
    if (-not (Test-Path -LiteralPath (Join-Path $Folder 'scan.json'))) { throw "$Folder is not a scan folder." }
    if (Test-CrScanRunning $Folder) { return $false }
    if ($Permanently) { Remove-Item -LiteralPath $Folder -Recurse -Force }
    else {
        Add-Type -AssemblyName Microsoft.VisualBasic
        [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($Folder, 'OnlyErrorDialogs', 'SendToRecycleBin')
    }
    $true
}
# ── Progress, for the progress window ───────────────────────────────────────
#
# A running scan writes progress.json in its folder every second or so: which process
# is scanning, how many sites are done, which are in progress, and what has been found.
# The progress window reads it; dropping a stop.request file in the folder asks the scan
# to stop once the sites in progress are finished.

function Get-CrProcessStamp {
    <# When a process started, as text, so a process id reused by Windows isn't mistaken for the scan. #>
    param([Parameter(Mandatory)] [System.Diagnostics.Process] $Process)
    try { $Process.StartTime.ToUniversalTime().ToString('o') } catch { '' }
}

function Test-CrProcessAlive {
    param([int] $Id, [string] $StartedAt)
    $p = Get-Process -Id $Id -ErrorAction SilentlyContinue
    if (-not $p) { return $false }
    $stamp = Get-CrProcessStamp $p
    if (-not $StartedAt -or -not $stamp) { return $true }
    # Compared as times, not text, so a file rewritten by hand or another tool still matches.
    $a = [DateTimeOffset]::MinValue; $b = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse($stamp, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$a) -or
        -not [DateTimeOffset]::TryParse("$StartedAt", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$b)) { return $stamp -eq "$StartedAt" }
    [Math]::Abs(($a - $b).TotalSeconds) -lt 1
}

function Read-CrProgress {
    <# progress.json, or nothing when there isn't one or it is being rewritten. #>
    param([Parameter(Mandatory)] [string] $Folder)
    $file = Join-Path $Folder 'progress.json'
    if (-not (Test-Path -LiteralPath $file)) { return }
    try { Read-CrJson $file } catch { }
}

function Test-CrScanRunning {
    <# Whether another process is scanning this folder right now. #>
    param([Parameter(Mandatory)] [string] $Folder)
    $p = Read-CrProgress $Folder
    [bool]($p -and $p.state -in 'Starting', 'Running', 'Stopping' -and [int]$p.pid -ne $PID -and (Test-CrProcessAlive $p.pid $p.processStartedAt))
}

function Get-CrRunningScan {
    <# The folder of a scan (of this tenant, if given) that a process is working on right now, or nothing. #>
    param([Parameter(Mandatory)] [string] $ResultsRoot, [string] $Tenant)
    if (-not (Test-Path -LiteralPath $ResultsRoot)) { return }
    Get-ChildItem -LiteralPath $ResultsRoot -Directory | Sort-Object Name -Descending |
        Where-Object { (Test-Path -LiteralPath (Join-Path $_.FullName 'progress.json')) -and (Test-CrScanRunning $_.FullName) } |
        Where-Object { -not $Tenant -or (Read-CrJson (Join-Path $_.FullName 'scope.json')).tenant -eq $Tenant } |
        Select-Object -First 1 -ExpandProperty FullName
}

function Update-CrTally {
    <# Keeps a note of each saved site's status and finding counts, re-reading only files that changed. Returns the notes that are new. #>
    param([Parameter(Mandatory)] [string] $SitesFolder, [Parameter(Mandatory)] [hashtable] $Tally)
    foreach ($file in Get-ChildItem -LiteralPath $SitesFolder -Filter '*.json') {
        $seen = $Tally[$file.Name]
        if ($seen -and $seen.Time -eq $file.LastWriteTimeUtc) { continue }
        try { $site = (Read-CrJson $file.FullName).site } catch { continue }
        $note = @{ Time = $file.LastWriteTimeUtc; Failed = $site.status -eq 'Failed'; Skipped = $site.status -eq 'Skipped'; Counts = $site.findingCounts; Title = $(if ($site.title) { $site.title } else { $site.url }); Error = $site.error }
        $Tally[$file.Name] = $note
        $note
    }
}

function Write-CrProgress {
    <# Writes progress.json for the scanning process (this one, unless given). Current holds the sites in progress, each with url, title, kind and since. #>
    param(
        [Parameter(Mandatory)] [string] $Folder,
        [Parameter(Mandatory)] [string] $State,
        [int] $Total,
        [int] $Done,
        [int] $DoneAtStart,
        [object[]] $Current = @(),
        [hashtable] $Tally = @{},
        [DateTimeOffset] $RunStartedAt = [DateTimeOffset]::UtcNow,
        $Score = $null,
        $OneDriveScore = $null,
        [string] $ErrorText = $null,
        [object[]] $Recent = @(),
        [System.Diagnostics.Process] $Process = (Get-Process -Id $PID)
    )
    $found = [ordered]@{}
    $throttle = Get-CrThrottle
    foreach ($s in (Get-CrRuleBook).severities) { $found[$s] = 0 }
    foreach ($t in $Tally.Values) { foreach ($s in @($found.Keys)) { $found[$s] += [int]$t.Counts.$s } }
    Write-CrJson (Join-Path $Folder 'progress.json') ([pscustomobject][ordered]@{
            pid              = $Process.Id
            processStartedAt = Get-CrProcessStamp $Process
            state            = $State
            total            = $Total
            done             = $Done
            doneAtStart      = $DoneAtStart
            failed           = @($Tally.Values | Where-Object Failed).Count
            skipped          = @($Tally.Values | Where-Object Skipped).Count
            runStartedAt     = $RunStartedAt.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
            updatedAt        = [DateTimeOffset]::UtcNow.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
            current          = @($Current | ForEach-Object {
                    # A copy of each step note as it is right now; the scan keeps changing the note itself.
                    # Holding the note's lock, which its writer takes for every change, so the copy never sees it change halfway.
                    if ($_ -is [System.Collections.IDictionary]) {
                        $copy = [ordered]@{}
                        [System.Threading.Monitor]::Enter($_.SyncRoot)
                        try { foreach ($k in @($_.Keys)) { $copy[$k] = $_[$k] } }
                        finally { [System.Threading.Monitor]::Exit($_.SyncRoot) }
                        [pscustomobject]$copy
                    }
                    else { $_ }
                } | Sort-Object since)
            findings         = $found
            recent           = @($Recent)
            pausedUntil      = if ($throttle.PauseUntil -gt (Get-CrUtcNow)) { $throttle.PauseUntil.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") } else { $null }
            waits            = [int]$throttle.Waits
            pace             = $throttle.Pace
            # Easing off after Microsoft said wait: how far, what it means now, and when it next steps back up.
            easeSteps        = [int]$throttle.EaseSteps
            easeUntil        = if ([int]$throttle.EaseSteps -gt 0) { $throttle.EaseUntil.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") } else { $null }
            perMinute        = [int]$throttle.PerMinute
            sitesAtOnce      = [int]$throttle.Sites
            score            = $Score
            oneDriveScore    = $OneDriveScore
            error            = $ErrorText
        })
}

function Set-CrProgressState {
    <# Changes the state (and error) in progress.json, for a scan that ends before it starts scanning. #>
    param([Parameter(Mandatory)] [string] $Folder, [Parameter(Mandatory)] [string] $State, [string] $ErrorText)
    $p = Read-CrProgress $Folder
    if (-not $p) { return }
    $p.state = $State
    $p.error = $ErrorText
    Write-CrJson (Join-Path $Folder 'progress.json') $p
}

function Start-CrBackgroundScan {
    <#
      Runs Start.ps1 -RunScan for a scan folder in a hidden PowerShell window, so the scan
      continues when the progress window or the console is closed. What it prints goes to
      scan.log and scan-errors.log in the folder. Returns the process.
    #>
    param([Parameter(Mandatory)] [string] $Folder, [Parameter(Mandatory)] [string] $StartScript, [Parameter(Mandatory)] [string] $SettingsPath)
    if (Test-CrScanRunning $Folder) { throw 'This scan is already running.' }
    Remove-Item -LiteralPath (Join-Path $Folder 'stop.request') -ErrorAction SilentlyContinue
    $arguments = '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$StartScript`"", '-RunScan', "`"$Folder`"", '-SettingsPath', "`"$SettingsPath`""
    $process = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $arguments -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput (Join-Path $Folder 'scan.log') -RedirectStandardError (Join-Path $Folder 'scan-errors.log')

    # Until the scan itself reports, the window shows it signing in.
    $scope = Read-CrJson (Join-Path $Folder 'scope.json')
    $done = @(Get-ChildItem -LiteralPath (Join-Path $Folder 'sites') -Filter '*.json').Count
    $p = Read-CrProgress $Folder
    if (-not $p -or [int]$p.pid -ne $process.Id) {
        $tally = @{}
        $null = Update-CrTally (Join-Path $Folder 'sites') $tally
        Write-CrProgress -Folder $Folder -State Starting -Total @($scope.sites).Count -Done $done -DoneAtStart $done -Tally $tally -Process $process
    }
    $process
}

function Get-CrSitesToScan {
    <# The sites in a scan folder still to do: no result yet, or a result that failed. #>
    param([Parameter(Mandatory)] [string] $Folder, [Parameter(Mandatory)] $Scope)
    $sitesFolder = Join-Path $Folder 'sites'
    foreach ($site in $Scope.sites) {
        $file = Join-Path $sitesFolder "$(Get-CrSiteKey $site.siteId).json"
        if ((Test-Path -LiteralPath $file) -and (Read-CrJson $file).site.status -ne 'Failed') { continue }
        $site
    }
}

function Invoke-CrScan {
    <#
      Scans every site in a scan folder still to do, then writes the summary and the
      report. Run it again on the same folder to continue after a stop. With -Settings to
      sign in with, it works at the scan's pace (scope.json): that many sites at once, each
      worker with its own sign-in, and no more requests a minute than the pace allows;
      -Parallel fixes the number of sites. Without -Settings (the offline tests) it scans
      one site at a time, unpaced. It keeps progress.json up to date for the progress
      window, and stops taking new sites once a stop.request file appears in the folder.
      A pace.request file holding Gentle, Normal or Fast changes the pace as it runs: the
      requests a minute at once, and the sites at once as sites in progress finish.
    #>
    param(
        [Parameter(Mandatory)] [string] $Folder,
        [int] $Parallel = 0,
        $Settings
    )

    if (Test-CrScanRunning $Folder) { throw 'This scan is already running, in the background or another window. Run Start again to see how it is going.' }
    $scope = Read-CrJson (Join-Path $Folder 'scope.json')
    $scanFile = Join-Path $Folder 'scan.json'
    $sitesFolder = Join-Path $Folder 'sites'
    $stopFile = Join-Path $Folder 'stop.request'
    Remove-Item -LiteralPath $stopFile -ErrorAction SilentlyContinue
    $total = @($scope.sites).Count
    $todo = @(Get-CrSitesToScan $Folder $scope)
    $finished = $false
    $errorText = $null
    $jobs = @()

    $scan = Read-CrJson $scanFile
    $scan.status = 'Running'
    Write-CrJson $scanFile $scan
    $activity = "Copilot Readiness: $($scope.level) scan"

    # What the progress window shows. Sites in progress are keyed by worker.
    $tally = @{}
    $current = [System.Collections.Concurrent.ConcurrentDictionary[int, object]]::new()
    # Sites finished this run, newest first, for the progress window's Finished list.
    $finishedSites = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
    $recent = [System.Collections.Generic.List[object]]::new()
    $runStartedAt = [DateTimeOffset]::UtcNow
    # One throttle for every worker: when Microsoft says wait, they all wait, and together they keep to the pace.
    # Where sites partway through keep their place (see Invoke-CrSiteScan).
    $null = New-Item -ItemType Directory -Path (Join-Path $Folder 'partial') -Force
    $paceFile = Join-Path $Folder 'pace.request'
    $throttle = New-CrThrottle
    Set-CrThrottlePace $throttle (Get-CrPace $scope.pace) -Paced:([bool]$Settings) -Sites $Parallel
    # Enough workers for the fastest pace; those above the current pace's number wait their turn.
    $workers = if ($Parallel -gt 0) { $Parallel } else { (Get-CrPaces | Measure-Object Sites -Maximum).Maximum }
    Set-CrThrottle $throttle
    Set-CrStopFile $stopFile
    $doneAtStart = $total - $todo.Count
    $null = Update-CrTally $sitesFolder $tally
    $logged = @{ Waits = 0; Ease = $null }
    $report = {
        param([string] $state, [int] $left)
        # A new pace asked for from the progress window: from now on, and when the scan is continued later.
        if (Test-Path -LiteralPath $paceFile) {
            try {
                $wanted = Get-CrPace "$(Get-Content -LiteralPath $paceFile -Raw)".Trim()
                Remove-Item -LiteralPath $paceFile -ErrorAction SilentlyContinue
                if ($wanted.Id -ne $throttle.Pace) {
                    Set-CrThrottlePace $throttle $wanted -Paced:([bool]$Settings) -Sites $Parallel
                    $saved = Read-CrJson (Join-Path $Folder 'scope.json')
                    $saved | Add-Member -NotePropertyName pace -NotePropertyValue $wanted.Id -Force
                    Write-CrJson (Join-Path $Folder 'scope.json') $saved
                    Write-Host "$(Get-Date -Format 'h:mm:ss tt')  Pace changed to $($wanted.Name): $($wanted.Description)"
                }
            }
            catch { Write-Host "$(Get-Date -Format 'h:mm:ss tt')  Couldn't change the pace: $($_.Exception.Message)" }
        }
        # A line per finished site, for scan.log and the progress window's details.
        foreach ($n in Update-CrTally $sitesFolder $tally) {
            if ($n.Failed) { Write-Host "$(Get-Date -Format 'h:mm:ss tt')  Couldn't read $($n.Title): $($n.Error)" }
            elseif ($n.Skipped) { Write-Host "$(Get-Date -Format 'h:mm:ss tt')  Left out $($n.Title): $($n.Error)" }
            else { Write-Host ("{0:h:mm:ss tt}  Done: {1} ({2} High, {3} Medium, {4} Low)" -f (Get-Date), $n.Title, [int]$n.Counts.High, [int]$n.Counts.Medium, [int]$n.Counts.Low) }
        }
        if ([int]$throttle.EaseSteps -gt 0) { Update-CrEase $throttle }
        if ($throttle.Waits -gt $logged.Waits) {
            $logged.Waits = $throttle.Waits
            Write-Host ("{0:h:mm:ss tt}  Microsoft asked the scan to slow down; everything waits until {1:h:mm:ss tt}." -f (Get-Date), $throttle.PauseUntil.ToLocalTime())
        }
        # Only easing off (or stepping back up) is logged here; a pace chosen in the window is logged above.
        $ease = [int]$throttle.EaseSteps
        if ($ease -ne $logged.Ease) {
            if ($null -ne $logged.Ease) {
                if ([int]$throttle.EaseSteps -gt 0) { Write-Host ("{0:h:mm:ss tt}  Easing off: {1} {2} at a time{3}, until {4:h:mm:ss tt} at least." -f (Get-Date), $throttle.Sites, $(if ([int]$throttle.Sites -eq 1) { 'site' } else { 'sites' }), $(if ([int]$throttle.PerMinute -gt 0) { ", at most $($throttle.PerMinute) requests a minute" }), $throttle.EaseUntil.ToLocalTime()) }
                else { Write-Host ("{0:h:mm:ss tt}  Back to the {1} pace." -f (Get-Date), (Get-CrPace $throttle.Pace).Name) }
            }
            $logged.Ease = $ease
        }
        $item = $null
        while ($finishedSites.TryDequeue([ref]$item)) { $recent.Insert(0, $item) }
        if ($recent.Count -gt 200) { $recent.RemoveRange(200, $recent.Count - 200) }
        # Progress is only for the window: failing to write it must never end the scan.
        try { Write-CrProgress -Folder $Folder -State $state -Total $total -Done ($total - $left) -DoneAtStart $doneAtStart -Current @($current.Values) -Tally $tally -RunStartedAt $runStartedAt -Recent $recent.ToArray() }
        catch { Write-Host "$(Get-Date -Format 'h:mm:ss tt')  Couldn't update the progress window this time: $($_.Exception.Message)" }
    }

    try {
        # Without a sign-in to give workers (the offline tests), sites are scanned here, one at a time.
        if (-not $Settings -or $todo.Count -eq 0) {
            $left = $todo.Count
            foreach ($site in $todo) {
                if (Test-Path -LiteralPath $stopFile) { break }
                $current[0] = New-CrStepNote $site
                Set-CrStepNote $current[0]
                & $report 'Running' $left
                Write-Progress -Id 1 -Activity $activity -Status "$($total - $left + 1) of $total  $($site.url)" -PercentComplete ([int](100 * ($total - $left) / [Math]::Max(1, $total)))
                $checkpoint = Join-Path (Join-Path (Split-Path $sitesFolder) 'partial') "$(Get-CrSiteKey $site.siteId).json"
                try { $result = Invoke-CrSiteScan -Site $site -Level $scope.level -StaleDays $scope.staleDays -Checkpoint $checkpoint }
                catch [System.OperationCanceledException] { break }
                Write-CrJson (Join-Path $sitesFolder "$(Get-CrSiteKey $site.siteId).json") ([pscustomobject]@{ site = $result.Site; findings = $result.Findings; uniqueItems = $result.UniqueItems })
                # Saved whole, the site no longer needs its place; one that failed keeps it, so the retry picks up there.
                if ($result.Site.status -ne 'Failed') { Remove-Item -LiteralPath $checkpoint -ErrorAction SilentlyContinue }
                $finishedSites.Enqueue((New-CrFinishedNote $current[0] $result.Site))
                $left--
            }
            $null = $current.TryRemove(0, [ref]$null)
            Set-CrStepNote $null
            $stopped = $left -gt 0
        }
        else {
            # Workers take sites from one queue until it's empty or a stop is asked for, each signed in on its own.
            $queue = [System.Collections.Concurrent.ConcurrentQueue[object]]::new([object[]]$todo)
            $modulePath = Join-Path $PSScriptRoot 'CopilotReadiness.psm1'
            $jobs = @(foreach ($n in 1..([Math]::Min([Math]::Max(1, $workers), $todo.Count))) {
                    Start-ThreadJob -ArgumentList $n, $modulePath, $Settings, $queue, $current, $scope, $sitesFolder, $stopFile, $throttle, $finishedSites -ScriptBlock {
                        param($n, $modulePath, $settings, $queue, $current, $scope, $sitesFolder, $stopFile, $throttle, $finishedSites)
                        $ErrorActionPreference = 'Stop'
                        Import-Module $modulePath
                        Set-CrThrottle $throttle
                        Set-CrStopFile $stopFile
                        $site = $null
                        $signedIn = $false
                        while (-not (Test-Path -LiteralPath $stopFile)) {
                            # A new site starts only while fewer than the pace's number are in progress, counting every
                            # worker's; sites already going when the pace drops finish first. Checked and taken under
                            # one lock, so two workers can't both take the last place.
                            $took = $false
                            [System.Threading.Monitor]::Enter($throttle.SyncRoot)
                            try {
                                if ($current.Count -lt [int]$throttle.Sites -and $queue.TryDequeue([ref]$site)) {
                                    $current[$n] = New-CrStepNote $site
                                    $took = $true
                                }
                            }
                            finally { [System.Threading.Monitor]::Exit($throttle.SyncRoot) }
                            if (-not $took) {
                                if ($queue.IsEmpty) { break }
                                Start-Sleep -Milliseconds 500
                                continue
                            }
                            if (-not $signedIn) {
                                try {
                                    Import-Module PnP.PowerShell -MinimumVersion (Get-CrPnPRequired)
                                    Connect-CrTenant $settings
                                }
                                catch [System.OperationCanceledException] { $null = $current.TryRemove($n, [ref]$null); break }
                                catch { $null = $current.TryRemove($n, [ref]$null); throw }
                                $signedIn = $true
                            }
                            Set-CrStepNote $current[$n]
                            $checkpoint = Join-Path (Join-Path (Split-Path $sitesFolder) 'partial') "$(Get-CrSiteKey $site.siteId).json"
                            try { $result = Invoke-CrSiteScan -Site $site -Level $scope.level -StaleDays $scope.staleDays -Checkpoint $checkpoint }
                            catch [System.OperationCanceledException] { $null = $current.TryRemove($n, [ref]$null); break }
                            Write-CrJson (Join-Path $sitesFolder "$(Get-CrSiteKey $site.siteId).json") ([pscustomobject]@{ site = $result.Site; findings = $result.Findings; uniqueItems = $result.UniqueItems })
                            # Saved whole, the site no longer needs its place; one that failed keeps it, so the retry picks up there.
                            if ($result.Site.status -ne 'Failed') { Remove-Item -LiteralPath $checkpoint -ErrorAction SilentlyContinue }
                            $finishedSites.Enqueue((New-CrFinishedNote $current[$n] $result.Site))
                            $null = $current.TryRemove($n, [ref]$null)
                        }
                    }
                })
            while ($jobs | Where-Object State -In 'NotStarted', 'Running') {
                $left = $queue.Count + $current.Count
                $done = $total - $left
                & $report $(if (Test-Path -LiteralPath $stopFile) { 'Stopping' } else { 'Running' }) $left
                # In a PowerShell window: a bar for the whole scan, and one under it for each site in progress.
                Write-Progress -Id 1 -Activity $activity -Status "$done of $total sites done, $($current.Count) in progress" -PercentComplete ([int](100 * $done / [Math]::Max(1, $total)))
                foreach ($k in 1..$jobs.Count) {
                    $note = $null
                    if ($current.TryGetValue($k, [ref]$note)) {
                        $words = Get-CrStepText $note
                        Write-Progress -Id (10 + $k) -ParentId 1 -Activity $(if ($note.title) { $note.title } else { $note.url }) -Status (@($words.Doing, $words.HowFar) -ne '' -join ', ') -PercentComplete $words.Percent
                    }
                    else { Write-Progress -Id (10 + $k) -ParentId 1 -Activity 'Site' -Completed }
                }
                Start-Sleep -Milliseconds 1000
            }
            foreach ($j in $jobs | Where-Object State -EQ 'Failed') { Write-Warning "A scan worker stopped: $($j.JobStateInfo.Reason.Message)" }
            $missing = @(Get-CrSitesToScan $Folder $scope | Where-Object { -not (Test-Path -LiteralPath (Join-Path $sitesFolder "$(Get-CrSiteKey $_.siteId).json")) }).Count
            $stopped = (Test-Path -LiteralPath $stopFile) -and $missing -gt 0
            if (-not $stopped -and $missing) {
                throw 'Some sites were not scanned because a scan worker stopped. Run the scan again to continue.'
            }
        }
        Write-Progress -Id 1 -Activity 'Copilot Readiness' -Completed
        $finished = -not $stopped
    }
    catch {
        $errorText = $_.Exception.Message
        throw
    }
    finally {
        if ($jobs) { $jobs | Stop-Job -ErrorAction SilentlyContinue; $jobs | Remove-Job -Force -ErrorAction SilentlyContinue }
        # Runs on Ctrl+C too, so the summary always matches what was saved.
        Complete-CrScan -Folder $Folder -Status $(if ($finished) { 'Completed' } else { 'Cancelled' })
        if ($finished) { Remove-Item -LiteralPath (Join-Path $Folder 'partial') -Recurse -Force -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $stopFile, $paceFile -ErrorAction SilentlyContinue
        Set-CrStopFile $null
        Set-CrStepNote $null
        $current.Clear()
        & $report 'Running' 0 | Out-Null
        $final = Read-CrJson $scanFile
        Write-CrProgress -Folder $Folder -State $(if ($finished) { 'Completed' } elseif ($errorText) { 'Failed' } else { 'Cancelled' }) -Total $total `
            -Done @($tally.Keys).Count -DoneAtStart $doneAtStart -Tally $tally -RunStartedAt $runStartedAt -Score $final.score -OneDriveScore $final.oneDriveScore -ErrorText $errorText -Recent $recent.ToArray()
        $failed = @($tally.Values | Where-Object Failed)
        if ($failed.Count) { Write-Warning "$($failed.Count) of $total sites could not be read; the report lists them and why. Run the scan again to retry them." }
        if (-not $finished) {
            Write-Host ''
            Write-Host 'Scan stopped. Everything finished so far is saved; run Start.ps1 again and choose Continue.' -ForegroundColor Yellow
        }
    }
}

function Complete-CrScan {
    <# Adds up the saved sites into scan.json, sites.json and findings.json, and writes the report when the scan is complete. #>
    param([Parameter(Mandatory)] [string] $Folder, [Parameter(Mandatory)] [string] $Status)

    $scanFile = Join-Path $Folder 'scan.json'
    $scan = Read-CrJson $scanFile
    $sites = [System.Collections.Generic.List[object]]::new()
    $findings = [System.Collections.Generic.List[object]]::new()
    $counts = New-CrCounts
    $scores = [System.Collections.Generic.List[int]]::new()
    $ownScores = [System.Collections.Generic.List[int]]::new()
    $uniqueItems = [System.Collections.Generic.List[object]]::new()

    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $Folder 'sites') -Filter '*.json') {
        $saved = Read-CrJson $file.FullName
        $sites.Add($saved.site)
        $f = @($saved.findings)
        $findings.AddRange([object[]]$f)
        Add-CrCounts $counts $f
        foreach ($u in @($saved.uniqueItems)) {
            if ($u) { $uniqueItems.Add([pscustomobject][ordered]@{ siteId = $saved.site.siteId; siteUrl = $saved.site.url; library = $u.library; libraryName = $u.libraryName; path = $u.path; objectType = $u.objectType; access = $u.access }) }
        }
        # SharePoint sites make up the tenant score; OneDrives, which the rule book gives a score of their own, make up the OneDrive score.
        $kind = if ($saved.site.kind) { $saved.site.kind } else { 'SharePoint' }
        if ($saved.site.status -eq 'Done' -and $null -eq $saved.site.score -and (Get-CrSiteKind $kind).ownScore) {
            # A OneDrive saved before OneDrive had a score: work it out from its saved counts.
            $totals = @{}
            foreach ($p in $saved.site.findingCounts.PSObject.Properties) { $totals[$p.Name] = $p.Value }
            $saved.site.score = Get-CrSiteScore $totals
        }
        if ($saved.site.status -eq 'Done' -and $null -ne $saved.site.score) {
            if ((Get-CrSiteKind $kind).inTenantScore) { $scores.Add([int]$saved.site.score) }
            elseif ((Get-CrSiteKind $kind).ownScore) { $ownScores.Add([int]$saved.site.score) }
        }
    }

    $scan.status = $Status
    $scan.completedAt = [DateTimeOffset]::UtcNow.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    $scan.sitesDone = $sites.Count
    $scan.counts = $counts
    $scan.findingsTotal = $findings.Count
    # Only a full scan earns a score; a partial one would flatter the tenant.
    $scan.score = if ($Status -eq 'Completed') { Get-CrTenantScore $scores.ToArray() } else { $null }
    $scan | Add-Member -NotePropertyName oneDriveScore -NotePropertyValue $(if ($Status -eq 'Completed') { Get-CrTenantScore $ownScores.ToArray() } else { $null }) -Force
    Write-CrJson $scanFile $scan

    if ($Status -eq 'Completed') {
        Export-CrResults -Folder $Folder -Scan $scan -Sites $sites.ToArray() -Findings $findings.ToArray() -UniqueItems $uniqueItems.ToArray()
    }
}
