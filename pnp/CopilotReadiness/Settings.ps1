# settings.json: which tenant, which app signs in, and how to scan by default.
# Start.ps1 writes it during setup; people can edit it by hand afterwards.

function New-CrSettings {
    <# Settings with every field present and nothing filled in yet. #>
    [pscustomobject][ordered]@{
        tenant        = ''
        sharePointUrl = ''
        app           = [pscustomobject][ordered]@{
            name       = 'Copilot Readiness Scanner (PnP)'
            clientId   = ''
            thumbprint = ''
            createdAt  = ''
        }
        # Tenants set up on this PC before, each with its own app, so switching back needs no new setup.
        otherTenants  = @()
        scan          = [pscustomobject][ordered]@{
            level         = 'Quick'
            include       = 'SharePoint'
            sites         = @()
            staleDays     = (Get-CrRuleBook).thresholds.staleDays
            resultsFolder = 'results'
            # The same path as resultsFolder when it was carried over from an older copy of the program (Restore-CrRememberedSetup).
            resultsCarried = ''
            # Gentle, Normal or Fast: how hard a scan works the tenant (Get-CrPaces).
            pace          = 'Normal'
        }
    }
}

function Read-CrSettings {
    <# Reads settings.json, filling in any field it doesn't have. A missing file gives empty settings. #>
    param([Parameter(Mandatory)] [string] $Path)
    $settings = New-CrSettings
    if (-not (Test-Path -LiteralPath $Path)) { return $settings }

    # Dates stay as written: read as dates, they lose their time zone, and how old an app is comes out hours wrong.
    $saved = Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json -DateKind String
    foreach ($p in $saved.PSObject.Properties) {
        if ($p.Name -in 'app', 'scan' -and $p.Value) {
            foreach ($inner in $p.Value.PSObject.Properties) { $settings.($p.Name) | Add-Member -NotePropertyName $inner.Name -NotePropertyValue $inner.Value -Force }
        }
        else {
            $settings | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force
        }
    }
    $settings.scan.sites = @($settings.scan.sites | Where-Object { $_ })
    $settings.otherTenants = @($settings.otherTenants | Where-Object { $_.tenant })
    $settings
}

function Save-CrSettings {
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] $Settings)
    $Settings | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Path -Encoding utf8
}

function Get-CrRememberedSetupPath {
    <#
      Where this Windows account remembers its setup, outside any one copy of the program, so
      that a newer version unzipped to a new folder can pick it up. It holds what settings.json
      holds: tenant names, app IDs and certificate thumbprints. No keys or passwords.
    #>
    param([string] $Root = $env:LOCALAPPDATA)
    if (-not $Root) { return $null }
    Join-Path $Root 'CopilotReadiness\setup.json'
}

function Get-CrNewestScanName {
    <# The newest scan's folder name in a results folder, or nothing. Their names start with when they started, so they sort by time. #>
    param([Parameter(Mandatory)] [string] $Folder)
    @(Get-ChildItem -LiteralPath $Folder -Directory -ErrorAction SilentlyContinue | Where-Object Name -Match '^\d{8}T\d{6}-' | ForEach-Object Name | Sort-Object -Descending) | Select-Object -First 1
}

function New-CrTenantEntry {
    <# The current tenant as it's kept under otherTenants: its name, address and app. #>
    param([Parameter(Mandatory)] $Settings)
    [pscustomobject][ordered]@{ tenant = $Settings.tenant; sharePointUrl = $Settings.sharePointUrl; clientId = $Settings.app.clientId; thumbprint = $Settings.app.thumbprint }
}

function Merge-CrRememberedTenants {
    <#
      Puts what's remembered in Before over the other tenants in Copy. Only the current tenant is
      known to be up to date in a copy, because it was just used. So running an older copy once
      doesn't lose a tenant added since, or bring back a certificate that's been replaced, or blank
      a working app. The current tenant with no app means it was removed, and it's forgotten.
    #>
    param([Parameter(Mandatory)] $Copy, [Parameter(Mandatory)] $Before)
    $kept = @(@(New-CrTenantEntry $Before) + @($Before.otherTenants) | Where-Object { $_.tenant -and $_.clientId -and $_.tenant -ne $Copy.tenant })
    $keptNames = @($kept | ForEach-Object tenant)
    $Copy.otherTenants = @(@($Copy.otherTenants | Where-Object { $keptNames -notcontains $_.tenant }) + $kept)
}

