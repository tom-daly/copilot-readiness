<#
.SYNOPSIS
  Runs every shared rule case (rules/cases.json) against the PowerShell rules.

.DESCRIPTION
  Passing means the rules find what the rule book says and give the expected ids.
  Exits 1 if any case fails.

.EXAMPLE
  pwsh -File pnp/tests/Test-RuleCases.ps1
#>
param(
    [string] $CasesPath = (Join-Path $PSScriptRoot '..\..\rules\cases.json')
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\CopilotReadiness\CopilotReadiness.psm1') -Force

$cases = Get-Content -LiteralPath $CasesPath -Raw -Encoding utf8 | ConvertFrom-Json -DateKind String
$site = $cases.site
$now = [DateTimeOffset]::Parse($cases.now, [Globalization.CultureInfo]::InvariantCulture)
$fields = 'id', 'check', 'rule', 'severity', 'objectType', 'path', 'principal', 'principalLogin', 'permission', 'detail'

$script:passed = 0
$script:failures = [System.Collections.Generic.List[string]]::new()

function Assert-Case {
    param([string] $Name, [scriptblock] $Test)
    try {
        $problem = & $Test
        if ($problem) { $script:failures.Add("$Name`n    $($problem -join "`n    ")") } else { $script:passed++ }
    }
    catch {
        $script:failures.Add("$Name`n    threw: $($_.Exception.Message)")
    }
}

function Compare-Findings {
    param([object[]] $Expected, [object[]] $Actual)
    $Expected = @($Expected | Where-Object { $null -ne $_ })
    $Actual = @($Actual | Where-Object { $null -ne $_ })
    if ($Expected.Count -ne $Actual.Count) {
        return "expected $($Expected.Count) findings, got $($Actual.Count): $(($Actual | ForEach-Object { "$($_.rule)/$($_.principal)" }) -join ', ')"
    }
    for ($i = 0; $i -lt $Expected.Count; $i++) {
        foreach ($f in $fields) {
            $e = $Expected[$i].$f
            $a = $Actual[$i].$f
            if ($f -eq 'id' -and $null -eq $e) { continue }
            if ("$e" -cne "$a" -or (($null -eq $e) -ne ($null -eq $a))) { return "finding $i ${f}: expected '$e', got '$a'" }
        }
        if ($Actual[$i].siteId -cne $site.siteId -or $Actual[$i].siteUrl -cne $site.url) { return "finding $i has the wrong site" }
    }
}

foreach ($c in $cases.principals) {
    Assert-Case "principal $($c.login) / $($c.title)" {
        $kind = Get-CrPrincipalKind $c.login $c.title $c.principalType
        if ($kind -cne $c.kind) { "expected $($c.kind), got $kind" }
    }
}

foreach ($c in $cases.guestEmails) {
    Assert-Case "guest email $($c.login)" {
        $email = Get-CrGuestEmail $c.login
        if ($email -cne $c.email) { "expected $($c.email), got $email" }
    }
}

foreach ($c in $cases.groupIds) {
    Assert-Case "group id $($c.login)" {
        $id = Get-CrAadGroupId $c.login
        if ("$id" -cne "$($c.groupId)") { "expected '$($c.groupId)', got '$id'" }
    }
}

foreach ($c in $cases.grants) {
    Assert-Case "grants: $($c.name)" {
        $groups = @{}
        if ($c.groups) { foreach ($p in $c.groups.PSObject.Properties) { $groups[[int]$p.Name] = $p.Value } }
        $actual = @(Get-CrGrantFindings -Site $site -ObjectType $c.object.objectType -Path $c.object.path -Assignments $c.assignments `
                -Scope $c.scope -Groups $groups -OwnersGroupId $c.ownersGroupId -SiteGroupId $c.siteGroupId -Now $now)
        Compare-Findings $c.expect $actual
    }
}

foreach ($c in $cases.siteFacts) {
    Assert-Case "site facts: $($c.name)" {
        Compare-Findings $c.expect @(Get-CrSiteFindings -Site $site -Facts $c.facts -StaleDays $c.staleDays -Now $now)
    }
}

foreach ($c in $cases.libraryTotals) {
    Assert-Case "library totals: $($c.name)" {
        $actual = if ($c.rule -eq 'BrokenInheritance') { Get-CrBrokenInheritanceFinding $site $c.path $c.count $now }
        else { Get-CrFilesUnlabeledFinding $site $c.path $c.count $c.files $now }
        Compare-Findings @($c.expect) @($actual)
    }
}

foreach ($c in $cases.siteScores) {
    Assert-Case "site score: $($c.name)" {
        $totals = @{}
        foreach ($p in $c.counts.PSObject.Properties) { $totals[$p.Name] = $p.Value }
        $score = Get-CrSiteScore $totals
        if ($score -ne $c.score) { "expected $($c.score), got $score" }
    }
}

foreach ($c in $cases.tenantScores) {
    Assert-Case "tenant score: $($c.name)" {
        $score = Get-CrTenantScore @($c.scores)
        if ("$score" -ne "$($c.score)") { "expected '$($c.score)', got '$score'" }
    }
}

foreach ($c in $cases.setAside) {
    Assert-Case "set aside: $($c.name)" {
        $found = (Get-CrSetAside $c.webTemplate).id
        if ("$found" -ne "$($c.expect)") { "expected '$($c.expect)', got '$found'" }
    }
}

# Every rule names a check and severities the rule book knows.
$book = Get-CrRuleBook
foreach ($r in $book.rules) {
    Assert-Case "rule book: $($r.id)" {
        if ($book.checks.id -notcontains $r.check) { "unknown check '$($r.check)'" }
        if ($book.severities -notcontains $r.severity) { "unknown severity '$($r.severity)'" }
        if ($r.severityWhenCanEdit -and $book.severities -notcontains $r.severityWhenCanEdit) { "unknown severity '$($r.severityWhenCanEdit)'" }
    }
}

if ($script:failures.Count) {
    Write-Host "$($script:failures.Count) failed, $script:passed passed" -ForegroundColor Red
    $script:failures | ForEach-Object { Write-Host "  FAIL $_" }
    exit 1
}
Write-Host "All $script:passed rule cases passed" -ForegroundColor Green
