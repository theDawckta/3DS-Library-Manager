# Regression coverage for the single authoritative SD lifecycle/state model.
#
# The bug this replaces: a remembered successful eject outranked physical reality.
# A card that Windows still had mounted was hidden from the target list and the
# interface kept reporting "Safe to remove SD card" about a live, usable volume,
# with no recovery short of physically pulling the card.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $env:THREEDS_MANAGER_DATA_ROOT) {
    $env:THREEDS_MANAGER_DATA_ROOT = Join-Path $env:TEMP ('BackupsNew3DS.Isolated.' + [guid]::NewGuid().ToString('N'))
}
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\ThreeDSLibrary.Core.psm1') -Force -DisableNameChecking

function Assert-Equal($Expected, $Actual, [string]$Message) {
    if ($Expected -ne $Actual) { throw "$Message Expected '$Expected'; got '$Actual'." }
}
function New-Target {
    param(
        [int]$DiskNumber = 1, [string]$DriveLetter = 'D:', [string]$UniqueId = 'USBSTOR\N3DS',
        [string]$DeviceId = 'USBSTOR\N3DS&0', [string]$EjectDeviceId = 'USB\READER',
        [bool]$HasNintendo3DS = $true, [string]$VolumeHealth = 'Healthy', [string]$BusType = 'USB'
    )
    [pscustomobject]@{
        DiskNumber=$DiskNumber; DriveLetter=$DriveLetter; DiskUniqueId=$UniqueId
        DeviceInstanceId=$DeviceId; EjectDeviceInstanceId=$EjectDeviceId
        DiskCapacityBytes=[uint64]127999672320; VolumeCapacityBytes=[uint64]127982960640
        FreeBytes=[uint64]29247733760; VolumeLabel='N3DS'; FileSystem='FAT32'
        VolumeHealthStatus=$VolumeHealth; BusType=$BusType; HasNintendo3DS=$HasNintendo3DS
        IsBoot=$false; IsSystem=$false
    }
}

$card = New-Target

# --- Every declared state must be reachable --------------------------------
$names = @(Get-ThreeDSSdLifecycleStateNames)
Assert-Equal 7 $names.Count 'The lifecycle model does not declare exactly seven states.'
foreach ($required in @('Mounted + idle','Mounted + busy','Ejecting','Safe to remove SD card',
    'No SD card detected','Reinserted - identifying','SD state uncertain')) {
    if ($required -notin $names) { throw "Lifecycle model is missing the '$required' state." }
}

$observed = @{}

# 1. Mounted + idle
$idle = Resolve-ThreeDSSdLifecycle -CurrentTargets @($card) -SelectedTarget $card
Assert-Equal 'Mounted + idle' $idle.State 'Mounted idle state mismatch.'
Assert-Equal $true $idle.CanEject 'A mounted idle card could not be ejected.'
Assert-Equal $true $idle.CanUseSd 'A mounted idle card was not usable.'
Assert-Equal $false $idle.ShowsSuccessfulEject 'A mounted idle card claimed a successful eject.'
$observed[$idle.State] = $true

# 2. Mounted + busy
$busy = Resolve-ThreeDSSdLifecycle -CurrentTargets @($card) -SelectedTarget $card -Busy $true
Assert-Equal 'Mounted + busy' $busy.State 'Busy state mismatch.'
Assert-Equal $false $busy.CanEject 'Eject was offered during an active SD operation.'
Assert-Equal $false $busy.CanUseSd 'A busy card was offered for new SD work.'
$observed[$busy.State] = $true

# 3. Ejecting
$ejecting = Resolve-ThreeDSSdLifecycle -CurrentTargets @($card) -SelectedTarget $card -Ejecting $true
Assert-Equal 'Ejecting' $ejecting.State 'In-flight eject state mismatch.'
Assert-Equal $false $ejecting.CanEject 'Eject was offered while an eject was already in flight.'
Assert-Equal $false $ejecting.ShowsSuccessfulEject 'An in-flight eject claimed success.'
$observed[$ejecting.State] = $true