function Select-CrRememberedResults {
    <#
      Which results folder to remember. A copy on its own results folder, or on ones carried over,
      only replaces remembered results once it has a newer scan than they do, or with TakeOver: the
      person chose it. Remembered results it can't see stay remembered, as they may only be unplugged;
      the next version asks. They're only looked for if there's a newer scan to offer, as a share
      that isn't answering takes a while to say so.
    #>
    param([Parameter(Mandatory)] $Settings, [Parameter(Mandatory)] [string] $ResultsFolder, [string] $Remembered, [switch] $TakeOver, [Parameter(Mandatory)] [scriptblock] $Exists)
    $folder = "$($Settings.scan.resultsFolder)"
    $carried = "$($Settings.scan.resultsCarried)"
    # Otherwise the folder was set on purpose: by hand, or by moving away from carried results.
    $notChosen = if ($carried) { $carried -eq $folder } else { -not [IO.Path]::IsPathRooted($folder) }
    if ($TakeOver -or -not $Remembered -or $Remembered -eq $ResultsFolder -or -not $notChosen) { return $ResultsFolder }
    $ownNewest = Get-CrNewestScanName $ResultsFolder
    if (-not $ownNewest -or -not (& $Exists $Remembered)) { return $Remembered }
    if ($ownNewest -gt (Get-CrNewestScanName $Remembered)) { $ResultsFolder } else { $Remembered }
}

function Save-CrRememberedSetup {
    <#
      Remembers these settings for the next version, with where the results are kept as a full
      path so it carries on using them, and the rule book's stale-site limit, to tell later whether
      this one was only the default. With no app left to remember, it forgets instead; if it can't,
      it says so. The file only changes when there's something new, and is never left half written.
    #>
    param(
        [Parameter(Mandatory)] $Settings,
        [Parameter(Mandatory)] [string] $ResultsFolder,
        [string] $Path = (Get-CrRememberedSetupPath),
        [switch] $TakeOver,
        [scriptblock] $Exists = { param($path) Test-Path -LiteralPath $path }
    )
    if (-not $Path) { return }
    $copy = $Settings | ConvertTo-Json -Depth 5 | ConvertFrom-Json -DateKind String
    # A file that can't be opened right now is left alone and this says so. One that opens but makes no sense is replaced.
    $before = if (Test-Path -LiteralPath $Path) {
        $null = [IO.File]::ReadAllBytes($Path)
        try { Read-CrSettings $Path } catch { $null }
    }
    if ($before) {
        Merge-CrRememberedTenants -Copy $copy -Before $before
        $ResultsFolder = Select-CrRememberedResults -Settings $Settings -ResultsFolder $ResultsFolder -Remembered "$($before.scan.resultsFolder)" -TakeOver:$TakeOver -Exists $Exists
    }
    if (-not $copy.app.clientId -and -not @($copy.otherTenants | Where-Object { $_.clientId }).Count) {
        if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force -ErrorAction Stop }
        return
    }
    $copy.scan.resultsFolder = $ResultsFolder
    $copy.scan | Add-Member -NotePropertyName staleDaysDefault -NotePropertyValue (Get-CrRuleBook).thresholds.staleDays -Force
    $now = ConvertTo-Json -InputObject $copy -Depth 20
    if ((Test-Path -LiteralPath $Path) -and "$(Get-Content -LiteralPath $Path -Raw -Encoding utf8)".Trim() -ceq $now.Trim()) { return }
    New-Item -ItemType Directory -Path (Split-Path $Path) -Force | Out-Null
    Write-CrJson $Path $copy
}

function Test-CrCertificateUsable {
    <# Whether a certificate can sign in: it's there, has its private key and hasn't expired. #>
    param($Certificate)
    [bool]($Certificate -and $Certificate.HasPrivateKey -and $Certificate.NotAfter -gt (Get-Date))
}

