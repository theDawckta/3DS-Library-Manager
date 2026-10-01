# Two SD cards from two consoles, used one at a time in the same reader, against the manager's
# own functions.  Each card keeps its own install batch, waiting games and removal marks, so
# nothing crosses between them: a batch is never reported returned from the wrong card, games
# chosen for one card are never copied to the other, and a removal is never confirmed on a
# card that never had the game.  The single record kept before cards were tracked separately
# is adopted only by the card that holds its install folder.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName PresentationFramework
$repo = Split-Path -Parent $PSScriptRoot
$root = Join-Path $env:TEMP ('BackupsNew3DS.MultiCard.' + [guid]::NewGuid().ToString('N'))
$env:THREEDS_MANAGER_DATA_ROOT = Join-Path $root 'state'
New-Item -ItemType Directory -Path $env:THREEDS_MANAGER_DATA_ROOT -Force | Out-Null
Import-Module (Join-Path $repo 'scripts\ThreeDSLibrary.Core.psm1') -Force -DisableNameChecking
function Check([bool]$Condition, [string]$Message) { if (-not $Condition) { throw "FAIL: $Message" }; "ok   $Message" }

try {
    # --- Two cards from two consoles, and the PC's prepared copies ---------------------------
    $cache = Join-Path $root 'InstallReady'
    function New-Card([string]$Name, [string]$Id0, [string]$Id1) {
        $cardRoot = Join-Path $root $Name
        New-Item -ItemType Directory -Path (Join-Path $cardRoot "Nintendo 3DS\$Id0\$Id1\title\00040000"), (Join-Path $cardRoot 'cias\InstallQueue') -Force | Out-Null
        [pscustomobject]@{ Root=$cardRoot; DiskNumber=2; DiskCapacityBytes=[uint64]127999672320; DriveLetter='D:'; VolumeLabel=$Name; FreeBytes=[uint64]64GB; VolumeHealthStatus='Healthy'
            Titles=(Join-Path $cardRoot "Nintendo 3DS\$Id0\$Id1\title\00040000"); Queue=(Join-Path $cardRoot 'cias\InstallQueue') }
    }
    # Same reader, same size, same drive letter: only the card's own folders tell them apart.
    $cardA = New-Card 'CardA' ('A' * 32) ('B' * 32)
    $cardB = New-Card 'CardB' ('C' * 32) ('D' * 32)
    function New-Artifact([string]$TitleId, [string]$Title, [int]$Length) {
        $dir = Join-Path $cache "Base\$TitleId"; New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $path = Join-Path $dir (('C0FFEE00' + ('0' * 56)) + '.cia'); [IO.File]::WriteAllBytes($path, (New-Object byte[] $Length))
        [pscustomobject]@{ Title=$Title; TitleId=$TitleId; Type='Base'; ProductCode='CTR-P-TEST'; Region='USA'; SaveSizeBytes=[uint64]1024
            ContentManifest=@([pscustomobject]@{ Index='0000'; ContentId='00000000'; Length=[uint64]$Length }); ArtifactPath=$path; ArtifactLength=[uint64]$Length; ArtifactSHA256=('C0FFEE00' + ('0' * 56)) }
    }
    function New-Installed($Card, $Artifact) {
        $dir = Join-Path $Card.Titles $Artifact.TitleId.Substring(8)
        New-Item -ItemType Directory -Path (Join-Path $dir 'content\cmd'), (Join-Path $dir 'data') -Force | Out-Null
        [IO.File]::WriteAllBytes((Join-Path $dir 'content\00000000.app'), (New-Object byte[] ([int]$Artifact.ArtifactLength)))
        [IO.File]::WriteAllBytes((Join-Path $dir 'content\00000000.tmd'), (New-Object byte[] 64))
        [IO.File]::WriteAllBytes((Join-Path $dir 'content\cmd\00000001.cmd'), (New-Object byte[] 32))
        [IO.File]::WriteAllBytes((Join-Path $dir 'data\00000001.sav'), (New-Object byte[] 1024))
    }
    $v = New-Artifact '0004000000AAA100' 'Game V' 3000      # in the old batch on card A
    $w = New-Artifact '0004000000AAA200' 'Game W' 3100      # waiting in the old record
    $y = New-Artifact '0004000000AAA300' 'Game Y' 3200      # installed on card A, marked for removal
    $z = New-Artifact '0004000000AAA400' 'Game Z' 3300      # chosen later for card B
    New-Installed $cardA $y

    # The record kept before cards were tracked separately: a batch out on card A, a game waiting,
    # and a removal mark for card A's console.
    $oldBatch = '1-games - 2026-09-30 10-00-00'
    New-Item -ItemType Directory -Path (Join-Path $cardA.Queue $oldBatch) -Force | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $cardA.Queue "$oldBatch\$($v.TitleId)-C0FFEE00.cia"), (New-Object byte[] 3000))
    $vEntry = [pscustomobject]@{ Title=$v.Title; TitleId=$v.TitleId; Type='Base'; ProductCode='CTR-P-TEST'; Region='USA'; SaveSizeBytes=[uint64]1024; ContentManifest=@($v.ContentManifest); FileName="$($v.TitleId)-C0FFEE00.cia"; Length=[uint64]3000; SHA256=$v.ArtifactSHA256 }
    [pscustomobject]@{ CreatedAt=(Get-Date).ToString('o'); BatchId=$oldBatch; Queue=@($vEntry) } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $cardA.Queue "$oldBatch\INSTALL-QUEUE.json") -Encoding UTF8
    Save-ThreeDSManagerState -Name 'guided-install.json' -Value ([pscustomobject]@{ Backlog=@($w); ActiveBatchId=$oldBatch; ActiveTitleIds=@($v.TitleId); ActiveCount=1; AwaitingReturn=$false; LastReturnMessage='' }) | Out-Null
    Save-ThreeDSManagerState -Name 'pending-removal.json' -Value ([pscustomobject]@{ CreatedAt=(Get-Date).ToString('o'); Status='Awaiting console removal'; Items=@([pscustomobject]@{ Title='Game Y'; TitleId=$y.TitleId; Type='Base' }) }) | Out-Null
    $stateRoot = $env:THREEDS_MANAGER_DATA_ROOT

    # --- Card stub inside the module, switchable between the two cards -----------------------
    $module = Get-Module ThreeDSLibrary.Core
    & $module { Set-Item -Path 'function:script:Assert-ThreeDSSafeTarget' -Value { param($DiskNumber,$ExpectedDiskCapacityBytes,$ExpectedDriveLetter,[switch]$AllowUnhealthyVolume) $script:ThreeDSTestStubTarget } }
    function Use-Reader($Card) { $script:InReader = $Card; & $module { param($c) $script:ThreeDSTestStubTarget = $c } $Card }
    Use-Reader $cardA
    $proof = & $module { Assert-ThreeDSSafeTarget -DiskNumber 9 -ExpectedDiskCapacityBytes ([uint64]1) -ExpectedDriveLetter 'Z:' }
    if ([IO.Path]::GetFullPath($proof.Root) -ne [IO.Path]::GetFullPath($cardA.Root)) { throw 'REFUSING TO RUN: card stub not in effect.' }

    # --- The manager's own functions and controls --------------------------------------
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'scripts\library-manager.ps1'), [ref]$null, [ref]$null)
    foreach ($name in 'Get-CardStateName','New-GuidedInstallState','Save-GuidedInstallState','Use-CardState','Use-CardKey','Import-LegacyCardState','Assert-SameCard','Invoke-ApplyChanges','Show-StoppedNotice','Register-CopiedBatch','Add-PendingRemoval','Clear-RemovalMark','Get-RemovalChanges','Invoke-RefreshAll','Read-SmartSdState','Complete-GuidedReturn','Resolve-PendingRemoval','Copy-WaitingGames','Copy-GuidedQueue','Show-Notice','Add-GuidedBacklog','Get-GuidedInstallPlan','Save-PreparationFailures','Set-PreparationFailure','Clear-PreparationFailure','Build-ViewItems','Update-SdSpace','New-PieSliceGeometry','Format-SpaceSize','Update-NextStep','Update-SelectionSummary','Apply-Filter','Get-FriendlyTitle') {
        $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
        if (-not $fn) { throw "$name not found in the manager." }
        . ([scriptblock]::Create($fn.Extent.Text))
    }
    $script:Logged = New-Object System.Collections.ArrayList
    function Add-Log([string]$Message) { [void]$script:Logged.Add($Message) }
    function Pump-Ui {}
    function Save-Preferences {}
    function Set-Progress([string]$Title, [string]$Detail, [uint64]$Done = 0, [uint64]$Total = 0) {}
    function Set-Busy([bool]$Busy, [string]$Title = 'Ready') { $script:Busy = $Busy; if ($Busy) { $script:InlineNotice = '' } }
    function Show-Error { param($ErrorValue, [string]$Game = '', [string]$Operation = '') throw "Unexpected error during ${Operation}: $ErrorValue" }
    function Get-SelectedTarget { param([switch]$AllowUnhealthyVolume) $script:InReader }
    function Get-ThreeDSToolchain { [pscustomobject]@{ Ready=$true; CtrToolPath='ctrtool.exe' } }
    function Assert-ThreeDSExternalDataPath { param($Path, $RepositoryRoot) $Path }
    function Get-ThreeDSLibraryInventory { param($LibraryRoot, $CtrToolPath, $ProgressAction, $CachedItems) $script:LibraryItems }
    $script:ArtifactById = @{ $v.TitleId=$v; $w.TitleId=$w; $y.TitleId=$y; $z.TitleId=$z }
    function Invoke-ThreeDSPreparationBatch {
        param($Items, $PrepareAction, $SuccessAction, $FailureAction)
        $artifacts = @(); $number = 0
        foreach ($view in $Items) { $number++; $artifact = $script:ArtifactById[$view.TitleId]; & $SuccessAction $view $artifact $number $Items.Count; $artifacts += $artifact }
        [pscustomobject]@{ Artifacts=$artifacts; PreparedCount=$artifacts.Count; CachedCount=0; FailedCount=0; Failures=@() }
    }
    foreach ($n in 'NextStepTitle','NextStepText','SelectionSummary','FooterStatus','SpaceSummary','SpaceGamesText','SpaceOtherText','SpaceFreeText') { Set-Variable -Scope Script -Name $n -Value (New-Object Windows.Controls.TextBlock) }
    foreach ($n in 'RefreshAll','ApplyChanges') { Set-Variable -Scope Script -Name $n -Value (New-Object Windows.Controls.Button) }
    foreach ($n in 'SpaceGamesSlice','SpaceOtherSlice','SpaceFreeSlice') { Set-Variable -Scope Script -Name $n -Value (New-Object Windows.Shapes.Path) }
    $script:SpaceCard = New-Object Windows.Controls.Border
    $script:Boot9Panel = New-Object Windows.Controls.StackPanel
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
    $script:GuidedInstall = New-GuidedInstallState; $script:CardKey = ''      # as at startup: no card checked yet
    function New-Lib($Artifact) { [pscustomobject]@{ TitleId=$Artifact.TitleId; Title="$($Artifact.Title) (USA)"; Type='Base'; SourceSHA256=('9' * 64); SourceLength=[uint64]4096; Format='CIA'; EncryptionState='Decrypted'; CacheState='Reused' } }
    $script:LibraryItems = @((New-Lib $v), (New-Lib $w), (New-Lib $y), (New-Lib $z))
    function Get-Folders($Card) { @(Get-ChildItem -LiteralPath $Card.Queue -Directory | ForEach-Object Name) }
    function Get-Row([string]$TitleId) { @($script:ViewItems | Where-Object TitleId -eq $TitleId)[0] }
    $keyA = Get-ThreeDSCardKey -SdRoot $cardA.Root
    $keyB = Get-ThreeDSCardKey -SdRoot $cardB.Root
    Check ($keyA -match '^[0-9A-F]{16}$' -and $keyB -match '^[0-9A-F]{16}$' -and $keyA -ne $keyB) 'each card gets its own key, though the reader, size and drive letter are the same'
    Check ($keyA -eq (Get-ThreeDSCardKey -SdRoot $cardA.Root)) 'a card keeps its key'

    # --- Card B goes in first: the old record is not its to take ----------------------------
    Use-Reader $cardB
    Invoke-RefreshAll
    Check ($script:CardKey -eq $keyB) 'card B is the card on screen'
    Check (Test-Path -LiteralPath (Join-Path $stateRoot 'guided-install.json')) 'card B does not adopt a record whose batch is on another card'
    Check (@(Get-Folders $cardB).Count -eq 0) 'nothing waiting for card A is copied to card B'
    Check ($script:GuidedInstall.LastReturnMessage -eq '' -and $script:NextStepText.Text -notmatch 'Batch returned') 'card A''s batch is not reported as returned from card B'
    Check ($null -eq $script:PendingRemoval -and $script:LastRemovalConfirmed -eq '') 'a removal for card A is not confirmed on card B, which never had the game'

    # --- A game chosen for card B goes to card B ---------------------------------------------
    Invoke-ApplyChanges -Adds @(Get-Row $z.TitleId)
    $bFolders = @(Get-Folders $cardB)
    Check ($bFolders.Count -eq 1 -and (Test-Path -LiteralPath (Join-Path $cardB.Queue "$($bFolders[0])\$($z.TitleId)-C0FFEE00.cia"))) 'card B gets its own batch'
    $savedB = Get-ThreeDSManagerState -Name "guided-install-$keyB.json"
    Check ($savedB -and $savedB.ActiveBatchId -eq $bFolders[0]) 'card B''s batch is saved under card B'

    # --- Card A goes in: it adopts the old record and keeps everything that was its own ------
    Use-Reader $cardA
    Invoke-RefreshAll
    Check ($script:CardKey -eq $keyA) 'card A is the card on screen'
    Check (-not (Test-Path -LiteralPath (Join-Path $stateRoot 'guided-install.json')) -and -not (Test-Path -LiteralPath (Join-Path $stateRoot 'pending-removal.json'))) 'card A adopts the old record, so no other card can'
    Check ($script:GuidedInstall.ActiveBatchId -eq $oldBatch -and (Test-Path -LiteralPath (Join-Path $cardA.Queue $oldBatch))) 'card A keeps its batch, which has not been to its 3DS yet'
    Check ((@($script:GuidedInstall.Backlog | ForEach-Object TitleId) -join ',') -eq $w.TitleId) 'the waiting game belongs to card A'
    Check ($script:PendingRemoval -and (@($script:PendingRemoval.Items | ForEach-Object TitleId) -join ',') -eq $y.TitleId) 'the removal mark belongs to card A and is still waiting'
    Check (-not (Test-Path -LiteralPath (Join-Path $cardA.Queue "$($bFolders[0])"))) 'card B''s batch is not copied to card A'
    Check ($script:NextStepTitle.Text -eq 'Batch ready - 1 game; 1 to remove' -and $script:NextStepText.Text -match '1 more game will be copied automatically') "card A's own steps: '$($script:NextStepTitle.Text)'"

    # --- A swapped card is refused until it has been checked ----------------------------------
    Use-Reader $cardB                     # card B pushed in, but the screen still shows card A
    $refused = ''
    try { Invoke-ApplyChanges -Removals @(Get-Row $y.TitleId) } catch { $refused = $_.Exception.Message }
    Check ($refused -match 'not the one shown') "Apply refuses a card the screen does not show ('$refused')"
    Check ($script:CardKey -eq $keyA -and @(Get-Folders $cardB).Count -eq 1) 'nothing changed on either card'
    # Card A with a game waiting and no batch out would copy, so the copy itself must check the card.
    $cardAState = $script:GuidedInstall
    $script:GuidedInstall = [pscustomobject]@{ Backlog=@($w); ActiveBatchId=''; ActiveTitleIds=@(); ActiveCount=0; AwaitingReturn=$false; LastReturnMessage='' }
    $refused = ''
    try { Copy-WaitingGames | Out-Null } catch { $refused = $_.Exception.Message }
    $script:GuidedInstall = $cardAState
    Check ($refused -match 'not the one shown' -and @(Get-Folders $cardB).Count -eq 1) 'copying refuses it too, and card B gets nothing'

    # --- Card A goes to its 3DS; card B is checked meanwhile; card A comes back ----------------
    Use-Reader $cardA
    $script:GuidedInstall.AwaitingReturn = $true; Save-GuidedInstallState       # safely ejected for the 3DS
    New-Installed $cardA $v                                                     # installed on console A
    Use-Reader $cardB
    Invoke-RefreshAll
    Check ($script:GuidedInstall.ActiveBatchId -eq $bFolders[0] -and $script:NextStepText.Text -notmatch 'Batch returned') 'card B shows only its own batch'
    Use-Reader $cardA
    Invoke-RefreshAll
    Check ($script:InlineNotice -match 'Batch returned: 1 of 1 installed') "card A's batch returns on card A ('$($script:InlineNotice)')"
    $aFolders = @(Get-Folders $cardA)
    Check ($oldBatch -notin $aFolders -and $aFolders.Count -eq 1 -and (Test-Path -LiteralPath (Join-Path $cardA.Queue "$($aFolders[0])\$($w.TitleId)-C0FFEE00.cia"))) 'the returned folder is removed and card A''s waiting game is copied to card A'
    Check ((Get-ThreeDSManagerState -Name "guided-install-$keyB.json").ActiveBatchId -eq $bFolders[0] -and (Test-Path -LiteralPath (Join-Path $cardB.Queue $bFolders[0]))) 'card B''s batch and record are untouched'

    # --- A removal is confirmed only on the card whose console did it --------------------------
    Remove-Item -LiteralPath (Join-Path $cardA.Titles $y.TitleId.Substring(8)) -Recurse -Force    # deleted on console A
    Invoke-RefreshAll
    Check ($script:LastRemovalConfirmed -eq 'Game Y' -and $null -eq $script:PendingRemoval) 'card A confirms its own removal'
    Use-Reader $cardB
    Invoke-RefreshAll
    Check ($script:LastRemovalConfirmed -eq '' -and $script:NextStepText.Text -notmatch 'Removal confirmed') 'card B does not show card A''s confirmation'
    Check (@($script:Logged | Where-Object { $_ -match 'different SD card' }).Count -ge 1) 'switching cards is logged'

    # --- Reopening the app while card A is out in its 3DS shows card A's batch -----------------
    $aBatch = (Get-ThreeDSManagerState -Name "guided-install-$keyA.json").ActiveBatchId
    $script:CardKey = ''; $script:GuidedInstall = New-GuidedInstallState; $script:InlineNotice = ''
    Use-CardKey $keyA                      # what startup does with the last card checked
    Update-NextStep
    Check ($script:NextStepTitle.Text -like 'Batch ready - 1 game*' -and $script:NextStepText.Text -match [regex]::Escape($aBatch)) "the last card's batch and folder are shown while it is out ('$($script:NextStepTitle.Text)')"
    $refused = ''
    try { Invoke-ApplyChanges -Adds @(Get-Row $z.TitleId) } catch { $refused = $_.Exception.Message }
    Check ($refused -match 'not the one shown') 'a different card in the reader still has to be checked before any change'
    'ALL CHECKS PASSED'
}
finally {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
}
