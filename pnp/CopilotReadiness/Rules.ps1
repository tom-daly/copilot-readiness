# The scan rules.
# Checks, severities, thresholds and the score come from the rule book
# (rules/rulebook.json); rules/cases.json says exactly what each rule must find. Pure: no network calls, so every rule is tested.

$script:RuleBook = $null

# SharePoint RoleTypeKind values.
$script:LimitedAccess = 1
$script:Reader = 2
$script:Contributor = 3
$script:WebDesigner = 4
$script:FullControl = 5
$script:Editor = 6

$script:Ordinal = [StringComparison]::Ordinal
$script:IgnoreCase = [StringComparison]::OrdinalIgnoreCase

function Get-CrRuleBook {
    <# The rule book: next to this module in a client package, or in the repository's rules folder. #>
    if (-not $script:RuleBook) {
        $path = @(
            (Join-Path $PSScriptRoot 'rulebook.json'),
            (Join-Path $PSScriptRoot '..\..\rules\rulebook.json')
        ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        if (-not $path) { throw 'rulebook.json not found. It belongs next to CopilotReadiness.psm1.' }
        $script:RuleBook = Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json
    }
    $script:RuleBook
}

function Get-CrRule {
    param([Parameter(Mandatory)] [string] $Id)
    $rule = (Get-CrRuleBook).rules | Where-Object id -CEQ $Id
    if (-not $rule) { throw "Rule '$Id' is not in the rule book." }
    $rule
}

function Get-CrSetAside {
    <# The rule book's set-aside entry (such as the app catalog) for a site with this root web template, or nothing if it is checked as usual. #>
    param([string] $WebTemplate)
    if (-not $WebTemplate) { return }
    (Get-CrRuleBook).setAside | Where-Object { "$($_.webTemplate)".Equals($WebTemplate, $script:IgnoreCase) } | Select-Object -First 1
}

# ── Principals ──────────────────────────────────────────────────────────────

function Get-CrPrincipalKind {
    <# Who a SharePoint principal really is, from its login name. Same order of tests as Principals.Classify. #>
    param([string] $LoginName, [string] $Title, [int] $PrincipalType)

    $ln = "$LoginName".ToLowerInvariant()
    $t = "$Title".ToLowerInvariant()

    # The two claims that hand access to (effectively) everyone in the tenant.
    if ($ln.StartsWith('c:0(.s|true', $script:Ordinal)) { return 'Everyone' }
    if ($ln.StartsWith('c:0-.f|rolemanager|spo-grid-all-users', $script:Ordinal)) { return 'EveryoneExceptExternal' }

    # Hidden groups SharePoint creates per sharing link: SharingLinks.<guid>.<Kind>.<guid>
    if ($ln.Contains('sharinglinks.') -or $t.StartsWith('sharinglinks.', $script:Ordinal)) {
        $name = if ($ln.Contains('sharinglinks.')) { $ln } else { $t }
        if ($name.Contains('.anonymous')) { return 'AnyoneLink' }
        if ($name.Contains('.organization')) { return 'OrganizationLink' }
        return 'SpecificPeopleLink'
    }

    if ($ln.Contains('#ext#') -or $ln.Contains('urn:spo:guest')) { return 'Guest' }

    if ($ln -ceq 'sharepoint\system' -or $ln.EndsWith('|app@sharepoint', $script:Ordinal) -or $ln -ceq 'app@sharepoint' -or
        $ln.StartsWith('i:0i.t|ms.sp.ext|', $script:Ordinal)) { return 'System' }

    if ($PrincipalType -eq 8) { return 'SharePointGroup' }

    if ($ln.StartsWith('c:0o.c|federateddirectoryclaimprovider|', $script:Ordinal)) {
        if ($ln.EndsWith('_o', $script:Ordinal)) { return 'M365GroupOwners' }
        return 'M365Group'
    }

    if ($PrincipalType -eq 4 -or $ln.StartsWith('c:0t.c|tenant|', $script:Ordinal)) { return 'SecurityGroup' }

    'User'
}

function Get-CrAadGroupId {
    <# The Entra group id inside a group claim, e.g. c:0o.c|federateddirectoryclaimprovider|{id}_o. #>
    param([string] $LoginName)
    $last = @("$LoginName".Split('|'))[-1]
    if ($last.EndsWith('_o', $script:IgnoreCase)) { $last = $last.Substring(0, $last.Length - 2) }
    if ($last -match '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') { return $last.ToLowerInvariant() }
    $null
}

function Get-CrGuestEmail {
    <# The real email address behind a #EXT# guest login. #>
    param([string] $LoginName)
    $idx = "$LoginName".IndexOf('#ext#', $script:IgnoreCase)
    if ($idx -lt 0) { return @("$LoginName".Split('|'))[-1] }
    $local = $LoginName.Substring(0, $idx)
    $pipe = $local.LastIndexOf('|')
    if ($pipe -ge 0) { $local = $local.Substring($pipe + 1) }
    $underscore = $local.LastIndexOf('_')
    if ($underscore -lt 0) { return $local }
    "$($local.Substring(0, $underscore))@$($local.Substring($underscore + 1))"
}

function Get-CrEffectiveRoles {
    <# Permission levels that actually grant something (not Limited Access). #>
    param([object[]] $Roles)
    @($Roles | Where-Object {
            $_.kind -ne $script:LimitedAccess -and
            -not "$($_.name)".Equals('Limited Access', $script:IgnoreCase) -and
            -not "$($_.name)".Equals('Web-Only Limited Access', $script:IgnoreCase)
        })
}

function Test-CrFullControl {
    param([object[]] $Roles)
    [bool](@($Roles | Where-Object kind -EQ $script:FullControl).Count)
}

function Test-CrCanEdit {
    <# Edit or above. Custom levels count as edit unless their name says read or view. #>
    param([object[]] $Roles)
    foreach ($r in $Roles) {
        if ($r.kind -in $script:Contributor, $script:WebDesigner, $script:FullControl, $script:Editor) { return $true }
        $name = "$($r.name)"
        if ($r.kind -eq 0 -and $name.IndexOf('read', $script:IgnoreCase) -lt 0 -and $name.IndexOf('view', $script:IgnoreCase) -lt 0) { return $true }
    }
    $false
}

function Get-CrHighestRole {
    <# The most powerful permission level's name, for display. #>
    param([object[]] $Roles)
    $rank = @{ $script:FullControl = 6; $script:WebDesigner = 5; $script:Editor = 4; $script:Contributor = 3; 0 = 2; $script:Reader = 1 }
    $top = $Roles | Sort-Object -Stable -Descending { $k = [int]$_.kind; if ($rank.ContainsKey($k)) { $rank[$k] } else { 0 } } | Select-Object -First 1
    if ($top) { "$($top.name)" } else { '' }
}

function Get-CrLinkPermission {
    param([string] $LoginName)
    if ("$LoginName".IndexOf('edit', $script:IgnoreCase) -ge 0) { 'Edit' } else { 'View' }
}

# ── Findings ────────────────────────────────────────────────────────────────

function Get-CrFindingId {
    <# Stable across scans for the same issue, so two scans can be compared. The recipe is in the rule book. #>
    param([string] $SiteId, [string] $Path, [string] $Rule, [string] $PrincipalLogin)
    $text = "$("$SiteId".ToLowerInvariant())|$("$Path".ToLowerInvariant())|$Rule|$("$PrincipalLogin".ToLowerInvariant())"
    $hash = [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($text))
    [Convert]::ToHexString($hash).Substring(0, 24).ToLowerInvariant()
}

function Get-CrSiteKey {
    param([string] $SiteId)
    $hash = [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes("$SiteId".ToLowerInvariant()))
    [Convert]::ToHexString($hash).Substring(0, 16).ToLowerInvariant()
}

function New-CrFinding {
    <# The check and severity come from the rule book. -CanEdit picks a rule's edit severity, if it has one. #>
    param(
        [Parameter(Mandatory)] $Site,
        [Parameter(Mandatory)] [string] $ObjectType,
        [string] $Path = '',
        [Parameter(Mandatory)] [string] $Rule,
        [string] $Principal = '',
        [string] $PrincipalLogin = '',
        [string] $Permission = '',
        [AllowNull()] [string] $Detail,
        [Parameter(Mandatory)] [DateTimeOffset] $Now,
        [switch] $CanEdit
    )
    $def = Get-CrRule $Rule
    $severity = if ($CanEdit -and $def.severityWhenCanEdit) { $def.severityWhenCanEdit } else { $def.severity }
    [pscustomobject][ordered]@{
        id             = Get-CrFindingId $Site.siteId $Path $Rule $PrincipalLogin
        check          = $def.check
        rule           = $Rule
        severity       = $severity
        siteId         = $Site.siteId
        siteUrl        = $Site.url
        path           = $Path
        objectType     = $ObjectType
        principal      = $Principal
        principalLogin = $PrincipalLogin
        permission     = $Permission
        detail         = if ([string]::IsNullOrEmpty($Detail)) { $null } else { $Detail }
        verifiedAt     = $Now.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
    }
}

function Get-CrBroadClaimName {
    param([string] $Kind)
    if ($Kind -eq 'Everyone') { 'Everyone' } else { 'Everyone except external users' }
}

function New-CrGuestFinding {
    param($Site, [string] $ObjectType, [string] $Path, [string] $Login, [string] $Name, [object[]] $Roles, [string] $Permission, [string] $Detail, [DateTimeOffset] $Now)
    $email = Get-CrGuestEmail $Login
    $display = if ([string]::IsNullOrEmpty($Name)) { $email } else { "$Name ($email)" }
    New-CrFinding -Site $Site -ObjectType $ObjectType -Path $Path -Rule GuestAccess -Principal $display -PrincipalLogin $Login `
        -Permission $Permission -Detail $Detail -Now $Now -CanEdit:(Test-CrCanEdit $Roles)
}

# ── Rules ───────────────────────────────────────────────────────────────────

function Get-CrGrantFindings {
    <#
      Turns role assignments into findings. Scope 'Site' is the site's root web, where
      SharePoint groups are looked inside; 'Item' is a library, folder or file with its
      own permissions, where only direct grants and sharing links count.
      Assignments: principalId, loginName, title, principalType, roles (name, kind).
      Groups: principalId -> title, broadClaim, guests (login, name), memberCount.
    #>
    param(
        [Parameter(Mandatory)] $Site,
        [Parameter(Mandatory)] [string] $ObjectType,
        [string] $Path = '',
        [object[]] $Assignments = @(),
        [Parameter(Mandatory)] [ValidateSet('Site', 'Item')] [string] $Scope,
        [hashtable] $Groups = @{},
        [AllowNull()] [Nullable[int]] $OwnersGroupId,
        [AllowNull()] [string] $SiteGroupId,
        [Parameter(Mandatory)] [DateTimeOffset] $Now
    )
    $large = (Get-CrRuleBook).thresholds.largeGroupMembers

    foreach ($ra in $Assignments) {
        $roles = Get-CrEffectiveRoles $ra.roles
        if ($roles.Count -eq 0) { continue }

        $permission = Get-CrHighestRole $roles
        $kind = Get-CrPrincipalKind $ra.loginName $ra.title $ra.principalType
        $common = @{ Site = $Site; ObjectType = $ObjectType; Path = $Path; Now = $Now }

        switch ($kind) {
            { $_ -in 'Everyone', 'EveryoneExceptExternal' } {
                New-CrFinding @common -Rule EveryoneGrant -Principal (Get-CrBroadClaimName $kind) -PrincipalLogin $ra.loginName -Permission $permission
            }
            'AnyoneLink' {
                New-CrFinding @common -Rule AnyoneLink -Principal 'Anyone with the link' -PrincipalLogin $ra.loginName -Permission (Get-CrLinkPermission $ra.loginName)
            }
            'OrganizationLink' {
                New-CrFinding @common -Rule OrgWideLink -Principal 'People in your organization with the link' -PrincipalLogin $ra.loginName -Permission (Get-CrLinkPermission $ra.loginName)
            }
            'Guest' {
                New-CrGuestFinding $Site $ObjectType $Path $ra.loginName $ra.title $roles $permission $null $Now
            }
            'SpecificPeopleLink' {
                # Guests reached through a "specific people" link still have access.
                $link = $Groups[[int]$ra.principalId]
                if ($link) {
                    foreach ($g in $link.guests) {
                        New-CrGuestFinding $Site $ObjectType $Path $g.login $g.name $roles $permission 'Shared with them through a link' $Now
                    }
                }
            }
            'SharePointGroup' {
                if ($Scope -ne 'Site') { break }
                $insight = $Groups[[int]$ra.principalId]
                if (-not $insight) { break }

                if ($insight.broadClaim) {
                    New-CrFinding @common -Rule EveryoneGrant -Principal $ra.title -PrincipalLogin $ra.loginName -Permission $permission `
                        -Detail "The group contains $(Get-CrBroadClaimName $insight.broadClaim)"
                }
                foreach ($g in $insight.guests) {
                    New-CrGuestFinding $Site $ObjectType $Path $g.login $g.name $roles $permission "Member of $($ra.title)" $Now
                }
                $full = Test-CrFullControl $roles
                if ($full -and $ra.principalId -ne $OwnersGroupId) {
                    New-CrFinding @common -Rule BroadFullControl -Principal $ra.title -PrincipalLogin $ra.loginName -Permission $permission `
                        -Detail "$($insight.memberCount) members"
                }
                elseif ($full -and $insight.memberCount -gt $large) {
                    New-CrFinding @common -Rule BroadFullControl -Principal $ra.title -PrincipalLogin $ra.loginName -Permission $permission `
                        -Detail "$($insight.memberCount) members have Full Control"
                }
            }
            { $_ -in 'SecurityGroup', 'M365Group', 'M365GroupOwners' } {
                $own = $SiteGroupId -and ((Get-CrAadGroupId $ra.loginName) -eq $SiteGroupId)
                if ($Scope -eq 'Site' -and (Test-CrFullControl $roles) -and -not $own) {
                    New-CrFinding @common -Rule BroadFullControl -Principal $ra.title -PrincipalLogin $ra.loginName -Permission $permission `
                        -Detail 'A directory group has Full Control'
                }
            }
        }
    }
}

function Get-CrSiteFindings {
    <#
      Site-wide facts to findings. Facts: isGroupConnected, isPublicGroup, sensitivityLabel,
      labelKnown, lastContentChange, ownerCount, ownersKnown, groupGuests (login, name).
    #>
    param(
        [Parameter(Mandatory)] $Site,
        [Parameter(Mandatory)] $Facts,
        [Parameter(Mandatory)] [int] $StaleDays,
        [Parameter(Mandatory)] [DateTimeOffset] $Now
    )
    $root = @{ Site = $Site; ObjectType = 'Site'; Path = ''; Now = $Now }

    if ($Facts.isPublicGroup) {
        New-CrFinding @root -Rule PublicGroup -Principal 'Everyone in the organization' -Permission 'Member' `
            -Detail "The site's Microsoft 365 group is public, so anyone in the organization can join and see it"
    }

    foreach ($g in $Facts.groupGuests) {
        New-CrFinding -Site $Site -ObjectType Group -Path '' -Now $Now -Rule GuestInGroup -Principal $g.name -PrincipalLogin $g.login `
            -Permission 'Member' -Detail "Guest member of the site's Microsoft 365 group"
    }

    if ($Facts.labelKnown -and [string]::IsNullOrEmpty($Facts.sensitivityLabel)) {
        New-CrFinding @root -Rule SiteUnlabeled
    }

    if ($Facts.ownersKnown) {
        if ($Facts.ownerCount -eq 0) { New-CrFinding @root -Rule SiteOwnerless -Detail 'No active owner or site admin' }
        elseif ($Facts.ownerCount -eq 1) { New-CrFinding @root -Rule SiteSingleOwner -Detail 'Only one owner' }
    }

    $last = ConvertTo-CrDate $Facts.lastContentChange
    if ($null -ne $last -and ($Now - $last) -gt [TimeSpan]::FromDays($StaleDays)) {
        New-CrFinding @root -Rule SiteStale -Detail "No content changed since $($last.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture))"
    }
}

function Get-CrBrokenInheritanceFinding {
    param($Site, [string] $LibraryPath, [int] $UniqueItems, [DateTimeOffset] $Now, [ValidateSet('Library', 'List')] [string] $ObjectType = 'Library')
    if ($UniqueItems -le 0) { return }
    New-CrFinding -Site $Site -ObjectType $ObjectType -Path $LibraryPath -Rule BrokenInheritance -Now $Now `
        -Detail "$UniqueItems $(if ($UniqueItems -eq 1) { 'item has its' } else { 'items have their' }) own permissions"
}

function Get-CrSiteKind {
    <# SharePoint or OneDrive, as the rule book describes it. #>
    param([Parameter(Mandatory)] [string] $Kind)
    $k = (Get-CrRuleBook).siteKinds | Where-Object id -CEQ $Kind
    if (-not $k) { throw "Site kind '$Kind' is not in the rule book." }
    $k
}

function Select-CrApplicable {
    <# Keeps the findings whose rule the rule book applies to this kind of site. #>
    param([Parameter(Mandatory)] [string] $Kind, [object[]] $Findings = @())
    $applies = @((Get-CrRuleBook).rules | Where-Object { $_.appliesTo -contains $Kind } | ForEach-Object id)
    $Findings | Where-Object { $applies -contains $_.rule }
}

function Get-CrFilesUnlabeledFinding {
    param($Site, [string] $LibraryPath, [int] $Unlabeled, [int] $Files, [DateTimeOffset] $Now)
    if ($Unlabeled -le 0) { return }
    New-CrFinding -Site $Site -ObjectType Library -Path $LibraryPath -Rule FilesUnlabeled -Now $Now `
        -Detail "$Unlabeled of $Files $(if ($Files -eq 1) { 'file' } else { 'files' }) $(if ($Unlabeled -eq 1) { 'has' } else { 'have' }) no sensitivity label"
}

# ── Counts and score ────────────────────────────────────────────────────────

function New-CrCounts {
    <# Counts by check then severity, e.g. counts.Oversharing.High. Always holds every check and severity. #>
    $book = Get-CrRuleBook
    $counts = [ordered]@{}
    foreach ($c in $book.checks) {
        $bySeverity = [ordered]@{}
        foreach ($s in $book.severities) { $bySeverity[$s] = 0 }
        $counts[$c.id] = $bySeverity
    }
    $counts
}

function Add-CrCounts {
    param([Parameter(Mandatory)] $Counts, [object[]] $Findings = @())
    foreach ($f in $Findings) { $Counts[$f.check][$f.severity]++ }
}

function Get-CrSeverityTotals {
    <# Findings per severity across every check. #>
    param([Parameter(Mandatory)] $Counts)
    $totals = [ordered]@{}
    foreach ($s in (Get-CrRuleBook).severities) {
        $totals[$s] = ($Counts.Values | ForEach-Object { [int]$_[$s] } | Measure-Object -Sum).Sum
    }
    $totals
}

function Get-CrSiteScore {
    <# By default 100, minus 15 per High, 5 per Medium and 1 per Low finding, floored at 0. Takes severity totals. #>
    param([Parameter(Mandatory)] $SeverityTotals)
    $score = (Get-CrRuleBook).score
    $lost = 0
    foreach ($p in $score.penalty.PSObject.Properties) { $lost += $p.Value * [int]$SeverityTotals[$p.Name] }
    [Math]::Max([int]$score.minimum, [int]$score.start - $lost)
}

function Get-CrTenantScore {
    <# The average of the site scores. [Math]::Round rounds halves to even, as the rule book says. #>
    param([int[]] $SiteScores = @())
    if ($SiteScores.Count -eq 0) { return $null }
    [int][Math]::Round(($SiteScores | Measure-Object -Average).Average)
}

function ConvertTo-CrDate {
    <#
      JSON dates arrive as text or, after ConvertFrom-Json, as DateTime in local time.
      Both become DateTimeOffset; a DateTime becomes UTC,
      so a date shown in a finding doesn't depend on this PC's time zone.
    #>
    param($Value)
    if ($null -eq $Value -or "$Value" -eq '') { return $null }
    if ($Value -is [DateTimeOffset]) { return $Value }
    if ($Value -is [DateTime]) {
        if ($Value.Kind -eq [DateTimeKind]::Unspecified) { $Value = [DateTime]::SpecifyKind($Value, [DateTimeKind]::Utc) }
        return [DateTimeOffset]::new($Value.ToUniversalTime())
    }
    $parsed = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse("$Value", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) { return $parsed }
    $null
}
