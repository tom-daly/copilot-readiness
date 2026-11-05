<#
.SYNOPSIS
  Checks how the scan behaves when Microsoft says "slow down", with a pretend clock and
  pretend answers: waiting as asked, every worker waiting together, slowing down on
  SharePoint's RateLimit warnings, and giving up only after a long spell. Exits 1 if
  anything is off.

.EXAMPLE
  pwsh -File pnp/tests/Test-Throttling.ps1
#>
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\CopilotReadiness\CopilotReadiness.psm1') -Force
$module = Get-Module CopilotReadiness

$script:Start = [DateTime]::new(2026, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)

# Pretend answers are taken in turn; each request notes the pretend time it was sent.
$fake = @{ Answers = [System.Collections.Generic.Queue[object]]::new(); Sent = [System.Collections.Generic.List[double]]::new(); Clock = $script:Start; Start = $script:Start; Slept = 0.0 }
& $module {
    param($fake)
    $script:Fake = $fake
    function script:Get-CrToken { 'token' }
    function script:Get-CrUtcNow { $script:Fake.Clock }
    function script:Start-Sleep {
        param([int] $Seconds, [int] $Milliseconds)
        $ms = if ($Seconds) { $Seconds * 1000 } else { $Milliseconds }
        $script:Fake.Clock = $script:Fake.Clock.AddMilliseconds($ms)
        $script:Fake.Slept += $ms / 1000
    }
    function script:Invoke-WebRequest {
        $script:Fake.Sent.Add(($script:Fake.Clock - $script:Fake.Start).TotalSeconds)
        $a = $script:Fake.Answers.Dequeue()
        [pscustomobject]@{ StatusCode = $a.Status; Headers = $a.Headers; Content = '{"value":[1]}' }
    }
} $fake

function Reset-Fake {
    $fake.Answers.Clear(); $fake.Sent.Clear(); $fake.Slept = 0.0
    $fake.Clock = $script:Start
    Set-CrThrottle (New-CrThrottle)
}
function Answer([int] $status, [hashtable] $headers = @{}) {
    $h = @{}
    foreach ($k in $headers.Keys) { $h[$k] = [string[]]@("$($headers[$k])") }
    $fake.Answers.Enqueue(@{ Status = $status; Headers = $h })
}
$url = 'https://contoso.sharepoint.com/_api/web'

$problems = [System.Collections.Generic.List[string]]::new()
function Check([string] $what, [bool] $ok) { if (-not $ok) { $problems.Add($what) } }

