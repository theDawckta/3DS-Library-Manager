Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ThreeDSManagerDataRoot {
    $root = if ($env:THREEDS_MANAGER_DATA_ROOT) {
        $env:THREEDS_MANAGER_DATA_ROOT
    }
    else {
        Join-Path $env:LOCALAPPDATA 'BackupsNew3DS\LibraryManager'
    }
    if (-not (Test-Path -LiteralPath $root)) {
        New-Item -ItemType Directory -Path $root -Force | Out-Null
    }
    [IO.Path]::GetFullPath($root)
}

function Get-ThreeDSByteSum {
    # Windows PowerShell 5.1 emits NO object at all from `Measure-Object -Property X -Sum`
    # when the pipeline is empty, so the idiomatic `(... | Measure-Object X -Sum).Sum`
    # dereferences $null and throws PropertyNotFoundException under Set-StrictMode.
    # Every aggregate total in this project must survive a zero-item collection.
    [CmdletBinding()]
    [OutputType([uint64])]
    param(
        [AllowNull()] [AllowEmptyCollection()] [object[]]$Items,
        [Parameter(Mandatory)] [string]$Property
    )
    [uint64]$total = 0
    foreach ($item in @($Items)) {
        if ($null -eq $item) { continue }
        $member = $item.PSObject.Properties[$Property]
        if (-not $member -or $null -eq $member.Value) {
            throw "Cannot total '$Property': an item in the collection does not expose that property."
        }
        $total += [uint64]$member.Value
    }
    $total
}

function Assert-ThreeDSExternalDataPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$RepositoryRoot
    )
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'A data folder must be selected.' }
    $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $fullRepo = [IO.Path]::GetFullPath($RepositoryRoot).TrimEnd('\')
    if ($fullPath.Equals($fullRepo, [StringComparison]::OrdinalIgnoreCase) -or
        $fullPath.StartsWith($fullRepo + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'ROMs, CIAs, and console data must remain outside the Git repository.'
    }
    $fullPath
}

function Get-ThreeDSToolchain {
    $dataRoot = Get-ThreeDSManagerDataRoot
    $toolRoot = Join-Path $dataRoot 'tools'
    $ctrtool = Join-Path $toolRoot 'ctrtool\ctrtool.exe'
    $converter = Join-Path $toolRoot '3dsconv\3dsconv\3dsconv.py'
    $pydeps = Join-Path $toolRoot 'pydeps'
    $pythonCandidates = @(
        'C:\Program Files\Python313\python.exe'
        'C:\Program Files\Python312\python.exe'
        'C:\Program Files\Python311\python.exe'
    )
    $python = $pythonCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $python) {
        $command = Get-Command python.exe -ErrorAction SilentlyContinue
        if ($command) { $python = $command.Source }
    }

    [pscustomobject]@{
        ToolRoot = $toolRoot
        CtrToolPath = $ctrtool
        ConverterPath = $converter
        PythonPath = $python
        PythonDependenciesPath = $pydeps
        Ready = [bool]((Test-Path -LiteralPath $ctrtool) -and
            (Test-Path -LiteralPath $converter) -and
            $python -and (Test-Path -LiteralPath (Join-Path $pydeps 'pyaes')))
    }
}

