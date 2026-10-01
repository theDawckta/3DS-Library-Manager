[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$CtrToolPath,
    [Parameter(Mandatory)] [string]$Test3dsPath,
    [Parameter(Mandatory)] [string]$TestCiaPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $env:THREEDS_MANAGER_DATA_ROOT) {
    $env:THREEDS_MANAGER_DATA_ROOT = Join-Path $env:TEMP 'BackupsNew3DS.Tests'
}
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\ThreeDSLibrary.Core.psm1') -Force -DisableNameChecking

function Assert-Equal($Expected, $Actual, [string]$Message) {
    if ($Expected -ne $Actual) { throw "$Message Expected '$Expected'; got '$Actual'." }
}

$sourceBefore = (Get-FileHash -LiteralPath $Test3dsPath -Algorithm SHA256).Hash
$ciaBefore = (Get-FileHash -LiteralPath $TestCiaPath -Algorithm SHA256).Hash

$metadata = Get-ThreeDSImageMetadata -Path $Test3dsPath -CtrToolPath $CtrToolPath
Assert-Equal '00040000000D6B00' $metadata.TitleId '3DS Title ID mismatch.'
Assert-Equal 'CTR-P-AZEE' $metadata.ProductCode '3DS Product Code mismatch.'
Assert-Equal 'USA' $metadata.Region '3DS product-region mismatch.'
Assert-Equal 131072 $metadata.SaveSizeBytes '3DS save size mismatch.'
Assert-Equal 'DecryptedHeaderMismatch' $metadata.EncryptionState '3DS crypto-state mismatch.'

$validation = Test-ThreeDSCia -Path $TestCiaPath -CtrToolPath $CtrToolPath `
    -ExpectedTitleId '00040000000D6B00' -ExpectedProductCode 'CTR-P-AZEE' `
    -ExpectedSaveSizeBytes 131072 -ExpectedRegion 'USA'
if (-not $validation.IsValid) {
    $validation | Format-List * | Out-String | Write-Host
    throw ('CIA validation failed: ' + ($validation.Errors -join '; '))
}
Assert-Equal 'USA' $validation.Region 'CIA region mismatch.'
Assert-Equal 'NoCrypto' $validation.EncryptionState 'CIA crypto-state mismatch.'
Assert-Equal 2 $validation.GoodContentHashCount 'CIA TMD content-hash count mismatch.'
Assert-Equal 2 @($validation.ContentManifest).Count 'CIA extracted content-manifest count mismatch.'

