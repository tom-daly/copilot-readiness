# Setting up a second PC. Each tenant has one app, so when it already exists this PC joins it:
# an admin signs in once, and this PC's certificate is added next to the ones already there.
# The app ID stays the same, and its permissions don't need accepting again.

# The app PnP itself signs admins in with (Azure PowerShell, from Microsoft). The scan's own app
# can't be used here, because this PC has no certificate for it yet.
$script:AdminClientId = '1950a258-227b-4e31-a9cf-717495945fc2'

function New-CrAdminGraph {
    <# Signs an admin in, and returns what calls Microsoft Graph as them: & $graph GET 'applications' (or PATCH with a body). #>
    param([Parameter(Mandatory)] $Settings, [switch] $DeviceLogin)
    $how = if ($DeviceLogin) { @{ DeviceLogin = $true } } else { @{ Interactive = $true; ForceAuthentication = $true } }
    Connect-PnPOnline -Url $Settings.sharePointUrl -ClientId $script:AdminClientId -Tenant $Settings.tenant @how -ErrorAction Stop
    $token = Get-PnPAccessToken -ResourceTypeName Graph
    {
        param([string] $Method, [string] $Path, $Body)
        $call = @{ Uri = "https://graph.microsoft.com/v1.0/$Path"; Method = $Method; Headers = @{ Authorization = "Bearer $token" } }
        if ($null -ne $Body) { $call.Body = $Body | ConvertTo-Json -Depth 8; $call.ContentType = 'application/json' }
        # Read as text, so dates go back to Microsoft exactly as they came.
        $answer = Invoke-WebRequest @call -ErrorAction Stop
        if ($answer.Content) { ConvertFrom-CrJson ([string]$answer.Content) }
    }.GetNewClosure()
}

