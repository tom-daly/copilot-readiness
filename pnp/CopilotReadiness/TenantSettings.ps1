# The tenant's sharing and Copilot settings, read from the SharePoint admin center, for
# the Tenant tab. They don't change what the scan finds or the score; they explain why
# so many links and guests turn up, and what to change so fewer are made.

function Get-CrAdminUrl {
    <# The SharePoint admin center for a tenant, from its SharePoint address. #>
    param([Parameter(Mandatory)] [string] $SharePointUrl)
    $SharePointUrl -replace '(?i)^(https://[^.]+)\.sharepoint\.com.*$', '$1-admin.sharepoint.com'
}

function Read-CrTenantSettings {
    <#
      Reads the settings the Tenant tab shows, as the scanner app, through its own connection
      to the admin center so the scan's connection is left alone. Returns name = value.
    #>
    param([Parameter(Mandatory)] $Settings)
    $admin = Get-CrAdminUrl $Settings.sharePointUrl
    $connection = Invoke-CrCertificateWait { Connect-PnPOnline -Url $admin -ClientId $Settings.app.clientId -Tenant $Settings.tenant -Thumbprint $Settings.app.thumbprint -ReturnConnection -ErrorAction Stop }
    $tenant = Get-PnPTenant -Connection $connection -ErrorAction Stop
    $values = [ordered]@{}
    foreach ($p in $tenant.PSObject.Properties) { $values[$p.Name] = $p.Value }
    # Restricted SharePoint Search is a separate setting; older PnP.PowerShell versions can't read it.
    $values['RestrictedSearchMode'] = try {
        $mode = Get-PnPTenantRestrictedSearchMode -Connection $connection -ErrorAction Stop
        if ($mode.Mode) { "$($mode.Mode)" } elseif ("$mode" -match 'Enabled') { 'Enabled' } else { 'Disabled' }
    }
    catch { $null }
    $values
}

function Get-CrTenantSettingsPath {
    <# Where a tenant's settings are kept once read: a file in the results folder, which the scan lists ignore. #>
    param([Parameter(Mandatory)] [string] $ResultsRoot, [Parameter(Mandatory)] [string] $Tenant)
    Join-Path $ResultsRoot ("tenant-settings-{0}.json" -f (Get-CrTenantFileName $Tenant))
}

function ConvertTo-CrPlainSettings {
    <#
      The settings as plain text, numbers and true/false, so they read back from a file the same
      as they came: a choice such as ExternalUserAndGuestSharing is kept as its name, not a number.
    #>
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Values)
    $plain = [ordered]@{}
    foreach ($k in $Values.Keys) {
        $v = $Values[$k]
        $plain[$k] = if ($null -eq $v) { $null }
        elseif ($v -is [enum] -or $v -is [guid] -or $v -is [DateTime] -or $v -is [DateTimeOffset]) { "$v" }
        elseif ($v -is [string] -or $v -is [bool] -or $v -is [ValueType]) { $v }
        elseif ($v -is [System.Collections.IEnumerable]) { , @($v | ForEach-Object { "$_" }) }
        else { "$v" }
    }
    $plain
}

