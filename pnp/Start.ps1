<#
.SYNOPSIS
  Copilot Readiness: sets this PC up to scan your tenant the first time, then scans.

.DESCRIPTION
  The first run (as a Global Administrator):
    1. asks for your tenant name, unless you pass -Tenant or it's already in settings.json,
    2. installs the PnP.PowerShell module if you don't have it,
    3. creates an app registration, "Copilot Readiness Scanner (PnP)", with a certificate
       kept in your Windows certificate store. A browser window asks you to sign in and
       then to accept the app's permissions,
    4. saves all of that to settings.json next to this script.

  Every run after that goes straight to the control window: choose how deep to scan and
  which sites, then start. The scan then runs in the background, in a hidden PowerShell
  window, and a progress window shows how far along it is. Closing the progress window
  doesn't stop the scan; run this again to see it. Each site is saved as soon as it's
  done, so if a scan stops, run this again and choose "Continue".

  "Sign out" in the control window (or -ChooseTenant, or -Tenant) switches to
  another tenant. Each tenant gets its own app the first time; settings.json remembers
  them all, so switching back needs no new setup.

  The app gets these application permissions. All of them are read-only in effect; the
  scan never changes anything in SharePoint.

    SharePoint  Sites.FullControl.All                 Reading who a site, library or file is shared with
                                                       needs it; Sites.Read.All cannot see permissions.
    Graph       Sites.Read.All                         List every site in the tenant.
    Graph       GroupMember.Read.All                   Owners, guests and visibility of Microsoft 365 groups.
    Graph       InformationProtectionPolicy.Read.All   Names of sensitivity labels.

  settings.json can be edited by hand: put an existing app's clientId and thumbprint under
  "app" to use it instead of creating one, and change the default level, sites, stale-site
  limit or results folder under "scan".

.EXAMPLE
  ./Start.ps1

.EXAMPLE
  ./Start.ps1 -Tenant contoso

.EXAMPLE
  ./Start.ps1 -Level Standard -NoWindow

.EXAMPLE
  ./Start.ps1 -Level Deep -Sites https://contoso.sharepoint.com/sites/finance, https://contoso.sharepoint.com/sites/hr

.EXAMPLE
  ./Start.ps1 -Resume
#>
param(
    # Your tenant, e.g. contoso or contoso.onmicrosoft.com. Needed the first time, or to switch tenants.
    [string] $Tenant,
    # Ask which tenant to scan, as on the first run.
    [switch] $ChooseTenant,
    # Create a new app registration even though settings.json already names one (for example on a new PC).
    [switch] $Setup,
    # Scan without the window, at this level. Defaults to the level in settings.json.
    [ValidateSet('Quick', 'Standard', 'Deep')] [string] $Level,
    # Only these site addresses. Defaults to the sites in settings.json, or every site.
    [string[]] $Sites,
    # A text file of site addresses, one per line.
    [string] $SitesFile,
    # SharePoint sites, OneDrive, or Both. Defaults to what settings.json says (SharePoint unless changed).
    [ValidateSet('SharePoint', 'OneDrive', 'Both')] [string] $Include,
    # How hard to work the tenant: Gentle, Normal or Fast. Defaults to the pace in settings.json (Normal unless changed).
    [ValidateSet('Gentle', 'Normal', 'Fast')] [string] $Pace,
    # Continue the last unfinished scan.
    [switch] $Resume,
    # Don't open the window.
    [switch] $NoWindow,
    [switch] $DeviceLogin,
    [string] $SettingsPath = (Join-Path $PSScriptRoot 'settings.json'),
    # Used by the window to run a scan folder in the background; not needed by hand.
    [string] $RunScan
)

$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw "This needs PowerShell 7.5 or later (you have $($PSVersionTable.PSVersion)). Install it from https://aka.ms/powershell, then double-click Start.cmd."
}

# PnP's "newer version available" notice means nothing to the person running a scan.
$env:PNPPOWERSHELL_UPDATECHECK = 'Off'

