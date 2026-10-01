# Static audit: PowerShell parser validation, WPF/XAML validation, and the
# standing prohibitions that must survive every future change.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $env:THREEDS_MANAGER_DATA_ROOT) {
    $env:THREEDS_MANAGER_DATA_ROOT = Join-Path $env:TEMP ('BackupsNew3DS.Isolated.' + [guid]::NewGuid().ToString('N'))
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptRoot = Join-Path $repoRoot 'scripts'
$testRoot = Join-Path $repoRoot 'tests'

function Assert-Equal($Expected, $Actual, [string]$Message) {
    if ($Expected -ne $Actual) { throw "$Message Expected '$Expected'; got '$Actual'." }
}

# --- 1. PowerShell parser validation ---------------------------------------
$sources = @(Get-ChildItem -LiteralPath $scriptRoot, $testRoot -File -Recurse |
    Where-Object { $_.Extension -in @('.ps1','.psm1') } | Sort-Object FullName)
if ($sources.Count -lt 10) { throw "Only $($sources.Count) PowerShell sources were found; the audit is not covering the project." }
$parseFailures = @()
foreach ($file in $sources) {
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$errors)
    foreach ($parseError in @($errors)) {
        $parseFailures += "$($file.Name):$($parseError.Extent.StartLineNumber) $($parseError.Message)"
    }
}
Assert-Equal 0 $parseFailures.Count ("PowerShell parser validation failed: " + ($parseFailures -join ' | '))

# --- 2. WPF/XAML validation -------------------------------------------------
# The manager needs an STA thread to load the XAML, so run its own validator.
$managerPath = Join-Path $scriptRoot 'library-manager.ps1'
if (-not (Test-Path -LiteralPath $managerPath)) { throw 'library-manager.ps1 is missing.' }
$xamlOutput = & powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File $managerPath -ValidateOnly 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) { throw "XAML validation exited with code $LASTEXITCODE`: $xamlOutput" }
if ($xamlOutput -notmatch 'GUI XAML validation PASS') { throw "XAML validation did not pass: $xamlOutput" }
if ($xamlOutput -notmatch 'GUI XAML validation PASS \((\d+) controls\)') { throw 'XAML validation did not report a control count.' }
$xamlControlCount = [int]$Matches[1]
if ($xamlControlCount -lt 30) { throw "XAML validation reported only $xamlControlCount controls." }

