<#
    Installs the helper tools the app converts and checks games with, below the app's own data
    folder.  The app runs this by itself the first time.  It is safe to run again: every step is
    skipped when already done, a half-finished earlier attempt is replaced, and every download is
    checked against a pinned SHA-256 before it is used.  Python 3 must already be installed.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'ThreeDSLibrary.Core.psm1') -Force -DisableNameChecking
$dataRoot = Get-ThreeDSManagerDataRoot
$toolRoot = Join-Path $dataRoot 'tools'
$ctrRoot = Join-Path $toolRoot 'ctrtool'
$convDir = Join-Path $toolRoot '3dsconv\3dsconv'
$depsRoot = Join-Path $toolRoot 'pydeps'
$downloadRoot = Join-Path $dataRoot 'downloads'

$ctrVersion = '1.3.0'
$ctrUrl = 'https://github.com/3DSGuy/Project_CTR/releases/download/ctrtool-v1.3.0/ctrtool-v1.3.0-win_x64.zip'
$ctrSha256 = '8031DFF3BE72D0ADB250FAE1F969F27627E12A89EBC6DD074A15A75F87DDC949'
$converterCommit = '50a30d292e039a8b315eaccef85a067a8f48c500'
$converterUrl = "https://raw.githubusercontent.com/ihaveamac/3dsconv/$converterCommit/3dsconv/3dsconv.py"
# SHA-256 of 3dsconv.py at the pinned commit, exactly as GitHub serves it (LF line endings).
$converterSha256 = 'E0811B2E5439E51EBEDCDBBED47A175C8C3057CCE6A8B27ABB8F1652535B763D'
$pyaesVersion = '1.6.1'

New-Item -ItemType Directory -Path $toolRoot, $downloadRoot -Force | Out-Null
# Windows PowerShell 5.1 may not offer TLS 1.2 by default; GitHub requires it.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

function Test-PinnedConverter([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    # A copy checked out by Git on Windows has CRLF line endings; compare the content as published.
    $text = [IO.File]::ReadAllText($Path).Replace("`r`n", "`n")
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text)))).Replace('-', '') }
    finally { $sha.Dispose() }
    $hash -eq $converterSha256
}

# --- 1. CTRTool ---------------------------------------------------------------------------
$ctrExe = Join-Path $ctrRoot 'ctrtool.exe'
if (-not (Test-Path -LiteralPath $ctrExe -PathType Leaf)) {
    Write-Host "Downloading CTRTool $ctrVersion..."
    $ctrZip = Join-Path $downloadRoot "ctrtool-v$ctrVersion-win_x64.zip"
    Invoke-WebRequest -UseBasicParsing -Uri $ctrUrl -OutFile $ctrZip
    if ((Get-FileHash -LiteralPath $ctrZip -Algorithm SHA256).Hash -ne $ctrSha256) {
        Remove-Item -LiteralPath $ctrZip -Force
        throw 'The CTRTool download did not match its published checksum. Nothing was installed; try again later.'
    }
    # Extract beside the final folder and move it into place, so an interrupted run never
    # leaves a half-filled tool folder that looks installed.
    $staging = "$ctrRoot.partial"
    if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
    Expand-Archive -LiteralPath $ctrZip -DestinationPath $staging
    if (-not (Test-Path -LiteralPath (Join-Path $staging 'ctrtool.exe') -PathType Leaf)) { throw 'The CTRTool package did not contain ctrtool.exe.' }
    if (Test-Path -LiteralPath $ctrRoot) { Remove-Item -LiteralPath $ctrRoot -Recurse -Force }   # an earlier attempt without ctrtool.exe
    Move-Item -LiteralPath $staging -Destination $ctrRoot
}

# --- 2. 3dsconv (a single Python file) -----------------------------------------------------
$converter = Join-Path $convDir '3dsconv.py'
if (-not (Test-PinnedConverter $converter)) {
    Write-Host 'Downloading 3dsconv...'
    New-Item -ItemType Directory -Path $convDir -Force | Out-Null
    $download = "$converter.download"
    Invoke-WebRequest -UseBasicParsing -Uri $converterUrl -OutFile $download
    if ((Get-FileHash -LiteralPath $download -Algorithm SHA256).Hash -ne $converterSha256) {
        Remove-Item -LiteralPath $download -Force
        throw 'The 3dsconv download did not match its pinned checksum. Nothing was installed; try again later.'
    }
    Move-Item -LiteralPath $download -Destination $converter -Force
}

# --- 3. Python and pyaes -------------------------------------------------------------------
$python = Find-ThreeDSPython
if (-not $python) {
    throw 'Python 3 is not installed. Install it from https://www.python.org/downloads/ (the default options are fine), then set up the helper tools again.'
}
if (-not (Test-Path -LiteralPath (Join-Path $depsRoot 'pyaes') -PathType Container)) {
    Write-Host "Installing pyaes $pyaesVersion inside the app's tool folder..."
    & $python -m pip install --disable-pip-version-check --no-compile --target $depsRoot "pyaes==$pyaesVersion" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Python could not install pyaes. Check the internet connection, then set up the helper tools again. (Python: $python)" }
}

[pscustomobject]@{
    InstalledAt = (Get-Date).ToString('o')
    CtrToolVersion = $ctrVersion
    CtrToolPackageSHA256 = $ctrSha256
    ConverterCommit = $converterCommit
    ConverterSHA256 = $converterSha256
    PythonPath = $python
    PyaesVersion = $pyaesVersion
} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $toolRoot 'toolchain.json') -Encoding UTF8
Write-Host "Helper tools are ready under $toolRoot"
