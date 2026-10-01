# Regression coverage for staging an install set onto the card.
#
# The card path is trusted: each validated InstallReady artifact is copied once,
# recorded under its validated digest, and never read back.  What must still hold
# is the shape of the batch, the private manifest record, and fail-closed cleanup
# of a partial folder when staging stops early.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$testRoot = Join-Path $env:TEMP ('BackupsNew3DS.Staging.' + [guid]::NewGuid().ToString('N'))
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

try {
    $cacheRoot = Join-Path $testRoot 'installready'
    $sdRoot = Join-Path $testRoot 'card'
    $queueParent = Join-Path $sdRoot 'cias\InstallQueue'
    New-Item -ItemType Directory -Path $cacheRoot, $queueParent, (Join-Path $sdRoot 'Nintendo 3DS') -Force | Out-Null

    $rng = New-Object Random 20260929
    $artifacts = @()
    foreach ($index in 1..3) {
        $titleId = '00040000{0:X8}' -f (0x00170000 + ($index * 0x100))
        $payload = New-Object byte[] (192 * 1024 + $index)
        $rng.NextBytes($payload)
        $path = Join-Path $cacheRoot "$titleId.cia"
        [IO.File]::WriteAllBytes($path, $payload)
        $artifacts += [pscustomobject]@{
            Title = "Staged Game $index"; TitleId = $titleId; Type = 'Base'
            ProductCode = 'CTR-P-S{0:D3}' -f $index; Region = 'USA'; SaveSizeBytes = [uint64]524288
            ContentManifest = @([pscustomobject]@{ Index='0000'; ContentId='00000000'; Length=[uint64]$payload.Length })
            ArtifactPath = $path; ArtifactLength = [uint64]$payload.Length
            ArtifactSHA256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToUpperInvariant()
        }
    }

    # Stand-in for the verified card.  Copy-ThreeDSInstallQueue resolves the target in
    # module scope, so the stub goes into the module and is proven before any write.
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
        throw 'REFUSING TO RUN: the module-scope card stub is not in effect, so staging could reach a real device.'
    }

    # --- A normal batch -------------------------------------------------------
    $progress = New-Object System.Collections.ArrayList
    $queue = Copy-ThreeDSInstallQueue -Artifacts $artifacts -TargetDiskNumber 2 -ExpectedDiskCapacityBytes ([uint64]127999672320) `
        -ExpectedDriveLetter 'D:' -ProgressAction { param($message) [void]$progress.Add([string]$message) }.GetNewClosure()
    if (-not ([IO.Path]::GetFullPath($queue.QueueRoot)).StartsWith([IO.Path]::GetFullPath($queueParent), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Staging escaped the fake card.'
    }
    if ($queue.BatchId -notmatch '^3-games - \d{4}-\d{2}-\d{2} \d{2}-\d{2}-\d{2}$') { throw "Unexpected batch folder name: $($queue.BatchId)" }
    Assert-Equal $true (& $module { Test-ThreeDSSafeBatchId -BatchId $args[0] } $queue.BatchId) 'The batch folder name is not recognised as a manager batch.'
    Assert-Equal 3 $queue.ItemCount 'Not every game was staged.'
    foreach ($artifact in $artifacts) {
        $staged = @($queue.Items | Where-Object TitleId -eq $artifact.TitleId)[0]
        Assert-Equal ('{0}-{1}.cia' -f $artifact.TitleId, $artifact.ArtifactSHA256.Substring(0, 8)) $staged.FileName 'Staged file name mismatch.'
        Assert-Equal $artifact.ArtifactSHA256 $staged.SHA256 'The staged record does not carry the validated digest.'
        Assert-Equal 1 @($staged.ContentManifest).Count 'The staged record lost its content manifest.'
        $copy = Join-Path $queue.QueueRoot $staged.FileName
        Assert-Equal $artifact.ArtifactSHA256 (Get-FileHash -LiteralPath $copy -Algorithm SHA256).Hash 'The copy is not byte-identical to the artifact.'
    }
    $manifest = Get-Content -LiteralPath (Join-Path $queue.QueueRoot 'INSTALL-QUEUE.json') -Raw | ConvertFrom-Json
    Assert-Equal $queue.BatchId $manifest.BatchId 'On-card manifest batch ID mismatch.'
    Assert-Equal 3 @($manifest.Queue).Count 'On-card manifest does not list every game.'
    if ((@($manifest.Instructions) -join ' ') -match 'Verify') { throw 'The on-card instructions still ask for GodMode9 Verify file.' }
    if ((@($manifest.Instructions) -join ' ') -notmatch 'Install game image') { throw 'The on-card instructions do not say Install game image.' }
    $record = Get-ThreeDSManagerState -Name (Get-ThreeDSInstallBatchStateName -BatchId $queue.BatchId)
    Assert-Equal 3 @($record.Queue).Count 'The private record does not list every game.'
    Assert-Equal 3 @(Get-ThreeDSKnownTitleManifests | Where-Object { $_.TitleId -in @($artifacts.TitleId) }).Count 'Staged manifests are not known for later health checks.'
    if (-not @($progress | Where-Object { $_ -match '^Copying 2 of 3 - Staged Game 2$' }).Count) { throw 'Progress did not name the game and its position.' }
    if (@($progress | Where-Object { $_ -match 'Verif' }).Count) { throw 'Staging still reports a verification pass.' }

    # --- Refusals leave nothing behind -----------------------------------------
    $foldersBefore = @(Get-ChildItem -LiteralPath $queueParent -Directory).Count
    $target.FreeBytes = [uint64]1MB
    Assert-Throws { Copy-ThreeDSInstallQueue -Artifacts $artifacts -TargetDiskNumber 2 -ExpectedDiskCapacityBytes ([uint64]127999672320) -ExpectedDriveLetter 'D:' } `
        'enough free space' 'A batch larger than the free space was staged.'
    $target.FreeBytes = [uint64]64GB
    Assert-Equal $foldersBefore @(Get-ChildItem -LiteralPath $queueParent -Directory).Count 'A refused batch left a folder behind.'

    Start-Sleep -Seconds 1   # a fresh timestamp for the next folder name
    $changed = @($artifacts[0], ($artifacts[1] | Select-Object *), $artifacts[2])
    $changed[1].ArtifactLength = [uint64]($changed[1].ArtifactLength + 1)
    Assert-Throws { Copy-ThreeDSInstallQueue -Artifacts $changed -TargetDiskNumber 2 -ExpectedDiskCapacityBytes ([uint64]127999672320) -ExpectedDriveLetter 'D:' } `
        'no longer the validated artifact' 'A replaced prepared file was staged.'
    Assert-Equal $foldersBefore @(Get-ChildItem -LiteralPath $queueParent -Directory).Count 'A batch that stopped part-way left its folder behind.'

    Start-Sleep -Seconds 1
    $missing = @($artifacts[0], ($artifacts[2] | Select-Object *))
    $missing[1].ArtifactPath = Join-Path $cacheRoot 'gone.cia'
    Assert-Throws { Copy-ThreeDSInstallQueue -Artifacts $missing -TargetDiskNumber 2 -ExpectedDiskCapacityBytes ([uint64]127999672320) -ExpectedDriveLetter 'D:' } `
        'Missing cache artifact' 'A missing prepared file was not refused.'
    Assert-Equal $foldersBefore @(Get-ChildItem -LiteralPath $queueParent -Directory).Count 'A batch with a missing file left its folder behind.'
    Assert-Equal 3 @(Get-ChildItem -LiteralPath $cacheRoot -File).Count 'Staging touched the prepared copies.'

    [pscustomobject]@{
        Status='PASS'; CopiesByteIdentical='PASS'; RecordsValidatedDigest='PASS'; NoReadBack='PASS'
        InstructionsInstallOnly='PASS'; ManifestsKnownForHealth='PASS'; FreeSpaceRefusal='PASS'
        PartialFolderRemoved='PASS'; PreparedCopiesUntouched='PASS'
    } | Format-List
}
finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