# Every x:Name in the XAML must be resolved into a script variable.
$managerText = Get-Content -LiteralPath $managerPath -Raw
$declaredNames = @([regex]::Matches($managerText, 'x:Name="([A-Za-z0-9_]+)"') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
if (-not ($managerText -match '\$controlNames\s*=\s*@\(([^)]*)\)')) { throw 'Could not locate the control-name list.' }
$boundNames = @([regex]::Matches($Matches[1], "'([A-Za-z0-9_]+)'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
$unbound = @($declaredNames | Where-Object { $_ -notin $boundNames })
Assert-Equal 0 $unbound.Count ("Named XAML controls are never bound: " + ($unbound -join ', '))
$missing = @($boundNames | Where-Object { $_ -notin $declaredNames })
Assert-Equal 0 $missing.Count ("Bound control names do not exist in the XAML: " + ($missing -join ', '))

# --- 3. --ignore-bad-hashes must remain prohibited --------------------------
# Conversion may never suppress source content-hash verification.  Only a comment
# recording the prohibition, or documentation describing it, is allowed.
# This audit necessarily contains the literal it forbids, so it excludes itself.
$auditable = @($sources | Where-Object { $_.Name -ne 'test-static-audit.ps1' })
$hashOffenders = @()
foreach ($file in $auditable) {
    $lineNumber = 0
    foreach ($line in @(Get-Content -LiteralPath $file.FullName)) {
        $lineNumber++
        if ($line -notmatch 'ignore-bad-hashes') { continue }
        if ($line -match '^\s*#') { continue }                       # explanatory comment
        if ($line -match 'ignore-bad-hashes' -and $line -match "(?i)(throw|prohibit|never|refuse|must not)") { continue }
        $hashOffenders += "$($file.Name):$lineNumber $($line.Trim())"
    }
}
Assert-Equal 0 $hashOffenders.Count ("--ignore-bad-hashes appears in executable code: " + ($hashOffenders -join ' | '))

# The prohibition must still be documented at the conversion call site.
$coreText = Get-Content -LiteralPath (Join-Path $scriptRoot 'ThreeDSLibrary.Core.psm1') -Raw
if ($coreText -notmatch '(?i)never add --ignore-bad-hashes') {
    throw 'The --ignore-bad-hashes prohibition comment was removed from the conversion path.'
}
# --ignore-encryption remains permitted, but only as a deliberate, single use.
$encryptionUses = @([regex]::Matches($coreText, "'--ignore-encryption'")).Count
if ($encryptionUses -lt 1) { throw 'The documented --ignore-encryption handling disappeared.' }
if ($encryptionUses -gt 1) { throw "--ignore-encryption is applied from $encryptionUses places; it must stay a single controlled decision." }

# --- 4. The zero-item aggregate idiom must not return -----------------------
# Scoped to production code: tests/test-aggregation.ps1 deliberately exercises the
# unsafe idiom to prove it still throws.
$sumOffenders = @()
foreach ($file in @($sources | Where-Object { $_.DirectoryName -eq $scriptRoot })) {
    $lineNumber = 0
    foreach ($line in @(Get-Content -LiteralPath $file.FullName)) {
        $lineNumber++
        if ($line -match '^\s*#') { continue }
        if ($line -match 'Measure-Object[^|\r\n]*-Sum\s*\)\s*\.Sum') { $sumOffenders += "$($file.Name):$lineNumber" }
    }
}
Assert-Equal 0 $sumOffenders.Count ("The unsafe zero-item .Sum idiom reappeared: " + ($sumOffenders -join ', '))

# --- 5. SD state text must come from the lifecycle model only ---------------
# The manager may not hand-write a safe-to-remove message anywhere except the
# single place that renders the resolved lifecycle state.
$rawEjectAssignments = @()
$lineNumber = 0
foreach ($line in @(Get-Content -LiteralPath $managerPath)) {
    $lineNumber++
    if ($line -match '^\s*#') { continue }
    if ($line -match '\$script:EjectStateText\.Text\s*=' -and $line -notmatch '\$state\.EjectStateText') {
        $rawEjectAssignments += "library-manager.ps1:$lineNumber"
    }
    if ($line -match '\$script:HeaderSdStatus\.Text\s*=' -and $line -notmatch '\$state\.HeaderText') {
        $rawEjectAssignments += "library-manager.ps1:$lineNumber"
    }
    if ($line -match '\$script:SdFriendlyStatus\.Text\s*=' -and $line -notmatch '\$state\.StatusText') {
        $rawEjectAssignments += "library-manager.ps1:$lineNumber"
    }
}
Assert-Equal 0 $rawEjectAssignments.Count ("SD status text is assigned outside the lifecycle renderer: " + ($rawEjectAssignments -join ', '))

# The SD list must be built and selected through the shared candidate model.
# Auto-selection once counted every lettered non-boot volume, so an internal
# drive beside the card blocked identification indefinitely.
$managerAst = [System.Management.Automation.Language.Parser]::ParseFile($managerPath, [ref]$null, [ref]$null)
$refreshSd = $managerAst.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Refresh-SdTargets'
}, $true)
if (-not $refreshSd) { throw 'Refresh-SdTargets is missing from the manager.' }
$refreshSdText = $refreshSd.Body.Extent.Text
if ($refreshSdText -notmatch 'Resolve-ThreeDSSdSelection') { throw 'The SD list no longer selects through Resolve-ThreeDSSdSelection.' }
if ($refreshSdText -match 'Count\s+-eq\s+1') { throw 'The SD list reintroduced a raw volume-count auto-selection rule.' }

# --- 6. No modal dialogs in normal operation --------------------------------
# Modal popups are reserved for destructive confirmations and errors. A completion
# or advisory popup can land behind another window and make the app look frozen,
# so results are reported inline instead.
$managerLines = @(Get-Content -LiteralPath $managerPath)
$windowDialogs = @()
for ($i = 0; $i -lt $managerLines.Count; $i++) {
    $line = $managerLines[$i]
    if ($line -notmatch 'MessageBox\]::Show\(\$window') { continue }
    $windowDialogs += [pscustomobject]@{ Line = $i + 1; Text = $line }
}
$informational = @($windowDialogs | Where-Object { $_.Text -match "'Information'" })
Assert-Equal 0 $informational.Count ("Completion popups remain: " + (@($informational | ForEach-Object { "line $($_.Line)" }) -join ', '))

# The only OK/Warning popup allowed is the one explaining why closing was blocked.
$warnDialogs = @($windowDialogs | Where-Object { $_.Text -match "'Warning'" -and $_.Text -notmatch "'YesNo'" })
foreach ($dialog in $warnDialogs) {
    if ($dialog.Text -notmatch 'Add_Closing') {
        throw "An advisory popup remains at line $($dialog.Line); advisories must be shown inline."
    }
}

# Applying the ticked changes is the decision, and Cancel is the only control while it
# runs.  Nothing here is destructive on the PC: adding copies games, and removing only
# marks a game for console-side deletion, which unticking Remove and applying undoes.
$confirmations = @($windowDialogs | Where-Object { $_.Text -match "'YesNo'" })
Assert-Equal 0 $confirmations.Count ("Confirmation prompts remain: " + (@($confirmations | ForEach-Object { "line $($_.Line)" }) -join ', '))
foreach ($noPrompt in @('Prepare SD card', 'Prepare next batch', 'Remove games from 3DS')) {
    if ($managerText -match ("MessageBox\]::Show\(\`$window[^
]*" + [regex]::Escape($noPrompt))) {
        throw "A pre-action confirmation still guards '$noPrompt'."
    }
}

# Results that used to be popups must now be reported through the inline surface.
if ($managerText -notmatch 'function Show-Notice') { throw 'The inline result surface Show-Notice is missing.' }
foreach ($phrase in @('Batch ready - ', 'Stopped', 'marked for removal')) {
    if ($managerText -notmatch [regex]::Escape("Show-Notice")) { throw 'Inline results are not routed through Show-Notice.' }
}

# --- 7. The card path is trusted: copies are never re-read ------------------
# With a healthy reader, staging copies each validated artifact once and returning
# batches are judged by manifest and length.  Re-reading staged or installed files
# is the complexity this pins out.
$coreAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $scriptRoot 'ThreeDSLibrary.Core.psm1'), [ref]$null, [ref]$null)
$stageFunction = $coreAst.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Copy-ThreeDSInstallQueue'
}, $true)
if (-not $stageFunction) { throw 'Could not locate the staging function.' }
$stageText = (@($stageFunction.Body.Extent.Text -split "`r?`n") | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
if ($stageText -match 'Test-ThreeDSCia|Get-ThreeDSImageMetadata|Get-ThreeDSFileSHA256|Get-FileHash') {
    throw 'Staging re-reads or re-validates a copy instead of trusting the validated artifact.'
}
if ($coreText -match 'WriteThrough|FILE_FLAG_NO_BUFFERING|Test-ThreeDSPersistedCopy') {
    throw 'Write-through or uncached read-back verification reappeared.'
}
$readSd = $managerAst.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Read-SmartSdState'
}, $true)
if (-not $readSd) { throw 'Read-SmartSdState is missing from the manager.' }
if ($readSd.Body.Extent.Text -match 'FullReadCheck|VerifyHashes|Get-ThreeDSFileSHA256') {
    throw 'Returning batches are re-read instead of judged by manifest and length.'
}

