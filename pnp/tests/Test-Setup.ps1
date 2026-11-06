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
    param([object[]] $Apps, [int] $Grants = 4, [switch] $NoPrincipal, [switch] $KeepOnly, [switch] $NoKeysInSearch, $OtherPc, [switch] $LookupFails)
    $state = @{ Apps = $Apps; Writes = [System.Collections.Generic.List[object]]::new(); Filters = [System.Collections.Generic.List[string]]::new(); Other = $OtherPc }
    $graph = {
        param($Method, $Path, $Body)
        if ($Method -eq 'PATCH') {
            $state.Writes.Add($Body)
            $list = @($Body.keyCredentials | ForEach-Object {
                    $k = $_ | Select-Object *
                    if (-not $k.PSObject.Properties['keyId']) { $k | Add-Member keyId 'new' }
                    # As Microsoft does: the certificate's thumbprint identifies it from then on.
                    if (-not $k.PSObject.Properties['customKeyIdentifier']) { $k | Add-Member customKeyIdentifier $certificate.Thumbprint }
                    $k
                })
            $state.Apps[0].keyCredentials = if ($KeepOnly) { @($list | Select-Object -First 1) } else { $list }
            # Another PC, working from the list it read earlier, overwrites this one's write.
            if ($state.Other) { $state.Apps[0].keyCredentials = @($firstPc, $state.Other); $state.Other = $null }
            return
        }
        if ($Path -like 'applications/*') { return [pscustomobject]@{ keyCredentials = $state.Apps[0].keyCredentials } }
        if ($Path -like 'applications`?*') {
            $state.Filters.Add($Path)
            # Microsoft only promises certificates' keys when asked about one app, so a search here gives none.
            return [pscustomobject]@{ value = @($state.Apps | ForEach-Object { [pscustomobject]@{ id = $_.id; appId = $_.appId; displayName = $_.displayName; keyCredentials = @($_.keyCredentials | ForEach-Object { $k = $_ | Select-Object *; $k.key = $null; $k }) } }) }
        }
        if ($LookupFails -and $Path -like 'servicePrincipals*') { throw 'service unavailable' }
        if ($Path -like 'servicePrincipals/*') { return [pscustomobject]@{ value = @(if ($Grants) { 1..$Grants | ForEach-Object { [pscustomobject]@{ id = "g$_" } } }) } }
        if ($Path -like 'servicePrincipals`?*') { return [pscustomobject]@{ value = @(if (-not $NoPrincipal) { [pscustomobject]@{ id = 'sp1' } }) } }
        throw "unexpected call: $Method $Path"
    }.GetNewClosure()
    [pscustomobject]@{ Graph = $graph; State = $state }
}
function New-App([string] $AppId = 'app-1', [object[]] $Keys = @($firstPc)) {
    [pscustomobject]@{ id = "obj-$AppId"; appId = $AppId; displayName = 'Scanner'; keyCredentials = @($Keys) }
}

