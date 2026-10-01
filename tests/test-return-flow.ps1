# End-to-end run of the manager's own return flow, with its real functions and WPF
# controls, against a fake card: a batch that went out to the 3DS with one game
# installed and one not, an old leftover folder, an empty folder with no manifest,
# and a folder the manager did not create.  The returned folders are removed whole,
# the uninstalled game goes back in the queue from its PC prepared copy, and a batch
# not yet taken to the 3DS is left alone.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName PresentationFramework
$repo = Split-Path -Parent $PSScriptRoot
$root = Join-Path $env:TEMP ('BackupsNew3DS.ReturnFlow.' + [guid]::NewGuid().ToString('N'))
$env:THREEDS_MANAGER_DATA_ROOT = Join-Path $root 'state'
New-Item -ItemType Directory -Path $env:THREEDS_MANAGER_DATA_ROOT -Force | Out-Null
Import-Module (Join-Path $repo 'scripts\ThreeDSLibrary.Core.psm1') -Force -DisableNameChecking
function Check([bool]$Condition, [string]$Message) { if (-not $Condition) { throw "FAIL: $Message" }; "ok   $Message" }

try {
    # --- Fake card ---------------------------------------------------------------
    $card = Join-Path $root 'card'
    $titles = Join-Path $card ('Nintendo 3DS\{0}\{1}\title\00040000' -f ('A' * 32), ('B' * 32))
    function New-Installed([string]$Low, [int]$AppLength) {
        $dir = Join-Path $titles $Low
        New-Item -ItemType Directory -Path (Join-Path $dir 'content\cmd'), (Join-Path $dir 'data') -Force | Out-Null
        [IO.File]::WriteAllBytes((Join-Path $dir 'content\00000000.app'), (New-Object byte[] $AppLength))
        [IO.File]::WriteAllBytes((Join-Path $dir 'content\00000000.tmd'), (New-Object byte[] 64))
        [IO.File]::WriteAllBytes((Join-Path $dir 'content\cmd\00000001.cmd'), (New-Object byte[] 32))
        [IO.File]::WriteAllBytes((Join-Path $dir 'data\00000001.sav'), (New-Object byte[] 1024))
    }
    New-Installed '0017EA00' 4096       # A: installed and healthy
    New-Installed '00AAAA00' 9999       # E: an earlier install whose content is incomplete
    function New-Entry([string]$TitleId, [string]$Title, [int]$Length) {
        [pscustomobject]@{
            Title=$Title; TitleId=$TitleId; Type='Base'; ProductCode='CTR-P-TEST'; Region='USA'; SaveSizeBytes=[uint64]1024
            ContentManifest=@([pscustomobject]@{ Index='0000'; ContentId='00000000'; Length=[uint64]4096 })
            FileName=('{0}-{1}.cia' -f $TitleId, ('AB12CD34')); Length=[uint64]$Length; SHA256=('AB12CD34' + ('0' * 56))
        }
    }
    function New-Folder([string]$BatchId, [object[]]$Entries) {
        $dir = Join-Path $card "cias\InstallQueue\$BatchId"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        foreach ($e in $Entries) { [IO.File]::WriteAllBytes((Join-Path $dir $e.FileName), (New-Object byte[] $e.Length)) }
        [pscustomobject]@{ CreatedAt=(Get-Date).ToString('o'); BatchId=$BatchId; Queue=@($Entries) } | ConvertTo-Json -Depth 6 |
            Set-Content -LiteralPath (Join-Path $dir 'INSTALL-QUEUE.json') -Encoding UTF8
    }
    $a = New-Entry '000400000017EA00' 'Hyrule Warriors Legends' 3000
    $b = New-Entry '0004000000173700' 'Stella Glow' 3100
    $c = New-Entry '000400000F70CC00' 'Fire Emblem Warriors' 3200
    $e = New-Entry '0004000000AAAA00' 'Broken Earlier Install' 3300
    New-Folder '2-games - 2026-09-29 04-35-49' @($a, $b)          # the batch that went out to the 3DS
    New-Folder '1-games - 2026-09-03 01-24-49' @($c)              # an old leftover
    New-Item -ItemType Directory -Path (Join-Path $card 'cias\InstallQueue\2-games - 2026-09-29 03-34-46') -Force | Out-Null   # empty, no manifest
    New-Item -ItemType Directory -Path (Join-Path $card 'cias\InstallQueue\Homebrew stuff') -Force | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $card 'cias\InstallQueue\Homebrew stuff\keep.cia'), (New-Object byte[] 10))
    # E's validated manifest is known from an earlier batch record.
    Save-ThreeDSManagerState -Name (Get-ThreeDSInstallBatchStateName -BatchId '1-games - 2026-09-01 10-00-00') -Value ([pscustomobject]@{ BatchId='1-games - 2026-09-01 10-00-00'; Queue=@($e) }) | Out-Null

    # --- Fake InstallReady: B's prepared copy exists, C's does not -------------------
    $cache = Join-Path $root 'installready'
    New-Item -ItemType Directory -Path (Join-Path $cache 'Base\0004000000173700') -Force | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $cache ('Base\0004000000173700\' + ('F' * 64) + '.cia')), (New-Object byte[] 3100))

    # --- Card stub inside the module, proven before anything runs ---------------------
    $target = [pscustomobject]@{ Root=$card; DiskNumber=2; DiskCapacityBytes=[uint64]127999672320; DriveLetter='D:'; VolumeLabel='N3DS'; FreeBytes=[uint64]64GB; VolumeHealthStatus='Healthy' }
    $module = Get-Module ThreeDSLibrary.Core
    & $module { param($t) $script:ThreeDSTestStubTarget = $t; Set-Item -Path 'function:script:Assert-ThreeDSSafeTarget' -Value { param($DiskNumber,$ExpectedDiskCapacityBytes,$ExpectedDriveLetter,[switch]$AllowUnhealthyVolume) $script:ThreeDSTestStubTarget } } $target
    $proof = & $module { Assert-ThreeDSSafeTarget -DiskNumber 9 -ExpectedDiskCapacityBytes ([uint64]1) -ExpectedDriveLetter 'Z:' }
    if ([IO.Path]::GetFullPath($proof.Root) -ne [IO.Path]::GetFullPath($card)) { throw 'REFUSING TO RUN: card stub not in effect.' }

    # --- The manager's own functions and controls --------------------------------------
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'scripts\library-manager.ps1'), [ref]$null, [ref]$null)
    foreach ($name in 'Read-SmartSdState','Complete-GuidedReturn','Get-GuidedInstallPlan','Add-GuidedBacklog','Save-GuidedInstallState','Build-ViewItems','Update-SdSpace','New-PieSliceGeometry','Format-SpaceSize','Update-NextStep','Update-SelectionSummary','Get-RemovalChanges','Apply-Filter','Get-FriendlyTitle') {
        $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
        if (-not $fn) { throw "$name not found in the manager." }
        . ([scriptblock]::Create($fn.Extent.Text))
    }
    $script:Logged = New-Object System.Collections.ArrayList
    function Add-Log([string]$Message) { [void]$script:Logged.Add($Message) }
    foreach ($n in 'NextStepTitle','NextStepText','SelectionSummary') { Set-Variable -Scope Script -Name $n -Value (New-Object Windows.Controls.TextBlock) }
    foreach ($n in 'RefreshAll','ApplyChanges') { Set-Variable -Scope Script -Name $n -Value (New-Object Windows.Controls.Button) }
    $script:Boot9Panel = New-Object Windows.Controls.StackPanel
    $script:SpaceCard = New-Object Windows.Controls.Border
    foreach ($n in 'SpaceSummary','SpaceGamesText','SpaceOtherText','SpaceFreeText') { Set-Variable -Scope Script -Name $n -Value (New-Object Windows.Controls.TextBlock) }
    foreach ($n in 'SpaceGamesSlice','SpaceOtherSlice','SpaceFreeSlice') { Set-Variable -Scope Script -Name $n -Value (New-Object Windows.Shapes.Path) }
    $script:GameGrid = New-Object Windows.Controls.DataGrid
    $script:SearchBox = New-Object Windows.Controls.TextBox
    $script:CachePath = New-Object Windows.Controls.TextBox; $script:CachePath.Text = $cache
    $script:SdTargets = New-Object Windows.Controls.ComboBox
    $script:SdLifecycle = [pscustomobject]@{ ShowsSuccessfulEject=$false; CanUseSd=$true; IsMounted=$true }
    $script:Busy = $false; $script:InlineNotice = ''; $script:PendingRemoval = $null; $script:LastRemovalConfirmed = ''
    $script:PreparationFailures = @(); $script:InstalledItems = @(); $script:BatchItems = @(); $script:ViewItems = @()
    # State as the old manager saved it: an extra legacy field must be tolerated.
    $script:GuidedInstall = [pscustomobject]@{ Backlog=@(); ActiveBatchId='2-games - 2026-09-29 04-35-49'; ActiveTitleIds=@($a.TitleId,$b.TitleId); ActiveCount=2; AwaitingReturn=$true; CarryForwardTitleIds=@(); LastReturnMessage='' }

    # --- The card comes back ----------------------------------------------------------------
    Read-SmartSdState -Target $target -ProgressAction { param($m) }
    $left = @(Get-ChildItem -LiteralPath (Join-Path $card 'cias\InstallQueue') -Directory | ForEach-Object Name)
    Check ($left.Count -eq 1 -and $left[0] -eq 'Homebrew stuff') "only the folder the app did not create remains ($($left -join ', '))"
    Check (Test-Path -LiteralPath (Join-Path $card 'cias\InstallQueue\Homebrew stuff\keep.cia')) 'the foreign folder is untouched'
    Check ([string]$script:GuidedInstall.ActiveBatchId -eq '') 'the returned batch is cleared'
    Check ($script:GuidedInstall.LastReturnMessage -eq 'Batch returned: 1 of 2 installed; 1 back in the queue') "return message: '$($script:GuidedInstall.LastReturnMessage)'"
    $queued = @($script:GuidedInstall.Backlog | ForEach-Object TitleId)
    Check ($queued.Count -eq 1 -and $queued[0] -eq $b.TitleId) "Stella Glow went back in the queue (queue: $($queued -join ', '))"
    Check ((@($script:GuidedInstall.Backlog)[0].ArtifactPath) -like "$cache*") 'it is queued from the PC prepared copy'
    Check (@($script:Logged | Where-Object { $_ -match 'Fire Emblem Warriors did not install and its prepared copy was not found' }).Count -eq 1) 'a game with no prepared copy is reported, not guessed'
    Check (@($script:InstalledItems | Where-Object { $_.TitleId -eq $a.TitleId -and $_.State -eq 'Installed + healthy' }).Count -eq 1) 'Hyrule Warriors is healthy by manifest match'
    Check (@($script:BatchItems).Count -eq 0) 'no install folder is left in view'
    Check (Test-Path -LiteralPath (Join-Path $titles '0017EA00\content\00000000.app')) 'installed games were not touched'
    $saved = Get-ThreeDSManagerState -Name 'guided-install.json'
    Check ($saved -and [string]$saved.ActiveBatchId -eq '' -and @($saved.Backlog).Count -eq 1) 'the new state was saved'

    # --- The game list and the Next step card --------------------------------------------
    function New-Lib([string]$TitleId, [string]$Title) { [pscustomobject]@{ TitleId=$TitleId; Title=$Title; Type='Base'; SourceSHA256=('9' * 64); SourceLength=[uint64]4096; Format='CIA'; EncryptionState='Decrypted' } }
    $script:LibraryItems = @((New-Lib $a.TitleId 'Hyrule Warriors Legends (USA)'), (New-Lib $b.TitleId 'Stella Glow (USA)'), (New-Lib $c.TitleId 'Fire Emblem Warriors (USA)'), (New-Lib $e.TitleId 'Broken Earlier Install (USA)'))
    Build-ViewItems
    $view = @{}; foreach ($v in $script:ViewItems) { $view[$v.TitleId] = $v }
    Check ($view[$a.TitleId].DisplayState -eq 'Yes' -and -not $view[$a.TitleId].CanSelect) 'Hyrule Warriors shows Yes'
    Check ($view[$b.TitleId].LifecycleState -eq 'Prepared on PC' -and -not $view[$b.TitleId].CanSelect) 'Stella Glow shows as queued'
    Check ($view[$c.TitleId].LifecycleState -eq 'Missing' -and $view[$c.TitleId].CanSelect) 'Fire Emblem Warriors can be ticked again'
    Check ($view[$e.TitleId].CanSelect -and $view[$e.TitleId].PreparationStatus -eq 'Install incomplete - add it again') 'a broken install can simply be added again'
    # Read-SmartSdState alone; the refresh around it copies the waiting game (test-add-to-sd.ps1).
    Check ($script:NextStepTitle.Text -eq '1 game waiting to copy') "Next step title: '$($script:NextStepTitle.Text)'"
    Check ($script:NextStepText.Text -match 'Batch returned: 1 of 2 installed; 1 back in the queue\.' -and $script:NextStepText.Text -match '1 game waiting to copy to the SD card\.' -and $script:NextStepText.Text -match 'copied automatically') 'Next step text reports the return and that the game follows automatically'
    Check ($script:NextStepText.Text -notmatch 'review|held|leftover|quarantin') 'no review, hold or leftover wording appears'

    # --- Only free space holds games back --------------------------------------------------
    $extra = [pscustomobject]@{ Title='Radiant Historia'; TitleId='00040000001C8F00'; Type='Base'; ArtifactLength=[uint64]3100; ArtifactPath=(Join-Path $cache 'x.cia'); ArtifactSHA256=('E' * 64); ContentManifest=@() }
    $script:GuidedInstall.Backlog = @(@($script:GuidedInstall.Backlog) + $extra)
    $script:SdTargets.ItemsSource = @([pscustomobject]@{ FriendlyDisplay='N3DS'; FreeBytes=[uint64](512MB + 3500) })
    $script:SdTargets.SelectedIndex = 0
    Update-NextStep
    Check ($script:NextStepTitle.Text -eq '2 games waiting to copy' -and $script:NextStepText.Text -match 'copied automatically') "a card with room for one copies it without asking: '$($script:NextStepText.Text)'"
    $script:SdTargets.ItemsSource = @([pscustomobject]@{ FriendlyDisplay='N3DS'; FreeBytes=[uint64](512MB + 100) })
    $script:SdTargets.SelectedIndex = 0
    Update-NextStep
    Check ($script:NextStepText.Text -match 'does not have enough free space') 'a full card says so'
    $script:SdTargets.ItemsSource = @(); $script:GuidedInstall.Backlog = @($script:GuidedInstall.Backlog | Where-Object { $_.TitleId -ne $extra.TitleId })

    # --- A batch not yet taken to the 3DS stays put ------------------------------------------
    New-Folder '1-games - 2026-09-29 07-00-00' @($c)
    $script:GuidedInstall.ActiveBatchId = '1-games - 2026-09-29 07-00-00'; $script:GuidedInstall.ActiveTitleIds = @($c.TitleId); $script:GuidedInstall.ActiveCount = 1; $script:GuidedInstall.AwaitingReturn = $false
    Read-SmartSdState -Target $target -ProgressAction { param($m) }
    Check (Test-Path -LiteralPath (Join-Path $card 'cias\InstallQueue\1-games - 2026-09-29 07-00-00')) 'a batch not yet taken to the 3DS is kept'
    Check ($script:GuidedInstall.ActiveBatchId -eq '1-games - 2026-09-29 07-00-00') 'it stays the active batch'
    Update-NextStep
    Check ($script:NextStepTitle.Text -eq 'Batch ready - 1 game' -and $script:NextStepText.Text -match 'Install game image') 'the card says Batch ready with install steps'

    # --- A game that failed preparation is simply ticked again ------------------------------
    $f = New-Lib '0004000000BBBB00' 'Xeodrifter (USA)'
    $script:PreparationFailures = @([pscustomobject]@{ TitleId=$f.TitleId; SourceSHA256=$f.SourceSHA256; Error='The source file is damaged.' })
    $script:LibraryItems = @(@($script:LibraryItems) + $f)
    Build-ViewItems
    $failedRow = @($script:ViewItems | Where-Object TitleId -eq $f.TitleId)[0]
    Check ($failedRow.CanSelect -and $failedRow.PreparationStatus -eq 'FAILED - hover for why' -and $failedRow.PreparationError -eq 'The source file is damaged.') 'a failed game stays tickable and shows why'
    Check ($script:SelectionSummary.Text -match 'tick it to try again') "selection summary: '$($script:SelectionSummary.Text)'"
    'ALL CHECKS PASSED'
}
finally {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
}