# 4. Ejected / safe to physically remove
$removed = Resolve-ThreeDSSdLifecycle -CurrentTargets @() -SelectedTarget $null `
    -EjectedDeviceInstanceId $card.DeviceInstanceId -EjectRemovalObserved $true
Assert-Equal 'Safe to remove SD card' $removed.State 'Confirmed-removal state mismatch.'
Assert-Equal $true $removed.ShowsSuccessfulEject 'Confirmed removal did not present the successful-eject message.'
Assert-Equal $false $removed.CanUseSd 'An ejected card was still offered for SD work.'
Assert-Equal $card.DeviceInstanceId $removed.EjectedDeviceInstanceId 'The confirmed eject record was dropped.'
$observed[$removed.State] = $true

# 5. Absent
$absent = Resolve-ThreeDSSdLifecycle -CurrentTargets @() -SelectedTarget $null
Assert-Equal 'No SD card detected' $absent.State 'Absent state mismatch.'
Assert-Equal $false $absent.ShowsSuccessfulEject 'An absent card with no eject on record claimed a successful eject.'
$observed[$absent.State] = $true

# 6. Reinserted but not positively reidentified
$reinserted = Resolve-ThreeDSSdLifecycle -CurrentTargets @($card) -SelectedTarget $null
Assert-Equal 'Reinserted - identifying' $reinserted.State 'Unidentified-media state mismatch.'
Assert-Equal $false $reinserted.CanUseSd 'An unidentified card was offered for SD work.'
Assert-Equal $false $reinserted.CanEject 'An unidentified card was offered for eject.'
$observed[$reinserted.State] = $true

# A selection that no longer matches the connected hardware is not reidentified.
$swapped = Resolve-ThreeDSSdLifecycle -CurrentTargets @((New-Target -UniqueId 'USBSTOR\OTHER' -DeviceId 'USBSTOR\OTHER&0')) -SelectedTarget $card
Assert-Equal 'Reinserted - identifying' $swapped.State 'A swapped physical device was treated as the selected card.'

# 7. Error / uncertain
$errored = Resolve-ThreeDSSdLifecycle -CurrentTargets @($card) -SelectedTarget $card -EnumerationError 'Windows lost the volume object.'
Assert-Equal 'SD state uncertain' $errored.State 'Enumeration-failure state mismatch.'
Assert-Equal $false $errored.CanUseSd 'An uncertain SD state was offered for SD work.'
Assert-Equal $false $errored.CanEject 'An uncertain SD state offered eject.'
$observed[$errored.State] = $true

# A 3DS card whose physical identity could not be read is never usable.
$notVerified = New-Target -EjectDeviceId ''
$unverified = Resolve-ThreeDSSdLifecycle -CurrentTargets @($notVerified) -SelectedTarget $notVerified
Assert-Equal 'SD state uncertain' $unverified.State 'An unverified card was not treated as uncertain.'
Assert-Equal $false $unverified.CanUseSd 'An unverified card was offered for SD work.'

# USB storage without a Nintendo 3DS folder is not an SD card at all.
$plainUsb = New-Target -HasNintendo3DS $false
$notACard = Resolve-ThreeDSSdLifecycle -CurrentTargets @($plainUsb) -SelectedTarget $plainUsb
Assert-Equal 'No SD card detected' $notACard.State 'USB storage without a Nintendo 3DS folder was treated as the SD card.'
Assert-Equal $false $notACard.CanUseSd 'USB storage without a Nintendo 3DS folder was offered for SD work.'

Assert-Equal 7 $observed.Keys.Count 'Not every declared lifecycle state was exercised.'

# --- INVARIANT 1 -----------------------------------------------------------
# "Safe to remove SD card" only after Windows ejected the verified device AND
# the device is confirmed gone.
$noRecord = Resolve-ThreeDSSdLifecycle -CurrentTargets @() -SelectedTarget $null -EjectedDeviceInstanceId ''
Assert-Equal $false $noRecord.ShowsSuccessfulEject 'Safe-to-remove was shown without a recorded successful eject.'
Assert-Equal 'No SD card detected' $noRecord.State 'An absent card with no eject record was mislabelled.'

# --- INVARIANT 2 (the reported contradiction) ------------------------------
# A mounted, usable card must never retain a successful-eject message, and must
# never be hidden from the interface, no matter what an earlier lifecycle recorded.
$stale = Resolve-ThreeDSSdLifecycle -CurrentTargets @($card) -SelectedTarget $card `
    -EjectedDeviceInstanceId $card.DeviceInstanceId -EjectRemovalObserved $false
