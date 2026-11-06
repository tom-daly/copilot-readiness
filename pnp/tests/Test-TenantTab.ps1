<#
.SYNOPSIS
  The Tenant tab's buttons, pressed in the real window with made-up settings. The window can't be
  seen, and nothing signs in. The buttons' code runs long after the window is built, so only
  pressing them shows it works. Exits 1 if anything is off.

.EXAMPLE
  pwsh -File pnp/tests/Test-TenantTab.ps1
#>
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\CopilotReadiness\CopilotReadiness.psm1') -Force
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

$problems = [System.Collections.Generic.List[string]]::new()
function Check([string] $Name, [bool] $Ok) { if (-not $Ok) { $problems.Add($Name) } }
function Pump([int] $Ms = 150) {
    $until = [DateTime]::UtcNow.AddMilliseconds($Ms)
    while ([DateTime]::UtcNow -lt $until) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 10 }
}
function Find-All($Parent, [scriptblock] $Test) { foreach ($c in $Parent.Controls) { if (& $Test $c) { $c }; Find-All $c $Test } }
function Showing($Page, [string] $Text) { @(Find-All $Page { param($c) $c.Text -eq $Text -and $c.Visible }) }
function Code($Page) { @(Find-All $Page { param($c) $c -is [System.Windows.Forms.RichTextBox] -and $c.Visible }) }

$sharePoint = 'https://contoso.sharepoint.com'
$values = [ordered]@{
    SharingCapability = 'ExternalUserAndGuestSharing'; OneDriveSharingCapability = 'ExternalUserSharingOnly'; ODBMembersCanShare = 'On'
    DefaultSharingLinkType = 'Internal'; CoreDefaultShareLinkScope = 'Uninitialized'; OneDriveDefaultShareLinkScope = 'Organization'
    CoreOrganizationSharingLinkMaxExpirationInDays = 30; OneDriveOrganizationSharingLinkMaxExpirationInDays = 0
    ExternalUserExpirationRequired = $false; ExternalUserExpireInDays = 60; ShowEveryoneExceptExternalUsersClaim = $true; RestrictedSearchMode = 'Enabled'
}
$view = Get-CrTenantSettingsView $values -SharePointUrl $sharePoint
# The first card with a picture has a damaged one.
$damaged = Join-Path ([IO.Path]::GetTempPath()) "cr-damaged-$PID.png"
Set-Content -LiteralPath $damaged -Value 'not a picture'
@($view | ForEach-Object Rows | Where-Object Picture)[0].Picture = $damaged