function Get-ThreeDSSafeVolumes {
    $results = @()
    foreach ($partition in @(Get-Partition | Where-Object DriveLetter)) {
        $disk = Get-Disk -Number $partition.DiskNumber
        if ($disk.IsBoot -or $disk.IsSystem) { continue }
        $diskDrive = try {
            Get-CimInstance -ClassName Win32_DiskDrive -Filter ("Index={0}" -f $disk.Number) -ErrorAction Stop |
                Select-Object -First 1
        }
        catch { $null }
        $ejectDeviceInstanceId = if ($diskDrive) {
            try {
                [string](Get-PnpDeviceProperty -InstanceId ([string]$diskDrive.PNPDeviceID) `
                    -KeyName 'DEVPKEY_Device_Parent' -ErrorAction Stop).Data
            }
            catch { '' }
        }
        else { '' }
        $volume = $null
        for ($attempt = 1; $attempt -le 4 -and -not $volume; $attempt++) {
            try { $volume = Get-Volume -DriveLetter $partition.DriveLetter -ErrorAction Stop | Select-Object -First 1 }
            catch { if ($attempt -lt 4) { Start-Sleep -Milliseconds 250 } }
        }
        if (-not $volume) { continue }
        $root = '{0}:\' -f $partition.DriveLetter
        $cimVolume = try {
            Get-CimInstance -ClassName Win32_Volume -ErrorAction Stop |
                Where-Object DriveLetter -eq ('{0}:' -f $partition.DriveLetter) |
                Select-Object -First 1
        }
        catch { $null }
        $results += [pscustomobject]@{
            DiskNumber = [int]$disk.Number
            DiskUniqueId = [string]$disk.UniqueId
            DiskSerialNumber = [string]$disk.SerialNumber
            DeviceInstanceId = if ($diskDrive) { [string]$diskDrive.PNPDeviceID } else { '' }
            EjectDeviceInstanceId = $ejectDeviceInstanceId
            DiskCapacityBytes = [uint64]$disk.Size
            DiskModel = [string]$disk.FriendlyName
            BusType = [string]$disk.BusType
            PartitionStyle = [string]$disk.PartitionStyle
            PartitionCount = @(Get-Partition -DiskNumber $disk.Number).Count
            DriveLetter = '{0}:' -f $partition.DriveLetter
            Root = $root
            VolumeLabel = [string]$volume.FileSystemLabel
            FileSystem = [string]$volume.FileSystem
            VolumeCapacityBytes = [uint64]$volume.Size
            FreeBytes = [uint64]$volume.SizeRemaining
            AllocationUnitBytes = if ($cimVolume) { [uint64]$cimVolume.BlockSize } else { 0 }
            VolumeHealthStatus = [string]$volume.HealthStatus
            HealthStatus = [string]$disk.HealthStatus
            OperationalStatus = [string]($disk.OperationalStatus -join ', ')
            HasNintendo3DS = Test-Path -LiteralPath (Join-Path $root 'Nintendo 3DS') -PathType Container
            IsBoot = [bool]$disk.IsBoot
            IsSystem = [bool]$disk.IsSystem
        }
    }
    @($results)
}

function Assert-ThreeDSSafeTarget {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [int]$DiskNumber,
        [Parameter(Mandatory)] [uint64]$ExpectedDiskCapacityBytes,
        [Parameter(Mandatory)] [string]$ExpectedDriveLetter,
        [switch]$AllowUnhealthyVolume
    )

    $matches = @(Get-ThreeDSSafeVolumes | Where-Object {
        $_.DiskNumber -eq $DiskNumber -and $_.DriveLetter -eq $ExpectedDriveLetter
    })
    if ($matches.Count -ne 1) { throw 'Windows temporarily lost the selected SD volume. Wait a moment, then choose Check for changes and try again. No files were changed.' }
    $target = $matches[0]
    if ($target.DiskCapacityBytes -ne $ExpectedDiskCapacityBytes) { throw 'The selected disk capacity changed.' }
    if ($target.IsBoot -or $target.IsSystem) { throw 'Refusing to use a boot or system disk.' }
    if ($target.BusType -ne 'USB') { throw 'The selected target is not USB-attached removable storage.' }
    if ($target.PartitionStyle -ne 'MBR' -or $target.PartitionCount -ne 1) {
        throw 'The selected target is not MBR with exactly one partition.'
    }
    # The 3DS reads FAT32.  Cluster size is a speed choice (3ds.hacks.guide uses 32 KiB for cards of
    # 64 GB or less and 64 KiB above), not an identity or safety property, so any size is accepted.
    if ($target.FileSystem -ne 'FAT32') {
        throw 'The selected SD card is not formatted FAT32. Format it as 3ds.hacks.guide describes, then try again.'
    }
    if (-not $AllowUnhealthyVolume -and $target.VolumeHealthStatus -ne 'Healthy') {
        throw "Windows reports the SD volume health as '$($target.VolumeHealthStatus)'. Repair and verify the filesystem before any copy or cleanup. No files were changed."
    }
    if (-not $target.HasNintendo3DS) { throw 'The selected target has no Nintendo 3DS directory.' }
    $target
}

function Resolve-ThreeDSEjectTarget {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $SelectedTarget,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$CurrentTargets
    )
    $diskUniqueId = [string]$SelectedTarget.DiskUniqueId
    $deviceInstanceId = [string]$SelectedTarget.DeviceInstanceId
    $ejectDeviceInstanceId = [string]$SelectedTarget.EjectDeviceInstanceId
    if ([string]::IsNullOrWhiteSpace($diskUniqueId) -or [string]::IsNullOrWhiteSpace($deviceInstanceId) -or
        [string]::IsNullOrWhiteSpace($ejectDeviceInstanceId)) {
        throw 'The selected SD card has no verified physical-device fingerprint. Refresh the SD list before ejecting.'
    }
    $matches = @($CurrentTargets | Where-Object {
        ([string]$_.DiskUniqueId).Equals($diskUniqueId, [StringComparison]::OrdinalIgnoreCase) -and
        ([string]$_.DeviceInstanceId).Equals($deviceInstanceId, [StringComparison]::OrdinalIgnoreCase) -and
        ([string]$_.EjectDeviceInstanceId).Equals($ejectDeviceInstanceId, [StringComparison]::OrdinalIgnoreCase) -and
        [uint64]$_.DiskCapacityBytes -eq [uint64]$SelectedTarget.DiskCapacityBytes
    })
    if ($matches.Count -ne 1) {
        throw 'The selected physical SD card is no longer uniquely present. Nothing was ejected.'
    }
    $current = $matches[0]
    if ([int]$current.DiskNumber -ne [int]$SelectedTarget.DiskNumber -or
        [string]$current.DriveLetter -ne [string]$SelectedTarget.DriveLetter) {
        throw 'The SD disk number or drive letter changed after selection. Refresh and reselect the card before ejecting.'
    }
    if ($current.IsBoot -or $current.IsSystem -or $current.BusType -ne 'USB' -or -not $current.HasNintendo3DS) {
        throw 'The selected device no longer satisfies the 3DS SD safety checks. Nothing was ejected.'
    }
    $otherMountedDevicesOnReader = @($CurrentTargets | Where-Object {
        ([string]$_.EjectDeviceInstanceId).Equals($ejectDeviceInstanceId, [StringComparison]::OrdinalIgnoreCase) -and
        -not ([string]$_.DeviceInstanceId).Equals($deviceInstanceId, [StringComparison]::OrdinalIgnoreCase)
    })
    if ($otherMountedDevicesOnReader.Count) {
        throw 'Another mounted storage device shares this reader. Refusing to eject the reader.'
    }
    $current
}

function Invoke-ThreeDSNativeDeviceEject {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$DeviceInstanceId)
    if (-not ('ThreeDSSafeEjectNative' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class ThreeDSSafeEjectNative {
    public enum PnpVetoType {
        Unknown = 0, LegacyDevice = 1, PendingClose = 2, WindowsApp = 3,
        WindowsService = 4, OutstandingOpen = 5, Device = 6, Driver = 7,
        IllegalDeviceRequest = 8, InsufficientPower = 9, NonDisableable = 10,
        LegacyDriver = 11, InsufficientRights = 12
    }

    [DllImport("CfgMgr32.dll", CharSet = CharSet.Unicode)]
    private static extern int CM_Locate_DevNodeW(out uint deviceInstance, string deviceId, uint flags);

    [DllImport("CfgMgr32.dll", CharSet = CharSet.Unicode)]
    private static extern int CM_Request_Device_EjectW(uint deviceInstance, out PnpVetoType vetoType,
        StringBuilder vetoName, int vetoNameLength, uint flags);

    public sealed class EjectResult {
        public int LocateResult { get; set; }
        public int EjectResultCode { get; set; }
        public PnpVetoType VetoType { get; set; }
        public string VetoName { get; set; }
        public bool Success { get { return LocateResult == 0 && EjectResultCode == 0; } }
    }

    public static EjectResult Request(string deviceInstanceId) {
        uint deviceInstance;
        int locate = CM_Locate_DevNodeW(out deviceInstance, deviceInstanceId, 0);
        if (locate != 0) {
            return new EjectResult { LocateResult = locate, EjectResultCode = -1,
                VetoType = PnpVetoType.Unknown, VetoName = "" };
        }
        var vetoName = new StringBuilder(512);
        PnpVetoType veto;
        int result = CM_Request_Device_EjectW(deviceInstance, out veto, vetoName, vetoName.Capacity, 0);
        return new EjectResult { LocateResult = locate, EjectResultCode = result,
            VetoType = veto, VetoName = vetoName.ToString() };
    }
}
'@
    }
    $native = [ThreeDSSafeEjectNative]::Request($DeviceInstanceId)
    [pscustomobject]@{
        Success=[bool]$native.Success
        LocateResult=[int]$native.LocateResult
        EjectResultCode=[int]$native.EjectResultCode
        VetoType=[string]$native.VetoType
        VetoName=[string]$native.VetoName
    }
}

function Invoke-ThreeDSSafeEject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $SelectedTarget,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$CurrentTargets,
        [bool]$ManagerBusy = $false,
        [scriptblock]$EjectAction,
        [scriptblock]$PresenceProbe,
        [scriptblock]$WaitAction,
        [ValidateRange(0,60)] [int]$RemovalTimeoutSeconds = 6,
        [ValidateRange(50,5000)] [int]$PollIntervalMilliseconds = 300
    )
    if ($ManagerBusy) {
        return [pscustomobject]@{
            Success=$false; RemovalConfirmed=$false; State='Mounted + busy'
            Message='Wait for the active SD operation to finish before ejecting.'
            Target=$null; NativeResult=$null
        }
    }
    $target = Resolve-ThreeDSEjectTarget -SelectedTarget $SelectedTarget -CurrentTargets $CurrentTargets
    $action = if ($EjectAction) { $EjectAction } else { { param($deviceId) Invoke-ThreeDSNativeDeviceEject -DeviceInstanceId $deviceId } }
    $native = & $action $target.EjectDeviceInstanceId
    if (-not $native -or -not $native.Success) {
        $vetoType = if ($native -and $native.PSObject.Properties['VetoType']) { [string]$native.VetoType } else { 'Unknown' }
        $vetoName = if ($native -and $native.PSObject.Properties['VetoName']) { [string]$native.VetoName } else { '' }
        if ($vetoType -notin @('LegacyDevice','PendingClose','WindowsApp','WindowsService','OutstandingOpen','Device','Driver','LegacyDriver')) {
            $vetoName = ''
        }
        $vetoName = ($vetoName -replace '[\x00-\x1F]+',' ').Trim()
        if ($vetoName.Length -gt 260) { $vetoName = $vetoName.Substring(0,260) }
        $detail = if ($vetoName) { "$vetoType ($vetoName)" } else { $vetoType }
        # Windows refused: the card was never ejected, so it is still mounted and idle.
        return [pscustomobject]@{
            Success=$false; RemovalConfirmed=$false; State='Mounted + idle'
            Message="Windows refused the safe eject: $detail. Close applications using the SD card and retry."
            Target=$target; NativeResult=$native
        }
    }

    # Windows accepted the request.  "Safe to remove" is only true once the exact
    # verified device has actually stopped being enumerated -- an accepted request
    # whose device is still mounted is uncertain, never removable.
    $probe = if ($PresenceProbe) { $PresenceProbe } else { { Get-ThreeDSSafeVolumes } }
    $deviceId = [string]$target.DeviceInstanceId
    $deadline = (Get-Date).AddSeconds($RemovalTimeoutSeconds)
    $removalConfirmed = $false
    do {
        $present = @(@(& $probe) | Where-Object {
            $null -ne $_ -and ([string]$_.DeviceInstanceId).Equals($deviceId, [StringComparison]::OrdinalIgnoreCase)
        })
        if (-not $present.Count) { $removalConfirmed = $true; break }
        if ((Get-Date) -ge $deadline) { break }
        if ($WaitAction) { & $WaitAction | Out-Null }
        Start-Sleep -Milliseconds $PollIntervalMilliseconds
    } while ($true)

    if (-not $removalConfirmed) {
        return [pscustomobject]@{
            Success=$true; RemovalConfirmed=$false; State='SD state uncertain'
            Message='Windows accepted the eject request but still reports the SD card as connected. Do not pull the card yet; choose Check for changes and try again.'
            Target=$target; NativeResult=$native
        }
    }
    [pscustomobject]@{
        Success=$true; RemovalConfirmed=$true; State='Safe to remove SD card'
        Message='Windows safely ejected the verified 3DS SD card. It can now be physically removed.'
        Target=$target; NativeResult=$native
    }
}

# ---------------------------------------------------------------------------
# SD lifecycle state model
#
# One authoritative resolver owns every SD state the interface can show.  The
# UI never invents a message or an enabled control: it renders whatever
# Resolve-ThreeDSSdLifecycle returns.  Physical presence is the authority --
# a remembered eject can never outrank a volume Windows still enumerates.
# ---------------------------------------------------------------------------

function Get-ThreeDSSdLifecycleStateNames {
    [OutputType([string[]])]
    param()
    @(
        'Mounted + idle'            # mounted, verified, nothing running
        'Mounted + busy'            # mounted, verified, an SD operation is active
        'Ejecting'                  # eject request in flight
        'Safe to remove SD card'    # Windows ejected it AND the device is confirmed gone
        'No SD card detected'       # absent
        'Reinserted - identifying'  # media present, not yet positively reidentified
        'SD state uncertain'        # error, or a claim contradicted by the hardware
    )
}

function Test-ThreeDSVerifiedSdTarget {
    param([AllowNull()]$Target)
    if (-not $Target) { return $false }
    foreach ($name in @('HasNintendo3DS','DiskUniqueId','DeviceInstanceId','EjectDeviceInstanceId')) {
        if (-not $Target.PSObject.Properties[$name]) { return $false }
    }
    [bool]($Target.HasNintendo3DS -and [string]$Target.DiskUniqueId -and
        [string]$Target.DeviceInstanceId -and [string]$Target.EjectDeviceInstanceId)
}

function Get-ThreeDSTargetFingerprint {
    param([AllowNull()]$Target)
    if (-not $Target) { return '' }
    foreach ($name in @('DiskUniqueId','DeviceInstanceId','EjectDeviceInstanceId','DiskCapacityBytes')) {
        if (-not $Target.PSObject.Properties[$name]) { return '' }
    }
    '{0}|{1}|{2}|{3}' -f ([string]$Target.DiskUniqueId).ToUpperInvariant(),
        ([string]$Target.DeviceInstanceId).ToUpperInvariant(),
        ([string]$Target.EjectDeviceInstanceId).ToUpperInvariant(),
        [uint64]$Target.DiskCapacityBytes
}

function Test-ThreeDSSdCandidate {
    # The single definition of "a 3DS SD card" for detection and the lifecycle model:
    # USB-attached, not a boot/system disk, and holding a Nintendo 3DS folder -- the
    # identity the eject and write gates already enforce.  Internal drives, other USB
    # storage and empty reader slots are never offered, auto-selected, or counted as
    # connected SD media, so a permanently attached disk can neither block automatic
    # identification nor mask a confirmed eject.
    param([AllowNull()]$Volume)
    if (-not $Volume) { return $false }
    foreach ($name in @('BusType','HasNintendo3DS','IsBoot','IsSystem')) {
        if (-not $Volume.PSObject.Properties[$name]) { return $false }
    }
    [bool]([string]$Volume.BusType -eq 'USB' -and $Volume.HasNintendo3DS -and
        -not $Volume.IsBoot -and -not $Volume.IsSystem)
}

function Resolve-ThreeDSSdSelection {
    # Decides what the SD list offers and which card it selects.  A chosen card stays
    # selected while its exact physical fingerprint is still uniquely present; failing
    # that, a lone candidate is selected automatically, and several candidates wait for
    # the user's choice rather than a guess.
    [CmdletBinding()]
    param(
        [AllowNull()] [AllowEmptyCollection()] [object[]]$Volumes = @(),
        [AllowNull()] $SelectedTarget = $null
    )
    $candidates = @(@($Volumes) | Where-Object { Test-ThreeDSSdCandidate -Volume $_ })
    $selectedIndex = -1
    $fingerprint = Get-ThreeDSTargetFingerprint -Target $SelectedTarget
    if ($fingerprint) {
        $matching = @(for ($i = 0; $i -lt $candidates.Count; $i++) {
            if ((Get-ThreeDSTargetFingerprint -Target $candidates[$i]) -eq $fingerprint) { $i }
        })
        if ($matching.Count -eq 1) { $selectedIndex = [int]$matching[0] }
    }
    if ($selectedIndex -lt 0 -and $candidates.Count -eq 1) { $selectedIndex = 0 }
    [pscustomobject]@{
        Candidates = $candidates
        SelectedIndex = $selectedIndex
        Selected = if ($selectedIndex -ge 0) { $candidates[$selectedIndex] } else { $null }
    }
}

function Resolve-ThreeDSSdLifecycle {
    [CmdletBinding()]
    param(
        [AllowNull()] [AllowEmptyCollection()] [object[]]$CurrentTargets = @(),
        [AllowNull()] $SelectedTarget = $null,
        [string]$EjectedDeviceInstanceId = '',
        [bool]$EjectRemovalObserved = $false,
        [bool]$Busy = $false,
        [bool]$Ejecting = $false,
        [string]$EnumerationError = ''
    )

    # Only 3DS SD candidates are connected SD media; any other volume Windows
    # enumerates (an internal disk, a USB stick) is invisible to this model.
    $targets = @(@($CurrentTargets) | Where-Object { Test-ThreeDSSdCandidate -Volume $_ })
    $ejectedId = [string]$EjectedDeviceInstanceId
    $removalObserved = [bool]$EjectRemovalObserved
    $ejectedStillMounted = $false
    if ($ejectedId) {
        $ejectedStillMounted = [bool]@($targets | Where-Object {
            ([string]$_.DeviceInstanceId).Equals($ejectedId, [StringComparison]::OrdinalIgnoreCase)
        }).Count
    }

    $state = ''
    $detail = ''
    $target = $null

    if ($EnumerationError) {
        $state = 'SD state uncertain'
        $detail = $EnumerationError
    }
    elseif ($Ejecting) {
        $state = 'Ejecting'
        $detail = 'Rechecking the physical device and asking Windows to remove it safely.'
    }
    else {
        if ($ejectedId) {
            if ($ejectedStillMounted) {
                # The remembered eject is contradicted by the hardware: Windows still
                # enumerates that exact device.  Drop the claim rather than keep
                # telling the user that a mounted, usable card is safe to pull.
                $ejectedId = ''
                $removalObserved = $false
            }
            else {
                $removalObserved = $true
                if (-not $targets.Count) {
                    $state = 'Safe to remove SD card'
                    $detail = 'Windows ejected the verified device and no longer reports it.'
                }
                else {
                    # The ejected card is gone but other media is present.
                    $ejectedId = ''
                    $removalObserved = $false
                }
            }
        }

        if (-not $state) {
            if (-not $targets.Count) {
                $state = 'No SD card detected'
                $detail = 'No removable 3DS SD card is connected.'
            }
            else {
                $selectedFingerprint = Get-ThreeDSTargetFingerprint -Target $SelectedTarget
                $matched = @()
                if ($selectedFingerprint) {
                    $matched = @($targets | Where-Object {
                        (Get-ThreeDSTargetFingerprint -Target $_) -eq $selectedFingerprint
                    })
                }
                if ($matched.Count -ne 1) {
                    $state = 'Reinserted - identifying'
                    $detail = if ($targets.Count -gt 1) {
                        "$($targets.Count) 3DS SD cards are connected. Choose the card to use from the SD card list."
                    }
                    else { 'A card is connected but has not been positively reidentified yet. Choose Check for changes.' }
                }
                else {
                    $target = $matched[0]
                    if (-not (Test-ThreeDSVerifiedSdTarget -Target $target)) {
                        $state = 'SD state uncertain'
                        $detail = 'The connected card is not a verified 3DS SD card.'
                        $target = $null
                    }
                    elseif ($Busy) {
                        $state = 'Mounted + busy'
                        $detail = 'An SD operation is running. Ejecting is disabled until it finishes.'
                    }
                    else {
                        $state = 'Mounted + idle'
                        $detail = 'The verified 3DS SD card is connected and idle.'
                    }
                }
            }
        }
    }

    $isMounted = $state -in @('Mounted + idle','Mounted + busy')
    $canUseSd = ($state -eq 'Mounted + idle')
    $canEject = ($state -eq 'Mounted + idle')
    $unhealthyVolume = [bool]($target -and [string]$target.VolumeHealthStatus -and
        [string]$target.VolumeHealthStatus -ne 'Healthy')
    # Several 3DS cards need the user's choice; Check for changes cannot resolve that.
    $awaitingChoice = ($state -eq 'Reinserted - identifying' -and $targets.Count -gt 1)

    $ejectStateText = switch ($state) {
        'Mounted + idle'           { if ($unhealthyVolume) { 'Connected - ready to eject (Windows check flagged)' } else { 'Connected - ready to eject' } }
        'Mounted + busy'           { 'SD in use' }
        'Ejecting'                 { 'Ejecting...' }
        'Safe to remove SD card'   { 'Safe to remove SD card' }
        'No SD card detected'      { 'No SD card connected' }
        'Reinserted - identifying' { if ($awaitingChoice) { 'Choose the SD card to use' } else { 'Identifying the SD card...' } }
        default                    { 'SD state uncertain' }
    }

    $headerText = switch ($state) {
        'Mounted + idle'           { "SD detected: $($target.VolumeLabel) $($target.DriveLetter)" }
        'Mounted + busy'           { "SD in use: $($target.VolumeLabel) $($target.DriveLetter)" }
        'Ejecting'                 { 'Ejecting SD card...' }
        'Safe to remove SD card'   { 'SD safely ejected' }
        'No SD card detected'      { 'SD card not detected' }
        'Reinserted - identifying' { if ($awaitingChoice) { 'Choose an SD card' } else { 'Identifying SD card...' } }
        default                    { 'SD state uncertain' }
    }

    $statusText = switch ($state) {
        'Mounted + idle' {
            # Advisory only.  The dirty flag does not block preparing, staging or
            # cleaning up; per-file verification is what decides those.
            $health = if ($unhealthyVolume) {
                " Windows has flagged this card for a routine check; games can still be prepared and verified."
            } else { '' }
            "Ready: $($target.VolumeLabel) on $($target.DriveLetter), $([Math]::Round($target.FreeBytes/1GB,1)) GiB free. Physical identity is rechecked before eject and every copy.$health"
        }
        'Mounted + busy'           { "$($target.VolumeLabel) on $($target.DriveLetter) is in use. Wait for the current operation to finish." }
        'Ejecting'                 { 'Asking Windows to safely remove the verified SD card...' }
        'Safe to remove SD card'   { 'Safe to remove the SD card. It must be physically removed and reinserted before this app will use it again.' }
        'No SD card detected'      { 'Connect the 3DS SD card. It is found automatically, or choose Check for changes.' }
        'Reinserted - identifying' { if ($awaitingChoice) { $detail } else { 'A card is connected. Choose Check for changes to identify it before any SD action.' } }
        default                    { $detail }
    }

    [pscustomobject]@{
        State = $state
        Detail = $detail
        IsMounted = $isMounted
        CanUseSd = $canUseSd
        CanEject = $canEject
        ShowsSuccessfulEject = ($state -eq 'Safe to remove SD card')
        Target = $target
        EjectedDeviceInstanceId = $ejectedId
        EjectRemovalObserved = $removalObserved
        HeaderText = $headerText
        StatusText = $statusText
        EjectStateText = $ejectStateText
    }
}

function Get-ThreeDSProfileRoot {
    param([Parameter(Mandatory)] [string]$SdRoot)
    $nintendoRoot = Join-Path $SdRoot 'Nintendo 3DS'
    $id0 = @(Get-ChildItem -LiteralPath $nintendoRoot -Directory -ErrorAction Stop |
        Where-Object Name -Match '^[0-9a-fA-F]{32}$')
    if ($id0.Count -ne 1) { throw "Expected one normal ID0; found $($id0.Count)." }
    $id1 = @(Get-ChildItem -LiteralPath $id0[0].FullName -Directory -ErrorAction Stop |
        Where-Object Name -Match '^[0-9a-fA-F]{32}$')
    if ($id1.Count -ne 1) { throw "Expected one normal ID1; found $($id1.Count)." }
    $id1[0].FullName
}

function Get-ThreeDSCardKey {
    <#
        A stable key for one SD card as used by one console: its Nintendo 3DS profile folder
        names (ID0 comes from the console, ID1 from the card).  It is hashed, so no console
        identifier is stored, and it is a safe state-filename key.  The same card keeps its key
        across readers, drive letters and sessions; a different card or console gets another.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$SdRoot)
    $profileRoot = Get-ThreeDSProfileRoot -SdRoot $SdRoot
    $id1 = Split-Path -Leaf $profileRoot
    $id0 = Split-Path -Leaf (Split-Path -Parent $profileRoot)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes(('3ds-card|{0}|{1}' -f $id0.ToUpperInvariant(), $id1.ToUpperInvariant()))
        ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').Substring(0, 16)
    }
    finally { $sha.Dispose() }
}

function Get-ThreeDSInstalledTitles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$SdRoot,
        [object[]]$ExpectedTitles = @(),
        [switch]$FullReadCheck,
        [scriptblock]$ProgressAction
    )

    $profile = Get-ThreeDSProfileRoot -SdRoot $SdRoot
    $types = [ordered]@{
        '00040000' = 'Base'
        '0004000e' = 'Update'
        '0004008c' = 'DLC'
    }
    $expectedById = @{}
    foreach ($expected in $ExpectedTitles) {
        if ($expected.TitleId) { $expectedById[$expected.TitleId.ToUpperInvariant()] = $expected }
    }
    $expectedPositionById = @{}
    $expectedOrder = @($expectedById.Keys | Sort-Object)
    for ($expectedIndex = 0; $expectedIndex -lt $expectedOrder.Count; $expectedIndex++) {
        $expectedPositionById[$expectedOrder[$expectedIndex]] = $expectedIndex + 1
    }
    $items = @()
    foreach ($high in $types.Keys) {
        $typeRoot = Join-Path $profile ("title\{0}" -f $high)
        if (-not (Test-Path -LiteralPath $typeRoot -PathType Container)) { continue }
        foreach ($dir in Get-ChildItem -LiteralPath $typeRoot -Directory) {
            if ($dir.Name -notmatch '^[0-9a-fA-F]{8}$') { continue }
            $titleId = ($high + $dir.Name).ToUpperInvariant()
            $files = @(Get-ChildItem -LiteralPath $dir.FullName -Recurse -File -Force -ErrorAction Stop)
            # A Title-ID folder holding no files is not an installation: GodMode9 leaves
            # one behind when it refuses a damaged CIA before writing anything.  Nothing
            # there needs console-side removal, so the title stays Missing and can be
            # restaged; reporting it would block every retry on an unremovable leftover.
            if ($files.Count -eq 0) { continue }
            $contentRoot = Join-Path $dir.FullName 'content'
            $dataRoot = Join-Path $dir.FullName 'data'
            $apps = @(if (Test-Path -LiteralPath $contentRoot) {
                @(Get-ChildItem -LiteralPath $contentRoot -File -Filter '*.app' -Force)
            } else { @() })
            $tmds = @(if (Test-Path -LiteralPath $contentRoot) {
                @(Get-ChildItem -LiteralPath $contentRoot -File -Filter '*.tmd' -Force)
            } else { @() })
            $cmds = @(if (Test-Path -LiteralPath (Join-Path $contentRoot 'cmd')) {
                @(Get-ChildItem -LiteralPath (Join-Path $contentRoot 'cmd') -File -Filter '*.cmd' -Force)
            } else { @() })
            $errors = @()
            $notes = @()
            if ($apps.Count -lt 1) { $errors += 'No installed .app content files.' }
            if ($apps | Where-Object Length -le 0) { $errors += 'One or more .app content files are empty.' }
            if ($tmds.Count -ne 1 -or ($tmds.Count -eq 1 -and $tmds[0].Length -le 0)) {
                $errors += 'Expected exactly one non-empty installed TMD.'
            }
            if ($cmds.Count -lt 1 -or ($cmds | Where-Object Length -le 0)) {
                $errors += 'No complete non-empty installed CMD metadata.'
            }

            $expected = if ($expectedById.ContainsKey($titleId)) { $expectedById[$titleId] } else { $null }
            $hasExpectedManifest = [bool]($expected -and $expected.PSObject.Properties['ContentManifest'] -and
                @($expected.ContentManifest).Count -gt 0)
            if ($hasExpectedManifest) {
                $actualById = @{}
                foreach ($app in $apps) { $actualById[$app.BaseName.ToUpperInvariant()] = $app }
                foreach ($content in @($expected.ContentManifest)) {
                    $contentId = ([string]$content.ContentId).ToUpperInvariant()
                    if (-not $actualById.ContainsKey($contentId)) {
                        $errors += "Missing expected content $contentId.app."
                    }
                    elseif ([uint64]$actualById[$contentId].Length -ne [uint64]$content.Length) {
                        $errors += "Installed length mismatch for $contentId.app."
                    }
                }
                $expectedIds = @(@($expected.ContentManifest) | ForEach-Object { ([string]$_.ContentId).ToUpperInvariant() })
                $unexpected = @($apps | Where-Object { $_.BaseName.ToUpperInvariant() -notin $expectedIds })
                if ($unexpected.Count) { $errors += 'Unexpected installed .app content exists.' }
                if ($expected.PSObject.Properties['SaveSizeBytes'] -and [uint64]$expected.SaveSizeBytes -gt 0) {
                    $saves = @(if (Test-Path -LiteralPath $dataRoot) {
                        @(Get-ChildItem -LiteralPath $dataRoot -File -Filter '*.sav' -Force)
                    } else { @() })
                    if ($saves.Count -ne 1) { $errors += 'Expected exactly one title save container.' }
                    elseif ([uint64]$saves[0].Length -ne [uint64]$expected.SaveSizeBytes) {
                        $errors += 'Installed save-container length mismatch.'
                    }
                }
                if ($FullReadCheck -and $errors.Count -eq 0) {
                    try {
                        foreach ($file in @($apps + $tmds + $cmds)) {
                            $callerProgress = $ProgressAction
                            $currentTitleId = $titleId
                            $currentTitleName = if ($expected.PSObject.Properties['Title'] -and $expected.Title) { [string]$expected.Title } else { $titleId }
                            $currentTitlePosition = [int]$expectedPositionById[$titleId]
                            $currentExpectedCount = $expectedOrder.Count
                            $readProgress = {
                                param($done,$total)
                                if ($callerProgress) {
                                    $finished = $currentTitlePosition - 1
                                    $remaining = $currentExpectedCount - $currentTitlePosition
                                    & $callerProgress "Verifying game $currentTitlePosition of $currentExpectedCount`: $currentTitleName. $finished finished, $remaining remaining after this." $done $total | Out-Null
                                }
                            }.GetNewClosure()
                            Get-ThreeDSFileSHA256 -Path $file.FullName -ProgressAction $readProgress | Out-Null
                        }
                        $notes += 'All installed content/metadata files passed a complete read.'
                    }
                    catch { $errors += ('Complete read failed: ' + $_.Exception.Message) }
                }
            }
            else {
                $notes += 'No validated CIA content manifest is available for comparison.'
            }

            # An exact match to the validated manifest (content IDs, lengths, metadata and
            # save) is enough: the card path is trusted, so no full read is required.
            # -FullReadCheck remains an optional diagnostic that can only demote.
            $health = if ($errors.Count) { 'Unhealthy' } elseif ($hasExpectedManifest) { 'Healthy' } else { 'Uncertain' }
            $items += [pscustomobject]@{
                TitleId = $titleId
                Type = $types[$high]
                InstalledFileCount = $files.Count
                InstalledBytes = Get-ThreeDSByteSum -Items $files -Property 'Length'
                HasSave = [bool]($files | Where-Object FullName -Match '(?i)\\data\\.*\.sav$')
                Health = $health
                State = "Installed + $($health.ToLowerInvariant())"
                HealthDetails = @($errors + $notes) -join ' '
                ExpectedManifestMatched = [bool]($hasExpectedManifest -and $errors.Count -eq 0)
            }
        }
    }
    @($items | Sort-Object Type, TitleId)
}

