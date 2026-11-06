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

    $saved = Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json
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
            $others += [pscustomobject][ordered]@{ tenant = $Settings.tenant; sharePointUrl = $Settings.sharePointUrl; clientId = $Settings.app.clientId; thumbprint = $Settings.app.thumbprint }
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