$form = $null
try {
    $sites = @([pscustomobject]@{ siteId = '1'; url = "$sharePoint/sites/a"; title = 'A'; kind = 'SharePoint'; teams = $null })
    $form = New-CrControlForm -Sites $sites -TenantName 'contoso.onmicrosoft.com' -SharePointUrl $sharePoint -PastScans @() -TenantSettings $view -TenantSettingsRead ([pscustomobject]@{ ReadAt = [DateTimeOffset]::UtcNow; Problem = $null })
    $form.Opacity = 0
    $form.ShowInTaskbar = $false
    $form.Show(); Pump 300
    $allTabs = @(Find-All $form { param($c) $c -is [System.Windows.Forms.TabControl] })
    $tabs = $allTabs[0]; $groups = $allTabs[1]
    $tabs.SelectedTab = $tabs.TabPages | Where-Object Text -Like 'Tenant*'; Pump

    Check 'the settings are on a tab for each group, saying how many to change' ((@($groups.TabPages | ForEach-Object Text) -join '|') -match '^Who can share: 2 to change\|Links: \d to change\|Guests: 1 to change\|Copilot and search: 1 to change$')
    Check 'nothing behind Show more is made until it is pressed' (-not @(Find-All $form { param($c) $c -is [System.Windows.Forms.RichTextBox] }).Count)

    # Show more, with a damaged picture: the card still opens, without it.
    $groups.SelectedIndex = 0; Pump
    $page = $groups.SelectedTab
    $more = Showing $page 'Show more'
    Check 'each card has Show more' ($more.Count -eq 3)
    $more[0].PerformClick(); Pump
    Check 'a damaged picture leaves the rest of the card showing' ((Showing $page "Microsoft's guide").Count -eq 1 -and -not (Showing $page 'Show me').Count -and $more[0].Text -eq 'Show less')
    $more[0].PerformClick(); Pump
    Check 'Show less folds it again' ($more[0].Text -eq 'Show more' -and -not (Showing $page "Microsoft's guide").Count)
    $more[0].PerformClick(); Pump
    Check 'and opening it again doesn''t make it twice' ((Showing $page "Microsoft's guide").Count -eq 1)
    $more[0].PerformClick(); Pump

    # The OneDrive resharing card: PowerShell, PnP first.
    $reshare = @($more | Where-Object { $_.Parent.Controls[0].Text -like 'People with edit*' })[0]
    $reshare.PerformClick(); Pump
    Check 'commands stay folded until PowerShell is pressed' (-not (Code $page).Count)
    $powerShell = (Showing $page 'PowerShell')[0]
    $powerShell.PerformClick(); Pump
    $first = (Code $page)[0]
    Check 'PowerShell opens the PnP commands first' ($first.Text -like 'Connect-PnPOnline*' -and (Showing $page 'Set up a PnP client ID').Count -eq 1)
    $colours = @(foreach ($i in 0, $first.Text.IndexOf('#')) { $first.Select($i, 1); $first.SelectionColor.ToArgb() })
    Check 'the code is coloured, on black' ($colours[0] -ne $colours[1] -and $first.BackColor.R -lt 40)

    if ([Threading.Thread]::CurrentThread.ApartmentState -eq 'STA') {
        $copy = (Showing $page 'Copy')[0]
        $copy.PerformClick(); Pump
        $copied = [System.Windows.Forms.Clipboard]::GetText()
        Check 'Copy copies the commands, with undo as a note' ($copy.Text -eq 'Copied' -and $copied -match '(?m)^Set-PnPTenant -ODBMembersCanShare Off' -and $copied -match '(?m)^# Set-PnPTenant -ODBMembersCanShare On')
        Pump 2800
        Check 'and the button goes back to Copy' ($copy.Text -eq 'Copy')
    }

    # Choosing SPO on one card moves every card, on every tab, including ones not opened yet.
    $groups.SelectedIndex = 3; Pump
    $other = $groups.SelectedTab
    (Showing $other 'Show more')[0].PerformClick(); Pump
    (Showing $other 'PowerShell')[0].PerformClick(); Pump
    Check 'another card starts on the same choice' ((Code $other)[0].Text -like 'Connect-PnPOnline*')
    (@(Find-All $other { param($c) $c -is [System.Windows.Forms.RadioButton] -and $c.Text -eq 'SPO' -and $c.Visible }))[0].Checked = $true; Pump
    Check 'choosing SPO shows SPO, with no client ID button' ((Code $other)[0].Text -like 'Connect-SPOService*' -and -not (Showing $other 'Set up a PnP client ID').Count)
    $groups.SelectedIndex = 0; Pump
    Check 'the card on the other tab follows' ((Code $page)[0].Text -like 'Connect-SPOService*' -and -not (Showing $page 'Set up a PnP client ID').Count)
    Check 'and its choice shows it' (@(Find-All $page { param($c) $c -is [System.Windows.Forms.RadioButton] -and $c.Text -eq 'SPO' -and $c.Checked -and $c.Visible }).Count -eq 1)
    $powerShell.PerformClick(); Pump
    Check 'PowerShell folds the commands again' (-not (Code $page).Count)

    # The choice lasts when the window is built again, as it is after Refresh, and so does the group.
    Check 'the choice is kept for the next window' ((Get-CrCommandTool) -eq 'SPO')
    $groups.SelectedIndex = 2; Pump
    $refresh = (Showing $form 'Refresh')[0]
    $refresh.PerformClick(); Pump
    Check 'Refresh says which group was showing' ($form.Tag.Action -eq 'RefreshTenant' -and $form.Tag.Group -eq 'Guests')
    $form.Dispose()
    $form = New-CrControlForm -Sites $sites -TenantName 'contoso.onmicrosoft.com' -SharePointUrl $sharePoint -PastScans @() -TenantSettings $view -TenantSettingsRead ([pscustomobject]@{ ReadAt = [DateTimeOffset]::UtcNow; Problem = $null }) -StartTab 'Tenant' -StartGroup 'Guests'
    $form.Opacity = 0
    $form.ShowInTaskbar = $false
    $form.Show(); Pump 300
    $allTabs = @(Find-All $form { param($c) $c -is [System.Windows.Forms.TabControl] })
    $tabs = $allTabs[0]; $groups = $allTabs[1]
    Check 'after Refresh it opens on the same group' ($tabs.SelectedTab.Text -eq 'Tenant' -and $groups.SelectedTab.Tag -eq 'Guests')
    $groups.SelectedIndex = 3; Pump
    (Showing $groups.SelectedTab 'Show more')[0].PerformClick(); Pump
    (Showing $groups.SelectedTab 'PowerShell')[0].PerformClick(); Pump
    Check 'a card opened in the new window is on SPO' ((Code $groups.SelectedTab)[0].Text -like 'Connect-SPOService*')

    # A setting that's already right has no commands to offer.
    $groups.SelectedIndex = 1; Pump
    $links = $groups.SelectedTab
    $expiry = @(Showing $links 'Show more' | Where-Object { $_.Parent.Controls[0].Text -eq 'Company-wide links expire' })[0]
    $expiry.PerformClick(); Pump
    Check 'links already expiring in 30 days offer no PowerShell' (-not (Showing $expiry.Parent 'PowerShell').Count)

    # Going back to an earlier width measures again.
    $form.WindowState = 'Normal'; Pump
    $sized = { param($w) $form.Width = $w; Pump; $null = $form.GetType().GetMethod('OnResizeEnd', [Reflection.BindingFlags]'NonPublic,Instance').Invoke($form, [object[]]@(, [EventArgs]::Empty)); Pump; @(Find-All $links { param($c) $c -is [System.Windows.Forms.Label] -and $c.Tag -eq 'rest' -and $c.Visible })[0].MaximumSize.Width }
    $a = & $sized 1000; $b = & $sized 1400; $c = & $sized 1000
    Check "text follows the window, back to an earlier width too (got $a, $b, $c)" ($b -gt $a -and $c -eq $a)
}
catch { $problems.Add("threw: $($_.Exception.Message) at $($_.InvocationInfo.PositionMessage)") }
finally {
    if ($form) { $form.Close(); $form.Dispose() }
    Remove-Item -LiteralPath $damaged -ErrorAction SilentlyContinue
}

