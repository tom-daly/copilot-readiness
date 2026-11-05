# The first window Start.ps1 shows: a check mark or an X for each system check, a Fix
# button for what it can fix itself, and, on the first run, the tenant name.

function New-CrCheckForm {
    <#
      Builds the window. GetChecks is called with the tenant name typed so far and returns
      the checks. When the window closes, its Tag holds Action 'Continue' or 'Cancel',
      and the Tenant typed in (if it asked for one). Tenants are the ones set up on this
      PC before, offered to pick from.
    #>
    param(
        [Parameter(Mandatory)] [scriptblock] $GetChecks,
        [switch] $AskTenant,
        [string[]] $Tenants = @(),
        [string] $ModulePath = (Join-Path $PSScriptRoot 'CopilotReadiness.psm1')
    )
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $font = [System.Drawing.Font]::new('Segoe UI', 9.5)
    $bold = [System.Drawing.Font]::new('Segoe UI Semibold', 10)
    $title = [System.Drawing.Font]::new('Segoe UI Semibold', 14)
    $iconFont = [System.Drawing.Font]::new('Segoe UI Symbol', 13, [System.Drawing.FontStyle]::Bold)
    $muted = [System.Drawing.Color]::FromArgb(95, 102, 112)
    $icons = @{
        Ok      = @{ Text = [string][char]0x2713; Color = [System.Drawing.Color]::FromArgb(26, 127, 55) }
        Info    = @{ Text = 'i'; Color = [System.Drawing.Color]::FromArgb(9, 105, 218) }
        Warning = @{ Text = '!'; Color = [System.Drawing.Color]::FromArgb(179, 89, 0) }
        Fixable = @{ Text = '!'; Color = [System.Drawing.Color]::FromArgb(179, 89, 0) }
        Problem = @{ Text = [string][char]0x2715; Color = [System.Drawing.Color]::FromArgb(198, 40, 40) }
    }

    $form = [System.Windows.Forms.Form]@{
        Text          = 'Copilot Readiness: getting ready'
        Font          = $font
        AutoScaleMode = 'Dpi'
        StartPosition = 'CenterScreen'
        Size          = [System.Drawing.Size]::new(760, 700)
        MinimumSize   = [System.Drawing.Size]::new(640, 480)
        BackColor     = [System.Drawing.Color]::White
        Tag           = [pscustomobject]@{ Action = 'Cancel'; Tenant = $null }
    }

    $layout = [System.Windows.Forms.TableLayoutPanel]@{ Dock = 'Fill'; ColumnCount = 1; Padding = [System.Windows.Forms.Padding]::new(20, 16, 20, 16) }
    $null = $layout.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new('Percent', 100))
    $form.Controls.Add($layout)
    function Add-Row($control, [string] $size = 'AutoSize') {
        $style = if ($size -eq 'Fill') { [System.Windows.Forms.RowStyle]::new('Percent', 100) } else { [System.Windows.Forms.RowStyle]::new('AutoSize') }
        $null = $layout.RowStyles.Add($style)
        $layout.Controls.Add($control)
        $control
    }
    function New-Label([string] $text, $labelFont = $font, $color = $null) {
        $l = [System.Windows.Forms.Label]@{ Text = $text; Font = $labelFont; AutoSize = $true; MaximumSize = [System.Drawing.Size]::new(640, 0); Margin = [System.Windows.Forms.Padding]::new(0, 0, 0, 4) }
        if ($color) { $l.ForeColor = $color }
        $l
    }

    $null = Add-Row (New-Label 'Getting ready' $title)
    $null = Add-Row (New-Label 'Checking this PC before the scan.' $font $muted)

    # First run: the tenant name
    $tenantBox = $null
    if ($AskTenant) {
        $tenantPanel = [System.Windows.Forms.FlowLayoutPanel]@{ AutoSize = $true; Dock = 'Fill'; FlowDirection = 'TopDown'; WrapContents = $false; Margin = [System.Windows.Forms.Padding]::new(0, 12, 0, 0) }
        $tenantPanel.Controls.Add((New-Label $(if ($Tenants) { 'Which Microsoft 365 tenant to scan' } else { 'Your Microsoft 365 tenant name' }) $bold))
        if ($Tenants) {
            $tenantPanel.Controls.Add((New-Label ('Pick one already set up on this PC, or type another: its name (for example contoso) or its SharePoint address. ' +
                        'Another one is set up when you continue: you sign in as one of its Global Administrators.') $font $muted))
        }
        # Typed in, or picked from the tenants set up here before.
        $tenantBox = [System.Windows.Forms.ComboBox]@{ Width = 360; DropDownStyle = 'DropDown' }
        foreach ($t in $Tenants) { [void]$tenantBox.Items.Add($t) }
        if ($tenantBox.PSObject.Properties['PlaceholderText']) { $tenantBox.PlaceholderText = 'for example contoso, or https://contoso.sharepoint.com' }
        $tenantPanel.Controls.Add($tenantBox)
        $null = Add-Row $tenantPanel
    }

    # One row per check: an icon, then the name and what it found.
    $list = [System.Windows.Forms.TableLayoutPanel]@{ Dock = 'Fill'; ColumnCount = 2; AutoScroll = $true; Margin = [System.Windows.Forms.Padding]::new(0, 12, 0, 0) }
    $null = $list.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new('Absolute', 34))
    $null = $list.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new('Percent', 100))
    $null = Add-Row $list 'Fill'

    $status = New-Label '' $font $muted
    $null = Add-Row $status

    $buttons = [System.Windows.Forms.FlowLayoutPanel]@{ FlowDirection = 'RightToLeft'; Dock = 'Fill'; AutoSize = $true; Margin = [System.Windows.Forms.Padding]::new(0, 8, 0, 0) }
    $continue = [System.Windows.Forms.Button]@{ Text = 'Continue'; AutoSize = $true; Padding = [System.Windows.Forms.Padding]::new(12, 3, 12, 3); Enabled = $false }
    $fix = [System.Windows.Forms.Button]@{ Text = 'Fix'; AutoSize = $true; Padding = [System.Windows.Forms.Padding]::new(12, 3, 12, 3); Visible = $false }
    $again = [System.Windows.Forms.Button]@{ Text = 'Check again'; AutoSize = $true; Padding = [System.Windows.Forms.Padding]::new(12, 3, 12, 3) }
    $cancel = [System.Windows.Forms.Button]@{ Text = 'Cancel'; AutoSize = $true; Padding = [System.Windows.Forms.Padding]::new(12, 3, 12, 3); DialogResult = 'Cancel' }
    $buttons.Controls.AddRange(@($continue, $fix, $again, $cancel))
    $null = Add-Row $buttons
    $form.AcceptButton = $continue
    $form.CancelButton = $cancel

    $state = @{ Checks = @(); CheckedTenant = $null; Job = $null }

    $show = {
        $list.SuspendLayout()
        $list.Controls.Clear()
        $list.RowStyles.Clear()
        foreach ($c in $state.Checks) {
            $null = $list.RowStyles.Add([System.Windows.Forms.RowStyle]::new('AutoSize'))
            $icon = [System.Windows.Forms.Label]@{ Text = $icons[$c.State].Text; ForeColor = $icons[$c.State].Color; Font = $iconFont; AutoSize = $true; Margin = [System.Windows.Forms.Padding]::new(0, 6, 0, 0) }
            $text = [System.Windows.Forms.FlowLayoutPanel]@{ AutoSize = $true; FlowDirection = 'TopDown'; WrapContents = $false; Margin = [System.Windows.Forms.Padding]::new(0, 4, 0, 4) }
            $name = [System.Windows.Forms.Label]@{ Text = $c.Name; Font = $bold; AutoSize = $true; Margin = [System.Windows.Forms.Padding]::new(0) }
            $detail = [System.Windows.Forms.Label]@{ Text = $c.Detail; ForeColor = $muted; AutoSize = $true; MaximumSize = [System.Drawing.Size]::new(560, 0); Margin = [System.Windows.Forms.Padding]::new(0, 2, 0, 0) }
            $text.Controls.AddRange(@($name, $detail))
            $list.Controls.Add($icon)
            $list.Controls.Add($text)
        }
        $list.ResumeLayout()

        $blocked = @($state.Checks | Where-Object State -In 'Problem', 'Fixable').Count
        $fix.Visible = [bool]@($state.Checks | Where-Object State -EQ 'Fixable').Count
        $needTenant = $tenantBox -and -not $tenantBox.Text.Trim()
        $continue.Enabled = -not $blocked -and -not $needTenant -and -not $state.Job
        $status.Text = if ($state.Job) { $status.Text }
        elseif ($blocked) { 'Fix the items marked with an X or an exclamation point, then check again.' }
        elseif ($needTenant) { 'Type your tenant name to continue.' }
        else { 'All set.' }
    }.GetNewClosure()

    $run = {
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        $status.Text = 'Checking...'
        [System.Windows.Forms.Application]::DoEvents()
        $tenant = if ($tenantBox) { $tenantBox.Text.Trim() } else { $null }
        $state.Checks = @(& $GetChecks $tenant)
        $state.CheckedTenant = $tenant
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
        & $show
    }.GetNewClosure()

    # Fixes (installing PnP.PowerShell) take a while, so they run beside the window and it stays responsive.
    $timer = [System.Windows.Forms.Timer]@{ Interval = 500 }
    $timer.Add_Tick({
            if ($state.Job.State -in 'Running', 'NotStarted') { return }
            $timer.Stop()
            $failed = $state.Job.State -eq 'Failed' -or $state.Job.Error.Count
            $why = if ($failed) { "$($state.Job.JobStateInfo.Reason.Message) $($state.Job.Error | Select-Object -First 1)".Trim() }
            Remove-Job $state.Job -Force
            $state.Job = $null
            $again.Enabled = $true
            & $run
            if ($failed) { $status.Text = "The fix didn't work: $why" }
        }.GetNewClosure())

    $fix.Add_Click({
            $fixes = @($state.Checks | Where-Object State -EQ 'Fixable' | ForEach-Object Fix | Select-Object -Unique)
            $fix.Visible = $false; $continue.Enabled = $false; $again.Enabled = $false
            $status.Text = 'Fixing... installing PnP.PowerShell can take a minute or two.'
            $state.Job = Start-ThreadJob -ArgumentList $ModulePath, $fixes -ScriptBlock {
                param($modulePath, $fixes)
                Import-Module $modulePath
                foreach ($f in $fixes) { Invoke-CrSystemFix $f }
            }
            $timer.Start()
        }.GetNewClosure())

    $again.Add_Click({ & $run }.GetNewClosure())
    if ($tenantBox) {
        $tenantBox.Add_TextChanged({ & $show }.GetNewClosure())
        $tenantBox.Add_SelectionChangeCommitted({ $form.BeginInvoke([Action]{ & $run }) | Out-Null }.GetNewClosure())
        $tenantBox.Add_Leave({ if ($tenantBox.Text.Trim() -and $tenantBox.Text.Trim() -ne $state.CheckedTenant) { & $run } }.GetNewClosure())
    }
    $continue.Add_Click({
            # A tenant name typed since the last check gets checked before going on.
            if ($tenantBox -and $tenantBox.Text.Trim() -ne $state.CheckedTenant) { & $run; if (-not $continue.Enabled) { return } }
            $form.Tag = [pscustomobject]@{ Action = 'Continue'; Tenant = $(if ($tenantBox) { $tenantBox.Text.Trim() }) }
            $form.Close()
        }.GetNewClosure())
    $form.Add_Load({ Set-CrFitToScreen $form }.GetNewClosure())
    $form.Add_Shown({ & $run }.GetNewClosure())
    $form.Add_FormClosed({ $timer.Dispose() }.GetNewClosure())

    $form
}

function Show-CrCheckWindow {
    <# Shows the system check window; returns Action 'Continue' or 'Cancel', and the Tenant typed in. #>
    param([Parameter(Mandatory)] [scriptblock] $GetChecks, [switch] $AskTenant, [string[]] $Tenants = @())
    $form = New-CrCheckForm -GetChecks $GetChecks -AskTenant:$AskTenant -Tenants $Tenants
    try {
        [void]$form.ShowDialog()
        $form.Tag
    }
    finally {
        $form.Dispose()
    }
}