function Get-ThreeDSSdSpaceUsage {
    <#
        Splits the card into games, other and free space for the space chart.  Games are
        installed titles (base, update and DLC) plus CIAs waiting in install folders, taken
        from the inventory already read; other is everything else in use, including the
        filesystem's own allocation slack.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [uint64]$TotalBytes,
        [Parameter(Mandatory)] [uint64]$FreeBytes,
        [AllowNull()] [AllowEmptyCollection()] [object[]]$InstalledTitles = @(),
        [AllowNull()] [AllowEmptyCollection()] [object[]]$Batches = @()
    )
    if ($FreeBytes -gt $TotalBytes) { $FreeBytes = $TotalBytes }
    [uint64]$used = $TotalBytes - $FreeBytes
    [uint64]$games = 0
    foreach ($title in @($InstalledTitles)) {
        if ($title -and $title.PSObject.Properties['InstalledBytes']) { $games += [uint64]$title.InstalledBytes }
    }
    foreach ($batch in @($Batches)) {
        if (-not $batch -or -not $batch.PSObject.Properties['Items']) { continue }
        foreach ($item in @($batch.Items)) {
            if ($item -and $item.PSObject.Properties['Length']) { $games += [uint64]$item.Length }
        }
    }
    if ($games -gt $used) { $games = $used }
    [pscustomobject]@{
        TotalBytes = $TotalBytes
        GamesBytes = $games
        OtherBytes = [uint64]($used - $games)
        FreeBytes = $FreeBytes
    }
}

function Convert-ThreeDSSizeTextToBytes {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return [uint64]0 }
    if ($Value -match '^([0-9]+)K$') { return [uint64]$matches[1] * 1KB }
    if ($Value -match '^([0-9]+)M$') { return [uint64]$matches[1] * 1MB }
    if ($Value -match '^([0-9]+)G$') { return [uint64]$matches[1] * 1GB }
    if ($Value -match '^0x([0-9A-Fa-f]+)$') { return [Convert]::ToUInt64($matches[1], 16) }
    [uint64]$Value
}

function Get-ThreeDSRegionFromProductCode {
    param([string]$ProductCode)
    if ([string]::IsNullOrWhiteSpace($ProductCode)) { return '' }
    switch ($ProductCode.Substring($ProductCode.Length - 1).ToUpperInvariant()) {
        'E' { 'USA' }
        'P' { 'Europe' }
        'J' { 'Japan' }
        'U' { 'Australia' }
        'C' { 'China' }
        'K' { 'Korea' }
        'T' { 'Taiwan' }
        default { '' }
    }
}

function Get-ThreeDSFileSHA256 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Path,
        [scriptblock]$ProgressAction
    )
    $item = Get-Item -LiteralPath $Path
    $stream = New-Object IO.FileStream($item.FullName,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read,8MB,[IO.FileOptions]::SequentialScan)
    $sha = [Security.Cryptography.SHA256]::Create()
    $buffer = New-Object byte[] 8MB
    [uint64]$processed = 0
    [uint64]$nextProgress = 0
    try {
        while (($read = $stream.Read($buffer,0,$buffer.Length)) -gt 0) {
            [void]$sha.TransformBlock($buffer,0,$read,$buffer,0)
            $processed += [uint64]$read
            if ($ProgressAction -and ($processed -ge $nextProgress -or $processed -eq [uint64]$item.Length)) {
                & $ProgressAction $processed ([uint64]$item.Length) | Out-Null
                $nextProgress = $processed + 64MB
            }
        }
        [void]$sha.TransformFinalBlock((New-Object byte[] 0),0,0)
        ([BitConverter]::ToString($sha.Hash) -replace '-','').ToUpperInvariant()
    }
    finally {
        $sha.Dispose()
        $stream.Dispose()
    }
}

