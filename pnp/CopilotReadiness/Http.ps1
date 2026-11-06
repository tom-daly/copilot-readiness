# SharePoint REST and Microsoft Graph, app-only, with the access token PnP holds for
# the current connection. Requests go out with Invoke-WebRequest rather than PnP's own
# REST cmdlets so throttling can be handled here: any 429
# or 503 waits for Retry-After (or backs off) and tries again.
#
# Microsoft limits the app as a whole, not each request, so the sites scanned at once
# share one throttle: when Microsoft says wait, they all wait, and the chosen pace caps
# requests a minute across all of them. Microsoft says SharePoint doesn't send RateLimit
# headers, so the pace is what keeps the scan clear of the limits; if a service ever does
# send them, the scan slows down when it sees them and pauses when the allowance is nearly gone.

$script:UserAgent = 'ISV|ThomasDaly|CopilotReadiness-PnP/1.0'
$script:GraphRoot = 'https://graph.microsoft.com/v1.0'
$script:Tokens = @{}

# How long one request keeps trying while Microsoft says wait, before its site is given up on.
$script:ThrottlePatienceMinutes = 20
# Gap before each request while SharePoint says the allowance is mostly used.
$script:SlowGapMilliseconds = 500
# A RateLimit-Remaining at or below this share of RateLimit-Limit pauses everything until RateLimit-Reset.
$script:PauseAtRemaining = 0.1
# Easing off: each time Microsoft says wait, the scan steps down (half the requests a minute,
# one site fewer at a time), up to this many steps; it steps back up one at a time after
# this many minutes without being told to wait.
$script:MaxEaseSteps = 3
$script:EaseMinutes = 10
# Never slower than this many requests a minute while easing off.
$script:EaseFloorPerMinute = 10

function New-CrThrottle {
    <#
      The shared throttle: when to continue, when slow mode ends, how often Microsoft said
      wait, and the pace: at most PerMinute requests a minute across every worker (0 for no
      limit), each taking the next free slot, and Sites at once. PerMinute and Sites are the
      pace's own (BasePerMinute, BaseSites) less any easing off (EaseSteps, until EaseUntil).
      Safe to share between threads.
    #>
    param([int] $PerMinute = 0)
    [hashtable]::Synchronized(@{
            PauseUntil = [DateTime]::MinValue; SlowUntil = [DateTime]::MinValue; Waits = 0; NextSlot = [DateTime]::MinValue; Pace = $null
            PerMinute = $PerMinute; Sites = 1; BasePerMinute = $PerMinute; BaseSites = 1; EaseSteps = 0; EaseUntil = [DateTime]::MinValue
        })
}

function Update-CrEase {
    <#
      Works out the throttle's requests a minute and sites at once from its pace and how
      far it has eased off, first stepping back up once a spell has passed without Microsoft
      saying wait. Called with the throttle's lock held, or on its own.
    #>
    param([Parameter(Mandatory)] [hashtable] $Throttle)
    [System.Threading.Monitor]::Enter($Throttle.SyncRoot)
    try {
        $now = Get-CrUtcNow
        if ([int]$Throttle.EaseSteps -gt 0 -and $now -ge $Throttle.EaseUntil) {
            $Throttle.EaseSteps = [int]$Throttle.EaseSteps - 1
            $Throttle.EaseUntil = $now.AddMinutes($script:EaseMinutes)
        }
        $steps = [int]$Throttle.EaseSteps
        $base = [int]$Throttle.BasePerMinute
        $Throttle.PerMinute = if ($base -le 0) { 0 } else { [Math]::Max([Math]::Min($base, $script:EaseFloorPerMinute), [int][Math]::Floor($base / [Math]::Pow(2, $steps))) }
        $Throttle.Sites = [Math]::Max(1, [int]$Throttle.BaseSites - $steps)
    }
    finally { [System.Threading.Monitor]::Exit($Throttle.SyncRoot) }
}

