$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$testStateRoot = Join-Path ([IO.Path]::GetTempPath()) ('BackupsNew3DS-StateName-' + [guid]::NewGuid().ToString('N'))
$env:THREEDS_MANAGER_DATA_ROOT = $testStateRoot
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\ThreeDSLibrary.Core.psm1') -Force -DisableNameChecking

function Assert-True([bool]$Condition,[string]$Message) {
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function New-TestItem([string]$Name,[string]$TitleId) {
    [pscustomobject]@{
        DisplayTitle = $Name
        LibraryItem = [pscustomobject]@{
            Title = $Name
            TitleId = $TitleId
            SourcePath = "C:\owned-sources\$Name.3ds"
            SourceSHA256 = ('A' * 64)
        }
    }
}

$items = @(
    (New-TestItem 'Prepared Game' '0004000000000001'),
    (New-TestItem 'Broken Game' '0004000000000002'),
    (New-TestItem 'Cached Game' '0004000000000003')
)
$attempted = [Collections.Generic.List[string]]::new()
$observedFailures = [Collections.Generic.List[object]]::new()
$prepare = {
    param($item,$position,$count)
    $attempted.Add($item.DisplayTitle) | Out-Null
    if ($item.DisplayTitle -eq 'Broken Game') {
        throw 'CIA validation failed: One or more content-integrity hashes failed; NCCH ExHeader/ExeFS/RomFS integrity did not fully validate.'
    }
    [pscustomobject]@{
        Title = $item.DisplayTitle
        TitleId = $item.LibraryItem.TitleId
        CacheDisposition = if ($item.DisplayTitle -eq 'Cached Game') { 'Cached' } else { 'Prepared' }
    }
}
$onFailure = { param($failure,$position,$count) $observedFailures.Add($failure) | Out-Null }
$result = Invoke-ThreeDSPreparationBatch -Items $items -PrepareAction $prepare -FailureAction $onFailure

Assert-True ($attempted.Count -eq 3) 'a recoverable title failure must not skip later titles'
Assert-True ($result.Artifacts.Count -eq 2) 'successful artifacts must be preserved across a title failure'
Assert-True ($result.PreparedCount -eq 1) 'prepared count should include newly prepared artifacts only'
Assert-True ($result.CachedCount -eq 1) 'cached count should include reused artifacts only'
Assert-True ($result.FailedCount -eq 1) 'failed count should include only the broken title'
Assert-True ($result.Failures[0].Title -eq 'Broken Game') 'failure must retain the human game title'
Assert-True ($result.Failures[0].Code -eq 'ContentIntegrityFailed') 'content-integrity failure must be title-scoped'
Assert-True ($result.Failures[0].Error -notmatch '^CIA validation failed:') 'the normal UI error should be concise'
Assert-True ($result.Failures[0].TechnicalError -match 'NCCH ExHeader') 'diagnostic state must preserve the original validation detail'
Assert-True ($result.Failures[0].StateKey -eq ('0004000000000002-' + ('A' * 64))) 'failure identity must use Title ID plus source SHA-256'
Assert-True ($observedFailures.Count -eq 1) 'the failure callback should run once'

$fatalItems = @(
    (New-TestItem 'Good Before Fatal' '0004000000000011'),
    (New-TestItem 'Fatal Tool Failure' '0004000000000012'),
    (New-TestItem 'Must Not Run' '0004000000000013')
)
$fatalAttempts = [Collections.Generic.List[string]]::new()
$successfulBeforeFatal = [Collections.Generic.List[string]]::new()
$fatalAction = {
    param($item,$position,$count)
    $fatalAttempts.Add($item.DisplayTitle) | Out-Null
    if ($item.DisplayTitle -eq 'Fatal Tool Failure') { throw 'CTRTool is not configured.' }
    [pscustomobject]@{Title=$item.DisplayTitle;TitleId=$item.LibraryItem.TitleId;CacheDisposition='Prepared'}
}
$successAction = { param($item,$artifact,$position,$count) $successfulBeforeFatal.Add($artifact.TitleId) | Out-Null }
$fatalThrown = $false
try {
    Invoke-ThreeDSPreparationBatch -Items $fatalItems -PrepareAction $fatalAction -SuccessAction $successAction | Out-Null
}
catch { $fatalThrown = $true }
Assert-True $fatalThrown 'a toolchain failure must stop the batch'
Assert-True ($fatalAttempts.Count -eq 2) 'no title after a fatal batch failure may run'
Assert-True ($successfulBeforeFatal.Count -eq 1) 'success completed before a fatal failure must remain recorded'

$sdFailure = Get-ThreeDSPreparationFailureScope -ErrorValue ([Exception]::new('The selected disk capacity changed.'))
$spaceFailure = Get-ThreeDSPreparationFailureScope -ErrorValue ([Exception]::new('There is not enough space on the destination.'))
$unknownFailure = Get-ThreeDSPreparationFailureScope -ErrorValue ([Exception]::new('Unclassified failure.'))
Assert-True ($sdFailure.Scope -eq 'Fatal' -and $sdFailure.Code -eq 'SdSafety') 'SD identity changes must be fatal'
Assert-True ($spaceFailure.Scope -eq 'Fatal' -and $spaceFailure.Code -eq 'InsufficientSpace') 'insufficient space must be fatal'
Assert-True ($unknownFailure.Scope -eq 'Fatal') 'unknown failures must fail closed'

$oldSourceKey = Get-ThreeDSPreparationStateKey -TitleId '000400000F70CC00' -SourceSHA256 ('A' * 64)
$replacementSourceKey = Get-ThreeDSPreparationStateKey -TitleId '000400000F70CC00' -SourceSHA256 ('B' * 64)
Assert-True ($oldSourceKey -ne $replacementSourceKey) 'a replacement source must not erase or inherit an earlier source failure'

# Exact regression: the human-readable SD folder name was incorrectly interpolated directly into
# Save-ThreeDSManagerState, whose filename contract intentionally rejects spaces.
$failingBatchId = '1-games - 2026-09-02 00-10-27'
$rawStateName = "install-batch-$failingBatchId.json"
$oldFailureReproduced = $false
try { Save-ThreeDSManagerState -Name $rawStateName -Value ([pscustomobject]@{BatchId=$failingBatchId}) | Out-Null }
catch { $oldFailureReproduced = ($_.Exception.Message -match '^Invalid state filename:') }
Assert-True $oldFailureReproduced 'the exact old human-readable state filename must reproduce the rejection'

$safeStateName = Get-ThreeDSInstallBatchStateName -BatchId $failingBatchId
Assert-True ($safeStateName -eq 'install-batch-A3F2AC535D480F1001480E607211332A358BD5D91499B6DFB4A741B91136F87C.json') 'friendly batch ID must map to its stable SHA-256 state key'
Assert-True ($safeStateName -match '^install-batch-[A-F0-9]{64}\.json$') 'generated batch state filename must use only safe stable characters'
$savedPath = Save-ThreeDSManagerState -Name $safeStateName -Value ([pscustomobject]@{BatchId=$failingBatchId})
Assert-True (Test-Path -LiteralPath $savedPath -PathType Leaf) 'the derived state filename must save successfully'
$display = Get-ThreeDSManagerErrorDisplay `
    -ErrorValue ([Exception]::new('Invalid state filename: D:\unsafe\Game: Error?.json')) `
    -Game 'Fire Emblem Warriors' -Operation 'Recording completed install set in private manager state'
Assert-True $display.IsInternal 'invalid state filenames must be presented as internal manager errors'
Assert-True ($display.Body -match 'Game: Fire Emblem Warriors') 'internal error display must include the known game'
Assert-True ($display.Body -match 'Operation: Recording completed install set') 'internal error display must include the operation'
Assert-True ($display.Body -match 'Invalid state filename: generated state key was rejected') 'internal error display must include sanitized relevant detail'
Assert-True ($display.Body -notmatch 'D:\\unsafe|Error\?') 'unsafe raw filename detail must not leak into the dialog'
Remove-Item -LiteralPath $testStateRoot -Recurse -Force

'Preparation failure isolation tests PASS'