Assert-Equal 'Mounted + idle' $stale.State 'A still-mounted card kept its stale ejected state.'
Assert-Equal $false $stale.ShowsSuccessfulEject 'A mounted, usable card retained a stale successful-eject message.'
Assert-Equal $true $stale.CanUseSd 'A mounted, usable card stayed unusable after a contradicted eject.'
Assert-Equal '' $stale.EjectedDeviceInstanceId 'The contradicted eject record was not cleared.'
if ($stale.EjectStateText -match 'Safe to remove') { throw 'The eject label still said "Safe to remove" for a mounted card.' }
if ($stale.StatusText -match 'Safe to remove') { throw 'The status text still said "Safe to remove" for a mounted card.' }
if ($stale.HeaderText -match 'ejected') { throw 'The header still reported the card as ejected while it was mounted.' }

# The same contradiction after an absence was previously observed (reinsertion).
$staleAfterAbsence = Resolve-ThreeDSSdLifecycle -CurrentTargets @($card) -SelectedTarget $card `
    -EjectedDeviceInstanceId $card.DeviceInstanceId -EjectRemovalObserved $true
Assert-Equal 'Mounted + idle' $staleAfterAbsence.State 'A reinserted, reidentified card was not returned to service.'
Assert-Equal $false $staleAfterAbsence.ShowsSuccessfulEject 'A reinserted card retained the successful-eject message.'
Assert-Equal '' $staleAfterAbsence.EjectedDeviceInstanceId 'The eject record survived reinsertion.'

# A busy, still-mounted card with a stale eject record is busy, never removable.
$staleBusy = Resolve-ThreeDSSdLifecycle -CurrentTargets @($card) -SelectedTarget $card `
    -EjectedDeviceInstanceId $card.DeviceInstanceId -Busy $true
Assert-Equal 'Mounted + busy' $staleBusy.State 'A busy mounted card with a stale eject record was mislabelled.'
Assert-Equal $false $staleBusy.ShowsSuccessfulEject 'A busy mounted card claimed to be safely removable.'

