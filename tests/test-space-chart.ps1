# The SD card space chart: the games / other / free split from the inventory already
# read, the pie geometry, and the manager's own Update-SdSpace against a live drive.
# The live drive is only queried for its size and free space; nothing is written.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName PresentationFramework
$repo = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repo 'scripts\ThreeDSLibrary.Core.psm1') -Force -DisableNameChecking
function Check([bool]$Condition, [string]$Message) { if (-not $Condition) { throw "FAIL: $Message" }; "ok   $Message" }

# --- The split --------------------------------------------------------------------
$titles = @([pscustomobject]@{ TitleId='000400000F70CC00'; InstalledBytes=[uint64]3GB }, [pscustomobject]@{ TitleId='0004000E0F70CC00'; InstalledBytes=[uint64]500MB })
$batches = @([pscustomobject]@{ BatchId='2-games'; Items=@([pscustomobject]@{ Length=[uint64]1GB }, [pscustomobject]@{ Length=[uint64]2GB }) })
$u = Get-ThreeDSSdSpaceUsage -TotalBytes ([uint64]127982960640) -FreeBytes ([uint64]42090000000) -InstalledTitles $titles -Batches $batches
Check ($u.GamesBytes -eq [uint64](3GB + 500MB + 3GB)) 'games are installed titles plus CIAs waiting to install'
Check ($u.OtherBytes -eq [uint64](127982960640 - 42090000000 - (3GB + 500MB + 3GB))) 'other is the rest of the used space'
Check (($u.GamesBytes + $u.OtherBytes + $u.FreeBytes) -eq $u.TotalBytes) 'the three parts add up to a real-sized card'
$empty = Get-ThreeDSSdSpaceUsage -TotalBytes ([uint64]64GB) -FreeBytes ([uint64]64GB) -InstalledTitles @() -Batches @()
Check ($empty.GamesBytes -eq 0 -and $empty.OtherBytes -eq 0 -and $empty.FreeBytes -eq [uint64]64GB) 'an empty card is all free'
$null1 = Get-ThreeDSSdSpaceUsage -TotalBytes ([uint64]64GB) -FreeBytes ([uint64]60GB) -InstalledTitles $null -Batches $null
Check ($null1.OtherBytes -eq [uint64]4GB) 'no inventory yet counts nothing as games'
$odd = Get-ThreeDSSdSpaceUsage -TotalBytes ([uint64]10GB) -FreeBytes ([uint64]9GB) -InstalledTitles @([pscustomobject]@{ TitleId='X'; InstalledBytes=[uint64]5GB }, [pscustomobject]@{ TitleId='Y' }) -Batches @([pscustomobject]@{ BatchId='no items' })
Check ($odd.GamesBytes -eq [uint64]1GB -and $odd.OtherBytes -eq 0) 'games never exceed the used space, and rows without sizes are skipped'
$over = Get-ThreeDSSdSpaceUsage -TotalBytes ([uint64]10GB) -FreeBytes ([uint64]11GB)
Check ($over.FreeBytes -eq [uint64]10GB -and $over.OtherBytes -eq 0) 'free space is capped at the card size'

# --- The manager's own chart functions and controls ------------------------------------
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'scripts\library-manager.ps1'), [ref]$null, [ref]$null)
foreach ($name in 'Format-SpaceSize','New-PieSliceGeometry','Update-SdSpace') {
    $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
    if (-not $fn) { throw "$name not found in the manager." }
    . ([scriptblock]::Create($fn.Extent.Text))
}
Check ($null -eq (New-PieSliceGeometry 0 0 58)) 'an empty part draws no slice'
Check ((New-PieSliceGeometry 0 1 58) -is [Windows.Media.EllipseGeometry]) 'a part that is the whole card draws a full circle'
$quarter = (New-PieSliceGeometry 0 0.25 58).Bounds
Check ([Math]::Abs($quarter.Left - 58) -lt 0.01 -and [Math]::Abs($quarter.Right - 116) -lt 0.01 -and [Math]::Abs($quarter.Top) -lt 0.01 -and [Math]::Abs($quarter.Bottom - 58) -lt 0.01) "a quarter starts at 12 o'clock and runs clockwise ($quarter)"
$most = (New-PieSliceGeometry 0.1 0.8 58).Bounds
# 10% to 90% passes 3, 6 and 9 o'clock but not 12, so it spans the full width and stops short of the top.
Check ($most.Width -gt 115 -and [Math]::Abs($most.Top - (58 - 58 * [Math]::Cos(0.2 * [Math]::PI))) -lt 0.01 -and [Math]::Abs($most.Bottom - 116) -lt 0.01) "a slice over half the card takes the long way round ($most)"
Check ((Format-SpaceSize ([uint64]42090000000)) -eq ('{0:N1} GB' -f (42090000000 / 1GB))) 'sizes show in GB'
Check ((Format-SpaceSize ([uint64]300MB)) -eq ('{0:N0} MB' -f 300)) 'small sizes show in MB'