function Copy-ThreeDSFileWithProgress {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Source,
        [Parameter(Mandatory)] [string]$Destination,
        [scriptblock]$ProgressAction
    )
    $sourceItem = Get-Item -LiteralPath $Source
    $input = New-Object IO.FileStream($sourceItem.FullName,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read,8MB,[IO.FileOptions]::SequentialScan)
    $output = New-Object IO.FileStream($Destination,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None,8MB,[IO.FileOptions]::SequentialScan)
    $buffer = New-Object byte[] 8MB
    [uint64]$processed = 0
    [uint64]$nextProgress = 0
    $completed = $false
    try {
        while (($read = $input.Read($buffer,0,$buffer.Length)) -gt 0) {
            $output.Write($buffer,0,$read)
            $processed += [uint64]$read
            if ($ProgressAction -and ($processed -ge $nextProgress -or $processed -eq [uint64]$sourceItem.Length)) {
                & $ProgressAction $processed ([uint64]$sourceItem.Length) | Out-Null
                $nextProgress = $processed + 64MB
            }
        }
        $output.Flush($true)
        $completed = $true
    }
    finally {
        $output.Dispose()
        $input.Dispose()
        if (-not $completed -and (Test-Path -LiteralPath $Destination -PathType Leaf)) {
            Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
        }
    }
    (Get-Item -LiteralPath $Destination).LastWriteTimeUtc = $sourceItem.LastWriteTimeUtc
}

function Invoke-ThreeDSCtrTool {
    param(
        [Parameter(Mandatory)] [string]$CtrToolPath,
        [Parameter(Mandatory)] [string]$Path,
        [switch]$Verify,
        [string[]]$AdditionalArguments = @(),
        [scriptblock]$HeartbeatAction
    )
    if (-not (Test-Path -LiteralPath $CtrToolPath -PathType Leaf)) { throw 'CTRTool was not found.' }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Input file was not found: $Path" }
    $arguments = @()
    if ($Verify) { $arguments += '-y' }
    $arguments += $AdditionalArguments
    $arguments += $Path
    $quoted = @($arguments | ForEach-Object {
        $value = [string]$_
        if ($value -match '[\s"]') { '"' + $value.Replace('"', '\"') + '"' } else { $value }
    })
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $CtrToolPath
    $startInfo.Arguments = $quoted -join ' '
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    [void]$process.Start()
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    try {
        while (-not $process.WaitForExit(200)) {
            if ($HeartbeatAction) { & $HeartbeatAction | Out-Null }
        }
    }
    catch {
        if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
        throw
    }
    $stdout = $stdoutTask.Result
    $stderr = $stderrTask.Result
    $output = @(($stdout + "`n" + $stderr) -split "`r?`n" | Where-Object { $_ -ne '' })
    [pscustomobject]@{
        ExitCode = $process.ExitCode
        Lines = @($output)
        Text = ($output -join "`n")
    }
}

function Invoke-ThreeDSProcess {
    param(
        [Parameter(Mandatory)] [string]$FilePath,
        [string[]]$Arguments = @(),
        [hashtable]$Environment = @{},
        [scriptblock]$HeartbeatAction
    )
    $quoted = @($Arguments | ForEach-Object {
        $value = [string]$_
        if ($value -match '[\s"]') { '"' + $value.Replace('"', '\"') + '"' } else { $value }
    })
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = $quoted -join ' '
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($name in $Environment.Keys) { $startInfo.EnvironmentVariables[$name] = [string]$Environment[$name] }
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        [void]$process.Start()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        try {
            while (-not $process.WaitForExit(200)) {
                if ($HeartbeatAction) { & $HeartbeatAction | Out-Null }
            }
        }
        catch {
            if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
            throw
        }
        $stdout = $stdoutTask.Result
        $stderr = $stderrTask.Result
        [pscustomobject]@{ ExitCode=$process.ExitCode; Output=@(($stdout + "`n" + $stderr) -split "`r?`n" | Where-Object { $_ -ne '' }) }
    }
    finally { $process.Dispose() }
}

function Read-ThreeDSSmdh {
    param([Parameter(Mandatory)] [string]$Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 0x2020 -or [Text.Encoding]::ASCII.GetString($bytes, 0, 4) -ne 'SMDH') {
        throw 'Extracted icon is not a valid SMDH structure.'
    }
    $decode = {
        param([int]$Offset, [int]$Length)
        ([Text.Encoding]::Unicode.GetString($bytes, $Offset, $Length)).Trim([char]0)
    }
    $mask = [BitConverter]::ToUInt32($bytes, 0x2018)
    $regions = @()
    # Use a hashtable, not OrderedDictionary: numeric OrderedDictionary access
    # is positional, which would map flag 0x02 to the third entry (Europe).
    $map = @{ 1='Japan'; 2='USA'; 4='Europe'; 8='Australia'; 16='China'; 32='Korea'; 64='Taiwan' }
    foreach ($bit in $map.Keys) { if ($mask -band [int]$bit) { $regions += $map[$bit] } }
    [pscustomobject]@{
        ShortTitle = & $decode 0x208 0x80
        LongTitle = & $decode 0x288 0x100
        Publisher = & $decode 0x388 0x80
        RegionMask = ('0x{0:X8}' -f $mask)
        Region = ($regions -join ', ')
    }
}

function Get-ThreeDSImageMetadata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$CtrToolPath,
        [switch]$SkipHash,
        [scriptblock]$HashProgressAction
    )

    $item = Get-Item -LiteralPath $Path
    $extension = $item.Extension.ToLowerInvariant()
    if ($extension -notin @('.3ds', '.cci', '.cia')) { throw "Unsupported source format: $extension" }
    $metadataProgress = $HashProgressAction
    $metadataLength = [uint64]$item.Length
    $metadataHeartbeat = { if ($metadataProgress) { & $metadataProgress 0 $metadataLength } }.GetNewClosure()
    $result = Invoke-ThreeDSCtrTool -CtrToolPath $CtrToolPath -Path $item.FullName -HeartbeatAction $metadataHeartbeat
    $text = $result.Text
    $titleId = $null
    if ($text -match '(?im)^\|?-?\s*TitleId:\s*([0-9a-f]{16})\s*$') { $titleId = $matches[1].ToUpperInvariant() }
    elseif ($text -match '(?im)^Title id:\s*([0-9a-f]{16})\s*$') { $titleId = $matches[1].ToUpperInvariant() }
    $productCode = if ($text -match '(?im)^Product code:\s*(\S+)') { $matches[1] } else { '' }
    $saveBytes = [uint64]0
    if ($text -match '(?im)^\|?\s*\|?-?\s*SaveDataSize:\s*(0x[0-9a-f]+)') {
        $saveBytes = Convert-ThreeDSSizeTextToBytes $matches[1]
    }
    elseif ($text -match '(?im)^Savedata size:\s*(\S+)') {
        $saveBytes = Convert-ThreeDSSizeTextToBytes $matches[1]
    }
    $state = 'Unknown'
    if ($text -match '(?i)appears to be decrypted, contrary to header flags') { $state = 'DecryptedHeaderMismatch' }
    elseif ($text -match '(?im)> Crypto Key\s+None') { $state = 'NoCrypto' }
    elseif ($text -match '(?im)> Crypto Key\s+(?!None)') { $state = 'Encrypted' }

    [pscustomobject]@{
        SourcePath = $item.FullName
        FileName = $item.Name
        Format = $extension.TrimStart('.').ToUpperInvariant()
        Length = [uint64]$item.Length
        SHA256 = if ($SkipHash) { '' } else { Get-ThreeDSFileSHA256 -Path $item.FullName -ProgressAction $HashProgressAction }
        TitleId = $titleId
        ProductCode = $productCode
        Region = Get-ThreeDSRegionFromProductCode -ProductCode $productCode
        SaveSizeBytes = $saveBytes
        EncryptionState = $state
        ToolExitCode = $result.ExitCode
        ToolOutput = $text
    }
}

