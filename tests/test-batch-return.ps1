# Regression coverage for what happens when the card comes back from the 3DS.
#
# Installed health is an exact manifest match with no full read.  A batch that has
# been out to the console is finished with: its folder is removed whole, and titles
# that did not install go back in the queue.  There is no review, hold or quarantine
# state, and a folder the manager did not create is never touched.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$testRoot = Join-Path $env:TEMP ('BackupsNew3DS.Return.' + [guid]::NewGuid().ToString('N'))
$env:THREEDS_MANAGER_DATA_ROOT = Join-Path $testRoot 'state'
New-Item -ItemType Directory -Path $env:THREEDS_MANAGER_DATA_ROOT -Force | Out-Null
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\ThreeDSLibrary.Core.psm1') -Force -DisableNameChecking

function Assert-Equal($Expected, $Actual, [string]$Message) {
    if ($Expected -ne $Actual) { throw "$Message Expected '$Expected'; got '$Actual'." }
}
function Assert-Throws([scriptblock]$Action, [string]$Pattern, [string]$Message) {
    $caught = $null
    try { & $Action } catch { $caught = $_.Exception.Message }
    if ($null -eq $caught) { throw $Message }
    if ($Pattern -and $caught -notmatch $Pattern) { throw "$Message Unexpected error: $caught" }
}
function New-TitleFolder([string]$Base, [string]$Low, [int]$AppLength, [int]$SaveLength) {
    $dir = Join-Path $Base $Low
    New-Item -ItemType Directory -Path (Join-Path $dir 'content\cmd'), (Join-Path $dir 'data') -Force | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $dir 'content\00000000.app'), (New-Object byte[] $AppLength))
    [IO.File]::WriteAllBytes((Join-Path $dir 'content\00000000.tmd'), (New-Object byte[] 64))
    [IO.File]::WriteAllBytes((Join-Path $dir 'content\cmd\00000001.cmd'), (New-Object byte[] 32))
    if ($SaveLength) { [IO.File]::WriteAllBytes((Join-Path $dir 'data\00000001.sav'), (New-Object byte[] $SaveLength)) }
}
function New-Expected([string]$TitleId, [int]$AppLength, [int]$SaveLength) {
    [pscustomobject]@{
        Title="Game $TitleId"; TitleId=$TitleId; Type='Base'; SaveSizeBytes=[uint64]$SaveLength
        ContentManifest=@([pscustomobject]@{ Index='0000'; ContentId='00000000'; Length=[uint64]$AppLength })
    }
}
function New-StagedItem([string]$TitleId, [uint64]$Length = 4096) {
    [pscustomobject]@{
        Title="Game $TitleId"; TitleId=$TitleId; Type='Base'; ProductCode='CTR-P-TEST'; Region='USA'
        SaveSizeBytes=[uint64]524288; ContentManifest=@(); FileName="$TitleId-AAAAAAAA.cia"; Length=$Length
        SHA256=('A' * 64); StagedFileState='Present'; InstallState='Unknown'
    }
}
function New-Batch([string]$Id, [object[]]$Items) {
    [pscustomobject]@{
        BatchId=$Id; BatchPath="X:\$Id"; Items=@($Items); ItemCount=@($Items).Count; State='Staged on SD'
        InstalledCount=0; RemainingCount=@($Items).Count; InstalledItems=@(); RemainingItems=@($Items)
    }
}