function Set-CrThrottlePace {
    <#
      Puts a throttle on a pace (Get-CrPace): its requests a minute (only when Paced; the
      offline tests run unpaced) and its sites at once, unless Sites fixes that number.
      Workers see the change at once, so it can be called while a scan runs.
    #>
    param([Parameter(Mandatory)] [hashtable] $Throttle, [Parameter(Mandatory)] $Pace, [switch] $Paced, [int] $Sites = 0)
    # A new pace keeps any easing off: if Microsoft has just said wait, the scan still steps back up gradually.
    $Throttle.BasePerMinute = if ($Paced) { [int]$Pace.PerMinute } else { 0 }
    $Throttle.BaseSites = if ($Sites -gt 0) { $Sites } else { [int]$Pace.Sites }
    $Throttle.Pace = $Pace.Id
    Update-CrEase $Throttle
}

$script:Throttle = New-CrThrottle

function Get-CrThrottle { $script:Throttle }

function Set-CrThrottle {
    <# Makes this module use a throttle shared with other scan workers. #>
    param([Parameter(Mandatory)] [hashtable] $Throttle)
    $script:Throttle = $Throttle
}

function Get-CrUtcNow { [DateTime]::UtcNow }

# Stopping: once this file exists (the progress window's Stop button makes it), the next
# request or step throws, and the site in progress is left to be started again later.
$script:StopFile = $null

function Set-CrStopFile {
    param([string] $Path)
    $script:StopFile = $Path
}

function Assert-CrNotStopped {
    if ($script:StopFile -and [System.IO.File]::Exists($script:StopFile)) { throw [System.OperationCanceledException]::new('The scan was stopped.') }
}

function Set-CrPause {
    <#
      Holds every request back for this many seconds, unless a longer pause is already set.
      Throttled (Microsoft said wait) also eases the scan off one step, once per spell of
      waiting: several sites told to wait at the same moment count as one.
    #>
    param([Parameter(Mandatory)] [double] $Seconds, [switch] $Throttled)
    $now = Get-CrUtcNow
    $until = $now.AddSeconds($Seconds)
    [System.Threading.Monitor]::Enter($script:Throttle.SyncRoot)
    try {
        $newSpell = $script:Throttle.PauseUntil -le $now
        if ($until -gt $script:Throttle.PauseUntil) { $script:Throttle.PauseUntil = $until }
        if ($Throttled) {
            $script:Throttle.Waits++
            if ($newSpell) {
                $script:Throttle.EaseSteps = [Math]::Min($script:MaxEaseSteps, [int]$script:Throttle.EaseSteps + 1)
                $script:Throttle.EaseUntil = $until.AddMinutes($script:EaseMinutes)
                Update-CrEase $script:Throttle
            }
        }
    }
    finally { [System.Threading.Monitor]::Exit($script:Throttle.SyncRoot) }
}

function Wait-CrThrottle {
    <# Waits out a shared pause, then leaves a gap while in slow mode. #>
    while ($true) {
        Assert-CrNotStopped
        $left = ($script:Throttle.PauseUntil - (Get-CrUtcNow)).TotalMilliseconds
        if ($left -le 0) { break }
        Start-Sleep -Milliseconds ([int][Math]::Min(5000, [Math]::Ceiling($left)))
    }
    if ($script:Throttle.SlowUntil -gt (Get-CrUtcNow)) { Start-Sleep -Milliseconds $script:SlowGapMilliseconds }

    # The pace: requests are spread evenly, one slot each, however many workers are asking.
    if ([int]$script:Throttle.EaseSteps -gt 0) { Update-CrEase $script:Throttle }
    $perMinute = [int]$script:Throttle.PerMinute
    if ($perMinute -le 0) { return }
    [System.Threading.Monitor]::Enter($script:Throttle.SyncRoot)
    try {
        $now = Get-CrUtcNow
        $slot = if ($script:Throttle.NextSlot -gt $now) { $script:Throttle.NextSlot } else { $now }
        $script:Throttle.NextSlot = $slot.AddMilliseconds(60000.0 / $perMinute)
    }
    finally { [System.Threading.Monitor]::Exit($script:Throttle.SyncRoot) }
    $wait = ($slot - $now).TotalMilliseconds
    if ($wait -gt 0) { Start-Sleep -Milliseconds ([int][Math]::Ceiling($wait)) }
}