# With nothing to change, a group is still chosen, so the tab is measured before it's opened.
$allGood = Get-CrTenantSettingsView ([ordered]@{ SharingCapability = 'Disabled'; OneDriveSharingCapability = 'Disabled'; ShowEveryoneClaim = $false }) -SharePointUrl $sharePoint
$goodForm = New-CrControlForm -Sites @([pscustomobject]@{ siteId = '1'; url = "$sharePoint/sites/a"; title = 'A'; kind = 'SharePoint'; teams = $null }) -TenantName 'contoso.onmicrosoft.com' -SharePointUrl $sharePoint -PastScans @() -TenantSettings $allGood -TenantSettingsRead ([pscustomobject]@{ ReadAt = [DateTimeOffset]::UtcNow; Problem = $null })
$goodTabs = @(Find-All $goodForm { param($c) $c -is [System.Windows.Forms.TabControl] })[1]
Check 'with nothing to change, the first group is still chosen' ($goodTabs.SelectedIndex -eq 0)
$goodForm.Dispose()

# A past scan that can't be continued says why when it's picked.
$note = "This scan started under an older version's rules, so it can't be continued. Start a new scan."
$past = @(
    [pscustomobject]@{ Folder = 'x'; StartedAt = [DateTimeOffset]::UtcNow; Level = 'Quick'; Include = 'SharePoint'; Total = 5; Done = 2; State = 'OlderRules'; Score = $null; OneDriveScore = $null; Findings = $null; Report = $null; RulesNote = $note }
    [pscustomobject]@{ Folder = 'y'; StartedAt = [DateTimeOffset]::UtcNow; Level = 'Quick'; Include = 'SharePoint'; Total = 5; Done = 2; State = 'Stopped'; Score = $null; OneDriveScore = $null; Findings = $null; Report = $null; RulesNote = $null }
)
$pastForm = New-CrControlForm -Sites @([pscustomobject]@{ siteId = '1'; url = "$sharePoint/sites/a"; title = 'A'; kind = 'SharePoint'; teams = $null }) -TenantName 'contoso.onmicrosoft.com' -SharePointUrl $sharePoint -PastScans $past -StartTab 'Past scans'
$pastForm.Opacity = 0; $pastForm.ShowInTaskbar = $false
$pastForm.Show(); Pump 300
$pastList = @(Find-All $pastForm { param($c) $c -is [System.Windows.Forms.ListView] -and $c.Visible })[0]
$pastList.Items[0].Selected = $true; Pump
Check 'picking a scan under other rules says why, and Continue is off' ((Showing $pastForm $note).Count -eq 1 -and -not (Showing $pastForm 'Continue scan')[0].Enabled)
$pastList.Items[0].Selected = $false; $pastList.Items[1].Selected = $true; Pump
Check 'picking one that can continue goes back' (-not (Showing $pastForm $note).Count -and (Showing $pastForm 'Continue scan')[0].Enabled)
$pastForm.Close(); $pastForm.Dispose()

# The question about results that can't be found, with an & in the path.
$ask = New-CrMissingResultsForm -Folder 'D:\R&D\results'
$ask.Opacity = 0; $ask.ShowInTaskbar = $false
$ask.Show(); Pump
Check 'an & in the folder shows as itself' (@(Find-All $ask { param($c) $c -is [System.Windows.Forms.Label] -and $c.Text -like '*R&D*' -and -not $c.UseMnemonic }).Count -eq 1)
Check 'closing it without choosing means stop' ($ask.Tag -eq 'Stop')
@(Find-All $ask { param($c) $c.Text -eq 'Start a new results folder' })[0].PerformClick(); Pump
Check 'the button says what was chosen' ($ask.Tag -eq 'New')
$ask.Dispose()

if ($problems.Count) {
    Write-Host "$($problems.Count) Tenant tab checks failed" -ForegroundColor Red
    $problems | ForEach-Object { Write-Host "  FAIL $_" -ForegroundColor Red }
    exit 1
}
Write-Host 'Tenant tab checks passed' -ForegroundColor Green
