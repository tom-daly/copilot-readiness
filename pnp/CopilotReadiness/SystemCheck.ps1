# The checks Start.ps1 runs before anything else, so problems show up as plain
# sentences with a fix, not as errors halfway through a scan.

# The PnP.PowerShell version this was built and tested with. Older ones are updated.
$script:PnPVersion = [version]'3.4.1'
$script:PowerShellMinimum = [version]'7.5'

function Get-CrPnPRequired { $script:PnPVersion }

function New-CrCheck {
    <# State: Ok, Info, Warning (can go ahead), Problem (can't), Fixable (Fix says how). #>
    param([string] $Name, [string] $State, [string] $Detail, [string] $Fix)
    [pscustomobject]@{ Name = $Name; State = $State; Detail = $Detail; Fix = $Fix }
}

function Get-CrPnPVersion {
    <# The newest PnP.PowerShell installed, or nothing. #>
    $m = Get-Module -ListAvailable PnP.PowerShell | Sort-Object Version -Descending | Select-Object -First 1
    if ($m) { $m.Version }
}

function Get-CrSystemCheck {
    param(
        [Parameter(Mandatory)] $Settings,
        [Parameter(Mandatory)] [string] $ResultsFolder,
        [string] $Tenant
    )
    $checks = [System.Collections.Generic.List[object]]::new()

    $ps = $PSVersionTable.PSVersion
    $checks.Add($(if ($ps -ge $script:PowerShellMinimum) { New-CrCheck 'PowerShell' Ok "Version $ps" }
            else { New-CrCheck 'PowerShell' Problem "Version $ps is too old. Install PowerShell $script:PowerShellMinimum or later from https://aka.ms/powershell, then start again." }))

    $checks.Add($(if ($IsWindows) { New-CrCheck 'Windows' Ok 'The certificate is kept in your Windows certificate store' }
            else { New-CrCheck 'Windows' Problem 'This keeps its certificate in the Windows certificate store, so it needs Windows.' }))

    $pnp = Get-CrPnPVersion
    $checks.Add($(if (-not $pnp) { New-CrCheck 'PnP.PowerShell' Fixable "Not installed. Fix installs version $script:PnPVersion for your account." InstallPnP }
            elseif ($pnp -lt $script:PnPVersion) { New-CrCheck 'PnP.PowerShell' Fixable "Version $pnp is older than $script:PnPVersion, which this needs. Fix installs $script:PnPVersion for your account." InstallPnP }
            else { New-CrCheck 'PnP.PowerShell' Ok "Version $pnp" }))

    # Reaching Microsoft's sign-in service also tells us whether the tenant name is real.
    $name = ConvertTo-CrTenantName $(if ($Tenant) { $Tenant } else { $Settings.tenant })
    try {
        $r = Invoke-WebRequest "https://login.microsoftonline.com/$(if ($name) { $name } else { 'common' })/v2.0/.well-known/openid-configuration" -TimeoutSec 20 -SkipHttpErrorCheck
        $checks.Add($(if ([int]$r.StatusCode -eq 200) { New-CrCheck 'Microsoft 365' Ok $(if ($name) { "Can reach $name" } else { 'Can reach Microsoft 365' }) }
                elseif ($name) { New-CrCheck 'Microsoft 365' Problem "There is no tenant called $name. Check the name and try again." }
                else { New-CrCheck 'Microsoft 365' Problem "Microsoft's sign-in service answered $([int]$r.StatusCode)." }))
    }
    catch {
        $checks.Add((New-CrCheck 'Microsoft 365' Problem "Can't reach Microsoft 365 from this PC: $($_.Exception.Message). Check the internet connection or proxy."))
    }

    # The tenant typed in may be another one set up on this PC before, with its own app.
    $app = Get-CrTenantApp $Settings $name
    if (-not $app.clientId -or -not $app.thumbprint) {
        $checks.Add((New-CrCheck 'Setup' Info "Not set up yet$(if ($name) { " for $name" }). Continue creates the '$($Settings.app.name)' app; you sign in as a Global Administrator and accept its permissions."))
    }
    else {
        $cert = Get-Item -LiteralPath "Cert:\CurrentUser\My\$($app.thumbprint)" -ErrorAction SilentlyContinue
        $checks.Add($(if (-not $cert) {
                    New-CrCheck 'Certificate' Problem ("The certificate for '$($Settings.app.name)' isn't on this PC. Copy it from the PC where setup ran " +
                        "(with its private key), or start again with -Setup to create a new app for this PC.")
                }
                elseif ($cert.NotAfter -lt (Get-Date)) { New-CrCheck 'Certificate' Problem "Expired on $($cert.NotAfter.ToString('MMMM d, yyyy')). Start again with -Setup to create a new app." }
                elseif ($cert.NotAfter -lt (Get-Date).AddDays(30)) { New-CrCheck 'Certificate' Warning "Expires on $($cert.NotAfter.ToString('MMMM d, yyyy')). After that, start with -Setup to create a new app." }
                else { New-CrCheck 'Certificate' Ok "Valid until $($cert.NotAfter.ToString('MMMM d, yyyy'))" }))
    }

    try {
        New-Item -ItemType Directory -Path $ResultsFolder -Force | Out-Null
        $probe = Join-Path $ResultsFolder ".write-check-$PID"
        Set-Content -LiteralPath $probe -Value 'ok'
        Remove-Item -LiteralPath $probe
        $checks.Add((New-CrCheck 'Results folder' Ok $ResultsFolder))
    }
    catch {
        $checks.Add((New-CrCheck 'Results folder' Problem "Can't save results in $ResultsFolder ($($_.Exception.Message)). Change scan.resultsFolder in settings.json."))
    }

    $checks.ToArray()
}