function Test-ThreeDSCia {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$CtrToolPath,
        [string]$ExpectedTitleId,
        [string]$ExpectedProductCode,
        [uint64]$ExpectedSaveSizeBytes = 0,
        [string]$ExpectedRegion,
        [scriptblock]$ProgressAction
    )

    $item = Get-Item -LiteralPath $Path
    if ($item.Extension -ne '.cia') { throw 'CIA validation requires a .cia input.' }
    $callerProgress = $ProgressAction
    $verifyHeartbeat = { if ($callerProgress) { & $callerProgress 'Inspecting CIA structure' 0 0 | Out-Null } }.GetNewClosure()
    $verify = Invoke-ThreeDSCtrTool -CtrToolPath $CtrToolPath -Path $item.FullName -Verify -HeartbeatAction $verifyHeartbeat
    $text = $verify.Text
    $callerProgress = $ProgressAction
    $hashProgress = { param($done,$total) if ($callerProgress) { & $callerProgress 'Hashing validated CIA' $done $total | Out-Null } }.GetNewClosure()
    $metadata = Get-ThreeDSImageMetadata -Path $item.FullName -CtrToolPath $CtrToolPath -HashProgressAction $hashProgress
    $errors = @()
    if (-not $metadata.TitleId) { $errors += 'Title ID could not be read.' }
    if ($ExpectedTitleId -and $metadata.TitleId -ne $ExpectedTitleId.ToUpperInvariant()) { $errors += 'Title ID mismatch.' }
    if ($ExpectedProductCode -and $metadata.ProductCode -ne $ExpectedProductCode) { $errors += 'Product Code mismatch.' }
    if ($ExpectedSaveSizeBytes -and $metadata.SaveSizeBytes -ne $ExpectedSaveSizeBytes) { $errors += 'Save-size mismatch.' }
    if ($text -match '(?im)Hash:\s*\(FAIL\)|hash:\s*\(FAIL\)|Level [0-9]+:\s*\(FAIL\)') {
        $errors += 'One or more content-integrity hashes failed.'
    }
    # ctrtool renders nested TMD hash rows with tree-drawing prefixes such as
    # "|  \- Hash: (GOOD)".  Accept only prefix characters before Hash so
    # ordinary prose cannot accidentally satisfy this integrity check.
    $contentHashes = @([regex]::Matches($text, '(?im)^\s*[\|\\\-\s]*Hash:\s*\(GOOD\)') |
        ForEach-Object Value).Count
    if ($contentHashes -lt 1) { $errors += 'No GOOD TMD content hashes were found.' }
    if ($text -notmatch '(?im)^Exheader hash:\s*\(GOOD\)' -or
        $text -notmatch '(?im)^ExeFS hash:\s*\(GOOD\)' -or
        $text -notmatch '(?im)^RomFS hash:\s*\(GOOD\)') {
        $errors += 'NCCH ExHeader/ExeFS/RomFS integrity did not fully validate.'
    }
    if ($text -notmatch '(?ims)Section name:\s*banner.*?Section hash:\s*\(GOOD\)' -or
        $text -notmatch '(?ims)Section name:\s*icon.*?Section hash:\s*\(GOOD\)') {
        $errors += 'Icon or banner section hash did not validate.'
    }
    # The CIA content layer and the NCCH layer are encrypted independently, and a
    # decrypted CIA wrapping a Secure-key NCCH is the ordinary eShop shape, so the two
    # flags are not compared.  Crypto consistency is proven above instead: ctrtool
    # applies the NCCH's declared crypto, so a flag that disagrees with the data
    # fails the ExHeader/ExeFS/RomFS hashes.
    $encryptedYes = $text -match '(?im)Encrypted:\s*YES'
    $encryptedNo = $text -match '(?im)Encrypted:\s*NO'
    $cryptoNone = $text -match '(?im)> Crypto Key\s+None'
    $ncchEncrypted = $text -match '(?im)> Crypto Key\s+(?!None)'

    $validationRoot = Join-Path (Get-ThreeDSManagerDataRoot) ('validation\{0}' -f [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $validationRoot -Force | Out-Null
    $contentManifest = @()
    try {
        $prefix = Join-Path $validationRoot 'contents'
        $extractHeartbeat = { if ($callerProgress) { & $callerProgress 'Reading CIA contents' 0 0 | Out-Null } }.GetNewClosure()
        Invoke-ThreeDSCtrTool -CtrToolPath $CtrToolPath -Path $item.FullName -AdditionalArguments @("--contents=$prefix") -HeartbeatAction $extractHeartbeat | Out-Null
        $contents = @(Get-ChildItem -LiteralPath $validationRoot -File -Filter 'contents.*')
        foreach ($content in $contents) {
            if ($content.Name -match '(?i)\.([0-9a-f]{4})\.([0-9a-f]{8})$') {
                $contentManifest += [pscustomobject]@{
                    Index=$matches[1].ToUpperInvariant()
                    ContentId=$matches[2].ToUpperInvariant()
                    Length=[uint64]$content.Length
                }
            }
        }
        if ($contentManifest.Count -ne $contentHashes) {
            $errors += 'Extracted CIA content manifest does not match the verified TMD content count.'
        }
        $application = $contents | Where-Object Name -Match '\.0000\.' | Select-Object -First 1
        if (-not $application) { $application = $contents | Sort-Object Length -Descending | Select-Object -First 1 }
        if (-not $application) { throw 'CIA application content could not be extracted.' }
        $exefs = Join-Path $validationRoot 'application.exefs'
        Invoke-ThreeDSCtrTool -CtrToolPath $CtrToolPath -Path $application.FullName -AdditionalArguments @("--exefs=$exefs") -HeartbeatAction $extractHeartbeat | Out-Null
        $exefsDir = Join-Path $validationRoot 'exefs'
        New-Item -ItemType Directory -Path $exefsDir -Force | Out-Null
        Invoke-ThreeDSCtrTool -CtrToolPath $CtrToolPath -Path $exefs -AdditionalArguments @("--exefsdir=$exefsDir") -HeartbeatAction $extractHeartbeat | Out-Null
        $iconPath = Join-Path $exefsDir 'icon.bin'
        $bannerPath = Join-Path $exefsDir 'banner.bin'
        if (-not (Test-Path -LiteralPath $iconPath) -or -not (Test-Path -LiteralPath $bannerPath)) {
            throw 'Readable icon/banner files were not extracted.'
        }
        $smdh = Read-ThreeDSSmdh -Path $iconPath
        $banner = [IO.File]::ReadAllBytes($bannerPath)
        if ($banner.Length -lt 4 -or [Text.Encoding]::ASCII.GetString($banner, 0, 4) -ne 'CBMD') {
            throw 'Extracted banner is not a valid CBMD structure.'
        }
        $requiredRegion = if ($ExpectedRegion) { $ExpectedRegion } else { $metadata.Region }
        if ($requiredRegion -and $smdh.Region -notmatch [regex]::Escape($requiredRegion)) {
            $errors += 'Region mismatch.'
        }
    }
    catch {
        $errors += $_.Exception.Message
        $smdh = [pscustomobject]@{ ShortTitle=''; LongTitle=''; Publisher=''; RegionMask=''; Region='' }
    }
    finally {
        Remove-Item -LiteralPath $validationRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    [pscustomobject]@{
        IsValid = $errors.Count -eq 0
        Errors = @($errors)
        Path = $item.FullName
        Length = [uint64]$item.Length
        SHA256 = $metadata.SHA256
        TitleId = $metadata.TitleId
        ProductCode = $metadata.ProductCode
        SaveSizeBytes = $metadata.SaveSizeBytes
        Region = $smdh.Region
        RegionMask = $smdh.RegionMask
        Title = if ($smdh.LongTitle) { $smdh.LongTitle -replace "`r?`n", ' ' } else { $smdh.ShortTitle }
        Publisher = $smdh.Publisher
        EncryptionState = if ($encryptedNo -and $cryptoNone) { 'NoCrypto' } elseif ($encryptedYes -or $ncchEncrypted) { 'Encrypted' } else { 'Unknown' }
        GoodContentHashCount = $contentHashes
        ContentManifest = @($contentManifest | Sort-Object Index)
    }
}

function Get-ThreeDSLibraryInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$LibraryRoot,
        [Parameter(Mandatory)] [string]$CtrToolPath,
        [scriptblock]$ProgressAction,
        [object[]]$CachedItems = @(),
        [switch]$ForceRescan
    )
    if (-not (Test-Path -LiteralPath $LibraryRoot -PathType Container)) { throw 'Library folder does not exist.' }
    $files = @(Get-ChildItem -LiteralPath $LibraryRoot -File -Recurse -ErrorAction Stop |
        Where-Object Extension -In @('.3ds', '.cci', '.cia') | Sort-Object FullName)
    $cachedByPath = @{}
    $normalizedCachedItems = @($CachedItems | ForEach-Object { $_ })
    foreach ($cachedItem in $normalizedCachedItems) {
        if ($cachedItem.SourcePath) {
            $cachedByPath[[IO.Path]::GetFullPath([string]$cachedItem.SourcePath).ToUpperInvariant()] = $cachedItem
        }
    }
    $results = @()
    $position = 0
    foreach ($file in $files) {
        $position++
        $cacheKey = $file.FullName.ToUpperInvariant()
        $cached = if ($cachedByPath.ContainsKey($cacheKey)) { $cachedByPath[$cacheKey] } else { $null }
        $cachedTimestamp = if ($cached -and $cached.PSObject.Properties['SourceLastWriteTimeUtc']) { [string]$cached.SourceLastWriteTimeUtc } else { '' }
        $timestampMatches = (-not $cachedTimestamp) -or ($cachedTimestamp -eq $file.LastWriteTimeUtc.ToString('o'))
        $canReuse = (-not $ForceRescan) -and $cached -and [uint64]$cached.SourceLength -eq [uint64]$file.Length -and
            $timestampMatches -and $cached.SourceSHA256 -and $cached.TitleId
        if ($canReuse) {
            if ($ProgressAction) { & $ProgressAction $position $files.Count $file.Name ([uint64]$file.Length) ([uint64]$file.Length) 'Reused' | Out-Null }
            $results += [pscustomobject]@{
                Selected=$true; Title=[IO.Path]::GetFileNameWithoutExtension($file.Name); TitleId=[string]$cached.TitleId
                Type=[string]$cached.Type; Format=[string]$cached.Format; ProductCode=[string]$cached.ProductCode
                Region=[string]$cached.Region; EncryptionState=[string]$cached.EncryptionState
                SaveSizeBytes=[uint64]$cached.SaveSizeBytes; SourcePath=$file.FullName; SourceLength=[uint64]$file.Length
                SourceLastWriteTimeUtc=$file.LastWriteTimeUtc.ToString('o'); SourceSHA256=[string]$cached.SourceSHA256
                Status='Identified'; PreparedPath=[string]$cached.PreparedPath; PreparedSHA256=[string]$cached.PreparedSHA256
                CacheState='Reused'
            }
            continue
        }
        if ($ProgressAction) { & $ProgressAction $position $files.Count $file.Name 0 ([uint64]$file.Length) 'Scanning' | Out-Null }
        try {
            $callerProgress = $ProgressAction
            $currentPosition = $position
            $currentCount = $files.Count
            $currentName = $file.Name
            $hashProgress = {
                param($done,$total)
                if ($callerProgress) { & $callerProgress $currentPosition $currentCount $currentName $done $total | Out-Null }
            }.GetNewClosure()
            $meta = Get-ThreeDSImageMetadata -Path $file.FullName -CtrToolPath $CtrToolPath -HashProgressAction $hashProgress
            $results += [pscustomobject]@{
                Selected = $true
                Title = [IO.Path]::GetFileNameWithoutExtension($file.Name)
                TitleId = $meta.TitleId
                Type = if ($meta.TitleId -match '^0004000E') { 'Update' } elseif ($meta.TitleId -match '^0004008C') { 'DLC' } else { 'Base' }
                Format = $meta.Format
                ProductCode = $meta.ProductCode
                Region = $meta.Region
                EncryptionState = $meta.EncryptionState
                SaveSizeBytes = $meta.SaveSizeBytes
                SourcePath = $meta.SourcePath
                SourceLength = $meta.Length
                SourceLastWriteTimeUtc = $file.LastWriteTimeUtc.ToString('o')
                SourceSHA256 = $meta.SHA256
                Status = if ($meta.TitleId) { 'Identified' } else { 'Needs identification' }
                PreparedPath = ''
                PreparedSHA256 = ''
                CacheState = 'Scanned'
            }
        }
        catch {
            $results += [pscustomobject]@{
                Selected=$false; Title=$file.BaseName; TitleId=''; Type='Unknown'; Format=$file.Extension.TrimStart('.').ToUpperInvariant()
                ProductCode=''; Region=''; EncryptionState='Unknown'; SaveSizeBytes=[uint64]0; SourcePath=$file.FullName; SourceLength=[uint64]$file.Length
                SourceLastWriteTimeUtc=$file.LastWriteTimeUtc.ToString('o'); SourceSHA256=''; Status=('ERROR: ' + $_.Exception.Message)
                PreparedPath=''; PreparedSHA256=''; CacheState='Scanned'
            }
        }
    }
    @($results)
}

function New-ThreeDSSyncPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$LibraryItems,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$InstalledTitles,
        [object[]]$InstallBatches = @()
    )
    $installed = @{}
    foreach ($item in $InstalledTitles) { $installed[$item.TitleId.ToUpperInvariant()] = $item }
    $staged = @{}
    foreach ($batch in $InstallBatches) {
        foreach ($item in @($batch.Items)) {
            $id = $item.TitleId.ToUpperInvariant()
            if (-not $staged.ContainsKey($id)) { $staged[$id] = @() }
            $staged[$id] += $batch.BatchId
        }
    }
    $desired = @{}
    $represented = @{}
    $plan = @()
    foreach ($item in $LibraryItems) {
        if (-not $item.TitleId) { continue }
        $id = $item.TitleId.ToUpperInvariant()
        $represented[$id] = $true
        $isDesired = if ($item.PSObject.Properties['Selected']) { [bool]$item.Selected } else { $true }
        if ($isDesired) { $desired[$id] = $true }
        $state = if ($installed.ContainsKey($id)) { $installed[$id].State } elseif ($staged.ContainsKey($id)) { 'Staged on SD' } else { 'Missing' }
        if (-not $isDesired -and $state -eq 'Missing') { continue }
        $action = if (-not $isDesired -and $state -match '^Installed') { 'Review removal' }
            elseif (-not $isDesired -and $state -eq 'Staged on SD') { 'Review batch cleanup' }
            elseif ($state -eq 'Missing') { 'Prepare + stage' }
            elseif ($state -eq 'Staged on SD') { 'Await console install' }
            elseif ($state -eq 'Installed + healthy') { 'Leave alone' }
            else { 'Diagnose' }
        $plan += [pscustomobject]@{
            Selected = [bool]($isDesired -and $action -eq 'Prepare + stage')
            Title = $item.Title
            TitleId = $id
            Type = $item.Type
            DesiredState = if ($isDesired) { 'Installed' } else { 'Not installed' }
            CurrentState = $state
            Action = $action
            StagedBatchIds = if ($staged.ContainsKey($id)) { $staged[$id] -join ', ' } else { '' }
            SourcePath = $item.SourcePath
            SourceSHA256 = $item.SourceSHA256
            PreparedPath = $item.PreparedPath
            PreparedSHA256 = $item.PreparedSHA256
        }
    }
    foreach ($item in $InstalledTitles) {
        if (-not $represented.ContainsKey($item.TitleId.ToUpperInvariant())) {
            $plan += [pscustomobject]@{
                Selected=$false; Title=''; TitleId=$item.TitleId; Type=$item.Type; DesiredState='Not represented'
                CurrentState=$item.State; Action='Report only'; StagedBatchIds=''; SourcePath=''; SourceSHA256=''; PreparedPath=''; PreparedSHA256=''
            }
        }
    }
    @($plan | Sort-Object Type, TitleId)
}

