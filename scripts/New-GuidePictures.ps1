<#
.SYNOPSIS
  Takes the pictures in the guide (docs/): the real windows and report, filled with a made-up Contoso tenant.

.DESCRIPTION
  Never signs in to a tenant and never reads pnp/results or pnp/settings.json, so no real
  names can end up in a picture. Windows are captured on their own, so whatever else is on
  the screen stays out, but they do flash up while it runs. Run it again when a window changes.

.EXAMPLE
  pwsh -STA -File scripts/New-GuidePictures.ps1
#>
param(
    [string] $OutFolder = (Join-Path $PSScriptRoot '..\docs\pictures'),
    [string] $Chrome = 'C:\Program Files\Google\Chrome\Application\chrome.exe'
)
$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..')
Import-Module (Join-Path $root 'pnp\CopilotReadiness\CopilotReadiness.psm1') -Force
Add-Type -AssemblyName System.Windows.Forms, System.Drawing, UIAutomationClient, UIAutomationTypes
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class CrSnap {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hwnd, IntPtr hdc, uint flags);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out RECT r);
    [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr hwnd, int attr, out RECT r, int size);
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc f, IntPtr l);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    public static IntPtr FindOwn(uint pid, string title) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, l) => {
            uint p; GetWindowThreadProcessId(h, out p);
            if (p != pid || !IsWindowVisible(h)) return true;
            var s = new StringBuilder(256); GetWindowText(h, s, 256);
            if (s.ToString() == title) { found = h; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }
    public static RECT Frame(IntPtr h) { RECT r; if (DwmGetWindowAttribute(h, 9, out r, Marshal.SizeOf(typeof(RECT))) != 0) GetWindowRect(h, out r); return r; }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern uint GetLongPathName(string s, StringBuilder l, uint n);
    public static string LongPath(string p) { var s = new StringBuilder(1024); return GetLongPathName(p, s, 1024) > 0 ? s.ToString() : p; }
}
'@
# Every position (window edges, buttons, Explorer's items) in real screen pixels, so crops and
# red boxes land in the right place whatever the display scaling. Must come before any window.
[void][System.Windows.Forms.Application]::SetHighDpiMode('PerMonitorV2')

New-Item -ItemType Directory -Path $OutFolder -Force | Out-Null
$OutFolder = (Resolve-Path $OutFolder).Path
# The temp folder can come back in its short form (THOMAS~1); Explorer reports the full one.
$work = Join-Path ([CrSnap]::LongPath([IO.Path]::GetTempPath())) "cr-guide-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
New-Item -ItemType Directory -Path $work | Out-Null