Import-Module (Join-Path $PSScriptRoot 'CopilotReadiness\CopilotReadiness.psm1') -Force
$settings = Read-CrSettings $SettingsPath
$resultsFolder = $settings.scan.resultsFolder
if (-not [IO.Path]::IsPathRooted($resultsFolder)) { $resultsFolder = Join-Path $PSScriptRoot $resultsFolder }
$headless = $NoWindow -or $Level -or $Resume -or -not $IsWindows

# ── A scan in the background: the progress window starts this in a hidden window ──

if ($RunScan) {
    $ProgressPreference = 'SilentlyContinue'
    try {
        # The scan's own tenant, which may not be the one settings.json is on now.
        $scope = Get-Content -LiteralPath (Join-Path $RunScan 'scope.json') -Raw | ConvertFrom-Json
        Set-CrTenant $settings $scope.tenant
        Import-Module PnP.PowerShell -MinimumVersion (Get-CrPnPRequired)
        Write-Host "$(Get-Date -Format s) Signing in to $($settings.sharePointUrl)"
        Connect-CrTenant $settings
        Write-Host "$(Get-Date -Format s) Scanning $RunScan"
        Invoke-CrScan -Folder $RunScan -Settings $settings
        Write-Host "$(Get-Date -Format s) Finished"
    }
    catch {
        Write-Host "$(Get-Date -Format s) $($_.Exception.Message)"
        # The scan reports its own problems; this covers ones before it starts, such as signing in.
        if ((Read-CrProgress $RunScan).state -eq 'Starting') { Set-CrProgressState $RunScan Failed $_.Exception.Message }
        throw
    }
    return
}

$startScript = $PSCommandPath
$launch = { param($folder) Start-CrBackgroundScan -Folder $folder -StartScript $startScript -SettingsPath $SettingsPath }.GetNewClosure()
$showProgress = {
    param($folder)
    $view = Show-CrProgressWindow -Folder $folder -Launch $launch
    Write-Host ''
    if ($view.Running) { Write-Host 'The scan keeps running in the background. Double-click Start.cmd again to see how it is going.' -ForegroundColor Cyan }
    else {
        Write-Host "$($view.Heading). $($view.Status)" -ForegroundColor $(if ($view.State -eq 'Completed') { 'Green' } else { 'Yellow' })
        if ($view.Report) { Write-Host "Report: $($view.Report)" }
    }
    if ($view.Back) { Write-Host 'Going back to the main window.' }
    $view
}.GetNewClosure()

# ── System check ────────────────────────────────────────────────────────────

$getChecks = { param($typedTenant) Get-CrSystemCheck -Settings $settings -ResultsFolder $resultsFolder -Tenant $(if ($typedTenant) { $typedTenant } else { $Tenant }) }.GetNewClosure()

# The check always runs. Its window only appears on a first run, when asked to choose a
# tenant, or when something needs fixing; otherwise warnings (such as a certificate
# expiring soon) are just printed.
$checks = & $getChecks $null
$askTenant = (-not $Tenant -and -not $settings.tenant) -or ($ChooseTenant -and -not $Tenant)
$blocked = @($checks | Where-Object State -In 'Problem', 'Fixable').Count

if (-not $headless -and ($askTenant -or $blocked)) {
    $ready = Show-CrCheckWindow -GetChecks $getChecks -AskTenant:$askTenant -Tenants (Get-CrTenantNames $settings)
    if ($ready.Action -ne 'Continue') { Write-Host 'Stopped before starting.'; return }
    if ($ready.Tenant) { $Tenant = $ready.Tenant }
}
elseif (-not $headless) {
    Write-CrSystemCheck @($checks | Where-Object State -EQ 'Warning')
}
else {
    Write-Host 'Checking this PC...'
    $fixes = @($checks | Where-Object State -EQ 'Fixable' | ForEach-Object Fix | Select-Object -Unique)
    if ($fixes.Count) {
        foreach ($f in $fixes) { Write-Host "  Fixing: $f..."; Invoke-CrSystemFix $f }
        $checks = & $getChecks $null
    }
    Write-CrSystemCheck $checks
    if (@($checks | Where-Object State -In 'Problem', 'Fixable').Count) { throw 'Fix the items marked FAIL above, then start again.' }
}

