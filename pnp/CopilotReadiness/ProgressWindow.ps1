# The progress window: how far along a scan is while it runs in the background. Closing
# the window leaves the scan running; Start.ps1 shows the window again the next time.

function Format-CrDuration {
    <# "40 seconds", "12 minutes", "2 hours 10 minutes", "3 days 4 hours". #>
    param([double] $Seconds)
    function Say([long] $n, [string] $unit) { if ($n -eq 1) { "1 $unit" } else { "$n $($unit)s" } }
    function Pair([long] $big, [string] $bigUnit, [long] $small, [string] $smallUnit) {
        if ($small) { "$(Say $big $bigUnit) $(Say $small $smallUnit)" } else { Say $big $bigUnit }
    }
    $s = [long][Math]::Max(0, [Math]::Round($Seconds))
    if ($s -lt 60) { return Say $s 'second' }
    $minutes = [long][Math]::Round($s / 60)
    if ($minutes -lt 60) { return Say $minutes 'minute' }
    if ($minutes -lt 24 * 60) { return Pair ([Math]::Floor($minutes / 60)) 'hour' ($minutes % 60) 'minute' }
    $hours = [long][Math]::Round($s / 3600)
    Pair ([Math]::Floor($hours / 24)) 'day' ($hours % 24) 'hour'
}

