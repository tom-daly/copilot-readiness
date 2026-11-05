# Copilot Readiness: a scan of a Microsoft 365 tenant, run with PnP PowerShell from an
# admin's own PC. Rules.ps1 holds the rules; Settings.ps1 reads settings.json;
# SystemCheck.ps1 checks the PC before starting; TenantSettings.ps1 reads the tenant's sharing and Copilot settings; Http.ps1 talks to SharePoint and
# Graph; Scan.ps1 walks the tenant; Report.ps1 writes the results; CheckWindow.ps1
# shows the system check; ControlWindow.ps1 is the window that starts a scan;
# ProgressWindow.ps1 shows a scan running in the background; ActivityWindow.ps1 shows
# what the script prints while it sets up and signs in.

foreach ($part in 'Rules', 'Settings', 'SystemCheck', 'TenantSettings', 'Http', 'Scan', 'Report', 'CheckWindow', 'ControlWindow', 'ProgressWindow', 'ActivityWindow') {
    $file = Join-Path $PSScriptRoot "$part.ps1"
    if (Test-Path -LiteralPath $file) { . $file }
}

Export-ModuleMember -Function *-Cr*
