# The SD safety gate that every write passes through: the exact selected USB card, MBR with
# one FAT32 partition and a Nintendo 3DS folder.  Cluster size is not part of it, so a card
# formatted as 3ds.hacks.guide describes (32 KiB clusters up to 64 GB) is accepted.
# Windows storage queries are replaced by synthetic volumes inside the module.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repo = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repo 'scripts\ThreeDSLibrary.Core.psm1') -Force -DisableNameChecking
function Check([bool]$Condition, [string]$Message) { if (-not $Condition) { throw "FAIL: $Message" }; "ok   $Message" }

$module = Get-Module ThreeDSLibrary.Core
function New-Volume([hashtable]$Change = @{}) {
    $volume = [ordered]@{
        DiskNumber=3; DriveLetter='E:'; DiskCapacityBytes=[uint64]63864569856; IsBoot=$false; IsSystem=$false
        BusType='USB'; PartitionStyle='MBR'; PartitionCount=1; FileSystem='FAT32'; AllocationUnitBytes=[uint64]32768
        VolumeHealthStatus='Healthy'; HasNintendo3DS=$true; Root='E:\'
    }
    foreach ($key in $Change.Keys) { $volume[$key] = $Change[$key] }
    [pscustomobject]$volume
}
function Test-Gate($Volume) {
    & $module { param($v) $script:SafeTargetTestVolume = $v; Set-Item -Path 'function:script:Get-ThreeDSSafeVolumes' -Value { @($script:SafeTargetTestVolume) } } $Volume
    try { & $module { Assert-ThreeDSSafeTarget -DiskNumber 3 -ExpectedDiskCapacityBytes ([uint64]63864569856) -ExpectedDriveLetter 'E:' } | Out-Null; 'accepted' }
    catch { $_.Exception.Message }
}

Check ((Test-Gate (New-Volume)) -eq 'accepted') 'a 64 GB card with 32 KiB clusters, as the guide formats it, is accepted'
Check ((Test-Gate (New-Volume @{ AllocationUnitBytes=[uint64]65536 })) -eq 'accepted') 'a card with 64 KiB clusters is accepted'
Check ((Test-Gate (New-Volume @{ AllocationUnitBytes=[uint64]0 })) -eq 'accepted') 'a card whose cluster size Windows did not report is accepted'
Check ((Test-Gate (New-Volume @{ FileSystem='exFAT' })) -match 'not formatted FAT32') 'an exFAT card is refused with a clear reason'
Check ((Test-Gate (New-Volume @{ IsSystem=$true })) -match 'boot or system disk') 'a system disk is refused'
Check ((Test-Gate (New-Volume @{ BusType='NVMe' })) -match 'not USB-attached') 'an internal drive is refused'
Check ((Test-Gate (New-Volume @{ PartitionStyle='GPT' })) -match 'not MBR') 'a GPT disk is refused'
Check ((Test-Gate (New-Volume @{ HasNintendo3DS=$false })) -match 'no Nintendo 3DS directory') 'a card without a Nintendo 3DS folder is refused'
Check ((Test-Gate (New-Volume @{ DiskCapacityBytes=[uint64]1 })) -match 'capacity changed') 'a different disk in the same slot is refused'
'ALL CHECKS PASSED'
