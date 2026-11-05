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
    $connection = Connect-PnPOnline -Url $admin -ClientId $Settings.app.clientId -Tenant $Settings.tenant -Thumbprint $Settings.app.thumbprint -ReturnConnection -ErrorAction Stop
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

function Get-CrTenantSettingsView {
    <#
      Turns the raw settings into what the Tenant tab shows: groups of rows, each with the
      setting's plain name, its value in words, a State (Good, Watch or Info) and, when it
      could be better, what to change. Each row also carries Links: Microsoft's guide to the
      setting and, when there is one, the admin center page where it is changed (SharePointUrl
      gives the tenant; without it only the guides are linked), Where: the trail to follow to
      reach the setting, in words, Picture: a screenshot of that screen, when there is one, and
      Recommended: the value we suggest, in the same words as Value. Each link has an Icon: a
      Windows icon-font character for its button. Settings this tenant doesn't have are left out.
    #>
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Values, [string] $SharePointUrl)
    function Has($name) { $Values.Contains($name) -and $null -ne $Values[$name] -and "$($Values[$name])" -ne '' }
    function Row($name, $value, $state, $advice = '') { [pscustomobject]@{ Name = $name; Value = $value; State = $state; Advice = $advice; Recommended = ''; Where = ''; Picture = ''; Links = @() } }

    # Where each setting is explained and changed. Admin center pages need the tenant; the rest are the same for everyone.
    # Where is the trail to follow, as the admin center words it (checked against a real tenant in October 2026), and
    # Picture a screenshot of that screen, in the pictures folder next to this file.
    $admin = if ($SharePointUrl) { Get-CrAdminUrl $SharePointUrl }
    function Link($text, $url, $icon) { [pscustomobject]@{ Text = $text; Url = $url; Icon = $icon } }
    function Guide($url) { Link 'Microsoft''s guide' $url ([char]0xE8A5) }
    function AdminPage($page) { if ($admin) { Link 'Open the SharePoint admin center' "$admin/_layouts/15/online/AdminHome.aspx#/$page" ([char]0xE713) } }
    function PowerShellRef($cmdlet) { Link 'The PowerShell command' "https://learn.microsoft.com/powershell/module/microsoft.online.sharepoint.powershell/$cmdlet" ([char]0xE756) }
    $sharingGuide = 'https://learn.microsoft.com/sharepoint/turn-external-sharing-on-or-off'
    $sp = 'SharePoint admin center > Policies > Sharing'
    $noPage = 'No page for this one: an admin runs the PowerShell command in the guide'
    $spots = @{
        ShareWith     = @{ Recommended = 'New and existing guests, who must sign in, or stricter'; Where = "$sp > External sharing: drag the SharePoint and OneDrive sliders"; Picture = 'sharing-external.png'
                           Links = @((Guide $sharingGuide), (AdminPage 'sharing')) }
        DefaultLink   = @{ Recommended = 'Specific people'; Where = "$sp > File and folder links: 'Choose the type of link that's selected by default'. OneDrive's own default is set with PowerShell."; Picture = 'sharing-links.png'
                           Links = @((Guide 'https://learn.microsoft.com/sharepoint/change-default-sharing-link'), (AdminPage 'sharing')) }
        DefaultRole   = @{ Recommended = 'View'; Where = "$sp > File and folder links: 'Choose the permission that's selected by default for sharing links'"; Picture = 'sharing-links.png'
                           Links = @((Guide 'https://learn.microsoft.com/sharepoint/change-default-sharing-link'), (AdminPage 'sharing')) }
        AnyoneExpiry  = @{ Recommended = 'After 30 days or sooner'; Where = "$sp > File and folder links: 'These links must expire within this many days'. It only appears while Anyone is allowed."; Picture = 'sharing-links.png'
                           Links = @((Guide $sharingGuide), (AdminPage 'sharing')) }
        OrgLinkExpiry = @{ Recommended = 'After 90 days or sooner'; Where = $noPage; Picture = ''
                           Links = @((Guide $sharingGuide), (PowerShellRef 'set-spotenant')) }
        GuestExpiry   = @{ Recommended = 'After 60 days or sooner'; Where = "$sp > External sharing > More external sharing settings: 'Guest access to a site or OneDrive will expire automatically after this many days'"; Picture = 'sharing-more.png'
                           Links = @((Guide $sharingGuide), (AdminPage 'sharing')) }
        Reshare       = @{ Recommended = 'No'; Where = "$sp > External sharing > More external sharing settings: 'Allow guests to share items they don't own'"; Picture = 'sharing-more.png'
                           Links = @((Guide $sharingGuide), (AdminPage 'sharing')) }
        Domains       = @{ Recommended = 'Only the allowed domains, when you work with a fixed set of partners'; Where = "$sp > External sharing > More external sharing settings: 'Limit external sharing by domain'"; Picture = 'sharing-more.png'
                           Links = @((Guide 'https://learn.microsoft.com/sharepoint/restricted-domains-sharing'), (AdminPage 'sharing')) }
        Search        = @{ Recommended = 'Off, once oversharing is fixed'; Where = $noPage; Picture = ''
                           Links = @((Guide 'https://learn.microsoft.com/sharepoint/restricted-sharepoint-search'), (PowerShellRef 'set-spotenantrestrictedsearchmode')) }
        SiteAccess    = @{ Recommended = 'Available, so sensitive sites can be limited to a group'; Where = 'SharePoint admin center > Policies > Access control > Site-level access restriction (marked PRO: it needs SharePoint Advanced Management)'; Picture = 'access-control.png'
                           Links = @((Guide 'https://learn.microsoft.com/sharepoint/restricted-access-control'), (AdminPage 'accessControl')) }
        Everyone      = @{ Recommended = 'No'; Where = $noPage; Picture = ''
                           Links = @((Guide 'https://learn.microsoft.com/microsoft-365/copilot/microsoft-365-copilot-setup'), (PowerShellRef 'set-spotenant')) }
        Labels        = @{ Recommended = 'On'; Where = 'Microsoft Purview > Solutions > Information Protection > Sensitivity labels: press Turn on now if it is shown'; Picture = ''
                           Links = @((Guide 'https://learn.microsoft.com/purview/sensitivity-labels-sharepoint-onedrive-files'), (Link 'Open Microsoft Purview' 'https://purview.microsoft.com' ([char]0xE72E))) }
        DefaultLabel  = @{ Recommended = 'Allowed'; Where = $noPage; Picture = ''
                           Links = @((Guide 'https://learn.microsoft.com/purview/sensitivity-labels-sharepoint-default-label'), (PowerShellRef 'set-spotenant')) }
    }
    function With($row, $kind) {
        $spot = $spots[$kind]
        $row.Links = @($spot.Links | Where-Object { $_ })
        $row.Where = $spot.Where
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

    $sharing = [System.Collections.Generic.List[object]]::new()
    foreach ($s in @(@('SharingCapability', 'SharePoint sites can be shared with'), @('OneDriveSharingCapability', 'OneDrive can be shared with'))) {
        if (-not (Has $s[0])) { continue }
        $v = "$($Values[$s[0]])"
        $sharing.Add((With $(if ($v -eq 'ExternalUserAndGuestSharing') { Row $s[1] $outside[$v] Watch '"Anyone" links work for whoever has them, with no sign-in. Allow only guests who sign in unless you really need them.' }
                elseif ($outside.ContainsKey($v)) { Row $s[1] $outside[$v] $(if ($v -in 'Disabled', 'ExistingExternalUserSharingOnly') { 'Good' } else { 'Info' }) }
                else { Row $s[1] $v Info }) ShareWith))
    }
    if ($defaultLink) {
        $sharing.Add((With $(if ($defaultLink -eq 'Specific people') { Row 'Link people get by default' $defaultLink Good }
                elseif ($defaultLink -eq 'Microsoft''s default') { Row 'Link people get by default' $defaultLink Watch 'Set the default link to Specific people, so a quick share doesn''t open a file to the whole company.' }
                else { Row 'Link people get by default' $defaultLink Watch 'Most people keep the default. Set it to Specific people, so a quick share doesn''t open a file to the whole company, and Copilot doesn''t show it to everyone.' }) DefaultLink))
    }
    if ($scopeNames.ContainsKey($odScope)) {
        $sharing.Add((With $(if ($odScope -eq 'SpecificPeople') { Row 'Link people get by default in OneDrive' $scopeNames[$odScope] Good } else { Row 'Link people get by default in OneDrive' $scopeNames[$odScope] Watch 'Set it to Specific people.' }) DefaultLink))
    }
    if ($defaultRole) {
        $sharing.Add((With $(if ($defaultRole -eq 'Edit') { Row 'Default link lets people' 'Edit' Watch 'View is the safer default; people can still choose Edit when they mean it.' } else { Row 'Default link lets people' $defaultRole Good }) DefaultRole))
    }
    if (Has 'RequireAnonymousLinksExpireInDays') {
        $d = [int]$Values['RequireAnonymousLinksExpireInDays']
        $sharing.Add((With $(if ($d -gt 0) { Row '"Anyone" links expire' (Days $d) Good }
                elseif ($anyoneAllowed) { Row '"Anyone" links expire' 'Never' Watch 'An "Anyone" link works forever for whoever it reaches. Make them expire, for example after 30 days.' }
                else { Row '"Anyone" links expire' 'Never, but "Anyone" links are turned off' Info }) AnyoneExpiry))
    }
    foreach ($s in @(@('CoreOrganizationSharingLinkMaxExpirationInDays', 'Company-wide links expire'), @('OneDriveOrganizationSharingLinkMaxExpirationInDays', 'Company-wide links in OneDrive expire'))) {
        if (-not (Has $s[0])) { continue }
        $d = [int]$Values[$s[0]]
        $sharing.Add((With $(if ($d -gt 0) { Row $s[1] (Days $d) Good } else { Row $s[1] 'Never' Watch 'A company-wide link keeps working for everyone in the company long after it was needed. Set a maximum, for example 90 days.' }) OrgLinkExpiry))
    }
    if ((Has 'ExternalUserExpirationRequired') -and $guestsAllowed) {
        $sharing.Add((With $(if ($Values['ExternalUserExpirationRequired'] -eq $true) { Row 'Guest access expires' (Days $Values['ExternalUserExpireInDays']) Good }
                else { Row 'Guest access expires' 'Never' Watch 'Guests keep their access until someone removes it. Make it expire, for example after 60 days; owners can extend it.' }) GuestExpiry))
    }
    if ((Has 'PreventExternalUsersFromResharing') -and $guestsAllowed) {
        $sharing.Add((With $(if ($Values['PreventExternalUsersFromResharing'] -eq $true) { Row 'Guests can share what they were given' 'No' Good } else { Row 'Guests can share what they were given' 'Yes' Watch 'Stop guests sharing your files with other people.' }) Reshare))
    }
    if ((Has 'SharingDomainRestrictionMode') -and $guestsAllowed) {
        $sharing.Add((With (Row 'Sharing limited to certain domains' $(switch ("$($Values['SharingDomainRestrictionMode'])") { 'AllowList' { 'Yes, only the allowed domains' } 'BlockList' { 'All but the blocked domains' } default { 'No' } }) $(if ("$($Values['SharingDomainRestrictionMode'])" -eq 'AllowList') { 'Good' } else { 'Info' })) Domains))
    }

    $copilot = [System.Collections.Generic.List[object]]::new()
    if (Has 'RestrictedSearchMode') {
        $copilot.Add((With $(if ("$($Values['RestrictedSearchMode'])" -eq 'Enabled') { Row 'Restricted SharePoint Search' 'On' Info 'Copilot and search only reach the sites on your allowed list, plus what people use or are shared directly. Turn it off once oversharing is fixed. Microsoft is retiring this setting; Restricted Content Discovery takes its place.' }
                else { Row 'Restricted SharePoint Search' 'Off' Info 'Copilot can use every site a person can open. That''s right once oversharing is fixed. Microsoft is retiring this setting; to hold sites back from Copilot in the meantime, use Restricted Content Discovery instead.' }) Search))
    }
    if (Has 'EnableRestrictedAccessControl') {
        $copilot.Add((With (Row 'Restricted site access' $(if ($Values['EnableRestrictedAccessControl'] -eq $true) { 'Available' } else { 'Off' }) Info 'Lets you limit a site to the members of a chosen group, whatever it has been shared with.') SiteAccess))
    }
    foreach ($s in @(@('ShowEveryoneExceptExternalUsersClaim', '"Everyone except external users" can be picked when sharing'), @('ShowEveryoneClaim', '"Everyone" can be picked when sharing'))) {
        if (-not (Has $s[0])) { continue }
        $copilot.Add((With $(if ($Values[$s[0]] -eq $true) { Row $s[1] 'Yes' Watch 'One click shares with the whole company, which Copilot then shows to everyone. Hide it from the people picker.' } else { Row $s[1] 'No' Good }) Everyone))
    }
    if (Has 'EnableAIPIntegration') {
        $copilot.Add((With $(if ($Values['EnableAIPIntegration'] -eq $true) { Row 'Sensitivity labels for files in SharePoint and OneDrive' 'On' Good }
                else { Row 'Sensitivity labels for files in SharePoint and OneDrive' 'Off' Watch 'Turn it on so SharePoint, search and Copilot can work with labeled files.' }) Labels))
    }
    if (Has 'DisableDocumentLibraryDefaultLabeling') {
        $copilot.Add((With $(if ($Values['DisableDocumentLibraryDefaultLabeling'] -eq $true) { Row 'Default labels for libraries' 'Turned off' Watch 'Allow default labels, so new files in a library get its label automatically.' } else { Row 'Default labels for libraries' 'Allowed' Good }) DefaultLabel))
    }

    @(
        [pscustomobject]@{ Name = 'Sharing'; Rows = $sharing.ToArray() }
        [pscustomobject]@{ Name = 'Copilot and search'; Rows = $copilot.ToArray() }
    )
}
