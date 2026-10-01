# End-to-end run of the manager's own "Add to SD card" action and "Check for changes"
# refresh, with their real functions and WPF controls, against a fake card.  Games the
# user chose are copied without another click: straight after preparation, at startup,
# and when the card comes back from the 3DS.  They wait on the PC only while an earlier
# batch is still out to be installed or the card is full, and the Next step card says
# which.  Only conversion and the library scan are stubbed.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName PresentationFramework
$repo = Split-Path -Parent $PSScriptRoot
$root = Join-Path $env:TEMP ('BackupsNew3DS.AddToSd.' + [guid]::NewGuid().ToString('N'))
$env:THREEDS_MANAGER_DATA_ROOT = Join-Path $root 'state'
New-Item -ItemType Directory -Path $env:THREEDS_MANAGER_DATA_ROOT -Force | Out-Null
Import-Module (Join-Path $repo 'scripts\ThreeDSLibrary.Core.psm1') -Force -DisableNameChecking
function Check([bool]$Condition, [string]$Message) { if (-not $Condition) { throw "FAIL: $Message" }; "ok   $Message" }

try {
    # --- Fake card and PC prepared copies ---------------------------------------------
    $card = Join-Path $root 'card'
    $cache = Join-Path $root 'InstallReady'
    $queueRoot = Join-Path $card 'cias\InstallQueue'
    $titles = Join-Path $card ('Nintendo 3DS\{0}\{1}\title\00040000' -f ('A' * 32), ('B' * 32))
    New-Item -ItemType Directory -Path $titles, $queueRoot, $cache -Force | Out-Null
    function New-Artifact([string]$TitleId, [string]$Title, [int]$Length) {
        $dir = Join-Path $cache "Base\$TitleId"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $path = Join-Path $dir (('C0FFEE00' + ('0' * 56)) + '.cia')
        [IO.File]::WriteAllBytes($path, (New-Object byte[] $Length))
        [pscustomobject]@{
            Title=$Title; TitleId=$TitleId; Type='Base'; ProductCode='CTR-P-TEST'; Region='USA'; SaveSizeBytes=[uint64]1024
            ContentManifest=@([pscustomobject]@{ Index='0000'; ContentId='00000000'; Length=[uint64]$Length })
            ArtifactPath=$path; ArtifactLength=[uint64]$Length; ArtifactSHA256=('C0FFEE00' + ('0' * 56))
        }
    }
    function New-Installed($Artifact) {
        $dir = Join-Path $titles $Artifact.TitleId.Substring(8)
        New-Item -ItemType Directory -Path (Join-Path $dir 'content\cmd'), (Join-Path $dir 'data') -Force | Out-Null
        [IO.File]::WriteAllBytes((Join-Path $dir 'content\00000000.app'), (New-Object byte[] ([int]$Artifact.ArtifactLength)))
        [IO.File]::WriteAllBytes((Join-Path $dir 'content\00000000.tmd'), (New-Object byte[] 64))
        [IO.File]::WriteAllBytes((Join-Path $dir 'content\cmd\00000001.cmd'), (New-Object byte[] 32))
        [IO.File]::WriteAllBytes((Join-Path $dir 'data\00000001.sav'), (New-Object byte[] 1024))
    }
    $omega = New-Artifact '000400000011C500' 'Pokemon Omega Ruby' 4000
    $smt = New-Artifact '0004000000033600' 'Shin Megami Tensei IV' 5000
    $stella = New-Artifact '0004000000173700' 'STELLA GLOW' 3000           # prepared earlier, already waiting
    $ridge = New-Artifact '0004000000037A00' 'Ridge Racer 3D' 2000

    # --- Card stub inside the module, proven before anything runs ---------------------
    $target = [pscustomobject]@{ Root=$card; DiskNumber=2; DiskCapacityBytes=[uint64]127999672320; DriveLetter='D:'; VolumeLabel='N3DS'; FreeBytes=[uint64]64GB; VolumeHealthStatus='Healthy' }
    $module = Get-Module ThreeDSLibrary.Core
    & $module { param($t) $script:ThreeDSTestStubTarget = $t; Set-Item -Path 'function:script:Assert-ThreeDSSafeTarget' -Value { param($DiskNumber,$ExpectedDiskCapacityBytes,$ExpectedDriveLetter,[switch]$AllowUnhealthyVolume) $script:ThreeDSTestStubTarget } } $target
    $proof = & $module { Assert-ThreeDSSafeTarget -DiskNumber 9 -ExpectedDiskCapacityBytes ([uint64]1) -ExpectedDriveLetter 'Z:' }
    if ([IO.Path]::GetFullPath($proof.Root) -ne [IO.Path]::GetFullPath($card)) { throw 'REFUSING TO RUN: card stub not in effect.' }

    # --- The manager's own functions and controls --------------------------------------
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'scripts\library-manager.ps1'), [ref]$null, [ref]$null)
    foreach ($name in 'Invoke-ApplyChanges','Show-StoppedNotice','Register-CopiedBatch','Add-PendingRemoval','Clear-RemovalMark','Get-RemovalChanges','Invoke-RefreshAll','Read-SmartSdState','Complete-GuidedReturn','Resolve-PendingRemoval','Copy-WaitingGames','Copy-GuidedQueue','Show-Notice','Add-GuidedBacklog','Get-GuidedInstallPlan','Save-GuidedInstallState','Save-PreparationFailures','Set-PreparationFailure','Clear-PreparationFailure','Build-ViewItems','Update-SdSpace','New-PieSliceGeometry','Format-SpaceSize','Update-NextStep','Update-SelectionSummary','Apply-Filter','Get-FriendlyTitle') {
        $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
        if (-not $fn) { throw "$name not found in the manager." }
        . ([scriptblock]::Create($fn.Extent.Text))
    }
    $script:Logged = New-Object System.Collections.ArrayList
    function Add-Log([string]$Message) { [void]$script:Logged.Add($Message) }
    function Pump-Ui {}
    function Save-Preferences {}
    # Cancel: the real Set-Progress throws at its next checkpoint once Cancel is pressed.
    $script:CancelWhen = $null
    function Set-Progress([string]$Title, [string]$Detail, [uint64]$Done = 0, [uint64]$Total = 0) { if ($script:CancelWhen -and (& $script:CancelWhen $Title $Detail)) { $script:CancelWhen = $null; throw [System.OperationCanceledException]::new('The operation was stopped by the user.') } }
    function Set-Busy([bool]$Busy, [string]$Title = 'Ready') { $script:Busy = $Busy; if ($Busy) { $script:InlineNotice = '' } }
    function Show-Error { param($ErrorValue, [string]$Game = '', [string]$Operation = '') throw "Unexpected error during ${Operation}: $ErrorValue" }
    function Get-SelectedTarget { param([switch]$AllowUnhealthyVolume) $target }
    function Get-ThreeDSToolchain { [pscustomobject]@{ Ready=$true; CtrToolPath='ctrtool.exe' } }
    function Assert-ThreeDSExternalDataPath { param($Path, $RepositoryRoot) $Path }
    function Get-ThreeDSLibraryInventory { param($LibraryRoot, $CtrToolPath, $ProgressAction, $CachedItems) $script:LibraryItems }
    # Conversion is stubbed: every ticked game prepares except one named in $script:FailTitleIds.
    $script:FailTitleIds = @(); $script:CancelAtGame = 0
    function Invoke-ThreeDSPreparationBatch {
        param($Items, $PrepareAction, $SuccessAction, $FailureAction)
        $artifacts = @(); $failures = @(); $number = 0
        foreach ($view in $Items) {
            $number++
            if ($number -eq $script:CancelAtGame) { $script:CancelAtGame = 0; throw [System.OperationCanceledException]::new('The operation was stopped by the user.') }
            if ($view.TitleId -in $script:FailTitleIds) {
                $failure = [pscustomobject]@{ Title=$view.DisplayTitle; TitleId=$view.TitleId; SourceSHA256=$view.LibraryItem.SourceSHA256; Error='The source file is damaged.'; TechnicalError='hash mismatch' }
                & $FailureAction $failure $number $Items.Count; $failures += $failure
            }
            else {
                $artifact = $script:ArtifactById[$view.TitleId]
                & $SuccessAction $view $artifact $number $Items.Count; $artifacts += $artifact
            }
        }
        [pscustomobject]@{ Artifacts=$artifacts; PreparedCount=$artifacts.Count; CachedCount=0; FailedCount=$failures.Count; Failures=$failures }
    }
    $script:ArtifactById = @{ $omega.TitleId=$omega; $smt.TitleId=$smt; $stella.TitleId=$stella; $ridge.TitleId=$ridge }

    foreach ($n in 'NextStepTitle','NextStepText','SelectionSummary','FooterStatus') { Set-Variable -Scope Script -Name $n -Value (New-Object Windows.Controls.TextBlock) }
    foreach ($n in 'RefreshAll','ApplyChanges') { Set-Variable -Scope Script -Name $n -Value (New-Object Windows.Controls.Button) }
    $script:Boot9Panel = New-Object Windows.Controls.StackPanel
    $script:SpaceCard = New-Object Windows.Controls.Border
    foreach ($n in 'SpaceSummary','SpaceGamesText','SpaceOtherText','SpaceFreeText') { Set-Variable -Scope Script -Name $n -Value (New-Object Windows.Controls.TextBlock) }
    foreach ($n in 'SpaceGamesSlice','SpaceOtherSlice','SpaceFreeSlice') { Set-Variable -Scope Script -Name $n -Value (New-Object Windows.Shapes.Path) }
    $script:GameGrid = New-Object Windows.Controls.DataGrid
    $script:SearchBox = New-Object Windows.Controls.TextBox
    $script:LibraryPath = New-Object Windows.Controls.TextBox; $script:LibraryPath.Text = (Join-Path $root 'Active')
    $script:CachePath = New-Object Windows.Controls.TextBox; $script:CachePath.Text = $cache
    $script:Boot9Path = New-Object Windows.Controls.TextBox
    $script:SdTargets = New-Object Windows.Controls.ComboBox
    $script:RepositoryRoot = $repo
    $script:SdLifecycle = [pscustomobject]@{ ShowsSuccessfulEject=$false; CanUseSd=$true; IsMounted=$true }
    $script:Busy = $false; $script:InlineNotice = ''; $script:PendingRemoval = $null; $script:LastRemovalConfirmed = ''
    $script:PreparationFailures = @(); $script:InstalledItems = @(); $script:BatchItems = @(); $script:LibraryCache = @()
    $script:GuidedInstall = [pscustomobject]@{ Backlog=@($stella); ActiveBatchId=''; ActiveTitleIds=@(); ActiveCount=0; AwaitingReturn=$false; LastReturnMessage='Batch returned: 3 of 3 installed' }
    function New-Lib([string]$TitleId, [string]$Title) { [pscustomobject]@{ TitleId=$TitleId; Title=$Title; Type='Base'; SourceSHA256=('9' * 64); SourceLength=[uint64]4096; Format='CIA'; EncryptionState='Decrypted'; CacheState='Reused' } }
    $script:LibraryItems = @((New-Lib $omega.TitleId 'Pokemon Omega Ruby (USA)'), (New-Lib $smt.TitleId 'Shin Megami Tensei IV (USA)'), (New-Lib $stella.TitleId 'Stella Glow (USA)'), (New-Lib $ridge.TitleId 'Ridge Racer 3D (USA)'))
    Build-ViewItems
    function Get-Ticked([string[]]$TitleIds) { @($script:ViewItems | Where-Object { $_.TitleId -in $TitleIds }) }
    function Get-Folders { @(Get-ChildItem -LiteralPath $queueRoot -Directory | ForEach-Object Name) }
    function Get-FolderTitleIds([string]$Folder) { @(Get-ChildItem -LiteralPath (Join-Path $queueRoot $Folder) -Filter *.cia | ForEach-Object { $_.Name.Substring(0, 16) } | Sort-Object) -join ',' }
    function Reset-Card([object[]]$Waiting) {
        foreach ($folder in @(Get-Folders)) { Remove-Item -LiteralPath (Join-Path $queueRoot $folder) -Recurse -Force }
        $script:GuidedInstall.ActiveBatchId = ''; $script:GuidedInstall.ActiveTitleIds = @(); $script:GuidedInstall.ActiveCount = 0; $script:GuidedInstall.AwaitingReturn = $false
        $script:GuidedInstall.Backlog = @($Waiting); $script:BatchItems = @(); $script:InlineNotice = ''
    }

    # --- Ticking games puts them on the card in one click -----------------------------
    $script:FailTitleIds = @($smt.TitleId)
    Invoke-ApplyChanges -Adds (Get-Ticked @($omega.TitleId, $smt.TitleId))
    $folders = @(Get-Folders)
    Check ($folders.Count -eq 1 -and $folders[0] -like '2-games - *') "one GodMode9 folder was written ($($folders -join ', '))"
    Check ((Get-FolderTitleIds $folders[0]) -eq ((@($omega.TitleId, $stella.TitleId) | Sort-Object) -join ',')) 'it holds the new game and the one already waiting'
    Check ($script:GuidedInstall.ActiveBatchId -eq $folders[0] -and $script:GuidedInstall.ActiveCount -eq 2) 'the folder is the active batch'
    Check (@($script:GuidedInstall.Backlog).Count -eq 0) 'nothing is left waiting on the PC'
    Check ($script:NextStepTitle.Text -eq 'Batch ready - 2 games') "Next step title: '$($script:NextStepTitle.Text)'"
    Check ($script:InlineNotice -match '^Copied 2 games to the SD card; 1 failed' -and $script:InlineNotice -match 'Shin Megami Tensei IV: The source file is damaged\.' -and $script:InlineNotice -notmatch 'Safely Eject') "the notice reports the batch and the failure: '$($script:InlineNotice)'"
    $saved = Get-ThreeDSManagerState -Name 'guided-install.json'
    Check ($saved -and [string]$saved.ActiveBatchId -eq $folders[0]) 'the batch was saved'
    $failedRow = @($script:ViewItems | Where-Object TitleId -eq $smt.TitleId)[0]
    Check ($failedRow.CanSelect -and $failedRow.HasPreparationFailure) 'the failed game stays tickable'

    # --- A batch still on the card: newly prepared games wait on the PC ------------------
    $script:FailTitleIds = @()
    Invoke-ApplyChanges -Adds (Get-Ticked @($smt.TitleId))
    Check (@(Get-Folders).Count -eq 1) 'no second folder is written while a batch is on the card'
    Check (@($script:GuidedInstall.Backlog | ForEach-Object TitleId) -contains $smt.TitleId) 'the game waits on the PC'
    Check ($script:InlineNotice -match '^1 game waiting to copy' -and $script:InlineNotice -match 'installed and the card is back') "the notice says when it will be copied: '$($script:InlineNotice)'"
    Check ($script:NextStepText.Text -match '1 more game will be copied automatically when this card comes back\.') "Next step says it follows automatically: '$($script:NextStepText.Text)'"
    $failedRow = @($script:ViewItems | Where-Object TitleId -eq $smt.TitleId)[0]
    Check (-not $failedRow.HasPreparationFailure) 'a successful retry clears the failure'

    # --- The card comes back: the batch finishes and the next one is copied by itself -----
    New-Installed $omega                                   # Omega Ruby installed; Stella Glow did not
    $script:GuidedInstall.AwaitingReturn = $true           # set when the card was safely ejected
    $returned = $folders[0]
    # The next batch is copied moments after the returned folder is removed, so its
    # timestamped name can repeat an earlier one.  Hold every 2-game name for the next
    # few seconds, as earlier batches would, so the clash happens on every run.
    $now = Get-Date
    $held = @(0..15 | ForEach-Object { '2-games - ' + $now.AddSeconds($_).ToString('yyyy-MM-dd HH-mm-ss', [Globalization.CultureInfo]::InvariantCulture) } | Where-Object { $_ -ne $returned })
    foreach ($id in $held) { Save-ThreeDSManagerState -Name (Get-ThreeDSInstallBatchStateName -BatchId $id) -Value ([pscustomobject]@{ BatchId=$id; Queue=@() }) | Out-Null }
    $returnedRecord = Get-ThreeDSInstallBatchStateName -BatchId $returned
    Invoke-RefreshAll
    $folders = @(Get-Folders)
    Check ($returned -notin $folders) 'the returned folder was removed'
    Check ($folders.Count -eq 1 -and $folders[0] -like '2-games - *') "the next batch was copied without a click ($($folders -join ', '))"
    Check ($folders[0] -notin $held -and $folders[0] -ne $returned) "a batch name is never reused ($($folders[0]))"
    $record = Get-ThreeDSManagerState -Name $returnedRecord
    Check ($record -and @($record.Queue | ForEach-Object TitleId) -contains $omega.TitleId) 'the returned batch keeps its private record of what it installed'
    Check ((Get-FolderTitleIds $folders[0]) -eq ((@($smt.TitleId, $stella.TitleId) | Sort-Object) -join ',')) 'it holds the waiting game and the one that did not install'
    Check ($script:GuidedInstall.ActiveBatchId -eq $folders[0] -and @($script:GuidedInstall.Backlog).Count -eq 0) 'the new folder is the active batch and nothing waits'
    Check ($script:InlineNotice -match '^Copied 2 waiting games to the SD card' -and $script:InlineNotice -match 'Batch returned: 1 of 2 installed; 1 back in the queue\.') "the notice reports the return and the copy: '$($script:InlineNotice)'"
    Check ($script:NextStepTitle.Text -eq 'Batch ready - 2 games' -and $script:NextStepText.Text -match 'Install game image') 'Next step gives the install steps'

    # --- Startup with games already waiting: copied without a click ---------------------
    Reset-Card @($smt, $stella)
    $script:GuidedInstall.LastReturnMessage = 'Batch returned: 3 of 3 installed'
    Invoke-RefreshAll
    $folders = @(Get-Folders)
    Check ($folders.Count -eq 1 -and (Get-FolderTitleIds $folders[0]) -eq ((@($smt.TitleId, $stella.TitleId) | Sort-Object) -join ',')) 'waiting games are copied when the app starts'
    Check ($script:NextStepTitle.Text -eq 'Batch ready - 2 games') "Next step title: '$($script:NextStepTitle.Text)'"
    Check ($script:NextStepText.Text -notmatch 'waiting to copy') 'nothing is left asking to be copied'
    Check (@($script:InstalledItems | Where-Object { $_.TitleId -eq $omega.TitleId -and $_.State -eq 'Installed + healthy' }).Count -eq 1) 'a game installed from an earlier batch is still confirmed healthy'

    # --- A full card: the games wait, and the card says why -----------------------------------
    Reset-Card @($smt, $stella)
    $target.FreeBytes = [uint64](512MB + 100)
    $script:SdTargets.ItemsSource = @([pscustomobject]@{ FriendlyDisplay='N3DS'; FreeBytes=$target.FreeBytes }); $script:SdTargets.SelectedIndex = 0
    Invoke-RefreshAll
    Check (@(Get-Folders).Count -eq 0) 'nothing is written to a full card'
    Check (@($script:GuidedInstall.Backlog).Count -eq 2) 'both games wait on the PC'
    Check ($script:NextStepTitle.Text -eq '2 games waiting to copy' -and $script:NextStepText.Text -match 'does not have enough free space') "Next step explains the wait: '$($script:NextStepText.Text)'"

    # --- A real-sized card: free space beyond 32-bit range must plan normally ----------
    $script:InlineNotice = ''; $script:GuidedInstall.LastReturnMessage = ''
    $script:SdTargets.ItemsSource = @([pscustomobject]@{ FriendlyDisplay='N3DS'; FreeBytes=[uint64]42090000000 }); $script:SdTargets.SelectedIndex = 0
    Update-NextStep
    Check ($script:NextStepTitle.Text -eq '2 games waiting to copy' -and $script:NextStepText.Text -match 'copied automatically' -and $script:NextStepText.Text -notmatch 'free space') "a 39 GB card plans the whole queue: '$($script:NextStepText.Text)'"
    Check (@($script:Logged | Where-Object { $_ -match 'plan unavailable' }).Count -eq 0) 'the plan never failed'

    # --- No card: the games wait for it ---------------------------------------------------
    $script:SdLifecycle = [pscustomobject]@{ ShowsSuccessfulEject=$false; CanUseSd=$false; IsMounted=$false }
    Update-NextStep
    Check ($script:NextStepText.Text -match 'Connect the SD card and they will be copied automatically\.') "Next step waits for the card: '$($script:NextStepText.Text)'"

    # --- Add and remove in one click ------------------------------------------------------
    $script:SdLifecycle = [pscustomobject]@{ ShowsSuccessfulEject=$false; CanUseSd=$true; IsMounted=$true }
    $target.FreeBytes = [uint64]64GB
    $script:SdTargets.ItemsSource = @([pscustomobject]@{ FriendlyDisplay='N3DS'; FreeBytes=[uint64]64GB }); $script:SdTargets.SelectedIndex = 0
    New-Installed $ridge
    Reset-Card @()
    Invoke-RefreshAll
    $row = @{}; foreach ($v in $script:ViewItems) { $row[$v.TitleId] = $v }
    Check ($row[$omega.TitleId].CanRemove -and $row[$ridge.TitleId].CanRemove -and $row[$smt.TitleId].CanSelect) 'installed games can be ticked to remove and missing ones to add'
    $row[$smt.TitleId].IsChosen = $true; $row[$omega.TitleId].IsRemoveChosen = $true
    Update-SelectionSummary
    Check ([string]$script:ApplyChanges.Content -eq 'Add 1, remove 1' -and $script:ApplyChanges.IsEnabled) "one button names both changes: '$($script:ApplyChanges.Content)'"
    Invoke-ApplyChanges -Adds @($row[$smt.TitleId]) -Removals @($row[$omega.TitleId])
    $folders = @(Get-Folders)
    Check ($folders.Count -eq 1 -and (Get-FolderTitleIds $folders[0]) -eq $smt.TitleId) 'the game to add was copied'
    Check ($script:PendingRemoval -and @($script:PendingRemoval.Items | ForEach-Object TitleId) -contains $omega.TitleId) 'the game to remove is marked'
    $savedRemoval = Get-ThreeDSManagerState -Name 'pending-removal.json'
    Check ($savedRemoval -and $savedRemoval.Status -eq 'Awaiting console removal') 'the removal mark was saved'
    Check (Test-Path -LiteralPath (Join-Path $titles $omega.TitleId.Substring(8))) 'the PC never deletes the installed game itself'
    Check ($script:InlineNotice -match '^Copied 1 game to the SD card; 1 marked for removal') "the notice reports both: '$($script:InlineNotice)'"
    Check ($script:NextStepTitle.Text -eq 'Batch ready - 1 game; 1 to remove') "Next step title: '$($script:NextStepTitle.Text)'"
    Check ($script:NextStepText.Text -match 'Install game image' -and $script:NextStepText.Text -match 'delete: Pokemon Omega Ruby\.') 'Next step gives the install and delete steps together'
    $omegaRow = @($script:ViewItems | Where-Object TitleId -eq $omega.TitleId)[0]
    Check ($omegaRow.PreparationStatus -eq 'Delete on the 3DS' -and $omegaRow.IsRemoveChosen -and $omegaRow.CanRemove) 'the marked game says so and its Remove box stays ticked'
    Check ([string]$script:ApplyChanges.Content -eq 'Apply changes' -and -not $script:ApplyChanges.IsEnabled) 'nothing is left to apply'

    # --- Remove only: no confirmation pop-up, marks join the earlier ones ------------------
    Invoke-ApplyChanges -Removals @(@($script:ViewItems | Where-Object TitleId -eq $ridge.TitleId)[0])
    Check ($script:InlineNotice -match '^1 game marked for removal') "the notice: '$($script:InlineNotice)'"
    Check (@($script:PendingRemoval.Items).Count -eq 2) 'both marked games stay marked'
    Check ($script:NextStepTitle.Text -eq 'Batch ready - 1 game; 2 to remove') "Next step title: '$($script:NextStepTitle.Text)'"

    # --- The console deleted one of the two: that one is confirmed, the other stays --------
    Remove-Item -LiteralPath (Join-Path $titles $ridge.TitleId.Substring(8)) -Recurse -Force
    Invoke-RefreshAll
    Check ($script:LastRemovalConfirmed -eq 'Ridge Racer 3D') "the deleted game is confirmed: '$($script:LastRemovalConfirmed)'"
    Check ((@($script:PendingRemoval.Items | ForEach-Object TitleId) -join ',') -eq $omega.TitleId) 'the other stays marked'
    Check (@((Get-ThreeDSManagerState -Name 'pending-removal.json').Items).Count -eq 1) 'the remaining mark was saved'

    # --- Cancel while preparing: finished games are kept, the rest is cancelled ------------
    Reset-Card @()
    Build-ViewItems
    $script:CancelAtGame = 2
    Invoke-ApplyChanges -Adds (Get-Ticked @($smt.TitleId, $stella.TitleId))
    Check (@(Get-Folders).Count -eq 0) 'nothing is copied after Cancel'
    Check ((@($script:GuidedInstall.Backlog | ForEach-Object TitleId) -join ',') -eq $smt.TitleId) 'the game prepared before Cancel is kept, waiting on the PC'
    Check ($script:InlineNotice -match '^Stopped' -and $script:InlineNotice -match 'Kept what had finished: 1 game prepared\.') "the notice says what was kept: '$($script:InlineNotice)'"
    $row = @{}; foreach ($v in $script:ViewItems) { $row[$v.TitleId] = $v }
    Check ($row[$smt.TitleId].LifecycleState -eq 'Prepared on PC' -and $row[$stella.TitleId].CanSelect) 'the list shows the kept game, and the cancelled one can be ticked again'
    Check (-not $script:Busy) 'the app is idle again'

    # --- Cancel while copying: games already on the card are kept as a smaller batch -------
    $script:CancelWhen = { param($Title, $Detail) $Title -eq 'Copying games to the SD card' -and $Detail -match '^Copying 2 of 2' }
    Invoke-ApplyChanges -Adds (Get-Ticked @($stella.TitleId))
    $folders = @(Get-Folders)
    Check ($folders.Count -eq 1 -and $folders[0] -like '1-games - *') "the folder holds only the finished copy and is named for it ($($folders -join ', '))"
    $onCard = @(Get-ChildItem -LiteralPath (Join-Path $queueRoot $folders[0]) -Filter *.cia)
    $manifest = Get-Content -LiteralPath (Join-Path $queueRoot "$($folders[0])\INSTALL-QUEUE.json") -Raw | ConvertFrom-Json
    Check ($onCard.Count -eq 1 -and @($manifest.Queue).Count -eq 1 -and $manifest.BatchId -eq $folders[0]) 'one complete game, no partial file, and a matching install list'
    Check ($null -ne (Get-ThreeDSManagerState -Name (Get-ThreeDSInstallBatchStateName -BatchId $folders[0]))) 'the smaller batch has its private record'
    $copiedId = $onCard[0].Name.Substring(0, 16)
    $waitingIds = @($script:GuidedInstall.Backlog | ForEach-Object TitleId)
    Check ($script:GuidedInstall.ActiveBatchId -eq $folders[0] -and $waitingIds.Count -eq 1 -and $waitingIds[0] -ne $copiedId) 'it is the active batch and the cancelled game waits on the PC'
    Check ($script:InlineNotice -match 'Kept what had finished: 1 game prepared, 1 copied to the SD card\.') "the notice says what was kept: '$($script:InlineNotice)'"
    Check ($script:NextStepTitle.Text -like 'Batch ready - 1 game*' -and $script:NextStepText.Text -match '1 more game will be copied automatically') "Next step: '$($script:NextStepText.Text)'"

    # --- Changed your mind: untick Remove and apply to keep the game -----------------------
    $omegaRow = @($script:ViewItems | Where-Object TitleId -eq $omega.TitleId)[0]
    $omegaRow.IsRemoveChosen = $false
    Update-SelectionSummary
    Check ([string]$script:ApplyChanges.Content -eq 'Keep on 3DS' -and $script:ApplyChanges.IsEnabled) "unticking a mark offers to keep it: '$($script:ApplyChanges.Content)'"
    Invoke-ApplyChanges -Keeps @(Get-RemovalChanges -Keep)
    Check ($null -eq $script:PendingRemoval -and (Get-ThreeDSManagerState -Name 'pending-removal.json').Status -eq 'Cleared') 'the mark is gone and stays gone'
    $omegaRow = @($script:ViewItems | Where-Object TitleId -eq $omega.TitleId)[0]
    Check ($omegaRow.PreparationStatus -eq '' -and -not $omegaRow.IsRemoveChosen -and $omegaRow.CanRemove) 'the game is back to normal'
    Check ($script:InlineNotice -match '^1 game kept on the 3DS' -and $script:NextStepText.Text -notmatch 'delete:') "no delete step remains: '$($script:InlineNotice)'"
    'ALL CHECKS PASSED'
}
finally {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
}
