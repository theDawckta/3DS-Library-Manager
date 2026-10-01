# Runs every self-contained regression suite.  Tests that need real ROM/CIA
# assets and the toolchain are skipped unless their paths are supplied.
[CmdletBinding()]
param(
    [string]$CtrToolPath,
    [string]$Test3dsPath,
    [string]$TestCiaPath
)
$ErrorActionPreference = 'Continue'
# Every suite runs against a throwaway state folder, never the app's real saved state.
if (-not $env:THREEDS_MANAGER_DATA_ROOT) {
    $env:THREEDS_MANAGER_DATA_ROOT = Join-Path $env:TEMP ('BackupsNew3DS.Tests.' + [guid]::NewGuid().ToString('N'))
}

$selfContained = @(
    'test-aggregation.ps1'
    'test-sd-lifecycle.ps1'
    'test-installed-inventory.ps1'
    'test-safe-eject.ps1'
    'test-safe-target.ps1'
    'test-staging.ps1'
    'test-batch-return.ps1'
    'test-return-flow.ps1'
    'test-add-to-sd.ps1'
    'test-multiple-cards.ps1'
    'test-space-chart.ps1'
    'test-guided-workflow.ps1'
    'test-preparation-failures.ps1'
    'test-static-audit.ps1'
)

$results = @()
foreach ($name in $selfContained) {
    $path = Join-Path $PSScriptRoot $name
    if (-not (Test-Path -LiteralPath $path)) {
        $results += [pscustomobject]@{ Test=$name; Result='MISSING'; Detail='File not found' }
        continue
    }
    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $path 2>&1 | Out-String
    $results += [pscustomobject]@{
        Test = $name
        Result = if ($LASTEXITCODE -eq 0) { 'PASS' } else { 'FAIL' }
        Detail = if ($LASTEXITCODE -eq 0) { '' } else { ($output -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 3) -join ' ' }
    }
}

# Batman conversion/validation regression needs the real proven source and CIA.
$corePath = Join-Path $PSScriptRoot 'test-library-core.ps1'
if ($CtrToolPath -and $Test3dsPath -and $TestCiaPath) {
    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $corePath `
        -CtrToolPath $CtrToolPath -Test3dsPath $Test3dsPath -TestCiaPath $TestCiaPath 2>&1 | Out-String
    $results += [pscustomobject]@{
        Test = 'test-library-core.ps1'
        Result = if ($LASTEXITCODE -eq 0) { 'PASS' } else { 'FAIL' }
        Detail = if ($LASTEXITCODE -eq 0) { 'Batman conversion/validation regression' } else { ($output -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 3) -join ' ' }
    }
}
else {
    $results += [pscustomobject]@{
        Test = 'test-library-core.ps1'; Result='SKIPPED'
        Detail='Supply -CtrToolPath, -Test3dsPath and -TestCiaPath to run the Batman regression.'
    }
}

$results | Format-Table -AutoSize
$failed = @($results | Where-Object Result -in @('FAIL','MISSING'))
$passed = @($results | Where-Object Result -eq 'PASS')
$skipped = @($results | Where-Object Result -eq 'SKIPPED')
Write-Output ''
Write-Output ("Total {0}: {1} passed, {2} failed, {3} skipped." -f $results.Count, $passed.Count, $failed.Count, $skipped.Count)
if ($failed.Count) { exit 1 }
exit 0
