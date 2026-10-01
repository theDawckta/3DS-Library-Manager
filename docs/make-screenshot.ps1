<#
    Regenerates docs/screenshot.png for the README from the app's real window, filled with demo
    data.  It reads no SD card, library or settings, and writes only the PNG.  The window is shown
    off-screen just long enough to lay out, so nothing appears on the desktop.

        powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\docs\make-screenshot.ps1
#>
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName PresentationFramework
$repo = Split-Path -Parent $PSScriptRoot
$manager = Join-Path $repo 'scripts\library-manager.ps1'
$text = Get-Content -LiteralPath $manager -Raw
$start = $text.IndexOf("@'") + 2
[xml]$xaml = $text.Substring($start, $text.IndexOf("'@", $start) - $start)
$window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
function C([string]$Name) { $window.FindName($Name) }

# The pie slices are drawn with the app's own geometry function.
$ast = [System.Management.Automation.Language.Parser]::ParseFile($manager, [ref]$null, [ref]$null)
$fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'New-PieSliceGeometry' }, $true)
. ([scriptblock]::Create($fn.Extent.Text))

# --- Demo data ---------------------------------------------------------------------------
function Row([string]$Title, [string]$Playable, [bool]$Add = $false, [bool]$Remove = $false, [string]$Status = '', [string]$Why = '') {
    $failed = $Status -like 'FAILED*'
    [pscustomobject]@{
        IsChosen=$Add; IsRemoveChosen=$Remove; CanSelect=($Playable -eq 'No'); CanRemove=($Playable -eq 'Yes')
        DisplayTitle=$Title; Type='Base'; DisplayState=$Playable
        PreparationStatus=$Status; PreparationError=$Why; PreparationForeground=$(if ($failed) { '#B42318' } else { '#44515E' })
    }
}
(C 'GameGrid').ItemsSource = @(
    (Row 'Animal Crossing - New Leaf' 'Yes')
    (Row 'Bravely Default' 'No' -Add $true)
    (Row 'Fire Emblem Awakening' 'Yes')
    (Row 'Kid Icarus - Uprising' 'Yes' -Remove $true)
    (Row 'Kirby - Planet Robobot' 'Yes')
    (Row 'Legend of Zelda, The - A Link Between Worlds' 'Yes')
    (Row 'Luigi''s Mansion - Dark Moon' 'No' -Add $true)
    (Row 'Mario Kart 7' 'Yes')
    (Row 'Metroid - Samus Returns' 'Yes')
    (Row 'Monster Hunter Generations' 'No' -Status 'FAILED - hover for why' -Why 'The source file is damaged.')
    (Row 'Pokemon Ultra Moon' 'Yes')
    (Row 'Professor Layton and the Azran Legacy' 'No')
    (Row 'Shovel Knight' 'Yes')
    (Row 'Super Mario 3D Land' 'Yes')
    (Row 'Xenoblade Chronicles 3D' 'No')
)
(C 'SelectionSummary').Text = '2 games to add - about 2.3 GiB; 1 game to remove'
(C 'ApplyChanges').Content = 'Add 2, remove 1'; (C 'ApplyChanges').IsEnabled = $true
(C 'HeaderSdStatus').Text = 'SD detected: N3DS E:'
(C 'SdTargets').ItemsSource = @([pscustomobject]@{ FriendlyDisplay='N3DS (119.2 GiB)' }); (C 'SdTargets').SelectedIndex = 0
(C 'SdFriendlyStatus').Text = 'Ready: N3DS on E:, 59.0 GiB free. Physical identity is rechecked before eject and every copy.'
(C 'EjectStateText').Text = 'Connected - ready to eject'; (C 'EjectSd').IsEnabled = $true
(C 'NextStepTitle').Text = 'Next step'
(C 'NextStepText').Text = "Batch returned: 4 of 4 installed.`n`nChoose games to add or remove."
$total = 119.2; $parts = @(@('Games', 54.1), @('Other', 6.1), @('Free', 59.0)); $angle = 0.0
foreach ($part in $parts) {
    $fraction = $part[1] / $total
    (C "Space$($part[0])Slice").Data = New-PieSliceGeometry $angle $fraction 58
    (C "Space$($part[0])Text").Text = '{0} - {1:N1} GB ({2}%)' -f $part[0], $part[1], [Math]::Round($fraction * 100)
    $angle += $fraction
}
(C 'SpaceSummary').Text = '59.0 GB free of 119.2 GB'; (C 'SpaceCard').Visibility = 'Visible'
(C 'FooterStatus').Text = 'Ready'

# --- Lay out off-screen and capture the window's content --------------------------------
$window.WindowStartupLocation = 'Manual'; $window.Left = -32000; $window.Top = -32000
$window.Width = 1360; $window.Height = 860; $window.ShowInTaskbar = $false; $window.ShowActivated = $false
$window.Show()
$window.Dispatcher.Invoke([action]{}, [Windows.Threading.DispatcherPriority]::ApplicationIdle)
$content = $window.Content
$scale = 1.5
$bitmap = [Windows.Media.Imaging.RenderTargetBitmap]::new([int]($content.ActualWidth * $scale), [int]($content.ActualHeight * $scale), 96 * $scale, 96 * $scale, [Windows.Media.PixelFormats]::Pbgra32)
$bitmap.Render($content)
$window.Close()
$encoder = [Windows.Media.Imaging.PngBitmapEncoder]::new(); $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
$out = Join-Path $PSScriptRoot 'screenshot.png'
$stream = [IO.File]::Create($out); try { $encoder.Save($stream) } finally { $stream.Dispose() }
"Saved $out ($([int]($content.ActualWidth * $scale)) x $([int]($content.ActualHeight * $scale)))"