$ciaItem = Get-Item -LiteralPath $TestCiaPath
$cachedCia = [pscustomobject]@{
    Selected=$true; Title=$validation.Title; TitleId=$validation.TitleId; Type='Base'; Format='CIA'
    ProductCode=$validation.ProductCode; Region='USA'; EncryptionState='NoCrypto'
    SaveSizeBytes=[uint64]$validation.SaveSizeBytes; SourcePath=$ciaItem.FullName
    SourceLength=[uint64]$ciaItem.Length; SourceLastWriteTimeUtc=$ciaItem.LastWriteTimeUtc.ToString('o')
    SourceSHA256=$validation.SHA256; Status='Identified'; PreparedPath=''; PreparedSHA256=''
}
# ConvertFrom-Json on Windows PowerShell can return a nested array. Smart refresh must normalize it.
$smartInventory = @(Get-ThreeDSLibraryInventory -LibraryRoot $ciaItem.DirectoryName -CtrToolPath $CtrToolPath `
    -CachedItems (, @($cachedCia)))
Assert-Equal 1 $smartInventory.Count 'Smart inventory item count mismatch.'
Assert-Equal 'Reused' $smartInventory[0].CacheState 'Unchanged CIA was unnecessarily rescanned.'
Assert-Equal $validation.SHA256 $smartInventory[0].SourceSHA256 'Smart inventory changed the cached source hash.'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$repoPathWasBlocked = $false
try { Assert-ThreeDSExternalDataPath -Path (Join-Path $repositoryRoot 'roms') -RepositoryRoot $repositoryRoot | Out-Null }
catch { $repoPathWasBlocked = $true }
Assert-Equal $true $repoPathWasBlocked 'Repository data-boundary check failed.'
Assert-Equal ([IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')) `
    (Assert-ThreeDSExternalDataPath -Path $env:TEMP -RepositoryRoot $repositoryRoot) `
    'External data path was unexpectedly changed.'

$library = @(
    [pscustomobject]@{Selected=$true;Title='Wanted';TitleId='0004000000000001';Type='Base';SourcePath='A';SourceSHA256='1';PreparedPath='';PreparedSHA256=''},
    [pscustomobject]@{Selected=$false;Title='Remove';TitleId='0004000000000002';Type='Base';SourcePath='B';SourceSHA256='2';PreparedPath='';PreparedSHA256=''},
    [pscustomobject]@{Selected=$true;Title='Staged update';TitleId='0004000E00000004';Type='Update';SourcePath='C';SourceSHA256='3';PreparedPath='';PreparedSHA256=''}
)
$installed = @(
    [pscustomobject]@{TitleId='0004000000000002';Type='Base';State='Installed + healthy';InstalledFileCount=1;InstalledBytes=1;HasSave=$false},
    [pscustomobject]@{TitleId='0004000000000003';Type='Base';State='Installed + uncertain';InstalledFileCount=1;InstalledBytes=1;HasSave=$false}
)
$batches = @([pscustomobject]@{
    BatchId='20260901-120000'; Integrity='Verified'; State='Staged on SD'; CleanupEligible=$false; ItemCount=1
    ManifestSHA256='TEST'; Issues=@()
    Items=@([pscustomobject]@{TitleId='0004000E00000004';Type='Update'})
})
$plan = @(New-ThreeDSSyncPlan -LibraryItems $library -InstalledTitles $installed -InstallBatches $batches)
Assert-Equal 4 $plan.Count 'Sync-plan item count mismatch.'
Assert-Equal 'Prepare + stage' ($plan | Where-Object TitleId -eq '0004000000000001').Action 'Missing-title action mismatch.'
Assert-Equal 'Review removal' ($plan | Where-Object TitleId -eq '0004000000000002').Action 'Deselected-title action mismatch.'
Assert-Equal 'Report only' ($plan | Where-Object TitleId -eq '0004000000000003').Action 'Extra-title action mismatch.'
Assert-Equal 'Await console install' ($plan | Where-Object TitleId -eq '0004000E00000004').Action 'Staged-title action mismatch.'

$healthyInstalled = @([pscustomobject]@{TitleId='0004000E00000004';State='Installed + healthy'})
$resolved = @(Resolve-ThreeDSInstallBatches -Batches $batches -InstalledTitles $healthyInstalled)
Assert-Equal 'Complete' $resolved[0].State 'Healthy-batch reconciliation mismatch.'
Assert-Equal 1 $resolved[0].InstalledCount 'Healthy batch did not count its installed title.'
Assert-Equal 'Installed' $resolved[0].Items[0].InstallState 'Healthy batch item was not marked installed.'
Assert-Equal 0 $resolved[0].RemainingCount 'Healthy batch retained a remaining title.'
$emptyLibraryPlan = @(New-ThreeDSSyncPlan -LibraryItems @() -InstalledTitles $installed -InstallBatches @())
Assert-Equal 2 $emptyLibraryPlan.Count 'Empty-library refresh did not preserve installed reporting.'
Assert-Equal 'Report only' $emptyLibraryPlan[0].Action 'Empty-library refresh produced a state-changing action.'

Assert-Equal $sourceBefore (Get-FileHash -LiteralPath $Test3dsPath -Algorithm SHA256).Hash 'Source file changed during tests.'
Assert-Equal $ciaBefore (Get-FileHash -LiteralPath $TestCiaPath -Algorithm SHA256).Hash 'CIA file changed during tests.'

[pscustomobject]@{
    Status='PASS'
    SourceTitleId=$metadata.TitleId
    SourceEncryptionState=$metadata.EncryptionState
    CiaSHA256=$validation.SHA256
    CiaRegion=$validation.Region
    CiaSaveSizeBytes=$validation.SaveSizeBytes
    SyncPlanItems=$plan.Count
} | Format-List