# ── What the script is doing, in a window ───────────────────────────────────
#
# Until the next window is ready (setting up, signing in, finding sites), a window shows
# everything printed here. It reads this run's transcript, kept in the logs folder. If
# anything goes wrong, the window says what and waits to be closed.

$script:activity = $null
if (-not $headless) {
    $logFolder = Join-Path $PSScriptRoot 'logs'
    New-Item -ItemType Directory -Path $logFolder -Force | Out-Null
    Get-ChildItem -LiteralPath $logFolder -Filter '*.log' | Where-Object LastWriteTime -LT (Get-Date).AddDays(-30) | Remove-Item -Force -ErrorAction SilentlyContinue
    $log = Join-Path $logFolder "start-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
    $null = Start-Transcript -LiteralPath $log -Append
    $script:activity = Start-CrActivityWindow -LogPath $log -Title $(if ($Tenant) { "Getting $(ConvertTo-CrTenantName $Tenant) ready" } else { 'Getting things ready' })
}
$closeActivity = { Stop-CrActivityWindow $script:activity; $script:activity = $null }
trap {
    if ($script:activity) { Stop-CrActivityWindow $script:activity -Problem $_.Exception.Message; $script:activity = $null }
    break
}

Import-Module PnP.PowerShell -MinimumVersion (Get-CrPnPRequired)

# ── Setup: the tenant ───────────────────────────────────────────────────────

if (-not $Tenant -and -not $settings.tenant) {
    $Tenant = Read-Host 'Your Microsoft 365 tenant name (for example contoso, or contoso.onmicrosoft.com)'
    if (-not $Tenant) { throw 'No tenant name given.' }
}
if ($Tenant) {
    Set-CrTenant $settings $Tenant
    Save-CrSettings $SettingsPath $settings
}

# A scan of this tenant already running in the background: show how it's going.
$running = Get-CrRunningScan $resultsFolder -Tenant $settings.tenant
if ($running) {
    if ($headless) { Write-Warning "A scan of $($settings.tenant) is already running in the background ($running)." }
    else {
        Write-Host "A scan of $($settings.tenant) is already running; showing how it is going."
        & $closeActivity
        $view = & $showProgress $running
        if (-not $view.Back) { return }
        # Main window was pressed: carry on to sign in and show it.
    }
}

# ── Setup: the app that signs in ────────────────────────────────────────────

$app = $settings.app
$newApp = $Setup -or -not $app.clientId -or -not $app.thumbprint

if (-not $newApp -and -not (Test-Path -LiteralPath "Cert:\CurrentUser\My\$($app.thumbprint)")) {
    throw ("The certificate for '$($app.name)' isn't on this PC. Either copy it here (export it from the PC where setup ran, " +
        "with its private key, and import it into your personal certificates), or run ./Start.ps1 -Setup to add this PC to the app.")
}

