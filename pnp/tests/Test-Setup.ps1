<#
.SYNOPSIS
  Adding a second PC to a tenant's app, against pretend Microsoft answers, with no network.
  Exits 1 if anything is off.

.EXAMPLE
  pwsh -File pnp/tests/Test-Setup.ps1
#>
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\CopilotReadiness\CopilotReadiness.psm1') -Force

$problems = [System.Collections.Generic.List[string]]::new()
function Check([string] $Name, [bool] $Ok) { if (-not $Ok) { $problems.Add($Name) } }
function Fails([scriptblock] $Do) { try { $null = & $Do; '' } catch { $_.Exception.Message } }

$rsa = [System.Security.Cryptography.RSA]::Create(2048)
$request = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=Test PC', $rsa, 'SHA256', [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
$certificate = $request.CreateSelfSigned([DateTimeOffset]::UtcNow, [DateTimeOffset]::UtcNow.AddDays(1))
$firstPc = [pscustomobject]@{ keyId = 'k1'; customKeyIdentifier = 'AAAA'; key = 'first-pc-key'; type = 'AsymmetricX509Cert'; usage = 'Verify'; displayName = 'CN=First PC'; endDateTime = '2036-10-23T04:00:00Z'; startDateTime = '2026-10-23T04:00:00Z' }

function New-Tenant {
    <# A pretend tenant. Writes are kept in Writes; KeepOnly makes an update lose certificates, as Microsoft's list replacement would. #>
    param([object[]] $Apps, [int] $Grants = 4, [switch] $NoPrincipal, [switch] $KeepOnly)
    $state = @{ Apps = $Apps; Writes = [System.Collections.Generic.List[object]]::new(); Filters = [System.Collections.Generic.List[string]]::new() }
    $graph = {
        param($Method, $Path, $Body)
        if ($Method -eq 'PATCH') {
            $state.Writes.Add($Body)
            $list = @($Body.keyCredentials | ForEach-Object { $k = $_ | Select-Object *; if (-not $k.PSObject.Properties['keyId']) { $k | Add-Member keyId 'new' }; $k })
            $state.Apps[0].keyCredentials = if ($KeepOnly) { @($list[-1]) } else { $list }
            return
        }
        if ($Path -like 'applications/*') { return [pscustomobject]@{ keyCredentials = $state.Apps[0].keyCredentials } }
        if ($Path -like 'applications?*') { $state.Filters.Add($Path); return [pscustomobject]@{ value = @($state.Apps) } }
        if ($Path -like 'servicePrincipals/*') { return [pscustomobject]@{ value = @(if ($Grants) { 1..$Grants | ForEach-Object { [pscustomobject]@{ id = "g$_" } } }) } }
        if ($Path -like 'servicePrincipals`?*') { return [pscustomobject]@{ value = @(if (-not $NoPrincipal) { [pscustomobject]@{ id = 'sp1' } }) } }
        throw "unexpected call: $Method $Path"
    }.GetNewClosure()
    [pscustomobject]@{ Graph = $graph; State = $state }
}
function New-App([string] $AppId = 'app-1', [object[]] $Keys = @($firstPc)) {
    [pscustomobject]@{ id = "obj-$AppId"; appId = $AppId; displayName = 'Scanner'; keyCredentials = @($Keys) }
}

# The list sent back keeps every certificate.
$merged = Merge-CrKeyCredentials -Existing @($firstPc) -Certificate $certificate
Check 'the list keeps the first PC and adds this one' ($merged.Count -eq 2 -and $merged[0].key -eq 'first-pc-key' -and $merged[0].keyId -eq 'k1' -and $merged[1].key -eq [Convert]::ToBase64String($certificate.RawData))
Check 'a first certificate on an app with none is fine' (@(Merge-CrKeyCredentials -Certificate $certificate).Count -eq 1)
$here = [pscustomobject]@{ keyId = 'k2'; customKeyIdentifier = $certificate.Thumbprint; key = 'x' }
Check 'a certificate already on the app is not added twice' ($null -eq (Merge-CrKeyCredentials -Existing @($firstPc, $here) -Certificate $certificate))
$noKey = $firstPc | Select-Object *; $noKey.key = $null
Check 'refuses to update when a certificate came back without its key' ((Fails { Merge-CrKeyCredentials -Existing @($noKey) -Certificate $certificate }) -like '*lock out*')

# One app: same ID, both certificates.
$t = New-Tenant -Apps @(New-App)
$r = Add-CrCertificateToApp -Graph $t.Graph -AppName "Scanner's (PnP)" -Certificate $certificate
Check "one app: this PC uses its ID (got $($r.AppId))" ($r.AppId -eq 'app-1' -and $r.Accepted)
Check 'one app: one update, keeping the first PC' ($t.State.Writes.Count -eq 1 -and $t.State.Apps[0].keyCredentials.Count -eq 2 -and $t.State.Apps[0].keyCredentials[0].keyId -eq 'k1')
Check "a name with an apostrophe or brackets is safe in the search (got $($t.State.Filters[0]))" ($t.State.Filters[0] -like "*Scanner%27%27s%20%28PnP%29*")