function Get-CrSavedTenantSettings {
    <#
      The tenant's sharing and Copilot settings for the Tenant tab. They're read from the tenant
      once and kept in the results folder; after that the saved copy is used, until -Refresh reads
      them again. Returns View (from Get-CrTenantSettingsView, or why they couldn't be read), ReadAt
      (when they were read, or nothing) and Problem (why a refresh failed, when the older copy is
      shown instead).
    #>
    param([Parameter(Mandatory)] $Settings, [Parameter(Mandatory)] [string] $ResultsRoot, [switch] $Refresh)
    $path = Get-CrTenantSettingsPath $ResultsRoot $Settings.tenant
    try {
        $kept = Get-CrKeptCopy -Path $path -Refresh:$Refresh -OldKey 'values' -Read { ConvertTo-CrPlainSettings (Read-CrTenantSettings $Settings) }
        [pscustomobject]@{ View = Get-CrTenantSettingsView (ConvertTo-CrDictionary $kept.Value) -SharePointUrl $Settings.sharePointUrl; ReadAt = $kept.ReadAt; Problem = $kept.Problem }
    }
    catch { [pscustomobject]@{ View = $_.Exception.Message; ReadAt = $null; Problem = $null } }
}

function Get-CrCodeSpans {
    <# The parts of some PowerShell worth colouring, as a code editor would: each with Start, Length and Kind (Comment, Command, Option, Value or Variable). #>
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Text)
    $pattern = '(?m)(?<Comment>^#[^\r\n]*)|(?<Command>\b[A-Z][a-z]+-[A-Za-z]+\b)|(?<Value>https://\S+|<[^>\r\n]+>)|(?<Variable>\$\w+)|(?<Option>(?<=\s)-[A-Za-z]+)|(?<Value>(?<=\s-[A-Za-z]+\s)\S+)'
    foreach ($m in [regex]::Matches($Text, $pattern)) {
        foreach ($kind in 'Comment', 'Command', 'Option', 'Value', 'Variable') {
            if ($m.Groups[$kind].Success) { [pscustomobject]@{ Start = $m.Index; Length = $m.Length; Kind = $kind }; break }
        }
    }
}