function Restore-CrRememberedSetup {
    <#
      A copy of the program with no settings.json of its own takes the remembered setup: every
      tenant, and where the results are, so it uses the same apps and certificates with nothing
      to set up. A tenant whose app or certificate has gone from this PC is the only one that
      needs setting up again: its app is cleared, so that happens by itself when it's chosen.
      If that's the last-used tenant, this starts on another that still works. A stale-site limit
      that was only the old rule book's default follows the new rule book. Returns Tenant and
      Ready (whether that tenant can sign in now), or nothing if there's nothing to restore. A remembered setup that can't be read throws, so the caller can say so.
    #>
    param(
        [Parameter(Mandatory)] [string] $SettingsPath,
        [string] $Path = (Get-CrRememberedSetupPath),
        [scriptblock] $HasCertificate = { param($thumbprint) Test-CrCertificateUsable (Get-Item -LiteralPath "Cert:\CurrentUser\My\$thumbprint" -ErrorAction SilentlyContinue) }
    )
    if ((Test-Path -LiteralPath $SettingsPath) -or -not $Path -or -not (Test-Path -LiteralPath $Path)) { return }
    $saved = Read-CrSettings $Path
    if (-not $saved.tenant) { return }
    if ($saved.scan.PSObject.Properties['staleDaysDefault']) {
        if ("$($saved.scan.staleDays)" -eq "$($saved.scan.staleDaysDefault)") { $saved.scan.staleDays = (Get-CrRuleBook).thresholds.staleDays }
        $saved.scan.PSObject.Properties.Remove('staleDaysDefault')
    }
    $works = { param($clientId, $thumbprint) [bool]($clientId -and $thumbprint -and (& $HasCertificate "$thumbprint")) }
    if (-not (& $works $saved.app.clientId $saved.app.thumbprint)) {
        $other = @($saved.otherTenants | Where-Object { & $works $_.clientId $_.thumbprint }) | Select-Object -First 1
        if ($other) { Set-CrTenant $saved $other.tenant }
    }
    if (-not (& $works $saved.app.clientId $saved.app.thumbprint)) { $saved.app.clientId = ''; $saved.app.thumbprint = '' }
    foreach ($o in @($saved.otherTenants)) {
        if (-not (& $works $o.clientId $o.thumbprint)) { $o.clientId = ''; $o.thumbprint = '' }
    }
    if ([IO.Path]::IsPathRooted("$($saved.scan.resultsFolder)")) { $saved.scan.resultsCarried = "$($saved.scan.resultsFolder)" }
    Save-CrSettings $SettingsPath $saved
    [pscustomobject]@{ Tenant = "$($saved.tenant)"; Ready = [bool]$saved.app.clientId }
}

function Get-CrCarriedResults {
    <# The results folder in use that was carried over from an older copy of the program, or nothing. #>
    param([Parameter(Mandatory)] $Settings)
    $carried = "$($Settings.scan.resultsCarried)"
    if ($carried -and $carried -eq "$($Settings.scan.resultsFolder)") { $carried }
}

function Get-CrMissingResults {
    <#
      The results folder carried over from an older copy of the program, if it can't be found. It
      may have been deleted, or be on a drive that isn't connected, or behind a share that's not
      answering, and nothing here can tell which, so this only reports it. Start.ps1 asks. A results
      folder set by hand is left alone, and is created as usual.
    #>
    param([Parameter(Mandatory)] $Settings, [scriptblock] $Exists = { param($path) Test-Path -LiteralPath $path })
    $carried = Get-CrCarriedResults -Settings $Settings
    if ($carried -and -not (& $Exists $carried)) { $carried }
}

function Set-CrOwnResults {
    <# Goes back to this copy's own results folder, once the person has said to. The caller saves the settings. #>
    param([Parameter(Mandatory)] $Settings)
    $Settings.scan.resultsFolder = 'results'
    $Settings.scan.resultsCarried = ''
}

function ConvertTo-CrTenantName {
    <#
      contoso -> contoso.onmicrosoft.com; a name with a dot is kept as it is. A pasted
      SharePoint address works too, any of its sites or the admin or OneDrive one:
      https://contoso.sharepoint.com/sites/x -> contoso.onmicrosoft.com.
    #>
    param([string] $Tenant)
    $Tenant = "$Tenant".Trim().Trim('"', "'")
    if ($Tenant -match '^(?:https?://)?([a-z0-9][a-z0-9-]*?)(?:-admin|-my)?\.sharepoint\.(?:com|us|de|cn)(?:[/:?#]|$)') { return "$($Matches[1].ToLowerInvariant()).onmicrosoft.com" }
    if ($Tenant -match '^https?://([^/]+)') { $Tenant = $Matches[1] }
    if ($Tenant -and $Tenant -notmatch '\.') { "$Tenant.onmicrosoft.com" } else { $Tenant }
}

function Get-CrTenantFileName {
    <# A tenant's name as it goes into a file name: contoso.onmicrosoft.com stays, anything odd becomes _. #>
    param([Parameter(Mandatory)] [string] $Tenant)
    $Tenant -replace '[^A-Za-z0-9.-]', '_'
}

function ConvertTo-CrDictionary {
    <# Name -> value, whether it comes as a dictionary or as an object read back from JSON. #>
    param($Value)
    if ($Value -is [System.Collections.IDictionary]) { return $Value }
    $d = [ordered]@{}
    if ($Value) { foreach ($p in $Value.PSObject.Properties) { $d[$p.Name] = $p.Value } }
    $d
}