$script:SpaceCard = New-Object Windows.Controls.Border
foreach ($n in 'SpaceSummary','SpaceGamesText','SpaceOtherText','SpaceFreeText') { Set-Variable -Scope Script -Name $n -Value (New-Object Windows.Controls.TextBlock) }
foreach ($n in 'SpaceGamesSlice','SpaceOtherSlice','SpaceFreeSlice') { Set-Variable -Scope Script -Name $n -Value (New-Object Windows.Shapes.Path) }
$script:SdTargets = New-Object Windows.Controls.ComboBox
$script:InstalledItems = $titles; $script:BatchItems = $batches

# A stand-in card whose root is the system drive: only its size and free space are read.
# Card states come from the real lifecycle model, never hand-built flags.
$card = [pscustomobject]@{
    FriendlyDisplay='N3DS'; Root=([IO.Path]::GetPathRoot($env:SystemRoot))
    DiskNumber=1; DriveLetter='D:'; DiskUniqueId='USBSTOR\N3DS'; DeviceInstanceId='USBSTOR\N3DS&0'; EjectDeviceInstanceId='USB\READER'
    DiskCapacityBytes=[uint64]127999672320; VolumeCapacityBytes=[uint64]127982960640; FreeBytes=[uint64]1
    VolumeLabel='N3DS'; FileSystem='FAT32'; VolumeHealthStatus='Healthy'; BusType='USB'; HasNintendo3DS=$true; IsBoot=$false; IsSystem=$false
}
$script:SdTargets.ItemsSource = @($card); $script:SdTargets.SelectedIndex = 0
function Set-CardState([bool]$Busy = $false, [bool]$Ejecting = $false, [object[]]$Present = @($card)) {
    $script:SdLifecycle = Resolve-ThreeDSSdLifecycle -CurrentTargets $Present -SelectedTarget $card -Busy $Busy -Ejecting $Ejecting
    $script:SdLifecycle.State
}

# The check that reads the inventory always runs busy, so the chart must draw then.
Check ((Set-CardState -Busy $true) -eq 'Mounted + busy') 'the card is busy during a check'
Update-SdSpace
$drive = [IO.DriveInfo]::new($card.Root)
Check ([string]$script:SpaceCard.Visibility -eq 'Visible') 'the chart draws while a check or copy is running'
Check ((Set-CardState) -eq 'Mounted + idle') 'the card is idle afterwards'
Update-SdSpace
Check ([string]$script:SpaceCard.Visibility -eq 'Visible') 'the chart shows for an idle card'
Check ([Math]::Abs([double]$card.FreeBytes - [double]$drive.TotalFreeSpace) -lt 1GB) 'the card''s free space is refreshed live for the copy plan'
Check ($script:SpaceGamesText.Text -match '^Games - .+ \(\d+%\)$' -and $script:SpaceOtherText.Text -match '^Other - ' -and $script:SpaceFreeText.Text -match '^Free - ') "legend: $($script:SpaceGamesText.Text) | $($script:SpaceOtherText.Text) | $($script:SpaceFreeText.Text)"
Check ($script:SpaceSummary.Text -match ' free of ') "summary: $($script:SpaceSummary.Text)"
Check ($null -ne $script:SpaceGamesSlice.Data -and $null -ne $script:SpaceOtherSlice.Data) 'games and other slices are drawn'

Check ((Set-CardState -Ejecting $true) -eq 'Ejecting') 'the card is being ejected'
Update-SdSpace
Check ([string]$script:SpaceCard.Visibility -eq 'Collapsed') 'the chart hides while the card is ejected'
Check ((Set-CardState -Present @()) -eq 'No SD card detected') 'the card is gone'
Update-SdSpace
Check ([string]$script:SpaceCard.Visibility -eq 'Collapsed') 'the chart hides with no card connected'
Set-CardState | Out-Null; $script:SdTargets.ItemsSource = @(); $script:SdTargets.SelectedIndex = -1
Update-SdSpace
Check ([string]$script:SpaceCard.Visibility -eq 'Collapsed') 'the chart hides with no card selected'
$script:SdTargets.ItemsSource = @([pscustomobject]@{ FriendlyDisplay='N3DS'; FreeBytes=[uint64]5 }); $script:SdTargets.SelectedIndex = 0
Update-SdSpace
Check ([string]$script:SpaceCard.Visibility -eq 'Collapsed') 'a card record without a root is not charted'
'ALL CHECKS PASSED'