# A certificate this PC already has on the app is used again, not a new one.
$later = [DateTime]::Now.AddDays(300)
$soon = [DateTime]::Now.AddDays(5)
$mine = [pscustomobject]@{ Thumbprint = 'AAAA'; HasPrivateKey = $true; NotAfter = $later }
$t = New-Tenant -Apps @(New-App)
Check 'a certificate already on the app is used again' ((Get-CrReusableCertificate -Graph $t.Graph -AppName 'Scanner' -Certificates @($mine)).Thumbprint -eq 'AAAA')
Check 'looking writes nothing' ($t.State.Writes.Count -eq 0)
Check 'a certificate not on this app is not used' ($null -eq (Get-CrReusableCertificate -Graph $t.Graph -AppName 'Scanner' -Certificates @([pscustomobject]@{ Thumbprint = 'BBBB'; HasPrivateKey = $true; NotAfter = $later })))
Check 'nor one without its private key' ($null -eq (Get-CrReusableCertificate -Graph $t.Graph -AppName 'Scanner' -Certificates @([pscustomobject]@{ Thumbprint = 'AAAA'; HasPrivateKey = $false; NotAfter = $later })))
Check 'nor one about to run out' ($null -eq (Get-CrReusableCertificate -Graph $t.Graph -AppName 'Scanner' -Certificates @([pscustomobject]@{ Thumbprint = 'AAAA'; HasPrivateKey = $true; NotAfter = $soon })))
Check 'no certificates here: nothing to ask' ($null -eq (Get-CrReusableCertificate -Graph { throw 'asked' } -AppName 'Scanner' -Certificates @()))
$t = New-Tenant -Apps @((New-App), (New-App 'app-2'))
Check 'two apps of that name: left for adding to explain' ($null -eq (Get-CrReusableCertificate -Graph $t.Graph -AppName 'Scanner' -Certificates @($mine)))

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
$noPause = { }
$r = Add-CrCertificateToApp -Sleep $noPause -Graph $t.Graph -AppName "Scanner's (PnP)" -Certificate $certificate
Check "one app: this PC uses its ID (got $($r.AppId))" ($r.AppId -eq 'app-1' -and $r.Accepted)
Check 'one app: one update, keeping the first PC' ($t.State.Writes.Count -eq 1 -and $t.State.Apps[0].keyCredentials.Count -eq 2 -and $t.State.Apps[0].keyCredentials[0].keyId -eq 'k1')
Check "a name with an apostrophe or brackets is safe in the search (got $($t.State.Filters[0]))" ($t.State.Filters[0] -like "*Scanner%27%27s%20%28PnP%29*")

# Already on the app: nothing to change.
$t = New-Tenant -Apps @(New-App -Keys @($firstPc, $here))
$r = Add-CrCertificateToApp -Sleep $noPause -Graph $t.Graph -AppName 'Scanner' -Certificate $certificate
Check 'a certificate already on the app changes nothing' ($t.State.Writes.Count -eq 0 -and $r.AppId -eq 'app-1')

# Setup run again on a PC: its new certificate replaces its old one, and the first PC's stays.
$oldHere = [pscustomobject]@{ keyId = 'k3'; customKeyIdentifier = 'OLDPC'; key = 'old-key'; type = 'AsymmetricX509Cert'; usage = 'Verify'; displayName = 'CN=Old' }
$t = New-Tenant -Apps @(New-App -Keys @($firstPc, $oldHere))
$null = Add-CrCertificateToApp -Sleep $noPause -Graph $t.Graph -AppName 'Scanner' -Certificate $certificate -Replace 'OLDPC'
$ids = @($t.State.Apps[0].keyCredentials | ForEach-Object { "$($_.customKeyIdentifier)" })
Check "setup run again replaces this PC's certificate (got $($ids -join ', '))" ($ids.Count -eq 2 -and $ids -contains 'AAAA' -and $ids -contains $certificate.Thumbprint -and $ids -notcontains 'OLDPC')

# Two PCs joining together: the other PC's write drops this one's, and this one puts itself back without losing theirs.
$otherPc = [pscustomobject]@{ keyId = 'k9'; customKeyIdentifier = 'OTHERPC'; key = 'other-key'; type = 'AsymmetricX509Cert'; usage = 'Verify'; displayName = 'CN=Other' }
$t = New-Tenant -Apps @(New-App) -OtherPc $otherPc
$null = Add-CrCertificateToApp -Sleep $noPause -Graph $t.Graph -AppName 'Scanner' -Certificate $certificate
$ids = @($t.State.Apps[0].keyCredentials | ForEach-Object { "$($_.customKeyIdentifier)" })
Check "two PCs at once: all three certificates end up on the app (got $($ids -join ', '))" ($ids.Count -eq 3 -and $ids -contains 'AAAA' -and $ids -contains 'OTHERPC' -and $ids -contains $certificate.Thumbprint -and $t.State.Writes.Count -eq 2)

# Not being able to read whether permissions were accepted doesn't undo the join.
$t = New-Tenant -Apps @(New-App) -LookupFails
$r = Add-CrCertificateToApp -Sleep $noPause -Graph $t.Graph -AppName 'Scanner' -Certificate $certificate
Check 'a failed permissions lookup keeps the certificate and says it does not know' ($null -eq $r.Accepted -and @($t.State.Apps[0].keyCredentials).Count -eq 2)