# A different card appearing after the ejected one left clears the old record.
$otherCard = New-Target -DiskNumber 2 -DriveLetter 'E:' -UniqueId 'USBSTOR\SECOND' -DeviceId 'USBSTOR\SECOND&0'
$replaced = Resolve-ThreeDSSdLifecycle -CurrentTargets @($otherCard) -SelectedTarget $otherCard `
    -EjectedDeviceInstanceId $card.DeviceInstanceId -EjectRemovalObserved $true
Assert-Equal 'Mounted + idle' $replaced.State 'A replacement card was not brought into service.'
Assert-Equal '' $replaced.EjectedDeviceInstanceId 'The old eject record survived a card swap.'

# --- Full transition sequence ----------------------------------------------
# idle -> ejecting -> safe to remove -> absent -> reinserted -> identified idle
$sequence = @()
$record = ''; $observedAbsence = $false
$step = Resolve-ThreeDSSdLifecycle -CurrentTargets @($card) -SelectedTarget $card -EjectedDeviceInstanceId $record -EjectRemovalObserved $observedAbsence
$sequence += $step.State
$step = Resolve-ThreeDSSdLifecycle -CurrentTargets @($card) -SelectedTarget $card -Ejecting $true
$sequence += $step.State
$record = $card.DeviceInstanceId; $observedAbsence = $true
$step = Resolve-ThreeDSSdLifecycle -CurrentTargets @() -SelectedTarget $null -EjectedDeviceInstanceId $record -EjectRemovalObserved $observedAbsence
$sequence += $step.State
$record = $step.EjectedDeviceInstanceId; $observedAbsence = $step.EjectRemovalObserved
$step = Resolve-ThreeDSSdLifecycle -CurrentTargets @($card) -SelectedTarget $null -EjectedDeviceInstanceId $record -EjectRemovalObserved $observedAbsence
$sequence += $step.State
$record = $step.EjectedDeviceInstanceId; $observedAbsence = $step.EjectRemovalObserved
$step = Resolve-ThreeDSSdLifecycle -CurrentTargets @($card) -SelectedTarget $card -EjectedDeviceInstanceId $record -EjectRemovalObserved $observedAbsence
$sequence += $step.State
$expectedSequence = 'Mounted + idle,Ejecting,Safe to remove SD card,Reinserted - identifying,Mounted + idle'
Assert-Equal $expectedSequence ($sequence -join ',') 'Lifecycle transition sequence mismatch.'

# --- Zero-item and null inputs must not throw ------------------------------
$empty = Resolve-ThreeDSSdLifecycle -CurrentTargets @() -SelectedTarget $null
Assert-Equal 'No SD card detected' $empty.State 'Empty-collection resolution failed.'
$nullTargets = Resolve-ThreeDSSdLifecycle -CurrentTargets $null -SelectedTarget $null
Assert-Equal 'No SD card detected' $nullTargets.State 'Null-collection resolution failed.'
$withNulls = Resolve-ThreeDSSdLifecycle -CurrentTargets @($null, $card, $null) -SelectedTarget $card
Assert-Equal 'Mounted + idle' $withNulls.State 'Null entries broke lifecycle resolution.'

# --- Unhealthy volume stays usable for read-only work, and says so ----------
$warned = New-Target -VolumeHealth 'Warning'
$warnState = Resolve-ThreeDSSdLifecycle -CurrentTargets @($warned) -SelectedTarget $warned
Assert-Equal 'Mounted + idle' $warnState.State 'An unhealthy-volume card was not reported as mounted.'
Assert-Equal $true $warnState.CanUseSd 'An unhealthy-volume card was blocked from read-only reconciliation.'
# The dirty flag is surfaced as a small advisory and must not claim that work is blocked.
if ($warnState.EjectStateText -notmatch 'flagged') { throw 'Volume health advisory was not surfaced in the eject label.' }
if ($warnState.StatusText -notmatch 'flagged') { throw 'Volume health advisory was not surfaced in the status text.' }
if ($warnState.StatusText -match 'blocked') { throw 'The advisory still claims that writes or cleanup are blocked.' }
if ($warnState.EjectStateText -notmatch 'ready to eject') { throw 'An advisory-health card was not presented as usable.' }

# --- Other drives never count as SD media -----------------------------------
# The bug this pins: an internal NVMe data drive (not the boot disk) was listed
# beside the card.  With two entries nothing was auto-selected, the manager sat at
# "Identifying SD card..." indefinitely, the automatic game check never ran, and
# Check SD card repeated the same non-choice.  The same drive also made
# "No SD card detected" and the confirmed safe eject unreachable.
$internal = New-Target -DiskNumber 0 -DriveLetter 'T:' -UniqueId 'NVME\INTERNAL' -DeviceId 'SCSI\DISK&VEN_NVME&0' `
    -EjectDeviceId 'PCI\NVME' -BusType 'NVMe' -HasNintendo3DS $false