function Get-CrHeader {
    <# A response header's first value, whatever its case, or nothing. #>
    param($Headers, [string] $Name)
    foreach ($key in @($Headers.Keys)) {
        if ($key -ieq $Name) { return "$(@($Headers[$key])[0])" }
    }
}

function Get-CrRetryAfter {
    <# Seconds Microsoft asked to wait (Retry-After as seconds or a date), or Fallback when it didn't say. #>
    param($Headers, [double] $Fallback)
    $value = Get-CrHeader $Headers 'Retry-After'
    $seconds = 0
    if ($value -and [int]::TryParse($value, [ref]$seconds)) { return [Math]::Max(1, $seconds) }
    $date = [DateTimeOffset]::MinValue
    if ($value -and [DateTimeOffset]::TryParse($value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$date)) {
        return [Math]::Max(1, ($date.UtcDateTime - (Get-CrUtcNow)).TotalSeconds)
    }
    $Fallback
}

function Update-CrPace {
    <#
      SharePoint's RateLimit headers appear once the app has used most of its allowance.
      Nearly gone: everything pauses until it resets. Otherwise: slow mode until then.
    #>
    param($Headers)
    $limit = 0; $remaining = 0; $reset = 0
    if (-not [int]::TryParse((Get-CrHeader $Headers 'RateLimit-Limit'), [ref]$limit) -or
        -not [int]::TryParse((Get-CrHeader $Headers 'RateLimit-Remaining'), [ref]$remaining) -or
        -not [int]::TryParse((Get-CrHeader $Headers 'RateLimit-Reset'), [ref]$reset) -or $limit -le 0) { return }
    if ($remaining -le $limit * $script:PauseAtRemaining) { Set-CrPause ([Math]::Max(1, $reset)) }
    else {
        $until = (Get-CrUtcNow).AddSeconds([Math]::Max(1, $reset))
        if ($until -gt $script:Throttle.SlowUntil) { $script:Throttle.SlowUntil = $until }
    }
}

# Until when a refused certificate is worth waiting on: soon after it was added. Later than that,
# a refusal means something is really wrong (say an admin removed it), so it isn't waited on.
$script:CertificateWaitUntil = [DateTime]::MinValue
$script:CertificateWaitOn = $true

function Set-CrCertificateWait {
    <# Off is for a caller that shows its own wait, as the setup screen does. #>
    param([Parameter(Mandatory)] [bool] $On)
    $script:CertificateWaitOn = $On
}

function Invoke-CrCertificateWait {
    <#
      Runs Do, and if Microsoft doesn't recognise a new certificate yet (AADSTS700027), waits and
      tries again. A new certificate can be accepted by some of Microsoft's servers and refused by
      others for some minutes, so one that has just worked can still be refused. Other errors go
      straight back to the caller. Pressing Stop ends the wait within a second.
    #>
    param([Parameter(Mandatory)] [scriptblock] $Do, [Nullable[DateTime]] $Until, [int] $Every = 15, [scriptblock] $Sleep)
    $limit = if ($Until) { $Until } else { $script:CertificateWaitUntil }
    $said = $false
    $note = $script:Step
    $before = if ($note) { $note.doing }
    try {
        while ($true) {
            try { return & $Do }
            catch {
                if (-not $script:CertificateWaitOn -or $_.Exception.Message -notmatch 'AADSTS700027' -or [DateTime]::UtcNow -ge $limit) { throw }
                if (-not $said) {
                    Write-Host "$(Get-Date -Format 'h:mm:ss tt')  Microsoft isn't accepting this computer's new certificate yet. Waiting; this is normal."
                    if ($note) { $note.doing = "Waiting for Microsoft to accept this computer's new certificate" }
                    $said = $true
                }
                if ($Sleep) { & $Sleep $Every }
                else { foreach ($second in 1..$Every) { Assert-CrNotStopped; Start-Sleep -Seconds 1 } }
            }
        }
    }
    finally { if ($said -and $note) { $note.doing = $before } }
}