try {
    # --- 1. Health is an exact manifest match, with no full read ---------------
    $sdRoot = Join-Path $testRoot 'card'
    $base = Join-Path $sdRoot ('Nintendo 3DS\{0}\{1}\title\00040000' -f ('A' * 32), ('B' * 32))
    New-TitleFolder $base '00100000' 4096 524288
    New-TitleFolder $base '00200000' 5000 524288
    New-TitleFolder $base '00300000' 4096 0
    $expected = @((New-Expected '0004000000100000' 4096 524288), (New-Expected '0004000000200000' 4096 524288))
    $state = @{}
    foreach ($title in @(Get-ThreeDSInstalledTitles -SdRoot $sdRoot -ExpectedTitles $expected)) { $state[$title.TitleId] = $title.State }
    Assert-Equal 'Installed + healthy' $state['0004000000100000'] 'An exact manifest match was not healthy without a full read.'
    Assert-Equal 'Installed + unhealthy' $state['0004000000200000'] 'A content length mismatch was accepted as healthy.'
    Assert-Equal 'Installed + uncertain' $state['0004000000300000'] 'A title with no validated manifest was claimed healthy.'

    # --- 2. A staged title is installed or it is not ----------------------------
    $installed = @(
        [pscustomobject]@{ TitleId='0004000000100000'; State='Installed + healthy' },
        [pscustomobject]@{ TitleId='0004000000200000'; State='Installed + unhealthy' }
    )
    $mixed = New-Batch '3-games - 2026-09-29 04-35-49' @((New-StagedItem '0004000000100000'), (New-StagedItem '0004000000200000'), (New-StagedItem '0004000000400000'))
    $resolved = @(Resolve-ThreeDSInstallBatches -Batches @($mixed) -InstalledTitles $installed)[0]
    Assert-Equal 'Partially installed - 2 remaining' $resolved.State 'Mixed batch state mismatch.'
    Assert-Equal 1 $resolved.InstalledCount 'Installed count mismatch.'
    Assert-Equal 2 $resolved.RemainingCount 'Remaining count mismatch.'
    Assert-Equal 'Remaining' (@($resolved.Items | Where-Object TitleId -eq '0004000000200000')[0].InstallState) 'An incomplete install was not simply remaining.'
    foreach ($forbidden in @('ReviewRequired','CleanupEligible','FailedItems','CleanupItems')) {
        if ($resolved.PSObject.Properties[$forbidden]) { throw "A reconciled batch still carries $forbidden." }
    }
    Assert-Equal 'Complete' (@(Resolve-ThreeDSInstallBatches -Batches @((New-Batch '1-games - 2026-09-29 05-00-00' @((New-StagedItem '0004000000100000')))) -InstalledTitles $installed)[0].State) 'Fully installed batch state mismatch.'
    Assert-Equal 'Ready to install' (@(Resolve-ThreeDSInstallBatches -Batches @((New-Batch '1-games - 2026-09-29 05-00-01' @((New-StagedItem '0004000000400000')))) -InstalledTitles $installed)[0].State) 'Untouched batch state mismatch.'

    # --- 3. Which folders are finished with ------------------------------------
    $active = New-Batch '2-games - 2026-09-29 06-00-00' @((New-StagedItem '0004000000500000'), (New-StagedItem '0004000000600000'))
    [void](Resolve-ThreeDSInstallBatches -Batches @($active) -InstalledTitles @())
    $ready = Resolve-ThreeDSBatchReturn -Batches @($active) -ActiveBatchId $active.BatchId -AwaitingReturn $false
    Assert-Equal 1 @($ready.KeepBatches).Count 'A batch not yet taken to the 3DS was not kept.'
    Assert-Equal 0 @($ready.RemoveBatches).Count 'A batch not yet taken to the 3DS was removed.'
    Assert-Equal $false $ready.ActiveReturned 'A batch not yet taken to the 3DS was reported as returned.'

    $back = Resolve-ThreeDSBatchReturn -Batches @($active) -ActiveBatchId $active.BatchId -AwaitingReturn $true
    Assert-Equal 1 @($back.RemoveBatches).Count 'A returned batch was not finished with.'
    Assert-Equal 2 @($back.RequeueItems).Count 'Games that did not install were not queued again.'
    Assert-Equal $true $back.ActiveReturned 'A returned batch was not reported as returned.'

    $partly = New-Batch '2-games - 2026-09-29 06-10-00' @((New-StagedItem '0004000000100000'), (New-StagedItem '0004000000700000'))
    [void](Resolve-ThreeDSInstallBatches -Batches @($partly) -InstalledTitles $installed)
    $notEjected = Resolve-ThreeDSBatchReturn -Batches @($partly) -ActiveBatchId $partly.BatchId -AwaitingReturn $false
    Assert-Equal 1 @($notEjected.RemoveBatches).Count 'A batch with installs was kept because the card was not ejected through the app.'
    Assert-Equal 1 @($notEjected.RequeueItems).Count 'Only the game that did not install should go back in the queue.'
    Assert-Equal '0004000000700000' @($notEjected.RequeueItems)[0].TitleId 'The wrong game was queued again.'

    $stale = New-Batch '4-games - 2026-09-03 01-24-49' @((New-StagedItem '0004000000800000'))
    $foreign = New-Batch 'My own folder' @((New-StagedItem '0004000000900000'))
    [void](Resolve-ThreeDSInstallBatches -Batches @($stale, $foreign) -InstalledTitles @())
    $leftovers = Resolve-ThreeDSBatchReturn -Batches @($active, $stale, $foreign) -ActiveBatchId $active.BatchId -AwaitingReturn $false
    Assert-Equal 1 @($leftovers.RemoveBatches).Count 'Only the leftover manager folder should be removed.'
    Assert-Equal $stale.BatchId @($leftovers.RemoveBatches)[0].BatchId 'The wrong folder was chosen for removal.'
    Assert-Equal 1 @($leftovers.KeepBatches).Count 'The active batch was not kept.'
    Assert-Equal 0 @($leftovers.RequeueItems | Where-Object TitleId -eq '0004000000900000').Count 'A game from a folder the manager did not create was queued.'

    $gone = Resolve-ThreeDSBatchReturn -Batches @() -ActiveBatchId $active.BatchId -AwaitingReturn $true
    Assert-Equal $true $gone.ActiveMissing 'A missing active folder was not reported.'
    Assert-Equal $true $gone.ActiveReturned 'A missing active folder left the batch waiting forever.'
    Assert-Equal $false (Resolve-ThreeDSBatchReturn -Batches @() -ActiveBatchId '').ActiveReturned 'Nothing active still reported a return.'
    Assert-Equal 0 @((Resolve-ThreeDSBatchReturn -Batches $null).RemoveBatches).Count 'A null batch list broke the return logic.'

    # --- 4. Finding the prepared copy to queue again ---------------------------
    $cacheRoot = Join-Path $testRoot 'installready'
    $titleDir = Join-Path $cacheRoot 'Base\0004000000700000'
    New-Item -ItemType Directory -Path $titleDir -Force | Out-Null
    $preparedPath = Join-Path $titleDir (('C' * 64) + '.cia')
    [IO.File]::WriteAllBytes($preparedPath, (New-Object byte[] 4096))
    $found = Find-ThreeDSPreparedArtifact -InstallReadyRoot $cacheRoot -Item (New-StagedItem '0004000000700000' 4096)
    Assert-Equal $preparedPath $found.ArtifactPath 'The prepared copy was not found.'
    Assert-Equal ([uint64]4096) $found.ArtifactLength 'Prepared copy length mismatch.'
    Assert-Equal ('A' * 64) $found.ArtifactSHA256 'The queued artifact lost its validated digest.'
    Assert-Equal $null (Find-ThreeDSPreparedArtifact -InstallReadyRoot $cacheRoot -Item (New-StagedItem '0004000000700000' 999)) 'A prepared copy of a different size was accepted.'
    Assert-Equal $null (Find-ThreeDSPreparedArtifact -InstallReadyRoot $cacheRoot -Item (New-StagedItem '0004000000A00000')) 'A game with no prepared copy produced one.'
    [IO.File]::WriteAllBytes((Join-Path $titleDir (('D' * 64) + '.cia')), (New-Object byte[] 4096))
    Assert-Equal $null (Find-ThreeDSPreparedArtifact -InstallReadyRoot $cacheRoot -Item (New-StagedItem '0004000000700000' 4096)) 'An ambiguous prepared copy was guessed.'

    # --- 5. Removing a finished folder from the (fake) card --------------------
    $target = [pscustomobject]@{
        Root = $sdRoot; DriveLetter = 'D:'; DiskNumber = 2; DiskCapacityBytes = [uint64]127999672320
        VolumeLabel = 'N3DS'; FreeBytes = [uint64]64GB; VolumeHealthStatus = 'Healthy'
    }
    $module = Get-Module ThreeDSLibrary.Core
    & $module {
        param($stubTarget)
        $script:ThreeDSTestStubTarget = $stubTarget
        Set-Item -Path 'function:script:Assert-ThreeDSSafeTarget' -Value {
            param($DiskNumber, $ExpectedDiskCapacityBytes, $ExpectedDriveLetter, [switch]$AllowUnhealthyVolume)
            $script:ThreeDSTestStubTarget
        }
    } $target
    $proof = & $module { Assert-ThreeDSSafeTarget -DiskNumber 9 -ExpectedDiskCapacityBytes ([uint64]1) -ExpectedDriveLetter 'Z:' }
    if (-not $proof -or [IO.Path]::GetFullPath($proof.Root) -ne [IO.Path]::GetFullPath($sdRoot)) {
        throw 'REFUSING TO RUN: the module-scope card stub is not in effect, so removal could reach a real device.'
    }
    $queueParent = Join-Path $sdRoot 'cias\InstallQueue'
    $finished = Join-Path $queueParent $stale.BatchId
    $foreignDir = Join-Path $queueParent 'My own folder'
    New-Item -ItemType Directory -Path $finished, $foreignDir -Force | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $finished '0004000000800000-AAAAAAAA.cia'), (New-Object byte[] 1024))
    Set-Content -LiteralPath (Join-Path $finished 'INSTALL-QUEUE.json') -Value '{}'
    [IO.File]::WriteAllBytes((Join-Path $foreignDir 'keep.bin'), (New-Object byte[] 16))
    $removeArgs = @{ TargetDiskNumber = 2; ExpectedDiskCapacityBytes = [uint64]127999672320; ExpectedDriveLetter = 'D:' }

    $removed = Remove-ThreeDSInstallFolder -BatchId $stale.BatchId @removeArgs
    Assert-Equal $true $removed.Removed 'The finished folder was not removed.'
    Assert-Equal 2 $removed.RemovedFileCount 'The removed file count is wrong.'
    Assert-Equal $false (Test-Path -LiteralPath $finished) 'The finished folder is still on the card.'
    Assert-Equal $true (Test-Path -LiteralPath (Join-Path $foreignDir 'keep.bin')) 'A folder the manager did not create was touched.'
    Assert-Throws { Remove-ThreeDSInstallFolder -BatchId 'My own folder' @removeArgs } 'did not create' 'A folder the manager did not create was removed.'
    Assert-Throws { Remove-ThreeDSInstallFolder -BatchId '..\..\Nintendo 3DS' @removeArgs } 'did not create' 'A path outside the install queue was accepted.'
    Assert-Equal $false (Remove-ThreeDSInstallFolder -BatchId '1-games - 2026-09-29 09-09-09' @removeArgs).Removed 'A folder that was already gone was reported removed.'
    Assert-Equal $true (Test-Path -LiteralPath (Join-Path $base '00100000\content\00000000.app')) 'Removal reached the installed games.'

    [pscustomobject]@{
        Status='PASS'; HealthFromManifestWithoutFullRead='PASS'; InstalledOrRemainingOnly='PASS'
        UnreturnedBatchKept='PASS'; ReturnedBatchFinished='PASS'; NotInstalledRequeued='PASS'
        LeftoverFoldersRemoved='PASS'; ForeignFoldersUntouched='PASS'; MissingActiveFolderHandled='PASS'
        PreparedCopyFound='PASS'; FolderRemovalBoundToQueue='PASS'
    } | Format-List
}
finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
