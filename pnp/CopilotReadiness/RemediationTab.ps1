# The Remediation tab of the control window: choose a fix, its options and the sites,
# preview what it would change, then do it. The work itself is in Remediation.ps1 and
# runs in the background; this tab follows it with a timer.

function Add-CrRemediationTab {
    <#
      Builds the tab and adds it to Tabs. Called by New-CrControlForm while it builds the
      window, and uses its New-Label, so the tab's wrapping text follows the window's width.
      Remediation carries ResultsRoot, Tenant, TeamsKnown (whether Teams and channel sites
      could be told apart), DefaultPace (Gentle, Normal or Fast) and Start (a script block
      taking a fix's folder, step and pace that starts it in the background).
    #>
    param(
        [Parameter(Mandatory)] [System.Windows.Forms.Form] $Form,
        [Parameter(Mandatory)] [System.Windows.Forms.TabControl] $Tabs,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Sites,
        [Parameter(Mandatory)] [hashtable] $Remediation,
        [Parameter(Mandatory)] [System.Drawing.Font] $Font,
        [Parameter(Mandatory)] [System.Drawing.Font] $Bold,
        [Parameter(Mandatory)] [System.Drawing.Color] $Muted,
        [Parameter(Mandatory)] [scriptblock] $NewLabel
    )
    $resultsRoot = $Remediation.ResultsRoot
    $tenant = $Remediation.Tenant
    $startFix = $Remediation.Start
    $teamsKnown = [bool]$Remediation.TeamsKnown
    $form = $Form

    $page = [System.Windows.Forms.TabPage]@{ Text = 'Remediation'; BackColor = [System.Drawing.Color]::White; Padding = [System.Windows.Forms.Padding]::new(12, 8, 12, 8); AutoScroll = $true }
    $page.AutoScrollMinSize = [System.Drawing.Size]::new(0, 600)
    $grid = [System.Windows.Forms.TableLayoutPanel]@{ Dock = 'Fill'; ColumnCount = 2 }
    $null = $grid.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new('Percent', 50))
    $null = $grid.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new('Percent', 50))
    # Rows: what to do, which links, how old (the site list beside all three), progress, results, buttons and pace.
    foreach ($size in 'AutoSize', 'AutoSize', 'P55', 'AutoSize', 'P45', 'AutoSize') {
        $null = $grid.RowStyles.Add($(if ($size -like 'P*') { [System.Windows.Forms.RowStyle]::new('Percent', [int]$size.Substring(1)) } else { [System.Windows.Forms.RowStyle]::new('AutoSize') }))
    }
    $page.Controls.Add($grid)
    $Tabs.TabPages.Add($page)

    function New-Box([string] $text, [int] $top = 12) {
        [System.Windows.Forms.GroupBox]@{ Text = $text; AutoSize = $true; Dock = 'Top'; Padding = [System.Windows.Forms.Padding]::new(12, 8, 12, 8); Margin = [System.Windows.Forms.Padding]::new(0, $top, 6, 0) }
    }
    function New-Stack {
        [System.Windows.Forms.FlowLayoutPanel]@{ Dock = 'Fill'; AutoSize = $true; FlowDirection = 'TopDown'; WrapContents = $false }
    }
    function New-Note([string] $text) {
        $l = & $NewLabel $text $Font $Muted
        $l.Tag = 'half'
        $l
    }

    # What to do: one fix for now.
    $actionBox = New-Box 'What to do' 4
    $actionStack = New-Stack
    $actionRadio = [System.Windows.Forms.RadioButton]@{ Text = 'Remove sharing links'; Font = $Bold; AutoSize = $true; Checked = $true; Margin = [System.Windows.Forms.Padding]::new(0, 4, 0, 0) }
    $actionNote = New-Note ('Removes the sharing links you choose on the sites you choose. Preview first: it lists every link it finds and which would go, ' +
        'and changes nothing. Access given straight to a person, and owners'' and members'' access, are never touched.')
    $actionNote.Margin = [System.Windows.Forms.Padding]::new(18, 2, 0, 0)
    $actionStack.Controls.AddRange(@($actionRadio, $actionNote))
    $actionBox.Controls.Add($actionStack)
    $grid.Controls.Add($actionBox, 0, 0)

    # Which links
    $linksBox = New-Box 'Which links'
    $linksStack = New-Stack
    # One tick box per type, so a client can, say, remove only "Anyone" links and keep company-wide ones.
    $linkBoxes = [ordered]@{}
    $linkLabels = [ordered]@{
        Anyone         = '"Anyone" links (no sign-in needed)'
        Organization   = '"People in your organization" links'
        SpecificPeople = '"Specific people" links'
        Other          = 'Other links (such as "People with existing access")'
    }
    foreach ($type in $linkLabels.Keys) {
        $box = [System.Windows.Forms.CheckBox]@{ Text = $linkLabels[$type]; Font = $Bold; AutoSize = $true; Tag = $type; Margin = [System.Windows.Forms.Padding]::new(0, 4, 0, 0) }
        $box.Checked = $type -in 'Anyone', 'Organization'
        $linkBoxes[$type] = $box
        $linksStack.Controls.Add($box)
    }
    $linksNote = New-Note 'Tick one or more. "Specific people" links only reach the people named on them; removing them means those people ask again.'
    $linksNote.Margin = [System.Windows.Forms.Padding]::new(0, 6, 0, 0)
    $linksStack.Controls.Add($linksNote)
    $linksBox.Controls.Add($linksStack)
    $grid.Controls.Add($linksBox, 0, 1)

    # How old
    $ageBox = New-Box 'How old'
    $ageStack = New-Stack
    $anyAge = [System.Windows.Forms.RadioButton]@{ Text = 'Any age'; Font = $Bold; AutoSize = $true; Tag = 'Any'; Margin = [System.Windows.Forms.Padding]::new(0, 4, 0, 0) }
    $olderRow = [System.Windows.Forms.FlowLayoutPanel]@{ AutoSize = $true; WrapContents = $false; Margin = [System.Windows.Forms.Padding]::new(0, 4, 0, 0) }
    $older = [System.Windows.Forms.RadioButton]@{ Text = 'Older than'; Font = $Bold; AutoSize = $true; Tag = 'OlderThan'; Checked = $true; Margin = [System.Windows.Forms.Padding]::new(0, 3, 6, 0) }
    # Set one at a time: the range has to be in place before the value, and a list of settings can apply them in any order.
    $days = [System.Windows.Forms.NumericUpDown]@{ Width = 70; Margin = [System.Windows.Forms.Padding]::new(0, 0, 6, 0) }
    $days.Maximum = 3650
    $days.Minimum = 1
    $days.Value = 180
    $daysWord = [System.Windows.Forms.Label]@{ Text = 'days'; AutoSize = $true; Margin = [System.Windows.Forms.Padding]::new(0, 4, 0, 0) }
    $olderRow.Controls.AddRange(@($older, $days, $daysWord))
    $beforeRow = [System.Windows.Forms.FlowLayoutPanel]@{ AutoSize = $true; WrapContents = $false; Margin = [System.Windows.Forms.Padding]::new(0, 4, 0, 0) }
    $before = [System.Windows.Forms.RadioButton]@{ Text = 'Made before'; Font = $Bold; AutoSize = $true; Tag = 'Before'; Margin = [System.Windows.Forms.Padding]::new(0, 3, 6, 0) }
    $beforeDate = [System.Windows.Forms.DateTimePicker]@{ Format = 'Long'; Width = 220; Value = (Get-Date).Date.AddDays(-180) }
    $beforeRow.Controls.AddRange(@($before, $beforeDate))
    # The three are in different panels, so they don't untick each other by themselves.
    $ageRadios = @($anyAge, $older, $before)
    foreach ($r in $ageRadios) {
        $others = @($ageRadios | Where-Object { $_ -ne $r })
        $r.Add_CheckedChanged({ param($sender) if ($sender.Checked) { foreach ($o in $others) { $o.Checked = $false } } }.GetNewClosure())
    }
    $days.Add_ValueChanged({ $older.Checked = $true }.GetNewClosure())
    $beforeDate.Add_ValueChanged({ $before.Checked = $true }.GetNewClosure())
    $ageNote = New-Note 'A link whose date SharePoint doesn''t give is kept unless you choose Any age.'
    $ageNote.Margin = [System.Windows.Forms.Padding]::new(0, 6, 0, 0)
    $ageStack.Controls.AddRange(@($anyAge, $olderRow, $beforeRow, $ageNote))
    $ageBox.Controls.Add($ageStack)
    $grid.Controls.Add($ageBox, 0, 2)

    # Pace, beside the Preview and Remove buttons: the same choices and limits as a scan, since a big
    # OneDrive can mean thousands of requests. Changing it doesn't undo a preview.
    $paceRow = [System.Windows.Forms.FlowLayoutPanel]@{ AutoSize = $true; WrapContents = $false; Margin = [System.Windows.Forms.Padding]::new(24, 6, 0, 0) }
    $paceRow.Controls.Add([System.Windows.Forms.Label]@{ Text = 'Pace:'; AutoSize = $true; ForeColor = $Muted; Margin = [System.Windows.Forms.Padding]::new(0, 4, 8, 0) })
    $paceTips = [System.Windows.Forms.ToolTip]::new()
    $paceRadios = [ordered]@{}
    foreach ($pace in Get-CrPaces) {
        $radio = [System.Windows.Forms.RadioButton]@{ Text = $pace.Name; AutoSize = $true; Tag = $pace.Id; Margin = [System.Windows.Forms.Padding]::new(0, 2, 14, 0) }
        $paceTips.SetToolTip($radio, "At most $($pace.PerMinute) requests a minute, one site at a time. Can be changed while a Preview or Remove runs.")
        $paceRadios[$pace.Id] = $radio
        $paceRow.Controls.Add($radio)
    }
    $paceRadios[(Get-CrPace "$($Remediation.DefaultPace)").Id].Checked = $true
    $selectedPace = { Get-CrPace ($paceRadios.Values | Where-Object Checked | Select-Object -First 1).Tag }.GetNewClosure()
    # A site previewed before is normally brought up to date from Microsoft's list of changes; this reads everything again.
    $fullCheck = [System.Windows.Forms.CheckBox]@{ Text = 'Check every file again'; AutoSize = $true; Margin = [System.Windows.Forms.Padding]::new(10, 2, 0, 0) }
    $paceTips.SetToolTip($fullCheck, ('A site previewed before is normally brought up to date from Microsoft''s list of changes: only files changed since ' +
            'are checked again, which is much quicker on a big OneDrive. Tick this to read every file again instead.'))
    $paceRow.Controls.Add($fullCheck)

    # Which sites: filters by kind, a search box, and a list to tick.
    $siteBox = [System.Windows.Forms.GroupBox]@{ Text = 'Which sites'; Dock = 'Fill'; Padding = [System.Windows.Forms.Padding]::new(12, 8, 12, 12); Margin = [System.Windows.Forms.Padding]::new(6, 4, 0, 0) }
    $siteLayout = [System.Windows.Forms.TableLayoutPanel]@{ Dock = 'Fill'; ColumnCount = 1 }
    $null = $siteLayout.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new('Percent', 100))
    foreach ($i in 1..2) { $null = $siteLayout.RowStyles.Add([System.Windows.Forms.RowStyle]::new('AutoSize')) }
    $null = $siteLayout.RowStyles.Add([System.Windows.Forms.RowStyle]::new('Percent', 100))
    $null = $siteLayout.RowStyles.Add([System.Windows.Forms.RowStyle]::new('AutoSize'))
    $kindRow = [System.Windows.Forms.FlowLayoutPanel]@{ AutoSize = $true; WrapContents = $true; Dock = 'Fill'; Margin = [System.Windows.Forms.Padding]::new(0, 0, 0, 4) }
    $placeWords = [ordered]@{ SharePoint = 'SharePoint'; Team = 'Teams'; Channel = 'Channels'; OneDrive = 'OneDrive' }
    $placeCounts = @{}
    foreach ($s in $Sites) { $p = Get-CrSitePlace $s; $placeCounts[$p] = 1 + [int]$placeCounts[$p] }
    $placeBoxes = [ordered]@{}
    $tips = [System.Windows.Forms.ToolTip]::new()
    foreach ($p in $placeWords.Keys) {
        $box = [System.Windows.Forms.CheckBox]@{ Text = ('{0} ({1:N0})' -f $placeWords[$p], [int]$placeCounts[$p]); AutoSize = $true; Checked = $true; Tag = $p; Margin = [System.Windows.Forms.Padding]::new(0, 2, 16, 0) }
        if (-not $teamsKnown -and $p -in 'Team', 'Channel') {
            $box.Enabled = $false
            $tips.SetToolTip($box, "Couldn't tell which sites belong to Teams, so they're listed under SharePoint.")
        }
        $placeBoxes[$p] = $box
        $kindRow.Controls.Add($box)
    }
    $search = [System.Windows.Forms.TextBox]@{ Dock = 'Fill'; PlaceholderText = 'Type to find one by name or address'; Margin = [System.Windows.Forms.Padding]::new(0, 4, 0, 4) }
    $list = [System.Windows.Forms.CheckedListBox]@{ Dock = 'Fill'; CheckOnClick = $true; IntegralHeight = $false; Margin = [System.Windows.Forms.Padding]::new(0, 0, 0, 4) }
    $listFoot = [System.Windows.Forms.FlowLayoutPanel]@{ AutoSize = $true; Dock = 'Fill'; WrapContents = $true; Margin = [System.Windows.Forms.Padding]::new(0) }
    $tickShown = [System.Windows.Forms.LinkLabel]@{ Text = 'Check all shown'; AutoSize = $true; Margin = [System.Windows.Forms.Padding]::new(0, 2, 12, 0) }
    $clearAll = [System.Windows.Forms.LinkLabel]@{ Text = 'Clear'; AutoSize = $true; Margin = [System.Windows.Forms.Padding]::new(0, 2, 24, 0) }
    $chosenCount = [System.Windows.Forms.Label]@{ Text = ''; AutoSize = $true; Font = $Bold; Margin = [System.Windows.Forms.Padding]::new(0, 2, 0, 0) }
    $listFoot.Controls.AddRange(@($tickShown, $clearAll, $chosenCount))
    # Said when more sites match than the list shows, on a line of its own so neither it nor the count is cut off.
    $moreSites = & $NewLabel '' $Font $Muted
    $moreSites.Tag = 'half'
    $moreSites.Visible = $false
    $moreSites.Margin = [System.Windows.Forms.Padding]::new(0, 2, 0, 0)
    $listFoot.Controls.Add($moreSites)
    $listFoot.SetFlowBreak($chosenCount, $true)
    # What the next preview will do on the chosen sites: only what changed on sites checked before, or read everything.
    $planNote = & $NewLabel '' $Font $Muted
    $planNote.Tag = 'half'
    $planNote.Margin = [System.Windows.Forms.Padding]::new(0, 4, 0, 0)
    $siteLayout.RowStyles.Insert(3, [System.Windows.Forms.RowStyle]::new('AutoSize'))
    $siteLayout.Controls.AddRange(@($kindRow, $search, $list, $listFoot, $planNote))
    $siteBox.Controls.Add($siteLayout)
    $grid.Controls.Add($siteBox, 1, 0)
    $grid.SetRowSpan($siteBox, 3)

    # Progress: a bar and a line saying what is happening.
    $progressPanel = [System.Windows.Forms.TableLayoutPanel]@{ AutoSize = $true; Dock = 'Fill'; ColumnCount = 1; Margin = [System.Windows.Forms.Padding]::new(0, 12, 0, 0) }
    $null = $progressPanel.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new('Percent', 100))
    $bar = [System.Windows.Forms.ProgressBar]@{ Dock = 'Fill'; Height = 14; Visible = $false; Margin = [System.Windows.Forms.Padding]::new(0, 0, 0, 4) }
    $status = & $NewLabel 'Choose the links and sites, then press Preview.' $Bold
    # Under it, once a preview is shown: hide what stays, and tick or untick every link at once.
    $listTools = [System.Windows.Forms.FlowLayoutPanel]@{ AutoSize = $true; WrapContents = $false; Visible = $false; Margin = [System.Windows.Forms.Padding]::new(0, 4, 0, 0) }
    $hideKept = [System.Windows.Forms.CheckBox]@{ Text = 'Hide links that will be kept'; AutoSize = $true; Margin = [System.Windows.Forms.Padding]::new(0, 2, 24, 0) }
    $tickAllLinks = [System.Windows.Forms.LinkLabel]@{ Text = 'Tick all'; AutoSize = $true; Margin = [System.Windows.Forms.Padding]::new(0, 4, 12, 0) }
    $untickAllLinks = [System.Windows.Forms.LinkLabel]@{ Text = 'Untick all'; AutoSize = $true; Margin = [System.Windows.Forms.Padding]::new(0, 4, 24, 0) }
    $tickNote = [System.Windows.Forms.Label]@{ Text = 'Untick a link to leave it as it is.'; AutoSize = $true; ForeColor = $Muted; Margin = [System.Windows.Forms.Padding]::new(0, 4, 0, 0) }
    $listTools.Controls.AddRange(@($hideKept, $tickAllLinks, $untickAllLinks, $tickNote))
    $progressPanel.Controls.AddRange(@($bar, $status, $listTools))
    $grid.Controls.Add($progressPanel, 0, 3)
    $grid.SetColumnSpan($progressPanel, 2)

    # What the preview found, or what was removed.
    # After a preview, each link to remove has a tick box, ticked to start with.
    $results = [System.Windows.Forms.ListView]@{ View = 'Details'; FullRowSelect = $true; CheckBoxes = $true; VirtualMode = $true; Dock = 'Fill'; Margin = [System.Windows.Forms.Padding]::new(0, 4, 0, 4) }
    # Clicking a heading sorts by it; clicking it again turns the order round.
    $columnNames = @('What happens', 'Link', 'Access', 'Made on', 'Shared with', 'File or folder', 'Site')
    $columnWidths = @(270, 195, 60, 95, 180, 380, 160)
    foreach ($i in 0..($columnNames.Count - 1)) { $null = $results.Columns.Add($columnNames[$i], $columnWidths[$i]) }
    $grid.Controls.Add($results, 0, 4)
    $grid.SetColumnSpan($results, 2)

    $buttonRow = [System.Windows.Forms.FlowLayoutPanel]@{ AutoSize = $true; Dock = 'Fill'; WrapContents = $false; Margin = [System.Windows.Forms.Padding]::new(0, 4, 0, 0) }
    $preview = [System.Windows.Forms.Button]@{ Text = 'Preview'; AutoSize = $true; Padding = [System.Windows.Forms.Padding]::new(12, 3, 12, 3) }
    $remove = [System.Windows.Forms.Button]@{ Text = 'Remove links'; AutoSize = $true; Padding = [System.Windows.Forms.Padding]::new(12, 3, 12, 3); Enabled = $false }
    $openSheet = [System.Windows.Forms.Button]@{ Text = 'Open spreadsheet'; AutoSize = $true; Padding = [System.Windows.Forms.Padding]::new(10, 3, 10, 3); Enabled = $false; Margin = [System.Windows.Forms.Padding]::new(24, 3, 3, 3) }
    $openFolder = [System.Windows.Forms.Button]@{ Text = 'Open its folder'; AutoSize = $true; Padding = [System.Windows.Forms.Padding]::new(10, 3, 10, 3); Enabled = $false }
    Set-CrButtonStyle $preview Primary
    Set-CrButtonStyle $remove Danger
    Set-CrButtonStyle $openSheet
    Set-CrButtonStyle $openFolder
    $buttonRow.Controls.AddRange(@($preview, $remove, $paceRow, $openSheet, $openFolder))
    $grid.Controls.Add($buttonRow, 0, 5)
    $grid.SetColumnSpan($buttonRow, 2)

    # ── Behaviour ──

    # Ticks are kept by address, so searching and filtering don't lose them.
    $chosen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $shown = [System.Collections.Generic.List[string]]::new()      # the sites the list shows, in order
    $matching = [System.Collections.Generic.List[string]]::new()   # every site the filters and search match
    # Folder: the fix on screen. Step: Preview or Remove. Running: a step is going. Key: the choices it was started with.
    # PreviewKey: the choices of a finished preview, so Remove only works for exactly those. ToRemove: what the preview would remove.
    # Rows: the preview's links. Unticked: the links to remove that have been unticked, by Get-CrLinkKey. ShowingPreview: the list holds a preview.
    $st = @{ Filling = $false; Folder = $null; Step = $null; Running = $false; Key = $null; PreviewKey = $null; ToRemove = 0; Removed = $false; Sheet = $null
        Rows = @(); Unticked = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase); ShowingPreview = $false; Process = $null
        SortColumn = -1; SortDescending = $false
        # Goes up whenever the chosen sites, or their "last checked" times, change (see $chosenInfo).
        ChosenVersion = 0
        # How many chosen sites the list leaves out. A tick is always on a site in the list, so it can't change this.
        NotShown = 0 }

    # Each site by address, and when each was last previewed. Worked out once (and again after each
    # preview), not on every keystroke or tick: a tenant can have thousands of OneDrives.
    $siteByUrl = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($s in $Sites) { $siteByUrl["$($s.url)"] = $s }
    $siteUrls = [string[]]@($Sites | ForEach-Object { "$($_.url)" })
    $lastChecked = [System.Collections.Generic.Dictionary[string, DateTime]]::new([StringComparer]::OrdinalIgnoreCase)
    $readLastChecked = {
        $lastChecked.Clear()
        $times = Get-CrLinkCacheTimes -ResultsRoot $resultsRoot -Tenant $tenant -SiteUrls $siteUrls
        foreach ($k in $times.Keys) { $lastChecked[$k] = $times[$k] }
        $st.ChosenVersion++
    }.GetNewClosure()
    & $readLastChecked
    # Each site's place (SharePoint, Team, Channel or OneDrive), worked out once.
    $placeOf = [System.Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($s in $Sites) { $placeOf["$($s.url)"] = Get-CrSitePlace $s }

    # The site list, built as one list of lines and added in one go: thousands of sites one at a time is slow.
    # The list shows at most this many sites: past a couple of thousand it gets slow to fill. Typing narrows
    # it, and Check all ticks every site that matches, shown or not.
    $maxSitesShown = 2000
    $siteTick = @{ Handler = $null }   # the site list's tick handler, set below
    $fill = {
        $st.Filling = $true
        $text = $search.Text.Trim()
        $want = @{}
        foreach ($k in $placeBoxes.Keys) { $want[$k] = $placeBoxes[$k].Checked }
        $lines = [System.Collections.Generic.List[object]]::new()
        $shown.Clear()
        $matching.Clear()
        foreach ($s in $Sites) {
            $u = "$($s.url)"
            $p = $placeOf[$u]
            if (-not $want[$p]) { continue }
            if ($text -and $u.IndexOf($text, [StringComparison]::OrdinalIgnoreCase) -lt 0 -and "$($s.title)".IndexOf($text, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
            $matching.Add($u)
            if ($lines.Count -ge $maxSitesShown) { continue }
            $name = if ($s.title) { $s.title } else { $u }
            # Before the address, which can be long enough to push it out of sight.
            $seen = if ($lastChecked.ContainsKey($u)) { "   (last checked $($lastChecked[$u].ToString('MMM d, h:mm tt')))" } else { '' }
            $lines.Add("$name   [$p]$seen   $u")
            $shown.Add($u)
        }
        $list.BeginUpdate()
        $list.Items.Clear()
        $list.Items.AddRange($lines.ToArray())
        # Ticking the chosen ones would set off the tick handler once each (seconds for thousands), so it is off meanwhile.
        if ($siteTick.Handler) { $list.Remove_ItemCheck($siteTick.Handler) }
        try { for ($i = 0; $i -lt $shown.Count; $i++) { if ($chosen.Contains($shown[$i])) { $list.SetItemChecked($i, $true) } } }
        finally { if ($siteTick.Handler) { $list.Add_ItemCheck($siteTick.Handler) } }
        $list.EndUpdate()
        $moreSites.Visible = $matching.Count -gt $shown.Count
        $moreSites.Text = ('Showing {0:N0} of {1:N0}: type to find the others. Check all ticks all {1:N0}.' -f $shown.Count, $matching.Count)
        $tickShown.Text = if ($matching.Count -gt $shown.Count) { 'Check all {0:N0}' -f $matching.Count } else { 'Check all shown' }
        $st.NotShown = Get-CrChosenNotShown -Chosen @($chosen) -Shown @($shown) -Known $siteByUrl
        $st.Filling = $false
    }.GetNewClosure()

    $readOptions = {
        $age = ($ageRadios | Where-Object Checked | Select-Object -First 1).Tag
        [pscustomobject][ordered]@{
            links  = @($linkBoxes.Values | Where-Object Checked | ForEach-Object Tag)
            fullCheck = $fullCheck.Checked
            age    = $age
            days   = [int]$days.Value
            before = $beforeDate.Value.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
        }
    }.GetNewClosure()
    # The chosen sites, from the ticked addresses (not by going through every site in the tenant).
    $chosenSites = { @(foreach ($url in $chosen) { if ($siteByUrl.ContainsKey($url)) { $siteByUrl[$url] } }) }.GetNewClosure()
    # What depends only on the chosen sites (them, their addresses as one piece of text, how many were checked
    # before), worked out again only when they change, not on every tick: thousands can be chosen at once.
    $chosenCache = @{ Version = -1; Picked = @(); Sites = ''; Before = 0 }
    $chosenInfo = {
        if ($chosenCache.Version -ne $st.ChosenVersion) {
            $picked = @(& $chosenSites)
            $chosenCache.Picked = $picked
            $chosenCache.Sites = (@($picked | ForEach-Object url) | Sort-Object) -join ','
            $chosenCache.Before = @($picked | Where-Object { $lastChecked.ContainsKey($_.url) }).Count
            $chosenCache.Version = $st.ChosenVersion
        }
        $chosenCache
    }.GetNewClosure()
    # The choices as one piece of text, to tell whether a finished preview still matches them.
    # Only the option that applies counts, so changing the unused one doesn't undo the preview.
    $currentKey = {
        $o = & $readOptions
        $age = switch ($o.age) { 'OlderThan' { "older:$($o.days)" } 'Before' { "before:$($o.before)" } default { 'any' } }
        "$(@($o.links) -join '+')|$age|$((& $chosenInfo).Sites)"
    }.GetNewClosure()

    # The pace stays open while a step runs: changing it then tells the running step (see Update-CrFixPace).
    $inputs = @($actionBox, $linksBox, $ageBox, $fullCheck, $siteBox)
    $update = {
        $info = & $chosenInfo
        $n = $info.Picked.Count
        $chosenCount.Text = if ($n -eq 1) { '1 chosen' } else { '{0:N0} chosen' -f $n }
        # Ticked sites can be out of the list and are still previewed, so say so. Worked out as the list fills.
        if ($st.NotShown) { $chosenCount.Text += ', {0:N0} not shown in the list' -f $st.NotShown }
        # Whether the next preview reads everything or only what changed, so it's clear before pressing it.
        $before = $info.Before
        $planNote.Text = if (-not $n) { '' }
        elseif ($fullCheck.Checked) { 'Next preview: every file on the chosen sites is read again.' }
        elseif ($before -eq $n) { "Next preview: all $(if ($n -eq 1) { 'of it was' } else { "$n were" }) checked before, so only what changed since is read." }
        elseif (-not $before) { "Next preview: $(if ($n -eq 1) { 'it is new' } else { "all $n are new" }), so every file is read. After that, only what changed is read." }
        else { "Next preview: $before checked before, so only what changed is read; $($n - $before) new, read in full." }
        foreach ($c in $inputs) { $c.Enabled = -not $st.Running }
        if ($st.Running) {
            $preview.Text = 'Stop'
            $preview.Enabled = $true
            $remove.Enabled = $false
        }
        else {
            $preview.Text = 'Preview'
            $preview.Enabled = $n -gt 0 -and @($linkBoxes.Values | Where-Object Checked).Count -gt 0
            $same = $st.PreviewKey -and $st.PreviewKey -eq (& $currentKey)
            $ticked = $st.ToRemove - $st.Unticked.Count
            $remove.Enabled = [bool]($same -and -not $st.Removed -and $ticked -gt 0)
            $remove.Text = if ($remove.Enabled) { if ($ticked -eq 1) { 'Remove 1 link' } else { 'Remove {0:N0} links' -f $ticked } } else { 'Remove links' }
        }
        $openSheet.Enabled = [bool]($st.Sheet -and (Test-Path -LiteralPath $st.Sheet))
        $openFolder.Enabled = [bool]$st.Folder
    }.GetNewClosure()

    $typeWords = @{}
    foreach ($t in 'Anyone', 'Organization', 'SpecificPeople', 'Other') { $typeWords[$t] = Get-CrLinkTypeWord $t }
    $red = [System.Drawing.Color]::FromArgb(198, 40, 40)
    # Each row's text (all but What happens) and its key, worked out once for each new list of rows,
    # by position: thousands of rows are drawn, sorted and redrawn many times, and this is the slow part.
    $prep = @{ For = $null; Cells = $null; Keys = $null }
    $prepare = {
        $rows = $st.Rows
        $cells = [string[][]]::new($rows.Count)
        $keys = [string[]]::new($rows.Count)
        for ($i = 0; $i -lt $rows.Count; $i++) {
            $r = $rows[$i]
            $made = 'Unknown'
            $d = [DateTimeOffset]::MinValue
            if ($r.created -and [DateTimeOffset]::TryParse("$($r.created)", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$d)) { $made = $d.ToLocalTime().ToString('MMM d, yyyy') }
            $type = "$($r.type)"
            if ($typeWords.ContainsKey($type)) { $type = $typeWords[$type] }
            $cells[$i] = [string[]]@('', $type, "$($r.access)", $made, "$($r.sharedWith)", "$($r.url)", $(if ($r.siteTitle) { "$($r.siteTitle)" } else { "$($r.site)" }))
            $keys[$i] = Get-CrLinkKey $r
        }
        $prep.For = $rows; $prep.Cells = $cells; $prep.Keys = $keys
    }.GetNewClosure()

    # What happens to row i of Rows, in words: what Remove did, or, for a preview, whether it goes.
    $whatOf = {
        param([int] $i)
        $r = $st.Rows[$i]
        if (-not $st.ShowingPreview) { "$($r.result)" }
        elseif (-not $r.remove) { "Keep: $($r.why)" }
        elseif ($st.Unticked.Contains($prep.Keys[$i])) { 'Keep: you unticked it' }
        else { 'Will be removed' }
    }.GetNewClosure()

    # The list is "virtual": it asks for just the rows it draws (see RetrieveVirtualItem below), so it shows
    # every link however many there are; filling a list of thousands row by row took many seconds.
    # Order: which row of Rows each line of the list shows, after hiding and sorting.
    $view = @{ Order = [int[]]@() }
    $render = {
        if (-not [object]::ReferenceEquals($prep.For, $st.Rows)) { & $prepare }
        $rows = $st.Rows
        $n = $rows.Count
        $preview = $st.ShowingPreview
        $pick = [System.Collections.Generic.List[int]]::new()
        for ($i = 0; $i -lt $n; $i++) {
            if (-not $preview -or $rows[$i].remove -or -not $hideKept.Checked) { $pick.Add($i) }
        }
        $order = $pick.ToArray()
        if ($st.SortColumn -ge 0 -and $order.Count -gt 1) {
            # Sorted on prepared keys. The position after each keeps rows that tie in the order they were found,
            # both ways: for high to low, the positions count down, so turning the list round keeps ties in order.
            # Dates sort as dates (unknown ones first), the rest as the text shown.
            $col = $st.SortColumn
            $last = $order.Count - 1
            $sortKeys = [string[]]::new($order.Count)
            for ($j = 0; $j -lt $order.Count; $j++) {
                $i = $order[$j]
                $k = if ($col -eq 0) { & $whatOf $i } elseif ($col -eq 3) { "$($rows[$i].created)" } else { $prep.Cells[$i][$col] }
                $place = if ($st.SortDescending) { $last - $j } else { $j }
                $sortKeys[$j] = "$k`0$($place.ToString('D7'))"
            }
            [Array]::Sort($sortKeys, $order, [StringComparer]::OrdinalIgnoreCase)
            if ($st.SortDescending) { [Array]::Reverse($order) }
        }
        foreach ($c in 0..($columnNames.Count - 1)) {
            $results.Columns[$c].Text = if ($c -eq $st.SortColumn) { "$($columnNames[$c]) $(if ($st.SortDescending) { [char]0x25BC } else { [char]0x25B2 })" } else { $columnNames[$c] }
        }
        $view.Order = $order
        $results.VirtualListSize = 0          # so rows already drawn are asked for again
        $results.VirtualListSize = $order.Count
        $results.Invalidate()
    }.GetNewClosure()

    # What a finished, stopped or failed step leaves on screen.
    $showDone = {
        param($p)
        $st.Running = $false
        $bar.Visible = $false
        $problemText = if (@($p.problems).Count) { " $(@($p.problems).Count) site(s) couldn't be checked; they're in the log in its folder." } else { '' }
        if ($p.state -eq 'Failed' -and $st.Step -eq 'Preview') {
            $status.Text = "The preview stopped with a problem: $($p.error)"
        }
        elseif ($st.Step -eq 'Preview') {
            $file = Join-Path $st.Folder 'preview.json'
            if ($p.state -eq 'Completed' -and (Test-Path -LiteralPath $file)) {
                $found = Read-CrJson $file
                $links = @($found.links)
                $st.ToRemove = @($links | Where-Object remove).Count
                $st.PreviewKey = $st.Key
                & $readLastChecked; & $fill   # the sites' "last checked" times have moved on
                $st.Removed = $false
                $st.Sheet = Join-Path $st.Folder 'preview.csv'
                $st.Rows = $links
                $st.Unticked.Clear()
                $st.ShowingPreview = $true
                $results.CheckBoxes = $true
                & $render
                $listTools.Visible = $st.ToRemove -gt 0
                # How it checked: sites brought up to date from Microsoft's list of changes, and sites read in full.
                $how = ''
                if ($found.checked -and [int]$found.checked.changes) {
                    $since = if ($found.checked.since) { ' since ' + [DateTimeOffset]::Parse($found.checked.since, [Globalization.CultureInfo]::InvariantCulture).ToLocalTime().ToString('MMMM d, h:mm tt') } else { '' }
                    $how = " Only what changed$since was checked on {0:N0} site(s): {1:N0} file(s) and folder(s)." -f [int]$found.checked.changes, [int]$found.checked.changedItems
                    if ([int]$found.checked.full) { $how += ' {0:N0} site(s) were read in full.' -f [int]$found.checked.full }
                }
                if ($found.checked -and [int]$found.checked.resync) {
                    $how += ' On {0:N0} site(s) a folder''s sharing had changed since last time, and Microsoft then asks for everything there to be read again, so it was.' -f [int]$found.checked.resync
                }
                $status.Text = if (-not $links.Count) { "Preview done: no sharing links on the $(@($found.sites)) site(s) checked.$how$problemText" }
                else { ("Preview done: {0:N0} link(s) found, {1:N0} would be removed. Nothing has been changed yet.$how$problemText" -f $links.Count, $st.ToRemove) }
            }
            else { $status.Text = 'Preview stopped before it finished. Nothing was changed. Press Preview to start again.' }
        }
        else {
            $file = Join-Path $st.Folder 'removed.json'
            if (Test-Path -LiteralPath $file) {
                $links = @((Read-CrJson $file).links)
                $st.Removed = $true
                $st.Sheet = Join-Path $st.Folder 'removed.csv'
                $st.ShowingPreview = $false
                $listTools.Visible = $false
                $st.Rows = $links
                $results.CheckBoxes = $false
                & $render
                $what = '{0:N0} removed, {1:N0} already gone, {2:N0} failed.' -f [int]$p.removed, [int]$p.gone, [int]$p.failed
                if ([int]$p.skipped) { $what += ' {0:N0} left as they were because you unticked them.' -f [int]$p.skipped }
                $status.Text = switch ($p.state) {
                    'Completed' { "Done: $what" }
                    'Failed' { "It stopped with a problem: $($p.error) $what The links it didn't get to were left as they were; the list shows what happened to each." }
                    default { "Stopped part way: $what The rest were left as they were." }
                }
            }
            else {
                # It stopped before removing anything (say signing in failed): the preview is still there to try again.
                $listTools.Visible = $st.ToRemove -gt 0
                $status.Text = if ($p.state -eq 'Cancelled') { 'Stopped before removing anything. Nothing was removed; press Remove to start again.' }
                else { "Remove didn't start: $(if ($p.error) { $p.error } else { 'it stopped before removing anything' }). Nothing was removed; press Remove to try again." }
            }
        }
        & $update
    }.GetNewClosure()

    # Whether progress was written by the step this window started: same process number and start time.
    $fromStep = {
        param($p)
        if ($null -eq $p -or -not $st.Process -or [int]$p.pid -ne $st.Process.Id) { return $false }
        $mine = [DateTimeOffset]::MinValue; $theirs = [DateTimeOffset]::MinValue
        $stamp = Get-CrProcessStamp $st.Process
        if (-not [DateTimeOffset]::TryParse($stamp, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$mine) -or
            -not [DateTimeOffset]::TryParse("$($p.processStartedAt)", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$theirs)) { return $stamp -eq "$($p.processStartedAt)" }
        [Math]::Abs(($mine - $theirs).TotalSeconds) -lt 1
    }.GetNewClosure()

    # Follows the step running in the background, once a second.
    $timer = [System.Windows.Forms.Timer]@{ Interval = 1000 }
    $timer.Add_Tick({
            if (-not $st.Folder) { return }
            $p = Read-CrProgress $st.Folder
            # Started from this window: until the step itself reports (it writes progress with its own process),
            # what's in the file is from before, so it is followed by its process instead, however long it takes.
            # Its report is known by the process's number and when it started, since Windows reuses numbers.
            if ($st.Process -and -not (& $fromStep $p)) {
                if (-not $st.Process.HasExited) { $status.Text = 'Starting...'; return }
                $p = Read-CrProgress $st.Folder   # it may have reported just as it ended
                if (-not (& $fromStep $p)) {
                    $timer.Stop()
                    $st.Process = $null
                    & $showDone ([pscustomobject]@{ state = 'Failed'; error = "it closed before starting; the log in its folder says why"; problems = @() })
                    return
                }
            }
            # Opened while a step was just being launched (from another window): its note is there until it reports.
            if (-not $st.Process -and (Get-CrFixLaunch $st.Folder)) { $status.Text = 'Starting...'; return }
            if (-not $p) { return }
            if ($p.state -in 'Completed', 'Cancelled', 'Failed') { $timer.Stop(); $st.Process = $null; & $showDone $p; return }
            if (-not (Test-CrScanRunning $st.Folder)) {
                # The hidden window ended without saying so.
                $timer.Stop()
                & $showDone ([pscustomobject]@{ state = 'Failed'; error = 'it ended unexpectedly; the log in its folder says why'; problems = @() })
                return
            }
            $bar.Visible = $true
            $total = [Math]::Max(1, [int]$p.total)
            if ($p.step -eq 'Preview') {
                # In hundredths of a site, so the bar moves while one big site is read.
                $read = [int]$p.itemsRead
                $expected = [Math]::Max($read, [int]$p.itemsTotal)
                $bar.Maximum = $total * 100
                $part = if ($expected -gt 0) { [Math]::Floor(100.0 * $read / $expected) } else { 0 }
                $bar.Value = [Math]::Min($total * 100, [int]$p.done * 100 + [int]$part)
            }
            else {
                $bar.Maximum = $total
                $bar.Value = [Math]::Min($total, [int]$p.done)
            }
            $at = if ($p.pace) { " At the $((Get-CrPace $p.pace).Name) pace." } else { '' }
            $status.Text = if ($p.state -eq 'Starting') { 'Signing in...' }
            elseif ($p.step -eq 'Preview') {
                $files = if ($expected -gt 0) { ' Read {0:N0} of {1:N0} files and folders, {2:N0} with their own sharing.' -f $read, $expected, [int]$p.itemsShared } else { '' }
                ('Checking {0} ({1:N0} of {2:N0} sites).{3} {4:N0} link(s) found so far. Nothing is being changed.' -f $p.current, ([int]$p.done + 1), [int]$p.total, $files, ([int]$p.found + [int]$p.siteLinks)) + $at
            }
            else { ('Removing links: {0:N0} of {1:N0} done.' -f [int]$p.done, [int]$p.total) + $at }
        }.GetNewClosure())
    $form.Add_FormClosed({ $timer.Stop(); $timer.Dispose() }.GetNewClosure())

    $begin = {
        param([string] $step)
        $st.Step = $step
        $st.Running = $true
        $status.Text = 'Starting...'
        if ($step -eq 'Preview') {
            $st.PreviewKey = $null; $st.Sheet = $null; $st.ToRemove = 0
            $st.Rows = @(); $st.Unticked.Clear(); $st.ShowingPreview = $false
            & $render
        }
        $listTools.Visible = $false
        & $update
        # The step's own process: until it reports, the timer follows it, however long it takes to start.
        try { $st.Process = & $startFix $st.Folder $step (& $selectedPace).Id | Where-Object { $_ -is [System.Diagnostics.Process] } | Select-Object -First 1 }
        catch {
            $st.Running = $false
            $status.Text = "Couldn't start: $($_.Exception.Message)"
            & $update
            return
        }
        $timer.Start()
    }.GetNewClosure()

    $preview.Add_Click({
            if ($st.Running) {
                # Stop: the background step finishes the file it is on, then stops.
                $null = New-Item -ItemType File -Path (Join-Path $st.Folder 'stop.request') -Force
                $status.Text = 'Stopping...'
                $preview.Enabled = $false
                return
            }
            $sites = @(& $chosenSites)
            if (-not $sites.Count) { return }
            $st.Folder = New-CrFix -ResultsRoot $resultsRoot -Tenant $tenant -Sites $sites -Options (& $readOptions)
            $st.Key = & $currentKey
            & $begin 'Preview'
        }.GetNewClosure())

    $remove.Add_Click({
            $going = @($st.Rows | Where-Object { $_.remove -and -not $st.Unticked.Contains((Get-CrLinkKey $_)) })
            if (-not $going.Count) { return }
            $siteCount = @($going | ForEach-Object site | Select-Object -Unique).Count
            $what = if ($going.Count -eq 1) { '1 sharing link' } else { '{0:N0} sharing links' -f $going.Count }
            $where = if ($siteCount -eq 1) { '1 site' } else { '{0:N0} sites' -f $siteCount }
            $left = if ($st.Unticked.Count) { " The $($st.Unticked.Count) you unticked are left as they are." } else { '' }
            $answer = [System.Windows.Forms.MessageBox]::Show($form,
                "Remove $what from $($where)? These are the links ticked in the preview.$left Anyone using them loses access straight away, and this can't be undone.",
                'Remove sharing links', 'YesNo', 'Warning', 'Button2')
            if ($answer -ne 'Yes') { return }
            # The background step reads which links to leave alone from the fix's folder.
            Write-CrJson (Join-Path $st.Folder 'skip.json') @($st.Unticked)
            & $begin 'Remove'
        }.GetNewClosure())

    # Each line of the list as it is drawn: the row it shows (View.Order), its words, and its tick box.
    $results.Add_RetrieveVirtualItem({
            param($sender, $e)
            $i = $view.Order[$e.ItemIndex]
            $what = & $whatOf $i
            $cells = [string[]]$prep.Cells[$i].Clone()
            $cells[0] = $what
            $item = [System.Windows.Forms.ListViewItem]::new($cells)
            if ($st.ShowingPreview) { $item.Checked = $what -eq 'Will be removed' }
            if ($what -like 'Keep*' -or $what -eq 'Already gone') { $item.ForeColor = $Muted }
            elseif ($what -like 'Failed*') { $item.ForeColor = $red }
            $e.Item = $item
        }.GetNewClosure())

    # Ticking and unticking links in the preview, by clicking a tick box or pressing Space on the selected
    # lines. Links that stay can't be ticked: change the choices and preview again for those.
    $toggle = {
        param([int[]] $lines)
        if (-not $st.ShowingPreview -or $st.Running -or $st.Removed) { return }
        foreach ($line in $lines) {
            $i = $view.Order[$line]
            if (-not $st.Rows[$i].remove) { continue }
            $key = $prep.Keys[$i]
            if (-not $st.Unticked.Remove($key)) { [void]$st.Unticked.Add($key) }
            $results.RedrawItems($line, $line, $false)
        }
        & $update
    }.GetNewClosure()
    # A quick second click on a box arrives as a double click, not a click, so both count.
    $onBoxClick = {
        param($sender, $e)
        $hit = $results.HitTest($e.Location)
        if ($hit.Item -and $hit.Location -eq [System.Windows.Forms.ListViewHitTestLocations]::StateImage) { & $toggle @($hit.Item.Index) }
    }.GetNewClosure()
    $results.Add_MouseClick($onBoxClick)
    $results.Add_MouseDoubleClick($onBoxClick)
    $results.Add_KeyDown({
            param($sender, $e)
            if ($e.KeyCode -ne 'Space') { return }
            & $toggle ([int[]]@($results.SelectedIndices))
            $e.Handled = $true
            $e.SuppressKeyPress = $true
        }.GetNewClosure())
    $hideKept.Add_CheckedChanged({ & $render }.GetNewClosure())
    $tickAllLinks.Add_LinkClicked({ $st.Unticked.Clear(); & $render; & $update }.GetNewClosure())
    $results.Add_ColumnClick({
            param($sender, $e)
            if ($st.SortColumn -eq $e.Column) { $st.SortDescending = -not $st.SortDescending }
            else { $st.SortColumn = $e.Column; $st.SortDescending = $false }
            & $render
        }.GetNewClosure())
    $untickAllLinks.Add_LinkClicked({
            foreach ($r in $st.Rows) { if ($r.remove) { [void]$st.Unticked.Add((Get-CrLinkKey $r)) } }
            & $render; & $update
        }.GetNewClosure())

    $openSheet.Add_Click({ if ($st.Sheet -and (Test-Path -LiteralPath $st.Sheet)) { Start-Process $st.Sheet } }.GetNewClosure())
    $openFolder.Add_Click({ if ($st.Folder) { Start-Process explorer.exe -ArgumentList "`"$($st.Folder)`"" } }.GetNewClosure())

    # A hidden site that's still ticked would be previewed without anyone seeing it, so a kind of
    # site can't be hidden while any of its sites are ticked.
    foreach ($b in $placeBoxes.Values) {
        $b.Add_CheckedChanged({
                param($sender)
                if ($st.PuttingBoxBack) { return }
                if (-not $sender.Checked) {
                    $kind = "$($sender.Tag)"
                    $ticked = Get-CrTickedInPlace -Chosen @($chosen) -PlaceOf $placeOf -Place $kind
                    if ($ticked) {
                        $st.PuttingBoxBack = $true
                        try { $sender.Checked = $true } finally { $st.PuttingBoxBack = $false }
                        $word = $placeWords[$kind]
                        $sites = if ($ticked -eq 1) { '1 site is' } else { '{0:N0} sites are' -f $ticked }
                        $them = if ($ticked -eq 1) { 'it' } else { 'them' }
                        [void][System.Windows.Forms.MessageBox]::Show($form,
                            "$sites still ticked under $word, so $word can't be hidden. A hidden site would still be included in the preview.`n`nUntick $them first, or press Clear to untick everything.",
                            'Sites still ticked', 'OK', 'Warning')
                        return
                    }
                }
                & $fill
                & $update
            }.GetNewClosure())
    }
    # The list is filled again once typing pauses, not on every key: with thousands of sites each fill takes a moment.
    $searchPause = [System.Windows.Forms.Timer]@{ Interval = 300 }
    $searchPause.Add_Tick({ $searchPause.Stop(); & $fill; & $update }.GetNewClosure())
    $search.Add_TextChanged({ $searchPause.Stop(); $searchPause.Start() }.GetNewClosure())
    $form.Add_FormClosed({ $searchPause.Stop(); $searchPause.Dispose() }.GetNewClosure())
    $siteTick.Handler = [System.Windows.Forms.ItemCheckEventHandler]{
        param($sender, $e)
        if ($st.Filling) { return }
        $url = $shown[$e.Index]
        if ($e.NewValue -eq 'Checked') { [void]$chosen.Add($url) } else { [void]$chosen.Remove($url) }
        $st.ChosenVersion++
        # ItemCheck fires before the tick changes, so count after it has.
        $form.BeginInvoke([Action]{ & $update }) | Out-Null
    }.GetNewClosure()
    $list.Add_ItemCheck($siteTick.Handler)
    # Check all and Clear act on what the search box says now, even if typing paused only a moment ago.
    $searchNow = { if ($searchPause.Enabled) { $searchPause.Stop(); & $fill } }.GetNewClosure()
    $tickShown.Add_LinkClicked({ & $searchNow; foreach ($url in $matching) { [void]$chosen.Add($url) }; $st.ChosenVersion++; & $fill; & $update }.GetNewClosure())
    $clearAll.Add_LinkClicked({ & $searchNow; $chosen.Clear(); $st.ChosenVersion++; & $fill; & $update }.GetNewClosure())
    foreach ($r in @($linkBoxes.Values) + $ageRadios) { $r.Add_CheckedChanged({ & $update }.GetNewClosure()) }
    $days.Add_ValueChanged({ & $update }.GetNewClosure())
    $fullCheck.Add_CheckedChanged({ & $update }.GetNewClosure())
    foreach ($r in $paceRadios.Values) {
        $r.Add_CheckedChanged({
                param($sender)
                if (-not $sender.Checked -or -not $st.Running -or -not $st.Folder) { return }
                # The running step picks this up within a couple of seconds.
                try { Set-Content -LiteralPath (Join-Path $st.Folder 'pace.request') -Value $sender.Tag -Encoding utf8 } catch { }
            }.GetNewClosure())
    }
    $beforeDate.Add_ValueChanged({ & $update }.GetNewClosure())

    # The latest fix of this tenant comes back when the window opens, with its choices and sites:
    # one still running is followed again, a finished preview whose links haven't been removed
    # is shown again, so Remove can be pressed without previewing a big OneDrive all over, and a
    # Remove that was cut off shows what it did before it stopped.
    $latest = Get-CrLatestFix -ResultsRoot $resultsRoot -Tenant $tenant
    if ($latest -and ($latest.Running -or $latest.Previewed -or $latest.Interrupted)) {
        try {
            $fix = Read-CrJson (Join-Path $latest.Folder 'fix.json')
            foreach ($s in $fix.sites) { [void]$chosen.Add($s.url) }
            $st.ChosenVersion++
            foreach ($type in $linkBoxes.Keys) { $linkBoxes[$type].Checked = @($fix.options.links) -contains $type }
            switch ($fix.options.age) {
                'Any' { $anyAge.Checked = $true }
                'Before' { $beforeDate.Value = [DateTime]::ParseExact($fix.options.before, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture); $before.Checked = $true }
                default { $days.Value = [Math]::Max(1, [int]$fix.options.days); $older.Checked = $true }
            }
            $st.Folder = $latest.Folder
            $st.Step = $latest.Step
            $st.Key = & $currentKey
            # Links unticked before Remove was pressed (it saved them in skip.json) stay unticked.
            $restoreUnticked = {
                $skipFile = Join-Path $st.Folder 'skip.json'
                if (Test-Path -LiteralPath $skipFile) { foreach ($k in @(Read-CrJson $skipFile)) { if ($k) { [void]$st.Unticked.Add("$k") } } }
            }
            if ($latest.Running) {
                if ($st.Step -eq 'Remove') {
                    # The preview it is removing from, so that if it ends without removing anything, Remove can be pressed again.
                    $links = @((Read-CrJson (Join-Path $st.Folder 'preview.json')).links)
                    $st.Rows = $links
                    $st.ToRemove = @($links | Where-Object remove).Count
                    $st.PreviewKey = $st.Key
                    $st.Sheet = Join-Path $st.Folder 'preview.csv'
                    $st.ShowingPreview = $true
                    $results.CheckBoxes = $true
                    & $restoreUnticked
                    & $render
                }
                $st.Running = $true
                $timer.Start()
            }
            elseif ($latest.Interrupted) {
                # Cut off without ending (the PC restarted, say): what its journal says it did, link by link.
                $links = @(Read-CrRemoveJournal $st.Folder)
                $st.Removed = $true
                $st.ShowingPreview = $false
                $st.Rows = $links
                $results.CheckBoxes = $false
                & $render
                $removedN = @($links | Where-Object result -EQ 'Removed').Count
                $goneN = @($links | Where-Object result -EQ 'Already gone').Count
                $failedN = @($links | Where-Object { "$($_.result)" -like 'Failed*' }).Count
                $status.Text = ("Your last Remove was cut off before it finished (the PC restarted or the program was closed, say). Before that: {0:N0} removed, {1:N0} already gone, {2:N0} failed; the list shows each. " +
                    'The links it didn''t get to were left as they were: press Preview to find them again.') -f $removedN, $goneN, $failedN
            }
            else {
                # Shown as the finished preview it is, even when a Remove was tried after it and stopped before removing anything.
                $shownAs = if ($latest.Progress.step -eq 'Preview') { $latest.Progress } else { [pscustomobject]@{ step = 'Preview'; state = 'Completed'; problems = @() } }
                & $showDone $shownAs
                & $restoreUnticked
                & $render
                $made = $latest.PreviewedAt.ToLocalTime().ToString('MMMM d, h:mm tt')
                $tried = if ($latest.RemoveProblem) { " Remove was pressed but didn't start ($($latest.RemoveProblem)); nothing was removed." } else { '' }
                $kept = if ($st.Unticked.Count) { " The $($st.Unticked.Count) link(s) you unticked are still unticked." } else { '' }
                $status.Text = "Your last preview, from $made.$tried$kept $($status.Text -replace '^Preview done: ', '')"
            }
        }
        catch { }
    }

    & $fill
    & $update
    $page
}