$stick = New-Target -DiskNumber 3 -DriveLetter 'E:' -UniqueId 'USBSTOR\STICK' -DeviceId 'USBSTOR\STICK&0' `
    -EjectDeviceId 'USB\STICK' -HasNintendo3DS $false
$internal3ds = New-Target -DiskNumber 4 -DriveLetter 'S:' -UniqueId 'SATA\DATA' -DeviceId 'SCSI\DISK&VEN_SATA&0' `
    -EjectDeviceId 'PCI\SATA' -BusType 'SATA'
$systemUsb = New-Target -DiskNumber 5 -DriveLetter 'Y:' -UniqueId 'USBSTOR\SYSTEM' -DeviceId 'USBSTOR\SYSTEM&0'
$systemUsb.IsSystem = $true

$mixed = @($internal, $stick, $internal3ds, $systemUsb, $card)
$selection = Resolve-ThreeDSSdSelection -Volumes $mixed -SelectedTarget $null
Assert-Equal 1 @($selection.Candidates).Count 'Volumes other than the 3DS SD card were offered as SD cards.'
Assert-Equal 0 $selection.SelectedIndex 'The only 3DS SD card was not selected automatically.'
Assert-Equal 'D:' $selection.Selected.DriveLetter 'The wrong volume was selected as the SD card.'

$withOthers = Resolve-ThreeDSSdLifecycle -CurrentTargets $mixed -SelectedTarget $selection.Selected
Assert-Equal 'Mounted + idle' $withOthers.State 'The card was not usable while other drives were attached.'
Assert-Equal $true $withOthers.CanUseSd 'Other drives kept the automatic game check blocked.'

$onlyOthers = Resolve-ThreeDSSdLifecycle -CurrentTargets @($internal, $stick, $internal3ds, $systemUsb) -SelectedTarget $null
Assert-Equal 'No SD card detected' $onlyOthers.State 'Another drive was reported as a connected SD card.'

