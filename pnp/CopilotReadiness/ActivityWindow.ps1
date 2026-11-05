# A window that shows what the script is printing while no other window is up: setting
# up, signing in, waiting for a new app's permissions, finding sites. It runs on its own
# thread, so it keeps updating while the script works, and follows a text file the
# script writes to (its transcript). If something goes wrong it says so and stays open.
# While waiting on Microsoft it says why in plain words, with a countdown. The technical
# errors behind that wait stay in the log file, for anyone asked to look into a problem.

function Select-CrActivityLines {
    <#
      The lines of the transcript a person should see. Leaves out the block of PC details at each
      end, and the errors PowerShell records by itself, which can run over several lines.
      Read keeps its place in such an error between calls.
    #>
    param([string[]] $Lines = @(), [Parameter(Mandatory)] [hashtable] $Read)
    $skip = '^(\*{10,}|PowerShell transcript (start|end)|Start time:|End time:|Username:|RunAs User:|Configuration Name:|Machine:|Host Application:|Process ID:|PS\w*Version:|PSEdition:|PSCompatibleVersions:|GitCommitId:|OS:|Platform:|BuildVersion:|CLRVersion:|WSManStackVersion:|SerializationVersion:|Transcript started)'
    foreach ($line in $Lines) {
        if ($Read.InError) {
            if ($line.TrimEnd().EndsWith('"')) { $Read.InError = $false }
            continue
        }
        if ($line -match '^(PS>|>> )?TerminatingError\(') {
            if (-not $line.TrimEnd().EndsWith('"')) { $Read.InError = $true }
            continue
        }
        if ($line -notmatch $skip) { $line }
    }
}

$script:ActivityWindowScript = {
    param([string] $LogPath, [string] $Title, [hashtable] $State, [string] $SelectLines)
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $font = [System.Drawing.Font]::new('Segoe UI', 9.5)
    $muted = [System.Drawing.Color]::FromArgb(95, 102, 112)
    $form = [System.Windows.Forms.Form]@{
        Text          = 'Copilot Readiness'
        Font          = $font
        AutoScaleMode = 'Dpi'
        StartPosition = 'CenterScreen'
        Size          = [System.Drawing.Size]::new(960, 640)
        MinimumSize   = [System.Drawing.Size]::new(520, 320)
        BackColor     = [System.Drawing.Color]::White
    }
    $layout = [System.Windows.Forms.TableLayoutPanel]@{ Dock = 'Fill'; ColumnCount = 1; Padding = [System.Windows.Forms.Padding]::new(20, 16, 20, 16) }
    $null = $layout.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new('Percent', 100))
    foreach ($size in 'AutoSize', 'AutoSize', 'AutoSize', 'Fill', 'AutoSize') {
        $null = $layout.RowStyles.Add($(if ($size -eq 'Fill') { [System.Windows.Forms.RowStyle]::new('Percent', 100) } else { [System.Windows.Forms.RowStyle]::new('AutoSize') }))
    }
    $form.Controls.Add($layout)

    $heading = [System.Windows.Forms.Label]@{ Text = $Title; Font = [System.Drawing.Font]::new('Segoe UI Semibold', 14); AutoSize = $true; Margin = [System.Windows.Forms.Padding]::new(0, 0, 0, 4) }
    $note = [System.Windows.Forms.Label]@{ Text = 'What the script is doing. This closes by itself when the next step is ready.'; ForeColor = $muted; AutoSize = $true; Margin = [System.Windows.Forms.Padding]::new(0, 0, 0, 8) }
    $box = [System.Windows.Forms.TextBox]@{
        Multiline = $true; ReadOnly = $true; ScrollBars = 'Vertical'; WordWrap = $true; Dock = 'Fill'
        Font = [System.Drawing.Font]::new('Consolas', 9.5); BackColor = [System.Drawing.Color]::FromArgb(246, 248, 250)
    }
    $close = [System.Windows.Forms.Button]@{ Text = 'Close'; AutoSize = $true; Padding = [System.Windows.Forms.Padding]::new(12, 3, 12, 3); Anchor = 'Right'; Visible = $false; Margin = [System.Windows.Forms.Padding]::new(0, 8, 0, 0) }
    $close.Add_Click({ $form.Close() })
    # Shown only while waiting on Microsoft.
    $wait = [System.Windows.Forms.Panel]@{ AutoSize = $true; AutoSizeMode = 'GrowAndShrink'; Dock = 'Fill'; Visible = $false; BackColor = [System.Drawing.Color]::FromArgb(232, 242, 252); Padding = [System.Windows.Forms.Padding]::new(14, 10, 14, 10); Margin = [System.Windows.Forms.Padding]::new(0, 0, 0, 10) }
    $waitFlow = [System.Windows.Forms.FlowLayoutPanel]@{ AutoSize = $true; AutoSizeMode = 'GrowAndShrink'; FlowDirection = 'TopDown'; WrapContents = $false; Dock = 'Top' }
    $waitTitle = [System.Windows.Forms.Label]@{ Font = [System.Drawing.Font]::new('Segoe UI Semibold', 12); AutoSize = $true; Margin = [System.Windows.Forms.Padding]::new(0, 0, 0, 2) }
    $waitWhy = [System.Windows.Forms.Label]@{ AutoSize = $true; Margin = [System.Windows.Forms.Padding]::new(0, 0, 0, 6) }
    $waitCount = [System.Windows.Forms.Label]@{ Font = [System.Drawing.Font]::new('Segoe UI Semibold', 11); AutoSize = $true; Margin = [System.Windows.Forms.Padding]::new(0) }
    $waitFlow.Controls.AddRange(@($waitTitle, $waitWhy, $waitCount))
    $wait.Controls.Add($waitFlow)
    $layout.Controls.AddRange(@($heading, $note, $wait, $box, $close))

    # This window runs apart from the module, so it is handed the function's text.
    $select = [scriptblock]::Create($SelectLines)
    function Say-Span([double] $Seconds) {
        $s = [int][Math]::Max(0, [Math]::Ceiling($Seconds))
        $m = [Math]::Floor($s / 60); $r = $s % 60
        $parts = @(if ($m) { "$m $(if ($m -eq 1) { 'minute' } else { 'minutes' })" }; if ($r -or -not $m) { "$r $(if ($r -eq 1) { 'second' } else { 'seconds' })" })
        $parts -join ' '
    }
    $read = @{ Position = 0L; Shown = $false; InError = $false }
    $timer = [System.Windows.Forms.Timer]@{ Interval = 500 }
    $timer.Add_Tick({
            try {
                $stream = [System.IO.File]::Open($LogPath, 'Open', 'Read', 'ReadWrite')
                try {
                    $null = $stream.Seek($read.Position, 'Begin')
                    $reader = [System.IO.StreamReader]::new($stream)
                    $text = $reader.ReadToEnd()
                    $read.Position = $stream.Position
                }
                finally { $stream.Dispose() }
                $lines = @(& $select -Lines ($text -split "`r?`n") -Read $read)
                if ($text -and $lines) { $box.AppendText((($lines -join "`r`n").TrimEnd() + "`r`n")) }
            }
            catch { }
            $waiting = $State.Wait
            if ($waiting -and -not $State.Problem) {
                $now = [DateTime]::UtcNow
                $waitTitle.Text = $waiting.Title
                $waitWhy.Text = $waiting.Why
                $left = ($waiting.Until - $now).TotalSeconds
                $so = Say-Span ($now - $waiting.Since).TotalSeconds
                $waitCount.Text = if ($left -ge 1) { "Trying again in $(Say-Span $left). Waiting for $so so far." } else { "Checking now. Waiting for $so so far." }
                if (-not $wait.Visible) { $wait.Visible = $true }
            }
            elseif ($wait.Visible) { $wait.Visible = $false }
            if ($State.Problem -and -not $read.Shown) {
                $read.Shown = $true
                $heading.Text = 'Something went wrong'
                $heading.ForeColor = [System.Drawing.Color]::FromArgb(198, 40, 40)
                $note.Text = 'What happened is at the bottom. Close this window when you have read it.'
                $box.AppendText("`r`n$($State.Problem)`r`n")
                $close.Visible = $true
                $form.Activate()
            }
            if ($State.Close) { $form.Close() }
        })
    $form.Add_Load({
            # Most of the screen, so long lines have room.
            $area = [System.Windows.Forms.Screen]::FromControl($form).WorkingArea
            $width = [Math]::Min($area.Width, [Math]::Max($form.Width, [int]($area.Width * 0.6)))
            $height = [Math]::Min($area.Height, [Math]::Max($form.Height, [int]($area.Height * 0.7)))
            $form.Bounds = [System.Drawing.Rectangle]::new($area.Left + ($area.Width - $width) / 2, $area.Top + ($area.Height - $height) / 2, $width, $height)
        })
    $form.Add_Shown({ $timer.Start() })
    $form.Add_FormClosed({ $timer.Dispose() })
    [void]$form.ShowDialog()
    $form.Dispose()
}

