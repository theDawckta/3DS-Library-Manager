[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'ThreeDSLibrary.Core.psm1') -Force -DisableNameChecking
$dataRoot = Get-ThreeDSManagerDataRoot
$toolRoot = Join-Path $dataRoot 'tools'
$ctrRoot = Join-Path $toolRoot 'ctrtool'
$convRoot = Join-Path $toolRoot '3dsconv'
$depsRoot = Join-Path $toolRoot 'pydeps'
$downloadRoot = Join-Path $dataRoot 'downloads'
$ctrZip = Join-Path $downloadRoot 'ctrtool-v1.3.0-win_x64.zip'
$ctrUrl = 'https://github.com/3DSGuy/Project_CTR/releases/download/ctrtool-v1.3.0/ctrtool-v1.3.0-win_x64.zip'
$ctrSha256 = '8031DFF3BE72D0ADB250FAE1F969F27627E12A89EBC6DD074A15A75F87DDC949'
$converterCommit = '50a30d292e039a8b315eaccef85a067a8f48c500'

New-Item -ItemType Directory -Path $toolRoot,$downloadRoot -Force | Out-Null

Write-Host 'Downloading the pinned CTRTool v1.3.0 package...' -ForegroundColor Cyan
Invoke-WebRequest -Uri $ctrUrl -OutFile $ctrZip
$actual = (Get-FileHash -LiteralPath $ctrZip -Algorithm SHA256).Hash.ToUpperInvariant()
if ($actual -ne $ctrSha256) { throw 'CTRTool publisher digest mismatch.' }
if (Test-Path -LiteralPath $ctrRoot) { throw "Refusing to overwrite existing tool directory: $ctrRoot" }
Expand-Archive -LiteralPath $ctrZip -DestinationPath $ctrRoot

if (Test-Path -LiteralPath $convRoot) { throw "Refusing to overwrite existing tool directory: $convRoot" }
Write-Host 'Cloning the pinned upstream 3dsconv revision...' -ForegroundColor Cyan
& git clone --quiet --no-checkout https://github.com/ihaveamac/3dsconv.git $convRoot
if ($LASTEXITCODE -ne 0) { throw 'Unable to clone 3dsconv.' }
& git -C $convRoot checkout --quiet $converterCommit
if ($LASTEXITCODE -ne 0) { throw 'Unable to check out the pinned 3dsconv commit.' }

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
if (-not $python) { throw 'Python 3 was not found.' }

Write-Host 'Installing pyaes only inside the manager tool directory...' -ForegroundColor Cyan
& $python -m pip install --disable-pip-version-check --no-compile --target $depsRoot 'pyaes==1.6.1'
if ($LASTEXITCODE -ne 0) { throw 'Unable to install the local pyaes dependency.' }

$record = [pscustomobject]@{
    InstalledAt = (Get-Date).ToString('o')
    CtrToolVersion = '1.3.0'
    CtrToolPackageSHA256 = $ctrSha256
    ConverterCommit = $converterCommit
    PythonPath = $python
    PyaesVersion = '1.6.1'
}
$record | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $toolRoot 'toolchain.json') -Encoding UTF8
Write-Host "Library-manager tools are ready under $toolRoot" -ForegroundColor Green
