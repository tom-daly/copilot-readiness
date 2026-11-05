<#
.SYNOPSIS
  Runs every test of the scan. Exits 1 if any fail.

.EXAMPLE
  pwsh -File pnp/tests/Invoke-AllTests.ps1
#>
$failed = @()
foreach ($test in Get-ChildItem -LiteralPath $PSScriptRoot -Filter 'Test-*.ps1') {
    & pwsh -NoProfile -File $test.FullName
    if ($LASTEXITCODE) { $failed += $test.Name }
}
if ($failed) {
    Write-Host "Failed: $($failed -join ', ')" -ForegroundColor Red
    exit 1
}
Write-Host 'All tests passed' -ForegroundColor Green