function Start-CrActivityWindow {
    <# Opens the window, following the text file at LogPath. Returns what Stop-CrActivityWindow needs. #>
    param([Parameter(Mandatory)] [string] $LogPath, [string] $Title = 'Getting things ready')
    $state = [hashtable]::Synchronized(@{ Close = $false; Problem = $null; Wait = $null })
    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.ApartmentState = 'STA'
    $runspace.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $runspace
    $null = $ps.AddScript($script:ActivityWindowScript).AddArgument($LogPath).AddArgument($Title).AddArgument($state).AddArgument(${function:Select-CrActivityLines}.ToString())
    [pscustomobject]@{ PowerShell = $ps; Runspace = $runspace; Handle = $ps.BeginInvoke(); State = $state }
}

function Set-CrActivityWait {
    <# Shows why the script is waiting and counts down to Until. Without Title, stops showing it. No window, nothing to do. #>
    param($Window, [string] $Title, [string] $Why, [DateTime] $Since, [DateTime] $Until)
    if (-not $Window) { return }
    $Window.State.Wait = if ($Title) { @{ Title = $Title; Why = $Why; Since = $Since; Until = $Until } } else { $null }
}

function Stop-CrActivityWindow {
    <# Closes the window. With -Problem, shows the problem and waits for the person to close it. #>
    param($Window, [string] $Problem)
    if (-not $Window) { return }
    try {
        if ($Problem) {
            $Window.State.Problem = $Problem
            $null = $Window.Handle.AsyncWaitHandle.WaitOne()
        }
        else {
            # Give it a moment to show the last lines first.
            Start-Sleep -Milliseconds 600
            $Window.State.Close = $true
            $null = $Window.Handle.AsyncWaitHandle.WaitOne(5000)
        }
    }
    finally {
        $Window.PowerShell.Dispose()
        $Window.Runspace.Dispose()
    }
}
