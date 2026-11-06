# The control window: pick how deep to scan and which sites, see roughly how long it
# will take, then start. Also offers to continue an unfinished scan. Windows only;
# Start.ps1 -NoWindow does the same from the command line.

function Get-CrEstimate {
    <#
      A rough range for how long a scan takes, as text. Seconds per site are guesses from
      typical tenants; OneDrives always have their shared files checked, so one rate fits
      them all. Several sites at once (Parallel) divide the time.
    #>
    param([Parameter(Mandatory)] [string] $Level, [Parameter(Mandatory)] [int] $SiteCount, [int] $OneDriveCount = 0, [int] $Parallel = 1)
    $perSite = @{ Quick = 2, 6; Standard = 5, 40; Deep = 15, 240 }[$Level]
    $perOneDrive = 3, 45
    if ($SiteCount + $OneDriveCount -eq 0) { return 'Nothing chosen' }
    $at = [Math]::Max(1, $Parallel)

    # Minutes up to 90, then hours up to two days, then days.
    function Span([double] $seconds) {
        $minutes = [Math]::Max(1, [Math]::Round($seconds / 60))
        if ($minutes -lt 90) { return @{ N = $minutes; Unit = 'minute' } }
        $hours = [Math]::Round($seconds / 3600)
        if ($hours -lt 48) { return @{ N = $hours; Unit = 'hour' } }
        @{ N = [Math]::Round($seconds / 86400); Unit = 'day' }
    }
    function Say($span) { if ($span.N -eq 1) { "1 $($span.Unit)" } else { "$($span.N) $($span.Unit)s" } }

    $low = Span (($SiteCount * $perSite[0] + $OneDriveCount * $perOneDrive[0]) / $at)
    $high = Span (($SiteCount * $perSite[1] + $OneDriveCount * $perOneDrive[1]) / $at)
    $what = @(
        $(if ($SiteCount) { if ($SiteCount -eq 1) { '1 site' } else { '{0:N0} sites' -f $SiteCount } }),
        $(if ($OneDriveCount) { if ($OneDriveCount -eq 1) { '1 OneDrive' } else { '{0:N0} OneDrives' -f $OneDriveCount } })
    ) | Where-Object { $_ }
    $sites = $what -join ' and '
    $range = if ($low.N -eq $high.N -and $low.Unit -eq $high.Unit) { "about $(Say $high)" }
    elseif ($low.Unit -eq $high.Unit) { "roughly $($low.N) to $(Say $high)" }
    else { "roughly $(Say $low) to $(Say $high)" }
    "$($sites): $range"
}