function Get-CrAppsNamed {
    <# Every app in the tenant with this name. Graph is what New-CrAdminGraph returns. #>
    param([Parameter(Mandatory)] [scriptblock] $Graph, [Parameter(Mandatory)] [string] $AppName)
    $filter = [uri]::EscapeDataString("displayName eq '$($AppName.Replace("'", "''"))'")
    @((& $Graph GET "applications?`$filter=$filter&`$select=id,appId,displayName").value)
}

function Merge-CrKeyCredentials {
    <#
      The app's certificate list with this one added, or nothing if it's already there.
      Microsoft replaces the whole list on an update, so every certificate must go back
      with its key, or the PCs using them are locked out.
    #>
    param([object[]] $Existing = @(), [Parameter(Mandatory)] [System.Security.Cryptography.X509Certificates.X509Certificate2] $Certificate)
    if (@($Existing | Where-Object { "$($_.customKeyIdentifier)" -eq $Certificate.Thumbprint }).Count) { return }
    foreach ($k in $Existing) {
        if (-not $k.key) { throw "Microsoft didn't return the certificate ending $("$($k.keyId)".Split('-')[-1]), so adding another could lock out the PC using it. Nothing was changed." }
    }
    $new = [pscustomobject][ordered]@{
        type        = 'AsymmetricX509Cert'
        usage       = 'Verify'
        key         = [Convert]::ToBase64String($Certificate.RawData)
        displayName = $Certificate.Subject
    }
    , @(@($Existing) + $new)
}

function Remove-CrCertificateFromApp {
    <# Takes one certificate off the app, leaving the rest. For a setup that failed after adding it. #>
    param([Parameter(Mandatory)] [scriptblock] $Graph, [Parameter(Mandatory)] [string] $ObjectId, [Parameter(Mandatory)] [string] $Thumbprint)
    $keys = @((& $Graph GET "applications/$ObjectId`?`$select=keyCredentials").keyCredentials)
    $rest = @($keys | Where-Object { "$($_.customKeyIdentifier)" -ne $Thumbprint })
    if ($rest.Count -eq $keys.Count) { return }
    if (@($rest | Where-Object { -not $_.key }).Count) { return }
    $null = & $Graph PATCH "applications/$ObjectId" ([pscustomobject]@{ keyCredentials = $rest })
}

function Add-CrCertificateToApp {
    <#
      Finds the tenant's app by name and adds this PC's certificate to it. Replace names a
      certificate this PC is giving up, which comes off the app. Returns AppId, ObjectId and Accepted:
      whether the app's permissions have been accepted ($null if that couldn't be found out).

      Microsoft has no way to change the list only if nobody else just did, so two PCs joining
      together could each overwrite the other. And right after a change it can answer with the old
      list. So this reads the list back after a pause, and puts back anything that went missing,
      until the list is right. Graph is what New-CrAdminGraph returns. KeepOnFailure is for a
      certificate this PC was already using: if this fails, it stays on the app for what uses it.
    #>
    param(
        [Parameter(Mandatory)] [scriptblock] $Graph,
        [Parameter(Mandatory)] [string] $AppName,
        [Parameter(Mandatory)] [System.Security.Cryptography.X509Certificates.X509Certificate2] $Certificate,
        [string] $Replace,
        [switch] $KeepOnFailure,
        [int] $Checks = 6,
        [scriptblock] $Sleep = { Start-Sleep -Seconds (Get-Random -Minimum 10 -Maximum 21) }
    )
    $apps = @(Get-CrAppsNamed -Graph $Graph -AppName $AppName)
    if ($apps.Count -eq 0) { throw "Microsoft said the app '$AppName' already exists, but it can't be found. Check you signed in as a Global Administrator, then start again." }
    if ($apps.Count -gt 1) {
        throw ("This tenant has $($apps.Count) apps called '$AppName', with these app IDs: $($apps.appId -join ', '). " +
            'In the Entra admin center, under App registrations, delete the ones nobody uses so that one is left, then start again.')
    }
    $found = $apps[0]

    # Every certificate seen on the app during this run, by thumbprint, with its key.
    $known = [ordered]@{}
    $wrote = $false
    $right = $false
    try {
        foreach ($check in 1..$Checks) {
            # Certificates' keys only come back when asking for one app by itself, not from a search.
            $now = @((& $Graph GET "applications/$($found.id)?`$select=keyCredentials").keyCredentials)
            foreach ($k in $now) { if ("$($k.customKeyIdentifier)" -ne $Replace) { $known["$($k.customKeyIdentifier)"] = $k } }
            $here = @($now | ForEach-Object { "$($_.customKeyIdentifier)" })
            $missing = @($known.Keys | Where-Object { $here -notcontains $_ })
            $right = $here -contains $Certificate.Thumbprint -and -not $missing.Count -and -not ($Replace -and $here -contains $Replace)
            # Once it looks right after a change, it has held through the pause.
            if ($right) { break }
            $list = Merge-CrKeyCredentials -Existing @($known.Values) -Certificate $Certificate
            if (-not $list) { $list = @($known.Values) }
            $wrote = $true
            $null = & $Graph PATCH "applications/$($found.id)" ([pscustomobject]@{ keyCredentials = @($list) })
            if ($check -lt $Checks) { & $Sleep }
        }
        if (-not $right) {
            throw "Couldn't confirm this PC's certificate on '$AppName' after $Checks tries. Wait a few minutes and start again. If it keeps happening, check the app in the Entra admin center under App registrations > Certificates & secrets."
        }
    }
    catch {
        # Don't leave an entry nobody can use. If this fails too, the error above is still what matters.
        if ($wrote -and -not $KeepOnFailure) { try { Remove-CrCertificateFromApp -Graph $Graph -ObjectId $found.id -Thumbprint $Certificate.Thumbprint } catch { } }
        throw
    }

    # The certificate is on. Not being able to read this next part is no reason to undo that: the sign-in that follows will tell.
    $accepted = $null
    try {
        $principals = @((& $Graph GET "servicePrincipals?`$filter=appId eq '$($found.appId)'&`$select=id").value)
        $accepted = $false
        if ($principals.Count) { $accepted = @((& $Graph GET "servicePrincipals/$($principals[0].id)/appRoleAssignments").value).Count -gt 0 }
    }
    catch { $accepted = $null }
    [pscustomobject]@{ AppId = "$($found.appId)"; ObjectId = "$($found.id)"; Accepted = $accepted }
}

function Get-CrReusableCertificate {
    <#
      A certificate already on this PC that the tenant's app already accepts, so there's no need
      to add another: the one lasting longest, with its private key and at least a month to run.
      Other tenants' apps share the name, so being on this tenant's app is what counts. Nothing
      if there's none, or the app can't be picked out; adding a certificate then says why.
    #>
    param([Parameter(Mandatory)] [scriptblock] $Graph, [Parameter(Mandatory)] [string] $AppName, [object[]] $Certificates = @())
    $usable = @($Certificates | Where-Object { $_.HasPrivateKey -and $_.NotAfter -gt (Get-Date).AddDays(30) })
    if (-not $usable.Count) { return }
    $apps = @(Get-CrAppsNamed -Graph $Graph -AppName $AppName)
    if ($apps.Count -ne 1) { return }
    $onApp = @((& $Graph GET "applications/$($apps[0].id)?`$select=keyCredentials").keyCredentials | ForEach-Object { "$($_.customKeyIdentifier)" })
    @($usable | Where-Object { $onApp -contains $_.Thumbprint } | Sort-Object NotAfter -Descending) | Select-Object -First 1
}