# Progress must name the game and its position.
if ($stageText -notmatch 'Copying \$currentArtifactPosition of \$artifactCount') { throw 'Copy progress does not report position and game.' }

# --- 8. Repository storage boundaries --------------------------------------
$forbidden = @(Get-ChildItem -LiteralPath $repoRoot -File -Recurse -Force |
    Where-Object { $_.FullName -notmatch '\\\.git\\' -and $_.Extension -in @('.cia','.3ds','.cci','.app','.tmd','.sav','.bin') })
Assert-Equal 0 $forbidden.Count ("Game or console data is present in the repository: " + (@($forbidden | ForEach-Object { $_.Name }) -join ', '))

[pscustomobject]@{
    Status='PASS'
    ParserValidation="PASS ($($sources.Count) files)"
    XamlValidation="PASS ($xamlControlCount controls)"
    XamlControlBinding='PASS'
    IgnoreBadHashesProhibited='PASS'
    IgnoreEncryptionSingleUse='PASS'
    NoUnsafeSumIdiom='PASS'
    SdTextFromModelOnly='PASS'
    SdSelectionFromModel='PASS'
    NoCompletionPopups='PASS'
    OnlyDestructiveConfirmations='PASS'
    NoStagingReadBack='PASS'
    NoReturnFullRead='PASS'
    ProgressNamesGameAndPosition='PASS'
    NoGameDataInRepository='PASS'
} | Format-List