function Get-CrProgressView {
    <#
      What the progress window shows for a scan folder, worked out from progress.json,
      scope.json and scan.json; kept apart from the window so it can be tested. State is
      Starting, Running, Stopping, Completed, Cancelled, Failed, or Lost (the scan's
      process ended without saying why, for example the PC restarted).
    #>
    param([Parameter(Mandatory)] [string] $Folder, [DateTimeOffset] $Now = [DateTimeOffset]::UtcNow)

    $scope = Read-CrJson (Join-Path $Folder 'scope.json')
    $scan = Read-CrJson (Join-Path $Folder 'scan.json')
    $p = Read-CrProgress $Folder
    $total = @($scope.sites).Count
    $done = if ($p) { [int]$p.done } else { @(Get-ChildItem -LiteralPath (Join-Path $Folder 'sites') -Filter '*.json').Count }
    $failed = if ($p) { [int]$p.failed } else { 0 }

    $state = if ($p) { "$($p.state)" } elseif ($scan.status -eq 'Completed') { 'Completed' } else { 'Cancelled' }
    if ($state -in 'Starting', 'Running', 'Stopping' -and -not (Test-CrProcessAlive $p.pid $p.processStartedAt)) { $state = 'Lost' }
    $report = Join-Path $Folder 'report.html'
    if ($state -ne 'Completed' -or -not (Test-Path -LiteralPath $report)) { $report = $null }

    # What was asked for: "Standard scan of 40 SharePoint sites and 1,500 OneDrives".
    $od = @($scope.sites | Where-Object kind -EQ 'OneDrive').Count
    $sp = $total - $od
    $what = @(
        $(if ($sp) { if ($sp -eq 1) { '1 SharePoint site' } else { '{0:N0} SharePoint sites' -f $sp } }),
        $(if ($od) { if ($od -eq 1) { '1 OneDrive' } else { '{0:N0} OneDrives' -f $od } })
    ) | Where-Object { $_ }
    $started = [DateTimeOffset]::Parse($scan.startedAt, [Globalization.CultureInfo]::InvariantCulture).ToLocalTime().ToString('MMMM d, h:mm tt')
    # The pace the scan is at now (it can be changed while it runs), and one asked for but not yet taken up.
    $pace = Get-CrPace $(if ($p -and $p.pace) { $p.pace } else { $scope.pace })
    $paceFile = Join-Path $Folder 'pace.request'
    $paceAsked = if (Test-Path -LiteralPath $paceFile) { try { (Get-CrPace "$(Get-Content -LiteralPath $paceFile -Raw)".Trim()).Id } catch { $null } } else { $null }
    $about = "$(if ($sp) { "$($scope.level) scan" } else { 'Scan' }) of $($what -join ' and ') in $($scope.tenant) at $($pace.Name) pace, started $started"

    $count = '{0:N0} of {1:N0} {2} done' -f $done, $total, $(if ($total -eq 1) { 'site' } else { 'sites' })
    $runFor = if ($p -and $p.runStartedAt) { ($Now - [DateTimeOffset]::Parse($p.runStartedAt, [Globalization.CultureInfo]::InvariantCulture)).TotalSeconds } else { 0 }
    $running = $state -in 'Starting', 'Running', 'Stopping'

    # Each site in progress: what it's doing, how far through its items, and its time.
    $notes = @(if ($running -and $p) { $p.current })
    $current = @(foreach ($c in $notes) {
            $words = Get-CrStepText $c -Now $Now
            $soFar = ($Now - [DateTimeOffset]::Parse($c.since, [Globalization.CultureInfo]::InvariantCulture)).TotalSeconds
            [pscustomobject]@{
                Site   = if ($c.title) { "$($c.title)" } else { "$($c.url)" }
                Doing  = $words.Doing
                HowFar = $words.HowFar
                Time   = "$(Format-CrDuration $soFar) so far$(if ($words.Left -ge 0) { ", about $(Format-CrDuration $words.Left) left" })"
            }
        })

    # Sites finished this run, newest first: how each went and how long it took.
    # A scan from before this list existed has none, so nothing to show.
    $recent = @(foreach ($r in @(if ($p -and $p.recent) { $p.recent })) {
            if (-not $r.ended -or -not $r.since) { continue }
            $ended = [DateTimeOffset]::Parse($r.ended, [Globalization.CultureInfo]::InvariantCulture)
            $took = ($ended - [DateTimeOffset]::Parse($r.since, [Globalization.CultureInfo]::InvariantCulture)).TotalSeconds
            $result = switch ("$($r.status)") {
                'Failed' { "Couldn't read: $($r.error)" }
                # A site set aside on purpose says which kind it is ("App catalog: ..."); the rest were archived or locked.
                'Skipped' { if ("$($r.error)" -match '^([^:.]+): ') { "Left out on purpose: $($Matches[1])" } else { 'Archived or locked, so skipped' } }
                default {
                    $found = @(foreach ($s in (Get-CrRuleBook).severities) { if ([int]$r.counts.$s) { '{0:N0} {1}' -f [int]$r.counts.$s, $s } })
                    if ($found) { $found -join ', ' } else { 'No issues' }
                }
            }
            [pscustomobject]@{ Key = "$($r.url)|$($r.ended)"; Site = "$($r.title)"; Result = $result; Took = Format-CrDuration $took; At = $ended.ToLocalTime().ToString('h:mm:ss tt'); Url = "$($r.url)" }
        })

    # Sites partway through count for the part done, so the bar and the time left move during a big site.
    $partly = ($notes | ForEach-Object { if ([long]$_.items -gt 0) { [Math]::Min(0.99, [double]$_.itemsDone / [long]$_.items) } else { 0 } } | Measure-Object -Sum).Sum
    $progress = [Math]::Min([double]$total, $done + [double]$partly)
    $doneAtStart = if ($p) { [int]$p.doneAtStart } else { 0 }
    $progressThisRun = $progress - $doneAtStart
    $estimable = $runFor -ge 20 -and $progressThisRun -gt 0 -and ($done - $doneAtStart -ge 3 -or $total - $doneAtStart -le 3)
    $timeLeft = if ($estimable) { "about $(Format-CrDuration (($total - $progress) * $runFor / $progressThisRun)) left" } else { 'working out how long it will take' }
    $saved = 'Everything done so far is saved; Continue picks up from there.'
    $pausedFor = if ($p -and $p.pausedUntil) { ([DateTimeOffset]::Parse($p.pausedUntil, [Globalization.CultureInfo]::InvariantCulture) - $Now).TotalSeconds } else { 0 }

    $heading, $status = switch ($state) {
        'Starting' { 'Starting the scan', 'Signing in...' }
        'Running' {
            if ($pausedFor -ge 1) { 'Scanning', "$count. Microsoft asked the scan to slow down, so it is waiting; it starts again in $(Format-CrDuration $pausedFor)." }
            else { 'Scanning', "$count, $timeLeft" }
        }
        'Stopping' { 'Stopping', "$count. Stopping now; a site cut off partway picks up from its last saved place when you continue." }
        'Completed' { $(if ($null -ne $p.score -or $null -ne $p.oneDriveScore) { "Finished: " + (@($(if ($null -ne $p.score) { "score $($p.score)" }), $(if ($null -ne $p.oneDriveScore) { "OneDrive score $($p.oneDriveScore)" })) -join ', ') + ' out of 100' } else { 'Finished' }), $(if ($total -eq 1) { 'Done.' } else { 'All {0:N0} done.' -f $total }) }
        'Cancelled' { 'Stopped', "Stopped after $count. $saved" }
        'Failed' { 'The scan stopped', "Stopped after $count because of a problem: $($p.error) $saved" }
        default { 'The scan stopped unexpectedly', "Stopped after $count. $saved If it happens again, scan-errors.log in the results folder may say why." }
    }

    $extra = @(
        $(if ($running -and $runFor -ge 1) { "Running for $(Format-CrDuration $runFor)" }),
        $(if ($running -and $p.waits) { "Microsoft has asked it to wait $(if ([int]$p.waits -eq 1) { 'once' } else { '{0:N0} times' -f [int]$p.waits })" }),
        $(if ($running -and [int]$p.easeSteps -gt 0) {
                $sites = [int]$p.sitesAtOnce
                "So it has slowed itself down to $sites $(if ($sites -eq 1) { 'site' } else { 'sites' }) at a time$(if ([int]$p.perMinute -gt 0) { " and at most $($p.perMinute) requests a minute" }), and returns to the $($pace.Name) pace step by step once Microsoft stops asking"
            }),
        $(if ($failed) { "{0:N0} couldn't be read{1}" -f $failed, $(if ($state -eq 'Completed') { '; the report lists them and why' } else { '' }) }),
        $(if ($p -and [int]$p.skipped) { '{0:N0} left out (archived, locked, or set aside on purpose)' -f [int]$p.skipped })
    ) | Where-Object { $_ }


    $found = [ordered]@{}
    foreach ($s in (Get-CrRuleBook).severities) { $found[$s] = if ($p -and $p.findings) { [int]$p.findings.$s } else { 0 } }

    [pscustomobject]@{
        State      = $state
        Heading    = $heading
        About      = $about
        Status     = $status
        Extra      = $extra -join '. '
        Percent    = if ($total) { [Math]::Min(100, 100.0 * $progress / $total) } else { 0 }
        Current    = $current
        Recent     = $recent
        Findings   = $found
        Report     = $report
        CanStop    = $state -in 'Starting', 'Running'
        CanCarryOn = $state -in 'Cancelled', 'Failed', 'Lost'
        Running    = $running
        Pace       = $pace.Id
        PaceAsked  = $paceAsked
    }
}