$ejectedBesideOthers = Resolve-ThreeDSSdLifecycle -CurrentTargets @($internal, $stick) -SelectedTarget $null `
    -EjectedDeviceInstanceId $card.DeviceInstanceId -EjectRemovalObserved $true
Assert-Equal 'Safe to remove SD card' $ejectedBesideOthers.State 'Another drive hid the confirmed safe eject.'
Assert-Equal $true $ejectedBesideOthers.ShowsSuccessfulEject 'Another drive suppressed the successful-eject message.'

# Several 3DS cards wait for the user's choice, which then survives re-enumeration.
$second = New-Target -DiskNumber 2 -DriveLetter 'F:' -UniqueId 'USBSTOR\SECOND' -DeviceId 'USBSTOR\SECOND&0'
$ambiguous = Resolve-ThreeDSSdSelection -Volumes @($internal, $card, $second) -SelectedTarget $null
Assert-Equal 2 @($ambiguous.Candidates).Count 'Both connected 3DS SD cards were not offered.'
Assert-Equal (-1) $ambiguous.SelectedIndex 'A card was guessed while two 3DS SD cards were connected.'
$choose = Resolve-ThreeDSSdLifecycle -CurrentTargets @($internal, $card, $second) -SelectedTarget $null
Assert-Equal 'Reinserted - identifying' $choose.State 'Two unselected cards were not awaiting a choice.'
Assert-Equal $false $choose.CanUseSd 'SD work was offered before a card was chosen.'
if ($choose.StatusText -notmatch 'Choose the card') { throw 'Two connected cards did not ask the user to choose one.' }
if ($choose.StatusText -match 'Check for changes|Check SD card') { throw 'Two connected cards pointed at a re-check, which cannot choose between them.' }
if ($choose.HeaderText -match 'Identifying') { throw 'The header claimed identification was in progress while waiting for a choice.' }

$reenumerated = @($internal, (New-Target),
    (New-Target -DiskNumber 2 -DriveLetter 'F:' -UniqueId 'USBSTOR\SECOND' -DeviceId 'USBSTOR\SECOND&0'))
$kept = Resolve-ThreeDSSdSelection -Volumes $reenumerated -SelectedTarget $second
Assert-Equal 1 $kept.SelectedIndex 'The chosen card was dropped when the SD list was refreshed.'
Assert-Equal 'F:' $kept.Selected.DriveLetter 'Refreshing the SD list switched to a different card.'
$chosen = Resolve-ThreeDSSdLifecycle -CurrentTargets $reenumerated -SelectedTarget $kept.Selected
Assert-Equal 'Mounted + idle' $chosen.State 'A chosen card among several was not usable.'

# A lone card with an incomplete identity is still listed and selected, so the
# lifecycle can explain why it is unusable instead of reporting no card.
$unreadable = Resolve-ThreeDSSdSelection -Volumes @($internal, $notVerified) -SelectedTarget $null
Assert-Equal 0 $unreadable.SelectedIndex 'A 3DS card with an unreadable identity was hidden.'

# Zero-item, null, and partial inputs must not throw under strict mode.
$none = Resolve-ThreeDSSdSelection -Volumes @() -SelectedTarget $null
Assert-Equal 0 @($none.Candidates).Count 'An empty enumeration produced SD candidates.'
Assert-Equal (-1) $none.SelectedIndex 'An empty enumeration selected a card.'
$nullVolumes = Resolve-ThreeDSSdSelection -Volumes $null -SelectedTarget $card
Assert-Equal (-1) $nullVolumes.SelectedIndex 'A null enumeration selected a card.'
$partial = Resolve-ThreeDSSdSelection -Volumes @([pscustomobject]@{ DriveLetter='X:' }, $null, $card) -SelectedTarget $null
Assert-Equal 0 $partial.SelectedIndex 'A volume missing identity properties broke SD selection.'
Assert-Equal $false (Test-ThreeDSSdCandidate -Volume $null) 'A null volume was treated as an SD card.'

# --- Every state must produce non-empty, non-contradictory text -------------
foreach ($state in @($idle,$busy,$ejecting,$removed,$absent,$reinserted,$errored,$unverified,
    $notACard,$withOthers,$onlyOthers,$ejectedBesideOthers,$choose,$chosen)) {
    foreach ($field in @('HeaderText','StatusText','EjectStateText')) {
        if ([string]::IsNullOrWhiteSpace([string]$state.$field)) {
            throw "State '$($state.State)' produced an empty $field."
        }
    }
    if (-not $state.ShowsSuccessfulEject) {
        foreach ($field in @('StatusText','EjectStateText')) {
            if ([string]$state.$field -match 'Safe to remove') {
                throw "State '$($state.State)' leaked a successful-eject message into $field."
            }
        }
    }
    if ($state.ShowsSuccessfulEject -and $state.CanUseSd) {
        throw "State '$($state.State)' claimed both safe-to-remove and usable."
    }
    if ($state.CanEject -and -not $state.IsMounted) {
        throw "State '$($state.State)' offered eject for a card that is not mounted."
    }
}

[pscustomobject]@{
    Status='PASS'; StatesDeclared=7; StatesExercised=$observed.Keys.Count
    MountedIdle='PASS'; MountedBusy='PASS'; Ejecting='PASS'; SafeToRemove='PASS'; Absent='PASS'
    ReinsertedNotReidentified='PASS'; ErrorUncertain='PASS'
    SafeToRemoveRequiresConfirmedAbsence='PASS'
    MountedCardNeverKeepsStaleEjectMessage='PASS'
    MountedCardNeverHidden='PASS'
    TransitionSequence=$expectedSequence
    UnhealthyVolumeStillReadable='PASS'; EmptyAndNullInputs='PASS'; TextInvariants='PASS'
    OtherDrivesNeverCountAsSd='PASS'; LoneCardSelectedBesideOtherDrives='PASS'
    EjectConfirmedBesideOtherDrives='PASS'; SeveralCardsAwaitChoice='PASS'; ChosenCardSurvivesRefresh='PASS'
} | Format-List