if ($newApp) {
    Write-Host ''
    Write-Host "Setting up Copilot Readiness for $($settings.tenant) ($($settings.sharePointUrl))" -ForegroundColor Cyan
    Write-Host 'Creating the app registration. A browser window will ask you to sign in as a Global Administrator, and then to accept the permissions.'
    $certFolder = Join-Path $PSScriptRoot 'certificate'
    New-Item -ItemType Directory -Path $certFolder -Force | Out-Null

    $register = @{
        ApplicationName                  = $app.name
        Tenant                           = $settings.tenant
        Store                            = 'CurrentUser'
        OutPath                          = $certFolder
        SharePointApplicationPermissions = 'Sites.FullControl.All'
        GraphApplicationPermissions      = 'Sites.Read.All', 'GroupMember.Read.All', 'InformationProtectionPolicy.Read.All'
    }
    # How it signs you in has changed between PnP versions; use whichever this one offers.
    $accepts = (Get-Command Register-PnPEntraIDApp).Parameters
    if ($DeviceLogin -and $accepts.ContainsKey('DeviceLogin')) { $register.DeviceLogin = $true }
    elseif ($accepts.ContainsKey('Interactive')) { $register.Interactive = $true }

    $certificatesBefore = @(Get-CrAppCertificates $app.name | ForEach-Object Thumbprint)
    $keep = $null
    try {
        $alreadyThere = $false
        $created = $null
        try { $created = Register-PnPEntraIDApp @register }
        catch {
            if ($_.Exception.Message -notmatch 'already exists') { throw }
            $alreadyThere = $true
        }

        if ($alreadyThere) {
            # Set up before on another PC: this PC joins that app, with the certificate PnP has just made here.
            Write-Host "'$($app.name)' is already set up in this tenant, probably on another PC, so this PC will use it too." -ForegroundColor Cyan
            Write-Host 'A browser window will ask you to sign in as a Global Administrator once more, so this PC can be added.'
            $certificate = @(Get-CrAppCertificates $app.name | Where-Object { $certificatesBefore -notcontains $_.Thumbprint } | Sort-Object NotBefore -Descending) | Select-Object -First 1
            if (-not $certificate) { throw "The certificate for this PC wasn't made, so it can't be added to '$($app.name)'. Start again." }
            $graph = New-CrAdminGraph -Settings $settings -DeviceLogin:$DeviceLogin
            $joined = Add-CrCertificateToApp -Graph $graph -AppName $app.name -Certificate $certificate
            Write-Host "This PC now uses the app with ID $($joined.AppId)."
            $switchingOn = "this PC's certificate"
            $app.clientId = $joined.AppId
            $app.thumbprint = $certificate.Thumbprint
            if (-not $joined.Accepted) {
                Write-Host "The app's permissions haven't been accepted yet. A browser window will ask you to accept them."
                Start-Process "https://login.microsoftonline.com/$($settings.tenant)/adminconsent?client_id=$($joined.AppId)"
            }
        }
        else {
            # The output's property names differ a little between PnP versions.
            $props = $created.PSObject.Properties
            $app.clientId = "$(($props | Where-Object Name -Match 'ClientId|AppId' | Select-Object -First 1).Value)"
            $app.thumbprint = "$(($props | Where-Object Name -Match 'Thumbprint' | Select-Object -First 1).Value)"
            if (-not $app.clientId -or -not $app.thumbprint) { throw "The app was created but its id or certificate thumbprint couldn't be read from: $($created | Out-String)" }
        }
        $keep = $app.thumbprint
        $app.createdAt = [DateTimeOffset]::UtcNow.ToString('o')
        Save-CrSettings $SettingsPath $settings
    }
    finally {
        # The certificate's private key now lives in your certificate store; don't leave a copy lying around.
        Remove-CrSetupLeftovers -CertificateFolder $certFolder -AppName $app.name -CertificatesBefore $certificatesBefore -Keep $keep
    }
}

# ── Sign in. A new app's permissions can take a few minutes to reach SharePoint. ──

# A young app (made in the last two hours) keeps trying for up to 20 minutes; Microsoft
# can take that long to switch its permissions on everywhere.
Write-Host "Signing in to $($settings.sharePointUrl)..."
$created = [DateTimeOffset]::MinValue
$young = $newApp -or ([DateTimeOffset]::TryParse("$($app.createdAt)", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$created) -and
    $created -gt [DateTimeOffset]::UtcNow.AddHours(-2))
