<#
.SYNOPSIS
  Runs a whole Deep scan against a pretend tenant, with no network: listing sites,
  site and library checks, paging, a site that refuses access, stopping and carrying
  on, and the report. Exits 1 if anything is off.

.EXAMPLE
  pwsh -File pnp/tests/Test-ScanOffline.ps1
#>
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\CopilotReadiness\CopilotReadiness.psm1') -Force
$module = Get-Module CopilotReadiness

$work = Join-Path ([IO.Path]::GetTempPath()) "cr-offline-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
New-Item -ItemType Directory -Path $work | Out-Null

# ── The pretend tenant: URL pattern -> JSON answer, or an HTTP status to fail with ──
$sp = 'https://contoso.sharepoint.com'
$a = "$sp/sites/finance"
$b = "$sp/sites/archive"
$c = "$sp/sites/locked"
$d = 'https://contoso-my.sharepoint.com/personal/dana'
$e = "$sp/sites/old"
$f = "$sp/sites/appcatalog"
$guest = 'i:0#.f|membership|ann_fabrikam.com#ext#@contoso.onmicrosoft.com'
$raj = 'i:0#.f|membership|raj_tailspin.com#ext#@contoso.onmicrosoft.com'

$routes = [ordered]@{
    'graph.microsoft.com/v1.0/sites/getAllSites'                = @{ value = @(
            @{ id = 'contoso.sharepoint.com,a,1'; webUrl = $a; displayName = 'Finance'; isPersonalSite = $false },
            @{ id = 'contoso.sharepoint.com,b,2'; webUrl = "$b/"; displayName = 'Archive'; isPersonalSite = $false },
            @{ id = 'contoso.sharepoint.com,c,3'; webUrl = $c; displayName = 'Locked'; isPersonalSite = $false },
            @{ id = 'contoso.sharepoint.com,e,5'; webUrl = $e; displayName = 'Old'; isPersonalSite = $false },
            @{ id = 'contoso-my.sharepoint.com,d,4'; webUrl = $d; displayName = 'Dana'; isPersonalSite = $true }
        )
    }
    'groups/g1/owners'                                          = @{ value = @(@{ id = 'o1'; accountEnabled = $true }, @{ id = 'o2'; accountEnabled = $false }) }
    'groups/g1/members'                                         = @{ value = @(@{ id = 'u1'; displayName = 'Ann'; userPrincipalName = 'ann_fabrikam.com#EXT#@contoso.onmicrosoft.com' }) }
    'groups/g1?'                                                = @{ id = 'g1'; visibility = 'Public'; assignedLabels = @() }
    'sensitivityLabels'                                         = @{ value = @() }

    # Finance: group-connected, public, Everyone hidden in Visitors, a guest, one library over two pages
    "$a/_api/site?`$select=Id,GroupId"                          = @{ Id = 's1'; GroupId = 'g1' }
    "$a/_api/web?"                                              = @{ Title = 'Finance'; LastItemUserModifiedDate = '2026-09-30T10:11:00Z'; RoleAssignments = @(
            @{ Member = @{ Id = 3; LoginName = 'Finance Owners'; Title = 'Finance Owners'; PrincipalType = 8 }; RoleDefinitionBindings = @(@{ Name = 'Full Control'; RoleTypeKind = 5 }) },
            @{ Member = @{ Id = 7; LoginName = 'Finance Visitors'; Title = 'Finance Visitors'; PrincipalType = 8 }; RoleDefinitionBindings = @(@{ Name = 'Read'; RoleTypeKind = 2 }) }
        )
    }
    "$a/_api/web/AssociatedOwnerGroup"                          = @{ Id = 3 }
    "$a/_api/web/sitegroups/getbyid(3)/users"                   = @{ value = @(@{ Id = 1; LoginName = 'i:0#.f|membership|dana@contoso.com'; Title = 'Dana'; PrincipalType = 1 }) }
    "$a/_api/web/sitegroups/getbyid(7)/users"                   = @{ value = @(@{ Id = 9; LoginName = 'c:0-.f|rolemanager|spo-grid-all-users/x'; Title = 'Everyone except external users'; PrincipalType = 4 }) }
    "$a/_api/web/sitegroups/getbyid(50)/users"                  = @{ value = @(@{ Id = 11; LoginName = $guest; Title = 'Ann'; PrincipalType = 1 }) }
    "$a/_api/web/lists?"                                        = @{ value = @(
            @{ Id = 'L1'; Title = 'Documents'; ItemCount = 4; BaseType = 1; HasUniqueRoleAssignments = $false; IsSiteAssetsLibrary = $false; IsSystemList = $false; RootFolder = @{ ServerRelativeUrl = '/sites/finance/Shared Documents' } },
            @{ Id = 'L2'; Title = 'Site Assets'; ItemCount = 9; BaseType = 1; HasUniqueRoleAssignments = $true; IsSiteAssetsLibrary = $true; IsSystemList = $true; RootFolder = @{ ServerRelativeUrl = '/sites/finance/SiteAssets' } },
            @{ Id = 'L3'; Title = 'Requests'; ItemCount = 2; BaseType = 0; HasUniqueRoleAssignments = $true; IsSiteAssetsLibrary = $false; IsSystemList = $false; RootFolder = @{ ServerRelativeUrl = '/sites/finance/Lists/Requests' } },
            @{ Id = 'L4'; Title = 'Site Pages'; ItemCount = 3; BaseType = 1; HasUniqueRoleAssignments = $false; IsSiteAssetsLibrary = $false; IsSystemList = $true; RootFolder = @{ ServerRelativeUrl = '/sites/finance/SitePages' } }
        )
    }
    "$a/_api/web/lists(guid'L1')/items?page=2"                  = @{ value = @(@{ Id = 4; FileRef = '/sites/finance/Shared Documents/d.docx'; FSObjType = 0; HasUniqueRoleAssignments = $false; OData__IpLabelId = $null }) }
    "$a/_api/web/lists(guid'L1')/items?"                        = @{ value = @(
            @{ Id = 1; FileRef = '/sites/finance/Shared Documents/a.docx'; FSObjType = 0; HasUniqueRoleAssignments = $true; OData__IpLabelId = '' },
            @{ Id = 2; FileRef = '/sites/finance/Shared Documents/b.docx'; FSObjType = 0; HasUniqueRoleAssignments = $false; OData__IpLabelId = 'lbl-1' },
            @{ Id = 3; FileRef = '/sites/finance/Shared Documents/Payroll'; FSObjType = 1; HasUniqueRoleAssignments = $true }
        ); 'odata.nextLink' = "$a/_api/web/lists(guid'L1')/items?page=2"
    }
    "$a/_api/web/lists(guid'L1')/items(1)/RoleAssignments"      = @{ value = @(@{ Member = @{ Id = 40; LoginName = 'SharingLinks.x.AnonymousEdit.y'; Title = 'SharingLinks.x.AnonymousEdit.y'; PrincipalType = 8 }; RoleDefinitionBindings = @(@{ Name = 'Edit'; RoleTypeKind = 6 }) }) }
    "$a/_api/web/lists(guid'L1')/items(3)/RoleAssignments"      = @{ value = @(@{ Member = @{ Id = 50; LoginName = 'SharingLinks.x.Flexible.y'; Title = 'SharingLinks.x.Flexible.y'; PrincipalType = 8 }; RoleDefinitionBindings = @(@{ Name = 'Read'; RoleTypeKind = 2 }) }) }

    # Finance: a list shared with everyone, with one item shared with a guest
    "$a/_api/web/lists(guid'L3')/RoleAssignments"               = @{ value = @(@{ Member = @{ Id = 9; LoginName = 'c:0-.f|rolemanager|spo-grid-all-users/x'; Title = 'Everyone except external users'; PrincipalType = 4 }; RoleDefinitionBindings = @(@{ Name = 'Read'; RoleTypeKind = 2 }) }) }
    "$a/_api/web/lists(guid'L3')/items?"                        = @{ value = @(
            @{ Id = 7; FileRef = '/sites/finance/Lists/Requests/7_.000'; FSObjType = 0; HasUniqueRoleAssignments = $true },
            @{ Id = 8; FileRef = '/sites/finance/Lists/Requests/8_.000'; FSObjType = 0; HasUniqueRoleAssignments = $false }
        )
    }
    "$a/_api/web/lists(guid'L3')/items(7)/RoleAssignments"      = @{ value = @(@{ Member = @{ Id = 60; LoginName = $raj; Title = 'Raj'; PrincipalType = 1 }; RoleDefinitionBindings = @(@{ Name = 'Contribute'; RoleTypeKind = 3 }) }) }

    # Finance: a Board subsite with its own permissions, open to Everyone; its own Owners group is fine
    "$a/_api/web/webs"                                          = @{ value = @(@{ Title = 'Board'; Url = "$a/board"; ServerRelativeUrl = '/sites/finance/board'; HasUniqueRoleAssignments = $true }) }
    "$a/board/_api/web/webs"                                    = @{ value = @() }
    "$a/board/_api/web/RoleAssignments"                         = @{ value = @(
            @{ Member = @{ Id = 1; LoginName = 'c:0(.s|true'; Title = 'Everyone'; PrincipalType = 4 }; RoleDefinitionBindings = @(@{ Name = 'Read'; RoleTypeKind = 2 }) },
            @{ Member = @{ Id = 12; LoginName = 'Board Owners'; Title = 'Board Owners'; PrincipalType = 8 }; RoleDefinitionBindings = @(@{ Name = 'Full Control'; RoleTypeKind = 5 }) }
        )
    }
    "$a/board/_api/web/AssociatedOwnerGroup"                    = @{ Id = 12 }
    "$a/_api/web/sitegroups/getbyid(12)/users"                  = @{ value = @(@{ Id = 1; LoginName = 'i:0#.f|membership|dana@contoso.com'; Title = 'Dana'; PrincipalType = 1 }) }
    "$a/board/_api/web/lists?"                                  = @{ value = @() }

    # Dana's OneDrive: one file shared with an "Anyone" link
    "$d/_api/web?"                                              = @{ Title = 'Dana'; LastItemUserModifiedDate = '2026-09-01T08:00:00Z'; RoleAssignments = @(
            @{ Member = @{ Id = 5; LoginName = 'i:0#.f|membership|dana@contoso.com'; Title = 'Dana'; PrincipalType = 1 }; RoleDefinitionBindings = @(@{ Name = 'Full Control'; RoleTypeKind = 5 }) }
        )
    }
    "$d/_api/web/lists?"                                        = @{ value = @(
            @{ Id = 'L9'; Title = 'Documents'; ItemCount = 2; BaseType = 1; HasUniqueRoleAssignments = $true; IsSiteAssetsLibrary = $false; IsSystemList = $false; RootFolder = @{ ServerRelativeUrl = '/personal/dana/Documents' } },
            @{ Id = 'L10'; Title = 'Social'; ItemCount = 8; BaseType = 0; HasUniqueRoleAssignments = $true; IsSiteAssetsLibrary = $false; IsSystemList = $true; RootFolder = @{ ServerRelativeUrl = '/personal/dana/Social' } }
        )
    }
    "$d/_api/web/lists(guid'L9')/RoleAssignments"               = @{ value = @(@{ Member = @{ Id = 5; LoginName = 'i:0#.f|membership|dana@contoso.com'; Title = 'Dana'; PrincipalType = 1 }; RoleDefinitionBindings = @(@{ Name = 'Full Control'; RoleTypeKind = 5 }) }) }
    "$d/_api/web/lists(guid'L9')/items?"                        = @{ value = @(
            @{ Id = 1; FileRef = '/personal/dana/Documents/plan.xlsx'; FSObjType = 0; HasUniqueRoleAssignments = $true; OData__IpLabelId = '' },
            @{ Id = 2; FileRef = '/personal/dana/Documents/notes.docx'; FSObjType = 0; HasUniqueRoleAssignments = $false; OData__IpLabelId = '' }
        )
    }
    "$d/_api/web/lists(guid'L9')/items(1)/RoleAssignments"      = @{ value = @(@{ Member = @{ Id = 70; LoginName = 'SharingLinks.p.AnonymousView.q'; Title = 'SharingLinks.p.AnonymousView.q'; PrincipalType = 8 }; RoleDefinitionBindings = @(@{ Name = 'Read'; RoleTypeKind = 2 }) }) }

    # Archive: classic site, no label property under the first name, one admin, nothing changed for a year
    "$b/_api/site?`$select=Id,GroupId"                          = @{ Id = 's2'; GroupId = '00000000-0000-0000-0000-000000000000' }
    "$b/_api/site?`$select=SensitivityLabelId"                  = 400
    "$b/_api/site?`$select=SensitivityLabel"                    = @{ SensitivityLabel = '' }
    "$b/_api/web?"                                              = @{ Title = 'Archive'; LastItemUserModifiedDate = '2025-06-01T00:00:00Z'; RoleAssignments = @() }
    "$b/_api/web/AssociatedOwnerGroup"                          = 404
    "$b/_api/web/siteusers"                                     = @{ value = @(@{ LoginName = 'i:0#.f|membership|lee@contoso.com'; Title = 'Lee'; PrincipalType = 1 }, @{ LoginName = 'c:0t.c|tenant|x'; Title = 'SharePoint Administrator'; PrincipalType = 4 }) }
    "$b/_api/web/lists?"                                        = @{ value = @() }
    "$b/_api/web/webs"                                          = @{ value = @() }

    # Locked: access denied, and Graph says so too, so it is a failure to retry
    "$c/_api/site"                                              = 403
    "$c/_api/web?"                                              = 403
    'v1.0/sites/contoso.sharepoint.com,c,3?'                    = 403

    # Old: archived; SharePoint refuses and Graph says the site is locked
    "$e/_api/site"                                              = 403
    "$e/_api/web?"                                              = 403
    "$f/_api/web?"                                              = @{ WebTemplate = 'APPCATALOG' }
    'v1.0/sites/contoso.sharepoint.com,e,5?'                    = 423
}