function Get-CrAbout {
    <#
      What the Settings tab shows: what this needs and what this PC has, the app it signs in
      with, where results go, and who to ask for help.
    #>
    param([Parameter(Mandatory)] $Settings, [string] $ResultsFolder)
    $pnp = Get-CrPnPVersion
    $ps = $PSVersionTable.PSVersion
    $cert = if ($IsWindows -and $Settings.app.thumbprint) { Get-Item -LiteralPath "Cert:\CurrentUser\My\$($Settings.app.thumbprint)" -ErrorAction SilentlyContinue }
    [pscustomobject][ordered]@{
        Name         = 'Copilot Readiness scan'
        BuiltBy      = 'Thomas Daly'
        Support      = 'thomas.m.daly@outlook.com'
        RuleBook     = (Get-CrRuleBook).version
        Requirements = @(
            [pscustomobject]@{ Name = 'PowerShell'; Needs = "$script:PowerShellMinimum or later"; Has = "$ps"; Ok = $ps -ge $script:PowerShellMinimum }
            [pscustomobject]@{ Name = 'PnP.PowerShell'; Needs = "$script:PnPVersion or later"; Has = $(if ($pnp) { "$pnp" } else { 'Not installed' }); Ok = $pnp -and $pnp -ge $script:PnPVersion }
            [pscustomobject]@{ Name = 'Windows'; Needs = 'Windows 10 or later'; Has = $(if ($IsWindows) { [Environment]::OSVersion.Version.ToString() } else { 'Not Windows' }); Ok = [bool]$IsWindows }
            [pscustomobject]@{ Name = '.NET'; Needs = '8 or later (comes with PowerShell)'; Has = [Environment]::Version.ToString(); Ok = [Environment]::Version.Major -ge 8 }
        )
        Tenant       = $Settings.tenant
        SharePoint   = $Settings.sharePointUrl
        AppName      = $Settings.app.name
        AppId        = $Settings.app.clientId
        Thumbprint   = $Settings.app.thumbprint
        CertExpires  = $(if ($cert) { $cert.NotAfter } else { $null })
        Results      = $ResultsFolder
    }
}
function Invoke-CrSystemFix {
    <#
      Applies one fix. PnP.PowerShell 3 is signed by the .NET Foundation rather than
      Microsoft, so updating from version 2 needs -SkipPublisherCheck.
    #>
    param([Parameter(Mandatory)] [string] $Fix)
    switch ($Fix) {
        'InstallPnP' {
            Install-Module PnP.PowerShell -RequiredVersion $script:PnPVersion -Scope CurrentUser -Force -AllowClobber -SkipPublisherCheck
        }
        default { throw "No fix called $Fix." }
    }
}

function Write-CrSystemCheck {
    <# The checks as lines of text, for runs without the window. #>
    param([object[]] $Checks)
    $marks = @{ Ok = ' OK '; Info = 'INFO'; Warning = 'WARN'; Problem = 'FAIL'; Fixable = 'FIX ' }
    $colours = @{ Ok = 'Green'; Info = 'Cyan'; Warning = 'Yellow'; Problem = 'Red'; Fixable = 'Yellow' }
    foreach ($c in $Checks) { Write-Host "  [$($marks[$c.State])] $($c.Name): $($c.Detail)" -ForegroundColor $colours[$c.State] }
}