try {
    # Waits as long as Microsoft asks, then continues.
    Reset-Fake
    Answer 429 @{ 'Retry-After' = 30 }; Answer 200
    $r = Invoke-CrGet $url
    Check "waits what Retry-After says (sent at $($fake.Sent -join ', '))" ($r.value[0] -eq 1 -and $fake.Sent[1] -ge 30 -and $fake.Sent[1] -lt 31 -and (Get-CrThrottle).Waits -eq 1)

    # Every worker waits: the next request, from any worker, holds back until the pause is over.
    Reset-Fake
    Answer 503 @{ 'retry-after' = 45 }; Answer 200; Answer 200
    $null = Invoke-CrGet $url
    Set-CrPause 60 -Throttled
    $null = Invoke-CrGet $url
    Check "a pause holds back every request (sent at $($fake.Sent -join ', '))" ($fake.Sent[1] -ge 45 -and $fake.Sent[2] -ge 105)

    # Retry-After as a date.
    Reset-Fake
    Answer 429 @{ 'Retry-After' = $fake.Clock.AddSeconds(20).ToString('R') }; Answer 200
    $null = Invoke-CrGet $url
    Check "Retry-After as a date (sent at $($fake.Sent -join ', '))" ($fake.Sent[1] -ge 20 -and $fake.Sent[1] -lt 21)

    # No Retry-After: waits longer each time.
    Reset-Fake
    Answer 429; Answer 429; Answer 429; Answer 200
    $null = Invoke-CrGet $url
    Check "backs off 2, 4, 8 seconds when not told (sent at $($fake.Sent -join ', '))" (($fake.Sent -join ',') -eq '0,2,6,14')

    # SharePoint's warning that the allowance is nearly gone: everything pauses until it resets.
    Reset-Fake
    Answer 200 @{ 'RateLimit-Limit' = 100; 'RateLimit-Remaining' = 5; 'RateLimit-Reset' = 25 }; Answer 200
    $null = Invoke-CrGet $url; $null = Invoke-CrGet $url
    Check "nearly out of allowance: pauses until it resets (sent at $($fake.Sent -join ', '))" ($fake.Sent[1] -ge 25 -and (Get-CrThrottle).Waits -eq 0)

    # Mostly used: slow mode, a short gap before each request until the reset.
    Reset-Fake
    Answer 200 @{ 'RateLimit-Limit' = 100; 'RateLimit-Remaining' = 60; 'RateLimit-Reset' = 10 }; Answer 200; Answer 200
    $null = Invoke-CrGet $url; $null = Invoke-CrGet $url
    $fake.Clock = $fake.Clock.AddSeconds(11)
    $null = Invoke-CrGet $url
    Check "mostly used: slows down until the reset (sent at $($fake.Sent -join ', '))" ($fake.Sent[1] -eq 0.5 -and $fake.Sent[2] -eq 11.5 -and $fake.Slept -eq 0.5)

    # Told to wait again and again: gives up after about 20 minutes, with the status.
    Reset-Fake
    1..20 | ForEach-Object { Answer 429 @{ 'Retry-After' = 300 } }
    $status = 0
    try { $null = Invoke-CrGet $url } catch { $status = Get-CrStatus $_ }
    Check "gives up after a long spell (status $status after $($fake.Slept) seconds)" ($status -eq 429 -and $fake.Slept -ge 15 * 60 -and $fake.Slept -le 20 * 60)

    # Other errors are not retried.
    Reset-Fake
    Answer 404
    $status = 0
    try { $null = Invoke-CrGet $url } catch { $status = Get-CrStatus $_ }
    Check 'a 404 is not retried' ($status -eq 404 -and $fake.Sent.Count -eq 1)

    # A pace spreads requests evenly: Normal (150 a minute) sends one every 0.4 seconds.
    Reset-Fake
    Set-CrThrottle (New-CrThrottle -PerMinute (Get-CrPace 'Normal').PerMinute)
    1..4 | ForEach-Object { Answer 200 }
    1..4 | ForEach-Object { $null = Invoke-CrGet $url }
    Check "Normal pace spaces requests (sent at $($fake.Sent -join ', '))" (($fake.Sent -join ',') -eq '0,0.4,0.8,1.2')

    # A request that comes after a quiet spell goes at once; the pace doesn't save up gaps.
    $fake.Clock = $fake.Clock.AddSeconds(10)
    Answer 200; Answer 200
    $null = Invoke-CrGet $url; $null = Invoke-CrGet $url
    Check "after a quiet spell it goes at once (sent at $($fake.Sent -join ', '))" ($fake.Sent[4] -eq 11.2 -and [Math]::Round($fake.Sent[5], 3) -eq 11.6)

    # Fast is quicker but still paced (300 a minute, one every 0.2 seconds); unpaced, nothing holds it back.
    Reset-Fake
    $t = New-CrThrottle
    Set-CrThrottlePace $t (Get-CrPace 'Fast') -Paced
    Set-CrThrottle $t
    1..3 | ForEach-Object { Answer 200 }
    1..3 | ForEach-Object { $null = Invoke-CrGet $url }
    Check "Fast pace is still paced (sent at $($fake.Sent -join ', '))" ($fake.Sent[0] -eq 0 -and [Math]::Abs($fake.Sent[1] - 0.2) -lt 0.002 -and [Math]::Abs($fake.Sent[2] - 0.4) -lt 0.002 -and $t.Sites -eq 4 -and $t.Pace -eq 'Fast')
    Set-CrThrottlePace $t (Get-CrPace 'Gentle')
    Check 'unpaced (the offline tests) has no limit, and the sites follow the pace' ($t.PerMinute -eq 0 -and $t.Sites -eq 2)
    Set-CrThrottlePace $t (Get-CrPace 'Fast') -Paced -Sites 3
    Check 'a fixed number of sites stays fixed' ($t.Sites -eq 3 -and $t.PerMinute -eq 300)
    Check 'an unknown pace (an older scan) is Normal' ((Get-CrPace $null).Id -eq 'Normal' -and (Get-CrPace 'Gentle').PerMinute -lt (Get-CrPace 'Normal').PerMinute -and (Get-CrPace 'Normal').PerMinute -lt (Get-CrPace 'Fast').PerMinute)

    # Told to wait: the scan eases off a step (half the requests a minute, one site fewer), once per spell of waiting.
    Reset-Fake
    $t = New-CrThrottle
    Set-CrThrottlePace $t (Get-CrPace 'Normal') -Paced
    Set-CrThrottle $t
    Answer 429 @{ 'Retry-After' = 30 }; Answer 200
    $null = Invoke-CrGet $url
    Check "a wait eases off one step (got $($t.EaseSteps) steps, $($t.PerMinute) a minute, $($t.Sites) sites)" ($t.EaseSteps -eq 1 -and $t.PerMinute -eq 75 -and $t.Sites -eq 2)
    Set-CrPause 20 -Throttled; Set-CrPause 25 -Throttled
    Check "several sites told to wait in the same spell count once (got $($t.EaseSteps))" ($t.EaseSteps -eq 2)
    Set-CrPause 20 -Throttled
    Check "a wait during a wait doesn't step down again (got $($t.EaseSteps))" ($t.EaseSteps -eq 2 -and $t.PerMinute -eq 37 -and $t.Sites -eq 1)
    foreach ($i in 1..3) { $fake.Clock = $fake.Clock.AddMinutes(1); Set-CrPause 10 -Throttled }
    Check "easing off stops at three steps (got $($t.EaseSteps), $($t.PerMinute) a minute)" ($t.EaseSteps -eq 3 -and $t.PerMinute -eq 18 -and $t.Sites -eq 1)

    # Choosing another pace keeps the easing off; Gentle never drops below 10 a minute.
    Set-CrThrottlePace $t (Get-CrPace 'Gentle') -Paced
    Check "a new pace keeps the easing off, with a floor (got $($t.PerMinute) a minute)" ($t.EaseSteps -eq 3 -and $t.PerMinute -eq 10)
    Set-CrThrottlePace $t (Get-CrPace 'Normal') -Paced

    # Ten minutes without a wait steps back up, one step at a time, until the pace is back.
    $fake.Clock = $t.EaseUntil
    Update-CrEase $t
    Check "steps back up after a quiet spell (got $($t.EaseSteps), $($t.PerMinute) a minute)" ($t.EaseSteps -eq 2 -and $t.PerMinute -eq 37)
    Update-CrEase $t
    Check 'but only one step per spell' ($t.EaseSteps -eq 2)
    $fake.Clock = $t.EaseUntil; Update-CrEase $t
    $fake.Clock = $t.EaseUntil; Update-CrEase $t
    Check "back to the pace (got $($t.EaseSteps), $($t.PerMinute) a minute, $($t.Sites) sites)" ($t.EaseSteps -eq 0 -and $t.PerMinute -eq 150 -and $t.Sites -eq 3)

    # The throttle is shared between threads, as the scan's workers share it.
    $shared = New-CrThrottle
    $modulePath = Join-Path $PSScriptRoot '..\CopilotReadiness\CopilotReadiness.psm1'
    Start-ThreadJob -ArgumentList $modulePath, $shared { param($m, $t) Import-Module $m; Set-CrThrottle $t; Set-CrPause 30 -Throttled } | Receive-Job -Wait -AutoRemoveJob
    Check 'a pause set by one worker is seen by the others' ($shared.Waits -eq 1 -and $shared.PauseUntil -gt [DateTime]::UtcNow.AddSeconds(20))
}
catch {
    $problems.Add("threw: $($_.Exception.Message) at $($_.InvocationInfo.PositionMessage)")
}

if ($problems.Count) {
    Write-Host "$($problems.Count) throttling checks failed" -ForegroundColor Red
    $problems | ForEach-Object { Write-Host "  FAIL $_" }
    exit 1
}
Write-Host 'Throttling checks passed' -ForegroundColor Green