function Prepare-ThreeDSArtifact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $LibraryItem,
        [Parameter(Mandatory)] $Toolchain,
        [Parameter(Mandatory)] [string]$InstallReadyRoot,
        [string]$Boot9Path,
        [scriptblock]$ProgressAction
    )

    if (-not $LibraryItem.TitleId) { throw 'The selected source has no identified Title ID.' }
    if (-not (Test-Path -LiteralPath $LibraryItem.SourcePath -PathType Leaf)) { throw 'The selected source file is missing.' }
    if (-not (Test-Path -LiteralPath $Toolchain.CtrToolPath -PathType Leaf)) { throw 'CTRTool is not configured.' }
    $callerProgress = $ProgressAction
    $sourceHashProgress = {
        param($done,$total)
        if ($callerProgress) { & $callerProgress "Checking $($LibraryItem.Title)..." $done $total | Out-Null }
    }.GetNewClosure()
    $sourceHash = Get-ThreeDSFileSHA256 -Path $LibraryItem.SourcePath -ProgressAction $sourceHashProgress
    if ($LibraryItem.SourceSHA256 -and $sourceHash -ne $LibraryItem.SourceSHA256.ToUpperInvariant()) {
        throw 'The source SHA-256 changed since the library scan.'
    }

    $workRoot = Join-Path (Get-ThreeDSManagerDataRoot) ('work\{0}-{1}' -f $LibraryItem.TitleId, [guid]::NewGuid().ToString('N'))
    $inputRoot = Join-Path $workRoot 'input'
    $outputRoot = Join-Path $workRoot 'output'
    New-Item -ItemType Directory -Path $inputRoot,$outputRoot -Force | Out-Null
    $preparedCandidate = $null
    $cachePath = $null
    $cacheCreated = $false
    $completed = $false
    try {
        if ($ProgressAction) { & $ProgressAction "Authenticating $($LibraryItem.TitleId)..." | Out-Null }
        if ($LibraryItem.Format -eq 'CIA') {
            $preparedCandidate = $LibraryItem.SourcePath
        }
        elseif ($LibraryItem.Format -in @('3DS', 'CCI')) {
            if (-not (Test-Path -LiteralPath $Toolchain.ConverterPath -PathType Leaf) -or
                -not (Test-Path -LiteralPath $Toolchain.PythonPath -PathType Leaf) -or
                -not (Test-Path -LiteralPath $Toolchain.PythonDependenciesPath -PathType Container)) {
                throw 'The 3dsconv/Python toolchain is not configured.'
            }
            $copyPath = Join-Path $inputRoot ('{0}.3ds' -f $LibraryItem.TitleId)
            $copyProgress = {
                param($done,$total)
                if ($callerProgress) { & $callerProgress "Creating safe working copy of $($LibraryItem.Title)..." $done $total | Out-Null }
            }.GetNewClosure()
            Copy-ThreeDSFileWithProgress -Source $LibraryItem.SourcePath -Destination $copyPath -ProgressAction $copyProgress
            if ((Get-ThreeDSFileSHA256 -Path $copyPath) -ne $sourceHash) {
                throw 'Disposable source-copy hash mismatch.'
            }
            $args = @('--verbose', "--output=$outputRoot")
            if ($LibraryItem.EncryptionState -in @('DecryptedHeaderMismatch', 'NoCrypto')) {
                $args += '--ignore-encryption'
            }
            elseif ($LibraryItem.EncryptionState -eq 'Encrypted') {
                if (-not $Boot9Path -or -not (Test-Path -LiteralPath $Boot9Path -PathType Leaf)) {
                    throw 'This encrypted source requires a user-selected boot9 file outside Git.'
                }
                $args += "--boot9=$Boot9Path"
            }
            else {
                throw 'The source encryption state is unknown; conversion is blocked.'
            }
            # Intentionally never add --ignore-bad-hashes.
            $args += $copyPath
            if ($ProgressAction) { & $ProgressAction "Converting $($LibraryItem.TitleId)..." | Out-Null }
            $convertHeartbeat = { if ($callerProgress) { & $callerProgress "Converting $($LibraryItem.Title)..." 0 0 | Out-Null } }.GetNewClosure()
            $converterArgs = @($Toolchain.ConverterPath) + $args
            $converter = Invoke-ThreeDSProcess -FilePath $Toolchain.PythonPath `
                -Arguments $converterArgs `
                -Environment @{ PYTHONPATH=$Toolchain.PythonDependenciesPath } `
                -HeartbeatAction $convertHeartbeat
            $converterOutput = @($converter.Output)
            $converterExit = $converter.ExitCode
            if ($converterExit -ne 0 -or ($converterOutput -join "`n") -notmatch 'Done converting 1 out of 1 files') {
                throw ('3dsconv did not complete successfully: ' + (($converterOutput | Select-Object -Last 10) -join ' | '))
            }
            $outputs = @(Get-ChildItem -LiteralPath $outputRoot -File -Filter '*.cia')
            if ($outputs.Count -ne 1) { throw "Expected one converted CIA; found $($outputs.Count)." }
            $preparedCandidate = $outputs[0].FullName
        }
        else {
            throw "Unsupported preparation format: $($LibraryItem.Format)"
        }

        if ($ProgressAction) { & $ProgressAction "Validating $($LibraryItem.TitleId)..." | Out-Null }
        $validationProgress = {
            param($message,$done,$total)
            if ($callerProgress) { & $callerProgress "$message - $($LibraryItem.Title)" $done $total | Out-Null }
        }.GetNewClosure()
        $validation = Test-ThreeDSCia -Path $preparedCandidate -CtrToolPath $Toolchain.CtrToolPath `
            -ExpectedTitleId $LibraryItem.TitleId -ExpectedProductCode $LibraryItem.ProductCode `
            -ExpectedSaveSizeBytes ([uint64]$LibraryItem.SaveSizeBytes) -ExpectedRegion $LibraryItem.Region `
            -ProgressAction $validationProgress
        if (-not $validation.IsValid) { throw ('CIA validation failed: ' + ($validation.Errors -join '; ')) }
        if ($LibraryItem.EncryptionState -in @('DecryptedHeaderMismatch', 'NoCrypto') -and
            $validation.EncryptionState -ne 'NoCrypto') {
            throw 'The converted CIA did not produce the required internally consistent NoCrypto state.'
        }

        $type = if ($LibraryItem.Type -in @('Base','Update','DLC')) { $LibraryItem.Type } else { 'Base' }
        $cacheDir = Join-Path $InstallReadyRoot (Join-Path $type $LibraryItem.TitleId)
        New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
        $cachePath = Join-Path $cacheDir ($sourceHash + '.cia')
        if (Test-Path -LiteralPath $cachePath) {
            $existingHash = Get-ThreeDSFileSHA256 -Path $cachePath
            if ($existingHash -ne $validation.SHA256) { throw 'A different artifact already occupies the cache path.' }
        }
        else {
            $cacheCopyProgress = {
                param($done,$total)
                if ($callerProgress) { & $callerProgress "Saving validated copy of $($LibraryItem.Title)..." $done $total | Out-Null }
            }.GetNewClosure()
            Copy-ThreeDSFileWithProgress -Source $preparedCandidate -Destination $cachePath -ProgressAction $cacheCopyProgress
            $cacheCreated = $true
        }
        $cacheHash = Get-ThreeDSFileSHA256 -Path $cachePath
        if ($cacheHash -ne $validation.SHA256) { throw 'InstallReady cache-copy hash mismatch.' }

        $result = [pscustomobject]@{
            Title = $validation.Title
            TitleId = $validation.TitleId
            Type = $type
            ProductCode = $validation.ProductCode
            Region = $validation.Region
            SaveSizeBytes = $validation.SaveSizeBytes
            SourcePath = $LibraryItem.SourcePath
            SourceSHA256 = $sourceHash
            ArtifactPath = $cachePath
            ArtifactLength = [uint64](Get-Item -LiteralPath $cachePath).Length
            ArtifactSHA256 = $cacheHash
            EncryptionState = $validation.EncryptionState
            ContentManifest = @($validation.ContentManifest)
            ValidationStatus = 'Passed'
            CacheDisposition = if ($cacheCreated) { 'Prepared' } else { 'Cached' }
        }
        $completed = $true
        $result
    }
    finally {
        if (-not $completed -and $cacheCreated -and $cachePath -and
            (Test-Path -LiteralPath $cachePath -PathType Leaf)) {
            Remove-Item -LiteralPath $cachePath -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $workRoot) {
            Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Test-ThreeDSCancellation {
    # True when an error is, or wraps, the user's Stop request.
    param([AllowNull()] $ErrorValue)
    $exception = if ($ErrorValue -is [Management.Automation.ErrorRecord]) { $ErrorValue.Exception } else { $ErrorValue }
    while ($exception -is [Exception]) {
        if ($exception -is [OperationCanceledException]) { return $true }
        $exception = $exception.InnerException
    }
    $false
}

function Get-ThreeDSPreparationFailureScope {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $ErrorValue)

    $exception = if ($ErrorValue -is [Management.Automation.ErrorRecord]) {
        $ErrorValue.Exception
    }
    elseif ($ErrorValue -is [Exception]) {
        $ErrorValue
    }
    else {
        [Exception]::new([string]$ErrorValue)
    }
    $message = [string]$exception.Message

    if (Test-ThreeDSCancellation -ErrorValue $exception) {
        return [pscustomobject]@{ Scope='Fatal'; Code='Cancelled'; ConciseError='The operation was stopped by the user.' }
    }

    $fatalPatterns = [ordered]@{
        ToolchainUnavailable = '(?i)CTRTool was not found|CTRTool is not configured|3dsconv/Python toolchain is not configured|helper tools are not ready|Python toolchain'
        InsufficientSpace = '(?i)not enough space|insufficient (?:disk )?space|disk (?:is )?full'
        StorageIntegrity = '(?i)InstallReady cache-copy hash mismatch|Disposable source-copy hash mismatch'
        SdSafety = '(?i)selected (?:disk|target)|Windows temporarily lost the volume|SD volume|not FAT32|not MBR|USB-attached|boot or system disk|Nintendo 3DS directory|disk identity|volume identity'
        AccessDenied = '(?i)access (?:is )?denied|unauthorized access|permission denied'
    }
    foreach ($entry in $fatalPatterns.GetEnumerator()) {
        if ($message -match $entry.Value) {
            return [pscustomobject]@{ Scope='Fatal'; Code=$entry.Key; ConciseError=$message }
        }
    }

    $titlePatterns = [ordered]@{
        ContentIntegrityFailed = '(?i)CIA validation failed:.*(?:content-integrity hashes failed|NCCH ExHeader/ExeFS/RomFS integrity did not fully validate|section hash did not validate)'
        CiaValidationFailed = '(?i)^CIA validation failed:'
        ConversionFailed = '(?i)^3dsconv did not complete successfully:|Expected one converted CIA'
        SourceChanged = '(?i)source SHA-256 changed since the library scan'
        SourceMissing = '(?i)selected source file is missing'
        SourceMetadataMissing = '(?i)selected source has no identified Title ID'
        EncryptionStateUnsupported = '(?i)source encryption state is unknown|encrypted source requires a user-selected boot9'
        UnsupportedFormat = '(?i)unsupported preparation format'
        CacheConflict = '(?i)different artifact already occupies the cache path'
    }
    foreach ($entry in $titlePatterns.GetEnumerator()) {
        if ($message -match $entry.Value) {
            $concise = switch ($entry.Key) {
                'ContentIntegrityFailed' { 'Content-integrity hashes failed; the source or converted CIA is not safe to install.' }
                'ConversionFailed' { 'Conversion failed for this source. See Troubleshooting details for the tool output.' }
                'SourceChanged' { 'The source changed after scanning. Refresh the library before retrying.' }
                'SourceMissing' { 'The source file is missing.' }
                'SourceMetadataMissing' { 'The source has no usable Title ID.' }
                'EncryptionStateUnsupported' { 'This source cannot be decrypted with the current configuration.' }
                'UnsupportedFormat' { 'This source format is not supported.' }
                'CacheConflict' { 'A different prepared file already occupies this source cache location.' }
                default { $message }
            }
            return [pscustomobject]@{ Scope='Title'; Code=$entry.Key; ConciseError=$concise }
        }
    }

    [pscustomobject]@{ Scope='Fatal'; Code='UnexpectedFailure'; ConciseError=$message }
}

function Get-ThreeDSManagerErrorDisplay {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $ErrorValue,
        [string]$Game,
        [string]$Operation
    )
    $exception = if ($ErrorValue -is [Management.Automation.ErrorRecord]) {$ErrorValue.Exception} elseif ($ErrorValue -is [Exception]) {$ErrorValue} else {$null}
    $message = if ($exception) {[string]$exception.Message} else {[string]$ErrorValue}
    $classification = Get-ThreeDSPreparationFailureScope -ErrorValue $ErrorValue
    $invalidStateName = $message -match '^Invalid state filename(?::|\.)'
    $isInternal = $invalidStateName -or $classification.Code -eq 'UnexpectedFailure'
    if (-not $isInternal -or -not $Operation) {
        return [pscustomobject]@{IsInternal=$false;Title='3DS Game Installer';Body=$message}
    }
    $safeGame = if ($Game) {$Game} else {'Not available'}
    $safeOperation = if ($Operation) {$Operation} else {'Not available'}
    $detailLine = if ($invalidStateName) {
        'Invalid state filename: generated state key was rejected; no display title or error text was used.'
    }
    else {
        $safeDetail=($message -replace '[\r\n]+',' ').Trim()
        if($safeDetail.Length -gt 180){$safeDetail=$safeDetail.Substring(0,180)+'...'}
        "Detail: $safeDetail"
    }
    [pscustomobject]@{
        IsInternal=$true
        Title='Internal manager error'
        Body="Internal manager error`n`nGame: $safeGame`nOperation: $safeOperation`n$detailLine"
    }
}

function Get-ThreeDSPreparationStateKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$TitleId,
        [Parameter(Mandatory)] [string]$SourceSHA256
    )
    $normalizedTitleId = $TitleId.ToUpperInvariant()
    $normalizedSourceHash = $SourceSHA256.ToUpperInvariant()
    if ($normalizedTitleId -notmatch '^[A-F0-9]{16}$') { throw 'Invalid preparation-state Title ID.' }
    if ($normalizedSourceHash -notmatch '^[A-F0-9]{64}$') { throw 'Invalid preparation-state source SHA-256.' }
    "$normalizedTitleId-$normalizedSourceHash"
}

function Invoke-ThreeDSPreparationBatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]]$Items,
        [Parameter(Mandatory)] [scriptblock]$PrepareAction,
        [scriptblock]$SuccessAction,
        [scriptblock]$FailureAction
    )

    $artifacts = @()
    $failures = @()
    $preparedCount = 0
    $cachedCount = 0
    for ($index = 0; $index -lt $Items.Count; $index++) {
        $item = $Items[$index]
        try {
            $actionOutput = @(& $PrepareAction $item ($index + 1) $Items.Count)
            if ($actionOutput.Count -ne 1) {
                throw "Preparation returned $($actionOutput.Count) artifacts; expected exactly one."
            }
            $artifact = $actionOutput[0]
            $artifacts += $artifact
            if ($artifact.CacheDisposition -eq 'Cached') { $cachedCount++ } else { $preparedCount++ }
            if ($SuccessAction) { & $SuccessAction $item $artifact ($index + 1) $Items.Count | Out-Null }
        }
        catch {
            $classification = Get-ThreeDSPreparationFailureScope -ErrorValue $_
            if ($classification.Scope -eq 'Fatal') { throw }
            $libraryItem = if ($item.PSObject.Properties['LibraryItem']) { $item.LibraryItem } else { $item }
            $title = if ($item.PSObject.Properties['DisplayTitle'] -and $item.DisplayTitle) {
                [string]$item.DisplayTitle
            }
            elseif ($libraryItem.Title) { [string]$libraryItem.Title } else { [string]$libraryItem.TitleId }
            $failure = [pscustomobject]@{
                Status = 'Failed'
                Title = $title
                TitleId = [string]$libraryItem.TitleId
                SourcePath = [string]$libraryItem.SourcePath
                SourceSHA256 = [string]$libraryItem.SourceSHA256
                StateKey = Get-ThreeDSPreparationStateKey -TitleId ([string]$libraryItem.TitleId) -SourceSHA256 ([string]$libraryItem.SourceSHA256)
                Code = [string]$classification.Code
                Error = [string]$classification.ConciseError
                TechnicalError = [string]$_.Exception.Message
                FailedAt = (Get-Date).ToString('o')
            }
            $failures += $failure
            if ($FailureAction) { & $FailureAction $failure ($index + 1) $Items.Count | Out-Null }
        }
    }

    [pscustomobject]@{
        Artifacts = @($artifacts)
        Failures = @($failures)
        PreparedCount = $preparedCount
        CachedCount = $cachedCount
        FailedCount = $failures.Count
    }
}

function Test-ThreeDSSafeBatchId {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$BatchId)
    $legacyPattern = '^\d{8}-\d{6}(?:-[A-F0-9]{6})?$'
    $friendlyPattern = '^\d+-games - \d{4}-\d{2}-\d{2} \d{2}-\d{2}-\d{2}(?:-[A-F0-9]{6})?$'
    $numberedPattern = '^Batch \d+ of \d+ - \d+ games - \d{4}-\d{2}-\d{2} \d{2}-\d{2}-\d{2}(?:-[A-F0-9]{6})?$'
    ($BatchId -match $legacyPattern -or $BatchId -match $friendlyPattern -or $BatchId -match $numberedPattern)
}

function Get-ThreeDSInstallBatchStateName {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$BatchId)

    if (-not (Test-ThreeDSSafeBatchId -BatchId $BatchId)) { throw 'Unsafe batch ID.' }
    # Keep legacy compact IDs at their existing filenames. Human-readable SD folder names contain
    # spaces, so hash the complete stable batch identity before using it as a private state key.
    $stateKey = if ($BatchId -match '^[A-Za-z0-9._-]+$') {
        $BatchId
    }
    else {
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            $bytes = [Text.Encoding]::UTF8.GetBytes("install-batch|$BatchId")
            ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '')
        }
        finally { $sha.Dispose() }
    }
    "install-batch-$stateKey.json"
}

function New-ThreeDSGuidedBatchPlan {
    <#
        The next copy is the whole queue, in order, limited only by the card's free
        space: when everything does not fit, the games that fit go now and the rest
        follow once these are installed.  -AvailableBytes 0 means no limit.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()] [AllowEmptyCollection()] [object[]]$Items = @(),
        [AllowNull()] [AllowEmptyCollection()] [string[]]$InstalledTitleIds = @(),
        [uint64]$AvailableBytes = 0
    )
    $installed = @{}
    foreach ($titleId in @($InstalledTitleIds)) {
        if ($titleId) { $installed[([string]$titleId).ToUpperInvariant()] = $true }
    }
    $seen = @{}
    $remaining = @()
    foreach ($item in @($Items)) {
        if (-not $item) { continue }
        $titleId = ([string]$item.TitleId).ToUpperInvariant()
        if ($titleId -notmatch '^[A-F0-9]{16}$') { throw 'Queued item has an invalid Title ID.' }
        if ($installed.ContainsKey($titleId) -or $seen.ContainsKey($titleId)) { continue }
        $seen[$titleId] = $true
        $remaining += $item
    }
    $next = @()
    [uint64]$nextBytes = 0
    foreach ($item in $remaining) {
        $length = if ($item.PSObject.Properties['ArtifactLength']) { [uint64]$item.ArtifactLength } else { [uint64]0 }
        if ($AvailableBytes -and ($nextBytes + $length) -gt $AvailableBytes) { break }
        $next += $item
        $nextBytes += $length
    }
    [pscustomobject]@{
        RemainingCount=$remaining.Count
        Remaining=@($remaining)
        NextItems=@($next)
        NextCount=$next.Count
        NextBytes=$nextBytes
        LaterCount=($remaining.Count - $next.Count)
        NextDescription=if ($next.Count) { "$($next.Count) game$(if ($next.Count -ne 1) { 's' })" }
            elseif ($remaining.Count) { 'Not enough free space on the SD card' }
            else { 'No games remaining' }
    }
}

function Resolve-ThreeDSGuidedReturn {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]]$ActiveTitleIds,
        [AllowEmptyCollection()] [string[]]$InstalledTitleIds = @()
    )
    $installed=@{};foreach($id in @($InstalledTitleIds)){if($id){$installed[$id.ToUpperInvariant()]=$true}}
    $seen=@{};$confirmed=@();$remaining=@()
    foreach($id in @($ActiveTitleIds)){
        $normalized=([string]$id).ToUpperInvariant()
        if($normalized -notmatch '^[A-F0-9]{16}$'){throw 'Guided return contains an invalid Title ID.'}
        if($seen.ContainsKey($normalized)){continue};$seen[$normalized]=$true
        if($installed.ContainsKey($normalized)){$confirmed+=$normalized}else{$remaining+=$normalized}
    }
    [pscustomobject]@{
        BatchCount=$seen.Count;InstalledCount=$confirmed.Count;RemainingCount=$remaining.Count
        InstalledTitleIds=@($confirmed);RemainingTitleIds=@($remaining)
        Message="Batch returned: $($confirmed.Count) of $($seen.Count) installed"
    }
}

function Copy-ThreeDSInstallQueue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]]$Artifacts,
        [Parameter(Mandatory)] [int]$TargetDiskNumber,
        [Parameter(Mandatory)] [uint64]$ExpectedDiskCapacityBytes,
        [Parameter(Mandatory)] [string]$ExpectedDriveLetter,
        [scriptblock]$ProgressAction,
        [switch]$AllowAdvisoryVolumeHealth,
        # Receives the smaller batch under 'Batch' when the user stops after one or more
        # games were copied; the stop is still rethrown.
        [hashtable]$Outcome
    )
    if ($Artifacts.Count -eq 0) { throw 'No validated artifacts were supplied.' }
    $target = Assert-ThreeDSSafeTarget -DiskNumber $TargetDiskNumber `
        -ExpectedDiskCapacityBytes $ExpectedDiskCapacityBytes -ExpectedDriveLetter $ExpectedDriveLetter `
        -AllowUnhealthyVolume:$AllowAdvisoryVolumeHealth
    $required = Get-ThreeDSByteSum -Items $Artifacts -Property 'ArtifactLength'
    if ($target.FreeBytes -lt ($required + 512MB)) { throw 'The SD card does not have enough free space plus the safety reserve.' }
    # Every handoff is its own batch folder, so a later GodMode9 session can never
    # pick up stale CIAs from an earlier one.
    $stamp = (Get-Date).ToString('yyyy-MM-dd HH-mm-ss', [Globalization.CultureInfo]::InvariantCulture)
    $queueParent = Join-Path $target.Root 'cias\InstallQueue'
    # A name is never reused, even after its folder is gone: an earlier batch's private
    # record keeps the validated manifests that confirm its games are installed, and the
    # next batch is often copied in the same second that a returned folder is removed.
    $newBatchId = {
        param([int]$Count)
        $id = '{0}-games - {1}' -f $Count, $stamp
        $recordPath = Join-Path (Get-ThreeDSManagerDataRoot) (Get-ThreeDSInstallBatchStateName -BatchId $id)
        if ((Test-Path -LiteralPath (Join-Path $queueParent $id)) -or (Test-Path -LiteralPath $recordPath)) {
            $id += '-' + ([guid]::NewGuid().ToString('N').Substring(0,6).ToUpperInvariant())
        }
        $id
    }
    $batchId = & $newBatchId $Artifacts.Count
    $queueRoot = Join-Path $queueParent $batchId
    New-Item -ItemType Directory -Path $queueRoot -Force | Out-Null
    $queueCompleted = $false
    $staged = @()
    $stopped = $null
    try {
        try {
            $artifactPosition = 0
            foreach ($artifact in $Artifacts) {
                $artifactPosition++
                if (-not (Test-Path -LiteralPath $artifact.ArtifactPath -PathType Leaf)) { throw "Missing cache artifact: $($artifact.TitleId)" }
                # The InstallReady artifact was fully validated and hashed when it was
                # prepared; a length check catches an obviously replaced file cheaply.
                if ([uint64](Get-Item -LiteralPath $artifact.ArtifactPath).Length -ne [uint64]$artifact.ArtifactLength) {
                    throw "The prepared file for $($artifact.TitleId) is no longer the validated artifact."
                }
                $sourceHash = ([string]$artifact.ArtifactSHA256).ToUpperInvariant()
                $callerProgress = $ProgressAction
                $currentArtifactTitle = $artifact.Title
                $currentArtifactPosition = $artifactPosition
                $artifactCount = $Artifacts.Count
                $destination = Join-Path $queueRoot ('{0}-{1}.cia' -f $artifact.TitleId, $sourceHash.Substring(0, 8))
                $sdCopyProgress = { param($done,$total) if ($callerProgress) { & $callerProgress "Copying $currentArtifactPosition of $artifactCount - $currentArtifactTitle" $done $total $currentArtifactPosition $artifactCount | Out-Null } }.GetNewClosure()
                # The card path is trusted: a completed, flushed copy of the validated
                # artifact is recorded as that artifact without reading it back.
                Copy-ThreeDSFileWithProgress -Source $artifact.ArtifactPath -Destination $destination -ProgressAction $sdCopyProgress
                $staged += [pscustomobject]@{
                    Title=$artifact.Title; TitleId=$artifact.TitleId; Type=$artifact.Type
                    ProductCode=$artifact.ProductCode; Region=$artifact.Region; SaveSizeBytes=[uint64]$artifact.SaveSizeBytes
                    ContentManifest=@($artifact.ContentManifest)
                    FileName=[IO.Path]::GetFileName($destination); Length=[uint64]$artifact.ArtifactLength
                    SHA256=$sourceHash
                }
            }
        }
        catch {
            # A stop keeps the games already copied as a smaller batch: each is a complete,
            # flushed copy, and Copy-ThreeDSFileWithProgress has already removed the game it
            # was in the middle of.  Any other failure discards the unfinished batch.
            if (-not ((Test-ThreeDSCancellation -ErrorValue $_) -and $staged.Count)) { throw }
            $stopped = $_
            # The folder name states its game count, so it is renamed to match.
            $smallerId = & $newBatchId $staged.Count
            Rename-Item -LiteralPath $queueRoot -NewName $smallerId
            $batchId = $smallerId
            $queueRoot = Join-Path $queueParent $batchId
        }
        $created = (Get-Date).ToString('o')
        $record = [pscustomobject]@{
            CreatedAt=$created; BatchId=$batchId; BatchState='Staged on SD'
            TargetDiskNumber=$target.DiskNumber; TargetDiskCapacityBytes=$target.DiskCapacityBytes
            TargetVolumeLabel=$target.VolumeLabel
            Queue=@($staged)
            Instructions=@(
                'Boot GodMode9 with START + Power.'
                "Open [0:] SDCARD/cias/InstallQueue/$batchId."
                'Mark every CIA with L, then choose Install game image.'
            )
        }
        $queueRecord = Join-Path $queueRoot 'INSTALL-QUEUE.json'
        $record | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $queueRecord -Encoding UTF8
        # The private record keeps each title's validated content manifest after the
        # folder is gone, so installed health can still be confirmed later.
        Save-ThreeDSManagerState -Name (Get-ThreeDSInstallBatchStateName -BatchId $batchId) -Value ([pscustomobject]@{
            CreatedAt=$created; BatchId=$batchId; BatchState='Staged on SD'
            TargetDiskNumber=$target.DiskNumber; TargetDiskCapacityBytes=$target.DiskCapacityBytes
            TargetVolumeLabel=$target.VolumeLabel; SdRelativePath="cias\InstallQueue\$batchId"; Queue=@($staged)
        }) | Out-Null
        $queueCompleted = $true
        $result = [pscustomobject]@{
            CreatedAt=$created; BatchId=$batchId; BatchState='Staged on SD'
            QueueRoot=$queueRoot; QueueRecord=$queueRecord
            ItemCount=$staged.Count; TotalBytes=(Get-ThreeDSByteSum -Items $staged -Property 'Length')
            Items=@($staged)
        }
        if ($stopped) {
            if ($null -ne $Outcome) { $Outcome['Batch'] = $result }
            throw $stopped
        }
        $result
    }
    finally {
        if (-not $queueCompleted -and (Test-Path -LiteralPath $queueRoot -PathType Container)) {
            $safeQueueParent = [IO.Path]::GetFullPath((Join-Path $target.Root 'cias\InstallQueue')).TrimEnd('\')
            $resolvedQueue = [IO.Path]::GetFullPath($queueRoot).TrimEnd('\')
            if ($resolvedQueue.StartsWith($safeQueueParent + '\', [StringComparison]::OrdinalIgnoreCase) -and
                (Split-Path -Leaf $resolvedQueue) -eq $batchId) {
                Remove-Item -LiteralPath $resolvedQueue -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

function Import-ThreeDSGm9Exports {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$SdRoot,
        [Parameter(Mandatory)] [string]$LibraryRoot,
        [Parameter(Mandatory)] [string]$CtrToolPath,
        [scriptblock]$ProgressAction
    )
    $exportRoot = Join-Path $SdRoot 'gm9\out'
    if (-not (Test-Path -LiteralPath $exportRoot -PathType Container)) {
        throw 'No GodMode9 export folder exists at SD:/gm9/out.'
    }
    $exports = @(Get-ChildItem -LiteralPath $exportRoot -File -Filter '*.cia' -Recurse)
    if ($exports.Count -eq 0) { throw 'No CIA exports were found in SD:/gm9/out.' }
    $imported = @()
    foreach ($file in $exports) {
        if ($ProgressAction) { & $ProgressAction "Validating export $($file.Name)..." | Out-Null }
        $validation = Test-ThreeDSCia -Path $file.FullName -CtrToolPath $CtrToolPath
        if (-not $validation.IsValid) {
            throw "Export validation failed for $($file.Name): $($validation.Errors -join '; ')"
        }
        $type = switch -Regex ($validation.TitleId) {
            '^00040000' { 'Base'; break }
            '^0004000E' { 'Update'; break }
            '^0004008C' { 'DLC'; break }
            default { 'Other' }
        }
        $destinationRoot = Join-Path $LibraryRoot ("ImportedFrom3DS\$type\$($validation.TitleId)")
        New-Item -ItemType Directory -Path $destinationRoot -Force | Out-Null
        $destination = Join-Path $destinationRoot ($validation.SHA256 + '.cia')
        if (Test-Path -LiteralPath $destination) {
            if ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToUpperInvariant() -ne $validation.SHA256) {
                throw "A different file occupies the import destination for $($validation.TitleId)."
            }
        }
        else {
            Copy-Item -LiteralPath $file.FullName -Destination $destination
        }
        if ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToUpperInvariant() -ne $validation.SHA256) {
            throw "Imported CIA hash mismatch for $($validation.TitleId)."
        }
        $imported += [pscustomobject]@{
            Title=$validation.Title; TitleId=$validation.TitleId; Type=$type
            SourcePath=$file.FullName; DestinationPath=$destination; SHA256=$validation.SHA256
            Length=[uint64]$file.Length; Status='Validated and copied (source retained)'
        }
    }
    @($imported)
}

function Get-ThreeDSInstallBatches {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$SdRoot,
        [switch]$VerifyHashes,
        [scriptblock]$ProgressAction
    )
    $root = Join-Path $SdRoot 'cias\InstallQueue'
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return @() }
    $results = @()
    foreach ($directory in Get-ChildItem -LiteralPath $root -Directory | Sort-Object Name) {
        $issues = @()
        $manifestPath = Join-Path $directory.FullName 'INSTALL-QUEUE.json'
        $manifest = $null
        if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { $issues += 'Batch manifest is missing.' }
        else {
            try { $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json }
            catch { $issues += 'Batch manifest is unreadable JSON.' }
        }
        $items = @()
        if ($manifest) {
            foreach ($entry in @($manifest.Queue)) {
                if (-not $entry) { continue }
                $fileName = [string]$entry.FileName
                if ([IO.Path]::GetFileName($fileName) -ne $fileName -or $fileName -notmatch '^[0-9A-F]{16}-[0-9A-F]{8}\.cia$') {
                    $issues += 'Manifest contains an unsafe CIA filename.'
                    continue
                }
                $path = Join-Path $directory.FullName $fileName
                $fileState = 'Present'
                if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { $fileState = 'Missing' }
                elseif ([uint64](Get-Item -LiteralPath $path).Length -ne [uint64]$entry.Length) {
                    $fileState = 'Length mismatch'; $issues += "Staged length mismatch for $($entry.TitleId)."
                }
                elseif ($VerifyHashes) {
                    # Diagnostic only; the manager itself never re-reads staged copies.
                    $callerProgress = $ProgressAction
                    $currentTitleName = if ($entry.Title) { [string]$entry.Title } else { [string]$entry.TitleId }
                    $hashProgress = {
                        param($done,$total)
                        if ($callerProgress) { & $callerProgress "Checking staged game $currentTitleName" $done $total | Out-Null }
                    }.GetNewClosure()
                    if ((Get-ThreeDSFileSHA256 -Path $path -ProgressAction $hashProgress) -ne ([string]$entry.SHA256).ToUpperInvariant()) {
                        $fileState = 'Hash mismatch'; $issues += "Staged hash mismatch for $($entry.TitleId)."
                    }
                }
                $items += [pscustomobject]@{
                    Title=$entry.Title; TitleId=([string]$entry.TitleId).ToUpperInvariant(); Type=$entry.Type
                    ProductCode=$entry.ProductCode; Region=$entry.Region; SaveSizeBytes=[uint64]$entry.SaveSizeBytes
                    ContentManifest=@($entry.ContentManifest); FileName=$fileName; Length=[uint64]$entry.Length
                    SHA256=([string]$entry.SHA256).ToUpperInvariant(); StagedFileState=$fileState; InstallState='Unknown'
                }
            }
        }
        $results += [pscustomobject]@{
            BatchId=$directory.Name; BatchPath=$directory.FullName; ManifestPath=$manifestPath
            CreatedAt=if ($manifest -and $manifest.PSObject.Properties['CreatedAt']) { $manifest.CreatedAt } else { $null }
            Items=@($items); ItemCount=$items.Count; Types=(@($items | ForEach-Object { $_.Type } | Sort-Object -Unique) -join ', ')
            Integrity=if ($issues.Count) { 'Failed' } elseif ($VerifyHashes) { 'Verified' } else { 'Metadata verified' }
            Issues=@($issues); State='Staged on SD'
            InstalledCount=0; RemainingCount=$items.Count; InstalledItems=@(); RemainingItems=@($items)
        }
    }
    @($results)
}

function Get-ThreeDSKnownTitleManifests {
    [CmdletBinding()]
    param()
    $known = @{}
    foreach ($file in @(Get-ChildItem -LiteralPath (Get-ThreeDSManagerDataRoot) -File -Filter 'install-batch-*.json' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc)) {
        try {
            $record = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
            foreach ($item in @($record.Queue)) {
                if ($item.TitleId -and @($item.ContentManifest).Count) {
                    $known[$item.TitleId.ToUpperInvariant()] = $item
                }
            }
        }
        catch { continue }
    }
    @($known.Values)
}

function Resolve-ThreeDSInstallBatches {
    <#
        Marks each staged title Installed when its installed content matches the
        validated manifest, and Remaining otherwise.  There is no review or
        quarantine state: a title that did not install simply goes back in the queue.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Batches,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$InstalledTitles
    )
    $installed = @{}
    foreach ($title in @($InstalledTitles)) {
        if ($title -and $title.TitleId) { $installed[([string]$title.TitleId).ToUpperInvariant()] = $title }
    }
    foreach ($batch in @($Batches)) {
        if (-not $batch) { continue }
        $installedItems = @(); $remainingItems = @()
        foreach ($item in @($batch.Items)) {
            if (-not $item) { continue }
            $titleId = ([string]$item.TitleId).ToUpperInvariant()
            $isInstalled = [bool]($installed.ContainsKey($titleId) -and $installed[$titleId].State -eq 'Installed + healthy')
            $item | Add-Member -NotePropertyName InstallState -NotePropertyValue $(if ($isInstalled) { 'Installed' } else { 'Remaining' }) -Force
            if ($isInstalled) { $installedItems += $item } else { $remainingItems += $item }
        }
        $state = if (-not $remainingItems.Count) { 'Complete' }
            elseif (-not $installedItems.Count) { 'Ready to install' }
            else { "Partially installed - $($remainingItems.Count) remaining" }
        $batch | Add-Member -NotePropertyName State -NotePropertyValue $state -Force
        $batch | Add-Member -NotePropertyName InstalledCount -NotePropertyValue $installedItems.Count -Force
        $batch | Add-Member -NotePropertyName RemainingCount -NotePropertyValue $remainingItems.Count -Force
        $batch | Add-Member -NotePropertyName InstalledItems -NotePropertyValue @($installedItems) -Force
        $batch | Add-Member -NotePropertyName RemainingItems -NotePropertyValue @($remainingItems) -Force
    }
    @($Batches)
}

function Resolve-ThreeDSBatchReturn {
    <#
        Decides which install folders are finished with.  The active batch stays on
        the card until it has been out to the console (AwaitingReturn) or shows at
        least one install; every other manager folder is a leftover.  A finished
        folder is removed whole, and its titles that did not install go back in the
        queue.  Folders the manager did not create are never touched.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()] [AllowEmptyCollection()] [object[]]$Batches = @(),
        [AllowNull()] [string]$ActiveBatchId = '',
        [bool]$AwaitingReturn = $false
    )
    $keep = @(); $remove = @(); $requeue = @(); $activeFound = $false
    foreach ($batch in @($Batches)) {
        if (-not $batch) { continue }
        $id = [string]$batch.BatchId
        if (-not (Test-ThreeDSSafeBatchId -BatchId $id)) { continue }
        $isActive = [bool]($ActiveBatchId -and $id -eq $ActiveBatchId)
        if ($isActive) { $activeFound = $true }
        if ($isActive -and -not $AwaitingReturn -and [int]$batch.InstalledCount -eq 0) {
            $keep += $batch
            continue
        }
        $remove += $batch
        $requeue += @($batch.RemainingItems | Where-Object { $_ })
    }
    [pscustomobject]@{
        KeepBatches=@($keep)
        RemoveBatches=@($remove)
        RequeueItems=@($requeue)
        ActiveReturned=[bool]($ActiveBatchId -and (-not $activeFound -or @($remove | Where-Object { $_.BatchId -eq $ActiveBatchId }).Count))
        ActiveMissing=[bool]($ActiveBatchId -and -not $activeFound)
    }
}

function Find-ThreeDSPreparedArtifact {
    <#
        Finds the InstallReady artifact for a staged title, so a game that did not
        install goes back in the queue without being prepared again.  It is matched by
        Title ID, type and exact length; its validated digest and content manifest come
        from the staged record.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$InstallReadyRoot,
        [Parameter(Mandatory)] $Item
    )
    $titleId = ([string]$Item.TitleId).ToUpperInvariant()
    if ($titleId -notmatch '^[A-F0-9]{16}$') { return $null }
    $type = if ([string]$Item.Type -in @('Base','Update','DLC')) { [string]$Item.Type } else { 'Base' }
    $directory = Join-Path $InstallReadyRoot (Join-Path $type $titleId)
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { return $null }
    $candidates = @(Get-ChildItem -LiteralPath $directory -File -Filter '*.cia' |
        Where-Object { [uint64]$_.Length -eq [uint64]$Item.Length })
    if ($candidates.Count -ne 1) { return $null }
    [pscustomobject]@{
        Title=$Item.Title; TitleId=$titleId; Type=$type
        ProductCode=$Item.ProductCode; Region=$Item.Region; SaveSizeBytes=[uint64]$Item.SaveSizeBytes
        ArtifactPath=$candidates[0].FullName; ArtifactLength=[uint64]$candidates[0].Length
        ArtifactSHA256=([string]$Item.SHA256).ToUpperInvariant()
        ContentManifest=@($Item.ContentManifest)
    }
}

function Remove-ThreeDSInstallFolder {
    <#
        Removes one install folder the manager created, whole.  Staged CIAs are
        disposable copies of InstallReady artifacts, so nothing here is the only copy
        of anything.  The folder must carry a manager batch name and sit directly under
        cias\InstallQueue on the exact verified card.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$BatchId,
        [Parameter(Mandatory)] [int]$TargetDiskNumber,
        [Parameter(Mandatory)] [uint64]$ExpectedDiskCapacityBytes,
        [Parameter(Mandatory)] [string]$ExpectedDriveLetter,
        [switch]$AllowAdvisoryVolumeHealth
    )
    if (-not (Test-ThreeDSSafeBatchId -BatchId $BatchId)) { throw 'Refusing to remove a folder the manager did not create.' }
    $target = Assert-ThreeDSSafeTarget -DiskNumber $TargetDiskNumber -ExpectedDiskCapacityBytes $ExpectedDiskCapacityBytes `
        -ExpectedDriveLetter $ExpectedDriveLetter -AllowUnhealthyVolume:$AllowAdvisoryVolumeHealth
    $queueParent = [IO.Path]::GetFullPath((Join-Path $target.Root 'cias\InstallQueue')).TrimEnd('\')
    $folder = [IO.Path]::GetFullPath((Join-Path $queueParent $BatchId)).TrimEnd('\')
    if ((Split-Path -Parent $folder) -ne $queueParent) { throw 'Refusing to remove a folder outside cias\InstallQueue.' }
    if (-not (Test-Path -LiteralPath $folder -PathType Container)) {
        return [pscustomobject]@{ BatchId=$BatchId; Removed=$false; RemovedFileCount=0 }
    }
    $fileCount = @(Get-ChildItem -LiteralPath $folder -Recurse -File -Force).Count
    Remove-Item -LiteralPath $folder -Recurse -Force
    [pscustomobject]@{ BatchId=$BatchId; Removed=$true; RemovedFileCount=$fileCount }
}

function Save-ThreeDSManagerState {
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] $Value
    )
    if ($Name -notmatch '^[A-Za-z0-9._-]+$') {
        throw 'Invalid state filename: generated state keys may contain only letters, digits, dots, underscores, and hyphens.'
    }
    $path = Join-Path (Get-ThreeDSManagerDataRoot) $Name
    $Value | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path -Encoding UTF8
    $path
}