function New-CrProgressForm {
    <#
      Builds the window for a scan folder; it re-reads the scan's progress every second.
      Launch is called with the folder to continue a stopped scan in the background. When
      the window closes, its Tag holds the last view; Main window closes it with the
      result Retry, which asks for the main window back. The report opens by itself if
      the scan finishes while the window is open.
    #>
    param([Parameter(Mandatory)] [string] $Folder, [scriptblock] $Launch)
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $font = [System.Drawing.Font]::new('Segoe UI', 9.5)
    $bold = [System.Drawing.Font]::new('Segoe UI Semibold', 10)
    $title = [System.Drawing.Font]::new('Segoe UI Semibold', 14)
    $big = [System.Drawing.Font]::new('Segoe UI Semibold', 13)
    $muted = [System.Drawing.Color]::FromArgb(95, 102, 112)
    $colours = @{
        High   = [System.Drawing.Color]::FromArgb(198, 40, 40)
        Medium = [System.Drawing.Color]::FromArgb(179, 89, 0)
        Low    = [System.Drawing.Color]::FromArgb(95, 102, 112)
    }

    $form = [System.Windows.Forms.Form]@{
        Text          = 'Copilot Readiness scan'
        Font          = $font
        AutoScaleMode = 'Dpi'
        StartPosition = 'CenterScreen'
        Size          = [System.Drawing.Size]::new(1000, 760)
        MinimumSize   = [System.Drawing.Size]::new(640, 520)
        BackColor     = [System.Drawing.Color]::White
        Tag           = $null
    }

    $layout = [System.Windows.Forms.TableLayoutPanel]@{ Dock = 'Fill'; ColumnCount = 1; Padding = [System.Windows.Forms.Padding]::new(20, 16, 20, 16) }
    $null = $layout.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new('Percent', 100))
    $form.Controls.Add($layout)
    function Add-Row($control, [string] $size = 'AutoSize') {
        $style = if ($size -eq 'Fill') { [System.Windows.Forms.RowStyle]::new('Percent', 100) } else { [System.Windows.Forms.RowStyle]::new('AutoSize') }
        $null = $layout.RowStyles.Add($style)
        # A fixed row for each, so hiding one doesn't slide the others up into rows sized for something else.
        $layout.Controls.Add($control, 0, $layout.RowStyles.Count - 1)
        $control
    }
    function New-Label([string] $text, $labelFont = $font, $color = $null) {
        $l = [System.Windows.Forms.Label]@{ Text = $text; Font = $labelFont; AutoSize = $true; MaximumSize = [System.Drawing.Size]::new(1400, 0); Margin = [System.Windows.Forms.Padding]::new(0, 0, 0, 4) }
        if ($color) { $l.ForeColor = $color }
        $l
    }

    $heading = Add-Row (New-Label '' $title)
    $about = Add-Row (New-Label '' $font $muted)
    $bar = Add-Row ([System.Windows.Forms.ProgressBar]@{ Dock = 'Fill'; Height = 22; Minimum = 0; Maximum = 1000; Margin = [System.Windows.Forms.Padding]::new(0, 12, 0, 8) })
    $status = Add-Row (New-Label '' $bold)
    $extra = Add-Row (New-Label '' $font $muted)

    # The pace, which can be changed while the scan runs: the scan picks up pace.request within a second or two.
    $paceRow = [System.Windows.Forms.FlowLayoutPanel]@{ AutoSize = $true; Dock = 'Fill'; FlowDirection = 'LeftToRight'; WrapContents = $true; Margin = [System.Windows.Forms.Padding]::new(0, 8, 0, 0); Visible = $false }
    $paceLabel = New-Label 'Pace:' $bold
    $paceLabel.Margin = [System.Windows.Forms.Padding]::new(0, 5, 12, 0)
    $paceRow.Controls.Add($paceLabel)
    $paceRadios = @{}
    $paceSync = @{ On = $false }
    foreach ($pace in Get-CrPaces) {
        $radio = [System.Windows.Forms.RadioButton]@{ Text = $pace.Name; AutoSize = $true; Tag = $pace.Id; Margin = [System.Windows.Forms.Padding]::new(0, 4, 16, 0) }
        $radio.Add_CheckedChanged({
                param($sender)
                if ($paceSync.On -or -not $sender.Checked) { return }
                try { Set-Content -LiteralPath (Join-Path $Folder 'pace.request') -Value $sender.Tag -Encoding utf8 } catch { }
            }.GetNewClosure())
        $paceRadios[$pace.Id] = $radio
        $paceRow.Controls.Add($radio)
    }
    $paceNote = New-Label '' $font $muted
    $paceNote.Margin = [System.Windows.Forms.Padding]::new(8, 5, 0, 0)
    $paceRow.Controls.Add($paceNote)
    $null = Add-Row $paceRow

    # One line per site in progress: the site, what it's doing (which library or list), how far through its items, and its time.
    # It is only as tall as the sites in progress need; the Finished list below takes the rest.
    function New-SiteList([System.Collections.Specialized.OrderedDictionary] $columns) {
        $list = [System.Windows.Forms.ListView]@{ View = 'Details'; Dock = 'Fill'; FullRowSelect = $true; HeaderStyle = 'Nonclickable'; BorderStyle = 'None'; MultiSelect = $false }
        foreach ($c in $columns.Keys) { $null = $list.Columns.Add($c, 100) }
        # Drawn off screen first, so a changing cell doesn't blink.
        [System.Windows.Forms.Control].GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'Instance, NonPublic').SetValue($list, $true)
        $list.Add_Resize({
                param($sender)
                $width = [Math]::Max(200, $sender.ClientSize.Width - 4)
                $i = 0
                foreach ($share in $columns.Values) { $sender.Columns[$i].Width = [int]($width * $share); $i++ }
            }.GetNewClosure())
        $list
    }
    $nowBox = [System.Windows.Forms.GroupBox]@{ Text = 'Scanning now'; Dock = 'Top'; Height = 140; Padding = [System.Windows.Forms.Padding]::new(12, 8, 12, 8); Margin = [System.Windows.Forms.Padding]::new(0, 12, 0, 0) }
    $nowList = New-SiteList ([ordered]@{ 'Site' = 0.26; 'Doing now' = 0.38; 'How far' = 0.14; 'Time' = 0.22 })
    $nowBox.Controls.Add($nowList)
    $null = Add-Row $nowBox

    # Sites finished this run, newest first. Double-click one to open it.
    $doneBox = [System.Windows.Forms.GroupBox]@{ Text = 'Finished, newest first'; Dock = 'Fill'; Padding = [System.Windows.Forms.Padding]::new(12, 8, 12, 8); Margin = [System.Windows.Forms.Padding]::new(0, 12, 0, 0); Visible = $false }
    $doneList = New-SiteList ([ordered]@{ 'Site' = 0.26; 'What it found' = 0.46; 'Took' = 0.14; 'Finished at' = 0.14 })
    $doneList.Add_DoubleClick({ $item = $doneList.SelectedItems | Select-Object -First 1; if ($item.Tag) { Start-Process $item.Tag } }.GetNewClosure())
    $doneBox.Controls.Add($doneList)
    $null = Add-Row $doneBox 'Fill'
    $known = [System.Collections.Generic.HashSet[string]]::new()

    $foundBox = [System.Windows.Forms.GroupBox]@{ Text = 'Found so far'; AutoSize = $true; Dock = 'Top'; Padding = [System.Windows.Forms.Padding]::new(12, 8, 12, 8); Margin = [System.Windows.Forms.Padding]::new(0, 12, 0, 0) }
    $foundRow = [System.Windows.Forms.FlowLayoutPanel]@{ Dock = 'Fill'; AutoSize = $true; FlowDirection = 'LeftToRight'; WrapContents = $true }
    $foundLabels = [ordered]@{}
    foreach ($s in (Get-CrRuleBook).severities) {
        $l = New-Label '' $big $colours[$s]
        $l.Margin = [System.Windows.Forms.Padding]::new(0, 2, 28, 2)
        $foundLabels[$s] = $l
        $foundRow.Controls.Add($l)
    }
    $foundBox.Controls.Add($foundRow)
    $null = Add-Row $foundBox

    # Everything the scan prints (scan.log and scan-errors.log), shown on request.
    $detailsLink = Add-Row ([System.Windows.Forms.LinkLabel]@{ Text = 'Show what the scan is doing'; AutoSize = $true; Margin = [System.Windows.Forms.Padding]::new(0, 12, 0, 4) })
    $details = [System.Windows.Forms.TextBox]@{
        Multiline = $true; ReadOnly = $true; ScrollBars = 'Vertical'; WordWrap = $true; Dock = 'Fill'; Visible = $false
        Font = [System.Drawing.Font]::new('Consolas', 9); BackColor = [System.Drawing.Color]::FromArgb(246, 248, 250)
    }
    $null = Add-Row $details 'Fill'
    # The details share the space with "Scanning now" when shown, and take none when hidden.
    $detailsRow = $layout.RowStyles.Count - 1
    $layout.RowStyles[$detailsRow].Height = 0
    $read = @{ 'scan.log' = 0L; 'scan-errors.log' = 0L }
    $follow = {
        foreach ($name in @($read.Keys)) {
            $path = Join-Path $Folder $name
            if (-not (Test-Path -LiteralPath $path)) { continue }
            try {
                $stream = [System.IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
                try {
                    if ($stream.Length -lt $read[$name]) { $read[$name] = 0L }
                    $null = $stream.Seek($read[$name], 'Begin')
                    $text = [System.IO.StreamReader]::new($stream).ReadToEnd()
                    $read[$name] = $stream.Position
                }
                finally { $stream.Dispose() }
                if ($text.Trim()) { $details.AppendText(($text.TrimEnd() -replace "`r?`n", "`r`n") + "`r`n") }
            }
            catch { }
        }
    }.GetNewClosure()
    # Showing the details makes the whole window bigger (as big as the screen allows); hiding them puts it back.
    $sizeBefore = @{ Bounds = $null }
    $detailsLink.Add_LinkClicked({
            $details.Visible = -not $details.Visible
            $detailsLink.Text = if ($details.Visible) { 'Hide what the scan is doing' } else { 'Show what the scan is doing' }
            $layout.RowStyles[$detailsRow].Height = if ($details.Visible) { 100 } else { 0 }
            if ($details.Visible) {
                $sizeBefore.Bounds = $form.Bounds
                $area = [System.Windows.Forms.Screen]::FromControl($form).WorkingArea
                $width = [Math]::Min($area.Width, [Math]::Max($form.Width, [int]($area.Width * 0.7)))
                $height = [Math]::Min($area.Height, [Math]::Max($form.Height + 360, [int]($area.Height * 0.9)))
                $form.Bounds = [System.Drawing.Rectangle]::new($area.Left + ($area.Width - $width) / 2, $area.Top + ($area.Height - $height) / 2, $width, $height)
                & $follow
            }
            elseif ($sizeBefore.Bounds) { $form.Bounds = $sizeBefore.Bounds }
        }.GetNewClosure())
    $note = Add-Row (New-Label 'Main window takes you back to the main window; Close ends the program. Either way the scan keeps running in the background. Double-click Start.cmd again to see how it is going.' $font $muted)

    $buttons = [System.Windows.Forms.FlowLayoutPanel]@{ FlowDirection = 'RightToLeft'; Dock = 'Fill'; AutoSize = $true; Margin = [System.Windows.Forms.Padding]::new(0, 8, 0, 0) }
    function New-Button([string] $text) { [System.Windows.Forms.Button]@{ Text = $text; AutoSize = $true; Padding = [System.Windows.Forms.Padding]::new(12, 3, 12, 3) } }
    $close = New-Button 'Close'
    $close.DialogResult = 'Cancel'
    $back = New-Button 'Main window'
    $back.DialogResult = 'Retry'
    $openReport = New-Button 'Open report'
    $carryOn = New-Button 'Continue'
    $stop = New-Button 'Stop scan'
    $openFolder = New-Button 'Open results folder'
    $buttons.Controls.AddRange(@($close, $back, $openReport, $carryOn, $stop, $openFolder))
    $null = Add-Row $buttons
    $form.CancelButton = $close

    $seen = @{ Unfinished = $false; Opened = $false }
    $update = {
        # A file being rewritten just as it's read: try again on the next tick.
        try { $v = Get-CrProgressView $Folder } catch { return }
        $form.Tag = $v
        $heading.Text = $v.Heading
        $about.Text = $v.About
        $status.Text = $v.Status
        $extra.Text = $v.Extra
        $extra.Visible = [bool]$v.Extra
        $bar.Style = if ($v.State -eq 'Starting') { 'Marquee' } else { 'Continuous' }
        $bar.Value = [int](10 * $v.Percent)
        $paceRow.Visible = $v.Running
        # Show the pace asked for until the scan takes it up; setting it here doesn't count as a new choice.
        $showPace = if ($v.PaceAsked) { $v.PaceAsked } else { $v.Pace }
        if (-not $paceRadios[$showPace].Checked) { $paceSync.On = $true; $paceRadios[$showPace].Checked = $true; $paceSync.On = $false }
        $paceText = if ($v.PaceAsked -and $v.PaceAsked -ne $v.Pace) { "Switching to $($v.PaceAsked)..." }
        else { "$((Get-CrPace $v.Pace).Description) Change it any time; fewer sites at once takes effect as the sites in progress finish." }
        if ($paceNote.Text -ne $paceText) { $paceNote.Text = $paceText }
        $nowBox.Visible = $v.Running
        $rowHeight = $nowList.Font.Height + 6
        $nowBox.Height = 34 + $rowHeight * ([Math]::Max(1, $v.Current.Count) + 1) + 12
        # A box's heading redraws the box and its list whenever it is set, even to the same words, so only when it changes.
        $nowText = if ($v.Current.Count -gt 1) { "Scanning now: $($v.Current.Count) sites at once" } else { 'Scanning now' }
        if ($nowBox.Text -ne $nowText) { $nowBox.Text = $nowText }
        # Rows are changed in place, cell by cell, so the list doesn't flicker every second.
        while ($nowList.Items.Count -gt $v.Current.Count) { $nowList.Items.RemoveAt($nowList.Items.Count - 1) }
        for ($i = 0; $i -lt $v.Current.Count; $i++) {
            $c = $v.Current[$i]
            $cells = [string[]]@($c.Site, $c.Doing, $c.HowFar, $c.Time)
            if ($i -ge $nowList.Items.Count) { $null = $nowList.Items.Add([System.Windows.Forms.ListViewItem]::new($cells)) }
            else { for ($j = 0; $j -lt $cells.Count; $j++) { if ($nowList.Items[$i].SubItems[$j].Text -ne $cells[$j]) { $nowList.Items[$i].SubItems[$j].Text = $cells[$j] } } }
        }

        # New finished sites go in at the top; the rest stay put, so the list doesn't jump about.
        $new = @($v.Recent | Where-Object { -not $known.Contains($_.Key) })
        if ($new.Count) {
            $doneList.BeginUpdate()
            [array]::Reverse($new)
            foreach ($r in $new) {
                $item = [System.Windows.Forms.ListViewItem]::new([string[]]@($r.Site, $r.Result, $r.Took, $r.At))
                $item.Tag = $r.Url
                $item.Name = $r.Key
                $doneList.Items.Insert(0, $item)
                [void]$known.Add($r.Key)
            }
            while ($doneList.Items.Count -gt 200) { [void]$known.Remove($doneList.Items[$doneList.Items.Count - 1].Name); $doneList.Items.RemoveAt($doneList.Items.Count - 1) }
            $doneList.EndUpdate()
        }
        $doneBox.Visible = $doneList.Items.Count -gt 0
        $doneText = 'Finished this run: {0:N0}, newest first{1}' -f $(if ($v.Recent.Count -ge 200) { '200+' } else { $v.Recent.Count }), '. Double-click one to open it.'
        if ($doneBox.Text -ne $doneText) { $doneBox.Text = $doneText }
        foreach ($s in @($foundLabels.Keys)) { $foundLabels[$s].Text = '{0:N0} {1}' -f $v.Findings[$s], $s }
        $note.Visible = $v.Running
        if ($details.Visible) { & $follow }
        $stop.Visible = $v.Running
        $stop.Enabled = $v.CanStop
        $stop.Text = if ($v.State -eq 'Stopping') { 'Stopping...' } else { 'Stop scan' }
        $carryOn.Visible = $v.CanCarryOn -and $Launch
        $openReport.Visible = [bool]$v.Report
        $form.AcceptButton = if ($v.Report) { $openReport } else { $null }
        $form.Text = if ($v.Running) { 'Copilot Readiness scan: {0:N0}%' -f [Math]::Floor($v.Percent) } else { "Copilot Readiness scan: $($v.Heading.ToLowerInvariant())" }

        if ($v.State -ne 'Completed') { $seen.Unfinished = $true }
        elseif ($seen.Unfinished -and $v.Report -and -not $seen.Opened) {
            $seen.Opened = $true
            Invoke-Item -LiteralPath $v.Report
        }
    }.GetNewClosure()

    $timer = [System.Windows.Forms.Timer]@{ Interval = 1000 }
    $timer.Add_Tick($update)
    $stop.Add_Click({
            # The scan sees this file between sites and stops taking new ones.
            Set-Content -LiteralPath (Join-Path $Folder 'stop.request') -Value "Stop asked for by $([Environment]::UserName) at $([DateTimeOffset]::Now.ToString('o'))"
            $stop.Enabled = $false
            $stop.Text = 'Stopping...'
        }.GetNewClosure())
    $carryOn.Add_Click({
            try { $null = & $Launch $Folder }
            catch { $status.Text = "Could not continue: $($_.Exception.Message)"; return }
            & $update
        }.GetNewClosure())
    $openReport.Add_Click({ if ($form.Tag.Report) { Invoke-Item -LiteralPath $form.Tag.Report } }.GetNewClosure())
    $openFolder.Add_Click({ Invoke-Item -LiteralPath $Folder }.GetNewClosure())
    $form.Add_Load({
            # Most of the screen, so the sites in progress and the details have room.
            $area = [System.Windows.Forms.Screen]::FromControl($form).WorkingArea
            $width = [Math]::Min($area.Width, [Math]::Max($form.Width, [int]($area.Width * 0.6)))
            $height = [Math]::Min($area.Height, [Math]::Max($form.Height, [int]($area.Height * 0.8)))
            $form.Bounds = [System.Drawing.Rectangle]::new($area.Left + ($area.Width - $width) / 2, $area.Top + ($area.Height - $height) / 2, $width, $height)
            & $update
            $timer.Start()
        }.GetNewClosure())
    $form.Add_FormClosed({ $timer.Dispose() }.GetNewClosure())

    $form
}

function Show-CrProgressWindow {
    <# Shows the progress window for a scan folder until it is closed; returns the last view (State, Report and so on), with Back set when Main window was pressed. #>
    param([Parameter(Mandatory)] [string] $Folder, [scriptblock] $Launch)
    $form = New-CrProgressForm -Folder $Folder -Launch $Launch
    try {
        $result = $form.ShowDialog()
        $view = if ($form.Tag) { $form.Tag } else { Get-CrProgressView $Folder }
        $view | Add-Member -NotePropertyName Back -NotePropertyValue ($result -eq 'Retry') -Force
        $view
    }
    finally {
        $form.Dispose()
    }
}
