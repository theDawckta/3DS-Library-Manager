$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if (-not $env:THREEDS_MANAGER_DATA_ROOT) {
    $env:THREEDS_MANAGER_DATA_ROOT = Join-Path $env:TEMP ('BackupsNew3DS.Isolated.' + [guid]::NewGuid().ToString('N'))
}
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\ThreeDSLibrary.Core.psm1') -Force -DisableNameChecking

function Assert-Equal($Expected,$Actual,[string]$Message){if($Expected -ne $Actual){throw "$Message Expected '$Expected'; got '$Actual'."}}
function Assert-Throws([scriptblock]$Action,[string]$Message){$threw=$false;try{& $Action}catch{$threw=$true};if(-not $threw){throw $Message}}
function New-Target([int]$DiskNumber=1,[string]$DriveLetter='D:',[string]$UniqueId='USBSTOR\EXPECTED',[string]$DeviceId='USBSTOR\EXPECTED&0',[string]$EjectDeviceId='USB\READER'){
    [pscustomobject]@{
        DiskNumber=$DiskNumber;DriveLetter=$DriveLetter;DiskUniqueId=$UniqueId;DeviceInstanceId=$DeviceId;EjectDeviceInstanceId=$EjectDeviceId
        DiskCapacityBytes=[uint64]127999672320;BusType='USB';HasNintendo3DS=$true;IsBoot=$false;IsSystem=$false
        VolumeLabel='N3DS';VolumeHealthStatus='Healthy';VolumeCapacityBytes=[uint64]127982960640;FreeBytes=[uint64]29247733760
    }
}

$selected=New-Target
$current=New-Target
# A probe that reports the device gone -- the normal successful physical removal.
$goneProbe={ @() }
# A probe that keeps reporting the device -- Windows accepted but nothing left.
$stillPresentProbe={ @((New-Target)) }.GetNewClosure()

$resolved=Resolve-ThreeDSEjectTarget -SelectedTarget $selected -CurrentTargets @($current)
Assert-Equal 'USBSTOR\EXPECTED&0' $resolved.DeviceInstanceId 'Physical identity binding mismatch.'

$script:requestedDevice=''
$successAction={param($deviceId)$script:requestedDevice=$deviceId;[pscustomobject]@{Success=$true;VetoType='Unknown';VetoName=''}}
$success=Invoke-ThreeDSSafeEject -SelectedTarget $selected -CurrentTargets @($current) -EjectAction $successAction -PresenceProbe $goneProbe
Assert-Equal $true $success.Success 'Idle eject did not succeed.'
Assert-Equal $true $success.RemovalConfirmed 'Confirmed removal was not reported.'
Assert-Equal 'Safe to remove SD card' $success.State 'Successful eject UI state mismatch.'
Assert-Equal 'USB\READER' $script:requestedDevice 'Eject was not requested for the verified reader device.'

# Windows accepted the request but the device is still enumerated.  This must never
# be presented as safe to physically remove.
$unconfirmed=Invoke-ThreeDSSafeEject -SelectedTarget $selected -CurrentTargets @($current) `
    -EjectAction $successAction -PresenceProbe $stillPresentProbe -RemovalTimeoutSeconds 0 -PollIntervalMilliseconds 50
Assert-Equal $true $unconfirmed.Success 'An accepted eject request was not reported as accepted.'
Assert-Equal $false $unconfirmed.RemovalConfirmed 'A still-connected device was reported as removed.'
Assert-Equal 'SD state uncertain' $unconfirmed.State 'An unconfirmed removal was not reported as uncertain.'
if($unconfirmed.Message -match 'safe to remove'){throw 'An unconfirmed removal told the user the card was safe to remove.'}

# A device that disappears on a later poll is still a confirmed removal.
$script:pollCount=0
$delayedProbe={ $script:pollCount++; if($script:pollCount -ge 2){ @() } else { @((New-Target)) } }
$delayed=Invoke-ThreeDSSafeEject -SelectedTarget $selected -CurrentTargets @($current) `
    -EjectAction $successAction -PresenceProbe $delayedProbe -RemovalTimeoutSeconds 5 -PollIntervalMilliseconds 50
Assert-Equal $true $delayed.RemovalConfirmed 'A device that unmounted asynchronously was not confirmed removed.'
Assert-Equal 'Safe to remove SD card' $delayed.State 'Delayed removal state mismatch.'

$script:busyActionCalled=$false
$busy=Invoke-ThreeDSSafeEject -SelectedTarget $selected -CurrentTargets @($current) -ManagerBusy $true -EjectAction {param($id)$script:busyActionCalled=$true}
Assert-Equal $false $busy.Success 'Active-operation eject unexpectedly succeeded.'
Assert-Equal 'Mounted + busy' $busy.State 'Active-operation eject state mismatch.'
Assert-Equal $false $script:busyActionCalled 'Native eject was called during an active operation.'