# Running again changes nothing.
$t = New-Tenant -Apps @(New-App -Keys @($firstPc, $here))
$r = Add-CrCertificateToApp -Graph $t.Graph -AppName 'Scanner' -Certificate $certificate
Check 'setup run twice on one PC: no second certificate' ($t.State.Writes.Count -eq 0 -and $r.AppId -eq 'app-1')

# None, or too many: stops without changing anything.
$t = New-Tenant -Apps @()
Check 'no app: says so' ((Fails { Add-CrCertificateToApp -Graph $t.Graph -AppName 'Scanner' -Certificate $certificate }) -like '*can''t be found*' -and $t.State.Writes.Count -eq 0)
$t = New-Tenant -Apps @((New-App 'app-1'), (New-App 'app-2'))
$why = Fails { Add-CrCertificateToApp -Graph $t.Graph -AppName 'Scanner' -Certificate $certificate }
Check "two apps: lists both and changes neither (got $why)" ($why -like '*app-1, app-2*' -and $t.State.Writes.Count -eq 0)

# An update that loses a certificate is caught.
$t = New-Tenant -Apps @(New-App) -KeepOnly
Check 'an update that loses a certificate is reported' ((Fails { Add-CrCertificateToApp -Graph $t.Graph -AppName 'Scanner' -Certificate $certificate }) -like '*instead of 2*')

# Permissions not accepted yet.
$t = New-Tenant -Apps @(New-App) -NoPrincipal
Check 'never accepted in this tenant' (-not (Add-CrCertificateToApp -Graph $t.Graph -AppName 'Scanner' -Certificate $certificate).Accepted)
$t = New-Tenant -Apps @(New-App) -Grants 0
Check 'permissions not accepted' (-not (Add-CrCertificateToApp -Graph $t.Graph -AppName 'Scanner' -Certificate $certificate).Accepted)

# A new certificate that Microsoft accepts only some of the time.
$tries = @{ N = 0 }; $slept = [System.Collections.Generic.List[int]]::new()
$sleep = { param($s) $slept.Add($s) }.GetNewClosure()
$value = Invoke-CrCertificateWait -Sleep $sleep -Every 7 -Do { $tries.N++; if ($tries.N -lt 3) { throw 'Original exception: AADSTS700027: The certificate is not registered' }; 'signed in' }
Check "waits and retries while the certificate is refused (got $value after $($tries.N) tries)" ($value -eq 'signed in' -and $tries.N -eq 3 -and $slept.Count -eq 2 -and $slept[0] -eq 7)
$tries.N = 0
$why = Fails { Invoke-CrCertificateWait -Sleep $sleep -Do { $tries.N++; throw 'AADSTS50034: The user account does not exist' } }
Check 'any other error is not waited on' ($why -like '*AADSTS50034*' -and $tries.N -eq 1)
$tries.N = 0
$why = Fails { Invoke-CrCertificateWait -Sleep $sleep -Seconds 0 -Do { $tries.N++; throw 'AADSTS700027: not registered' } }
Check 'gives up when the time runs out' ($why -like '*AADSTS700027*' -and $tries.N -eq 1)

# The setup window keeps Microsoft's technical errors to the log file.
$read = @{ InError = $false }
$shown = @(Select-CrActivityLines -Read $read -Lines @(
        'Signing in to https://contoso.sharepoint.com...',
        'PS>TerminatingError(Connect-PnPOnline): "AADSTS700027: The certificate is not registered"',
        '>> TerminatingError(Connect-PnPOnline): "AADSTS700027: The certificate is not registered"',
        'Waiting for Microsoft.',
        'PS>TerminatingError(Invoke-WebRequest): "An error',
        'over more than one line'))
Check "technical errors are not shown (got $($shown -join ' | '))" (($shown -join '|') -eq 'Signing in to https://contoso.sharepoint.com...|Waiting for Microsoft.')
$shown = @(Select-CrActivityLines -Read $read -Lines @('and the end of it"', 'Setup done.', 'Start time: 20261104', '**********************'))
Check "an error split across two reads stays hidden, and text after it shows (got $($shown -join ' | '))" (($shown -join '|') -eq 'Setup done.' -and -not $read.InError)

# What a failed or finished setup leaves behind.
$folder = Join-Path ([IO.Path]::GetTempPath()) "cr-setup-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
New-Item -ItemType Directory -Path $folder | Out-Null
try {
    Set-Content (Join-Path $folder 'a.pfx') 'x'; Set-Content (Join-Path $folder 'a.cer') 'x'; Set-Content (Join-Path $folder 'keep.txt') 'x'
    Remove-CrSetupLeftovers -CertificateFolder $folder -AppName "Nothing has this name $([guid]::NewGuid())"
    Check 'private key copies are removed, other files stay' (@(Get-ChildItem $folder).Name -join ',' -eq 'keep.txt')
}
finally { Remove-Item $folder -Recurse -Force }

if ($problems.Count) {
    Write-Host "$($problems.Count) setup checks failed" -ForegroundColor Red
    $problems | ForEach-Object { Write-Host "  FAIL $_" }
    exit 1
}
Write-Host 'Setup checks passed' -ForegroundColor Green
