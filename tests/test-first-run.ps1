# First run for a new user, against the manager's own setup functions.  Setup is required, so it
# is never hidden: helper tools install by themselves on first start, the Next step card is a
# checklist with one button for the one thing only the user can do, a working folder is chosen
# beside the game folder, and the first check starts as soon as setup is done.  The tool
# download itself is replaced by a stub; setup-library-tools.ps1 is exercised separately.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName PresentationFramework
$repo = Split-Path -Parent $PSScriptRoot
$root = Join-Path $env:TEMP ('BackupsNew3DS.FirstRun.' + [guid]::NewGuid().ToString('N'))
$env:THREEDS_MANAGER_DATA_ROOT = Join-Path $root 'state'
New-Item -ItemType Directory -Path $env:THREEDS_MANAGER_DATA_ROOT -Force | Out-Null
Import-Module (Join-Path $repo 'scripts\ThreeDSLibrary.Core.psm1') -Force -DisableNameChecking
function Check([bool]$Condition, [string]$Message) { if (-not $Condition) { throw "FAIL: $Message" }; "ok   $Message" }

try {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'scripts\library-manager.ps1'), [ref]$null, [ref]$null)
    foreach ($name in 'Get-DefaultWorkingFolder','Test-FoldersOverlap','Get-SetupStep','Show-SetupStep','Install-HelperTools','Set-LibraryFolder','Invoke-SetupAction','Start-Setup','Resume-Setup','Invoke-CheckForChanges','Update-NextStep','Get-GuidedInstallPlan') {
        $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
        if (-not $fn) { throw "$name not found in the manager." }
        . ([scriptblock]::Create($fn.Extent.Text))
    }
    # --- Stubs for everything outside setup -------------------------------------------------
    $script:FakeToolsInstalled = $false; $script:FailSetup = $true; $script:SetupRuns = 0; $script:RefreshRuns = 0; $script:NextFolderChoice = ''
    $script:Logged = New-Object System.Collections.ArrayList
    function Get-ThreeDSToolchain { [pscustomobject]@{ Ready=$script:FakeToolsInstalled } }
    function Invoke-ToolSetup {
        $script:SetupRuns++
        if ($script:FailSetup) { throw 'Python 3 is not installed. Install it from https://www.python.org/downloads/ (the default options are fine), then set up the helper tools again.' }
        $script:FakeToolsInstalled = $true
    }
    function Add-Log([string]$Message) { [void]$script:Logged.Add($Message) }
    function Set-Busy([bool]$Busy, [string]$Title = 'Ready') { $script:Busy = $Busy }
    function Set-Progress([string]$Title, [string]$Detail, [uint64]$Done = 0, [uint64]$Total = 0) {}
    function Save-Preferences { $script:SavedPrefs = [pscustomobject]@{ LibraryRoot=$script:LibraryPath.Text; InstallReadyRoot=$script:CachePath.Text } }
    function Select-Folder([string]$InitialPath) { $script:NextFolderChoice }
    function Show-Notice([string]$Summary, [string]$Detail = '') { $script:InlineNotice = $Summary }
    function Get-RemovableSignature { 'drives' }
    function Invoke-RefreshAll { $script:RefreshRuns++ }
    function Refresh-SdTargets {
        $script:SdTargets.ItemsSource = @([pscustomobject]@{ FriendlyDisplay='N3DS'; FreeBytes=[uint64]64GB }); $script:SdTargets.SelectedIndex = 0
        $script:SdLifecycle = [pscustomobject]@{ ShowsSuccessfulEject=$false; CanUseSd=$true; IsMounted=$true; StatusText='SD detected' }
    }
    foreach ($n in 'NextStepTitle','NextStepText') { Set-Variable -Scope Script -Name $n -Value (New-Object Windows.Controls.TextBlock) }
    foreach ($n in 'SetupAction','CancelOperation') { Set-Variable -Scope Script -Name $n -Value (New-Object Windows.Controls.Button) }
    $script:LibraryPath = New-Object Windows.Controls.TextBox
    $script:CachePath = New-Object Windows.Controls.TextBox
    $script:SdTargets = New-Object Windows.Controls.ComboBox
    $script:SdLifecycle = [pscustomobject]@{ ShowsSuccessfulEject=$false; CanUseSd=$false; IsMounted=$false; StatusText='Connect the 3DS SD card.' }
    $script:Busy = $false; $script:InlineNotice = ''; $script:PendingRemoval = $null; $script:LastRemovalConfirmed = ''; $script:InstalledItems = @()
    $script:GuidedInstall = [pscustomobject]@{ Backlog=@(); ActiveBatchId=''; ActiveTitleIds=@(); ActiveCount=0; AwaitingReturn=$false; LastReturnMessage='' }
    $script:ToolsError = ''
    $games = Join-Path $root 'My 3DS\Games'
    New-Item -ItemType Directory -Path $games -Force | Out-Null

    # --- First start, Python missing: the tools try to install, and the card says why they could not
    Start-Setup
    Check ($script:SetupRuns -eq 1) 'the helper tools install by themselves on first start'
    Check ($script:NextStepTitle.Text -eq 'Finish setup' -and $script:NextStepText.Text -match 'Helper tools could not be set up\. Python 3 is not installed' -and $script:NextStepText.Text -match 'python\.org') "the card says what is missing and where to get it: '$($script:NextStepText.Text)'"
    Check ([string]$script:SetupAction.Visibility -eq 'Visible' -and [string]$script:SetupAction.Content -eq 'Set up helper tools' -and $script:SetupAction.IsEnabled) 'the card offers to try again'
    Check ($script:RefreshRuns -eq 0) 'nothing is checked before setup is done'
    Invoke-CheckForChanges
    Check ($script:RefreshRuns -eq 0 -and $script:NextStepTitle.Text -eq 'Finish setup') 'Check for changes waits for setup too'

    # --- Python installed, the user tries again --------------------------------------------------
    $script:FailSetup = $false
    Invoke-SetupAction
    Check ($script:SetupRuns -eq 2 -and $script:ToolsReady -and $script:ToolsError -eq '') 'the second try installs the tools'
    Check ($script:NextStepText.Text -match 'Done: helper tools are installed\.' -and $script:NextStepText.Text -match 'Choose the folder that holds your game files') 'the checklist moves on to the game folder'
    Check ([string]$script:SetupAction.Content -eq 'Choose game folder') 'the card asks for the game folder'

    # --- The user chooses the game folder: the working folder is chosen for them, and the first check runs
    $script:NextFolderChoice = $games
    Invoke-SetupAction
    $expectedWorking = Join-Path (Join-Path $root 'My 3DS') 'InstallReady'
    Check ($script:LibraryPath.Text -eq $games -and $script:CachePath.Text -eq $expectedWorking) "the working folder goes beside the game folder ($($script:CachePath.Text))"
    Check ($script:SavedPrefs.LibraryRoot -eq $games -and $script:SavedPrefs.InstallReadyRoot -eq $expectedWorking) 'both folders are saved'
    Check ($script:RefreshRuns -eq 1) 'the first check runs as soon as setup is done'
    Check ([string]$script:SetupAction.Visibility -eq 'Collapsed' -and $script:NextStepTitle.Text -ne 'Finish setup') 'the setup checklist is gone'

    # --- A later start with everything in place goes straight to work ----------------------------
    $runsBefore = $script:SetupRuns
    Start-Setup
    Check ($script:SetupRuns -eq $runsBefore -and $script:RefreshRuns -eq 2) 'a set-up app installs nothing and checks straight away'

    # --- A working folder inside the game folder is refused --------------------------------------
    $script:CachePath.Text = Join-Path $games 'InstallReady'
    Update-NextStep
    Check ((Get-SetupStep) -eq 'WorkingFolder' -and $script:NextStepText.Text -match 'must be outside your game folder' -and [string]$script:SetupAction.Content -eq 'Choose working folder') 'a working folder inside the game folder must be changed'
    $script:NextFolderChoice = Join-Path $root 'Elsewhere\Prepared'
    Invoke-SetupAction
    Check ((Get-SetupStep) -eq '' -and $script:RefreshRuns -eq 3) 'choosing another folder finishes setup and checks again'

    # --- A game folder that has gone (an unplugged drive) is asked for again -----------------------
    $script:LibraryPath.Text = Join-Path $root 'Unplugged\Games'
    Update-NextStep
    Check ((Get-SetupStep) -eq 'Library' -and [string]$script:SetupAction.Content -eq 'Choose game folder') 'a missing game folder is asked for again'

    # --- A game folder at a drive root keeps its working folder in the app's data folder ------------
    $atRoot = Get-DefaultWorkingFolder 'Q:\'
    Check ($atRoot -like "$env:THREEDS_MANAGER_DATA_ROOT*\InstallReady" -and -not (Test-FoldersOverlap 'Q:\' $atRoot)) "a game folder at the root of a games drive gets a working folder in app data ($atRoot)"
    'ALL CHECKS PASSED'
}
finally {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
}
