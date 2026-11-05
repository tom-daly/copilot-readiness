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
      until the list is right. Graph is what New-CrAdminGraph returns.
    #>
    param(
        [Parameter(Mandatory)] [scriptblock] $Graph,
        [Parameter(Mandatory)] [string] $AppName,
        [Parameter(Mandatory)] [System.Security.Cryptography.X509Certificates.X509Certificate2] $Certificate,
        [string] $Replace,
        [int] $Checks = 6,
        [scriptblock] $Sleep = { Start-Sleep -Seconds (Get-Random -Minimum 10 -Maximum 21) }
    )
    $filter = [uri]::EscapeDataString("displayName eq '$($AppName.Replace("'", "''"))'")
    $apps = @((& $Graph GET "applications?`$filter=$filter&`$select=id,appId,displayName").value)
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
        if ($wrote) { try { Remove-CrCertificateFromApp -Graph $Graph -ObjectId $found.id -Thumbprint $Certificate.Thumbprint } catch { } }
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