$script:vetoProbeCalled=$false
$blocked=Invoke-ThreeDSSafeEject -SelectedTarget $selected -CurrentTargets @($current) -EjectAction {
    param($id)[pscustomobject]@{Success=$false;VetoType='OutstandingOpen';VetoName='explorer.exe';EjectResultCode=23}
} -PresenceProbe { $script:vetoProbeCalled=$true; @() }
Assert-Equal $false $blocked.Success 'Open-handle veto unexpectedly succeeded.'
Assert-Equal $false $blocked.RemovalConfirmed 'A vetoed eject reported a confirmed removal.'
Assert-Equal 'Mounted + idle' $blocked.State 'Open-handle failure did not leave the card mounted and usable.'
Assert-Equal $false $script:vetoProbeCalled 'A vetoed eject still probed for removal.'
if($blocked.Message -notmatch 'OutstandingOpen' -or $blocked.Message -notmatch 'explorer.exe'){throw 'Open-handle detail was not surfaced.'}

$staleLetter=New-Target -DriveLetter 'E:'
Assert-Throws {Resolve-ThreeDSEjectTarget -SelectedTarget $selected -CurrentTargets @($staleLetter)} 'A stale drive letter was accepted.'

$wrongDevice=New-Target -UniqueId 'USBSTOR\OTHER' -DeviceId 'USBSTOR\OTHER&0'
$script:wrongActionCalled=$false
Assert-Throws {Invoke-ThreeDSSafeEject -SelectedTarget $selected -CurrentTargets @($wrongDevice) -EjectAction {param($id)$script:wrongActionCalled=$true} -PresenceProbe $goneProbe} 'The wrong removable device was accepted.'
Assert-Equal $false $script:wrongActionCalled 'Native eject was called for the wrong removable device.'

$wrongCapacity=New-Target
$wrongCapacity.DiskCapacityBytes=[uint64]31000000000
$script:capacityActionCalled=$false
Assert-Throws {Invoke-ThreeDSSafeEject -SelectedTarget $selected -CurrentTargets @($wrongCapacity) -EjectAction {param($id)$script:capacityActionCalled=$true} -PresenceProbe $goneProbe} 'A device with a different capacity was accepted.'
Assert-Equal $false $script:capacityActionCalled 'Native eject was called for a device of the wrong capacity.'

$sharedReaderTarget=New-Target -DiskNumber 2 -DriveLetter 'E:' -UniqueId 'USBSTOR\SECOND' -DeviceId 'USBSTOR\SECOND&1'
Assert-Throws {Invoke-ThreeDSSafeEject -SelectedTarget $selected -CurrentTargets @($current,$sharedReaderTarget) -EjectAction $successAction -PresenceProbe $goneProbe} 'A reader shared by another mounted device was ejected.'

Assert-Throws {Resolve-ThreeDSEjectTarget -SelectedTarget $selected -CurrentTargets @()} 'An ejected stale selection remained usable.'
$reinsertedSelection=New-Target -DiskNumber 4 -DriveLetter 'F:'
$reinsertedCurrent=New-Target -DiskNumber 4 -DriveLetter 'F:'
$reinserted=Invoke-ThreeDSSafeEject -SelectedTarget $reinsertedSelection -CurrentTargets @($reinsertedCurrent) -EjectAction $successAction -PresenceProbe $goneProbe
Assert-Equal $true $reinserted.Success 'Reinserted, positively reidentified device was rejected.'

# An unfingerprinted selection must never reach the native eject request.
$noFingerprint=New-Target
$noFingerprint.EjectDeviceInstanceId=''
Assert-Throws {Resolve-ThreeDSEjectTarget -SelectedTarget $noFingerprint -CurrentTargets @($current)} 'A selection with no reader fingerprint was accepted.'

# Every state this function returns must exist in the single lifecycle model.
$declared=@(Get-ThreeDSSdLifecycleStateNames)
foreach($result in @($success,$unconfirmed,$delayed,$busy,$blocked,$reinserted)){
    if($result.State -notin $declared){throw "Safe eject returned '$($result.State)', which is not a declared lifecycle state."}
}

[pscustomobject]@{
    Status='PASS';IdentityBinding='PASS';IdleEject='PASS';BusyDisabled='PASS';OpenHandleVeto='PASS'
    SuccessfulStateTransition='PASS';UnconfirmedRemovalIsUncertain='PASS';DelayedRemovalConfirmed='PASS'
    StaleLetterRejected='PASS';ReinsertionReidentified='PASS';WrongDeviceRejected='PASS'
    WrongCapacityRejected='PASS';SharedReaderRejected='PASS';UnfingerprintedRejected='PASS'
    StatesWithinLifecycleModel='PASS'
}|Format-List
