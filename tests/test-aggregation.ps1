# Regression coverage for the zero-item aggregate failure.
#
# Windows PowerShell 5.1 emits NO object from `Measure-Object -Property X -Sum`
# when the pipeline is empty, so `(... | Measure-Object X -Sum).Sum` dereferences
# $null and throws PropertyNotFoundException under Set-StrictMode.  Every aggregate
# total in this project must survive zero, one, and many items.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\ThreeDSLibrary.Core.psm1') -Force -DisableNameChecking

function Assert-Equal($Expected, $Actual, [string]$Message) {
    if ($Expected -ne $Actual) { throw "$Message Expected '$Expected'; got '$Actual'." }
}
function Assert-Throws([scriptblock]$Action, [string]$Message) {
    $threw = $false
    try { & $Action } catch { $threw = $true }
    if (-not $threw) { throw $Message }
}
function New-Items([int]$Count, [string]$Property = 'Length') {
    @(1..$Count | ForEach-Object { [pscustomobject]@{ $Property = [uint64]($_ * 100) } })
}

# --- The exact defect, reproduced against the raw idiom ---------------------
$emptyMeasure = (@() | Measure-Object Length -Sum)
Assert-Equal $true ($null -eq $emptyMeasure) 'Measure-Object -Property on empty input no longer returns $null; the regression premise changed.'
Assert-Throws { [uint64]((@() | Measure-Object Length -Sum).Sum) } 'The original zero-item .Sum idiom no longer throws; the regression premise changed.'

# --- Zero-item aggregation --------------------------------------------------
Assert-Equal ([uint64]0) (Get-ThreeDSByteSum -Items @() -Property 'Length') 'Zero-item aggregation did not return 0.'
Assert-Equal ([uint64]0) (Get-ThreeDSByteSum -Items $null -Property 'Length') 'Null-collection aggregation did not return 0.'
Assert-Equal ([uint64]0) (Get-ThreeDSByteSum -Items @($null, $null) -Property 'Length') 'All-null aggregation did not return 0.'
Assert-Equal ([uint64]0) (Get-ThreeDSByteSum -Items @() -Property 'ArtifactLength') 'Zero-item ArtifactLength aggregation did not return 0.'

# --- One-item aggregation ---------------------------------------------------
Assert-Equal ([uint64]100) (Get-ThreeDSByteSum -Items (New-Items 1) -Property 'Length') 'One-item aggregation mismatch.'
Assert-Equal ([uint64]4096) (Get-ThreeDSByteSum -Items @([pscustomobject]@{ ArtifactLength = [uint64]4096 }) -Property 'ArtifactLength') 'One-item ArtifactLength aggregation mismatch.'

# --- Many-item aggregation --------------------------------------------------
Assert-Equal ([uint64]5500) (Get-ThreeDSByteSum -Items (New-Items 10) -Property 'Length') 'Many-item aggregation mismatch.'
Assert-Equal ([uint64]5500) (Get-ThreeDSByteSum -Items (@(New-Items 10) + @($null)) -Property 'Length') 'Many-item aggregation with a null entry mismatch.'

# --- Large totals must not overflow or go negative --------------------------
$large = @(1..4 | ForEach-Object { [pscustomobject]@{ Length = [uint64]4294967296 } })
Assert-Equal ([uint64]17179869184) (Get-ThreeDSByteSum -Items $large -Property 'Length') '64-bit aggregation mismatch.'

# --- Real object shapes used by the manager ---------------------------------
$fileLike = @(Get-ChildItem -LiteralPath $PSScriptRoot -File | Select-Object -First 3)
$expected = [uint64]0; foreach ($f in $fileLike) { $expected += [uint64]$f.Length }
Assert-Equal $expected (Get-ThreeDSByteSum -Items $fileLike -Property 'Length') 'FileInfo aggregation mismatch.'
Assert-Equal ([uint64]0) (Get-ThreeDSByteSum -Items @(Get-ChildItem -LiteralPath $PSScriptRoot -File -Filter '*.no-such-extension') -Property 'Length') 'Empty Get-ChildItem aggregation did not return 0.'

# --- A missing property is a real error, not a silent zero ------------------
Assert-Throws { Get-ThreeDSByteSum -Items @([pscustomobject]@{ Other = 1 }) -Property 'Length' } 'A missing aggregate property was silently treated as zero.'
Assert-Throws { Get-ThreeDSByteSum -Items @([pscustomobject]@{ Length = $null }) -Property 'Length' } 'A null aggregate property was silently treated as zero.'