function Pump([int] $Ms = 800) {
    $until = [DateTime]::UtcNow.AddMilliseconds($Ms)
    while ([DateTime]::UtcNow -lt $until) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 20 }
}
function Find-Control($Parent, [string] $Text) {
    foreach ($c in $Parent.Controls) {
        if ($c.Text -eq $Text -and $c.Visible) { return $c }
        $hit = Find-Control $c $Text
        if ($hit) { return $hit }
    }
}
function Find-Type($Parent, [type] $Type) {
    foreach ($c in $Parent.Controls) {
        if ($c -is $Type) { return $c }
        $hit = Find-Type $c $Type
        if ($hit) { return $hit }
    }
}
function Save-Window([IntPtr] $Handle, [string] $Name, [System.Drawing.Rectangle[]] $Marks = @(), [System.Drawing.Rectangle] $Crop = [System.Drawing.Rectangle]::Empty) {
    <# Saves the window alone, with a red box round each mark. Marks and Crop are in screen coordinates. #>
    $outer = [CrSnap+RECT]::new(); [void][CrSnap]::GetWindowRect($Handle, [ref]$outer)
    $frame = [CrSnap]::Frame($Handle)
    $full = [System.Drawing.Bitmap]::new($outer.Right - $outer.Left, $outer.Bottom - $outer.Top)
    $g = [System.Drawing.Graphics]::FromImage($full)
    $hdc = $g.GetHdc()
    [void][CrSnap]::PrintWindow($Handle, $hdc, 2)
    $g.ReleaseHdc($hdc); $g.Dispose()
    $area = if ($Crop.IsEmpty) { [System.Drawing.Rectangle]::FromLTRB($frame.Left, $frame.Top, $frame.Right, $frame.Bottom) } else { $Crop }
    $image = [System.Drawing.Bitmap]::new($area.Width, $area.Height)
    $g = [System.Drawing.Graphics]::FromImage($image)
    $g.DrawImage($full, [System.Drawing.Rectangle]::new(0, 0, $area.Width, $area.Height), [System.Drawing.Rectangle]::new($area.Left - $outer.Left, $area.Top - $outer.Top, $area.Width, $area.Height), 'Pixel')
    $g.SmoothingMode = 'AntiAlias'
    $pen = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(220, 30, 30), 3)
    foreach ($m in $Marks) { $g.DrawRectangle($pen, $m.Left - $area.Left - 5, $m.Top - $area.Top - 5, $m.Width + 10, $m.Height + 10) }
    $g.Dispose(); $full.Dispose()
    $image.Save((Join-Path $OutFolder $Name), [System.Drawing.Imaging.ImageFormat]::Png)
    $image.Dispose()
    Write-Host "  $Name"
}
function Save-Form($Form, [string] $Name, [object[]] $Mark = @()) {
    Pump 400
    $marks = @($Mark | Where-Object { $_ } | ForEach-Object { $_.Parent.RectangleToScreen($_.Bounds) })
    Save-Window $Form.Handle $Name $marks
}

# ── A made-up tenant ────────────────────────────────────────────────────────

$tenant = 'contoso.onmicrosoft.com'
$sharePoint = 'https://contoso.sharepoint.com'
$spNames = 'Board Documents', 'Company Intranet', 'Finance', 'Human Resources', 'IT Help Desk', 'Legal', 'Marketing', 'Product Launch', 'Project Apollo', 'Sales Proposals', 'Staff Handbook', 'Supplier Contracts'
$people = 'Adele Vance', 'Alex Wilber', 'Diego Siciliani', 'Isaiah Langer', 'Lee Gu', 'Lynne Robbins', 'Megan Bowen', 'Nestor Wilke', 'Patti Fernandez', 'Pradeep Gupta'
$sites = @(
    foreach ($n in $spNames) { [pscustomobject]@{ siteId = "contoso.sharepoint.com,$($n -replace ' '),1"; url = "$sharePoint/sites/$($n -replace ' ')"; title = $n; kind = 'SharePoint' } }
    foreach ($n in $people) { [pscustomobject]@{ siteId = "contoso-my.sharepoint.com,$($n -replace ' '),1"; url = "https://contoso-my.sharepoint.com/personal/$(($n -replace ' ', '_').ToLower())_contoso_com"; title = $n; kind = 'OneDrive' } }
)