function Connect-CrTenant {
    <# Signs in as the scanner app with the certificate in the Windows certificate store. Settings come from settings.json. #>
    param([Parameter(Mandatory)] $Settings)
    $added = [DateTimeOffset]::MinValue
    $script:CertificateWaitUntil = if ([DateTimeOffset]::TryParse("$($Settings.app.createdAt)", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$added)) { $added.UtcDateTime.AddMinutes(30) } else { [DateTime]::MinValue }
    Invoke-CrCertificateWait { Connect-PnPOnline -Url $Settings.sharePointUrl -ClientId $Settings.app.clientId -Tenant $Settings.tenant -Thumbprint $Settings.app.thumbprint -ErrorAction Stop }
    $script:Tokens = @{}
}

function Get-CrToken {
    param([switch] $Graph)
    $key = if ($Graph) { 'Graph' } else { 'SharePoint' }
    $cached = $script:Tokens[$key]
    if (-not $cached -or $cached.Until -lt [DateTime]::UtcNow) {
        $cached = @{ Value = (Invoke-CrCertificateWait { Get-PnPAccessToken -ResourceTypeName $key }); Until = [DateTime]::UtcNow.AddMinutes(30) }
        $script:Tokens[$key] = $cached
    }
    $cached.Value
}

function ConvertFrom-CrJson {
    <#
      Parses a response. Dates stay text, so they are read exactly as sent.
      SharePoint list items carry both "Id" and "ID", which a PowerShell object
      can't hold, so such a response is parsed loosely and keeps the first of each pair.
    #>
    param([string] $Json)
    try {
        $Json | ConvertFrom-Json -Depth 64 -DateKind String
    }
    catch {
        $original = $_
        try { $loose = $Json | ConvertFrom-Json -Depth 64 -DateKind String -AsHashtable } catch { throw $original }
        ConvertTo-CrObject $loose
    }
}

function ConvertTo-CrObject {
    <# Parsed JSON as objects, dropping keys that differ from an earlier one only by case. #>
    param($Value)
    if ($Value -is [System.Collections.IDictionary]) {
        $props = [ordered]@{} # ignores case, so the second of "Id"/"ID" is skipped
        foreach ($key in $Value.Keys) {
            if (-not $props.Contains($key)) { $props[$key] = ConvertTo-CrObject $Value[$key] }
        }
        return [pscustomobject]$props
    }
    if ($Value -is [System.Collections.IList]) {
        return , @(foreach ($item in $Value) { ConvertTo-CrObject $item })
    }
    $Value
}

function Get-CrStatus {
    <# The HTTP status an Invoke-CrGet error carries, or 0 for anything else. #>
    param($ErrorRecord)
    $ex = if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) { $ErrorRecord.Exception } else { $ErrorRecord }
    if ($ex -and $ex.Data.Contains('Status')) { [int]$ex.Data['Status'] } else { 0 }
}