function Get-CrTenantSettingsView {
    <#
      Turns the raw settings into what the Tenant tab shows: groups of rows, each with the
      setting's plain name, its value in words, a State (Good, Watch or Info) and, when it
      could be better, what to change. Each row also carries Links: Microsoft's guide to the
      setting and, when there is one, the admin center page where it is changed (SharePointUrl
      gives the tenant; without it only the guides are linked), Where: the trail to follow to
      reach the setting, in words, Picture: a screenshot of that screen, when there is one, and
      Recommended: the value we suggest, in the same words as Value. Each link has an Icon: a
      Windows icon-font character for its button. Commands holds the PowerShell to change a setting
      that's changed that way and needs changing: one each for SPO and PnP, with Tool, Caption, Text and Help (a
      link to what's needed first, or nothing). Settings
      this tenant doesn't have are left out.
    #>
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Values, [string] $SharePointUrl)
    function Has($name) { $Values.Contains($name) -and $null -ne $Values[$name] -and "$($Values[$name])" -ne '' }
    function Row($name, $value, $state, $advice = '') { [pscustomobject]@{ Name = $name; Value = $value; State = $state; Advice = $advice; Recommended = ''; Where = ''; Picture = ''; Links = @(); Commands = @() } }

    # Where each setting is explained and changed. Admin center pages need the tenant; the rest are the same for everyone.
    # Where is the trail to follow, as the admin center words it (checked against a real tenant in October 2026), and
    # Picture a screenshot of that screen, in the pictures folder next to this file.
    $admin = if ($SharePointUrl) { Get-CrAdminUrl $SharePointUrl }
    function Link($text, $url, $icon) { [pscustomobject]@{ Text = $text; Url = $url; Icon = $icon } }
    function Guide($url) { Link 'Microsoft''s guide' $url ([char]0xE8A5) }
    function AdminPage($page) { if ($admin) { Link 'Open the SharePoint admin center' "$admin/_layouts/15/online/AdminHome.aspx#/$page" ([char]0xE713) } }
    # How long we recommend each lasts, in days.
    $limits = @{ AnyoneLink = 30; CompanyLink = 90; Guest = 60 }
    $sharingGuide = 'https://learn.microsoft.com/sharepoint/turn-external-sharing-on-or-off'
    $sp = 'SharePoint admin center > Policies > Sharing'
    $noPage = 'No page for this one: an admin sets it with PowerShell'
    $spoGuide = 'https://learn.microsoft.com/powershell/module/microsoft.online.sharepoint.powershell/set-spotenant'

    # The commands to change a setting, ready to copy, for both ways of running them. An undo of nothing
    # leaves that part out, for a change that can't be taken back. Deliberately nothing stops the later lines
    # if signing in fails: the person reads what they copy and runs it themselves, and that's theirs to check.
    $adminAddress = if ($admin) { $admin } else { 'https://<tenant>-admin.sharepoint.com' }
    function Code($tool, $caption, $connect, $read, $change, $why, $undo, $help) {
        $lines = @($connect, '', '# See the current value first, so you can put it back', $read, '', "# $why", $change)
        # The undo is a note, not a command, so pasting the whole block makes the change and leaves it made.
        # Its value is from when the settings were last read, so it says to check that against the line above.
        if ($undo) { $lines += @('', '# To undo it, check this is the value you saw above, then run it without the # at the front:', "# $undo") }
        [pscustomobject]@{ Tool = $tool; Caption = $caption; Text = $lines -join "`r`n"; Help = $help }
    }
    function Commands($spoRead, $spoSet, $spoUndo, $pnpRead, $pnpSet, $pnpUndo, $why) {
        @(
            Code 'SPO' 'Run it in Windows PowerShell and sign in as a SharePoint Administrator. It changes the whole tenant. If it says a command or option isn''t found, your SharePoint Online module is too old: run Update-Module Microsoft.Online.SharePoint.PowerShell.' "Connect-SPOService -Url $adminAddress" $spoRead $spoSet $why $spoUndo
            Code 'PnP' 'Run it in PowerShell 7 and sign in as a SharePoint Administrator. First put the client ID of your own PnP app in place of <your-app-client-id>. No PnP app yet? Press Set up a PnP client ID. It changes the whole tenant.' "Connect-PnPOnline -Url $adminAddress -Interactive -ClientId <your-app-client-id>" $pnpRead $pnpSet $why $pnpUndo (Link 'Set up a PnP client ID' 'https://pnp.github.io/powershell/articles/registerapplication.html' ([char]0xE8A5))
        )
    }
    # One setting of the tenant: what to set it to, what puts it back, and why it's being changed.
    function SettingCommands($setting, $to, $back, $why) {
        Commands "Get-SPOTenant | Select-Object $setting" "Set-SPOTenant -$setting $to" "Set-SPOTenant -$setting $back" "(Get-PnPTenant).$setting" "Set-PnPTenant -$setting $to" "Set-PnPTenant -$setting $back" $why
    }
    $spots = @{
        ShareWith     = @{ Recommended = 'New and existing guests, who must sign in, or stricter'; Where = "$sp > External sharing: drag the SharePoint and OneDrive sliders"; Picture = 'sharing-external.png'
                           Links = @((Guide $sharingGuide), (AdminPage 'sharing')) }
        DefaultLink   = @{ Recommended = 'Specific people'; Where = "$sp > File and folder links: 'Choose the type of link that's selected by default'. OneDrive's own default is set with PowerShell."; Picture = 'sharing-links.png'
                           Links = @((Guide 'https://learn.microsoft.com/sharepoint/change-default-sharing-link'), (AdminPage 'sharing')) }
        DefaultRole   = @{ Recommended = 'View'; Where = "$sp > File and folder links: 'Choose the permission that's selected by default for sharing links'"; Picture = 'sharing-links.png'
                           Links = @((Guide 'https://learn.microsoft.com/sharepoint/change-default-sharing-link'), (AdminPage 'sharing')) }
        AnyoneExpiry  = @{ Recommended = "After $($limits.AnyoneLink) days or sooner"; Where = "$sp > File and folder links: 'These links must expire within this many days'. It only appears while Anyone is allowed."; Picture = 'sharing-links.png'
                           Links = @((Guide $sharingGuide), (AdminPage 'sharing')) }
        OrgLinkExpiry = @{ Recommended = "After $($limits.CompanyLink) days or sooner"; Where = $noPage; Picture = ''
                           Links = @((Guide $sharingGuide)) }
        GuestExpiry   = @{ Recommended = "After $($limits.Guest) days or sooner"; Where = "$sp > External sharing > More external sharing settings: 'Guest access to a site or OneDrive will expire automatically after this many days'"; Picture = 'sharing-more.png'
                           Links = @((Guide $sharingGuide), (AdminPage 'sharing')) }
        Reshare       = @{ Recommended = 'No'; Where = "$sp > External sharing > More external sharing settings: 'Allow guests to share items they don't own'"; Picture = 'sharing-more.png'
                           Links = @((Guide $sharingGuide), (AdminPage 'sharing')) }
        Domains       = @{ Recommended = 'Only the allowed domains, when you work with a fixed set of partners'; Where = "$sp > External sharing > More external sharing settings: 'Limit external sharing by domain'"; Picture = 'sharing-more.png'
                           Links = @((Guide 'https://learn.microsoft.com/sharepoint/restricted-domains-sharing'), (AdminPage 'sharing')) }
        Search        = @{ Recommended = 'Off, once oversharing is fixed'; Where = $noPage; Picture = ''
                           Links = @((Guide 'https://learn.microsoft.com/sharepoint/restricted-sharepoint-search')) }
        SiteAccess    = @{ Recommended = 'Available, so sensitive sites can be limited to a group'; Where = 'SharePoint admin center > Policies > Access control > Site-level access restriction (marked PRO: it needs SharePoint Advanced Management)'; Picture = 'access-control.png'
                           Links = @((Guide 'https://learn.microsoft.com/sharepoint/restricted-access-control'), (AdminPage 'accessControl')) }
        Everyone      = @{ Recommended = 'No'; Where = $noPage; Picture = ''
                           Links = @((Guide 'https://learn.microsoft.com/microsoft-365/copilot/microsoft-365-copilot-setup')) }
        Labels        = @{ Recommended = 'On'; Where = 'Microsoft Purview > Solutions > Information Protection > Sensitivity labels: press Turn on now if it is shown'; Picture = ''
                           Links = @((Guide 'https://learn.microsoft.com/purview/sensitivity-labels-sharepoint-onedrive-files'), (Link 'Open Microsoft Purview' 'https://purview.microsoft.com' ([char]0xE72E))) }
        DefaultLabel  = @{ Recommended = 'Allowed'; Where = $noPage; Picture = ''
                           Links = @((Guide 'https://learn.microsoft.com/purview/sensitivity-labels-sharepoint-default-label')) }
        OneDriveReshare = @{ Recommended = 'No, only the OneDrive''s owner can share'; Where = $noPage; Picture = ''
                           Links = @((Guide $spoGuide)) }
    }
    function With($row, $kind, $commands = @()) {
        $spot = $spots[$kind]
        # A setting that's already right has nothing to change, and a command could only make it worse.
        $row.Commands = @(if ($row.State -ne 'Good') { $commands | Where-Object { $_ } })
        $row.Links = @($spot.Links | Where-Object { $_ })
        $row.Where = if ($spot.Where -eq $noPage -and -not $row.Commands.Count) { "$noPage. It doesn't need changing now." } else { $spot.Where }
        $row.Recommended = $spot.Recommended
        $row.Picture = if ($spot.Picture) { Join-Path $PSScriptRoot "pictures\$($spot.Picture)" } else { '' }
        $row
    }
    function Days($n) { if ([int]$n -le 0) { 'Never' } elseif ([int]$n -eq 1) { 'After 1 day' } else { "After $n days" } }

    $outside = @{
        Disabled                        = 'Only people in your organization'
        ExistingExternalUserSharingOnly = 'Guests already in your directory'
        ExternalUserSharingOnly         = 'New and existing guests, who must sign in'
        ExternalUserAndGuestSharing     = 'Anyone, including "Anyone" links that need no sign-in'
    }
    $anyoneAllowed = "$($Values['SharingCapability'])" -eq 'ExternalUserAndGuestSharing' -or "$($Values['OneDriveSharingCapability'])" -eq 'ExternalUserAndGuestSharing'
    $guestsAllowed = "$($Values['SharingCapability'])" -ne 'Disabled' -or "$($Values['OneDriveSharingCapability'])" -ne 'Disabled'

    # The newer link settings win once someone has set them; until then the older ones apply.
    $scopeNames = @{ SpecificPeople = 'Specific people'; Organization = 'People in your organization'; Anyone = 'Anyone with the link' }
    $typeNames = @{ Direct = 'Specific people'; Internal = 'People in your organization'; AnonymousAccess = 'Anyone with the link'; None = 'Microsoft''s default' }
    $coreScope = "$($Values['CoreDefaultShareLinkScope'])"
    $defaultLink = if ($scopeNames.ContainsKey($coreScope)) { $scopeNames[$coreScope] } elseif (Has 'DefaultSharingLinkType') { $typeNames["$($Values['DefaultSharingLinkType'])"] }
    $odScope = "$($Values['OneDriveDefaultShareLinkScope'])"
    $coreRole = "$($Values['CoreDefaultShareLinkRole'])"
    $defaultRole = if ($coreRole -in 'Edit', 'View') { $coreRole } elseif (Has 'DefaultLinkPermission') { "$($Values['DefaultLinkPermission'])" }

    $whoShares = [System.Collections.Generic.List[object]]::new()
    $links = [System.Collections.Generic.List[object]]::new()
    $guests = [System.Collections.Generic.List[object]]::new()
    foreach ($s in @(@('SharingCapability', 'SharePoint sites can be shared with'), @('OneDriveSharingCapability', 'OneDrive can be shared with'))) {
        if (-not (Has $s[0])) { continue }
        $v = "$($Values[$s[0]])"
        $whoShares.Add((With $(if ($v -eq 'ExternalUserAndGuestSharing') { Row $s[1] $outside[$v] Watch '"Anyone" links work for whoever has them, with no sign-in. Allow only guests who sign in unless you really need them.' }
                elseif ($outside.ContainsKey($v)) { Row $s[1] $outside[$v] $(if ($v -in 'Disabled', 'ExistingExternalUserSharingOnly') { 'Good' } else { 'Info' }) }
                else { Row $s[1] $v Info }) ShareWith))
    }
    if ($defaultLink) {
        $links.Add((With $(if ($defaultLink -eq 'Specific people') { Row 'Link people get by default' $defaultLink Good }
                elseif ($defaultLink -eq 'Microsoft''s default') { Row 'Link people get by default' $defaultLink Watch 'Set the default link to Specific people, so a quick share doesn''t open a file to the whole company.' }
                else { Row 'Link people get by default' $defaultLink Watch 'Most people keep the default. Set it to Specific people, so a quick share doesn''t open a file to the whole company, and Copilot doesn''t show it to everyone.' }) DefaultLink))
    }
    if ($scopeNames.ContainsKey($odScope)) {
        $links.Add((With $(if ($odScope -eq 'SpecificPeople') { Row 'Link people get by default in OneDrive' $scopeNames[$odScope] Good } else { Row 'Link people get by default in OneDrive' $scopeNames[$odScope] Watch 'Set it to Specific people.' }) DefaultLink (SettingCommands 'OneDriveDefaultShareLinkScope' 'SpecificPeople' $odScope 'New links in OneDrive are for specific people by default')))
    }
    if ($defaultRole) {
        $links.Add((With $(if ($defaultRole -eq 'Edit') { Row 'Default link lets people' 'Edit' Watch 'View is the safer default; people can still choose Edit when they mean it.' }
                elseif ($defaultRole -eq 'None') { Row 'Default link lets people' 'Microsoft''s default' Info 'This tenant hasn''t chosen one. View is the safer default; people can still choose Edit when they mean it.' }
                else { Row 'Default link lets people' $defaultRole Good }) DefaultRole))
    }
    if (Has 'RequireAnonymousLinksExpireInDays') {
        $d = [int]$Values['RequireAnonymousLinksExpireInDays']
        $links.Add((With $(if ($d -gt $limits.AnyoneLink -and $anyoneAllowed) { Row '"Anyone" links expire' (Days $d) Watch "An `"Anyone`" link works for whoever it reaches until it expires. Make them expire sooner, for example after $($limits.AnyoneLink) days." }
                elseif ($d -gt 0) { Row '"Anyone" links expire' (Days $d) Good }
                elseif ($anyoneAllowed) { Row '"Anyone" links expire' 'Never' Watch "An `"Anyone`" link works forever for whoever it reaches. Make them expire, for example after $($limits.AnyoneLink) days." }
                else { Row '"Anyone" links expire' 'Never, but "Anyone" links are turned off' Info }) AnyoneExpiry))
    }
    foreach ($s in @(@('CoreOrganizationSharingLinkMaxExpirationInDays', 'Company-wide links expire'), @('OneDriveOrganizationSharingLinkMaxExpirationInDays', 'Company-wide links in OneDrive expire'))) {
        if (-not (Has $s[0])) { continue }
        $d = [int]$Values[$s[0]]
        $links.Add((With $(if ($d -gt $limits.CompanyLink) { Row $s[1] (Days $d) Watch "A company-wide link keeps working for everyone in the company long after it was needed. Lower the maximum, for example to $($limits.CompanyLink) days." } elseif ($d -gt 0) { Row $s[1] (Days $d) Good } else { Row $s[1] 'Never' Watch "A company-wide link keeps working for everyone in the company long after it was needed. Set a maximum, for example $($limits.CompanyLink) days." }) OrgLinkExpiry (SettingCommands $s[0] $limits.CompanyLink $d "Company-wide links expire after at most $($limits.CompanyLink) days")))
    }
    if ((Has 'ExternalUserExpirationRequired') -and $guestsAllowed) {
        $guests.Add((With $(if ($Values['ExternalUserExpirationRequired'] -eq $true -and [int]$Values['ExternalUserExpireInDays'] -gt $limits.Guest) { Row 'Guest access expires' (Days $Values['ExternalUserExpireInDays']) Watch "Guests keep their access for longer than they usually need it. Make it expire sooner, for example after $($limits.Guest) days; owners can extend it." }
                elseif ($Values['ExternalUserExpirationRequired'] -eq $true) { Row 'Guest access expires' (Days $Values['ExternalUserExpireInDays']) Good }
                else { Row 'Guest access expires' 'Never' Watch "Guests keep their access until someone removes it. Make it expire, for example after $($limits.Guest) days; owners can extend it." }) GuestExpiry))
    }
    if ((Has 'PreventExternalUsersFromResharing') -and $guestsAllowed) {
        $guests.Add((With $(if ($Values['PreventExternalUsersFromResharing'] -eq $true) { Row 'Guests can share what they were given' 'No' Good } else { Row 'Guests can share what they were given' 'Yes' Watch 'Stop guests sharing your files with other people.' }) Reshare))
    }
    if (Has 'ODBMembersCanShare') {
        # On: anyone with edit permission can reshare. Off: only the owner can share. Unspecified: each owner decides.
        $membersShare = "$($Values['ODBMembersCanShare'])"
        $reshareWhy = 'Someone given edit access to a OneDrive file or folder can share it on with other people, so it can spread further than its owner meant. Turn it off so only the OneDrive''s owner can share. This affects every OneDrive in the tenant.'
        $row = switch ($membersShare) {
            'Off' { Row 'People with edit access can reshare in OneDrive' 'No, only the OneDrive''s owner can share' Good }
            'On' { Row 'People with edit access can reshare in OneDrive' 'Yes' Watch $reshareWhy }
            default { Row 'People with edit access can reshare in OneDrive' 'Each OneDrive''s owner decides' Watch $reshareWhy }
        }
        $whoShares.Add((With $row OneDriveReshare (SettingCommands 'ODBMembersCanShare' 'Off' $membersShare 'Only the OneDrive''s owner can share')))
    }
    if ((Has 'SharingDomainRestrictionMode') -and $guestsAllowed) {
        $whoShares.Add((With (Row 'Sharing limited to certain domains' $(switch ("$($Values['SharingDomainRestrictionMode'])") { 'AllowList' { 'Yes, only the allowed domains' } 'BlockList' { 'All but the blocked domains' } default { 'No' } }) $(if ("$($Values['SharingDomainRestrictionMode'])" -eq 'AllowList') { 'Good' } else { 'Info' })) Domains))
    }

    $copilot = [System.Collections.Generic.List[object]]::new()
    if (Has 'RestrictedSearchMode') {
        # Only worth a command while it's on. Microsoft stopped new turn-ons on July 31, 2026, so turning it off has no undo.
        $searchOff = if ("$($Values['RestrictedSearchMode'])" -eq 'Enabled') { Commands 'Get-SPOTenantRestrictedSearchMode' 'Set-SPOTenantRestrictedSearchMode -Mode Disabled' $null 'Get-PnPTenantRestrictedSearchMode' 'Set-PnPTenantRestrictedSearchMode -Mode Disabled' $null 'Turn it off. Microsoft stopped new turn-ons on July 31, 2026, so you may not be able to turn it back on' }
        $copilot.Add((With $(if ("$($Values['RestrictedSearchMode'])" -eq 'Enabled') { Row 'Restricted SharePoint Search' 'On' Info 'Copilot and search only reach the sites on your allowed list, plus what people use or are shared directly. Turn it off once oversharing is fixed. Microsoft is retiring this setting; Restricted Content Discovery takes its place.' }
                else { Row 'Restricted SharePoint Search' 'Off' Info 'Copilot can use every site a person can open. That''s right once oversharing is fixed. Microsoft is retiring this setting; to hold sites back from Copilot in the meantime, use Restricted Content Discovery instead.' }) Search $searchOff))
    }
    if (Has 'EnableRestrictedAccessControl') {
        $copilot.Add((With (Row 'Restricted site access' $(if ($Values['EnableRestrictedAccessControl'] -eq $true) { 'Available' } else { 'Off' }) Info 'Lets you limit a site to the members of a chosen group, whatever it has been shared with.') SiteAccess))
    }
    foreach ($s in @(@('ShowEveryoneExceptExternalUsersClaim', '"Everyone except external users" can be picked when sharing'), @('ShowEveryoneClaim', '"Everyone" can be picked when sharing'))) {
        if (-not (Has $s[0])) { continue }
        $copilot.Add((With $(if ($Values[$s[0]] -eq $true) { Row $s[1] 'Yes' Watch 'One click shares with the whole company, which Copilot then shows to everyone. Hide it from the people picker.' } else { Row $s[1] 'No' Good }) Everyone (SettingCommands $s[0] '$false' '$true' 'Hide it from the people picker')))
    }
    if (Has 'EnableAIPIntegration') {
        $copilot.Add((With $(if ($Values['EnableAIPIntegration'] -eq $true) { Row 'Sensitivity labels for files in SharePoint and OneDrive' 'On' Good }
                else { Row 'Sensitivity labels for files in SharePoint and OneDrive' 'Off' Watch 'Turn it on so SharePoint, search and Copilot can work with labeled files.' }) Labels))
    }
    if (Has 'DisableDocumentLibraryDefaultLabeling') {
        $copilot.Add((With $(if ($Values['DisableDocumentLibraryDefaultLabeling'] -eq $true) { Row 'Default labels for libraries' 'Turned off' Watch 'Allow default labels, so new files in a library get its label automatically.' } else { Row 'Default labels for libraries' 'Allowed' Good }) DefaultLabel (SettingCommands 'DisableDocumentLibraryDefaultLabeling' '$false' '$true' 'Allow default labels on libraries')))
    }

    @(
        [pscustomobject]@{ Name = 'Who can share'; Rows = $whoShares.ToArray() }
        [pscustomobject]@{ Name = 'Links'; Rows = $links.ToArray() }
        [pscustomobject]@{ Name = 'Guests'; Rows = $guests.ToArray() }
        [pscustomobject]@{ Name = 'Copilot and search'; Rows = $copilot.ToArray() }
    )
}
