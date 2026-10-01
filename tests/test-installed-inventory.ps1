# Regression coverage for installed-title inventory.
#
# The bug this pins: GodMode9 refuses a damaged CIA before writing anything and
# leaves an empty Title-ID folder behind.  Inventory reported that folder as an
# unhealthy install, so the title could never be selected again and new batches
# held it back pending a console-side removal that has nothing to remove.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$testRoot = Join-Path $env:TEMP ('BackupsNew3DS.Inventory.' + [guid]::NewGuid().ToString('N'))
$env:THREEDS_MANAGER_DATA_ROOT = Join-Path $testRoot 'state'
New-Item -ItemType Directory -Path $env:THREEDS_MANAGER_DATA_ROOT -Force | Out-Null
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\ThreeDSLibrary.Core.psm1') -Force -DisableNameChecking

function Assert-Equal($Expected, $Actual, [string]$Message) {
    if ($Expected -ne $Actual) { throw "$Message Expected '$Expected'; got '$Actual'." }
}

try {
    $sdRoot = Join-Path $testRoot 'card'
    $base = Join-Path $sdRoot ('Nintendo 3DS\{0}\{1}\title\00040000' -f ('A' * 32), ('B' * 32))

    # Refused install: an empty Title-ID folder, the real shape GodMode9 left.
    New-Item -ItemType Directory -Path (Join-Path $base '0f70cc00') -Force | Out-Null
    # Empty subfolders still hold no installed files.
    New-Item -ItemType Directory -Path (Join-Path $base '00173700\content\cmd') -Force | Out-Null
    # A partial install with real content stays visible as an unhealthy install.
    $partial = Join-Path $base '0011c400\content'
    New-Item -ItemType Directory -Path $partial -Force | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $partial '00000000.app'), [byte[]](1..64))
    # An install with complete metadata is still reported.
    $complete = Join-Path $base '00035800\content'
    New-Item -ItemType Directory -Path (Join-Path $complete 'cmd') -Force | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $complete '00000000.app'), [byte[]](1..64))
    [IO.File]::WriteAllBytes((Join-Path $complete '00000000.tmd'), [byte[]](1..16))
    [IO.File]::WriteAllBytes((Join-Path $complete 'cmd\00000001.cmd'), [byte[]](1..16))

    $titles = @(Get-ThreeDSInstalledTitles -SdRoot $sdRoot)
    $ids = @($titles | ForEach-Object { $_.TitleId })
    Assert-Equal 0 @($ids | Where-Object { $_ -eq '000400000F70CC00' }).Count 'An empty Title-ID folder was reported as an installed title.'
    Assert-Equal 0 @($ids | Where-Object { $_ -eq '0004000000173700' }).Count 'A Title-ID folder holding only empty subfolders was reported as an installed title.'
    Assert-Equal 'Installed + unhealthy' (@($titles | Where-Object TitleId -eq '000400000011C400')[0].State) 'A partial install with content was not reported as unhealthy.'
    Assert-Equal 1 @($ids | Where-Object { $_ -eq '0004000000035800' }).Count 'An install with content was not reported.'
    Assert-Equal 2 $titles.Count 'Inventory reported the wrong number of installed titles.'

    # A card holding only empty Title-ID folders has an empty inventory, without
    # tripping strict mode on the zero-item collection.
    $emptyCard = Join-Path $testRoot 'empty-card'
    New-Item -ItemType Directory -Path (Join-Path $emptyCard ('Nintendo 3DS\{0}\{1}\title\00040000\0f70cc00' -f ('C' * 32), ('D' * 32))) -Force | Out-Null
    Assert-Equal 0 @(Get-ThreeDSInstalledTitles -SdRoot $emptyCard).Count 'A card holding only empty Title-ID folders reported installed titles.'

    [pscustomobject]@{
        Status='PASS'
        EmptyTitleFolderIsNotInstalled='PASS'
        EmptySubfoldersAreNotInstalled='PASS'
        PartialContentStaysUnhealthy='PASS'
        InstalledContentStillReported='PASS'
        OnlyEmptyFoldersYieldsEmptyInventory='PASS'
    } | Format-List
}
finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