$script:calls = [System.Collections.Generic.List[string]]::new()
& $module {
    param($routes, $calls)
    $script:FakeRoutes = $routes
    $script:FakeCalls = $calls
    $script:FakeOnCall = $null
    function script:Invoke-CrGet {
        param([string] $Url, [switch] $AdvancedQuery)
        $script:FakeCalls.Add($Url)
        if ($script:FakeOnCall) { & $script:FakeOnCall $Url }
        foreach ($key in $script:FakeRoutes.Keys) {
            if ($Url.Contains($key)) {
                $answer = $script:FakeRoutes[$key]
                if ($answer -is [int]) {
                    $ex = [System.Net.Http.HttpRequestException]::new("HTTP $answer from $($Url.Split('?')[0]): pretend")
                    $ex.Data['Status'] = $answer
                    throw $ex
                }
                return ($answer | ConvertTo-Json -Depth 20 | ConvertFrom-Json -DateKind String)
            }
        }
        throw "The pretend tenant has no answer for $Url"
    }
} $routes $script:calls

$problems = [System.Collections.Generic.List[string]]::new()
function Check([string] $what, [bool] $ok) { if (-not $ok) { $problems.Add($what) } }

try {
    # The module's files share one namespace: a function defined twice silently replaces the first.
    $defs = Get-ChildItem (Join-Path $PSScriptRoot '..\CopilotReadiness\*.ps1') | ForEach-Object {
        [regex]::Matches((Get-Content $_.FullName -Raw), '(?m)^function ([\w-]+)') | ForEach-Object { $_.Groups[1].Value }
    }
    $twice = @($defs | Group-Object | Where-Object Count -GT 1 | ForEach-Object Name)
    Check "no function is defined twice ($($twice -join ', '))" ($twice.Count -eq 0)

    # settings.json: a missing file gives every field; a partial one keeps what it has; a new tenant forgets the old app.
    $settingsFile = Join-Path $work 'settings.json'
    $s = Read-CrSettings $settingsFile
    Check 'new settings have every field' ($s.app.name -and $s.scan.level -eq 'Quick' -and $s.scan.staleDays -eq 180 -and $s.scan.resultsFolder -eq 'results')
    Set-CrTenant $s 'contoso'
    Check 'tenant name is completed' ($s.tenant -eq 'contoso.onmicrosoft.com' -and $s.sharePointUrl -eq 'https://contoso.sharepoint.com')
    $s.app.clientId = 'abc'; $s.app.thumbprint = 'DEF'; $s.scan.level = 'Deep'
    Save-CrSettings $settingsFile $s
    '{ "tenant": "contoso.onmicrosoft.com", "app": { "clientId": "abc", "thumbprint": "DEF" }, "scan": { "sites": ["https://contoso.sharepoint.com/sites/finance/"] } }' |
        Set-Content $settingsFile
    $s = Read-CrSettings $settingsFile
    Check 'a hand-written file is filled in' ($s.app.clientId -eq 'abc' -and $s.app.name -and $s.scan.level -eq 'Quick' -and @($s.scan.sites).Count -eq 1)
    Set-CrTenant $s 'fabrikam.onmicrosoft.com'
    Check 'a different tenant starts with no app' (-not $s.app.clientId -and $s.sharePointUrl -eq 'https://fabrikam.sharepoint.com')
    Check 'the old tenant is remembered' (@($s.otherTenants).Count -eq 1 -and $s.otherTenants[0].clientId -eq 'abc' -and (Get-CrTenantApp $s 'contoso').thumbprint -eq 'DEF')
    $s.app.clientId = 'fab'; $s.app.thumbprint = 'FAB'
    Save-CrSettings $settingsFile $s
    $s = Read-CrSettings $settingsFile
    Set-CrTenant $s 'Contoso'
    Check 'switching back brings its app back' ($s.app.clientId -eq 'abc' -and $s.app.thumbprint -eq 'DEF' -and $s.sharePointUrl -eq 'https://contoso.sharepoint.com')
    Check 'both tenants are offered' (((Get-CrTenantNames $s) -join ',') -eq 'contoso.onmicrosoft.com,fabrikam.onmicrosoft.com' -and (Get-CrTenantApp $s 'fabrikam').clientId -eq 'fab')
    Check 'an unknown tenant has no app' (-not (Get-CrTenantApp $s 'tailspin').clientId)

    # A newer version in a new folder picks up the setup, with no new app or certificate.
    $memory = Join-Path $work 'remembered\setup.json'
    $oldResults = Join-Path $work 'old-copy-results'
    New-Item -ItemType Directory -Path $oldResults | Out-Null
    $hasCert = { param($t) $t -eq 'DEF' }
    $s = Read-CrSettings $settingsFile; Set-CrTenant $s 'contoso'
    Save-CrRememberedSetup -Settings $s -ResultsFolder $oldResults -Path $memory
    $newCopy = Join-Path $work 'new-copy-settings.json'
    $back = Restore-CrRememberedSetup -SettingsPath $newCopy -Path $memory -HasCertificate $hasCert
    $got = Read-CrSettings $newCopy
    Check 'a new copy gets the same app and certificate' ($back.Tenant -eq 'contoso.onmicrosoft.com' -and $got.app.clientId -eq 'abc' -and $got.app.thumbprint -eq 'DEF')
    Check 'and the same results, and the other tenants' ($got.scan.resultsFolder -eq $oldResults -and @($got.otherTenants).Count -eq 1)
    Set-Content -LiteralPath $newCopy -Value '{ "tenant": "fabrikam.onmicrosoft.com" }'
    Check 'a copy with its own settings keeps them' ($null -eq (Restore-CrRememberedSetup -SettingsPath $newCopy -Path $memory -HasCertificate $hasCert) -and (Read-CrSettings $newCopy).tenant -eq 'fabrikam.onmicrosoft.com')
    Remove-Item -LiteralPath $newCopy

    # One tenant's certificate gone: the others and the results aren't lost with it.
    $back = Restore-CrRememberedSetup -SettingsPath $newCopy -Path $memory -HasCertificate { param($t) $t -eq 'FAB' }
    $got = Read-CrSettings $newCopy
    Check 'last tenant has no certificate: starts on one that works' ($back.Ready -and $back.Tenant -eq 'fabrikam.onmicrosoft.com' -and $got.app.clientId -eq 'fab' -and $got.app.thumbprint -eq 'FAB' -and $got.sharePointUrl -eq 'https://fabrikam.sharepoint.com')
    Check 'and keeps the results, and still offers the other tenant' ($got.scan.resultsFolder -eq $oldResults -and (Get-CrTenantNames $got) -contains 'contoso.onmicrosoft.com')
    Set-CrTenant $got 'contoso'
    Check 'which sets itself up again when chosen' (-not $got.app.clientId -and -not $got.app.thumbprint)
    Remove-Item -LiteralPath $newCopy
    # The other way round: the last tenant works, another's certificate has gone.
    $null = Restore-CrRememberedSetup -SettingsPath $newCopy -Path $memory -HasCertificate $hasCert
    $got = Read-CrSettings $newCopy
    Check 'another tenant without its certificate sets itself up when chosen' ($got.app.clientId -eq 'abc' -and -not (Get-CrTenantApp $got 'fabrikam').clientId -and (Get-CrTenantNames $got) -contains 'fabrikam.onmicrosoft.com')
    Remove-Item -LiteralPath $newCopy
    # No certificates at all: setup runs for the same tenant, using the same results.
    $back = Restore-CrRememberedSetup -SettingsPath $newCopy -Path $memory -HasCertificate { param($t) $false }
    $got = Read-CrSettings $newCopy
    Check 'no certificates on this PC: setup runs, nothing else is lost' (-not $back.Ready -and $got.tenant -eq 'contoso.onmicrosoft.com' -and -not $got.app.clientId -and $got.scan.resultsFolder -eq $oldResults -and @(Get-CrTenantNames $got).Count -eq 2)
    Remove-Item -LiteralPath $newCopy
    # The app removed from the last tenant: that tenant goes, the other stays.
    $removedMemory = Join-Path $work 'remembered\removed.json'
    $u = Read-CrSettings $memory; $u.app.clientId = ''; $u.app.thumbprint = ''
    Save-CrRememberedSetup -Settings $u -ResultsFolder $oldResults -Path $removedMemory
    $back = Restore-CrRememberedSetup -SettingsPath $newCopy -Path $removedMemory -HasCertificate { param($t) $t -eq 'FAB' }
    Check 'app removed from the last tenant: carries on with the other' ($back.Tenant -eq 'fabrikam.onmicrosoft.com' -and $back.Ready -and @(Get-CrTenantNames (Read-CrSettings $newCopy)).Count -eq 1)
    Remove-Item -LiteralPath $newCopy

    # An older copy, or one that knows fewer tenants, doesn't lose one added since.
    $olderMemory = Join-Path $work 'remembered\older.json'
    Save-CrRememberedSetup -Settings (Read-CrSettings $memory) -ResultsFolder $oldResults -Path $olderMemory
    $older = New-CrSettings; Set-CrTenant $older 'contoso'; $older.app.clientId = 'abc'; $older.app.thumbprint = 'DEF'
    Save-CrRememberedSetup -Settings $older -ResultsFolder $oldResults -Path $olderMemory
    $kept = Read-CrSettings $olderMemory
    Check 'an older copy saving keeps the tenant it never knew' ($kept.app.clientId -eq 'abc' -and (Get-CrTenantApp $kept 'fabrikam').clientId -eq 'fab')
    Save-CrRememberedSetup -Settings $older -ResultsFolder $oldResults -Path $olderMemory
    Check 'and saving twice lists it once' (@((Read-CrSettings $olderMemory).otherTenants).Count -eq 1)
    $older.app.clientId = ''; $older.app.thumbprint = ''
    Save-CrRememberedSetup -Settings $older -ResultsFolder $oldResults -Path $olderMemory
    $kept = Read-CrSettings $olderMemory
    Check 'removing the app from one tenant leaves the others remembered' (-not $kept.app.clientId -and (Get-CrTenantApp $kept 'fabrikam').clientId -eq 'fab')
    $last = New-CrSettings; Set-CrTenant $last 'fabrikam'
    Save-CrRememberedSetup -Settings $last -ResultsFolder $oldResults -Path $olderMemory
    Check 'with the last app removed, the setup is forgotten' (-not (Test-Path -LiteralPath $olderMemory))

    # Results carried over from an older copy that can't be found: it asks, and changes nothing until told.
    $null = Restore-CrRememberedSetup -SettingsPath $newCopy -Path $memory -HasCertificate $hasCert
    $got = Read-CrSettings $newCopy
    Check 'results still there: nothing to ask' ($null -eq (Get-CrMissingResults -Settings $got) -and $got.scan.resultsFolder -eq $oldResults)
    Remove-Item -LiteralPath $oldResults -Recurse
    Check 'results not found: it says which folder, and changes nothing' ((Get-CrMissingResults -Settings $got) -eq $oldResults -and $got.scan.resultsFolder -eq $oldResults -and $got.scan.resultsCarried -eq $oldResults)
    Check 'and they count again once the drive is back' ($null -eq (Get-CrMissingResults -Settings $got -Exists { param($p) $true }))
    Set-CrOwnResults -Settings $got
    Check 'told to start again: back to its own folder, and nothing more to ask' ($got.scan.resultsFolder -eq 'results' -and $null -eq (Get-CrMissingResults -Settings $got))
    $byHand = New-CrSettings; $byHand.scan.resultsFolder = $oldResults
    Check 'a results folder set by hand is left to be created' ($null -eq (Get-CrMissingResults -Settings $byHand))
    Remove-Item -LiteralPath $newCopy

    # A remembered setup that can't be opened right now isn't overwritten; one that makes no sense is.
    $lockedMemory = Join-Path $work 'remembered\locked.json'
    $lockedSettings = New-CrSettings; Set-CrTenant $lockedSettings 'contoso'; $lockedSettings.app.clientId = 'abc'; $lockedSettings.app.thumbprint = 'DEF'
    Save-CrRememberedSetup -Settings $lockedSettings -ResultsFolder $work -Path $lockedMemory
    $lockedBefore = Get-Content -LiteralPath $lockedMemory -Raw
    $hold = [IO.File]::Open($lockedMemory, 'Open', 'ReadWrite', 'None')
    $lockedSettings.app.clientId = 'changed'
    $why = try { Save-CrRememberedSetup -Settings $lockedSettings -ResultsFolder $work -Path $lockedMemory; '' } catch { $_.Exception.Message }
    $hold.Dispose()
    Check 'a remembered setup locked for now is left alone, and it says so' ($why -and (Get-Content -LiteralPath $lockedMemory -Raw) -ceq $lockedBefore)
    Set-Content -LiteralPath $lockedMemory -Value '{ half a file'
    Save-CrRememberedSetup -Settings $lockedSettings -ResultsFolder $work -Path $lockedMemory
    Check 'one that makes no sense is replaced' ((Read-CrSettings $lockedMemory).app.clientId -eq 'changed')
    Remove-Item -LiteralPath $lockedMemory

    # A certificate that can't sign in counts as gone, so setup runs by itself.
    Check 'a certificate in date with its private key can sign in' (Test-CrCertificateUsable ([pscustomobject]@{ HasPrivateKey = $true; NotAfter = (Get-Date).AddDays(30) }))
    Check 'an expired one can''t' (-not (Test-CrCertificateUsable ([pscustomobject]@{ HasPrivateKey = $true; NotAfter = (Get-Date).AddDays(-1) })))
    Check 'nor one with no private key' (-not (Test-CrCertificateUsable ([pscustomobject]@{ HasPrivateKey = $false; NotAfter = (Get-Date).AddDays(30) })))
    Check 'nor one that isn''t there' (-not (Test-CrCertificateUsable $null))

    # When an app was made reads back as written, whatever the time zone.
    $when = '2026-11-06T21:33:00.0000000+00:00'
    $dated = Join-Path $work 'dated-settings.json'
    Set-Content -LiteralPath $dated -Value "{ `"app`": { `"clientId`": `"abc`", `"createdAt`": `"$when`" } }"
    $readBack = Read-CrSettings $dated
    Check "when an app was made reads back exactly (got $($readBack.app.createdAt))" ("$($readBack.app.createdAt)" -ceq $when)
    Save-CrSettings $dated $readBack
    Check 'and stays the same when saved again' ("$((Read-CrSettings $dated).app.createdAt)" -ceq $when)
    Remove-Item -LiteralPath $dated

    # An older copy's out-of-date entry for another tenant doesn't replace what's remembered.
    $staleCopyMemory = Join-Path $work 'remembered\stale-copy.json'
    $newest = New-CrSettings; Set-CrTenant $newest 'contoso'; $newest.app.clientId = 'abc'; $newest.app.thumbprint = 'DEF'
    $newest.otherTenants = @([pscustomobject]@{ tenant = 'fabrikam.onmicrosoft.com'; sharePointUrl = 'https://fabrikam.sharepoint.com'; clientId = 'fab'; thumbprint = 'NEW' })
    Save-CrRememberedSetup -Settings $newest -ResultsFolder $work -Path $staleCopyMemory
    $oldCopy = $newest | ConvertTo-Json -Depth 5 | ConvertFrom-Json; $oldCopy.otherTenants[0].thumbprint = 'OLD'
    Save-CrRememberedSetup -Settings $oldCopy -ResultsFolder $work -Path $staleCopyMemory
    Check 'an older copy doesn''t bring back a replaced certificate' ((Get-CrTenantApp (Read-CrSettings $staleCopyMemory) 'fabrikam').thumbprint -eq 'NEW')
    $switched = Read-CrSettings $staleCopyMemory; Set-CrTenant $switched 'fabrikam'; $switched.app.thumbprint = 'NEWER'
    Save-CrRememberedSetup -Settings $switched -ResultsFolder $work -Path $staleCopyMemory
    Check 'but the tenant just used is up to date' ((Read-CrSettings $staleCopyMemory).app.thumbprint -eq 'NEWER')
    Remove-Item -LiteralPath $staleCopyMemory

    # A remembered setup that can't be read says so, and a stale-site limit that was only the default follows the rule book.
    $damagedMemory = Join-Path $work 'remembered\damaged.json'
    Set-Content -LiteralPath $damagedMemory -Value '{ half a file'
    $why = try { Restore-CrRememberedSetup -SettingsPath $newCopy -Path $damagedMemory -HasCertificate $hasCert; '' } catch { $_.Exception.Message }
    Check 'a damaged remembered setup is reported' ($why -and -not (Test-Path -LiteralPath $newCopy))
    Remove-Item -LiteralPath $damagedMemory
    $staleMemory = Join-Path $work 'remembered\stale.json'
    $stale = New-CrSettings; Set-CrTenant $stale 'contoso'; $stale.app.clientId = 'abc'; $stale.app.thumbprint = 'DEF'
    Save-CrRememberedSetup -Settings $stale -ResultsFolder $work -Path $staleMemory
    $file = Get-Content -LiteralPath $staleMemory -Raw | ConvertFrom-Json; $file.scan.staleDays = 11; $file.scan.staleDaysDefault = 11
    $file | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $staleMemory
    $null = Restore-CrRememberedSetup -SettingsPath $newCopy -Path $staleMemory -HasCertificate $hasCert
    Check 'an old default stale-site limit follows the new rule book' ((Read-CrSettings $newCopy).scan.staleDays -eq (Get-CrRuleBook).thresholds.staleDays -and -not (Read-CrSettings $newCopy).scan.PSObject.Properties['staleDaysDefault'])
    Remove-Item -LiteralPath $newCopy
    $file.scan.staleDays = 45
    $file | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $staleMemory
    $null = Restore-CrRememberedSetup -SettingsPath $newCopy -Path $staleMemory -HasCertificate $hasCert
    Check 'one somebody chose stays' ((Read-CrSettings $newCopy).scan.staleDays -eq 45)
    Remove-Item -LiteralPath $newCopy, $staleMemory

    # Which results are remembered, when a copy is on a different folder from them.
    $whereMemory = Join-Path $work 'remembered\where.json'
    $rememberedFolder = Join-Path $work 'remembered-results'
    $ownFolder = Join-Path $work 'own-results'
    New-Item -ItemType Directory -Path $rememberedFolder | Out-Null
    $onOwn = New-CrSettings; Set-CrTenant $onOwn 'contoso'; $onOwn.app.clientId = 'abc'; $onOwn.app.thumbprint = 'DEF'
    Save-CrRememberedSetup -Settings $onOwn -ResultsFolder $rememberedFolder -Path $whereMemory
    Save-CrRememberedSetup -Settings $onOwn -ResultsFolder $ownFolder -Path $whereMemory
    Check 'an older copy on its own folder doesn''t replace remembered results still there' ((Read-CrSettings $whereMemory).scan.resultsFolder -eq $rememberedFolder)
    $moved = Read-CrSettings $whereMemory; $moved.scan.resultsFolder = 'results'; $moved.scan.resultsCarried = $rememberedFolder
    Save-CrRememberedSetup -Settings $moved -ResultsFolder $ownFolder -Path $whereMemory
    Check 'moving away from carried results on purpose does' ((Read-CrSettings $whereMemory).scan.resultsFolder -eq $ownFolder)
    $handSet = Read-CrSettings $whereMemory; $handSet.scan.resultsFolder = $rememberedFolder; $handSet.scan.resultsCarried = ''
    Save-CrRememberedSetup -Settings $handSet -ResultsFolder $rememberedFolder -Path $whereMemory
    Check 'and so does a folder set by hand' ((Read-CrSettings $whereMemory).scan.resultsFolder -eq $rememberedFolder)
    # A copy on its own folder takes over once its newest scan is newer, or when the person chose it.
    Save-CrRememberedSetup -Settings $handSet -ResultsFolder $rememberedFolder -Path $whereMemory
    New-Item -ItemType Directory -Path $ownFolder, (Join-Path $rememberedFolder '20260101T000000-aaaa') -Force | Out-Null
    Save-CrRememberedSetup -Settings $onOwn -ResultsFolder $ownFolder -Path $whereMemory
    Check 'with no scan of its own it doesn''t' ((Read-CrSettings $whereMemory).scan.resultsFolder -eq $rememberedFolder)
    Save-CrRememberedSetup -Settings $onOwn -ResultsFolder $ownFolder -Path $whereMemory -TakeOver
    Check 'told to, it does' ((Read-CrSettings $whereMemory).scan.resultsFolder -eq $ownFolder)
    Save-CrRememberedSetup -Settings $handSet -ResultsFolder $rememberedFolder -Path $whereMemory
    New-Item -ItemType Directory -Path (Join-Path $ownFolder '20250101T000000-bbbb') -Force | Out-Null
    Save-CrRememberedSetup -Settings $onOwn -ResultsFolder $ownFolder -Path $whereMemory
    Check 'an older scan of its own doesn''t count' ((Read-CrSettings $whereMemory).scan.resultsFolder -eq $rememberedFolder)
    New-Item -ItemType Directory -Path (Join-Path $ownFolder '20270101T000000-cccc') -Force | Out-Null
    Save-CrRememberedSetup -Settings $onOwn -ResultsFolder $ownFolder -Path $whereMemory
    Check 'a newer scan of its own does' ((Read-CrSettings $whereMemory).scan.resultsFolder -eq $ownFolder)
    # Saving the same again leaves the file alone, and a half-written temporary file is never left behind.
    (Get-Item -LiteralPath $whereMemory).LastWriteTime = [DateTime]'2020-01-01'
    Save-CrRememberedSetup -Settings $onOwn -ResultsFolder $ownFolder -Path $whereMemory
    Check 'nothing new: the file isn''t written again' ((Get-Item -LiteralPath $whereMemory).LastWriteTime -eq [DateTime]'2020-01-01' -and -not (Test-Path -LiteralPath "$whereMemory.tmp"))
    # A tenant blanked in one copy doesn't replace a working one in what's remembered.
    $blankMemory = Join-Path $work 'remembered\blank.json'
    $working = New-CrSettings; Set-CrTenant $working 'contoso'; $working.app.clientId = 'abc'; $working.app.thumbprint = 'DEF'
    $working.otherTenants = @([pscustomobject]@{ tenant = 'fabrikam.onmicrosoft.com'; sharePointUrl = 'https://fabrikam.sharepoint.com'; clientId = 'fab'; thumbprint = 'FAB' })
    Save-CrRememberedSetup -Settings $working -ResultsFolder $work -Path $blankMemory
    $blanked = $working | ConvertTo-Json -Depth 5 | ConvertFrom-Json; $blanked.otherTenants[0].clientId = ''; $blanked.otherTenants[0].thumbprint = ''
    Save-CrRememberedSetup -Settings $blanked -ResultsFolder $work -Path $blankMemory
    $kept = Read-CrSettings $blankMemory
    Check 'a tenant blanked in one copy stays working in what''s remembered, and listed once' ((Get-CrTenantApp $kept 'fabrikam').clientId -eq 'fab' -and @($kept.otherTenants | Where-Object tenant -EQ 'fabrikam.onmicrosoft.com').Count -eq 1)
    Save-CrRememberedSetup -Settings $handSet -ResultsFolder $rememberedFolder -Path $whereMemory
    Remove-Item -LiteralPath $rememberedFolder -Recurse
    Save-CrRememberedSetup -Settings $onOwn -ResultsFolder $ownFolder -Path $whereMemory
    $carriedCopy = $onOwn | ConvertTo-Json -Depth 5 | ConvertFrom-Json; $carriedCopy.scan.resultsFolder = $ownFolder; $carriedCopy.scan.resultsCarried = $ownFolder
    Save-CrRememberedSetup -Settings $carriedCopy -ResultsFolder $ownFolder -Path $whereMemory
    Check 'nor does an older copy on carried results replace them' ((Read-CrSettings $whereMemory).scan.resultsFolder -eq $rememberedFolder)
    $unplugged = Read-CrSettings $whereMemory
    Check 'remembered results it can''t see stay remembered, even with newer scans of its own' ($unplugged.scan.resultsFolder -eq $rememberedFolder)
    Save-CrRememberedSetup -Settings $onOwn -ResultsFolder $ownFolder -Path $whereMemory -TakeOver
    Check 'until the person chooses this folder' ((Read-CrSettings $whereMemory).scan.resultsFolder -eq $ownFolder)

    $s = Read-CrSettings $memory; $s.app.clientId = ''; $s.app.thumbprint = ''; $s.otherTenants = @()
    Save-CrRememberedSetup -Settings $s -ResultsFolder $work -Path $memory
    Check 'with the app removed, the remembered tenants stay until each is removed' (Test-Path -LiteralPath $memory)
    Remove-Item -LiteralPath $memory
    Check 'nothing remembered: nothing restored' ($null -eq (Restore-CrRememberedSetup -SettingsPath $newCopy -Path $memory -HasCertificate $hasCert))
    $names = 'https://fabrikam.sharepoint.com/', 'fabrikam.sharepoint.com', 'https://Fabrikam-admin.sharepoint.com/_layouts/15/online/AdminHome.aspx', 'https://fabrikam-my.sharepoint.com/personal/x', 'https://fabrikam.sharepoint.com/sites/finance', ' fabrikam ', 'fabrikam.onmicrosoft.com'
    Check "a pasted SharePoint address gives the tenant (got $(($names | ForEach-Object { ConvertTo-CrTenantName $_ }) -join ', '))" (@($names | ForEach-Object { ConvertTo-CrTenantName $_ } | Sort-Object -Unique) -join ',' -eq 'fabrikam.onmicrosoft.com')
    $n = New-CrSettings; Set-CrTenant $n 'https://fabrikam.sharepoint.com/'
    Check 'and its SharePoint address' ($n.tenant -eq 'fabrikam.onmicrosoft.com' -and $n.sharePointUrl -eq 'https://fabrikam.sharepoint.com')
    Check 'durations read naturally' (((45, 60, 3700, 7200, 90000 | ForEach-Object { Format-CrDuration $_ }) -join '|') -eq '45 seconds|1 minute|1 hour 2 minutes|2 hours|1 day 1 hour')

    # SharePoint list items arrive with both "Id" and "ID"; the first of each pair is kept, at any depth.
    $parsed = ConvertFrom-CrJson '{"value":[{"Id":4,"ID":4,"FileRef":"/a","Inner":{"x":1,"X":2}}],"odata.nextLink":null}'
    Check 'a response with Id and ID parses' ($parsed.value[0].Id -eq 4 -and $parsed.value[0].FileRef -eq '/a' -and $parsed.value[0].Inner.x -eq 1 -and @($parsed.value).Count -eq 1)
    Check 'an ordinary response parses as before' ((ConvertFrom-CrJson '{"value":[],"d":"2026-01-01T00:00:00Z"}').d -is [string])
    Check 'SharePoint sites listed, OneDrive left out, trailing slash removed' (@(Get-CrSites).Count -eq 4 -and (Get-CrSites).url -contains $b)
    Check 'OneDrive only' (@(Get-CrSites -Include OneDrive).Count -eq 1 -and (Get-CrSites -Include OneDrive)[0].kind -eq 'OneDrive')
    $sites = @(Get-CrSites -Include Both)
    Check 'both kinds listed' ($sites.Count -eq 5)

    $folder = New-CrScan -ResultsRoot $work -Level Deep -Sites $sites -Tenant 'contoso.onmicrosoft.com'
    Invoke-CrScan -Folder $folder 3>$null 6>$null

    $scan = Get-Content (Join-Path $folder 'scan.json') -Raw | ConvertFrom-Json
    $siteResults = Get-Content (Join-Path $folder 'sites.json') -Raw | ConvertFrom-Json -DateKind String
    $findings = Get-Content (Join-Path $folder 'findings.json') -Raw | ConvertFrom-Json -DateKind String
    $finance = $siteResults | Where-Object url -EQ $a
    $archive = $siteResults | Where-Object url -EQ $b
    $locked = $siteResults | Where-Object url -EQ $c
    $rulesFor = { param($url) @($findings | Where-Object siteUrl -EQ $url | ForEach-Object rule | Sort-Object) -join ',' }

    Check "scan completed (got $($scan.status))" ($scan.status -eq 'Completed')
    Check 'five site results' (@($siteResults).Count -eq 5)
    $old = $siteResults | Where-Object url -EQ $e
    Check "an archived site is skipped, not failed (got $($old.status))" ($old.status -eq 'Skipped' -and $null -eq $old.score -and $old.error -like 'Archived or locked*' -and -not ($findings | Where-Object siteUrl -EQ $e))
    Check "locked site failed with its reason (got $($locked.status): $($locked.error))" ($locked.status -eq 'Failed' -and $locked.error -match '403' -and $null -eq $locked.score)

    $expectFinance = 'AnyoneLink,BrokenInheritance,BrokenInheritance,EveryoneGrant,EveryoneGrant,EveryoneGrant,FilesUnlabeled,GuestAccess,GuestAccess,GuestInGroup,PublicGroup,SiteSingleOwner,SiteUnlabeled'
    Check "finance findings (got $(& $rulesFor $a))" ((& $rulesFor $a) -eq $expectFinance)
    Check "finance details (owners $($finance.ownerCount), guests $($finance.guestCount), unique $($finance.uniqueItemCount))" (
        $finance.ownerCount -eq 1 -and $finance.guestCount -eq 1 -and $finance.uniqueItemCount -eq 3 -and $finance.subsiteCount -eq 1 -and $finance.isGroupConnected -and $finance.lastActivityAt -eq '2026-09-30T10:11:00Z')
    Check 'finance: 2 of 3 files unlabelled, across both pages' (@($findings | Where-Object rule -EQ FilesUnlabeled).detail -eq '2 of 3 files have no sensitivity label')
    Check 'finance: guest reached by link on the folder' (@($findings | Where-Object { $_.rule -eq 'GuestAccess' -and $_.objectType -eq 'Folder' -and $_.detail -eq 'Shared with them through a link' }).Count -eq 1)
    Check 'site assets library skipped' (-not ($script:calls | Where-Object { $_ -like "*guid'L2'*" }))
    Check "finance score $($finance.score)" ($finance.score -eq [Math]::Max(0, 100 - 15 * $finance.findingCounts.High - 5 * $finance.findingCounts.Medium - $finance.findingCounts.Low))

    # The report's Table view carries the spreadsheets' rows, and the findings spreadsheet says where in words and links there.
    $html = Get-Content (Join-Path $folder 'report.html') -Raw
    $tableJson = [regex]::Match($html,"<script type='application/json' id='table-data'>(.*?)</script>", 'Singleline').Groups[1].Value
    $tableData = if ($tableJson) { $tableJson.Replace('<\/', '</') | ConvertFrom-Json } else { @() }
    $findingCsv = @(Import-Csv (Join-Path $folder 'findings.csv'))
    Check "the Table view has the findings, sites and own-permission rows (got $(@($tableData).Count) tables)" (
        @($tableData).Count -eq 3 -and @($tableData[0].rows).Count -eq $findingCsv.Count -and @($tableData[1].rows).Count -eq 5 -and $html.Contains("data-view='table'"))
    Check 'findings say "Whole site" and link to where they are' (
        ($findingCsv | Where-Object { $_.Location -eq 'Whole site' -and $_.Link -eq $a }) -and ($findingCsv | Where-Object { $_.Link -eq 'https://contoso.sharepoint.com/sites/finance/Shared%20Documents/a.docx' }))

    # Every item with its own permissions is listed, with who has access (Deep), apart from the issues and the score.
    $own = @(Import-Csv (Join-Path $folder 'unique-permissions.csv'))
    $ownText = @($own | ForEach-Object { "$($_.Location) | $($_.Type) | $($_.'Who has access')" } | Sort-Object) -join ' / '
    Check "items with their own permissions listed with who has access (got $ownText)" (
        $ownText -eq 'Lists/Requests, item 7 | List item | Raj (guest): Contribute / Shared Documents/a.docx | File | Anyone with the link: Edit / Shared Documents/Payroll | Folder | Link for specific people (1 person): View')
    Check "the list names each library or list as people know it (got $(@($own.'Library or list' | Sort-Object -Unique) -join ', '))" ((@($own.'Library or list' | Sort-Object -Unique) -join ',') -eq 'Documents,Requests')
    Check 'a subsite''s library says which subsite, and older results fall back to the address' (
        (Get-CrLibraryName ([pscustomobject]@{ siteUrl = $a; library = '/sites/finance/board/Shared Documents'; libraryName = 'Documents' })) -eq 'Documents (in board)' -and
        (Get-CrLibraryName ([pscustomobject]@{ siteUrl = $a; library = '/sites/finance/Lists/Requests'; libraryName = $null })) -eq 'Requests' -and
        (Get-CrLibraryName ([pscustomobject]@{ siteUrl = $a; library = '/sites/finance/Shared Documents' })) -eq 'Documents')
    Check 'OneDrive files are not in that list' (-not ($own | Where-Object 'Site URL' -EQ $d))
    Check 'the list links straight to each item' (@($own | Where-Object Link -EQ 'https://contoso.sharepoint.com/sites/finance/Shared%20Documents/Payroll').Count -eq 1)
    $html = Get-Content (Join-Path $folder 'report.html') -Raw
    Check 'report has the list, and the site links to it' ($html.Contains("<h2 id='own-permissions'>") -and $html.Contains("id='perm-$(Get-CrSiteKey 'contoso.sharepoint.com,a,1')'") -and
        $html.Contains("href='#perm-$(Get-CrSiteKey 'contoso.sharepoint.com,a,1')'>3 items with their own permissions</a>") -and $html.Contains('Raj (guest): Contribute'))

    # The app catalog is set aside: its template is read, then nothing else, and the report says why.
    $folderApps = New-CrScan -ResultsRoot $work -Level Deep -Sites @([pscustomobject]@{ siteId = 'contoso.sharepoint.com,f,6'; url = $f; title = 'Apps'; kind = 'SharePoint' }) -Tenant 'contoso.onmicrosoft.com'
    $script:calls.Clear()
    Invoke-CrScan -Folder $folderApps 3>$null 6>$null
    $apps = Read-CrJson (Join-Path $folderApps 'sites.json')
    $appsHtml = Get-Content (Join-Path $folderApps 'report.html') -Raw
    Check "the app catalog is left out with its reason (got $($apps.status): $($apps.error))" (
        $apps.status -eq 'Skipped' -and $apps.error -like 'App catalog: *' -and $null -eq $apps.score -and
        -not @(Read-CrJson (Join-Path $folderApps 'findings.json')).Where({ $_ }).Count -and @($script:calls | Where-Object { $_.StartsWith($f) }).Count -eq 1)
    Check 'the report lists it under Sites left out, saying why' ($appsHtml.Contains("<h2 id='skipped'>Sites left out</h2>") -and $appsHtml.Contains('<b>App catalog</b>') -and
        $appsHtml.Contains("href='#skipped'><b>1</b> left out"))
    $appsRecent = (Get-CrProgressView $folderApps).Recent
    Check "the finished list says it was left out on purpose (got $($appsRecent.Result))" ($appsRecent[0].Result -eq 'Left out on purpose: App catalog')
    Remove-Item $folderApps -Recurse -Force

    # Standard lists them too, without reading who has access to each.
    $folderStd = New-CrScan -ResultsRoot $work -Level Standard -Sites @($sites | Where-Object url -EQ $a) -Tenant 'contoso.onmicrosoft.com'
    $script:calls.Clear()
    Invoke-CrScan -Folder $folderStd 3>$null 6>$null
    $ownStd = @(Import-Csv (Join-Path $folderStd 'unique-permissions.csv'))
    Check "Standard lists them without who has access (got $($ownStd.Count))" ($ownStd.Count -eq 3 -and -not ($ownStd | Where-Object 'Who has access' -NE 'Run a Deep scan to see') -and
        -not ($script:calls | Where-Object { $_ -like '*/items(*)/RoleAssignments*' }))
    Remove-Item $folderStd -Recurse -Force

    # The progress window (or a virus checker) holding the file open must not stop the scan from replacing it.
    $busy = Join-Path $work 'busy.json'
    Write-CrJson $busy @{ n = 1 }
    $holder = [System.IO.File]::Open($busy, 'Open', 'Read', 'ReadWrite')
    $writer = Start-ThreadJob -ArgumentList (Join-Path $PSScriptRoot '..\CopilotReadiness\CopilotReadiness.psm1'), $busy -ScriptBlock {
        param($modulePath, $path)
        Import-Module $modulePath
        Write-CrJson $path @{ n = 2 }
    }
    Start-Sleep -Milliseconds 400
    $holder.Dispose()
    $null = $writer | Wait-Job -Timeout 30
    $writeError = $writer.ChildJobs[0].Error | Select-Object -First 1
    $writer | Remove-Job -Force
    Check "a file held open is replaced once it is let go (error: $writeError)" (-not $writeError -and (Read-CrJson $busy).n -eq 2)

    # A site's note changes all the time while the progress window's copy of it is written.
    $note = New-CrStepNote ([pscustomobject]@{ url = "$sp/sites/busy"; title = 'Busy'; kind = 'SharePoint' })
    $changer = Start-ThreadJob -ArgumentList (Join-Path $PSScriptRoot '..\CopilotReadiness\CopilotReadiness.psm1'), $note -ScriptBlock {
        param($modulePath, $note)
        Import-Module $modulePath
        Set-CrStepNote $note
        $until = (Get-Date).AddSeconds(2)
        while ((Get-Date) -lt $until) { Add-CrStepItems }
    }
    $copyErrors = 0
    $until = (Get-Date).AddSeconds(2)
    while ((Get-Date) -lt $until) { try { Write-CrProgress -Folder $work -State Running -Total 1 -Done 0 -DoneAtStart 0 -Current @($note) } catch { $copyErrors++ } }
    $changer | Wait-Job | Remove-Job -Force
    Check "progress is written while a site's note keeps changing (errors: $copyErrors)" ($copyErrors -eq 0 -and [long](Read-CrJson (Join-Path $work 'progress.json')).current[0].itemsDone -gt 0)

    Check 'finance: the subsite open to Everyone, its own Owners group not flagged' (@($findings | Where-Object { $_.objectType -eq 'Subsite' }).Count -eq 1 -and @($findings | Where-Object { $_.objectType -eq 'Subsite' })[0].principal -eq 'Everyone')
    Check 'finance: the list shared with everyone' (@($findings | Where-Object { $_.objectType -eq 'List' -and $_.rule -eq 'EveryoneGrant' -and $_.path -eq '/sites/finance/Lists/Requests' }).Count -eq 1)
    Check 'finance: the list item shared with a guest, as a link to open it' (@($findings | Where-Object { $_.objectType -eq 'Item' -and $_.path -eq '/sites/finance/Lists/Requests/DispForm.aspx?ID=7' -and $_.severity -eq 'High' }).Count -eq 1)
    Check 'finance: system lists such as Site Pages skipped' (-not ($script:calls | Where-Object { $_ -like "*guid'L4'*" }))
    $dana = $siteResults | Where-Object url -EQ $d
    Check "OneDrive: only the Anyone link, scored like a site (got $(& $rulesFor $d), score '$($dana.score)')" ((& $rulesFor $d) -eq 'AnyoneLink' -and $dana.kind -eq 'OneDrive' -and $dana.score -eq 85 -and $dana.status -eq 'Done')
    Check 'OneDrive: system lists skipped' (-not ($script:calls | Where-Object { $_ -like "*guid'L10'*" }))
    Check "archive findings (got $(& $rulesFor $b))" ((& $rulesFor $b) -eq 'SiteSingleOwner,SiteStale,SiteUnlabeled')
    Check 'tenant score is the average of the sites that were read, not the OneDrive' ($scan.score -eq [int][Math]::Round(($finance.score + $archive.score) / 2))
    Check "the OneDrive score is the OneDrive's own (got '$($scan.oneDriveScore)')" ($scan.oneDriveScore -eq 85)
    Check 'every finding id is unique' (@($findings.id | Sort-Object -Unique).Count -eq @($findings).Count)

    # What the progress window shows once it's done
    $progress = Get-Content (Join-Path $folder 'progress.json') -Raw | ConvertFrom-Json
    Check "progress says completed (got $($progress.state), $($progress.done) done, $($progress.failed) failed)" ($progress.state -eq 'Completed' -and $progress.done -eq 5 -and $progress.failed -eq 1 -and $progress.skipped -eq 1 -and $progress.pid -eq $PID)
    $recent = @((Get-CrProgressView $folder).Recent)
    Check "finished list has every site, newest first, with what each found (got $($recent.Count))" ($recent.Count -eq 5 -and ($recent | Where-Object { $_.Site -eq 'Old' -and $_.Result -eq 'Archived or locked, so skipped' }) -and ($recent | Where-Object { $_.Site -eq 'Locked' -and $_.Result -like "Couldn't read: HTTP 403*" }) -and ($recent | Where-Object { $_.Site -eq 'Archive' -and $_.Result -eq '2 Medium, 1 Low' }))
    Check 'progress counts what was found' (($progress.findings.High + $progress.findings.Medium + $progress.findings.Low) -eq $scan.findingsTotal)
    $view = Get-CrProgressView $folder
    Check "finished view (got $($view.State): $($view.Heading))" ($view.State -eq 'Completed' -and $view.Heading -eq "Finished: score $($scan.score), OneDrive score 85 out of 100" -and $view.Report -and -not $view.CanStop -and -not $view.CanCarryOn)
    Check "finished view says what was scanned (got $($view.About))" ($view.About -like 'Deep scan of 4 SharePoint sites and 1 OneDrive in contoso.onmicrosoft.com at Normal pace, started *' -and $view.Extra -like "1 couldn't be read*1 left out (archived, locked, or set aside on purpose)")

    foreach ($file in 'report.html', 'findings.csv', 'sites.csv') { Check "$file written" (Test-Path (Join-Path $folder $file)) }
    $csv = Import-Csv (Join-Path $folder 'findings.csv')
    Check 'findings.csv has a row per finding with advice' (@($csv).Count -eq @($findings).Count -and $csv[0].'What to do')
    $html = Get-Content (Join-Path $folder 'report.html') -Raw
    Check 'report shows the score and the rule names' ($html.Contains(">$($scan.score)</b>") -and $html.Contains('Open to everyone'))
    Check 'report shows the OneDrive score beside it' ($html.Contains("<b>85</b><span>out of 100</span></div><div>OneDrive</div>") -and $html.Contains('<div>SharePoint sites</div>'))
    Check 'report lists the archived site apart from the failed one' ($html.Contains("<h2 id='skipped'>") -and $html.Contains("href='#skipped'><b>1</b> left out") -and $html.Contains("href='#failed'><b>1</b> could not be read"))
    $oneDrive = @($siteResults | Where-Object kind -EQ 'OneDrive')[0]
    $oneDriveCsv = Join-Path $folder "onedrives\$($oneDrive.title).csv"
    $oneDriveFindings = @($findings | Where-Object siteId -EQ $oneDrive.siteId)
    Check "a OneDrive gets its own CSV with only its findings (expected $($oneDriveFindings.Count) rows)" (
        (Test-Path -LiteralPath $oneDriveCsv) -and $oneDriveFindings.Count -gt 0 -and @(Import-Csv -LiteralPath $oneDriveCsv).Count -eq $oneDriveFindings.Count -and -not (@(Import-Csv -LiteralPath $oneDriveCsv) | Where-Object 'Site URL' -NE $oneDrive.url))
    Check 'SharePoint sites do not get a file in the OneDrive folder' (@(Get-ChildItem -LiteralPath (Join-Path $folder 'onedrives') -File).Count -eq 1)
    Check "report links to the OneDrive's own CSV" ($html.Contains("<a href='onedrives/$([uri]::EscapeDataString("$($oneDrive.title).csv"))' download>"))
    $names = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $first = Get-CrOneDriveFileName -Title "Sam O'Brien" -SiteId 'a' -Used $names
    $second = Get-CrOneDriveFileName -Title "sam o'brien" -SiteId 'b' -Used $names
    Check "owners with the same name get separate files (got $first, $second)" ($first -eq "Sam O'Brien.csv" -and $second -like "sam o'brien (*).csv")
    Check 'a name with odd characters makes a safe file name' ((Get-CrOneDriveFileName -Title 'A/B: "C"?.' -SiteId 'c' -Used $names) -eq 'A B C.csv' -and (Get-CrOneDriveFileName -Title 'CON' -SiteId 'd' -Used $names) -eq 'OneDrive CON.csv' -and (Get-CrOneDriveFileName -Title '' -SiteId 'e' -Used $names) -eq "$(Get-CrSiteKey 'e').csv")
    Check 'report links to the CSV files' ($html.Contains("href='findings.csv'") -and $html.Contains("href='sites.csv'"))
    Check 'report still works in a viewer that blocks address changes' ($html.Contains('try { history.replaceState(') -and $html.Contains('try { history.pushState(') -and -not [regex]::IsMatch($html, '(?<!try \{ )history\.(replace|push)State\('))
    Check 'report has a section per site and per kind of issue' ($html.Contains("id='site-$(Get-CrSiteKey 'contoso.sharepoint.com,a,1')'") -and $html.Contains("id='issue-AnyoneLink'"))
    Check 'report has a OneDrive section and a SharePoint/OneDrive filter' ($html.Contains("id='onedrive'") -and $html.Contains("data-kind='OneDrive' aria-pressed"))
    Check 'report links a list item to the page that opens it' ($html.Contains('https://contoso.sharepoint.com/sites/finance/Lists/Requests/DispForm.aspx?ID=7') -and $html.Contains('Lists/Requests, item 7'))
    Check 'report links straight to the file' ($html.Contains('https://contoso.sharepoint.com/sites/finance/Shared%20Documents/a.docx'))

    # Stop and continue: forget one site, mark the scan stopped, run again; only that site is read again.
    $archiveFile = Join-Path $folder "sites\$(Get-CrSiteKey 'contoso.sharepoint.com,b,2').json"
    Remove-Item $archiveFile
    $s = Get-Content (Join-Path $folder 'scan.json') -Raw | ConvertFrom-Json
    $s.status = 'Cancelled'
    $s | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $folder 'scan.json')
    Check 'the stopped scan is offered to continue' ((Get-CrUnfinishedScan $work).Folder -eq $folder -and (Get-CrUnfinishedScan $work -Tenant 'contoso.onmicrosoft.com').Folder -eq $folder)
    Check 'but not to another tenant' ($null -eq (Get-CrUnfinishedScan $work -Tenant 'fabrikam.onmicrosoft.com'))
    $past = @(Get-CrPastScans $work -Tenant 'contoso.onmicrosoft.com')
    Check "past scans list the stopped scan, how far it got and no findings yet (got $($past.Count), $($past[0].State), $($past[0].Done) of $($past[0].Total))" (
        $past.Count -eq 1 -and $past[0].Folder -eq $folder -and $past[0].State -eq 'Stopped' -and $past[0].Done -eq $past[0].Total - 1 -and $null -eq $past[0].Findings)
    Check 'past scans leave out other tenants' (@(Get-CrPastScans $work -Tenant 'fabrikam.onmicrosoft.com').Count -eq 0)

    # A stopped scan from before the rules changed can't be continued: its report would mix two rule books.
    $olderRoot = Join-Path $work 'older-rules'
    $olderScan = Join-Path $olderRoot 'scan'
    New-Item -ItemType Directory -Path $olderRoot | Out-Null
    Copy-Item $folder $olderScan -Recurse
    Remove-Item (Join-Path $olderScan 'progress.json') -ErrorAction SilentlyContinue
    $oldScope = Get-Content (Join-Path $olderScan 'scope.json') -Raw | ConvertFrom-Json
    $oldScope.rulebook = -1
    $oldScope | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $olderScan 'scope.json')
    Check 'older rules: not offered to continue' ($null -eq (Get-CrUnfinishedScan $olderRoot))
    Check 'older rules: past scans say so' (@(Get-CrPastScans $olderRoot)[0].State -eq 'OlderRules' -and @(Get-CrPastScans $olderRoot)[0].RulesNote -like "*older version's rules*")
    $oldView = Get-CrProgressView $olderScan
    Check 'older rules: the progress window has no Continue, and says why' (-not $oldView.CanCarryOn -and $oldView.Status -like "*older version's rules*")
    $refused = try { Invoke-CrScan -Folder $olderScan 3>$null 6>$null; '' } catch { $_.Exception.Message }
    Check 'older rules: it can''t be run anyway' ($refused -like "*older version's rules*")
    # And the other way round: this copy is the older one.
    $oldScope.rulebook = [int](Get-CrRuleBook).version + 1
    $oldScope | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $olderScan 'scope.json')
    Write-CrJson (Join-Path $olderScan 'progress.json') ([pscustomobject]@{ state = 'Stopping'; pid = $PID; processStartedAt = (Get-CrProcessStamp (Get-Process -Id $PID)); done = 0; failed = 0; current = @() })
    $stoppingView = Get-CrProgressView $olderScan
    Check "newer rules: stopping doesn't promise it can continue (got $($stoppingView.State): $($stoppingView.Status))" ($stoppingView.State -eq 'Stopping' -and $stoppingView.Status -notlike '*when you continue*')
    Remove-Item (Join-Path $olderScan 'progress.json')
    Check 'newer rules: not offered to continue either' ($null -eq (Get-CrUnfinishedScan $olderRoot))
    Check 'newer rules: past scans say so' (@(Get-CrPastScans $olderRoot)[0].State -eq 'NewerRules')
    $oldView = Get-CrProgressView $olderScan
    $failedProgress = [pscustomobject]@{ state = 'Failed'; pid = 0; error = 'This scan started in a newer version, under newer rules, so it can''t be continued here. Continue it in that version, or start a new scan.'; done = 0; failed = 0 }
    Write-CrJson (Join-Path $olderScan 'progress.json') $failedProgress
    $failedView = Get-CrProgressView $olderScan
    Check "newer rules: a refused scan says why once (got $($failedView.Status))" (@([regex]::Matches($failedView.Status, 'newer version')).Count -eq 1)
    Remove-Item (Join-Path $olderScan 'progress.json')
    # A real problem isn't hidden by the note about rules.
    $failedProgress.error = 'Sign-in was refused.'
    Write-CrJson (Join-Path $olderScan 'progress.json') $failedProgress
    Check 'newer rules: a scan that failed for another reason still says what went wrong' ((Get-CrProgressView $olderScan).Status -like '*Sign-in was refused.*Continue it in that version*')
    Remove-Item (Join-Path $olderScan 'progress.json')
    Check 'newer rules: it says to continue in the newer version' (-not $oldView.CanCarryOn -and $oldView.Status -like '*Continue it in that version*')
    Remove-Item $olderRoot -Recurse -Force
    $spare = Join-Path $work 'spare-scan'
    Copy-Item $folder $spare -Recurse
    Check 'a past scan can be removed' ((Remove-CrScan $spare -Permanently) -and -not (Test-Path $spare))
    $notScan = New-Item (Join-Path $work 'not-a-scan') -ItemType Directory
    $refused = try { Remove-CrScan $notScan.FullName -Permanently; $false } catch { $true }
    Check 'a folder that isn''t a scan is not removed' ($refused -and (Test-Path $notScan.FullName))
    Remove-Item $notScan.FullName

    $script:calls.Clear()
    Invoke-CrScan -Folder $folder 3>$null 6>$null
    Check 'continuing reads only the missing site and the one that failed' (-not ($script:calls | Where-Object { $_ -notlike "$b*" -and $_ -notlike "$c*" -and $_ -notlike '*sites/contoso.sharepoint.com,c,3*' }))
    Check 'carried-on scan completed' ((Get-Content (Join-Path $folder 'scan.json') -Raw | ConvertFrom-Json).status -eq 'Completed')
    Check 'nothing left to continue' ($null -eq (Get-CrUnfinishedScan $work))
    $past = @(Get-CrPastScans $work)[0]
    $doneScan = Get-Content (Join-Path $folder 'scan.json') -Raw | ConvertFrom-Json
    Check 'past scans show a finished scan with its report, score and findings' (
        $past.State -eq 'Completed' -and $past.Report -and $past.Score -eq $doneScan.score -and ($past.Findings.High + $past.Findings.Medium + $past.Findings.Low) -eq $doneScan.findingsTotal)

    # Stop from the progress window: ask while Finance is being read (after Dana's OneDrive and Archive); it stops at once, and Finance is left to do again.
    $folder2 = New-CrScan -ResultsRoot $work -Level Quick -Sites $sites -Tenant 'contoso.onmicrosoft.com'
    $stopFile = Join-Path $folder2 'stop.request'
    & $module { $script:FakeOnCall = $args[0] } { param($url) if ($url.StartsWith("$a/_api/site")) { Set-Content $stopFile 'stop' } }.GetNewClosure()
    Invoke-CrScan -Folder $folder2 3>$null 6>$null
    & $module { $script:FakeOnCall = $null }
    $view = Get-CrProgressView $folder2
    Check "stopping stops at once, saving nothing half done (got $(@(Get-ChildItem (Join-Path $folder2 'sites')).Count) sites, $($view.State))" (
        @(Get-ChildItem (Join-Path $folder2 'sites')).Count -eq 2 -and $view.State -eq 'Cancelled' -and $view.CanCarryOn -and -not (Test-Path $stopFile))
    Check 'the stopped scan is saved as stopped' ((Get-Content (Join-Path $folder2 'scan.json') -Raw | ConvertFrom-Json).status -eq 'Cancelled')
    # Stopped in the middle of a big library: the site keeps its place, and continuing picks up at the next page, not the first.
    & $module { $script:CheckpointSeconds = 0 }
    $folder5 = New-CrScan -ResultsRoot $work -Level Deep -Sites @($sites | Where-Object url -EQ $a) -Tenant 'contoso.onmicrosoft.com'
    $stop5 = Join-Path $folder5 'stop.request'
    & $module { $script:FakeOnCall = $args[0] } { param($url) if ($url.EndsWith("lists(guid'L1')/items?page=2")) { Set-Content $stop5 'stop' } }.GetNewClosure()
    Invoke-CrScan -Folder $folder5 3>$null 6>$null
    & $module { $script:FakeOnCall = $null }
    $place = Join-Path $folder5 "partial\$(Get-CrSiteKey 'contoso.sharepoint.com,a,1').json"
    $saved = if (Test-Path $place) { Read-CrJson $place } else { $null }
    Check "a site stopped partway keeps its place (got $(if ($saved) { "next $($saved.current.walk.next), walked $($saved.current.walk.walked)" } else { 'no file' }))" (
        $saved -and $saved.current.libraryId -eq 'L1' -and $saved.current.walk.next -like "*items?page=2" -and $saved.current.walk.walked -eq 3 -and
        -not (Get-ChildItem (Join-Path $folder5 'sites') -Filter '*.json'))
    $script:calls.Clear()
    Invoke-CrScan -Folder $folder5 3>$null 6>$null
    Check 'continuing picks up at the next page, not the first' (
        @($script:calls | Where-Object { $_ -like "*lists(guid'L1')/items?page=2" }).Count -eq 1 -and -not ($script:calls | Where-Object { $_ -like "*lists(guid'L1')/items?`$select*" }) -and
        -not ($script:calls | Where-Object { $_ -like "*lists(guid'L1')/items(1)/RoleAssignments*" }))
    $resumed = Read-CrJson (Join-Path $folder5 'sites.json')
    $resumedRules = @(Read-CrJson (Join-Path $folder5 'findings.json') | ForEach-Object rule | Sort-Object) -join ','
    Check "the site picked up partway finds exactly what a whole run finds (got $resumedRules; unique $($resumed.uniqueItemCount))" (
        $resumedRules -eq $expectFinance -and $resumed.uniqueItemCount -eq 3 -and @(Import-Csv (Join-Path $folder5 'unique-permissions.csv')).Count -eq 3)
    Check 'its place is cleared once the scan is done' (-not (Test-Path (Join-Path $folder5 'partial')))
    & $module { $script:CheckpointSeconds = 30 }

    # A new pace asked for from the window: shown as asked, then taken up by the scan and kept for later.
    Set-Content (Join-Path $folder2 'pace.request') 'Gentle'
    $view = Get-CrProgressView $folder2
    Check "a pace asked for shows until it is taken up (got $($view.Pace) / $($view.PaceAsked))" ($view.Pace -eq 'Normal' -and $view.PaceAsked -eq 'Gentle')
    Invoke-CrScan -Folder $folder2 3>$null 6>$null
    $view = Get-CrProgressView $folder2
    Check 'continuing after a stop finishes it' ($view.State -eq 'Completed')
    Check "the scan takes up the new pace and keeps it (got $($view.Pace), scope $((Read-CrJson (Join-Path $folder2 'scope.json')).pace))" (
        $view.Pace -eq 'Gentle' -and -not $view.PaceAsked -and (Read-CrJson (Join-Path $folder2 'scope.json')).pace -eq 'Gentle' -and
        -not (Test-Path (Join-Path $folder2 'pace.request')) -and $view.About -like '*at Gentle pace*')

    # A scan running in another process: found, not started twice, and followed by the window.
    $many = @(1..10 | ForEach-Object { [pscustomobject]@{ siteId = "contoso.sharepoint.com,s$_,1"; url = "$sp/sites/s$_"; title = "S$_"; kind = 'SharePoint' } })
    $folder3 = New-CrScan -ResultsRoot $work -Level Standard -Sites $many -Tenant 'contoso.onmicrosoft.com'
    $other = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList '-NoProfile', '-Command', 'Start-Sleep 60' -WindowStyle Hidden -PassThru
    try {
        $now = [DateTimeOffset]::UtcNow
        $inProgress = [pscustomobject]@{ url = "$sp/sites/s6"; title = 'S6'; kind = 'SharePoint'; since = $now.AddMinutes(-2).UtcDateTime.ToString('o')
            doing = 'Checking items'; library = 'Documents'; libraryNumber = 2; libraryCount = 3; libraryItemsDone = 400; libraryItems = 1000
            itemsDone = 1500; items = 3000; walkSince = $now.AddSeconds(-100).UtcDateTime.ToString('o') }
        Write-CrProgress -Folder $folder3 -State Running -Total 10 -Done 5 -DoneAtStart 0 -Current @($inProgress) -RunStartedAt $now.AddMinutes(-10) -Process $other
        Check 'a scan running elsewhere is found' ((Test-CrScanRunning $folder3) -and (Get-CrRunningScan $work -Tenant 'contoso.onmicrosoft.com') -eq $folder3 -and -not (Get-CrRunningScan $work -Tenant 'fabrikam.onmicrosoft.com'))
        $refused = $false
        try { Invoke-CrScan -Folder $folder3 } catch { $refused = $_.Exception.Message -like '*already running*' }
        Check 'a running scan is not started twice' $refused
        $view = Get-CrProgressView $folder3 -Now $now
        Check "running view (got '$($view.Status)' / '$($view.Extra)' / '$($view.Current | ConvertTo-Json -Compress)' / $($view.Percent))" (
            $view.State -eq 'Running' -and $view.Status -eq '5 of 10 sites done, about 8 minutes left' -and $view.Extra -eq 'Running for 10 minutes' -and
            $view.Current[0].Site -eq 'S6' -and $view.Current[0].Doing -eq '2 of 3 libraries and lists: Documents' -and $view.Current[0].HowFar -eq '400 of 1,000 items' -and
            $view.Current[0].Time -eq '2 minutes so far, about 2 minutes left' -and $view.Percent -eq 55 -and $view.CanStop -and -not $view.CanCarryOn)

        # Microsoft asked the scan to wait: the window says so, and for how long.
        $p = Get-Content (Join-Path $folder3 'progress.json') -Raw | ConvertFrom-Json -DateKind String
        $p.pausedUntil = $now.AddSeconds(40).UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        $p.waits = 3
        $p | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $folder3 'progress.json')
        $view = Get-CrProgressView $folder3 -Now $now
        Check "paused view (got '$($view.Status)' / '$($view.Extra)')" (
            $view.Status -like '5 of 10 sites done. Microsoft asked the scan to slow down*starts again in ?? seconds.' -and $view.Extra -like '*Microsoft has asked it to wait 3 times')
    }
    finally {
        Stop-Process -Id $other.Id -Force -ErrorAction SilentlyContinue
        $other.WaitForExit()
    }
    $view = Get-CrProgressView $folder3
    Check "a scan whose process ended is lost, and can continue (got $($view.State))" ($view.State -eq 'Lost' -and $view.CanCarryOn -and -not (Test-CrScanRunning $folder3))

    # The Tenant tab: settings in plain words, the risky ones marked, ones a tenant lacks left out.
    $tenantValues = [ordered]@{
            SharingCapability = 'ExternalUserAndGuestSharing'; OneDriveSharingCapability = 'Disabled'; DefaultSharingLinkType = 'Internal'; CoreDefaultShareLinkScope = 'Uninitialized'
            DefaultLinkPermission = 'View'; RequireAnonymousLinksExpireInDays = -1; CoreOrganizationSharingLinkMaxExpirationInDays = 90
            ExternalUserExpirationRequired = $false; ExternalUserExpireInDays = 60; ShowEveryoneExceptExternalUsersClaim = $true; RestrictedSearchMode = 'Enabled'
        }
    $tenantView = Get-CrTenantSettingsView $tenantValues
    $rowOf = { param($name) @($tenantView.Rows) | Where-Object Name -EQ $name }
    Check 'tenant: Anyone links that never expire are marked' ((& $rowOf '"Anyone" links expire').State -eq 'Watch' -and (& $rowOf '"Anyone" links expire').Value -eq 'Never')
    Check 'tenant: a company-wide link limit is good' ((& $rowOf 'Company-wide links expire').Value -eq 'After 90 days' -and (& $rowOf 'Company-wide links expire').State -eq 'Good')
    Check 'tenant: a company-wide default link is marked' ((& $rowOf 'Link people get by default').Value -eq 'People in your organization' -and (& $rowOf 'Link people get by default').State -eq 'Watch')
    Check 'tenant: guests that never expire, and Everyone except external users, are marked' ((& $rowOf 'Guest access expires').State -eq 'Watch' -and (& $rowOf '"Everyone except external users" can be picked when sharing').State -eq 'Watch')
    Check 'tenant: settings it lacks are left out' (-not (& $rowOf 'Company-wide links in OneDrive expire') -and -not (& $rowOf 'Sensitivity labels for files in SharePoint and OneDrive'))
    $withLinks = Get-CrTenantSettingsView $tenantValues -SharePointUrl 'https://contoso.sharepoint.com/sites/x'
    $linked = @($withLinks | ForEach-Object Rows)
    Check 'tenant: every setting links to Microsoft''s guide' (-not @($linked | Where-Object { -not @($_.Links | Where-Object Text -EQ 'Microsoft''s guide').Count }).Count)
    Check 'tenant: every setting says where to find it' (-not @($linked | Where-Object { -not $_.Where }).Count)
    Check 'tenant: every picture named is in the pictures folder' (-not @($linked | Where-Object { $_.Picture -and -not (Test-Path $_.Picture) }).Count -and @($linked | Where-Object Picture).Count -ge 5)
    Check 'tenant: every setting says what we recommend' (-not @($linked | Where-Object { -not $_.Recommended }).Count)
    Check 'tenant: every link has an icon' (-not @($linked | ForEach-Object Links | Where-Object { -not $_.Icon }).Count)
    Check 'tenant: every link is a web address' (-not @($linked | ForEach-Object Links | Where-Object { $_.Url -notmatch '^https://' }).Count)
    Check 'tenant: admin center links go to this tenant''s admin center' ((@($linked | ForEach-Object Links | Where-Object Text -EQ 'Open the SharePoint admin center').Url | Sort-Object -Unique) -like 'https://contoso-admin.sharepoint.com/*')
    Check 'tenant: without a SharePoint address there are no admin center links' (-not @($tenantView | ForEach-Object Rows | ForEach-Object Links | Where-Object Text -EQ 'Open the SharePoint admin center').Count)
    # The PowerShell to change a setting, for SPO and PnP, ready to copy.
    Check 'tenant: no button just points at a PowerShell page any more' (-not @($linked | ForEach-Object Links | Where-Object Text -EQ 'The PowerShell command').Count)
    $commandValues = [ordered]@{ CoreOrganizationSharingLinkMaxExpirationInDays = 0; OneDriveOrganizationSharingLinkMaxExpirationInDays = 0; OneDriveDefaultShareLinkScope = 'Organization'; ShowEveryoneExceptExternalUsersClaim = $true; ShowEveryoneClaim = $true; DisableDocumentLibraryDefaultLabeling = $true; RestrictedSearchMode = 'Enabled'; ODBMembersCanShare = 'On'; SharingCapability = 'Disabled' }
    $commandRows = @((Get-CrTenantSettingsView $commandValues -SharePointUrl 'https://contoso.sharepoint.com') | ForEach-Object Rows)
    $withCommands = @($commandRows | Where-Object { @($_.Commands).Count })
    Check "tenant: every setting with no admin center page has its commands (got $($withCommands.Count))" ($withCommands.Count -eq 8)
    Check 'tenant: each has SPO and PnP' (-not @($withCommands | Where-Object { (@($_.Commands.Tool) -join ',') -ne 'SPO,PnP' }).Count)
    Check 'tenant: PnP says how to set up a client ID, and SPO needs none' (-not @($withCommands | Where-Object { $_.Commands[1].Help.Url -notmatch '^https://pnp\.github\.io/' -or -not $_.Commands[1].Help.Icon -or $_.Commands[0].Help }).Count)
    Check 'tenant: SPO commands only use SPO, and PnP only PnP' (-not @($withCommands | ForEach-Object Commands | Where-Object { ($_.Tool -eq 'SPO' -and $_.Text -match '-PnP|PnPOnline') -or ($_.Tool -eq 'PnP' -and $_.Text -match '-SPO|SPOService') }).Count)
    Check 'tenant: the commands name this tenant''s admin center' (-not @($withCommands | ForEach-Object Commands | Where-Object { $_.Text -notmatch '-Url https://contoso-admin\.sharepoint\.com' }).Count)
    Check 'tenant: without a SharePoint address they say where to put the tenant' ((@((Get-CrTenantSettingsView $commandValues) | ForEach-Object Rows | Where-Object Name -Like 'People with edit*')[0].Commands[0].Text) -match 'https://<tenant>-admin\.sharepoint\.com')
    $reshare = { param($v) @((Get-CrTenantSettingsView ([ordered]@{ ODBMembersCanShare = $v })) | ForEach-Object Rows | Where-Object Name -Like 'People with edit*')[0] }
    Check 'tenant: edit access can reshare in OneDrive is marked' ((& $reshare 'On').State -eq 'Watch' -and (& $reshare 'On').Value -eq 'Yes')
    Check 'tenant: each owner deciding is marked too' ((& $reshare 'Unspecified').State -eq 'Watch' -and (& $reshare 'Unspecified').Value -like 'Each*')
    Check 'tenant: only the owner sharing is good' ((& $reshare 'Off').State -eq 'Good')
    Check 'tenant: the reshare commands match what was asked for' ((& $reshare 'On').Commands[0].Text -match 'Get-SPOTenant \| Select-Object ODBMembersCanShare' -and (& $reshare 'On').Commands[0].Text -match 'Set-SPOTenant -ODBMembersCanShare Off' -and (& $reshare 'On').Commands[1].Text -match '\(Get-PnPTenant\)\.ODBMembersCanShare' -and (& $reshare 'On').Commands[1].Text -match 'Set-PnPTenant -ODBMembersCanShare Off')
    Check 'tenant: undo puts back what this tenant has now' ((& $reshare 'Unspecified').Commands[1].Text -match '(?m)^# Set-PnPTenant -ODBMembersCanShare Unspecified' -and (& $reshare 'On').Commands[0].Text -match '(?m)^# Set-SPOTenant -ODBMembersCanShare On')
    # Pasting a whole block makes the change and leaves it made.
    $blocks = @($withCommands | ForEach-Object Commands)
    Check 'tenant: each block makes one change, and the undo is only a note' (-not @($blocks | Where-Object { @([regex]::Matches($_.Text, '(?m)^Set-')).Count -ne 1 }).Count)
    $spoBroken = @($blocks | Where-Object Tool -EQ 'SPO' | Where-Object { $errors = $null; $null = [System.Management.Automation.Language.Parser]::ParseInput($_.Text, [ref]$null, [ref]$errors); @($errors).Count })
    Check "tenant: every SPO block can be pasted as it is (got $($spoBroken.Count) that can't)" (-not $spoBroken.Count)
    # A setting that's already right offers nothing that could make it worse.
    Check 'tenant: only the owner sharing offers no commands' (-not @((& $reshare 'Off').Commands).Count)
    Check 'tenant: and says nothing needs changing, as there is no button' ((& $reshare 'Off').Where -like "*doesn't need changing now*" -and (& $reshare 'On').Where -notlike '*need changing*')
    Check 'tenant: SPO says what to do if its module is too old' ((& $reshare 'On').Commands[0].Caption -like '*Update-Module Microsoft.Online.SharePoint.PowerShell*')
    $stricter = @((Get-CrTenantSettingsView ([ordered]@{ CoreOrganizationSharingLinkMaxExpirationInDays = 30 })) | ForEach-Object Rows)[0]
    Check 'tenant: links already expiring sooner than 90 days offer no commands' ($stricter.State -eq 'Good' -and -not @($stricter.Commands).Count)
    $noLimit = @((Get-CrTenantSettingsView ([ordered]@{ CoreOrganizationSharingLinkMaxExpirationInDays = 0 })) | ForEach-Object Rows)[0]
    Check 'tenant: links with no limit offer 90 days, and undo goes back to no limit' ($noLimit.Commands[1].Text -match '(?m)^Set-PnPTenant -CoreOrganizationSharingLinkMaxExpirationInDays 90' -and $noLimit.Commands[1].Text -match '(?m)^# Set-PnPTenant -CoreOrganizationSharingLinkMaxExpirationInDays 0')
    $search = { param($v) @((Get-CrTenantSettingsView ([ordered]@{ RestrictedSearchMode = $v })) | ForEach-Object Rows)[0] }
    Check 'tenant: Restricted Search that is on can be turned off, with no undo offered' ((& $search 'Enabled').Commands[0].Text -match 'Set-SPOTenantRestrictedSearchMode -Mode Disabled' -and (& $search 'Enabled').Commands[1].Text -match 'Set-PnPTenantRestrictedSearchMode -Mode Disabled' -and (& $search 'Enabled').Commands[0].Text -notmatch 'To undo')
    Check 'tenant: Restricted Search that is off shows no commands' (-not @((& $search 'Disabled').Commands).Count)
    $groupsOf = Get-CrTenantSettingsView ([ordered]@{ SharingCapability = 'Disabled'; ODBMembersCanShare = 'On'; DefaultLinkPermission = 'Edit'; ExternalUserExpirationRequired = $false; RestrictedSearchMode = 'Disabled'; OneDriveSharingCapability = 'ExternalUserSharingOnly' })
    Check 'tenant: settings come in the groups the tabs show' ((@($groupsOf.Name) -join ',') -eq 'Who can share,Links,Guests,Copilot and search')
    Check 'tenant: each setting is in its group' ((@($groupsOf | Where-Object Name -EQ 'Who can share').Rows.Name -contains 'People with edit access can reshare in OneDrive') -and (@($groupsOf | Where-Object Name -EQ 'Links').Rows.Name -contains 'Default link lets people') -and (@($groupsOf | Where-Object Name -EQ 'Guests').Rows.Name -contains 'Guest access expires'))
    $spansOf = { param($text) @(Get-CrCodeSpans $text | ForEach-Object { "$($_.Kind):$($text.Substring($_.Start, $_.Length))" }) -join '|' }
    Check 'code colours: a comment is all one colour' ((& $spansOf "# Only the OneDrive's owner can share") -eq "Comment:# Only the OneDrive's owner can share")
    $got = & $spansOf 'Set-PnPTenant -ODBMembersCanShare Off'
    Check "code colours: command, option and value (got $got)" ($got -eq 'Command:Set-PnPTenant|Option:-ODBMembersCanShare|Value:Off')
    $got = & $spansOf 'Connect-PnPOnline -Url https://contoso-admin.sharepoint.com -Interactive -ClientId <your-app-client-id>'
    Check "code colours: an address and something to fill in are values (got $got)" ($got -eq 'Command:Connect-PnPOnline|Option:-Url|Value:https://contoso-admin.sharepoint.com|Option:-Interactive|Option:-ClientId|Value:<your-app-client-id>')
    $got = & $spansOf "Set-SPOTenant -ShowEveryoneClaim `$false`n(Get-PnPTenant).ShowEveryoneClaim`nGet-SPOTenant | Select-Object ShowEveryoneClaim"
    Check "code colours: true or false, and later lines (got $got)" ($got -eq 'Command:Set-SPOTenant|Option:-ShowEveryoneClaim|Variable:$false|Command:Get-PnPTenant|Command:Get-SPOTenant|Command:Select-Object')
    # Longer than we recommend isn't good, whatever the setting.
    $lasting = @(Get-CrTenantSettingsView ([ordered]@{ SharingCapability = 'ExternalUserAndGuestSharing'; RequireAnonymousLinksExpireInDays = 365; CoreOrganizationSharingLinkMaxExpirationInDays = 365; OneDriveOrganizationSharingLinkMaxExpirationInDays = 91; ExternalUserExpirationRequired = $true; ExternalUserExpireInDays = 365 }) | ForEach-Object Rows)
    $stateOf = { param($name) @($lasting | Where-Object Name -EQ $name)[0].State }
    Check 'tenant: links and guests lasting longer than recommended are marked' ((& $stateOf '"Anyone" links expire') -eq 'Watch' -and (& $stateOf 'Company-wide links expire') -eq 'Watch' -and (& $stateOf 'Company-wide links in OneDrive expire') -eq 'Watch' -and (& $stateOf 'Guest access expires') -eq 'Watch')
    Check 'tenant: and company-wide links offer to lower it, with undo to what it is now' (@($lasting | Where-Object Name -EQ 'Company-wide links expire')[0].Commands[1].Text -match '(?m)^# Set-PnPTenant -CoreOrganizationSharingLinkMaxExpirationInDays 365')
    $atLimit = @(Get-CrTenantSettingsView ([ordered]@{ SharingCapability = 'ExternalUserAndGuestSharing'; RequireAnonymousLinksExpireInDays = 30; ExternalUserExpirationRequired = $true; ExternalUserExpireInDays = 60 }) | ForEach-Object Rows)
    Check 'tenant: right at what we recommend is good' (@($atLimit | Where-Object Name -EQ '"Anyone" links expire')[0].State -eq 'Good' -and @($atLimit | Where-Object Name -EQ 'Guest access expires')[0].State -eq 'Good')
    Check 'tenant: "Anyone" links that are turned off aren''t marked for lasting long' (@(Get-CrTenantSettingsView ([ordered]@{ SharingCapability = 'Disabled'; RequireAnonymousLinksExpireInDays = 365 }) | ForEach-Object Rows | Where-Object Name -EQ '"Anyone" links expire')[0].State -eq 'Good')
    Check 'tenant: the 90-day limit in the card, its advice and its command all match' (@($lasting | Where-Object Name -EQ 'Company-wide links expire')[0].Recommended -like '*90 days*' -and @($lasting | Where-Object Name -EQ 'Company-wide links expire')[0].Advice -like '*90 days*' -and @($lasting | Where-Object Name -EQ 'Company-wide links expire')[0].Commands[1].Text -match 'InDays 90')
    $noRole = @(Get-CrTenantSettingsView ([ordered]@{ DefaultLinkPermission = 'None' }) | ForEach-Object Rows)[0]
    Check 'tenant: a default permission nobody chose says so, and isn''t marked good' ($noRole.Value -eq "Microsoft's default" -and $noRole.State -eq 'Info')
    Check 'tenant: newer link settings win once set' ((@((Get-CrTenantSettingsView ([ordered]@{ DefaultSharingLinkType = 'Internal'; CoreDefaultShareLinkScope = 'SpecificPeople' })).Rows) | Where-Object Name -EQ 'Link people get by default').Value -eq 'Specific people')}
catch {
    $problems.Add("threw: $($_.Exception.Message) at $($_.InvocationInfo.PositionMessage)")
}
finally {
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}

if ($problems.Count) {
    Write-Host "$($problems.Count) offline scan checks failed" -ForegroundColor Red
    $problems | ForEach-Object { Write-Host "  FAIL $_" }
    exit 1
}
Write-Host 'Offline scan checks passed' -ForegroundColor Green