function Invoke-CrGet {
    <#
      One request: a GET, unless Method says otherwise, with Body sent as JSON. Only the
      Remediation tab's fixes send anything else; the scan only reads. ExtraHeaders are sent
      too (such as the Prefer header Graph's change lists need). Returns the parsed JSON;
      throws with Data.Status set when the answer is an error.
    #>
    param(
        [Parameter(Mandatory)] [string] $Url,
        [switch] $AdvancedQuery,
        [ValidateSet('GET', 'POST')] [string] $Method = 'GET',
        $Body,
        # Not called Headers: PowerShell ignores case, so that would be the same variable as $headers below.
        [hashtable] $ExtraHeaders = @{}
    )
    $isGraph = $Url.StartsWith('https://graph.microsoft.com/', [StringComparison]::OrdinalIgnoreCase)
    $delay = 2
    $giveUpAt = (Get-CrUtcNow).AddMinutes($script:ThrottlePatienceMinutes)
    $send = @{}
    if ($Method -ne 'GET') {
        $send.Method = $Method
        $send.Body = if ($null -eq $Body) { '{}' } else { ConvertTo-Json -InputObject $Body -Depth 10 -Compress }
        $send.ContentType = if ($isGraph) { 'application/json' } else { 'application/json;odata=nometadata' }
    }

    for ($attempt = 1; ; $attempt++) {
        Wait-CrThrottle
        $headers = @{
            Authorization = "Bearer $(Get-CrToken -Graph:$isGraph)"
            Accept        = if ($isGraph) { 'application/json' } else { 'application/json;odata=nometadata' }
        }
        if ($AdvancedQuery) { $headers.ConsistencyLevel = 'eventual' }
        foreach ($name in $ExtraHeaders.Keys) { $headers[$name] = $ExtraHeaders[$name] }

        try {
            $resp = Invoke-WebRequest -Uri $Url -Headers $headers -UserAgent $script:UserAgent -SkipHttpErrorCheck -ErrorAction Stop @send
        }
        catch {
            # Network trouble rather than an answer: retry a few times, then give up. Only reads are
            # sent again; a change (a POST) may have been made before the answer was lost, so the
            # caller looks to see whether it was (as Remove does) rather than making it twice.
            if ($attempt -ge 4 -or $Method -ne 'GET') { throw }
            Start-Sleep -Seconds $delay
            $delay = [Math]::Min($delay * 2, 60)
            continue
        }

        $status = [int]$resp.StatusCode
        if ($status -ge 200 -and $status -lt 300) {
            Update-CrPace $resp.Headers
            return ConvertFrom-CrJson $resp.Content
        }

        if ($status -in 429, 503) {
            # Every worker waits, not just this one; give up only after a long spell of being told to wait.
            $wait = Get-CrRetryAfter $resp.Headers $delay
            if ((Get-CrUtcNow).AddSeconds($wait) -lt $giveUpAt) {
                Write-Verbose "Throttled ($status); everything waits $wait seconds"
                Set-CrPause $wait -Throttled
                $delay = [Math]::Min($delay * 2, 300)
                continue
            }
        }

        if ($status -eq 401 -and $attempt -eq 1) {
            # Token expired early: get a new one and try once more.
            $script:Tokens = @{}
            continue
        }

        $body = "$($resp.Content)"
        if ($body.Length -gt 300) { $body = $body.Substring(0, 300) }
        $ex = [System.Net.Http.HttpRequestException]::new("HTTP $status from $($Url.Split('?')[0]): $body")
        $ex.Data['Status'] = $status
        throw $ex
    }
}

function Invoke-CrPost {
    <# One POST to SharePoint with a JSON body. #>
    param([Parameter(Mandatory)] [string] $Url, $Body)
    Invoke-CrGet -Url $Url -Method POST -Body $Body
}

function Get-CrPage {
    <# One page of a SharePoint collection: Items and the Next page's URL, if any. #>
    param([Parameter(Mandatory)] [string] $Url)
    $root = Invoke-CrGet $Url
    [pscustomobject]@{ Items = @($root.value); Next = $root.'odata.nextLink' }
}

function Get-CrAll {
    <# Every item of a SharePoint collection, following next links. #>
    param([Parameter(Mandatory)] [string] $Url)
    $all = [System.Collections.Generic.List[object]]::new()
    $next = $Url
    while ($next) {
        $page = Get-CrPage $next
        $all.AddRange([object[]]$page.Items)
        $next = $page.Next
    }
    , $all.ToArray()
}

function Invoke-CrGraph {
    param([Parameter(Mandatory)] [string] $Path, [switch] $AdvancedQuery)
    $url = if ($Path.StartsWith('https://', [StringComparison]::OrdinalIgnoreCase)) { $Path } else { "$script:GraphRoot/$($Path.TrimStart('/'))" }
    Invoke-CrGet $url -AdvancedQuery:$AdvancedQuery
}

function Get-CrGraphAll {
    <# Every item of a Graph collection, up to Max. #>
    param([Parameter(Mandatory)] [string] $Path, [switch] $AdvancedQuery, [int] $Max = [int]::MaxValue)
    $all = [System.Collections.Generic.List[object]]::new()
    $next = $Path
    while ($next -and $all.Count -lt $Max) {
        $root = Invoke-CrGraph $next -AdvancedQuery:$AdvancedQuery
        if ($root.value) { $all.AddRange([object[]]@($root.value)) }
        $next = $root.'@odata.nextLink'
    }
    if ($all.Count -gt $Max) { , $all.GetRange(0, $Max).ToArray() } else { , $all.ToArray() }
}