function Get-ThreeDSManagerState {
    param([Parameter(Mandatory)] [string]$Name)
    if ($Name -notmatch '^[A-Za-z0-9._-]+$') {
        throw 'Invalid state filename: generated state keys may contain only letters, digits, dots, underscores, and hyphens.'
    }
    $path = Join-Path (Get-ThreeDSManagerDataRoot) $Name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
}

Export-ModuleMember -Function @(
    'Get-ThreeDSManagerDataRoot', 'Assert-ThreeDSExternalDataPath', 'Get-ThreeDSToolchain',
    'Get-ThreeDSSafeVolumes', 'Assert-ThreeDSSafeTarget', 'Resolve-ThreeDSEjectTarget',
    'Invoke-ThreeDSNativeDeviceEject', 'Invoke-ThreeDSSafeEject', 'Get-ThreeDSInstalledTitles',
    'Get-ThreeDSImageMetadata', 'Test-ThreeDSCia', 'Get-ThreeDSLibraryInventory', 'New-ThreeDSSyncPlan',
    'Prepare-ThreeDSArtifact', 'Get-ThreeDSPreparationFailureScope', 'Get-ThreeDSManagerErrorDisplay',
    'Get-ThreeDSPreparationStateKey', 'Invoke-ThreeDSPreparationBatch', 'Get-ThreeDSByteSum',
    'Get-ThreeDSSdLifecycleStateNames', 'Resolve-ThreeDSSdLifecycle', 'Test-ThreeDSVerifiedSdTarget',
    'Get-ThreeDSTargetFingerprint', 'Test-ThreeDSSdCandidate', 'Resolve-ThreeDSSdSelection',
    'Get-ThreeDSInstallBatchStateName', 'New-ThreeDSGuidedBatchPlan', 'Resolve-ThreeDSGuidedReturn',
    'Copy-ThreeDSInstallQueue', 'Import-ThreeDSGm9Exports', 'Get-ThreeDSInstallBatches',
    'Get-ThreeDSKnownTitleManifests', 'Resolve-ThreeDSInstallBatches', 'Resolve-ThreeDSBatchReturn',
    'Find-ThreeDSPreparedArtifact', 'Remove-ThreeDSInstallFolder', 'Save-ThreeDSManagerState',
    'Get-ThreeDSManagerState', 'Get-ThreeDSSdSpaceUsage', 'Test-ThreeDSCancellation', 'Get-ThreeDSCardKey'
)