function Get-CrAppCertificates {
    <# The certificates in this Windows account's store that were made for the app. #>
    param([Parameter(Mandatory)] [string] $AppName)
    @(Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.Subject -eq "CN=$AppName" })
}

function Remove-CrSetupLeftovers {
    <#
      After setup, whether it worked or not: removes the copies of the private key from the
      certificate folder, and any certificate made during this run that nothing uses, with its key.
    #>
    param([Parameter(Mandatory)] [string] $CertificateFolder, [Parameter(Mandatory)] [string] $AppName, [string[]] $CertificatesBefore = @(), [string] $Keep)
    if (Test-Path -LiteralPath $CertificateFolder) {
        Get-ChildItem -LiteralPath $CertificateFolder -File | Where-Object Extension -In '.pfx', '.cer' | Remove-Item -Force
    }
    Get-CrAppCertificates $AppName | Where-Object { $CertificatesBefore -notcontains $_.Thumbprint -and $_.Thumbprint -ne $Keep } |
        ForEach-Object { Remove-Item -LiteralPath $_.PSPath -DeleteKey -Force }
}

# ── Removing the app ───────────────────────────────────────────────────────

function Remove-CrAppFromTenant {
    <#
      Deletes the app with this app ID from the tenant, which also takes away its permissions
      there. Entra keeps a deleted app for 30 days, so an admin can bring it back from Deleted
      applications in that time. Returns how many apps were deleted (0 when it was already gone).
      Graph is what New-CrAdminGraph returns.
    #>
    param([Parameter(Mandatory)] [scriptblock] $Graph, [Parameter(Mandatory)] [string] $AppId)
    $parsed = [guid]::Empty
    if (-not [guid]::TryParse($AppId, [ref]$parsed)) { throw "'$AppId' isn't an app ID." }
    # An app ID is unique in a tenant, so there is one app at most: one delete, which either happens or
    # doesn't, so a failure always means nothing in the tenant was changed.
    $app = @((& $Graph GET "applications?`$filter=appId eq '$AppId'&`$select=id,appId,displayName").value) | Select-Object -First 1
    if (-not $app) { return 0 }
    $null = & $Graph DELETE "applications/$($app.id)"
    1
}

function Uninstall-CrApp {
    <#
      Removes Copilot Readiness from the current tenant: an admin signs in, the app is deleted
      from the tenant, then this PC's certificate for it is deleted and settings.json forgets it
      (the caller saves). Every PC using the app loses access; setting it up again makes a new one.
      Other tenants' apps and certificates on this PC are left alone: they share the app's name,
      so only this tenant's certificate is removed, by its thumbprint. Past results are kept.

      Throws only while the tenant step is going (signing in, or deleting the app), when nothing
      has changed. After that it carries on whatever happens: settings.json always forgets the
      deleted app, and a certificate that couldn't be deleted is reported, not thrown. Returns
      Deleted (how many apps were deleted from the tenant) and CertificateProblem (why the
      certificate couldn't be deleted, or nothing).
    #>
    param([Parameter(Mandatory)] $Settings, [switch] $DeviceLogin, [scriptblock] $Graph)
    if (-not $Settings.app.clientId) { throw "There's no app set up for $($Settings.tenant) on this PC." }
    if (-not $Graph) { $Graph = New-CrAdminGraph -Settings $Settings -DeviceLogin:$DeviceLogin }
    # The tenant first: if that fails, this PC keeps its certificate and nothing has changed.
    $deleted = Remove-CrAppFromTenant -Graph $Graph -AppId $Settings.app.clientId
    $problem = $null
    $thumbprint = "$($Settings.app.thumbprint)"
    try {
        if ($thumbprint -and (Test-Path -LiteralPath "Cert:\CurrentUser\My\$thumbprint")) {
            Remove-Item -LiteralPath "Cert:\CurrentUser\My\$thumbprint" -DeleteKey -Force -ErrorAction Stop
        }
    }
    catch { $problem = $_.Exception.Message }
    $Settings.app.clientId = ''
    $Settings.app.thumbprint = ''
    $Settings.app.createdAt = ''
    [pscustomobject]@{ Deleted = $deleted; CertificateProblem = $problem }
}