function Get-CrKeptCopy {
    <#
      Something read from the tenant and kept in a file (in the results folder), so it isn't
      read every time the window opens. The saved copy is used while it is younger than
      MaxAgeDays (0: until -Refresh); otherwise Read runs and its answer is saved. If Read fails
      and there is a saved copy, that copy is used however old, with Problem saying why; with no
      saved copy, the error is thrown. Returns Value (as Read gave it, or as saved), ReadAt and Problem.
      OldKey names where an earlier version of this app kept the value in the file, so copies saved
      then still count. A fresh answer that can't be saved is still used.
    #>
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [scriptblock] $Read, [int] $MaxAgeDays = 0, [switch] $Refresh, [string] $OldKey)
    $saved = $null
    if (Test-Path -LiteralPath $Path) {
        try {
            $file = Read-CrJson $Path
            $value = if ($null -ne $file.value) { $file.value } elseif ($OldKey -and $file.PSObject.Properties[$OldKey]) { $file.$OldKey }
            if ($null -ne $value) {
                $saved = [pscustomobject]@{ Value = $value; ReadAt = [DateTimeOffset]::Parse($file.readAt, [Globalization.CultureInfo]::InvariantCulture); Problem = $null }
            }
        }
        catch { $saved = $null }   # a copy that can't be read is read again
    }
    if ($saved -and -not $Refresh -and ($MaxAgeDays -le 0 -or $saved.ReadAt -gt [DateTimeOffset]::UtcNow.AddDays(-$MaxAgeDays))) { return $saved }
    try { $value = & $Read }
    catch {
        if ($saved) { $saved.Problem = $_.Exception.Message; return $saved }
        throw
    }
    $now = [DateTimeOffset]::UtcNow
    try {
        New-Item -ItemType Directory -Path (Split-Path $Path) -Force | Out-Null
        Write-CrJson $Path ([pscustomobject][ordered]@{ readAt = $now.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'"); value = $value })
    }
    catch { Write-Host "Couldn't save $([System.IO.Path]::GetFileName($Path)) (it will be read again next time): $($_.Exception.Message)" }
    [pscustomobject]@{ Value = $value; ReadAt = $now; Problem = $null }
}

function Get-CrTenantNames {
    <# The current tenant, then the others set up on this PC. #>
    param([Parameter(Mandatory)] $Settings)
    @(@($Settings.tenant) + @($Settings.otherTenants | ForEach-Object tenant) | Where-Object { $_ } | Select-Object -Unique)
}

function Get-CrTenantApp {
    <# The app a tenant signs in with: the current tenant's, one set up here before, or none (empty clientId and thumbprint). #>
    param([Parameter(Mandatory)] $Settings, [string] $Tenant)
    $name = ConvertTo-CrTenantName $Tenant
    if (-not $name -or $name -eq $Settings.tenant) {
        return [pscustomobject]@{ clientId = $Settings.app.clientId; thumbprint = $Settings.app.thumbprint; sharePointUrl = $Settings.sharePointUrl }
    }
    $saved = @($Settings.otherTenants | Where-Object tenant -EQ $name) | Select-Object -First 1
    if ($saved) { return [pscustomobject]@{ clientId = "$($saved.clientId)"; thumbprint = "$($saved.thumbprint)"; sharePointUrl = "$($saved.sharePointUrl)" } }
    [pscustomobject]@{ clientId = ''; thumbprint = ''; sharePointUrl = '' }
}

function Set-CrTenant {
    <#
      contoso -> contoso.onmicrosoft.com and https://contoso.sharepoint.com. Switching to
      another tenant keeps the old one's app under otherTenants and brings back the new
      one's, if it was set up on this PC before; otherwise the new one needs setting up.
    #>
    param([Parameter(Mandatory)] $Settings, [Parameter(Mandatory)] [string] $Tenant)
    $Tenant = ConvertTo-CrTenantName $Tenant
    if ($Settings.tenant -and $Settings.tenant -ne $Tenant) {
        $app = Get-CrTenantApp $Settings $Tenant
        $others = @($Settings.otherTenants | Where-Object { $_.tenant -ne $Settings.tenant -and $_.tenant -ne $Tenant })
        if ($Settings.app.clientId) {
            $others += New-CrTenantEntry $Settings
        }
        $Settings.otherTenants = @($others)
        $Settings.sharePointUrl = $app.sharePointUrl
        $Settings.app.clientId = $app.clientId
        $Settings.app.thumbprint = $app.thumbprint
    }
    $Settings.tenant = $Tenant
    if (-not $Settings.sharePointUrl) { $Settings.sharePointUrl = "https://$($Tenant.Split('.')[0]).sharepoint.com" }
    $Settings.sharePointUrl = $Settings.sharePointUrl.TrimEnd('/')
}
