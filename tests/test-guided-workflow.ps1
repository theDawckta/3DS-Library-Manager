$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if (-not $env:THREEDS_MANAGER_DATA_ROOT) {
    $env:THREEDS_MANAGER_DATA_ROOT = Join-Path $env:TEMP ('BackupsNew3DS.Isolated.' + [guid]::NewGuid().ToString('N'))
}
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\ThreeDSLibrary.Core.psm1') -Force -DisableNameChecking

function Assert-Equal($Expected,$Actual,[string]$Message){if($Expected -ne $Actual){throw "$Message Expected '$Expected'; got '$Actual'."}}
function Assert-Throws([scriptblock]$Action,[string]$Message){$threw=$false;try{& $Action}catch{$threw=$true};if(-not $threw){throw $Message}}
function New-Items([int]$Start,[int]$Count,[string]$Prefix,[uint64]$Length=2GB){
    @(0..($Count-1)|ForEach-Object{$n=$Start+$_;[pscustomobject]@{Title="$Prefix $n";TitleId=('00040000{0:X8}' -f $n);ArtifactLength=$Length}})
}

# There is no batch size: the next copy is the whole queue, in order.
$queue=New-Items 1 10 'Queued'
$all=New-ThreeDSGuidedBatchPlan -Items $queue
Assert-Equal 10 $all.RemainingCount 'Queue count mismatch.'
Assert-Equal 10 $all.NextCount 'The whole queue was not copied in one go.'
Assert-Equal 0 $all.LaterCount 'Games were held back with no space limit.'
Assert-Equal '10 games' $all.NextDescription 'Next-copy copy mismatch.'
for($i=0;$i -lt 10;$i++){Assert-Equal $queue[$i].TitleId $all.NextItems[$i].TitleId "Queue order was not kept at position $i."}
Assert-Equal ([uint64]20GB) $all.NextBytes 'Next-copy size mismatch.'

# Only free space holds games back, in queue order.
$tight=New-ThreeDSGuidedBatchPlan -Items $queue -AvailableBytes ([uint64]7GB)
Assert-Equal 3 $tight.NextCount 'The games that fit were not all taken.'
Assert-Equal 7 $tight.LaterCount 'The games that do not fit were not held for later.'
Assert-Equal $queue[2].TitleId $tight.NextItems[2].TitleId 'Space limiting broke queue order.'
Assert-Equal 1 (New-ThreeDSGuidedBatchPlan -Items $queue -AvailableBytes ([uint64]2GB)).NextCount 'An exact fit was refused.'
$full=New-ThreeDSGuidedBatchPlan -Items $queue -AvailableBytes ([uint64]1GB)
Assert-Equal 0 $full.NextCount 'A game larger than the free space was planned.'
Assert-Equal 'Not enough free space on the SD card' $full.NextDescription 'Full-card copy mismatch.'
Assert-Equal '1 game' (New-ThreeDSGuidedBatchPlan -Items (New-Items 1 1 'One')).NextDescription 'Singular copy mismatch.'

# Planning never mutates what it is given.
$before=@($queue|ForEach-Object{'{0}|{1}' -f $_.TitleId,$_.Title}) -join ';'
[void](New-ThreeDSGuidedBatchPlan -Items $queue -AvailableBytes ([uint64]5GB))
Assert-Equal $before (@($queue|ForEach-Object{'{0}|{1}' -f $_.TitleId,$_.Title}) -join ';') 'Planning mutated the queue.'

# Installed titles and duplicates never re-enter a copy.
$deduplicated=New-ThreeDSGuidedBatchPlan -Items @($queue+$queue[0..2]) -InstalledTitleIds @($queue[0].TitleId,$queue[1].TitleId.ToLowerInvariant())
Assert-Equal 8 $deduplicated.RemainingCount 'Installed or duplicate titles stayed in the queue.'
Assert-Equal $queue[2].TitleId $deduplicated.NextItems[0].TitleId 'The first uninstalled title did not lead the next copy.'

# Empty, null and invalid input.
$empty=New-ThreeDSGuidedBatchPlan
Assert-Equal 0 $empty.RemainingCount 'Empty plan is not empty.'
Assert-Equal 'No games remaining' $empty.NextDescription 'Empty plan copy mismatch.'
Assert-Equal 0 (New-ThreeDSGuidedBatchPlan -Items $null -InstalledTitleIds $null).RemainingCount 'Null input broke planning.'
Assert-Equal 2 (New-ThreeDSGuidedBatchPlan -Items @($null,$queue[0],$null,$queue[1])).RemainingCount 'Null entries broke planning.'
Assert-Equal 1 (New-ThreeDSGuidedBatchPlan -Items @([pscustomobject]@{Title='No size';TitleId='0004000000ABCD00'}) -AvailableBytes ([uint64]1MB)).NextCount 'An item without a recorded size broke planning.'
Assert-Throws { New-ThreeDSGuidedBatchPlan -Items @([pscustomobject]@{Title='Bad';TitleId='NOT-A-TITLE'}) } 'An invalid Title ID was queued.'

# Return summaries.
$ids=@($queue[0..4].TitleId)
Assert-Equal 'Batch returned: 0 of 5 installed' (Resolve-ThreeDSGuidedReturn -ActiveTitleIds $ids).Message 'Zero-install return summary mismatch.'
$partialReturn=Resolve-ThreeDSGuidedReturn -ActiveTitleIds $ids -InstalledTitleIds @($queue[0..2].TitleId)
Assert-Equal 'Batch returned: 3 of 5 installed' $partialReturn.Message 'Partial return summary mismatch.'
Assert-Equal 2 $partialReturn.RemainingCount 'Partial return miscounted what did not install.'
Assert-Equal 0 (Resolve-ThreeDSGuidedReturn -ActiveTitleIds $ids -InstalledTitleIds $ids).RemainingCount 'Complete return kept finished titles.'

# The interface copy the workflow depends on, and no batch-size setting.
$repo=Split-Path -Parent $PSScriptRoot
$ui=Get-Content -LiteralPath (Join-Path $repo 'scripts\library-manager.ps1') -Raw
$implementation=$ui+(Get-Content -LiteralPath (Join-Path $repo 'scripts\ThreeDSLibrary.Core.psm1') -Raw)
foreach($required in @('Apply changes','Add to SD card','Remove from 3DS','marked for removal','Kept what had finished','waiting to copy','copied automatically','Batch returned:','GodMode9 folder:','Safely Eject SD','Install game image')){
    if($implementation -notmatch [regex]::Escape($required)){throw "Guided workflow copy is missing: $required"}
}
foreach($gone in @('Prepare next batch','BatchSize','GamesPerBatch','Verify file','Retry failed','RetryFailed','Copy to SD card','PrepareNextBatch','ready to copy','PlanRemoval','PrepareSelected','Prepare removal instructions','Remove from 3DS...','Stop safely')){
    if($ui -match [regex]::Escape($gone)){throw "Removed workflow piece is back in the interface: $gone"}
}
Assert-Equal 1 ([regex]::Matches($ui,'Copy-ThreeDSInstallQueue ')).Count 'Only Copy-GuidedQueue may write games to the SD card.'

[pscustomobject]@{Status='PASS';WholeQueueInOneCopy='PASS';FreeSpaceOnlyLimit='PASS';QueueOrderKept='PASS';InstalledAndDuplicatesSkipped='PASS';EmptyAndNullInput='PASS';ReturnSummaries='PASS';NoBatchSizeSetting='PASS'}|Format-List
