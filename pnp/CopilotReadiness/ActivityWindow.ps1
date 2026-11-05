# A window that shows what the script is printing while no other window is up: setting
# up, signing in, waiting for a new app's permissions, finding sites. It runs on its own
# thread, so it keeps updating while the script works, and follows a text file the
# script writes to (its transcript). If something goes wrong it says so and stays open.

$script:ActivityWindowScript = {
    param([string] $LogPath, [string] $Title, [hashtable] $State)
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
    foreach ($size in 'AutoSize', 'AutoSize', 'Fill', 'AutoSize') {
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
    $layout.Controls.AddRange(@($heading, $note, $box, $close))

    # The transcript starts and ends with a block of details about the PC; leave those out.
    $skip = '^(\*{10,}|PowerShell transcript (start|end)|Start time:|End time:|Username:|RunAs User:|Configuration Name:|Machine:|Host Application:|Process ID:|PS\w*Version:|PSEdition:|PSCompatibleVersions:|GitCommitId:|OS:|Platform:|BuildVersion:|CLRVersion:|WSManStackVersion:|SerializationVersion:|Transcript started)'
    $read = @{ Position = 0L; Shown = $false }
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
                $lines = @($text -split "`r?`n" | Where-Object { $_ -notmatch $skip })
                if ($text -and $lines) { $box.AppendText((($lines -join "`r`n").TrimEnd() + "`r`n")) }
            }
            catch { }
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
    $state = [hashtable]::Synchronized(@{ Close = $false; Problem = $null })
    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.ApartmentState = 'STA'
    $runspace.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $runspace
    $null = $ps.AddScript($script:ActivityWindowScript).AddArgument($LogPath).AddArgument($Title).AddArgument($state)
    [pscustomobject]@{ PowerShell = $ps; Runspace = $runspace; Handle = $ps.BeginInvoke(); State = $state }
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