# None, or too many: stops without changing anything.
$t = New-Tenant -Apps @()
Check 'no app: says so' ((Fails { Add-CrCertificateToApp -Sleep $noPause -Graph $t.Graph -AppName 'Scanner' -Certificate $certificate }) -like '*can''t be found*' -and $t.State.Writes.Count -eq 0)
$t = New-Tenant -Apps @((New-App 'app-1'), (New-App 'app-2'))
$why = Fails { Add-CrCertificateToApp -Sleep $noPause -Graph $t.Graph -AppName 'Scanner' -Certificate $certificate }
Check "two apps: lists both and changes neither (got $why)" ($why -like '*app-1, app-2*' -and $t.State.Writes.Count -eq 0)

# An update that never takes: reported, and this PC's entry isn't left behind.
$t = New-Tenant -Apps @(New-App) -KeepOnly
$why = Fails { Add-CrCertificateToApp -Sleep $noPause -Checks 3 -Graph $t.Graph -AppName 'Scanner' -Certificate $certificate }
$ids = @($t.State.Apps[0].keyCredentials | ForEach-Object { "$($_.customKeyIdentifier)" })
Check "an update that never takes is reported and leaves no entry (got $why / $($ids -join ', '))" ($why -like "*Couldn't confirm*" -and $ids -notcontains $certificate.Thumbprint -and $ids -contains 'AAAA')

# Failing partway: a new certificate comes off the app, one this PC was already using stays.
function New-FlakyGraph {
    <# The app's list at first leaves this PC's certificate out, as Microsoft can just after a change, and the check after the update fails. #>
    $flaky = @{ Keys = @($firstPc); Reads = 0 }
    $graph = {
        param($Method, $Path, $Body)
        if ($Method -eq 'PATCH') {
            $flaky.Keys = @($Body.keyCredentials | ForEach-Object {
                    $k = $_ | Select-Object *
                    if (-not $k.PSObject.Properties['customKeyIdentifier']) { $k | Add-Member customKeyIdentifier $certificate.Thumbprint }
                    $k
                })
            return
        }
        if ($Path -like 'applications/*') {
            $flaky.Reads++
            if ($flaky.Reads -eq 2) { throw 'service unavailable' }
            return [pscustomobject]@{ keyCredentials = $flaky.Keys }
        }
        [pscustomobject]@{ value = @([pscustomobject]@{ id = 'obj-app-1'; appId = 'app-1'; displayName = 'Scanner' }) }
    }.GetNewClosure()
    [pscustomobject]@{ Graph = $graph; State = $flaky }
}
$f = New-FlakyGraph
$why = Fails { Add-CrCertificateToApp -Sleep $noPause -Graph $f.Graph -AppName 'Scanner' -Certificate $certificate }
Check "a new certificate comes off the app if adding it fails (got $why)" ($why -like '*unavailable*' -and @($f.State.Keys.customKeyIdentifier) -notcontains $certificate.Thumbprint -and @($f.State.Keys.customKeyIdentifier) -contains 'AAAA')
$f = New-FlakyGraph
$why = Fails { Add-CrCertificateToApp -Sleep $noPause -Graph $f.Graph -AppName 'Scanner' -Certificate $certificate -KeepOnFailure }
Check "a certificate already in use stays on the app if it fails (got $why)" ($why -like '*unavailable*' -and @($f.State.Keys.customKeyIdentifier) -contains $certificate.Thumbprint -and @($f.State.Keys.customKeyIdentifier) -contains 'AAAA')

# Taking a certificate back off leaves the others.
$t = New-Tenant -Apps @(New-App -Keys @($firstPc, $oldHere))
Remove-CrCertificateFromApp -Graph $t.Graph -ObjectId 'obj-app-1' -Thumbprint 'OLDPC'
Check 'taking one certificate off leaves the rest' ((@($t.State.Apps[0].keyCredentials).customKeyIdentifier -join ',') -eq 'AAAA')