function New-DemoScan([string] $Results, [string] $Started, [int] $Seed, [string] $Level = 'Quick') {
    <#
      A finished scan of the made-up tenant. Each site gets made-up facts and shared files; the
      module's own rule, score and report code turn them into findings, scores and the report,
      just as a real scan does, so the pictures follow the rule book.
    #>
    $random = [Random]::new($Seed)
    $now = [DateTimeOffset]::Parse($Started, [Globalization.CultureInfo]::InvariantCulture)
    $stamp = { param([DateTimeOffset] $t) $t.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") }
    $staleDays = (Get-CrRuleBook).thresholds.staleDays
    $folder = New-CrScan -ResultsRoot $Results -Level $Level -Sites $sites -Tenant $tenant
    $scanFile = Join-Path $folder 'scan.json'
    $scan = Read-CrJson $scanFile
    $scan.startedAt = & $stamp $now
    Write-CrJson $scanFile $scan

    $files = 'Budget 2026.xlsx', 'Salaries.xlsx', 'Offer letter.docx', 'Board update.pptx', 'Customer list.xlsx', 'Contract draft.docx', 'Team photo.jpg', 'Roadmap.pptx'
    $link = {
        param($Site, [string] $Path, [string] $Login, [bool] $Anyone)
        if ($Anyone) { New-CrFinding -Site $Site -ObjectType File -Path $Path -Rule AnyoneLink -Principal 'Anyone with the link' -PrincipalLogin $Login -Permission $(if ($random.Next(2)) { 'View' } else { 'Edit' }) -Now $now }
        else { New-CrFinding -Site $Site -ObjectType File -Path $Path -Rule OrgWideLink -Principal 'People in your organization with the link' -PrincipalLogin $Login -Permission 'Edit' -Now $now }
    }
    foreach ($s in $sites) {
        $own = [System.Collections.Generic.List[object]]::new()
        if ($s.kind -eq 'OneDrive') {
            $owners = 1; $guests = 0; $label = $null
            $last = $now.AddDays(-$random.Next(1, 30))
            foreach ($i in 1..$random.Next(1, 7)) {
                $own.Add((& $link $s "Documents/$($files[$random.Next($files.Count)])" "link$i" ($random.Next(3) -eq 0)))
            }
        }
        else {
            # Facts first; the rule code decides which of the owner, label and stale issues they raise.
            $owners = @(0, 1, 1, 2, 2, 3)[$random.Next(6)]
            $label = if ($random.Next(2)) { @('General', 'Confidential')[$random.Next(2)] } else { $null }
            $last = if ($random.Next(4) -eq 0) { $now.AddDays(-($staleDays + $random.Next(10, 200))) } else { $now.AddDays(-$random.Next(1, 60)) }
            $guests = 0
            if ($random.Next(3) -eq 0) { $own.Add((New-CrFinding -Site $s -ObjectType Library -Path 'Shared Documents' -Rule EveryoneGrant -Principal 'Everyone except external users' -PrincipalLogin 'everyone' -Permission 'Read' -Now $now)) }
            if ($random.Next(3) -eq 0) { $own.Add((& $link $s "Shared Documents/$($files[$random.Next($files.Count)])" 'anyone' $true)) }
            if ($random.Next(2) -eq 0) { $guests = 1; $own.Add((New-CrFinding -Site $s -ObjectType Site -Rule GuestAccess -Principal 'Sam Partner (sam@fabrikam.com)' -PrincipalLogin 'sam' -Permission 'Read' -Now $now)) }
            $facts = [pscustomobject]@{ isGroupConnected = $true; isPublicGroup = $false; sensitivityLabel = $label; labelKnown = $true; lastContentChange = (& $stamp $last); ownerCount = $owners; ownersKnown = $true; groupGuests = @() }
            foreach ($f in @(Get-CrSiteFindings -Site $s -Facts $facts -StaleDays $staleDays -Now $now)) { $own.Add($f) }
        }
        $found = @(Select-CrApplicable -Kind $s.kind -Findings $own.ToArray())
        $counts = New-CrCounts
        Add-CrCounts $counts $found
        $totals = Get-CrSeverityTotals $counts
        $row = [pscustomobject][ordered]@{
            siteId = $s.siteId; url = $s.url; title = $s.title; kind = $s.kind; status = 'Done'; isGroupConnected = ($s.kind -eq 'SharePoint'); sensitivityLabel = $label
            lastActivityAt = (& $stamp $last); ownerCount = $owners; guestCount = $guests; subsiteCount = 0; uniqueItemCount = 0
            score = Get-CrSiteScore $totals; findingCounts = $totals; error = $null
        }
        Write-CrJson (Join-Path $folder "sites\$(Get-CrSiteKey $s.siteId).json") ([pscustomobject]@{ site = $row; findings = $found; uniqueItems = @() })
    }

    # The real totting up: the scores, the counts and the report.
    Complete-CrScan -Folder $folder -Status Completed
    # It stamps the finish as now; give the made-up scan its own time and write the report again.
    $scan = Read-CrJson $scanFile
    $scan.completedAt = & $stamp $now.AddMinutes(4)
    Write-CrJson $scanFile $scan
    Export-CrResults -Folder $folder -Scan (Read-CrJson $scanFile) -Sites @(Read-CrJson (Join-Path $folder 'sites.json')) -Findings @(Read-CrJson (Join-Path $folder 'findings.json'))
    $folder
}

try {
    $results = Join-Path $work 'results'
    $older = New-DemoScan $results '2026-10-05T14:10:00Z' 3
    Start-Sleep -Milliseconds 1100
    $latest = New-DemoScan $results '2026-11-02T15:30:00Z' 11

    # ── The folder ──────────────────────────────────────────────────────────
    $folderShown = Join-Path $work 'CopilotReadiness-PnP'
    New-Item -ItemType Directory -Path (Join-Path $folderShown 'CopilotReadiness') -Force | Out-Null
    Copy-Item (Join-Path $root 'pnp\Start.cmd'), (Join-Path $root 'pnp\Start.ps1'), (Join-Path $root 'pnp\README.md') $folderShown
    Set-Content -LiteralPath (Join-Path $folderShown 'START HERE.html') -Value '<!doctype html>'
    $shell = New-Object -ComObject Shell.Application
    $before = @($shell.Windows() | ForEach-Object { $_.HWND })
    Start-Process explorer.exe $folderShown
    $window = $null
    foreach ($i in 1..40) {
        Start-Sleep -Milliseconds 250
        $window = @($shell.Windows() | Where-Object { $_.LocationURL -and ([uri]$_.LocationURL).LocalPath.TrimEnd('\') -eq $folderShown }) | Select-Object -First 1
        if ($window) { break }
    }
    if ($window) {
        Start-Sleep -Seconds 2
        $hwnd = [IntPtr]$window.HWND
        $ae = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
        $cond = { param($p, $v) [System.Windows.Automation.PropertyCondition]::new($p, $v) }
        $item = $ae.FindFirst('Descendants', (& $cond ([System.Windows.Automation.AutomationElement]::NameProperty) 'Start.cmd'))
        if (-not $item) { $item = $ae.FindFirst('Descendants', (& $cond ([System.Windows.Automation.AutomationElement]::NameProperty) 'Start')) }
        $list = $ae.FindFirst('Descendants', (& $cond ([System.Windows.Automation.AutomationElement]::ControlTypeProperty) ([System.Windows.Automation.ControlType]::List)))
        if ($item -and $list) {
            $r = $list.Current.BoundingRectangle; $m = $item.Current.BoundingRectangle
            $crop = [System.Drawing.Rectangle]::new([int]$r.Left, [int]$r.Top, [int][Math]::Min($r.Width, 640), [int][Math]::Min($r.Height, $m.Bottom - $r.Top + 45))
            Save-Window $hwnd '01-start-cmd.png' @([System.Drawing.Rectangle]::new([int]$m.Left, [int]$m.Top, [int][Math]::Min($m.Width, 235), [int]$m.Height)) $crop
        }
        else { Write-Warning "Couldn't find Start.cmd in the folder window; picture 01 not taken." }
        # Only ever the window this script opened.
        if (@($before) -notcontains $window.HWND) { $window.Quit() }
    }
    else { Write-Warning "The folder window didn't open; picture 01 not taken." }

    # ── The check window ────────────────────────────────────────────────────
    $checkRows = {
        param([bool] $needPnP, [string] $typed)
        $ok = { param($n, $s, $d, $f) [pscustomobject]@{ Name = $n; State = $s; Detail = $d; Fix = $f } }
        & $ok 'PowerShell' Ok 'Version 7.5.4'
        & $ok 'Windows' Ok 'The certificate is kept in your Windows certificate store'
        if ($needPnP) { & $ok 'PnP.PowerShell' Fixable 'Not installed. Fix installs version 3.4.1 for your account.' InstallPnP } else { & $ok 'PnP.PowerShell' Ok 'Version 3.4.1' }
        & $ok 'Microsoft 365' Ok $(if ($typed) { "Can reach $typed" } else { 'Can reach Microsoft 365' })
        & $ok 'Setup' Info "Not set up yet$(if ($typed) { " for $typed" }). Continue creates the 'Copilot Readiness Scanner (PnP)' app; you sign in as a Global Administrator and accept its permissions."
        & $ok 'Results folder' Ok 'C:\CopilotReadiness\CopilotReadiness-PnP\results'
    }.GetNewClosure()
    foreach ($shot in @(@{ NeedPnP = $true; Name = '02-check-fix.png'; Mark = 'Fix' }, @{ NeedPnP = $false; Name = '03-check-tenant.png'; Mark = 'Continue' })) {
        $need = $shot.NeedPnP
        $form = New-CrCheckForm -AskTenant -GetChecks { param($t) & $checkRows $need $t }.GetNewClosure()
        $form.Show(); Pump 500
        $box = Find-Type $form ([System.Windows.Forms.ComboBox])
        $box.Text = 'contoso'; Pump 100
        (Find-Control $form 'Check again').PerformClick(); Pump 500
        Save-Form $form $shot.Name @($(if (-not $need) { $box }), (Find-Control $form $shot.Mark))
        $form.Close(); $form.Dispose()
    }

    # ── Setting up ──────────────────────────────────────────────────────────
    $log = Join-Path $work 'activity.log'
    Set-Content $log @(
        "Setting up Copilot Readiness for $tenant ($sharePoint)"
        'Creating the app registration. A browser window will ask you to sign in as a Global Administrator, and then to accept the permissions.'
        "Signing in to $sharePoint..."
        "  3:12:05 PM  Microsoft is still switching on the new app's permissions. This usually takes a few minutes and can take up to 20. Trying again in 30 seconds (waited 0 of 20 minutes so far)."
        "  3:12:35 PM  Microsoft is still switching on the new app's permissions. This usually takes a few minutes and can take up to 20. Trying again in 30 seconds (waited 0.5 of 20 minutes so far)."
    )
    $activity = Start-CrActivityWindow -LogPath $log -Title 'Getting contoso ready'
    Start-Sleep -Seconds 3
    $hwnd = [CrSnap]::FindOwn([uint32]$PID, 'Copilot Readiness')
    if ($hwnd -ne [IntPtr]::Zero) { Save-Window $hwnd '04-getting-ready.png' } else { Write-Warning 'Setup window not found; picture 04 not taken.' }
    Stop-CrActivityWindow $activity

    # ── The main window ─────────────────────────────────────────────────────
    $values = [ordered]@{
        SharingCapability = 'ExternalUserAndGuestSharing'; OneDriveSharingCapability = 'ExternalUserAndGuestSharing'; DefaultSharingLinkType = 'Internal'; CoreDefaultShareLinkScope = 'Uninitialized'
        DefaultLinkPermission = 'Edit'; RequireAnonymousLinksExpireInDays = -1; CoreOrganizationSharingLinkMaxExpirationInDays = 90
        ExternalUserExpirationRequired = $false; ExternalUserExpireInDays = 60; ShowEveryoneExceptExternalUsersClaim = $true; RestrictedSearchMode = 'Disabled'
    }
    $form = New-CrControlForm -Sites $sites -TenantName $tenant -SharePointUrl $sharePoint -PastScans @(Get-CrPastScans $results -Tenant $tenant) `
        -TenantSettings (Get-CrTenantSettingsView $values -SharePointUrl $sharePoint)
    $form.Show(); Pump 1000
    Save-Form $form '05-new-scan.png' @((Find-Control $form 'Start scan'))
    $tabs = Find-Type $form ([System.Windows.Forms.TabControl])
    $tabs.SelectedIndex = 1; Pump 800
    # Open report only works once a scan is picked, as the guide says; pick the latest.
    $pastList = Find-Type $form ([System.Windows.Forms.ListView])
    if ($pastList.Items.Count) { $pastList.Items[0].Selected = $true; $pastList.Focus() | Out-Null; Pump 300 }
    Save-Form $form '08-past-scans.png' @((Find-Control $form 'Open report'))
    $tabs.SelectedIndex = 2; Pump 1500
    Save-Form $form '09-tenant.png'
    $form.Close(); $form.Dispose()

    # ── The progress window ─────────────────────────────────────────────────
    $runningRoot = Join-Path $work 'running'
    $running = New-CrScan -ResultsRoot $runningRoot -Level Quick -Sites $sites -Tenant $tenant
    $stamp = { param($s) [DateTimeOffset]::UtcNow.AddSeconds(-$s).UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") }
    $note = { param($t, $u, $s, $n, $of, $lib, $d, $items) [pscustomobject]@{ url = $u; title = $t; kind = 'SharePoint'; since = (& $stamp $s); doing = 'Checking items'; library = $lib; libraryNumber = $n; libraryCount = $of; libraryItemsDone = $d; libraryItems = $items; items = $items; itemsDone = $d } }
    $finished = { param($t, $s, $took, $h, $m, $l) [pscustomobject]@{ url = "$sharePoint/sites/$($t -replace ' ')"; title = $t; kind = 'SharePoint'; since = (& $stamp ($s + $took)); ended = (& $stamp $s); status = 'Done'; error = $null; counts = [pscustomobject]@{ High = $h; Medium = $m; Low = $l } } }
    Write-CrJson (Join-Path $running 'progress.json') ([pscustomobject][ordered]@{
            pid = $PID; processStartedAt = Get-CrProcessStamp (Get-Process -Id $PID); state = 'Running'; total = $sites.Count; done = 4; doneAtStart = 0; failed = 0; skipped = 0
            runStartedAt = (& $stamp 160); updatedAt = (& $stamp 0)
            current = @((& $note 'Marketing' "$sharePoint/sites/Marketing" 42 2 5 'Campaign Assets' 620 1400), (& $note 'Project Apollo' "$sharePoint/sites/ProjectApollo" 25 1 3 'Documents' 210 900), (& $note 'Sales Proposals' "$sharePoint/sites/SalesProposals" 9 1 4 'Proposals' 40 500))
            findings = [ordered]@{ High = 4; Medium = 14; Low = 5 }
            recent = @((& $finished 'Legal' 12 31 1 3 1), (& $finished 'IT Help Desk' 40 22 0 2 2), (& $finished 'Human Resources' 66 48 2 4 0), (& $finished 'Finance' 110 52 1 5 2))
            pausedUntil = $null; waits = 0; pace = 'Normal'; easeSteps = 0; easeUntil = $null; perMinute = 150; sitesAtOnce = 3; score = $null; oneDriveScore = $null; error = $null
        })
    $form = New-CrProgressForm -Folder $running -Launch { }
    $form.Show(); Pump 2000
    Save-Form $form '06-progress.png'
    $form.Close(); $form.Dispose()

# ── The report ──────────────────────────────────────────────────────────────
function Save-Page([string] $Url, [string] $Name, [int] $Height) {
    $profile = Join-Path $work "chrome-$Name"
    $out = Join-Path $OutFolder $Name
    # Start-Process joins these with bare spaces, so each is quoted in case a folder has a space in it.
    $p = Start-Process $Chrome -PassThru -WindowStyle Hidden -ArgumentList (@(
            '--headless=new', '--disable-gpu', '--hide-scrollbars', '--force-device-scale-factor=1', '--no-first-run', "--user-data-dir=$profile",
            "--window-size=1280,$Height", '--virtual-time-budget=4000', "--screenshot=$out", $Url) | ForEach-Object { "`"$_`"" })
    if (-not $p.WaitForExit(60000)) { Stop-Process -Id $p.Id -Force }
    if (Test-Path -LiteralPath $out) { Write-Host "  $Name" } else { Write-Warning "$Name not taken." }
}
$reportUrl = ([uri](Join-Path $latest 'report.html')).AbsoluteUri
Save-Page $reportUrl '07-report.png' 900
Write-Host "Pictures are in $OutFolder"
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