function New-CrControlForm {
    <#
      Builds the window. When it closes, its Tag holds the choice:
      Action 'New' (with Level, Include and Sites), 'Resume' (with Folder; the scan may already be
      running, in which case it is only to be watched), 'SwitchTenant' or 'Cancel'.
      Sites holds SharePoint sites and OneDrives, each with its kind; Include picks which
      are scanned. DefaultLevel, DefaultInclude and DefaultSites (addresses) are what it
      starts with. PastScans (from Get-CrPastScans) fills the Past scans tab; About (from
      Get-CrAbout) fills the Settings tab. TenantSettings (from Get-CrTenantSettingsView, or the
      reason they couldn't be read) fills the Tenant tab; TenantSettingsRead says when they were
      read (ReadAt) and why a refresh failed (Problem). Remediation (see Add-CrRemediationTab)
      adds the Remediation tab. StartTab names the tab to open on, and StartGroup the group on the
      Tenant tab, which RefreshTenant hands back as Group.
      Two more actions close it: 'RefreshTenant' (read the tenant's settings again, then open on
      the Tenant tab) and 'Uninstall' (remove the app from the tenant and this PC, already confirmed).
    #>
    param(
        [Parameter(Mandatory)] [object[]] $Sites,
        [Parameter(Mandatory)] [string] $TenantName,
        [string] $SharePointUrl,
        $Unfinished,
        [object[]] $PastScans = @(),
        [string] $DefaultLevel = 'Quick',
        [ValidateSet('SharePoint', 'OneDrive', 'Both')] [string] $DefaultInclude = 'SharePoint',
        [string[]] $DefaultSites = @(),
        [string] $DefaultPace = 'Normal',
        $About,
        $TenantSettings,
        $TenantSettingsRead,
        [hashtable] $Remediation,
        [string] $StartTab,
        [string] $StartGroup
    )
    $spCount = @($Sites | Where-Object kind -NE 'OneDrive').Count
    $odCount = @($Sites | Where-Object kind -EQ 'OneDrive').Count
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $font = [System.Drawing.Font]::new('Segoe UI', 9.5)
    $bold = [System.Drawing.Font]::new('Segoe UI Semibold', 10)
    $title = [System.Drawing.Font]::new('Segoe UI Semibold', 14)
    $muted = [System.Drawing.Color]::FromArgb(95, 102, 112)

    $form = [System.Windows.Forms.Form]@{
        Text            = 'Copilot Readiness scan'
        Font            = $font
        AutoScaleMode   = 'Dpi'
        StartPosition   = 'CenterScreen'
        Size            = [System.Drawing.Size]::new(860, 980)
        MinimumSize     = [System.Drawing.Size]::new(900, 640)
        BackColor       = [System.Drawing.Color]::White
        Tag             = [pscustomobject]@{ Action = 'Cancel'; Level = $null; Include = $null; Sites = @(); Folder = $null }
    }
    $logo = New-CrLogo 96
    $form.Icon = [System.Drawing.Icon]::FromHandle((New-CrLogo 64).GetHicon())

    $layout = [System.Windows.Forms.TableLayoutPanel]@{ Dock = 'Fill'; ColumnCount = 1; Padding = [System.Windows.Forms.Padding]::new(20, 16, 20, 16) }
    $null = $layout.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new('Percent', 100))
    $form.Controls.Add($layout)
    function Add-Row($control, [string] $size = 'AutoSize', [System.Windows.Forms.TableLayoutPanel] $to = $layout) {
        $style = if ($size -eq 'Fill') { [System.Windows.Forms.RowStyle]::new('Percent', 100) } else { [System.Windows.Forms.RowStyle]::new('AutoSize') }
        $null = $to.RowStyles.Add($style)
        $to.Controls.Add($control)
        $control
    }
    function New-Page([string] $text) {
        $page = [System.Windows.Forms.TabPage]@{ Text = $text; BackColor = [System.Drawing.Color]::White; Padding = [System.Windows.Forms.Padding]::new(12, 8, 12, 8); AutoScroll = $true }
        $pageLayout = [System.Windows.Forms.TableLayoutPanel]@{ Dock = 'Fill'; ColumnCount = 1 }
        $null = $pageLayout.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new('Percent', 100))
        $page.Controls.Add($pageLayout)
        $page, $pageLayout
    }
    # Labels that wrap; they are widened with the window.
    $wrapped = [System.Collections.Generic.List[System.Windows.Forms.Label]]::new()
    # As a closure too, for what's made after the window is built.
    $makeLabel = {
        param([string] $text, $labelFont, $color, [int] $width = 640)
        $l = [System.Windows.Forms.Label]@{ Text = $text; Font = $labelFont; AutoSize = $true; MaximumSize = [System.Drawing.Size]::new($width, 0); Margin = [System.Windows.Forms.Padding]::new(0, 0, 0, 4) }
        if ($color) { $l.ForeColor = $color }
        $wrapped.Add($l)
        $l
    }.GetNewClosure()
    function New-Label([string] $text, $labelFont = $font, $color = $null) { & $makeLabel $text $labelFont $color }

    # Title on the left; on the right, which tenant this is and a button to sign out of it.
    $header = [System.Windows.Forms.TableLayoutPanel]@{ AutoSize = $true; Dock = 'Fill'; ColumnCount = 2; RowCount = 1; Margin = [System.Windows.Forms.Padding]::new(0, 0, 0, 4) }
    $null = $header.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new('Percent', 100))
    $null = $header.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new('AutoSize'))
    $titleRow = [System.Windows.Forms.FlowLayoutPanel]@{ AutoSize = $true; WrapContents = $false; Anchor = 'Left'; Margin = [System.Windows.Forms.Padding]::new(0) }
    $logoBox = [System.Windows.Forms.PictureBox]@{ Image = $logo; SizeMode = 'Zoom'; Size = [System.Drawing.Size]::new(36, 36); Margin = [System.Windows.Forms.Padding]::new(0, 0, 10, 0) }
    $titleLabel = [System.Windows.Forms.Label]@{ Text = 'Copilot Readiness scan'; Font = $title; AutoSize = $true; Margin = [System.Windows.Forms.Padding]::new(0, 4, 0, 0) }
    $titleRow.Controls.AddRange(@($logoBox, $titleLabel))
    $header.Controls.Add($titleRow, 0, 0)

    $account = [System.Windows.Forms.TableLayoutPanel]@{ AutoSize = $true; ColumnCount = 2; RowCount = 2; Anchor = 'Right'; Margin = [System.Windows.Forms.Padding]::new(16, 0, 0, 0) }
    $tenantLabel = [System.Windows.Forms.Label]@{ Text = $TenantName; Font = $bold; AutoSize = $true; Anchor = 'Right'; Margin = [System.Windows.Forms.Padding]::new(0, 0, 10, 0) }
    # The SharePoint address only adds something when it doesn't start with the tenant's own name (contoso.onmicrosoft.com is contoso.sharepoint.com).
    $spHost = if ($SharePointUrl) { ([uri]$SharePointUrl).Host } else { '' }
    $hostLabel = [System.Windows.Forms.Label]@{ Text = $spHost; ForeColor = $muted; AutoSize = $true; Anchor = 'Right'; Margin = [System.Windows.Forms.Padding]::new(0, 0, 10, 0) }
    $hostLabel.Visible = $spHost -and $spHost.Split('.')[0] -ne "$TenantName".Split('.')[0]
    $signOut = [System.Windows.Forms.Button]@{
        Text = 'Sign out'; AutoSize = $true; FlatStyle = 'Flat'; TextImageRelation = 'ImageBeforeText'; Cursor = [System.Windows.Forms.Cursors]::Hand
        Padding = [System.Windows.Forms.Padding]::new(6, 2, 8, 2); Anchor = 'Right'; Margin = [System.Windows.Forms.Padding]::new(0)
    }
    $signOut.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(200, 205, 212)
    $signOut.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(240, 243, 246)
    $signOut.Image = New-CrGlyph ([char]0xF3B1) $signOut.Font.Height
    $signOut.Add_Click({ $form.Tag = [pscustomobject]@{ Action = 'SwitchTenant'; Level = $null; Include = $null; Sites = @() }; $form.Close() }.GetNewClosure())
    $tips = [System.Windows.Forms.ToolTip]::new()
    $tips.SetToolTip($signOut, 'Sign out of this tenant, then choose which tenant to scan')
    $account.Controls.Add($tenantLabel, 0, 0)
    $account.Controls.Add($hostLabel, 0, 1)
    $account.Controls.Add($signOut, 1, 0)
    $account.SetRowSpan($signOut, 2)
    $header.Controls.Add($account, 1, 0)
    $null = Add-Row $header

    $null = Add-Row (New-Label ('{0:N0} SharePoint {1} and {2:N0} {3} found.' -f $spCount, $(if ($spCount -eq 1) { 'site' } else { 'sites' }), $odCount, $(if ($odCount -eq 1) { 'OneDrive' } else { 'OneDrives' })) $font $muted)

    # An unfinished scan to continue
    if ($Unfinished) {
        $started = [DateTimeOffset]::Parse($Unfinished.Scan.startedAt, [Globalization.CultureInfo]::InvariantCulture).ToLocalTime().ToString('MMMM d, h:mm tt')
        $doneCount = @(Get-ChildItem -LiteralPath (Join-Path $Unfinished.Folder 'sites') -Filter '*.json').Count
        $resumeBox = [System.Windows.Forms.GroupBox]@{ Text = 'Unfinished scan'; AutoSize = $true; Dock = 'Top'; Padding = [System.Windows.Forms.Padding]::new(12, 4, 12, 8); Margin = [System.Windows.Forms.Padding]::new(0, 12, 0, 0) }
        # One line: what stopped, and the button to continue it.
        $resumeFlow = [System.Windows.Forms.FlowLayoutPanel]@{ Dock = 'Fill'; AutoSize = $true; FlowDirection = 'LeftToRight'; WrapContents = $true }
        $resumeText = New-Label "A $($Unfinished.Scope.level) scan started $started stopped after $doneCount of $(@($Unfinished.Scope.sites).Count) sites."
        $resumeText.Margin = [System.Windows.Forms.Padding]::new(0, 7, 16, 0)
        $resumeFlow.Controls.Add($resumeText)
        $resumeButton = [System.Windows.Forms.Button]@{ Text = 'Continue that scan'; AutoSize = $true; Padding = [System.Windows.Forms.Padding]::new(8, 2, 8, 2) }
        Set-CrButtonStyle $resumeButton Primary
        $resumeButton.Add_Click({ $form.Tag = [pscustomobject]@{ Action = 'Resume'; Level = $null; Include = $null; Sites = @(); Folder = $Unfinished.Folder }; $form.Close() }.GetNewClosure())
        $resumeFlow.Controls.Add($resumeButton)
        $resumeBox.Controls.Add($resumeFlow)
        $null = Add-Row $resumeBox
    }

    # Two tabs: start a new scan, or look back at earlier ones.
    $tabs = [System.Windows.Forms.TabControl]@{ Dock = 'Fill'; Padding = [System.Drawing.Point]::new(14, 5); Margin = [System.Windows.Forms.Padding]::new(0, 12, 0, 0) }
    $newPage, $newLayout = New-Page 'New scan'
    $pastPage, $pastLayout = New-Page "Past scans ($(@($PastScans).Count))"
    $tabs.TabPages.AddRange(@($newPage, $pastPage))
    $tenantPage = $null
    # The Tenant tab's settings are on tabs of their own, by group, so only the group on screen is measured.
    # Each card is measured once and then keeps its size, because measuring all of them every time the tab
    # was shown took ten seconds or more; they are measured again when the width changes. By group's page:
    # Layout, the group's cards, and the code boxes in them.
    $tenantTabs = if ($TenantSettings -and $TenantSettings -isnot [string]) { [System.Windows.Forms.TabControl]@{ Dock = 'Fill'; Padding = [System.Drawing.Point]::new(12, 5); Margin = [System.Windows.Forms.Padding]::new(0, 8, 0, 0) } }
    $tenantGroups = [System.Collections.Generic.Dictionary[object, object]]::new()
    $tenantWidth = @{ Rest = 640 }
    if ($TenantSettings) {
        $tenantPage, $tenantLayout = New-Page 'Tenant'
        $tenantPage.AutoScroll = $false
        $tabs.TabPages.Add($tenantPage)
    }
    if ($Remediation) {
        $null = Add-CrRemediationTab -Form $form -Tabs $tabs -Sites $Sites -Remediation $Remediation -Font $font -Bold $bold -Muted $muted -NewLabel ${function:New-Label}
    }
    if ($About) { $settingsPage, $settingsLayout = New-Page 'Settings'; $tabs.TabPages.Add($settingsPage) }
    $null = Add-Row $tabs 'Fill'

    # New scan: what and how deep on the left, which sites on the right with the full height, the estimate across the bottom.
    $newLayout.ColumnCount = 2
    $newLayout.ColumnStyles.Clear()
    $null = $newLayout.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new('Percent', 50))
    $null = $newLayout.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new('Percent', 50))
    foreach ($size in 'AutoSize', 'AutoSize', 'Fill', 'AutoSize') {
        $null = $newLayout.RowStyles.Add($(if ($size -eq 'Fill') { [System.Windows.Forms.RowStyle]::new('Percent', 100) } else { [System.Windows.Forms.RowStyle]::new('AutoSize') }))
    }

    # What to scan: SharePoint sites, OneDrive, or both
    $kindBox = [System.Windows.Forms.GroupBox]@{ Text = 'What to scan'; AutoSize = $true; Dock = 'Top'; Padding = [System.Windows.Forms.Padding]::new(12, 8, 12, 8); Margin = [System.Windows.Forms.Padding]::new(0, 4, 6, 0) }
    $kindFlow = [System.Windows.Forms.FlowLayoutPanel]@{ Dock = 'Fill'; AutoSize = $true; FlowDirection = 'TopDown'; WrapContents = $false }
    $kindRow = [System.Windows.Forms.FlowLayoutPanel]@{ AutoSize = $true; FlowDirection = 'TopDown'; WrapContents = $false; Margin = [System.Windows.Forms.Padding]::new(0) }
    $kindRadios = [ordered]@{}
    foreach ($k in @(@('SharePoint', 'SharePoint sites'), @('Both', 'SharePoint sites and OneDrive'), @('OneDrive', 'OneDrive only'))) {
        $radio = [System.Windows.Forms.RadioButton]@{ Text = $k[1]; Font = $bold; AutoSize = $true; Tag = $k[0]; Margin = [System.Windows.Forms.Padding]::new(0, 4, 24, 0) }
        $kindRadios[$k[0]] = $radio
        $kindRow.Controls.Add($radio)
    }
    $kindRadios[$DefaultInclude].Checked = $true
    $kindFlow.Controls.Add($kindRow)
    $kindNote = New-Label ('OneDrive: each person''s shared files are checked one by one for "Anyone" links, company-wide links, guests and "Everyone" access, ' +
        'whatever the level below. The report lists the names of those files, so check your organization is happy with that. OneDrive gets a score of its own.') $font $muted
    $kindNote.Margin = [System.Windows.Forms.Padding]::new(0, 6, 0, 0)
    $kindNote.Tag = 'half'
    $kindFlow.Controls.Add($kindNote)
    $kindBox.Controls.Add($kindFlow)
    $newLayout.Controls.Add($kindBox, 0, 0)

    # How deep
    $levelBox = [System.Windows.Forms.GroupBox]@{ Text = 'How deep (SharePoint sites)'; AutoSize = $true; Dock = 'Top'; Padding = [System.Windows.Forms.Padding]::new(12, 8, 12, 8); Margin = [System.Windows.Forms.Padding]::new(0, 12, 6, 0) }
    $levelFlow = [System.Windows.Forms.FlowLayoutPanel]@{ Dock = 'Fill'; AutoSize = $true; FlowDirection = 'TopDown'; WrapContents = $false }
    $levelRadios = @{}
    foreach ($level in Get-CrScanLevels) {
        $radio = [System.Windows.Forms.RadioButton]@{ Text = "$($level.Name): $($level.Summary)"; Font = $bold; AutoSize = $true; Tag = $level.Id; Margin = [System.Windows.Forms.Padding]::new(0, 6, 0, 0) }
        $levelRadios[$level.Id] = $radio
        $levelFlow.Controls.Add($radio)
        $desc = New-Label "$($level.Description) Takes $($level.PerSite)." $font $muted
        $desc.Margin = [System.Windows.Forms.Padding]::new(18, 0, 0, 4)
        $desc.Tag = 'half'
        $levelFlow.Controls.Add($desc)
    }
    $levelRadios[$(if ($levelRadios.ContainsKey($DefaultLevel)) { $DefaultLevel } else { 'Quick' })].Checked = $true
    $levelBox.Controls.Add($levelFlow)
    $newLayout.Controls.Add($levelBox, 0, 1)

    # How fast: one row of choices and a line about the one picked.
    $paceBox = [System.Windows.Forms.GroupBox]@{ Text = 'Pace'; AutoSize = $true; Dock = 'Top'; Padding = [System.Windows.Forms.Padding]::new(12, 8, 12, 8); Margin = [System.Windows.Forms.Padding]::new(0, 12, 6, 0) }
    $paceFlow = [System.Windows.Forms.FlowLayoutPanel]@{ Dock = 'Fill'; AutoSize = $true; FlowDirection = 'TopDown'; WrapContents = $false }
    $paceRow = [System.Windows.Forms.FlowLayoutPanel]@{ AutoSize = $true; FlowDirection = 'LeftToRight'; WrapContents = $false; Margin = [System.Windows.Forms.Padding]::new(0) }
    $paceRadios = [ordered]@{}
    foreach ($pace in Get-CrPaces) {
        $radio = [System.Windows.Forms.RadioButton]@{ Text = $pace.Name; Font = $bold; AutoSize = $true; Tag = $pace.Id; Margin = [System.Windows.Forms.Padding]::new(0, 4, 24, 0) }
        $paceRadios[$pace.Id] = $radio
        $paceRow.Controls.Add($radio)
    }
    $paceRadios[(Get-CrPace $DefaultPace).Id].Checked = $true
    $paceNote = New-Label '' $font $muted
    $paceNote.Margin = [System.Windows.Forms.Padding]::new(0, 6, 0, 0)
    $paceNote.Tag = 'half'
    $paceFlow.Controls.AddRange(@($paceRow, $paceNote))
    $paceBox.Controls.Add($paceFlow)
    $newLayout.Controls.Add($paceBox, 0, 2)

    # Which sites
    $siteBox = [System.Windows.Forms.GroupBox]@{ Text = 'Which sites'; Dock = 'Fill'; Padding = [System.Windows.Forms.Padding]::new(12, 8, 12, 12); Margin = [System.Windows.Forms.Padding]::new(6, 4, 0, 0) }
    $siteLayout = [System.Windows.Forms.TableLayoutPanel]@{ Dock = 'Fill'; ColumnCount = 1 }
    $null = $siteLayout.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new('Percent', 100))
    foreach ($i in 1..3) { $null = $siteLayout.RowStyles.Add([System.Windows.Forms.RowStyle]::new('AutoSize')) }
    $null = $siteLayout.RowStyles.Add([System.Windows.Forms.RowStyle]::new('Percent', 100))
    $null = $siteLayout.RowStyles.Add([System.Windows.Forms.RowStyle]::new('AutoSize'))

    $allRadio = [System.Windows.Forms.RadioButton]@{ Text = "All"; AutoSize = $true; Checked = $true }
    $someRadio = [System.Windows.Forms.RadioButton]@{ Text = 'Only the ones I check below'; AutoSize = $true }
    $filter = [System.Windows.Forms.TextBox]@{ Dock = 'Fill'; PlaceholderText = 'Type to find one by name or address'; Enabled = $false; Margin = [System.Windows.Forms.Padding]::new(18, 4, 0, 4) }
    $list = [System.Windows.Forms.CheckedListBox]@{ Dock = 'Fill'; CheckOnClick = $true; IntegralHeight = $false; Enabled = $false; Margin = [System.Windows.Forms.Padding]::new(18, 0, 0, 4) }
    $listButtons = [System.Windows.Forms.FlowLayoutPanel]@{ AutoSize = $true; Dock = 'Fill'; Margin = [System.Windows.Forms.Padding]::new(14, 0, 0, 0) }
    $tickShown = [System.Windows.Forms.LinkLabel]@{ Text = 'Check all shown'; AutoSize = $true; Enabled = $false }
    $clearAll = [System.Windows.Forms.LinkLabel]@{ Text = 'Clear'; AutoSize = $true; Enabled = $false }
    $listButtons.Controls.AddRange(@($tickShown, $clearAll))
    $siteLayout.Controls.AddRange(@($allRadio, $someRadio, $filter, $list, $listButtons))
    $siteBox.Controls.Add($siteLayout)
    $newLayout.Controls.Add($siteBox, 1, 0)
    $newLayout.SetRowSpan($siteBox, 3)

    # The list shows sites matching the filter; checks are kept by address so filtering doesn't lose them.
    $chosen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($url in $DefaultSites) { if ($url) { [void]$chosen.Add($url.Trim().TrimEnd('/')) } }
    $shown = [System.Collections.Generic.List[string]]::new()   # the address behind each line of the list
    $state = @{ Filling = $false }
    $selectedInclude = { ($kindRadios.Values | Where-Object Checked | Select-Object -First 1).Tag }.GetNewClosure()
    $included = { param($s) $inc = & $selectedInclude; $inc -eq 'Both' -or ($inc -eq 'OneDrive') -eq ($s.kind -eq 'OneDrive') }.GetNewClosure()
    $fill = {
        $state.Filling = $true
        $list.BeginUpdate()
        $list.Items.Clear()
        $shown.Clear()
        $text = $filter.Text.Trim()
        foreach ($s in $Sites) {
            if (-not (& $included $s)) { continue }
            if ($text -and $s.url.IndexOf($text, [StringComparison]::OrdinalIgnoreCase) -lt 0 -and "$($s.title)".IndexOf($text, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
            $i = $list.Items.Add($(if ($s.title) { "$($s.title)   ($($s.url))" } else { $s.url }))
            $shown.Add($s.url)
            if ($chosen.Contains($s.url)) { $list.SetItemChecked($i, $true) }
        }
        $list.EndUpdate()
        $state.Filling = $false
    }.GetNewClosure()

    # Estimate and buttons
    $estimate = New-Label '' $bold
    $estimate.Margin = [System.Windows.Forms.Padding]::new(0, 12, 0, 4)
    $newLayout.Controls.Add($estimate, 0, 3)
    $newLayout.SetColumnSpan($estimate, 2)
    $buttons = [System.Windows.Forms.FlowLayoutPanel]@{ FlowDirection = 'RightToLeft'; Dock = 'Fill'; AutoSize = $true; Margin = [System.Windows.Forms.Padding]::new(0, 8, 0, 0) }
    $start = [System.Windows.Forms.Button]@{ Text = 'Start scan'; AutoSize = $true; Padding = [System.Windows.Forms.Padding]::new(12, 3, 12, 3) }
    $cancel = [System.Windows.Forms.Button]@{ Text = 'Cancel'; AutoSize = $true; Padding = [System.Windows.Forms.Padding]::new(12, 3, 12, 3); DialogResult = 'Cancel' }
    $buttons.Controls.AddRange(@($start, $cancel))
    Set-CrButtonStyle $start Primary
    Set-CrButtonStyle $cancel
    $null = Add-Row $buttons
    $form.AcceptButton = $start
    $form.CancelButton = $cancel

    # Past scans of this tenant, newest first: open a finished one's report, continue one that stopped, or remove old ones.
    $pastNote = New-Label $(if (@($PastScans).Count) { 'Scans of this tenant run on this PC, newest first. Double-click a finished one to open its report. Hold Ctrl or Shift to pick several to remove.' } else { 'No scans of this tenant on this PC yet.' }) $font $muted
    $pastHint = $pastNote.Text
    $null = Add-Row $pastNote -to $pastLayout
    $pastList = [System.Windows.Forms.ListView]@{ View = 'Details'; FullRowSelect = $true; MultiSelect = $true; HideSelection = $false; Dock = 'Fill'; Margin = [System.Windows.Forms.Padding]::new(0, 4, 0, 4) }
    foreach ($c in @(@('Started', 175), @('What', 230), @('Sites', 90), @('How it ended', 170), @('Score', 60), @('OneDrive score', 115), @('High', 55), @('Medium', 65), @('Low', 50))) {
        $null = $pastList.Columns.Add($c[0], $c[1])
    }
    foreach ($p in $PastScans) {
        $what = switch ($p.Include) {
            'OneDrive' { 'OneDrive' }
            'Both' { "$($p.Level), SharePoint and OneDrive" }
            default { "$($p.Level), SharePoint sites" }
        }
        $ended = switch ($p.State) {
            'Completed' { 'Finished' }
            'Running' { 'Running now' }
            'OlderRules' { 'Stopped, older rules' }
            'NewerRules' { 'Stopped, newer rules' }
            default { 'Stopped, can continue' }
        }
        $row = [System.Windows.Forms.ListViewItem]::new($p.StartedAt.ToLocalTime().ToString('MMM d, yyyy, h:mm tt'))
        foreach ($text in @($what, ('{0:N0} of {1:N0}' -f $p.Done, $p.Total), $ended, "$($p.Score)", "$($p.OneDriveScore)",
                $(if ($p.Findings) { '{0:N0}' -f $p.Findings.High } else { '' }), $(if ($p.Findings) { '{0:N0}' -f $p.Findings.Medium } else { '' }), $(if ($p.Findings) { '{0:N0}' -f $p.Findings.Low } else { '' }))) {
            $null = $row.SubItems.Add($text)
        }
        if ($p.State -ne 'Completed') { $row.ForeColor = $muted }
        $row.Tag = $p
        $null = $pastList.Items.Add($row)
    }
    $null = Add-Row $pastList 'Fill' $pastLayout

    $pastButtons = [System.Windows.Forms.FlowLayoutPanel]@{ FlowDirection = 'LeftToRight'; Dock = 'Fill'; AutoSize = $true; Margin = [System.Windows.Forms.Padding]::new(0, 4, 0, 0) }
    $openReport = [System.Windows.Forms.Button]@{ Text = 'Open report'; AutoSize = $true; Padding = [System.Windows.Forms.Padding]::new(10, 2, 10, 2); Enabled = $false }
    $carryOn = [System.Windows.Forms.Button]@{ Text = 'Continue scan'; AutoSize = $true; Padding = [System.Windows.Forms.Padding]::new(10, 2, 10, 2); Enabled = $false }
    $openFolder = [System.Windows.Forms.Button]@{ Text = 'Open its folder'; AutoSize = $true; Padding = [System.Windows.Forms.Padding]::new(10, 2, 10, 2); Enabled = $false }
    $removeScans = [System.Windows.Forms.Button]@{ Text = 'Remove'; AutoSize = $true; Padding = [System.Windows.Forms.Padding]::new(10, 2, 10, 2); Enabled = $false; Margin = [System.Windows.Forms.Padding]::new(24, 3, 3, 3) }
    $pastButtons.Controls.AddRange(@($openReport, $carryOn, $openFolder, $removeScans))
    Set-CrButtonStyle $openReport Primary
    Set-CrButtonStyle $carryOn Primary
    Set-CrButtonStyle $openFolder
    Set-CrButtonStyle $removeScans Danger
    $null = Add-Row $pastButtons -to $pastLayout

    # Open, continue and open its folder work on one scan; Remove on any picked that aren't running.
    $picked = { if ($pastList.SelectedItems.Count -eq 1) { $pastList.SelectedItems[0].Tag } }.GetNewClosure()
    $removable = { @($pastList.SelectedItems | Where-Object { $_.Tag.State -ne 'Running' }) }.GetNewClosure()
    $pastList.Add_SelectedIndexChanged({
            $p = & $picked
            $openReport.Enabled = [bool]($p -and $p.Report)
            $carryOn.Enabled = [bool]($p -and $p.State -in 'Stopped', 'Running')
            # A scan that can't be continued says why, and what to do instead.
            $pastNote.Text = if ($p -and $p.RulesNote) { $p.RulesNote } else { $pastHint }
            $carryOn.Text = if ($p -and $p.State -eq 'Running') { 'Show progress' } else { 'Continue scan' }
            $openFolder.Enabled = [bool]$p
            $removeScans.Enabled = @(& $removable).Count -gt 0
        }.GetNewClosure())
    $removeScans.Add_Click({
            $rows = @(& $removable)
            if (-not $rows.Count) { return }
            $what = if ($rows.Count -eq 1) { "the scan started $($rows[0].Text)" } else { "these $($rows.Count) scans" }
            $answer = [System.Windows.Forms.MessageBox]::Show($form, "Remove $what, with its report and spreadsheets? They go to the Recycle Bin, so you can get them back from there.",
                'Remove past scans', 'YesNo', 'Question', 'Button2')
            if ($answer -ne 'Yes') { return }
            foreach ($row in $rows) {
                try {
                    if (Remove-CrScan $row.Tag.Folder) {
                        $pastList.Items.Remove($row)
                        if ($resumeBox -and $Unfinished -and $row.Tag.Folder -eq $Unfinished.Folder) { $resumeBox.Visible = $false }
                    }
                }
                catch { [void][System.Windows.Forms.MessageBox]::Show($form, "Couldn't remove the scan started $($row.Text): $($_.Exception.Message)", 'Remove past scans', 'OK', 'Warning') }
            }
            $pastPage.Text = "Past scans ($($pastList.Items.Count))"
            if (-not $pastList.Items.Count) { $pastNote.Text = 'No scans of this tenant on this PC yet.' }
        }.GetNewClosure())
    $openReport.Add_Click({ $p = & $picked; if ($p.Report) { Start-Process $p.Report } }.GetNewClosure())
    $pastList.Add_DoubleClick({ $p = & $picked; if ($p.Report) { Start-Process $p.Report } }.GetNewClosure())
    $openFolder.Add_Click({ $p = & $picked; if ($p) { Start-Process explorer.exe -ArgumentList "`"$($p.Folder)`"" } }.GetNewClosure())
    $carryOn.Add_Click({
            $p = & $picked
            if ($p.State -notin 'Stopped', 'Running') { return }
            $form.Tag = [pscustomobject]@{ Action = 'Resume'; Level = $null; Include = $null; Sites = @(); Folder = $p.Folder }
            $form.Close()
        }.GetNewClosure())

    # Tenant: the sharing and Copilot settings, as cards a non-technical reader can take in at a glance:
    # a verdict in words, the setting, what it is now and what we recommend. Show more opens the rest:
    # why, where to find it, a picture of the screen, and buttons to the guide and the admin center.
    if ($TenantSettings) {
        # When the settings were read, and a button to read them again.
        $readRow = [System.Windows.Forms.FlowLayoutPanel]@{ AutoSize = $true; WrapContents = $false; Margin = [System.Windows.Forms.Padding]::new(0, 4, 0, 0) }
        $readAt = if ($TenantSettingsRead -and $TenantSettingsRead.ReadAt) { $TenantSettingsRead.ReadAt.ToLocalTime().ToString('MMMM d, yyyy, h:mm tt') }
        $readText = [System.Windows.Forms.Label]@{ Text = $(if ($readAt) { "Read from your tenant on $readAt." } else { 'Not read from your tenant yet.' }); AutoSize = $true; ForeColor = $muted; Margin = [System.Windows.Forms.Padding]::new(0, 7, 12, 0) }
        $refreshTenant = [System.Windows.Forms.Button]@{ Text = 'Refresh'; AutoSize = $true; Padding = [System.Windows.Forms.Padding]::new(8, 1, 8, 1) }
        Set-CrButtonStyle $refreshTenant
        $refreshTenant.Add_Click({ $form.Tag = [pscustomobject]@{ Action = 'RefreshTenant'; Level = $null; Include = $null; Sites = @(); Folder = $null; Group = $(if ($tenantTabs) { "$($tenantTabs.SelectedTab.Tag)" }) }; $form.Close() }.GetNewClosure())
        $tips.SetToolTip($refreshTenant, 'Read the settings from your tenant again. The window closes and opens again on this tab.')
        $readRow.Controls.AddRange(@($readText, $refreshTenant))
        $null = Add-Row $readRow -to $tenantLayout
        if ($TenantSettingsRead -and $TenantSettingsRead.Problem) {
            $null = Add-Row (New-Label "Couldn't read them again just now, so these are from the time above: $($TenantSettingsRead.Problem)" $font ([System.Drawing.Color]::FromArgb(191, 87, 0))) -to $tenantLayout
        }
    }
    if ($TenantSettings -is [string]) {
        $null = Add-Row (New-Label "Couldn't read this tenant's settings: $TenantSettings" $font $muted) -to $tenantLayout
    }
    elseif ($TenantSettings) {
        $cardName = [System.Drawing.Font]::new('Segoe UI Semibold', 12)
        $cardValue = [System.Drawing.Font]::new('Segoe UI Semibold', 11.5)
        $cardAdvice = [System.Drawing.Font]::new('Segoe UI', 10.5)
        $badgeFont = [System.Drawing.Font]::new('Segoe UI Semibold', 10.5)
        $codeFont = [System.Drawing.Font]::new('Consolas', 10)
        $codeBack = [System.Drawing.Color]::FromArgb(18, 18, 18)
        $codeColors = @{
            Comment  = [System.Drawing.Color]::FromArgb(106, 153, 85)
            Command  = [System.Drawing.Color]::FromArgb(220, 220, 170)
            Option   = [System.Drawing.Color]::FromArgb(156, 220, 254)
            Value    = [System.Drawing.Color]::FromArgb(206, 145, 120)
            Variable = [System.Drawing.Color]::FromArgb(86, 156, 214)
        }
        # PnP or SPO, one at a time. The choice holds for every card and while this run lasts, so it's only made once.
        $toolChoice = @{ Tool = Get-CrCommandTool }
        $toolCards = [System.Collections.Generic.List[scriptblock]]::new()
        $ink = [System.Drawing.Color]::FromArgb(32, 36, 42)
        $looks = @{
            Watch = @{ Word = 'Change this'; Badge = [System.Drawing.Color]::FromArgb(191, 87, 0); Back = [System.Drawing.Color]::FromArgb(255, 244, 229); Edge = [System.Drawing.Color]::FromArgb(255, 204, 128) }
            Good  = @{ Word = 'Good'; Badge = [System.Drawing.Color]::FromArgb(22, 128, 56); Back = [System.Drawing.Color]::FromArgb(236, 250, 240); Edge = [System.Drawing.Color]::FromArgb(160, 220, 180) }
            Info  = @{ Word = 'Just so you know'; Badge = [System.Drawing.Color]::FromArgb(90, 100, 112); Back = [System.Drawing.Color]::FromArgb(243, 245, 248); Edge = [System.Drawing.Color]::FromArgb(205, 210, 218) }
        }
        $glyphs = @{}
        $glyphOf = {
            param([char] $glyph, [System.Drawing.Color] $color)
            # Drawn once per icon and shared; every card has the same few buttons.
            $key = "$([int]$glyph)-$($color.ToArgb())"
            if (-not $glyphs.ContainsKey($key)) { $glyphs[$key] = New-CrGlyph $glyph 18 $color }
            $glyphs[$key]
        }.GetNewClosure()
        $iconButton = {
            param([string] $text, [char] $glyph)
            $b = [System.Windows.Forms.Button]@{
                Text = $text; Font = $cardAdvice; AutoSize = $true; FlatStyle = 'Flat'; TextImageRelation = 'ImageBeforeText'; ImageAlign = 'MiddleLeft'
                Cursor = [System.Windows.Forms.Cursors]::Hand; BackColor = [System.Drawing.Color]::White; ForeColor = $ink
                Padding = [System.Windows.Forms.Padding]::new(6, 3, 8, 3); Margin = [System.Windows.Forms.Padding]::new(0, 0, 10, 6)
            }
            $b.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(200, 205, 212)
            $b.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(240, 243, 246)
            $b.Image = & $glyphOf $glyph $ink
            $b
        }.GetNewClosure()
        # A wrapping label for inside a card, at the width the cards are now.
        $restLabel = {
            param([string] $text, $color)
            $l = & $makeLabel $text $cardAdvice $color $tenantWidth.Rest
            $l.Tag = 'rest'
            $l
        }.GetNewClosure()

        # The headline: how many settings should change, in one plain sentence.
        $all = @($TenantSettings | ForEach-Object Rows)
        $toChange = @($all | Where-Object State -EQ 'Watch').Count
        $headline = if ($toChange -eq 0) { 'Your sharing and Copilot settings look good.' }
        elseif ($toChange -eq 1) { '1 setting is worth changing.' }
        else { "$toChange settings are worth changing." }
        $headlineColor = if ($toChange) { $looks.Watch.Badge } else { $looks.Good.Badge }
        $h = New-Label $headline $title $headlineColor
        $h.Margin = [System.Windows.Forms.Padding]::new(0, 8, 0, 2)
        $null = Add-Row $h -to $tenantLayout
        $null = Add-Row (New-Label ('These are how your SharePoint admin center is set up. They don''t change the score, ' +
                'but they decide how easily files get shared too widely, so changing the orange ones means fewer problems in the next scan. ' +
                'Press Show more on a card for why, where to find the setting and a picture of the screen.') $cardAdvice $muted) -to $tenantLayout

        $thumbs = @{}
        # The window is built again after Refresh and after a scan, so what it draws with goes when it does.
        $form.Add_Disposed({
                foreach ($made in @($cardName, $cardValue, $cardAdvice, $badgeFont, $codeFont) + @($glyphs.Values) + @($thumbs.Values) | Where-Object { $_ }) { $made.Dispose() }
            }.GetNewClosure())
        $chevronDown = & $glyphOf ([char]0xE70D) $ink
        $chevronUp = & $glyphOf ([char]0xE70E) $ink
        # The screen a card shows, scaled once when it's first opened and shared by every card that shows it:
        # painting a full-size image each time is slow, and most cards are never opened.
        $thumbOf = {
            param($file)
            if (-not $thumbs.ContainsKey($file)) {
                $full = [System.Drawing.Image]::FromFile($file)
                $thumb = [System.Drawing.Bitmap]::new(360, [int](360 * $full.Height / $full.Width))
                $g = [System.Drawing.Graphics]::FromImage($thumb)
                $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                $g.DrawImage($full, 0, 0, $thumb.Width, $thumb.Height)
                $g.Dispose(); $full.Dispose()
                $thumbs[$file] = $thumb
            }
            $thumbs[$file]
        }.GetNewClosure()
        # Lets a card grow or shrink to fit a change, then keeps its new size. If the change fails, the group still carries on.
        $refitCard = {
            param($card, $groupLayout, [scriptblock] $change, $with)
            $groupLayout.SuspendLayout()
            try { $card.AutoSize = $true; & $change $with }
            finally {
                $groupLayout.ResumeLayout($true)
                $size = $card.Size
                $card.AutoSize = $false
                $card.Size = $size
            }
        }.GetNewClosure()
        # What a card shows behind Show more, made the first time it's pressed: most cards are never opened, and
        # making and measuring all of it for every card is what made this tab slow. This runs long after the
        # window was built, so what the buttons it adds need comes in ui, which they keep hold of.
        $fillCard = {
            param($ui, $r, $details, $card, $groupLayout, $groupEntry)
            if ($r.Advice) {
                $advice = & $restLabel $r.Advice $ink
                $advice.Margin = [System.Windows.Forms.Padding]::new(0, 4, 0, 0)
                $details.Controls.Add($advice)
            }
            if ($r.Where) {
                $where = & $restLabel "Where to find it: $($r.Where)" $muted
                $where.Margin = [System.Windows.Forms.Padding]::new(0, 8, 0, 0)
                $details.Controls.Add($where)
            }
            # A picture that can't be read is left out; the rest of the card still shows.
            $image = if ($r.Picture -and (Test-Path -LiteralPath $r.Picture)) { try { & $thumbOf $r.Picture } catch { $null } }
            if ($image) {
                $picture = [System.Windows.Forms.PictureBox]@{ Image = $image; Size = $image.Size; SizeMode = 'Normal'; BackColor = [System.Drawing.Color]::White; BorderStyle = 'FixedSingle'; Cursor = [System.Windows.Forms.Cursors]::Hand; Margin = [System.Windows.Forms.Padding]::new(0, 8, 0, 0) }
                $pictureFile = $r.Picture
                $picture.Add_Click({ Start-Process $pictureFile }.GetNewClosure())
                $details.Controls.Add($picture)
            }
            $buttons = @()
            if ($image) { $buttons += [pscustomobject]@{ Text = 'Show me'; Url = $r.Picture; Icon = [char]0xE91B } }
            $buttons += @($r.Links)
            $commands = @($r.Commands)
            if ($buttons.Count -or $commands.Count) {
                $buttonRow = [System.Windows.Forms.FlowLayoutPanel]@{ AutoSize = $true; FlowDirection = 'LeftToRight'; WrapContents = $true; Margin = [System.Windows.Forms.Padding]::new(0, 10, 0, 0) }
                foreach ($l in $buttons) {
                    $url = $l.Url
                    $button = & $iconButton $l.Text $l.Icon
                    $button.Add_Click({ Start-Process $url }.GetNewClosure())
                    $buttonRow.Controls.Add($button)
                }
                $details.Controls.Add($buttonRow)
            }
            if ($commands.Count) {
                # The commands to change the setting, folded away behind their own button: PnP or SPO, one at a time.
                $powerShell = & $iconButton 'PowerShell' ([char]0xE70D)
                $powerShell.TextImageRelation = 'TextBeforeImage'
                $buttonRow.Controls.Add($powerShell)

                $codePanel = [System.Windows.Forms.FlowLayoutPanel]@{ AutoSize = $true; FlowDirection = 'TopDown'; WrapContents = $false; Visible = $false; Margin = [System.Windows.Forms.Padding]::new(0, 4, 0, 0) }
                $toolRow = [System.Windows.Forms.FlowLayoutPanel]@{ AutoSize = $true; WrapContents = $false; Margin = [System.Windows.Forms.Padding]::new(0) }
                $radios = @{}
                foreach ($name in 'PnP', 'SPO') {
                    $radios[$name] = [System.Windows.Forms.RadioButton]@{ Text = $name; Font = $cardAdvice; AutoSize = $true; Checked = $name -eq $ui.ToolChoice.Tool; Margin = [System.Windows.Forms.Padding]::new(0, 0, 18, 0) }
                    $toolRow.Controls.Add($radios[$name])
                }
                $codePanel.Controls.Add($toolRow)
                $caption = & $restLabel ' ' $muted
                $caption.Margin = [System.Windows.Forms.Padding]::new(0, 6, 0, 0)
                $codePanel.Controls.Add($caption)
                $lineCount = (@($commands | ForEach-Object { @($_.Text -split "`r`n").Count }) | Measure-Object -Maximum).Maximum
                $codeFrame = [System.Windows.Forms.Panel]@{
                    BackColor = $codeBack; Width = $tenantWidth.Rest; Padding = [System.Windows.Forms.Padding]::new(12, 10, 12, 4); Margin = [System.Windows.Forms.Padding]::new(0, 6, 0, 6)
                    Height = $lineCount * $codeFont.Height + 22 + [System.Windows.Forms.SystemInformation]::HorizontalScrollBarHeight
                }
                $codeView = [System.Windows.Forms.RichTextBox]@{ Dock = 'Fill'; ReadOnly = $true; BorderStyle = 'None'; BackColor = $codeBack; ForeColor = [System.Drawing.Color]::FromArgb(212, 212, 212); Font = $codeFont; WordWrap = $false; ScrollBars = 'Horizontal'; DetectUrls = $false; TabStop = $false }
                $codeFrame.Controls.Add($codeView)
                $groupEntry.Codes.Add($codeFrame)
                $codePanel.Controls.Add($codeFrame)
                $actions = [System.Windows.Forms.FlowLayoutPanel]@{ AutoSize = $true; WrapContents = $false; Margin = [System.Windows.Forms.Padding]::new(0) }
                $copy = & $iconButton 'Copy' ([char]0xE8C8)
                $actions.Controls.Add($copy)
                $helpLink = @($commands | ForEach-Object Help | Where-Object { $_ }) | Select-Object -First 1
                $help = $null
                if ($helpLink) {
                    $helpUrl = $helpLink.Url
                    $help = & $iconButton $helpLink.Text $helpLink.Icon
                    $help.Add_Click({ Start-Process $helpUrl }.GetNewClosure())
                    $actions.Controls.Add($help)
                }
                $codePanel.Controls.Add($actions)
                $details.Controls.Add($codePanel)

                $codeState = @{ Open = $false; Showing = $null; Text = '' }
                # Says what happened for a moment, then goes back, so it can't be read later as being about something else.
                $copyPause = [System.Windows.Forms.Timer]@{ Interval = 2500 }
                $copyPause.Add_Tick({ $copyPause.Stop(); if (-not $copy.IsDisposed) { $copy.Text = 'Copy' } }.GetNewClosure())
                $copy.Add_Disposed({ $copyPause.Stop(); $copyPause.Dispose() }.GetNewClosure())
                $copy.Add_Click({
                        try { [System.Windows.Forms.Clipboard]::SetText($codeState.Text); $copy.Text = 'Copied' } catch { $copy.Text = 'Couldn''t copy' }
                        $copyPause.Stop(); $copyPause.Start()
                    }.GetNewClosure())
                # Filled in only once it's opened, so opening the window stays quick.
                $showCode = {
                    if ($codeState.Showing -eq $ui.ToolChoice.Tool) { return }
                    $use = @($commands | Where-Object Tool -EQ $ui.ToolChoice.Tool)[0]
                    $codeState.Showing = $use.Tool
                    $codeState.Text = $use.Text
                    $caption.Text = $use.Caption
                    $copy.Text = 'Copy'
                    if ($help) { $help.Visible = [bool]$use.Help }
                    Set-CrCodeView -View $codeView -Text $use.Text -Colors $ui.CodeColors
                }.GetNewClosure()
                $togglePowerShell = {
                    $codeState.Open = -not $codeState.Open
                    $codePanel.Visible = $codeState.Open
                    if ($codeState.Open) { & $showCode }
                    $powerShell.Image = if ($codeState.Open) { $ui.ChevronUp } else { $ui.ChevronDown }
                }.GetNewClosure()
                $powerShell.Add_Click({ & $ui.RefitCard $card $groupLayout $togglePowerShell }.GetNewClosure())
                # When the choice changes on any card, this one follows it.
                $ui.ToolCards.Add({
                        $radios[$ui.ToolChoice.Tool].Checked = $true
                        if ($codeState.Open) { & $ui.RefitCard $card $groupLayout $showCode }
                    }.GetNewClosure())
                foreach ($name in 'PnP', 'SPO') {
                    $radio = $radios[$name]
                    $radio.Add_CheckedChanged({
                            if (-not $radio.Checked -or $ui.ToolChoice.Tool -eq $name) { return }
                            $ui.ToolChoice.Tool = $name
                            Set-CrCommandTool $name
                            foreach ($follow in $ui.ToolCards) { & $follow }
                        }.GetNewClosure())
                }
            }
        }.GetNewClosure()
        $ui = @{ ToolChoice = $toolChoice; ToolCards = $toolCards; CodeColors = $codeColors; ChevronUp = $chevronUp; ChevronDown = $chevronDown; RefitCard = $refitCard }
        # One Show more for every card, and one border: each card made its own, and a window's worth of them made it slow to open.
        $toggleMore = {
            param($c)
            # Made here the first time. If that fails, it says why, takes back what it added, and tries again next time.
            if (-not $c.Details.Visible -and -not $c.Filled) {
                if ($c.Problem) { [void]$wrapped.Remove($c.Problem); $c.Problem.Dispose(); $c.Problem = $null }
                $labels = $wrapped.Count; $codes = $c.GroupEntry.Codes.Count; $followers = $toolCards.Count
                try { & $fillCard $ui $c.Row $c.Details $c.Card $c.GroupLayout $c.GroupEntry; $c.Filled = $true }
                catch {
                    $why = $_.Exception.Message
                    foreach ($made in @($c.Details.Controls)) { $made.Dispose() }
                    $wrapped.RemoveRange($labels, $wrapped.Count - $labels)
                    $c.GroupEntry.Codes.RemoveRange($codes, $c.GroupEntry.Codes.Count - $codes)
                    $toolCards.RemoveRange($followers, $toolCards.Count - $followers)
                    $c.Problem = & $restLabel "Couldn't show this just now: $why Press Show less, then Show more to try again." $muted
                    $c.Details.Controls.Add($c.Problem)
                }
            }
            $c.Details.Visible = -not $c.Details.Visible
            $c.More.Text = if ($c.Details.Visible) { 'Show less' } else { 'Show more' }
            $c.More.Image = if ($c.Details.Visible) { $chevronUp } else { $chevronDown }
        }.GetNewClosure()
        $onMore = { param($sender) & $refitCard $sender.Tag.Card $sender.Tag.GroupLayout $toggleMore $sender.Tag }.GetNewClosure()
        $paintEdge = {
            param($sender, $e)
            $pen = [System.Drawing.Pen]::new($sender.Tag, 1)
            $e.Graphics.DrawRectangle($pen, 0, 0, $sender.Width - 1, $sender.Height - 1)
            $pen.Dispose()
        }
        $tenantLayout.SuspendLayout()
        $null = Add-Row $tenantTabs 'Fill' -to $tenantLayout
        $openOn = $null
        $backOn = $null
        foreach ($group in $TenantSettings) {
            if (-not @($group.Rows).Count) { continue }
            # Each group's tab says how many of its settings are worth changing, and scrolls on its own.
            $groupChange = @($group.Rows | Where-Object State -EQ 'Watch').Count
            $groupPage, $groupLayout = New-Page $(if ($groupChange) { "$($group.Name): $groupChange to change" } else { $group.Name })
            $groupPage.Tag = $group.Name
            $groupLayout.Dock = 'Top'; $groupLayout.AutoSize = $true
            $groupLayout.SuspendLayout()
            $tenantTabs.TabPages.Add($groupPage)
            $groupEntry = @{ Layout = $groupLayout; Cards = [System.Collections.Generic.List[object]]::new(); Codes = [System.Collections.Generic.List[object]]::new() }
            $tenantGroups[$groupPage] = $groupEntry
            if ($group.Name -eq $StartGroup) { $backOn = $groupPage }
            if ($groupChange -and -not $openOn) { $openOn = $groupPage }
            # What needs changing comes first, so it isn't missed.
            $rows = @($group.Rows | Where-Object State -EQ 'Watch') + @($group.Rows | Where-Object State -EQ 'Good') + @($group.Rows | Where-Object State -EQ 'Info')
            foreach ($r in $rows) {
                $look = $looks[$r.State]
                $card = [System.Windows.Forms.TableLayoutPanel]@{ AutoSize = $true; Dock = 'Top'; ColumnCount = 2; BackColor = $look.Back; Padding = [System.Windows.Forms.Padding]::new(14, 12, 14, 12); Margin = [System.Windows.Forms.Padding]::new(0, 0, 0, 8) }
                $null = $card.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new('Absolute', 150))
                $null = $card.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new('Percent', 100))
                $null = $card.RowStyles.Add([System.Windows.Forms.RowStyle]::new('AutoSize'))
                $card.Tag = $look.Edge
                $card.Add_Paint($paintEdge)

                $badge = [System.Windows.Forms.Label]@{ Text = $look.Word; Font = $badgeFont; ForeColor = [System.Drawing.Color]::White; BackColor = $look.Badge; AutoSize = $false; Size = [System.Drawing.Size]::new(130, 32); TextAlign = 'MiddleCenter'; Margin = [System.Windows.Forms.Padding]::new(0, 2, 0, 0) }
                $what = [System.Windows.Forms.FlowLayoutPanel]@{ AutoSize = $true; FlowDirection = 'TopDown'; WrapContents = $false; Dock = 'Fill'; Margin = [System.Windows.Forms.Padding]::new(0) }
                $name = New-Label $r.Name $cardName $ink
                $name.Tag = 'rest'
                $name.Margin = [System.Windows.Forms.Padding]::new(0, 2, 0, 6)
                $what.Controls.Add($name)

                # Now and Recommended, side by side so the difference is plain.
                $facts = [System.Windows.Forms.TableLayoutPanel]@{ AutoSize = $true; ColumnCount = 2; Margin = [System.Windows.Forms.Padding]::new(0) }
                $null = $facts.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new('Absolute', 130))
                $null = $facts.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new('AutoSize'))
                $recommendedColor = if ($r.State -eq 'Watch') { $looks.Watch.Badge } elseif ($r.State -eq 'Good') { $looks.Good.Badge } else { $ink }
                foreach ($fact in @(@('Now', $r.Value, $ink), @('Recommended', $r.Recommended, $recommendedColor))) {
                    if (-not $fact[1]) { continue }
                    $null = $facts.RowStyles.Add([System.Windows.Forms.RowStyle]::new('AutoSize'))
                    $key = [System.Windows.Forms.Label]@{ Text = $fact[0]; Font = $cardAdvice; ForeColor = $muted; AutoSize = $true; Margin = [System.Windows.Forms.Padding]::new(0, 3, 0, 3) }
                    $val = New-Label $fact[1] $cardValue $fact[2]
                    $val.Tag = 'narrow'
                    $val.Margin = [System.Windows.Forms.Padding]::new(0, 2, 0, 2)
                    $facts.Controls.Add($key)
                    $facts.Controls.Add($val)
                }
                $what.Controls.Add($facts)

                # The rest is folded away behind Show more, so the list stays short and quick to draw.
                $details = [System.Windows.Forms.FlowLayoutPanel]@{ AutoSize = $true; FlowDirection = 'TopDown'; WrapContents = $false; Visible = $false; Margin = [System.Windows.Forms.Padding]::new(0, 4, 0, 0) }

                $more = & $iconButton 'Show more' ([char]0xE70D)
                $more.Margin = [System.Windows.Forms.Padding]::new(0, 6, 0, 0)
                $more.Tag = @{ Row = $r; Details = $details; Card = $card; GroupLayout = $groupLayout; GroupEntry = $groupEntry; More = $more; Filled = $false }
                $more.Add_Click($onMore)
                $what.Controls.Add($more)
                $what.Controls.Add($details)

                $card.Controls.Add($badge, 0, 0)
                $card.Controls.Add($what, 1, 0)
                $null = Add-Row $card -to $groupLayout
                $groupEntry.Cards.Add($card)
            }
            $groupLayout.ResumeLayout($false)
        }
        # Always one chosen: a tab control not yet on screen has none, and then nothing would be measured ahead of time.
        if ($backOn) { $tenantTabs.SelectedTab = $backOn } elseif ($openOn) { $tenantTabs.SelectedTab = $openOn } elseif ($tenantTabs.TabPages.Count) { $tenantTabs.SelectedIndex = 0 }
        $tenantLayout.ResumeLayout()
    }

    # Settings: what this needs and what this PC has, the sign-in app, where results go, and who to ask.
    if ($About) {
        function New-Facts([string] $heading, [object[]] $rows) {
            $box = [System.Windows.Forms.GroupBox]@{ Text = $heading; AutoSize = $true; Dock = 'Top'; Padding = [System.Windows.Forms.Padding]::new(12, 8, 12, 8); Margin = [System.Windows.Forms.Padding]::new(0, 4, 0, 8) }
            $grid = [System.Windows.Forms.TableLayoutPanel]@{ AutoSize = $true; Dock = 'Fill'; ColumnCount = 2 }
            $null = $grid.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new('AutoSize'))
            $null = $grid.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new('Percent', 100))
            foreach ($r in $rows) {
                $null = $grid.RowStyles.Add([System.Windows.Forms.RowStyle]::new('AutoSize'))
                $key = [System.Windows.Forms.Label]@{ Text = $r[0]; AutoSize = $true; ForeColor = $muted; Margin = [System.Windows.Forms.Padding]::new(0, 4, 24, 4) }
                $value = if ($r[1] -is [System.Windows.Forms.Control]) { $r[1] } else { [System.Windows.Forms.Label]@{ Text = "$($r[1])"; AutoSize = $true; Margin = [System.Windows.Forms.Padding]::new(0, 4, 0, 4) } }
                $grid.Controls.AddRange(@($key, $value))
            }
            $box.Controls.Add($grid)
            $box
        }
        # A value with a small button beside it, such as Copy or Open.
        function New-ValueWithButton([string] $text, [string] $buttonText, [scriptblock] $onClick) {
            $row = [System.Windows.Forms.FlowLayoutPanel]@{ AutoSize = $true; WrapContents = $false; Margin = [System.Windows.Forms.Padding]::new(0) }
            $label = [System.Windows.Forms.Label]@{ Text = $text; AutoSize = $true; Margin = [System.Windows.Forms.Padding]::new(0, 7, 10, 0) }
            $button = [System.Windows.Forms.Button]@{ Text = $buttonText; AutoSize = $true; Padding = [System.Windows.Forms.Padding]::new(6, 0, 6, 0); Margin = [System.Windows.Forms.Padding]::new(0, 2, 0, 2) }
            Set-CrButtonStyle $button
            $button.Add_Click($onClick)
            $row.Controls.AddRange(@($label, $button))
            $row
        }

        $support = [System.Windows.Forms.LinkLabel]@{ Text = $About.Support; AutoSize = $true; Margin = [System.Windows.Forms.Padding]::new(0, 4, 0, 4) }
        $support.Add_LinkClicked({ Start-Process $About.SupportUrl }.GetNewClosure())
        $null = Add-Row (New-Facts 'About' @(
                , @('App', $About.Name)
                , @('Built by', $About.BuiltBy)
                , @('Support', $support)
                , @('Rule book', "Version $($About.RuleBook)")
            )) -to $settingsLayout

        # What this needs, with a check mark or a cross for what this PC has.
        $needs = [System.Windows.Forms.ListView]@{ View = 'Details'; FullRowSelect = $true; HeaderStyle = 'Nonclickable'; Dock = 'Fill'; Height = 130; Margin = [System.Windows.Forms.Padding]::new(0) }
        foreach ($c in @(@('', 30), @('Needs', 150), @('Version needed', 230), @('This PC has', 170))) { $null = $needs.Columns.Add($c[0], $c[1]) }
        foreach ($r in $About.Requirements) {
            $row = [System.Windows.Forms.ListViewItem]::new($(if ($r.Ok) { [string][char]0x2713 } else { [string][char]0x2717 }))
            $row.UseItemStyleForSubItems = $false
            $row.ForeColor = if ($r.Ok) { [System.Drawing.Color]::FromArgb(26, 127, 55) } else { [System.Drawing.Color]::FromArgb(198, 40, 40) }
            foreach ($text in $r.Name, $r.Needs, $r.Has) { $null = $row.SubItems.Add($text) }
            $null = $needs.Items.Add($row)
        }
        $needsBox = [System.Windows.Forms.GroupBox]@{ Text = 'What this needs'; Dock = 'Top'; Height = 170; Padding = [System.Windows.Forms.Padding]::new(12, 8, 12, 8); Margin = [System.Windows.Forms.Padding]::new(0, 4, 0, 8) }
        $needsBox.Controls.Add($needs)
        $null = Add-Row $needsBox -to $settingsLayout

        $appId = if ($About.AppId) { New-ValueWithButton $About.AppId 'Copy' ({ [System.Windows.Forms.Clipboard]::SetText($About.AppId) }.GetNewClosure()) } else { 'Not set up yet' }
        $null = Add-Row (New-Facts 'Sign-in app' @(
                , @('Name', $About.AppName)
                , @('App (client) ID', $appId)
                , @('Certificate thumbprint', $(if ($About.Thumbprint) { $About.Thumbprint } else { 'None' }))
                , @('Certificate expires', $(if ($About.CertExpires) { $About.CertExpires.ToString('MMM d, yyyy') } else { 'Not on this PC' }))
                , @('Tenant', $About.Tenant)
                , @('SharePoint', $About.SharePoint)
            )) -to $settingsLayout

        # Removing Copilot Readiness from the tenant, and this PC's certificate for it.
        if ($About.AppId) {
            $removeBox = [System.Windows.Forms.GroupBox]@{ Text = 'Remove from this tenant'; AutoSize = $true; Dock = 'Top'; Padding = [System.Windows.Forms.Padding]::new(12, 8, 12, 8); Margin = [System.Windows.Forms.Padding]::new(0, 4, 0, 8) }
            $removeStack = [System.Windows.Forms.FlowLayoutPanel]@{ Dock = 'Fill'; AutoSize = $true; FlowDirection = 'TopDown'; WrapContents = $false }
            $removeNote = New-Label ("Deletes the app from $($About.Tenant) and its certificate from this computer. Everyone using it, on any computer, " +
                'loses access straight away and would have to set it up again. Past scans on this computer are kept.') $font $muted
            $removeButton = [System.Windows.Forms.Button]@{ Text = 'Remove Copilot Readiness from this tenant'; AutoSize = $true; Padding = [System.Windows.Forms.Padding]::new(10, 3, 10, 3); Margin = [System.Windows.Forms.Padding]::new(0, 6, 0, 0) }
            Set-CrButtonStyle $removeButton Danger
            $removeButton.Add_Click({
                    $answer = [System.Windows.Forms.MessageBox]::Show($form,
                        ("This removes Copilot Readiness from $($About.Tenant):`n`n" +
                        "  - the app ($($About.AppId)) is deleted from your tenant, and its permissions go with it`n" +
                        "  - this computer's certificate for it is deleted`n`n" +
                        "Anyone else using it, on any computer, loses access straight away. To use it again, someone has to set it up again from the start.`n`n" +
                        "A Global Administrator signs in to do this. Past scans on this computer are kept.`n`nRemove it?"),
                        'Remove Copilot Readiness', 'YesNo', 'Warning', 'Button2')
                    if ($answer -ne 'Yes') { return }
                    $form.Tag = [pscustomobject]@{ Action = 'Uninstall'; Level = $null; Include = $null; Sites = @(); Folder = $null }
                    $form.Close()
                }.GetNewClosure())
            $removeStack.Controls.AddRange(@($removeNote, $removeButton))
            $removeBox.Controls.Add($removeStack)
            $null = Add-Row $removeBox -to $settingsLayout
        }

        $results = New-ValueWithButton $About.Results 'Open' ({ Start-Process explorer.exe -ArgumentList "`"$($About.Results)`"" }.GetNewClosure())
        $null = Add-Row (New-Facts 'Results' @(, @('Saved in', $results))) -to $settingsLayout
    }

    # Start scan belongs to the New scan tab.
    $tabs.Add_SelectedIndexChanged({
            $onNew = $tabs.SelectedTab -eq $newPage
            $start.Visible = $onNew
            $cancel.Text = if ($onNew) { 'Cancel' } else { 'Close' }
            $form.AcceptButton = if ($onNew) { $start } else { $null }
        }.GetNewClosure())

    $selectedLevel = { ($levelRadios.Values | Where-Object Checked | Select-Object -First 1).Tag }.GetNewClosure()
    $selectedPace = { Get-CrPace ($paceRadios.Values | Where-Object Checked | Select-Object -First 1).Tag }.GetNewClosure()

    # The left side's height changes with the notes shown; on a small screen the New scan tab scrolls rather than cutting it off.
    $fit = {
        $newLayout.PerformLayout()
        $needed = 12
        foreach ($c in $kindBox, $levelBox, $paceBox, $estimate) { $needed += $c.Height + $c.Margin.Vertical }
        $newPage.AutoScrollMinSize = [System.Drawing.Size]::new(0, [Math]::Max(360, $needed))
    }.GetNewClosure()
    $selectedSites = {
        @($Sites | Where-Object { (& $included $_) -and ($allRadio.Checked -or $chosen.Contains($_.url)) })
    }.GetNewClosure()
    $refresh = {
        $picked = @(& $selectedSites)
        $od = @($picked | Where-Object kind -EQ 'OneDrive').Count
        $pace = & $selectedPace
        $estimate.Text = Get-CrEstimate -Level (& $selectedLevel) -SiteCount ($picked.Count - $od) -OneDriveCount $od -Parallel $pace.Sites
        $paceNote.Text = "$($pace.Description) Microsoft recommends running big scans at night or on weekends."
        $start.Enabled = $picked.Count -gt 0
        $inc = & $selectedInclude
        # The OneDrive note only matters when OneDrive is being scanned.
        $kindNote.Visible = $inc -ne 'SharePoint'
        $levelBox.Enabled = $inc -ne 'OneDrive'
        $allRadio.Text = switch ($inc) {
            'SharePoint' { 'All {0:N0} SharePoint sites' -f $spCount }
            'OneDrive' { 'All {0:N0} OneDrives' -f $odCount }
            default { 'All {0:N0} SharePoint sites and {1:N0} OneDrives' -f $spCount, $odCount }
        }
        if ($form.Visible) { & $fit }
    }.GetNewClosure()

    foreach ($r in $levelRadios.Values) { $r.Add_CheckedChanged($refresh) }
    foreach ($r in $paceRadios.Values) { $r.Add_CheckedChanged($refresh) }
    foreach ($r in $kindRadios.Values) { $r.Add_CheckedChanged({ if ($list.Enabled) { & $fill }; & $refresh }.GetNewClosure()) }
    $allRadio.Add_CheckedChanged({
            $some = -not $allRadio.Checked
            $filter.Enabled = $some; $list.Enabled = $some; $tickShown.Enabled = $some; $clearAll.Enabled = $some
            if ($some -and $list.Items.Count -eq 0) { & $fill }
            & $refresh
        }.GetNewClosure())
    $filter.Add_TextChanged({ & $fill }.GetNewClosure())
    $list.Add_ItemCheck({
            param($sender, $e)
            if ($state.Filling) { return }
            $url = $shown[$e.Index]
            if ($e.NewValue -eq 'Checked') { [void]$chosen.Add($url) } else { [void]$chosen.Remove($url) }
            # ItemCheck fires before the tick changes, so count after it has.
            $form.BeginInvoke([Action]{ & $refresh }) | Out-Null
        }.GetNewClosure())
    $tickShown.Add_LinkClicked({ foreach ($url in $shown) { [void]$chosen.Add($url) }; & $fill; & $refresh }.GetNewClosure())
    $clearAll.Add_LinkClicked({ $chosen.Clear(); & $fill; & $refresh }.GetNewClosure())
    $start.Add_Click({
            $form.Tag = [pscustomobject]@{ Action = 'New'; Level = (& $selectedLevel); Include = (& $selectedInclude); Sites = @(& $selectedSites); Pace = (& $selectedPace).Id; Folder = $null }
            $form.Close()
        }.GetNewClosure())

    # Sites saved in the settings start the window on "only these", already checked.
    if (@($Sites | Where-Object { $chosen.Contains($_.url) }).Count) { $someRadio.Checked = $true }

    # Most of the screen, so the site list has room; the wrapping text follows the width.
    # Opens full screen; restoring it gives most of the screen.
    $form.Add_Load({ Set-CrScreenShare $form -Width 0.6 -Height 0.88; $form.WindowState = 'Maximized' }.GetNewClosure())
    if ($StartTab) {
        $open = $tabs.TabPages | Where-Object { $_.Text -like "$StartTab*" } | Select-Object -First 1
        if ($open) { $tabs.SelectedTab = $open }
    }
    # The wrapped labels are re-measured to the new width, but only those on the tab that is showing, and only
    # when a resize ends, the window is maximized or restored, or the tab changes. Re-measuring every label on
    # every tab for every pixel of a drag re-laid out every card on the Tenant tab each time and froze the window.
    $pageOf = [System.Collections.Generic.Dictionary[object, object]]::new()
    $reflowed = @{}
    $reflow = {
        param($page)
        if (-not $page) { $page = $tabs.SelectedTab }
        $widths = @{
            default = [Math]::Max(300, $layout.ClientSize.Width - $layout.Padding.Horizontal - 80)
            half    = [Math]::Max(200, [int]($tabs.ClientSize.Width / 2) - 70)
            rest    = [Math]::Max(200, $tabs.ClientSize.Width - 280)
        }
        $widths.narrow = [Math]::Max(200, $widths.rest - 140)
        $tenantWidth.Rest = $widths.rest
        # Compared by the widths the text wraps to, not the window's: the panels inside can settle at a new
        # width while the window's stays put (as when it first appears), and the text must follow them.
        # On the Tenant tab, that's only the group on screen.
        $groupPage = if ($tenantTabs -and $page -eq $tenantPage) { $tenantTabs.SelectedTab }
        $group = if ($groupPage) { $tenantGroups[$groupPage] }
        # Only the last widths each place was measured at count: going back to an earlier width has to measure it again.
        $place = "$($page.Text)|$($groupPage.Text)"
        $key = "$($widths.default)|$($widths.half)|$($widths.rest)"
        if ($reflowed[$place] -eq $key) { return }
        $reflowed[$place] = $key
        $todo = foreach ($l in $wrapped) {
            if (-not $pageOf.ContainsKey($l)) {
                $p = $l.Parent
                while ($p -and $p -isnot [System.Windows.Forms.TabPage]) { $p = $p.Parent }
                $pageOf[$l] = $p
            }
            if (-not $pageOf[$l] -or $pageOf[$l] -eq $page -or ($groupPage -and $pageOf[$l] -eq $groupPage)) { $l }
        }
        $holders = [System.Collections.Generic.HashSet[object]]::new()
        foreach ($l in $todo) { if ($l.Parent) { $null = $holders.Add($l.Parent) } }
        # A group's cards are measured again at the new width, all at once, then keep their size.
        if ($group) { $group.Layout.SuspendLayout(); foreach ($c in $group.Cards) { $c.SuspendLayout(); $c.AutoSize = $true } }
        foreach ($h in $holders) { $h.SuspendLayout() }
        foreach ($l in $todo) {
            $w = switch ($l.Tag) { 'half' { $widths.half } 'rest' { $widths.rest } 'narrow' { $widths.narrow } default { $widths.default } }
            $l.MaximumSize = [System.Drawing.Size]::new($w, 0)
        }
        foreach ($h in $holders) { $h.ResumeLayout($true) }
        if ($group) {
            foreach ($b in $group.Codes) { $b.Width = $widths.rest }
            foreach ($c in $group.Cards) { $c.ResumeLayout($false) }
            $group.Layout.ResumeLayout($true)
            # All at once: one card at a time makes the whole group lay itself out again for each.
            $group.Layout.SuspendLayout()
            foreach ($c in $group.Cards) { $size = $c.Size; $c.AutoSize = $false; $c.Size = $size }
            $group.Layout.ResumeLayout($true)
        }
        & $fit
    }.GetNewClosure()
    $windowState = @{ Last = $form.WindowState }
    $form.Add_Resize({
            if (-not $form.Visible -or $form.WindowState -ne $windowState.Last) { $windowState.Last = $form.WindowState; & $reflow }
        }.GetNewClosure())
    $form.Add_ResizeEnd({ & $reflow }.GetNewClosure())
    $tabs.Add_SelectedIndexChanged({ & $reflow }.GetNewClosure())
    if ($tenantTabs) { $tenantTabs.Add_SelectedIndexChanged({ & $reflow }.GetNewClosure()) }
    # The panels only settle at their final size once the window is on screen. The Tenant tab is
    # measured then too, whichever tab is showing, so opening it later is quick.
    $form.Add_Shown({ & $reflow; if ($tenantPage -and $tabs.SelectedTab -ne $tenantPage) { & $reflow $tenantPage } }.GetNewClosure())

    & $refresh
    $form
}

# PnP or SPO for the Tenant tab's commands. Kept here because the window is built again after Refresh and after a scan.
$script:CommandTool = 'PnP'
function Get-CrCommandTool { $script:CommandTool }
function Set-CrCommandTool { param([Parameter(Mandatory)] [ValidateSet('PnP', 'SPO')] [string] $Tool) $script:CommandTool = $Tool }

function Set-CrCodeView {
    <# Shows code in a box, coloured like a code editor. Colors gives each kind from Get-CrCodeSpans its colour. #>
    param([Parameter(Mandatory)] [System.Windows.Forms.RichTextBox] $View, [Parameter(Mandatory)] [string] $Text, [Parameter(Mandatory)] [hashtable] $Colors)
    $View.Text = $Text
    # Measured on the box's own copy: it keeps line ends differently, which moves everything after the first line.
    foreach ($span in Get-CrCodeSpans $View.Text) {
        $View.Select($span.Start, $span.Length)
        $View.SelectionColor = $Colors[$span.Kind]
    }
    $View.Select(0, 0)
}

function New-CrGlyph {
    <# A small picture of one Windows icon-font character (Segoe Fluent Icons or MDL2), or nothing if neither font is there. #>
    param([char] $Glyph, [int] $Size = 16, [System.Drawing.Color] $Color = [System.Drawing.Color]::FromArgb(60, 64, 72))
    $installed = [System.Drawing.Text.InstalledFontCollection]::new().Families.Name
    $family = @('Segoe Fluent Icons', 'Segoe MDL2 Assets') | Where-Object { $_ -in $installed } | Select-Object -First 1
    if (-not $family) { return $null }
    $iconFont = [System.Drawing.Font]::new($family, [single]($Size * 0.7), [System.Drawing.GraphicsUnit]::Pixel)
    $bitmap = [System.Drawing.Bitmap]::new($Size, $Size)
    $g = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $g.TextRenderingHint = 'AntiAliasGridFit'
        $format = [System.Drawing.StringFormat]@{ Alignment = 'Center'; LineAlignment = 'Center' }
        $brush = [System.Drawing.SolidBrush]::new($Color)
        $g.DrawString([string]$Glyph, $iconFont, $brush, [System.Drawing.RectangleF]::new(0, 0, $Size, $Size), $format)
        $brush.Dispose()
    }
    finally { $g.Dispose(); $iconFont.Dispose() }
    $bitmap
}

function New-CrLogo {
    <#
      The app's own mark: a rounded square in blue, violet and pink, lit teal at the bottom
      left and amber at the top right, with a white check mark.
    #>
    param([int] $Size = 64)
    $bitmap = [System.Drawing.Bitmap]::new($Size, $Size)
    $g = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $g.SmoothingMode = 'AntiAlias'
        $rect = [System.Drawing.RectangleF]::new(0, 0, $Size - 1, $Size - 1)
        $d = $Size * 0.44
        $square = [System.Drawing.Drawing2D.GraphicsPath]::new()
        $square.AddArc($rect.X, $rect.Y, $d, $d, 180, 90)
        $square.AddArc($rect.Right - $d, $rect.Y, $d, $d, 270, 90)
        $square.AddArc($rect.Right - $d, $rect.Bottom - $d, $d, $d, 0, 90)
        $square.AddArc($rect.X, $rect.Bottom - $d, $d, $d, 90, 90)
        $square.CloseFigure()

        $base = [System.Drawing.Drawing2D.LinearGradientBrush]::new($rect, [System.Drawing.Color]::Blue, [System.Drawing.Color]::Red, [single]45)
        $blend = [System.Drawing.Drawing2D.ColorBlend]::new(3)
        $blend.Colors = @([System.Drawing.Color]::FromArgb(24, 110, 243), [System.Drawing.Color]::FromArgb(122, 82, 238), [System.Drawing.Color]::FromArgb(232, 66, 150))
        $blend.Positions = @([single]0, [single]0.5, [single]1)
        $base.InterpolationColors = $blend
        $g.FillPath($base, $square)
        $base.Dispose()

        # Soft glows of teal and amber, kept inside the square.
        $g.SetClip($square)
        foreach ($glow in @(@(0.05, 0.95, 52, 211, 170), @(0.95, 0.05, 255, 183, 64))) {
            $r = $Size * 0.75
            $spot = [System.Drawing.Drawing2D.GraphicsPath]::new()
            $spot.AddEllipse([single]($glow[0] * $Size - $r), [single]($glow[1] * $Size - $r), [single](2 * $r), [single](2 * $r))
            $brush = [System.Drawing.Drawing2D.PathGradientBrush]::new($spot)
            $brush.CenterColor = [System.Drawing.Color]::FromArgb(235, $glow[2], $glow[3], $glow[4])
            $brush.SurroundColors = @([System.Drawing.Color]::FromArgb(0, $glow[2], $glow[3], $glow[4]))
            $g.FillPath($brush, $spot)
            $brush.Dispose(); $spot.Dispose()
        }
        $g.ResetClip()

        $pen = [System.Drawing.Pen]::new([System.Drawing.Color]::White, [single]($Size * 0.1))
        $pen.StartCap = 'Round'; $pen.EndCap = 'Round'; $pen.LineJoin = 'Round'
        $g.DrawLines($pen, [System.Drawing.PointF[]]@(
                [System.Drawing.PointF]::new($Size * 0.29, $Size * 0.53),
                [System.Drawing.PointF]::new($Size * 0.44, $Size * 0.67),
                [System.Drawing.PointF]::new($Size * 0.72, $Size * 0.36)))
        $pen.Dispose(); $square.Dispose()
    }
    finally { $g.Dispose() }
    $bitmap
}

function Set-CrButtonStyle {
    <# Primary buttons are solid blue, Danger ones red-edged, the rest light with a thin border. #>
    param([System.Windows.Forms.Button] $Button, [ValidateSet('Primary', 'Secondary', 'Danger')] [string] $Kind = 'Secondary')
    $Button.FlatStyle = 'Flat'
    $Button.Cursor = [System.Windows.Forms.Cursors]::Hand
    $Button.UseVisualStyleBackColor = $false
    $colors = switch ($Kind) {
        'Primary' { @{ Back = [System.Drawing.Color]::FromArgb(15, 108, 189); Fore = [System.Drawing.Color]::White; Border = [System.Drawing.Color]::FromArgb(15, 108, 189); Hover = [System.Drawing.Color]::FromArgb(17, 94, 163) } }
        'Danger' { @{ Back = [System.Drawing.Color]::White; Fore = [System.Drawing.Color]::FromArgb(198, 40, 40); Border = [System.Drawing.Color]::FromArgb(230, 160, 160); Hover = [System.Drawing.Color]::FromArgb(253, 236, 236) } }
        default { @{ Back = [System.Drawing.Color]::White; Fore = [System.Drawing.Color]::FromArgb(31, 35, 40); Border = [System.Drawing.Color]::FromArgb(200, 205, 212); Hover = [System.Drawing.Color]::FromArgb(240, 243, 246) } }
    }
    $Button.FlatAppearance.MouseOverBackColor = $colors.Hover
    # Flat buttons don't grey themselves out, so a turned-off one is drawn pale.
    $apply = {
        $Button.BackColor = if ($Button.Enabled) { $colors.Back } else { [System.Drawing.Color]::FromArgb(243, 244, 246) }
        $Button.ForeColor = if ($Button.Enabled) { $colors.Fore } else { [System.Drawing.Color]::FromArgb(160, 166, 173) }
        $Button.FlatAppearance.BorderColor = if ($Button.Enabled) { $colors.Border } else { [System.Drawing.Color]::FromArgb(225, 228, 232) }
    }.GetNewClosure()
    & $apply
    $Button.Add_EnabledChanged($apply)
}

function Set-CrScreenShare {
    <# Sizes a window to this share of the screen (never smaller than it was built) and centres it. #>
    param([System.Windows.Forms.Form] $Form, [double] $Width, [double] $Height)
    $area = [System.Windows.Forms.Screen]::FromControl($Form).WorkingArea
    $w = [Math]::Min($area.Width, [Math]::Max($Form.Width, [int]($area.Width * $Width)))
    $h = [Math]::Min($area.Height, [Math]::Max($Form.MinimumSize.Height, [int]($area.Height * $Height)))
    $Form.Bounds = [System.Drawing.Rectangle]::new($area.Left + [int](($area.Width - $w) / 2), $area.Top + [int](($area.Height - $h) / 2), $w, $h)
}

function Set-CrFitToScreen {
    param([System.Windows.Forms.Form] $Form)
    $area = [System.Windows.Forms.Screen]::FromControl($Form).WorkingArea
    if ($Form.Height -gt $area.Height) { $Form.Height = $area.Height }
    if ($Form.Top -lt $area.Top -or $Form.Bottom -gt $area.Bottom) { $Form.Top = $area.Top + [Math]::Max(0, ($area.Height - $Form.Height) / 2) }
}

function Show-CrControlWindow {
    <# Shows the window and returns the choice: Action 'New' (with Level, Include and Sites), 'Resume' (with Folder), 'SwitchTenant' or 'Cancel'. #>
    param(
        [Parameter(Mandatory)] [object[]] $Sites,
        [Parameter(Mandatory)] [string] $TenantName,
        [string] $SharePointUrl,
        $Unfinished,
        [object[]] $PastScans = @(),
        [string] $DefaultLevel = 'Quick',
        [string] $DefaultInclude = 'SharePoint',
        [string[]] $DefaultSites = @(),
        [string] $DefaultPace = 'Normal',
        $About,
        $TenantSettings,
        $TenantSettingsRead,
        [hashtable] $Remediation,
        [string] $StartTab,
        [string] $StartGroup
    )
    $form = New-CrControlForm -Sites $Sites -TenantName $TenantName -SharePointUrl $SharePointUrl -Unfinished $Unfinished -PastScans $PastScans -DefaultLevel $DefaultLevel `
        -DefaultInclude $DefaultInclude -DefaultSites $DefaultSites -DefaultPace $DefaultPace -About $About -TenantSettings $TenantSettings -TenantSettingsRead $TenantSettingsRead -Remediation $Remediation -StartTab $StartTab -StartGroup $StartGroup
    try {
        [void]$form.ShowDialog()
        $form.Tag
    }
    finally {
        $form.Dispose()
    }
}