# Permissions not accepted yet.
$t = New-Tenant -Apps @(New-App) -NoPrincipal
Check 'never accepted in this tenant' ($false -eq (Add-CrCertificateToApp -Sleep $noPause -Graph $t.Graph -AppName 'Scanner' -Certificate $certificate).Accepted)
$t = New-Tenant -Apps @(New-App) -Grants 0
Check 'permissions not accepted' ($false -eq (Add-CrCertificateToApp -Sleep $noPause -Graph $t.Graph -AppName 'Scanner' -Certificate $certificate).Accepted)

# A new certificate that Microsoft accepts only some of the time.
$tries = @{ N = 0 }; $slept = [System.Collections.Generic.List[int]]::new()
$sleep = { param($s) $slept.Add($s) }.GetNewClosure()
$soon = [DateTime]::UtcNow.AddMinutes(5)
$value = Invoke-CrCertificateWait -Sleep $sleep -Until $soon -Every 7 -Do { $tries.N++; if ($tries.N -lt 3) { throw 'Original exception: AADSTS700027: The certificate is not registered' }; 'signed in' }
Check "waits and retries while the certificate is refused (got $value after $($tries.N) tries)" ($value -eq 'signed in' -and $tries.N -eq 3 -and $slept.Count -eq 2 -and $slept[0] -eq 7)
$tries.N = 0
$why = Fails { Invoke-CrCertificateWait -Sleep $sleep -Until $soon -Do { $tries.N++; throw 'AADSTS50034: The user account does not exist' } }
Check 'any other error is not waited on' ($why -like '*AADSTS50034*' -and $tries.N -eq 1)
$tries.N = 0
$why = Fails { Invoke-CrCertificateWait -Sleep $sleep -Until ([DateTime]::UtcNow.AddSeconds(-1)) -Do { $tries.N++; throw 'AADSTS700027: not registered' } }
Check 'gives up when the time runs out' ($why -like '*AADSTS700027*' -and $tries.N -eq 1)
$tries.N = 0
$why = Fails { Invoke-CrCertificateWait -Sleep $sleep -Do { $tries.N++; throw 'AADSTS700027: not registered' } }
Check 'an old certificate that is refused is not waited on' ($why -like '*AADSTS700027*' -and $tries.N -eq 1)
Set-CrCertificateWait $false
$tries.N = 0
$why = Fails { Invoke-CrCertificateWait -Sleep $sleep -Until $soon -Do { $tries.N++; throw 'AADSTS700027: not registered' } }
Set-CrCertificateWait $true
Check 'the setup screen can turn the wait off, so it does not hide inside its own' ($why -like '*AADSTS700027*' -and $tries.N -eq 1)
$stopFile = Join-Path ([IO.Path]::GetTempPath()) "cr-stop-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
Set-Content -LiteralPath $stopFile 'stop'
Set-CrStopFile $stopFile
$stopped = $null
try { $null = Invoke-CrCertificateWait -Until $soon -Every 2 -Do { throw 'AADSTS700027: not registered' } }
catch { $stopped = $_.Exception }
Set-CrStopFile $null
Remove-Item -LiteralPath $stopFile
Check 'Stop ends the wait' ($stopped -is [System.OperationCanceledException])

# The setup window keeps Microsoft's technical errors to the log file.
$read = @{ InError = $false; Depth = 0 }
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

$read = @{ InError = $false; Depth = 0 }
$shown = @(Select-CrActivityLines -Read $read -Lines @(
        'PS>TerminatingError(Invoke-WebRequest): "{',
        '  "error": {',
        '    "code": "InvalidAuthenticationToken",',
        '    "message": "Access token has expired"',
        '  }',
        '}"',
        'Waiting for Microsoft.',
        'Original exception: AADSTS700027: not registered'))
Check "an error in several lines stays hidden even where a line ends in a quote (got $($shown -join ' | '))" (($shown -join '|') -eq 'Waiting for Microsoft.')

