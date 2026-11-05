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

function Add-CrCertificateToApp {
    <#
      Finds the tenant's app by name and adds this PC's certificate to it. Returns AppId,
      and Accepted: whether the app's permissions have been accepted in this tenant.
      Graph is what New-CrAdminGraph returns.
    #>
    param(
        [Parameter(Mandatory)] [scriptblock] $Graph,
        [Parameter(Mandatory)] [string] $AppName,
        [Parameter(Mandatory)] [System.Security.Cryptography.X509Certificates.X509Certificate2] $Certificate
    )
    $filter = [uri]::EscapeDataString("displayName eq '$($AppName.Replace("'", "''"))'")
    $apps = @((& $Graph GET "applications?`$filter=$filter&`$select=id,appId,displayName,keyCredentials").value)
    if ($apps.Count -eq 0) { throw "Microsoft said the app '$AppName' already exists, but it can't be found. Check you signed in as a Global Administrator, then start again." }
    if ($apps.Count -gt 1) {
        throw ("This tenant has $($apps.Count) apps called '$AppName', with these app IDs: $($apps.appId -join ', '). " +
            'In the Entra admin center, under App registrations, delete the ones nobody uses so that one is left, then start again.')
    }
    $found = $apps[0]
    $before = @($found.keyCredentials)
    $list = Merge-CrKeyCredentials -Existing $before -Certificate $Certificate
    if ($list) {
        $null = & $Graph PATCH "applications/$($found.id)" ([pscustomobject]@{ keyCredentials = $list })
        # Make sure nothing was lost, so a PC already using this app isn't quietly locked out.
        $after = @((& $Graph GET "applications/$($found.id)?`$select=keyCredentials").keyCredentials)
        $missing = @($before | Where-Object { $after.keyId -notcontains $_.keyId })
        if ($missing.Count -or $after.Count -ne $before.Count + 1) {
            throw "After adding this PC's certificate, '$AppName' had $($after.Count) certificates instead of $($before.Count + 1). Check it in the Entra admin center under App registrations > Certificates & secrets."
        }
    }
    $principals = @((& $Graph GET "servicePrincipals?`$filter=appId eq '$($found.appId)'&`$select=id").value)
    $accepted = $false
    if ($principals.Count) { $accepted = @((& $Graph GET "servicePrincipals/$($principals[0].id)/appRoleAssignments").value).Count -gt 0 }
    [pscustomobject]@{ AppId = "$($found.appId)"; Accepted = $accepted }
}

function Get-CrAppCertificates {
    <# The certificates in this Windows account's store that were made for the app. #>
    param([Parameter(Mandatory)] [string] $AppName)
    @(Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.Subject -eq "CN=$AppName" })
}

function Remove-CrSetupLeftovers {
    <#
      After setup, whether it worked or not: removes the copies of the private key from the
      certificate folder, and any certificate made during this run that nothing uses.
    #>
    param([Parameter(Mandatory)] [string] $CertificateFolder, [Parameter(Mandatory)] [string] $AppName, [string[]] $CertificatesBefore = @(), [string] $Keep)
    if (Test-Path -LiteralPath $CertificateFolder) {
        Get-ChildItem -LiteralPath $CertificateFolder -File | Where-Object Extension -In '.pfx', '.cer' | Remove-Item -Force
    }
    Get-CrAppCertificates $AppName | Where-Object { $CertificatesBefore -notcontains $_.Thumbprint -and $_.Thumbprint -ne $Keep } | Remove-Item -Force
}