# --- No source file may reintroduce the unsafe idiom ------------------------
$scriptRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts'
$offenders = @(Get-ChildItem -LiteralPath $scriptRoot -File -Recurse |
    Where-Object { $_.Extension -in @('.ps1','.psm1') } |
    Select-String -Pattern 'Measure-Object[^\r\n|]*-Sum\s*\)\s*\.Sum' |
    Where-Object { $_.Line -notmatch '^\s*#' } |
    ForEach-Object { "$($_.Filename):$($_.LineNumber)" })
Assert-Equal 0 $offenders.Count ("The unsafe zero-item .Sum idiom reappeared: " + ($offenders -join ', '))

# --- Installed-title aggregation must survive an empty title directory ------
# This is the shape that actually crashed reconciliation: a Title-ID directory
# that exists on the SD card but contains no files.
$emptyTitleDir = Join-Path $env:TEMP ('BackupsNew3DS.Agg.' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $emptyTitleDir -Force | Out-Null
try {
    $files = @(Get-ChildItem -LiteralPath $emptyTitleDir -Recurse -File -Force)
    Assert-Equal 0 $files.Count 'Fixture directory was not empty.'
    Assert-Equal ([uint64]0) (Get-ThreeDSByteSum -Items $files -Property 'Length') 'Empty installed-title directory aggregation did not return 0.'
}
finally { Remove-Item -LiteralPath $emptyTitleDir -Recurse -Force }

# --- The same bug family: member access across an empty collection ----------
# `@($empty.Property)` also throws PropertyNotFoundStrict under Set-StrictMode,
# and reconciliation builds a batch's Types string exactly that way.
$emptyCollection = @()
Assert-Throws { @($emptyCollection.Type) } 'Empty-collection member access no longer throws; the regression premise changed.'
Assert-Equal '' ((@($emptyCollection | ForEach-Object { $_.Type }) | Sort-Object -Unique) -join ', ') 'The safe empty-collection projection did not return an empty string.'
Assert-Equal 'Base' ((@(@([pscustomobject]@{Type='Base'}) | ForEach-Object { $_.Type }) | Sort-Object -Unique) -join ', ') 'The safe one-item projection mismatched.'
Assert-Equal 'Base, DLC' ((@(@([pscustomobject]@{Type='DLC'},[pscustomobject]@{Type='Base'},[pscustomobject]@{Type='Base'}) | ForEach-Object { $_.Type }) | Sort-Object -Unique) -join ', ') 'The safe many-item projection mismatched.'

# A staged batch whose manifest lists no entries must reconcile, not crash.
$emptyBatch = [pscustomobject]@{
    BatchId='Batch 1 of 1 - 0 games - 2026-09-02 12-00-00'; BatchPath='X:\empty'
    ManifestPath='X:\empty\INSTALL-QUEUE.json'; ManifestSHA256=('B'*64); CreatedAt='2026-09-02T12:00:00-07:00'
    BatchGroupId=''; BatchNumber=1; BatchCount=1; Items=@(); ItemCount=0
    Types=(@(@() | ForEach-Object { $_.Type }) -join ', '); Integrity='Metadata verified'; Issues=@()
    State='Staged on SD'; CleanupEligible=$false; InstalledCount=0; RemainingCount=0
    InstalledItems=@(); RemainingItems=@(); CleanupItems=@()
}
$env:THREEDS_MANAGER_DATA_ROOT = Join-Path $env:TEMP ('BackupsNew3DS.AggBatch.' + [guid]::NewGuid().ToString('N'))
try {
    $resolvedEmpty = @(Resolve-ThreeDSInstallBatches -Batches @($emptyBatch) -InstalledTitles @())[0]
    Assert-Equal 'Complete' $resolvedEmpty.State 'A zero-item batch did not reconcile as finished.'
    Assert-Equal 0 $resolvedEmpty.InstalledCount 'A zero-item batch reported installs.'
    Assert-Equal 0 $resolvedEmpty.RemainingCount 'A zero-item batch reported remainders.'
}
finally {
    if (Test-Path -LiteralPath $env:THREEDS_MANAGER_DATA_ROOT) { Remove-Item -LiteralPath $env:THREEDS_MANAGER_DATA_ROOT -Recurse -Force }
}

[pscustomobject]@{
    Status='PASS'; OriginalIdiomStillThrows='PASS'; ZeroItem='PASS'; OneItem='PASS'; ManyItem='PASS'
    NullEntries='PASS'; SixtyFourBitTotal='PASS'; FileInfoShape='PASS'; MissingPropertyRejected='PASS'
    NoUnsafeIdiomInSources='PASS'; EmptyInstalledTitleDirectory='PASS'
    EmptyCollectionMemberAccess='PASS'; ZeroItemBatchReconciles='PASS'
} | Format-List