if (-not (Test-Path variable:switchingOn)) { $switchingOn = "the app's permissions" }
# Microsoft's servers don't all accept something new at the same moment, so one good sign-in
# doesn't mean it's ready. After a new setup, several in a row have to work.
$needed = if ($newApp) { 3 } else { 1 }
$good = 0
$waitSince = $null
$told = $false
$giveUpAt = [DateTime]::UtcNow.AddMinutes($(if ($young) { 20 } else { 0 }))
while ($true) {
    try {
        Connect-CrTenant $settings -NoWait
        $null = Invoke-CrGraph 'sites/getAllSites?$select=id&$top=1'
        $null = Invoke-CrGet "$($settings.sharePointUrl)/_api/web/RoleAssignments?`$top=1"
        $good++
        if ($good -ge $needed) { break }
        $pause = 10
    }
    catch {
        $good = 0
        $pause = 30
        if ([DateTime]::UtcNow -ge $giveUpAt) {
            if ($young) {
                throw ("The app is set up and saved, but after 20 minutes Microsoft still won't let it read your sites. Check the permissions were accepted " +
                    "(Entra admin center > App registrations > '$($app.name)' > API permissions: each should say 'Granted'), then start again. " +
                    "The last error was: $($_.Exception.Message)")
            }
            throw
        }
        Write-Verbose $_.Exception.Message
    }
    # Normal for a new app or certificate: say so in plain words. The technical error stays in the log.
    if (-not $waitSince) { $waitSince = [DateTime]::UtcNow }
    $headline = if ($good) { "Almost there. Microsoft is finishing switching on $switchingOn." } else { "Nothing is wrong. Microsoft is switching on $switchingOn." }
    if ($script:activity) {
        if (-not $told) { Write-Host "Waiting for Microsoft to switch on $switchingOn. This is normal."; $told = $true }
        Set-CrActivityWait $script:activity -Title $headline `
            -Why "This is normal. It usually takes a few minutes and can take up to 20. You don't need to do anything, and this keeps trying by itself." `
            -Since $waitSince -Until ([DateTime]::UtcNow.AddSeconds($pause))
    }
    else {
        Write-Host ("  {0:h:mm:ss tt}  $headline This is normal, and can take up to 20 minutes. Trying again in $pause seconds." -f (Get-Date))
    }
    Start-Sleep -Seconds $pause
}
Set-CrActivityWait $script:activity
if ($newApp) { Write-Host 'Setup done. This PC is ready to scan.' -ForegroundColor Green }

# ── Scan ────────────────────────────────────────────────────────────────────

$choice = $null
if ($Resume) {
    $unfinished = Get-CrUnfinishedScan $resultsFolder -Tenant $settings.tenant
    if (-not $unfinished) { throw "There is no unfinished scan of $($settings.tenant) in $resultsFolder to continue." }
    $folder = $unfinished.Folder
}
else {
    Write-Host 'Finding your sites...'
    $include = if ($Include) { $Include } else { $settings.scan.include }
    $all = @(Get-CrSites -Include $(if ($headless) { $include } else { 'Both' }))
    $spFound = @($all | Where-Object kind -NE 'OneDrive').Count
    $odFound = @($all | Where-Object kind -EQ 'OneDrive').Count
    Write-Host ("Found {0:N0} SharePoint {1} and {2:N0} {3}." -f $spFound, $(if ($spFound -eq 1) { 'site' } else { 'sites' }), $odFound, $(if ($odFound -eq 1) { 'OneDrive' } else { 'OneDrives' }))

    $wanted = @($Sites) + @(if ($SitesFile) { Get-Content -LiteralPath $SitesFile })
    $wanted = @($wanted | Where-Object { "$_".Trim() } | ForEach-Object { "$_".Trim().TrimEnd('/') })
    if (-not $wanted.Count) { $wanted = @($settings.scan.sites | ForEach-Object { "$_".Trim().TrimEnd('/') }) }

    if ($headless) {
        $chosen = $all
        if ($wanted.Count) {
            $chosen = @($all | Where-Object { $wanted -contains $_.url })
            foreach ($w in $wanted | Where-Object { $all.url -notcontains $_ }) { Write-Warning "Not found among your sites, skipped: $w" }
        }
        $choice = [pscustomobject]@{ Action = 'New'; Level = $(if ($Level) { $Level } else { $settings.scan.level }); Include = $include; Sites = $chosen; Pace = $(if ($Pace) { $Pace } else { $settings.scan.pace }) }
    }
    else {
        # The Tenant tab's settings; if they can't be read the tab says why and the scan goes ahead.
        Write-Host 'Reading the tenant''s sharing settings...'
        $tenantSettings = try { Get-CrTenantSettingsView (Read-CrTenantSettings $settings) -SharePointUrl $settings.sharePointUrl } catch { $_.Exception.Message }
        & $closeActivity
    }
}