# What a failed or finished setup leaves behind.
$folder = Join-Path ([IO.Path]::GetTempPath()) "cr-setup-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
New-Item -ItemType Directory -Path $folder | Out-Null
try {
    Set-Content (Join-Path $folder 'a.pfx') 'x'; Set-Content (Join-Path $folder 'a.cer') 'x'; Set-Content (Join-Path $folder 'keep.txt') 'x'
    Remove-CrSetupLeftovers -CertificateFolder $folder -AppName "Nothing has this name $([guid]::NewGuid())"
    Check 'private key copies are removed, other files stay' (@(Get-ChildItem $folder).Name -join ',' -eq 'keep.txt')
}
finally { Remove-Item $folder -Recurse -Force }

# Removing the app: the tenant's app is deleted, then only this tenant's settings are forgotten.
$calls = [System.Collections.Generic.List[string]]::new()
$fakeGraph = {
    param([string] $Method, [string] $Path, $Body)
    $calls.Add("$Method $Path")
    if ($Method -eq 'GET' -and $Path -like 'applications?*') { return [pscustomobject]@{ value = @([pscustomobject]@{ id = 'obj-1'; appId = '11111111-2222-3333-4444-555555555555' }) } }
}.GetNewClosure()
$removing = [pscustomobject]@{
    tenant = 'contoso.onmicrosoft.com'
    app    = [pscustomobject]@{ name = 'Copilot Readiness Scanner (PnP)'; clientId = '11111111-2222-3333-4444-555555555555'; thumbprint = 'NOT-ON-THIS-PC'; createdAt = '2026-01-01' }
    otherTenants = @([pscustomobject]@{ tenant = 'fabrikam.onmicrosoft.com'; clientId = 'other'; thumbprint = 'OTHER' })
}
$removal = Uninstall-CrApp -Settings $removing -Graph $fakeGraph
Check "the app is found by its ID and deleted (calls: $($calls -join ' | '))" ($removal.Deleted -eq 1 -and -not $removal.CertificateProblem -and $calls[0] -like "GET applications?`$filter=appId eq '11111111-2222-3333-4444-555555555555'*" -and $calls[1] -eq 'DELETE applications/obj-1')
Check 'settings forget the app, other tenants kept' (-not $removing.app.clientId -and -not $removing.app.thumbprint -and $removing.otherTenants[0].clientId -eq 'other')
$calls.Clear()
$failing = { param($Method, $Path, $Body) if ($Method -eq 'DELETE') { throw 'Forbidden' }; [pscustomobject]@{ value = @([pscustomobject]@{ id = 'obj-1' }) } }
$keep = [pscustomobject]@{ tenant = 'contoso.onmicrosoft.com'; app = [pscustomobject]@{ clientId = '11111111-2222-3333-4444-555555555555'; thumbprint = 'T'; createdAt = '' } }
$threw = try { $null = Uninstall-CrApp -Settings $keep -Graph $failing; $false } catch { $true }
Check 'when the tenant refuses, this PC keeps the app' ($threw -and $keep.app.clientId -and $keep.app.thumbprint -eq 'T')

# The tenant's settings read back from the saved copy look the same as when first read.
$values = [ordered]@{ SharingCapability = [Microsoft.PowerShell.ExecutionPolicy]::Bypass; OneDriveSharingCapability = 'Disabled'; RequireAnonymousLinksExpireInDays = 30; ShowEveryoneClaim = $false; AllowedDomainList = @('a.com', 'b.com') }
$plain = ConvertTo-CrPlainSettings $values
$back = (ConvertTo-Json -InputObject ([pscustomobject]$plain) -Depth 5 | ConvertFrom-Json)
Check 'choices are kept as names, lists as lists' ($back.SharingCapability -eq 'Bypass' -and $back.RequireAnonymousLinksExpireInDays -eq 30 -and @($back.AllowedDomainList).Count -eq 2 -and $back.ShowEveryoneClaim -eq $false)

if ($problems.Count) {
    Write-Host "$($problems.Count) setup checks failed" -ForegroundColor Red
    $problems | ForEach-Object { Write-Host "  FAIL $_" }
    exit 1
}
Write-Host 'Setup checks passed' -ForegroundColor Green