# With the window this is a loop: the progress window's Main window button comes back to the main
# window, with the past scans read again. Without the window the scan runs once.
while ($true) {
    if (-not $headless) {
        # A scan running in the background is listed under Past scans, where it can be watched; only a stopped one is offered to continue.
        $unfinished = Get-CrUnfinishedScan $resultsFolder -Tenant $settings.tenant
        if ($unfinished -and (Test-CrScanRunning $unfinished.Folder)) { $unfinished = $null }
        $choice = Show-CrControlWindow -Sites $all -TenantName $settings.tenant -SharePointUrl $settings.sharePointUrl -Unfinished $unfinished `
            -PastScans @(Get-CrPastScans $resultsFolder -Tenant $settings.tenant) -DefaultLevel $settings.scan.level -DefaultInclude $include -DefaultSites $wanted -DefaultPace $(if ($Pace) { $Pace } else { $settings.scan.pace }) -About (Get-CrAbout $settings $resultsFolder) -TenantSettings $tenantSettings
    }

    switch ($choice.Action) {
        'Cancel' { Write-Host 'No scan started.'; return }
        'SwitchTenant' {
            # Start again, asking which tenant; this tenant's app stays saved for switching back.
            try { Disconnect-PnPOnline } catch { }
            & $PSCommandPath -ChooseTenant -SettingsPath $SettingsPath -DeviceLogin:$DeviceLogin
            return
        }
        'Resume' { $folder = if ($choice.Folder) { $choice.Folder } else { $unfinished.Folder } }
        'New' {
            if (-not @($choice.Sites).Count) { throw 'No sites chosen.' }
            $folder = New-CrScan -ResultsRoot $resultsFolder -Level $choice.Level -Sites $choice.Sites -Tenant $settings.tenant -StaleDays $settings.scan.staleDays -Pace (Get-CrPace $choice.Pace).Id
        }
    }

    $scope = Get-Content -LiteralPath (Join-Path $folder 'scope.json') -Raw | ConvertFrom-Json
    Write-Host ''
    $odScope = @($scope.sites | Where-Object kind -EQ 'OneDrive').Count
    $spScope = @($scope.sites).Count - $odScope
    Write-Host ("Scanning {0}. Results: $folder" -f (@($(if ($spScope) { "$spScope SharePoint $(if ($spScope -eq 1) { 'site' } else { 'sites' }) ($($scope.level))" }), $(if ($odScope) { "$odScope $(if ($odScope -eq 1) { 'OneDrive' } else { 'OneDrives' })" })) -join ' and ')) -ForegroundColor Cyan

    # With the window, the scan runs in the background and the progress window follows it.
    if (-not $headless) {
        if (Test-CrScanRunning $folder) { Write-Host 'This scan is already running in the background; the progress window shows how far along it is.' }
        else {
            $null = & $launch $folder
            Write-Host 'The scan is running in the background; the progress window shows how far along it is.'
        }
        $view = & $showProgress $folder
        if (-not $view.Back) { return }
        continue
    }

    Write-Host 'Press Ctrl+C to stop; run this script again to continue from where it stopped.'
    Write-Host ''

    Invoke-CrScan -Folder $folder -Settings $settings

    $scan = Get-Content -LiteralPath (Join-Path $folder 'scan.json') -Raw | ConvertFrom-Json
    Write-Host ''
    Write-Host "Finished. $(if ($null -ne $scan.score) { "Score $($scan.score) out of 100, " })$($scan.findingsTotal) findings across $($scan.sitesDone) sites and OneDrives." -ForegroundColor Green
    $report = Join-Path $folder 'report.html'
    Write-Host "Report: $report"
    return
}
