[CmdletBinding()]
param([switch]$ValidateOnly)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    $arguments = @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',('"{0}"' -f $PSCommandPath))
    if ($ValidateOnly) { $arguments += '-ValidateOnly' }
    Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments
    exit
}

Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Windows.Forms
Import-Module (Join-Path $PSScriptRoot 'ThreeDSLibrary.Core.psm1') -Force -DisableNameChecking

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="3DS Game Installer" Height="790" Width="1180" MinHeight="690" MinWidth="980"
        WindowStartupLocation="CenterScreen" Background="#F4F6F8" FontFamily="Segoe UI">
  <Window.Resources>
    <Style TargetType="Button"><Setter Property="Padding" Value="18,9"/><Setter Property="Margin" Value="0,0,8,0"/><Setter Property="MinHeight" Value="38"/><Setter Property="FontSize" Value="14"/></Style>
    <Style x:Key="PrimaryButton" TargetType="Button"><Setter Property="Background" Value="#176B3A"/><Setter Property="Foreground" Value="White"/><Setter Property="BorderBrush" Value="#176B3A"/><Setter Property="FontWeight" Value="SemiBold"/><Setter Property="Padding" Value="22,11"/><Setter Property="MinHeight" Value="42"/></Style>
    <Style x:Key="Card" TargetType="Border"><Setter Property="Background" Value="White"/><Setter Property="BorderBrush" Value="#D8DEE6"/><Setter Property="BorderThickness" Value="1"/><Setter Property="CornerRadius" Value="8"/><Setter Property="Padding" Value="16"/></Style>
    <Style TargetType="TextBox"><Setter Property="Padding" Value="8,5"/></Style>
  </Window.Resources>
  <Grid>
    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
    <Border Grid.Row="0" Background="#172336" Padding="22,17">
      <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <StackPanel><TextBlock Text="3DS Game Installer" Foreground="White" FontSize="25" FontWeight="SemiBold"/><TextBlock Text="Choose games, copy them to the SD card, then install them in GodMode9." Foreground="#C8D4E4" FontSize="14" Margin="0,4,0,0"/></StackPanel>
        <TextBlock x:Name="HeaderSdStatus" Grid.Column="1" Text="SD card not checked" Foreground="#C8D4E4" HorizontalAlignment="Right" VerticalAlignment="Center"/>
      </Grid>
    </Border>
    <Border x:Name="ProgressCard" Grid.Row="1" Margin="18,14,18,0" Style="{StaticResource Card}" Background="#EEF6FF" BorderBrush="#9BC4EE" Visibility="Collapsed">
      <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="180"/></Grid.ColumnDefinitions>
        <StackPanel><TextBlock x:Name="ProgressTitle" Text="Ready" FontWeight="SemiBold" FontSize="15" Foreground="#153A5B"/><TextBlock x:Name="ProgressDetail" Text="Connect the SD card and refresh your games." Margin="0,4,12,0" Foreground="#3D5D78" TextTrimming="CharacterEllipsis"/><ProgressBar x:Name="OperationProgress" Height="9" Margin="0,10,12,0" Minimum="0" Maximum="100" Value="0"/></StackPanel>
        <StackPanel Grid.Column="1" VerticalAlignment="Center" HorizontalAlignment="Right"><TextBlock x:Name="ElapsedText" HorizontalAlignment="Right" Foreground="#3D5D78"/><Button x:Name="CancelOperation" Content="Cancel" Margin="0,8,0,0" Padding="14,5" MinHeight="30" Visibility="Collapsed"/></StackPanel>
      </Grid>
    </Border>
    <Grid Grid.Row="2" Margin="18,14,18,10">
      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="380"/></Grid.ColumnDefinitions>
      <Border Grid.Column="0" Style="{StaticResource Card}" Margin="0,0,14,0">
        <Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
          <Grid Grid.Row="0"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><StackPanel><TextBlock Text="Your games" FontSize="20" FontWeight="SemiBold" Foreground="#172336"/><TextBlock Text="Check only the games you want to add. Installed games are left alone." Foreground="#5F6B78" Margin="0,4,0,0"/></StackPanel><Button x:Name="RefreshAll" Grid.Column="1" Content="Check for changes"/></Grid>
          <TextBox x:Name="SearchBox" Grid.Row="1" Margin="0,14,0,10" ToolTip="Filter by game name"/>
          <DataGrid x:Name="GameGrid" Grid.Row="2" AutoGenerateColumns="False" CanUserAddRows="False" IsReadOnly="False" HeadersVisibility="Column" GridLinesVisibility="Horizontal" BorderThickness="0" RowHeaderWidth="0" AlternatingRowBackground="#F8FAFC" SelectionMode="Single">
            <DataGrid.Columns>
              <DataGridTemplateColumn Header="Add" Width="58"><DataGridTemplateColumn.CellTemplate><DataTemplate><CheckBox IsChecked="{Binding IsChosen,Mode=TwoWay,UpdateSourceTrigger=PropertyChanged}" IsEnabled="{Binding CanSelect}" HorizontalAlignment="Center" VerticalAlignment="Center"/></DataTemplate></DataGridTemplateColumn.CellTemplate></DataGridTemplateColumn>
              <DataGridTemplateColumn Header="Remove" Width="70"><DataGridTemplateColumn.CellTemplate><DataTemplate><CheckBox IsChecked="{Binding IsRemoveChosen,Mode=TwoWay,UpdateSourceTrigger=PropertyChanged}" IsEnabled="{Binding CanRemove}" HorizontalAlignment="Center" VerticalAlignment="Center"/></DataTemplate></DataGridTemplateColumn.CellTemplate></DataGridTemplateColumn>
              <DataGridTextColumn Header="Game" Binding="{Binding DisplayTitle}" Width="3*" IsReadOnly="True"/><DataGridTextColumn Header="Type" Binding="{Binding Type}" Width="85" IsReadOnly="True"/><DataGridTextColumn Header="Playable now?" Binding="{Binding DisplayState}" Width="110" IsReadOnly="True"/>
              <DataGridTemplateColumn Header="Preparation" Width="220"><DataGridTemplateColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding PreparationStatus}" Foreground="{Binding PreparationForeground}" ToolTip="{Binding PreparationError}" TextTrimming="CharacterEllipsis" VerticalAlignment="Center"/></DataTemplate></DataGridTemplateColumn.CellTemplate></DataGridTemplateColumn>
            </DataGrid.Columns>
          </DataGrid>
          <Grid Grid.Row="3" Margin="0,14,0,0"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><TextBlock x:Name="SelectionSummary" Text="Refresh to see your library." VerticalAlignment="Center" Foreground="#44515E"/><StackPanel Grid.Column="1" Orientation="Horizontal"><Button x:Name="ApplyChanges" Content="Apply changes" Style="{StaticResource PrimaryButton}" IsEnabled="False"/></StackPanel></Grid>
        </Grid>
      </Border>
      <ScrollViewer Grid.Column="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" HorizontalContentAlignment="Left"><StackPanel Width="350" Margin="0,0,4,0">
        <Border Style="{StaticResource Card}" Margin="0,0,0,12"><StackPanel><TextBlock Text="SD card" FontSize="17" FontWeight="SemiBold" Foreground="#172336"/><TextBlock x:Name="SdFriendlyStatus" Text="Connect the 3DS SD card, then refresh." TextWrapping="Wrap" Margin="0,7,0,10" Foreground="#5F6B78"/><ComboBox x:Name="SdTargets" DisplayMemberPath="FriendlyDisplay" MinHeight="32"/><Button x:Name="RefreshSd" Content="Check SD card" Margin="0,10,0,0"/><TextBlock x:Name="EjectStateText" Text="SD card unavailable" FontWeight="SemiBold" Foreground="#5F6B78" Margin="0,12,0,5"/><Button x:Name="EjectSd" Content="Safely Eject SD" Style="{StaticResource PrimaryButton}" Margin="0" IsEnabled="False"/></StackPanel></Border>
        <Border x:Name="NextStepCard" Style="{StaticResource Card}" Margin="0,0,0,12" Background="#F0F8F3" BorderBrush="#9BC8AA"><StackPanel><TextBlock x:Name="NextStepTitle" Text="Next step" FontSize="17" FontWeight="SemiBold" Foreground="#174A2B"/><TextBlock x:Name="NextStepText" Text="Refresh your games to begin." TextWrapping="Wrap" Margin="0,7,0,10" Foreground="#365D43"/></StackPanel></Border>
        <Border x:Name="SpaceCard" Style="{StaticResource Card}" Margin="0,0,0,12" Visibility="Collapsed"><StackPanel><TextBlock Text="SD card space" FontSize="17" FontWeight="SemiBold" Foreground="#172336"/><TextBlock x:Name="SpaceSummary" TextWrapping="Wrap" Margin="0,4,0,12" Foreground="#5F6B78"/><Grid><Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions><Canvas Width="116" Height="116" VerticalAlignment="Center"><Path x:Name="SpaceFreeSlice" Fill="#D5DCE4" Stroke="White" StrokeThickness="1.5"/><Path x:Name="SpaceOtherSlice" Fill="#E0A13A" Stroke="White" StrokeThickness="1.5"/><Path x:Name="SpaceGamesSlice" Fill="#2F7BC0" Stroke="White" StrokeThickness="1.5"/></Canvas><StackPanel Grid.Column="1" Margin="18,0,0,0" VerticalAlignment="Center"><DockPanel Margin="0,0,0,9"><Rectangle Width="12" Height="12" RadiusX="2" RadiusY="2" Fill="#2F7BC0" Margin="0,0,8,0" VerticalAlignment="Center"/><TextBlock x:Name="SpaceGamesText" Foreground="#172336" TextWrapping="Wrap"/></DockPanel><DockPanel Margin="0,0,0,9"><Rectangle Width="12" Height="12" RadiusX="2" RadiusY="2" Fill="#E0A13A" Margin="0,0,8,0" VerticalAlignment="Center"/><TextBlock x:Name="SpaceOtherText" Foreground="#172336" TextWrapping="Wrap"/></DockPanel><DockPanel><Rectangle Width="12" Height="12" RadiusX="2" RadiusY="2" Fill="#D5DCE4" Margin="0,0,8,0" VerticalAlignment="Center"/><TextBlock x:Name="SpaceFreeText" Foreground="#172336" TextWrapping="Wrap"/></DockPanel></StackPanel></Grid></StackPanel></Border>
        <Expander Header="Settings" Margin="2,2,2,8"><StackPanel Margin="8,10,4,4"><TextBlock Text="Where your game files are" FontWeight="SemiBold"/><DockPanel Margin="0,4,0,9"><Button x:Name="BrowseLibrary" DockPanel.Dock="Right" Content="Change"/><TextBox x:Name="LibraryPath" ToolTip="{Binding RelativeSource={RelativeSource Self},Path=Text}"/></DockPanel><TextBlock Text="Working storage for prepared games" FontWeight="SemiBold"/><TextBlock Text="The app manages this folder automatically." Foreground="#5F6B78" FontSize="12"/><DockPanel Margin="0,4,0,9"><Button x:Name="BrowseCache" DockPanel.Dock="Right" Content="Change"/><TextBox x:Name="CachePath" ToolTip="{Binding RelativeSource={RelativeSource Self},Path=Text}"/></DockPanel><StackPanel x:Name="Boot9Panel" Visibility="Collapsed" Margin="0,2,0,8"><TextBlock Text="Encrypted cartridge support" FontWeight="SemiBold"/><TextBlock Text="Only needed when the app finds an encrypted physical-cartridge dump. Leave blank unless the app specifically asks for it." TextWrapping="Wrap" Foreground="#5F6B78" FontSize="12" Margin="0,2,0,4"/><DockPanel><Button x:Name="BrowseBoot9" DockPanel.Dock="Right" Content="Choose file"/><TextBox x:Name="Boot9Path" ToolTip="{Binding RelativeSource={RelativeSource Self},Path=Text}"/></DockPanel></StackPanel><Button x:Name="SetupTools" Content="Set up helper tools" Margin="0,2,0,0"/><Expander Header="Troubleshooting details" Margin="0,9,0,0"><TextBox x:Name="Log" Height="120" IsReadOnly="True" AcceptsReturn="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" FontFamily="Consolas" FontSize="11" Margin="0,7,0,0"/></Expander></StackPanel></Expander>
      </StackPanel></ScrollViewer>
    </Grid>
    <Border Grid.Row="3" Background="#E8ECF1" Padding="18,8"><TextBlock x:Name="FooterStatus" Text="Ready" Foreground="#44515E"/></Border>
  </Grid>
</Window>
'@

$reader=New-Object System.Xml.XmlNodeReader $xaml
$window=[Windows.Markup.XamlReader]::Load($reader)
$controlNames=@('HeaderSdStatus','ProgressCard','ProgressTitle','ProgressDetail','OperationProgress','ElapsedText','CancelOperation','RefreshAll','SearchBox','GameGrid','SelectionSummary','ApplyChanges','SdFriendlyStatus','SdTargets','RefreshSd','EjectStateText','EjectSd','NextStepCard','NextStepTitle','NextStepText','SpaceCard','SpaceSummary','SpaceGamesSlice','SpaceOtherSlice','SpaceFreeSlice','SpaceGamesText','SpaceOtherText','SpaceFreeText','BrowseLibrary','LibraryPath','BrowseCache','CachePath','Boot9Panel','BrowseBoot9','Boot9Path','SetupTools','Log','FooterStatus')
foreach($name in $controlNames){Set-Variable -Name $name -Value $window.FindName($name) -Scope Script}
if($ValidateOnly){"GUI XAML validation PASS ($($controlNames.Count) controls)";exit}

$script:InstanceMutex = New-Object Threading.Mutex($false, 'Local\BackupsNew3DS.LibraryManager')
$script:OwnsInstanceMutex = $false
try {
    $script:OwnsInstanceMutex = $script:InstanceMutex.WaitOne(0, $false)
}
catch [System.Threading.AbandonedMutexException] {
    $script:OwnsInstanceMutex = $true
}
if (-not $script:OwnsInstanceMutex) {
    [Windows.MessageBox]::Show('3DS Game Installer is already open.', '3DS Game Installer', 'OK', 'Information') | Out-Null
    $script:InstanceMutex.Dispose()
    exit
}

$script:RepositoryRoot=Split-Path -Parent $PSScriptRoot
$script:LibraryItems=@();$script:LibraryCache=@();$script:InstalledItems=@();$script:BatchItems=@();$script:ViewItems=@();$script:SdItems=@();$script:PreparationFailures=@();$script:PendingRemoval=$null;$script:LastRemovalConfirmed='';$script:GuidedInstall=[pscustomobject]@{Backlog=@();ActiveBatchId='';ActiveTitleIds=@();ActiveCount=0;AwaitingReturn=$false;LastReturnMessage=''};$script:Busy=$false;$script:CancelRequested=$false;$script:OperationStarted=$null;$script:LastDriveSignature='';$script:EjectedDeviceInstanceId='';$script:EjectRemovalObserved=$false;$script:Ejecting=$false;$script:SdEnumerationError='';$script:NextStepOwnedByEject=$false;$script:InlineNotice='';$script:SdLifecycle=(Resolve-ThreeDSSdLifecycle -CurrentTargets @() -SelectedTarget $null)
$script:Timer=New-Object Windows.Threading.DispatcherTimer;$script:Timer.Interval=[TimeSpan]::FromSeconds(1)
$script:Timer.Add_Tick({if($script:Busy -and $script:OperationStarted){$elapsed=(Get-Date)-$script:OperationStarted;$script:ElapsedText.Text='Working - {0:mm\:ss}' -f $elapsed}});$script:Timer.Start()
$script:DeviceTimer=New-Object Windows.Threading.DispatcherTimer;$script:DeviceTimer.Interval=[TimeSpan]::FromSeconds(3)
$script:DeviceTimer.Add_Tick({if($script:Busy){return};$signature=Get-RemovableSignature;if($signature -eq $script:LastDriveSignature){return};$script:LastDriveSignature=$signature;try{Refresh-SdTargets;$tools=Get-ThreeDSToolchain;if($script:SdTargets.SelectedItem -and $tools.Ready -and $script:LibraryPath.Text -and $script:CachePath.Text){Invoke-RefreshAll}}catch{Show-Error $_}})

function Show-Notice([string]$Summary,[string]$Detail=''){
    # Normal results are reported in the window, never behind a modal popup.
    $script:InlineNotice=if($Detail){"$Summary`n$Detail"}else{$Summary}
    $script:FooterStatus.Text=$Summary
    Add-Log $(if($Detail){"$Summary - $Detail"}else{$Summary})
    Update-NextStep
    Pump-Ui
}
function Add-Log([string]$Message){$script:Log.AppendText("[$(Get-Date -Format 'HH:mm:ss')] $Message`r`n");$script:Log.ScrollToEnd()}
function Pump-Ui{$window.Dispatcher.Invoke([action]{},[Windows.Threading.DispatcherPriority]::Background)}
function Set-Progress([string]$Title,[string]$Detail,[uint64]$Done=0,[uint64]$Total=0){$script:ProgressTitle.Text=$Title;$script:ProgressDetail.Text=$Detail;if($Total -gt 0){$script:OperationProgress.IsIndeterminate=$false;$script:OperationProgress.Value=[Math]::Min(100,[double]$Done/[double]$Total*100);$script:FooterStatus.Text='{0} - {1:N0}%' -f $Title,$script:OperationProgress.Value}else{$script:OperationProgress.IsIndeterminate=$true;$script:FooterStatus.Text=$Title};Pump-Ui;if($script:Busy -and $script:CancelRequested){throw [System.OperationCanceledException]::new('The operation was stopped by the user.') }}
function Set-Busy([bool]$Busy,[string]$Title='Ready'){$script:Busy=$Busy;if($Busy){$script:InlineNotice='';$script:ProgressCard.Visibility='Visible';$script:CancelRequested=$false;$script:CancelOperation.Visibility='Visible';$script:CancelOperation.IsEnabled=$true;$script:OperationStarted=Get-Date;$script:ElapsedText.Text='Working - 00:00'}else{$script:CancelRequested=$false;$script:CancelOperation.Visibility='Collapsed';$script:OperationStarted=$null;$script:ElapsedText.Text='';$script:OperationProgress.IsIndeterminate=$false;$script:OperationProgress.Value=0;$script:ProgressCard.Visibility='Collapsed'};foreach($control in @($script:RefreshAll,$script:ApplyChanges,$script:RefreshSd,$script:EjectSd,$script:BrowseLibrary,$script:BrowseCache,$script:BrowseBoot9,$script:SetupTools,$script:GameGrid,$script:SearchBox,$script:SdTargets,$script:LibraryPath,$script:CachePath,$script:Boot9Path)){$control.IsEnabled=-not $Busy};Apply-SdLifecycle|Out-Null;Update-SelectionSummary;$script:FooterStatus.Text=$Title;Pump-Ui}
function Show-Error {
    param($ErrorValue,[string]$Game='',[string]$Operation='')
    $exception=if($ErrorValue -is [Management.Automation.ErrorRecord]){$ErrorValue.Exception}elseif($ErrorValue -is [Exception]){$ErrorValue}else{$null}
    $message=if($exception){$exception.Message}else{[string]$ErrorValue}
    $cancelled=Test-ThreeDSCancellation -ErrorValue $ErrorValue
    $script:CancelRequested=$false
    if($cancelled){
        try{Build-ViewItems}catch{Add-Log "Could not refresh the game list after stopping: $($_.Exception.Message)"}
        Show-Notice 'Stopped' 'Finished work was kept; the step in progress was cancelled and its partial files removed.'
        return
    }
    Add-Log "ERROR: $message"
    if($ErrorValue -is [Management.Automation.ErrorRecord] -and $ErrorValue.ScriptStackTrace){Add-Log $ErrorValue.ScriptStackTrace}
    $presentation=Get-ThreeDSManagerErrorDisplay -ErrorValue $ErrorValue -Game $Game -Operation $Operation
    if($presentation.IsInternal){
        Set-Progress "Internal manager error - $Game" $Operation 0 100
        [Windows.MessageBox]::Show($window,$presentation.Body,$presentation.Title,'OK','Error')|Out-Null
        return
    }
    Set-Progress 'Stopped safely' $message 0 100
    [Windows.MessageBox]::Show($window,$message,'3DS Game Installer','OK','Error')|Out-Null
}
function Select-Folder([string]$InitialPath){$dialog=New-Object Windows.Forms.FolderBrowserDialog;$dialog.Description='Select a folder';if($InitialPath -and(Test-Path -LiteralPath $InitialPath)){$dialog.SelectedPath=$InitialPath};if($dialog.ShowDialog() -eq [Windows.Forms.DialogResult]::OK){$dialog.SelectedPath}}
function Save-Preferences {
    if (-not $script:LibraryPath.Text -and -not $script:CachePath.Text) { return }
    Save-ThreeDSManagerState -Name 'preferences.json' -Value ([pscustomobject]@{
        SavedAt=(Get-Date).ToString('o'); LibraryRoot=$script:LibraryPath.Text
        InstallReadyRoot=$script:CachePath.Text; Boot9Path=$script:Boot9Path.Text
    }) | Out-Null
}
function Save-GuidedInstallState { Save-ThreeDSManagerState -Name 'guided-install.json' -Value $script:GuidedInstall | Out-Null }
function Add-GuidedBacklog([object[]]$Artifacts) {
    $byId=@{}
    foreach($item in @($script:GuidedInstall.Backlog)+@($Artifacts)){if($item.TitleId){$byId[([string]$item.TitleId).ToUpperInvariant()]=$item}}
    $script:GuidedInstall.Backlog=@($byId.Values);Save-GuidedInstallState
}
function Get-GuidedInstallPlan([AllowNull()]$FreeBytes=$null) {
    # Everything queued goes in one copy; only the card's free space, less the
    # staging reserve, can hold some of it back for the next copy.
    $installedIds=@($script:InstalledItems|Where-Object State -eq 'Installed + healthy'|ForEach-Object TitleId)
    if($null -eq $FreeBytes){$card=$script:SdTargets.SelectedItem;if($card -and $card.PSObject.Properties['FreeBytes']){$FreeBytes=$card.FreeBytes}}
    # The planner reads 0 as no limit, so a card at or under the reserve passes 1: nothing fits.
    $available=if($null -eq $FreeBytes){[uint64]0}elseif([uint64]$FreeBytes -gt [uint64]512MB){[uint64]([uint64]$FreeBytes-[uint64]512MB)}else{[uint64]1}
    New-ThreeDSGuidedBatchPlan -Items @($script:GuidedInstall.Backlog) -InstalledTitleIds $installedIds -AvailableBytes $available
}
function Complete-GuidedReturn([int]$RequeuedCount=0) {
    # The active batch came back from the 3DS: report what installed and clear it.
    $healthyIds=@($script:InstalledItems|Where-Object State -eq 'Installed + healthy'|ForEach-Object TitleId)
    $return=Resolve-ThreeDSGuidedReturn -ActiveTitleIds @($script:GuidedInstall.ActiveTitleIds) -InstalledTitleIds $healthyIds
    $script:GuidedInstall.LastReturnMessage=$return.Message+$(if($RequeuedCount){"; $RequeuedCount back in the queue"}else{''})
    $script:GuidedInstall.ActiveBatchId='';$script:GuidedInstall.ActiveTitleIds=@();$script:GuidedInstall.ActiveCount=0;$script:GuidedInstall.AwaitingReturn=$false
    Save-GuidedInstallState
}
function Save-PreparationFailures {
    $state=[pscustomobject]@{StateVersion=1;SavedAt=(Get-Date).ToString('o');Failures=@($script:PreparationFailures)}
    Save-ThreeDSManagerState -Name 'preparation-failures.json' -Value $state | Out-Null
}
function Set-PreparationFailure($Failure) {
    $key=Get-ThreeDSPreparationStateKey -TitleId $Failure.TitleId -SourceSHA256 $Failure.SourceSHA256
    $Failure|Add-Member -NotePropertyName StateKey -NotePropertyValue $key -Force
    $script:PreparationFailures = @($script:PreparationFailures | Where-Object {
        (Get-ThreeDSPreparationStateKey -TitleId $_.TitleId -SourceSHA256 $_.SourceSHA256) -ne $key
    }) + @($Failure)
    Save-PreparationFailures
}
function Clear-PreparationFailure([string]$TitleId,[string]$SourceSHA256) {
    $key=Get-ThreeDSPreparationStateKey -TitleId $TitleId -SourceSHA256 $SourceSHA256
    $remaining = @($script:PreparationFailures | Where-Object {
        (Get-ThreeDSPreparationStateKey -TitleId $_.TitleId -SourceSHA256 $_.SourceSHA256) -ne $key
    })
    if ($remaining.Count -eq $script:PreparationFailures.Count) { return }
    $script:PreparationFailures = $remaining
    Save-PreparationFailures
}
function Get-FriendlyTitle([string]$Title){$clean=$Title -replace '\s+Decrypted$','';$clean=$clean -replace '\s+\((USA|Europe|Japan|EUR|JPN)\).*$','';$clean=$clean -replace '^\w?\d+\s+-\s+','';$clean.Trim()}
function Get-RemovableSignature{try{(@([IO.DriveInfo]::GetDrives()|Where-Object{$_.DriveType -eq [IO.DriveType]::Removable -and $_.IsReady}|ForEach-Object{"$($_.Name)|$($_.VolumeLabel)|$($_.TotalSize)"}|Sort-Object)-join ';')}catch{''}}
function Remove-StaleManagerWork {
    $workRoot = [IO.Path]::GetFullPath((Join-Path (Get-ThreeDSManagerDataRoot) 'work')).TrimEnd('\')
    if (-not (Test-Path -LiteralPath $workRoot)) { return 0 }
    $removed = 0
    foreach ($directory in @(Get-ChildItem -LiteralPath $workRoot -Directory -Force)) {
        $full = [IO.Path]::GetFullPath($directory.FullName).TrimEnd('\')
        if ($directory.Name -notmatch '^[0-9A-F]{16}-[0-9a-f]{32}$') { continue }
        if (-not $full.StartsWith($workRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { continue }
        Remove-Item -LiteralPath $full -Recurse -Force
        $removed++
    }
    $removed
}

# Every SD message and every SD-gated control is derived from one resolved
# lifecycle state.  Nothing in the interface may set these texts directly.
function Apply-SdLifecycle {
    $state=Resolve-ThreeDSSdLifecycle -CurrentTargets $script:SdItems -SelectedTarget $script:SdTargets.SelectedItem `
        -EjectedDeviceInstanceId $script:EjectedDeviceInstanceId -EjectRemovalObserved $script:EjectRemovalObserved `
        -Busy $script:Busy -Ejecting $script:Ejecting -EnumerationError $script:SdEnumerationError
    if($script:EjectedDeviceInstanceId -and -not $state.EjectedDeviceInstanceId){
        Add-Log "Cleared the recorded eject: Windows reports the verified SD card as connected again."
    }
    $script:EjectedDeviceInstanceId=[string]$state.EjectedDeviceInstanceId
    $script:EjectRemovalObserved=[bool]$state.EjectRemovalObserved
    $script:SdLifecycle=$state
    $script:HeaderSdStatus.Text=$state.HeaderText
    $script:SdFriendlyStatus.Text=$state.StatusText
    $script:EjectStateText.Text=$state.EjectStateText
    $script:EjectSd.IsEnabled=($state.CanEject -and -not $script:Busy -and -not $script:Ejecting)
    # The space chart describes a mounted card; the next refresh redraws it on return.
    if(-not $state.IsMounted){$script:SpaceCard.Visibility='Collapsed'}
    # The successful-eject banner exists only while the model says so, so it can
    # never survive into a lifecycle where the card is mounted and usable again.
    if($state.ShowsSuccessfulEject){
        $script:NextStepTitle.Text='Safe to remove SD card'
        $script:NextStepText.Text='Remove the SD card, use it in the 3DS, then reconnect it. The physical device will be identified again before any SD action.'
        $script:NextStepOwnedByEject=$true
    }elseif($script:NextStepOwnedByEject){
        $script:NextStepOwnedByEject=$false
        Update-NextStep
    }
    $state
}
function Update-EjectState { Apply-SdLifecycle | Out-Null }
function Refresh-SdTargets {
    $volumes=@()
    $script:SdEnumerationError=''
    try{$volumes=@(Get-ThreeDSSafeVolumes)}
    catch{$script:SdEnumerationError='Windows could not enumerate removable storage: '+$_.Exception.Message}
    # List and select only 3DS SD cards; other drives must never block identification.
    # Safe eject re-enumerates every volume for its shared-reader check.
    $selection=Resolve-ThreeDSSdSelection -Volumes $volumes -SelectedTarget $script:SdTargets.SelectedItem
    $items=@($selection.Candidates)
    foreach($item in $items){$label=if($item.VolumeLabel){$item.VolumeLabel}else{$item.DriveLetter};$item|Add-Member FriendlyDisplay ("$label ($([Math]::Round($item.VolumeCapacityBytes/1GB,1)) GiB)") -Force}
    $script:SdItems=$items;$script:SdTargets.ItemsSource=$items
    $script:SdTargets.SelectedIndex=$selection.SelectedIndex
    Apply-SdLifecycle|Out-Null
    Update-SelectionSummary
}
function Mark-SdEjected($Target){
    # Only reached after Invoke-ThreeDSSafeEject confirmed Windows removed the exact
    # verified device.  Absence is already established here; it is never assumed.
    if($script:GuidedInstall.ActiveBatchId){$script:GuidedInstall.AwaitingReturn=$true;Save-GuidedInstallState}
    $script:EjectedDeviceInstanceId=[string]$Target.DeviceInstanceId
    $script:EjectRemovalObserved=$true
    $script:SdItems=@();$script:SdTargets.ItemsSource=@();$script:SdTargets.SelectedIndex=-1
    $script:LastDriveSignature=Get-RemovableSignature
    Apply-SdLifecycle|Out-Null
    Update-SelectionSummary
}
function Invoke-SafeEject {
    if($script:Busy -or $script:Ejecting){return}
    $selected=$script:SdTargets.SelectedItem
    if(-not $selected){Show-Error 'Connect and select the 3DS SD card first.';return}
    $result=$null
    try{
        $script:Ejecting=$true
        Set-Busy $true 'Ejecting SD card';$script:CancelOperation.Visibility='Collapsed'
        Set-Progress 'Ejecting SD card' 'Rechecking the physical disk identity and asking Windows to safely remove it...' 0 0
        Save-Preferences
        $current=@(Get-ThreeDSSafeVolumes)
        $result=Invoke-ThreeDSSafeEject -SelectedTarget $selected -CurrentTargets $current -ManagerBusy:$false `
            -PresenceProbe { Get-ThreeDSSafeVolumes } -WaitAction { Pump-Ui }
    }catch{Show-Error $_}
    finally{$script:Ejecting=$false;Set-Busy $false 'Ready'}
    if(-not $result){try{Refresh-SdTargets}catch{Show-Error $_};return}
    Add-Log "Safe eject result: $($result.State) - $($result.Message)"
    if($result.Success -and $result.RemovalConfirmed){
        Mark-SdEjected $result.Target
        $script:FooterStatus.Text='Safe to remove SD card'
        Add-Log $result.Message
        return
    }
    # Either Windows refused, or it accepted but still reports the card connected.
    # Neither outcome may present the card as safe to physically remove.
    try{Refresh-SdTargets}catch{Show-Error $_}
    Show-Notice $(if($result.Success){'SD card still connected'}else{'Could not safely eject SD'}) $result.Message
}
function Get-SelectedTarget{param([switch]$AllowUnhealthyVolume)$item=$script:SdTargets.SelectedItem;if(-not $item){throw 'Connect and select the 3DS SD card first.'};Assert-ThreeDSSafeTarget -DiskNumber $item.DiskNumber -ExpectedDiskCapacityBytes $item.DiskCapacityBytes -ExpectedDriveLetter $item.DriveLetter -AllowUnhealthyVolume:$AllowUnhealthyVolume}
function Update-SelectionSummary {
    $selected = @($script:ViewItems | Where-Object IsChosen)
    $removals = @(Get-RemovalChanges -Mark)
    $keeps = @(Get-RemovalChanges -Keep)
    $failed = @($script:ViewItems | Where-Object HasPreparationFailure)
    [uint64]$bytes = 0
    foreach ($selectedItem in $selected) { $bytes += [uint64]$selectedItem.SourceLength }
    $changes = @()
    if ($selected.Count) { $changes += "$($selected.Count) game$(if($selected.Count -ne 1){'s'}) to add - about $([Math]::Round($bytes/1GB,1)) GiB" }
    if ($removals.Count) { $changes += "$($removals.Count) game$(if($removals.Count -ne 1){'s'}) to remove" }
    if ($keeps.Count) { $changes += "$($keeps.Count) game$(if($keeps.Count -ne 1){'s'}) to keep" }
    $script:SelectionSummary.Text = if ($changes.Count) { $changes -join '; ' }
    elseif ($failed.Count) { "$($failed.Count) game(s) failed preparation. Hover one to see why; fix or replace its file, then tick it to try again." }
    elseif ($script:ViewItems.Count) { 'Tick games to add or remove, then apply the changes.' }
    else { 'Waiting for the automatic game check.' }
    # One action applies every change; its label says exactly what it will do.
    $actions = @()
    if ($selected.Count) { $actions += "add $($selected.Count)" }
    if ($removals.Count) { $actions += "remove $($removals.Count)" }
    if ($keeps.Count) { $actions += "keep $($keeps.Count)" }
    $script:ApplyChanges.Content = if ($actions.Count -gt 1) { $label = $actions -join ', '; $label.Substring(0,1).ToUpperInvariant() + $label.Substring(1) }
    elseif ($selected.Count) { 'Add to SD card' }
    elseif ($removals.Count) { 'Remove from 3DS' }
    elseif ($keeps.Count) { 'Keep on 3DS' }
    else { 'Apply changes' }
    $hasSd = [bool]$script:SdLifecycle.CanUseSd
    $script:RefreshAll.IsEnabled = (-not $script:Busy -and $hasSd)
    $script:ApplyChanges.IsEnabled = (-not $script:Busy -and $hasSd -and $actions.Count -gt 0)
}
function Get-RemovalChanges {
    # The Remove column shows saved marks, so a change is a tick that differs from its mark.
    param([switch]$Mark,[switch]$Keep)
    if ($Mark) { @($script:ViewItems | Where-Object { $_.IsRemoveChosen -and -not $_.IsMarkedForRemoval }) }
    else { @($script:ViewItems | Where-Object { $_.IsMarkedForRemoval -and -not $_.IsRemoveChosen }) }
}
function Apply-Filter{$filter=$script:SearchBox.Text.Trim();$visible=if($filter){@($script:ViewItems|Where-Object DisplayTitle -Like "*$filter*")}else{@($script:ViewItems)};$script:GameGrid.ItemsSource=$visible}
function Update-NextStep {
    if($script:SdLifecycle.ShowsSuccessfulEject){
        $script:NextStepTitle.Text='Safe to remove SD card'
        $script:NextStepText.Text='Remove the SD card, use it in the 3DS, then reconnect it. The physical device will be identified again before any SD action.'
        $script:NextStepOwnedByEject=$true
        return
    }
    $plan=$null
    try{$plan=Get-GuidedInstallPlan}catch{Add-Log "Next-step plan unavailable: $($_.Exception.Message)"}
    $waiting=if($plan){[int]$plan.RemainingCount}else{0}
    $waitingText="$waiting game$(if($waiting -ne 1){'s'})"
    $notice=if($script:InlineNotice){"$($script:InlineNotice)`n`n"}else{''}
    # Adds and removals are applied together, so their console steps are shown together.
    $removing=@(if($script:PendingRemoval){@($script:PendingRemoval.Items)|ForEach-Object{$_.Title}})
    $removeSteps="open System Settings > Data Management > Nintendo 3DS > Software and delete: $($removing -join ', '). Removal is confirmed automatically when the card comes back."
    if($script:GuidedInstall.ActiveBatchId){
        $later=if($waiting){"`n`n$waiting more game$(if($waiting -ne 1){'s'}) will be copied automatically when this card comes back."}else{''}
        $alsoRemove=if($removing.Count){"`n`nThen, on the 3DS, $removeSteps"}else{''}
        $script:NextStepTitle.Text="Batch ready - $($script:GuidedInstall.ActiveCount) game$(if([int]$script:GuidedInstall.ActiveCount -ne 1){'s'})$(if($removing.Count){"; $($removing.Count) to remove"})"
        $script:NextStepText.Text="$($notice)GodMode9 folder:`nSDCARD/cias/InstallQueue/$($script:GuidedInstall.ActiveBatchId)`n`nChoose Safely Eject SD. In GodMode9, mark every game in that folder with L and choose Install game image.$alsoRemove$later"
    }
    elseif($removing.Count){
        $alsoWaiting=if($waiting){"`n`n$waitingText waiting to copy to the SD card."}else{''}
        $script:NextStepTitle.Text="Remove $($removing.Count) game$(if($removing.Count -ne 1){'s'}) on the 3DS"
        $script:NextStepText.Text="$($notice)Choose Safely Eject SD. On the 3DS, $removeSteps$alsoWaiting"
    }
    elseif($script:LastRemovalConfirmed){
        $script:NextStepTitle.Text='Removal confirmed';$script:NextStepText.Text="$($script:LastRemovalConfirmed) is no longer installed. Its PC source and prepared copy were preserved."
    }
    else{
        if(-not $plan){$script:NextStepTitle.Text='Next step';$script:NextStepText.Text='Check for changes to refresh the remaining game count.';return}
        $prefix="$(if($script:InlineNotice){"$($script:InlineNotice)`n`n"})$(if($script:GuidedInstall.LastReturnMessage){"$($script:GuidedInstall.LastReturnMessage).`n`n"})"
        if($waiting){
            # Chosen games are copied without another click; this only says what they wait for.
            $reason=if(-not $script:SdLifecycle.IsMounted){'Connect the SD card and they will be copied automatically.'}elseif(-not $plan.NextCount){'The SD card does not have enough free space for the next game. Free up space, then choose Check for changes.'}else{'They are copied automatically. If copying was stopped, choose Check for changes.'}
            $script:NextStepTitle.Text="$waitingText waiting to copy"
            $script:NextStepText.Text="$prefix$waitingText waiting to copy to the SD card.`n$reason"
        }else{$script:NextStepTitle.Text='Next step';$script:NextStepText.Text="$($prefix)Choose games to add or remove."}
    }
}
function Format-SpaceSize([uint64]$Bytes){if($Bytes -ge 1GB){'{0:N1} GB' -f ($Bytes/1GB)}else{'{0:N0} MB' -f ($Bytes/1MB)}}
function New-PieSliceGeometry([double]$Start,[double]$Fraction,[double]$Radius){
    # A slice of a circle centred at (Radius,Radius), running clockwise from 12 o'clock.
    if($Fraction -le 0){return $null}
    $center=[Windows.Point]::new($Radius,$Radius)
    if($Fraction -ge 0.9999){return [Windows.Media.EllipseGeometry]::new($center,$Radius,$Radius)}
    $from=2*[Math]::PI*$Start;$to=2*[Math]::PI*($Start+$Fraction)
    $figure=[Windows.Media.PathFigure]::new();$figure.StartPoint=$center;$figure.IsClosed=$true
    $figure.Segments.Add([Windows.Media.LineSegment]::new([Windows.Point]::new($Radius+$Radius*[Math]::Sin($from),$Radius-$Radius*[Math]::Cos($from)),$true))
    $figure.Segments.Add([Windows.Media.ArcSegment]::new([Windows.Point]::new($Radius+$Radius*[Math]::Sin($to),$Radius-$Radius*[Math]::Cos($to)),[Windows.Size]::new($Radius,$Radius),0,($Fraction -gt 0.5),[Windows.Media.SweepDirection]::Clockwise,$true))
    $geometry=[Windows.Media.PathGeometry]::new();$geometry.Figures.Add($figure);$geometry
}
function Update-SdSpace {
    # Reads the selected card's live free space, which also keeps the copy plan current,
    # and draws the games / other / free chart from the inventory already read.  It runs
    # while a check or copy is busy, so it needs a mounted card, not an idle one.
    $card=$script:SdTargets.SelectedItem
    $script:SpaceCard.Visibility='Collapsed'
    if(-not $card -or -not $script:SdLifecycle.IsMounted -or -not $card.PSObject.Properties['Root']){return}
    try{$drive=[IO.DriveInfo]::new([string]$card.Root);$total=[uint64]$drive.TotalSize;$free=[uint64]$drive.TotalFreeSpace}catch{return}
    if(-not $total){return}
    if($card.PSObject.Properties['FreeBytes']){$card.FreeBytes=$free}
    $usage=Get-ThreeDSSdSpaceUsage -TotalBytes $total -FreeBytes $free -InstalledTitles @($script:InstalledItems) -Batches @($script:BatchItems)
    $start=0.0
    foreach($part in @(@('Games',$usage.GamesBytes),@('Other',$usage.OtherBytes),@('Free',$usage.FreeBytes))){
        $fraction=[double]$part[1]/[double]$total
        (Get-Variable -Scope Script -Name "Space$($part[0])Slice" -ValueOnly).Data=New-PieSliceGeometry $start $fraction 58
        (Get-Variable -Scope Script -Name "Space$($part[0])Text" -ValueOnly).Text="$($part[0]) - $(Format-SpaceSize $part[1]) ($([Math]::Round($fraction*100))%)"
        $start+=$fraction
    }
    $script:SpaceSummary.Text="$(Format-SpaceSize $usage.FreeBytes) free of $(Format-SpaceSize $total)"
    $script:SpaceCard.Visibility='Visible'
}
function Build-ViewItems {
    $installed=@{}; foreach($item in $script:InstalledItems){$installed[$item.TitleId]=$item}
    $staged=@{}; foreach($batch in $script:BatchItems){foreach($item in @($batch.Items)){$staged[$item.TitleId]=$batch}}
    $queued=@{};foreach($item in @($script:GuidedInstall.Backlog)){if($item.TitleId){$queued[([string]$item.TitleId).ToUpperInvariant()]=$true}}
    $failureByKey=@{}; foreach($failure in $script:PreparationFailures){if($failure.TitleId -and $failure.SourceSHA256){$failureByKey[(Get-ThreeDSPreparationStateKey -TitleId $failure.TitleId -SourceSHA256 $failure.SourceSHA256)]=$failure}}
    $markedForRemoval=@{};if($script:PendingRemoval){foreach($marked in @($script:PendingRemoval.Items)){$markedForRemoval[[string]$marked.TitleId]=$true}}
    $requiresBoot9=@($script:LibraryItems|Where-Object{$_.Format -in @('3DS','CCI') -and $_.EncryptionState -eq 'Encrypted'}).Count -gt 0
    $script:Boot9Panel.Visibility=if($requiresBoot9){'Visible'}else{'Collapsed'}
    $views=@()
    foreach($item in $script:LibraryItems){
        if(-not $item.TitleId){continue}
        $state=if($installed.ContainsKey($item.TitleId)){$installed[$item.TitleId].State}elseif($staged.ContainsKey($item.TitleId)){'Staged on SD'}elseif($queued.ContainsKey($item.TitleId)){'Prepared on PC'}else{'Missing'}
        $playable=($state -in @('Installed + healthy','Installed + uncertain'))
        # A broken install is simply added again; GodMode9 reinstalls over it.
        $incomplete=($state -eq 'Installed + unhealthy')
        $addable=($state -eq 'Missing' -or $incomplete)
        $itemKey=Get-ThreeDSPreparationStateKey -TitleId $item.TitleId -SourceSHA256 $item.SourceSHA256
        $failure=if($addable -and $failureByKey.ContainsKey($itemKey)){$failureByKey[$itemKey]}else{$null}
        $removing=($playable -and $markedForRemoval.ContainsKey([string]$item.TitleId))
        $views+=[pscustomobject]@{
            # The Remove box shows the saved mark, so unticking it and applying undoes the mark.
            IsChosen=$false; IsRemoveChosen=$removing; IsMarkedForRemoval=$removing
            CanSelect=$addable
            CanRemove=($playable -and $item.Type -eq 'Base')
            DisplayTitle=(Get-FriendlyTitle $item.Title); Type=$item.Type
            DisplayState=if($playable){'Yes'}else{'No'}; LifecycleState=$state
            PreparationStatus=if($failure){'FAILED - hover for why'}elseif($incomplete){'Install incomplete - add it again'}elseif($removing){'Delete on the 3DS'}else{''}
            PreparationError=if($failure){[string]$failure.Error}elseif($incomplete){'The installed files on the SD card are incomplete. Add the game again to reinstall it.'}elseif($removing){'Marked for removal. Delete it on the 3DS in System Settings > Data Management > Nintendo 3DS > Software, or untick Remove and apply to keep it.'}else{''}
            PreparationForeground=if($failure){'#B42318'}elseif($incomplete -or $removing){'#8A5A00'}else{'#44515E'}
            HasPreparationFailure=[bool]$failure
            TitleId=$item.TitleId; SourceLength=[uint64]$item.SourceLength; LibraryItem=$item
        }
    }
    $script:ViewItems=@($views|Sort-Object Type,DisplayTitle)
    Update-SdSpace; Apply-Filter; Update-SelectionSummary; Update-NextStep
}

function Resolve-PendingRemoval {
    if (-not $script:PendingRemoval -or $script:PendingRemoval.Status -ne 'Awaiting console removal') { return }
    $installedIds=@{};foreach($installed in $script:InstalledItems){$installedIds[[string]$installed.TitleId]=$true}
    $remaining=@($script:PendingRemoval.Items|Where-Object{$installedIds.ContainsKey([string]$_.TitleId)})
    $removed=@($script:PendingRemoval.Items|Where-Object{-not $installedIds.ContainsKey([string]$_.TitleId)})
    if (-not $removed.Count) { return }
    # Each game deleted on the console is confirmed on its own; the rest stay marked.
    $names=@($removed|ForEach-Object{$_.Title})-join ', '
    $script:LastRemovalConfirmed=$names
    Add-Log "Console removal confirmed for: $names"
    if ($remaining.Count) {
        $script:PendingRemoval=[pscustomobject]@{CreatedAt=$script:PendingRemoval.CreatedAt;Status='Awaiting console removal';Items=$remaining}
        Save-ThreeDSManagerState -Name 'pending-removal.json' -Value $script:PendingRemoval|Out-Null
        return
    }
    $completed=[pscustomobject]@{CreatedAt=$script:PendingRemoval.CreatedAt;ConfirmedAt=(Get-Date).ToString('o');Status='Removal confirmed';Items=@($script:PendingRemoval.Items)}
    Save-ThreeDSManagerState -Name 'pending-removal.json' -Value $completed|Out-Null
    $script:PendingRemoval=$null
}

function Read-SmartSdState {
    param($Target,[scriptblock]$ProgressAction)
    $batches=@(Get-ThreeDSInstallBatches -SdRoot $Target.Root -ProgressAction $ProgressAction)
    $knownById=@{}
    foreach($known in @(Get-ThreeDSKnownTitleManifests)){if($known.TitleId){$knownById[([string]$known.TitleId).ToUpperInvariant()]=$known}}
    foreach($batch in $batches){foreach($known in @($batch.Items)){if($known.TitleId){$knownById[([string]$known.TitleId).ToUpperInvariant()]=$known}}}
    if($ProgressAction){& $ProgressAction 'Reading installed game inventory...' 0 0|Out-Null}
    # Installed health is an exact match to the validated manifest; nothing is re-read.
    $script:InstalledItems=@(Get-ThreeDSInstalledTitles -SdRoot $Target.Root -ExpectedTitles @($knownById.Values) -ProgressAction $ProgressAction|Sort-Object Type,TitleId)
    $batches=@(Resolve-ThreeDSInstallBatches -Batches $batches -InstalledTitles $script:InstalledItems)

    # A batch that has been out to the 3DS is finished with: its folder is removed
    # whole, and games that did not install go back in the queue.
    $activeBatchId=[string]$script:GuidedInstall.ActiveBatchId
    $return=Resolve-ThreeDSBatchReturn -Batches $batches -ActiveBatchId $activeBatchId -AwaitingReturn ([bool]$script:GuidedInstall.AwaitingReturn)
    $requeueItems=@($return.RequeueItems)
    if($return.ActiveMissing){
        # The folder is already gone from the card; its private record still lists the games.
        $record=$null;try{$record=Get-ThreeDSManagerState -Name (Get-ThreeDSInstallBatchStateName -BatchId $activeBatchId)}catch{}
        if($record -and $record.PSObject.Properties['Queue']){$requeueItems+=@(@($record.Queue)|Where-Object{$_})}
    }
    $skipIds=@{}
    foreach($title in $script:InstalledItems){if($title.State -eq 'Installed + healthy'){$skipIds[[string]$title.TitleId]=$true}}
    foreach($batch in @($return.KeepBatches)){foreach($item in @($batch.Items)){$skipIds[[string]$item.TitleId]=$true}}
    $requeued=@()
    foreach($item in $requeueItems){
        $titleId=([string]$item.TitleId).ToUpperInvariant()
        if($skipIds.ContainsKey($titleId)){continue};$skipIds[$titleId]=$true
        $artifact=if($script:CachePath.Text){Find-ThreeDSPreparedArtifact -InstallReadyRoot $script:CachePath.Text -Item $item}else{$null}
        if($artifact){$requeued+=$artifact}else{Add-Log "$($item.Title) did not install and its prepared copy was not found. Tick it again to add it back."}
    }
    if($requeued.Count){Add-GuidedBacklog -Artifacts $requeued}
    foreach($batch in @($return.RemoveBatches)){
        if($ProgressAction){& $ProgressAction "Removing finished install folder $($batch.BatchId)..." 0 0|Out-Null}
        try{
            Remove-ThreeDSInstallFolder -BatchId ([string]$batch.BatchId) -TargetDiskNumber $Target.DiskNumber -ExpectedDiskCapacityBytes $Target.DiskCapacityBytes -ExpectedDriveLetter $Target.DriveLetter -AllowAdvisoryVolumeHealth|Out-Null
            Add-Log "Removed install folder $($batch.BatchId): $($batch.InstalledCount) installed, $($batch.RemainingCount) not installed."
        }catch{Add-Log "Could not remove install folder $($batch.BatchId): $($_.Exception.Message)"}
    }
    if($return.ActiveReturned){Complete-GuidedReturn -RequeuedCount $requeued.Count}
    $script:BatchItems=@($return.KeepBatches)
}

function Add-PendingRemoval([object[]]$Views) {
    # Marks games for normal console-side deletion.  Earlier marks that the console has not
    # carried out yet stay; the PC never deletes anything from Nintendo 3DS itself.
    $byId=[ordered]@{}
    if($script:PendingRemoval){foreach($item in @($script:PendingRemoval.Items)){$byId[[string]$item.TitleId]=$item}}
    foreach($view in $Views){$byId[[string]$view.TitleId]=[pscustomobject]@{Title=$view.DisplayTitle;TitleId=$view.TitleId;Type=$view.Type}}
    $created=if($script:PendingRemoval){$script:PendingRemoval.CreatedAt}else{(Get-Date).ToString('o')}
    $script:PendingRemoval=[pscustomobject]@{CreatedAt=$created;Status='Awaiting console removal';Items=@($byId.Values)}
    $script:LastRemovalConfirmed=''
    Save-ThreeDSManagerState -Name 'pending-removal.json' -Value $script:PendingRemoval|Out-Null
}
function Clear-RemovalMark([object[]]$Views) {
    # Undoes marks the user unticked; the console was never asked to change anything.
    if(-not $script:PendingRemoval){return}
    $keepIds=@($Views|ForEach-Object{[string]$_.TitleId})
    $remaining=@($script:PendingRemoval.Items|Where-Object{[string]$_.TitleId -notin $keepIds})
    $script:PendingRemoval=if($remaining.Count){[pscustomobject]@{CreatedAt=$script:PendingRemoval.CreatedAt;Status='Awaiting console removal';Items=$remaining}}else{$null}
    Save-ThreeDSManagerState -Name 'pending-removal.json' -Value $(if($script:PendingRemoval){$script:PendingRemoval}else{[pscustomobject]@{Status='Cleared';ClearedAt=(Get-Date).ToString('o');Items=@()}})|Out-Null
}

function Invoke-RefreshAll{try{Set-Busy $true 'Checking for changes';Save-Preferences;$tools=Get-ThreeDSToolchain;if(-not $tools.Ready){throw 'Helper tools are not ready. Open Settings and choose Set up helper tools.'};$libraryRoot=Assert-ThreeDSExternalDataPath -Path $script:LibraryPath.Text -RepositoryRoot $script:RepositoryRoot;$target=Get-SelectedTarget -AllowUnhealthyVolume;Set-Progress 'Checking your game library' 'Comparing files with the saved library index...' 0 0;$scanProgress={param($position,$count,$name,$done,$total,$phase);$detail=if($phase -eq 'Reused'){"Game $position of $count unchanged - $name"}elseif($total){"Game $position of $count - $name - $([Math]::Round($done/1MB)) / $([Math]::Round($total/1MB)) MiB"}else{"Game $position of $count - $name"};Set-Progress 'Checking your game library' $detail $done $total};$script:LibraryItems=@(Get-ThreeDSLibraryInventory -LibraryRoot $libraryRoot -CtrToolPath $tools.CtrToolPath -ProgressAction $scanProgress -CachedItems $script:LibraryCache);$script:LibraryCache=@($script:LibraryItems);$duplicates=@($script:LibraryItems|Where-Object TitleId|Group-Object TitleId|Where-Object Count -gt 1);if($duplicates.Count){throw 'The library contains more than one source for the same game. Resolve duplicates before continuing.'};Save-ThreeDSManagerState -Name 'library-index.json' -Value $script:LibraryItems|Out-Null;$sdProgress={param($message,$done,$total)Set-Progress 'Checking the SD card' $message $done $total};Set-Progress 'Checking the SD card' 'Reading install-set manifests and installed-title metadata...' 0 0;Read-SmartSdState -Target $target -ProgressAction $sdProgress;Resolve-PendingRemoval;Build-ViewItems;$reused=@($script:LibraryItems|Where-Object CacheState -eq 'Reused').Count;$scanned=$script:LibraryItems.Count-$reused;Set-Progress 'Up to date' "$($script:ViewItems.Count) games found; $reused unchanged, $scanned new or changed." 100 100;Add-Log "Smart refresh complete: $($script:ViewItems.Count) games ($reused reused, $scanned rescanned), $($script:InstalledItems.Count) installed entries, $($script:BatchItems.Count) batches.";$returned=[string]$script:GuidedInstall.LastReturnMessage;$queue=Copy-WaitingGames;if($queue){Show-Notice "Copied $($queue.ItemCount) waiting game$(if($queue.ItemCount -ne 1){'s'}) to the SD card" $(if($returned){"$returned."}else{''})}}catch{Show-Error $_}finally{Set-Busy $false 'Ready'}}
function Invoke-ApplyChanges {
    # Applies every tick in one run: removals are marked first, then the games to add are
    # prepared and copied.  Once it starts, Stop is the only control.  Each finished step
    # is saved as it completes and kept; the step in progress and the rest are cancelled.
    param([AllowEmptyCollection()][object[]]$Adds=@(),[AllowEmptyCollection()][object[]]$Removals=@(),[AllowEmptyCollection()][object[]]$Keeps=@())
    $context=[pscustomobject]@{Game='';Operation='Applying changes'}
    $done=[pscustomobject]@{Marked=0;Kept=0;Prepared=0;BatchBefore=[string]$script:GuidedInstall.ActiveBatchId}
    try {
        if (-not ($Adds.Count + $Removals.Count + $Keeps.Count)) { throw 'Tick games to add or remove first.' }
        if (@($Adds|Where-Object{-not $_.CanSelect}).Count) { throw 'One game ticked to add is no longer eligible. Check for changes and review again.' }
        if (@($Removals|Where-Object{-not $_.CanRemove}).Count) { throw 'One game ticked to remove is no longer eligible. Check for changes first.' }
        # Preparation converts and validates on the PC and writes nothing to the SD,
        # so it only needs the card identified, not a cleared dirty flag.
        Get-SelectedTarget -AllowUnhealthyVolume|Out-Null
        Set-Busy $true 'Applying changes'
        if ($Keeps.Count) {
            Clear-RemovalMark $Keeps
            $done.Kept=$Keeps.Count
            Add-Log "No longer marked for removal: $(@($Keeps|ForEach-Object DisplayTitle) -join ', ')"
        }
        if ($Removals.Count) {
            $context.Operation='Marking games for removal'
            Add-PendingRemoval $Removals
            $done.Marked=$Removals.Count
            Add-Log "Marked for removal on the 3DS: $(@($Removals|ForEach-Object DisplayTitle) -join ', ')"
        }
        if (-not $Adds.Count) {
            Build-ViewItems
            $parts=@()
            if($done.Marked){$parts+="$($done.Marked) game$(if($done.Marked -ne 1){'s'}) marked for removal"}
            if($done.Kept){$parts+="$($done.Kept) game$(if($done.Kept -ne 1){'s'}) kept on the 3DS"}
            Show-Notice ($parts -join '; ')
            return
        }
        $tools=Get-ThreeDSToolchain
        $cache=Assert-ThreeDSExternalDataPath -Path $script:CachePath.Text -RepositoryRoot $script:RepositoryRoot
        $boot9=$script:Boot9Path.Text
        $prepareAction={
            param($view,$number,$count)
            $displayTitle=$view.DisplayTitle
            $context.Game=$displayTitle
            $context.Operation='Preparing and validating game'
            $progress={
                param($message,$done,$total)
                $remaining=$count-$number
                Set-Progress "Preparing $displayTitle - game $number of $count" "$message $($number-1) finished, $remaining remaining after this." $done $total
            }.GetNewClosure()
            Prepare-ThreeDSArtifact -LibraryItem $view.LibraryItem -Toolchain $tools -InstallReadyRoot $cache -Boot9Path $boot9 -ProgressAction $progress
        }.GetNewClosure()
        $successAction={
            param($view,$artifact,$number,$count)
            Clear-PreparationFailure $view.TitleId $view.LibraryItem.SourceSHA256
            # Queued as soon as it is ready, so a Stop later in the run keeps it.
            Add-GuidedBacklog -Artifacts @($artifact)
            $done.Prepared++
            Add-Log "Validated $($view.DisplayTitle): $($artifact.ArtifactSHA256)"
        }
        $failureAction={
            param($failure,$number,$count)
            Set-PreparationFailure $failure
            $remaining=$count-$number
            Set-Progress "Failed: $($failure.Title)" "$($failure.Error) Continuing; $number checked, $remaining remaining." $number $count
            Add-Log "FAILED $($failure.Title) [$($failure.TitleId)]: $($failure.TechnicalError)"
        }
        $result=Invoke-ThreeDSPreparationBatch -Items $Adds -PrepareAction $prepareAction -SuccessAction $successAction -FailureAction $failureAction
        Build-ViewItems
        $failureText=if($result.FailedCount){" $((@($result.Failures|ForEach-Object{"$($_.Title): $($_.Error)"}) -join ' | ').TrimEnd('.')). Fix or replace the failed file, then tick it again to retry."}else{''}
        # Preparing exists only to put games on the card, so carry straight on to the copy.
        $context.Game='';$context.Operation='Copying games to the SD card'
        $queue=Copy-WaitingGames
        $waiting=@($script:GuidedInstall.Backlog).Count
        # The Next step card below already gives the install and delete steps.
        $parts=@();$detail=''
        if($queue){$parts+="Copied $($queue.ItemCount) game$(if($queue.ItemCount -ne 1){'s'}) to the SD card"}
        elseif($script:GuidedInstall.ActiveBatchId -and $waiting){$parts+="$waiting game$(if($waiting -ne 1){'s'}) waiting to copy";$detail='They will be copied once the games already on the SD card are installed and the card is back.'}
        elseif($waiting){$parts+='Not enough free space on the SD card';$detail='The prepared games are waiting on the PC.'}
        if($result.FailedCount){$parts+="$($result.FailedCount) failed"}
        if($done.Marked){$parts+="$($done.Marked) marked for removal"}
        if($done.Kept){$parts+="$($done.Kept) kept on the 3DS"}
        Show-Notice ($parts -join '; ') "$detail$failureText".Trim()
    }
    catch {
        if (Test-ThreeDSCancellation -ErrorValue $_) { Show-StoppedNotice $done }
        else { Show-Error $_ -Game $context.Game -Operation $context.Operation }
    }
    finally { Set-Busy $false 'Ready' }
}
function Show-StoppedNotice($Done) {
    # Reports what finished before Stop.  Each of these steps was saved as it completed.
    $script:CancelRequested=$false
    $kept=@()
    if($Done.Kept){$kept+="$($Done.Kept) game$(if($Done.Kept -ne 1){'s'}) no longer marked for removal"}
    if($Done.Marked){$kept+="$($Done.Marked) game$(if($Done.Marked -ne 1){'s'}) marked for removal"}
    if($Done.Prepared){$kept+="$($Done.Prepared) game$(if($Done.Prepared -ne 1){'s'}) prepared"}
    $copied=if($script:GuidedInstall.ActiveBatchId -and $script:GuidedInstall.ActiveBatchId -ne $Done.BatchBefore){[int]$script:GuidedInstall.ActiveCount}else{0}
    if($copied){$kept+="$copied copied to the SD card"}
    try{Build-ViewItems}catch{Add-Log "Could not refresh the game list after stopping: $($_.Exception.Message)"}
    Show-Notice 'Stopped' $(if($kept.Count){"Kept what had finished: $($kept -join ', '). The step in progress and everything after it were cancelled."}else{'Nothing had finished yet, so nothing was changed.'})
}
function Copy-GuidedQueue {
    # Copies as much of the waiting queue as fits into one new GodMode9 folder.
    # Returns the new batch, or $null when not even one game fits.
    param([Parameter(Mandatory)]$Target)
    $plan=Get-GuidedInstallPlan -FreeBytes $Target.FreeBytes
    if(-not $plan.NextCount){return $null}
    $progress={param($message,$done,$total,$position,$itemCount)Set-Progress 'Copying games to the SD card' $message $done $total}.GetNewClosure()
    $outcome=@{}
    try{$queue=Copy-ThreeDSInstallQueue -Artifacts @($plan.NextItems) -TargetDiskNumber $Target.DiskNumber -ExpectedDiskCapacityBytes $Target.DiskCapacityBytes -ExpectedDriveLetter $Target.DriveLetter -AllowAdvisoryVolumeHealth -ProgressAction $progress -Outcome $outcome}
    catch{
        # A Stop keeps the games already copied as a smaller batch; the rest keep waiting.
        if($outcome.ContainsKey('Batch')){Register-CopiedBatch $outcome['Batch']}
        throw
    }
    Register-CopiedBatch $queue
    Set-Progress 'Batch ready' "$($queue.ItemCount) games staged in $($queue.QueueRoot)" 100 100
    $queue
}
function Register-CopiedBatch($Queue) {
    $ids=@($Queue.Items|ForEach-Object{([string]$_.TitleId).ToUpperInvariant()})
    $script:GuidedInstall.Backlog=@($script:GuidedInstall.Backlog|Where-Object{([string]$_.TitleId).ToUpperInvariant() -notin $ids})
    $script:GuidedInstall.ActiveBatchId=$Queue.BatchId;$script:GuidedInstall.ActiveTitleIds=@($ids);$script:GuidedInstall.ActiveCount=$Queue.ItemCount;$script:GuidedInstall.AwaitingReturn=$false;$script:GuidedInstall.LastReturnMessage=''
    Save-GuidedInstallState
    $newBatch=[pscustomobject]@{BatchId=$Queue.BatchId;BatchPath=$Queue.QueueRoot;ManifestPath=$Queue.QueueRecord;CreatedAt=$Queue.CreatedAt;Items=@($Queue.Items);ItemCount=$Queue.ItemCount;State='Ready to install';InstalledCount=0;RemainingCount=$Queue.ItemCount;InstalledItems=@();RemainingItems=@($Queue.Items)}
    $script:BatchItems=@($script:BatchItems|Where-Object BatchId -ne $Queue.BatchId)+@($newBatch)
    Build-ViewItems|Out-Null
}
function Copy-WaitingGames {
    # Games the user chose wait on the PC only while an earlier batch is still out to be
    # installed or the card is full; otherwise they are copied without another click.
    # Runs inside an operation that is already busy.  Returns the new batch or $null.
    if($script:GuidedInstall.ActiveBatchId -or -not @($script:GuidedInstall.Backlog).Count){return $null}
    # The plan uses the card's live free space, not the value from the last enumeration.
    Copy-GuidedQueue -Target (Get-SelectedTarget -AllowUnhealthyVolume)
}
function Invoke-ApplySelected {
    $script:GameGrid.CommitEdit()|Out-Null
    Invoke-ApplyChanges -Adds @($script:ViewItems|Where-Object IsChosen) -Removals @(Get-RemovalChanges -Mark) -Keeps @(Get-RemovalChanges -Keep)
}
$script:CancelOperation.Add_Click({if($script:Busy -and -not $script:CancelRequested){$script:CancelRequested=$true;$script:CancelOperation.IsEnabled=$false;$script:ProgressTitle.Text='Cancelling...';$script:ProgressDetail.Text='Keeping what has finished and removing the partial files of the step in progress.';$script:OperationProgress.IsIndeterminate=$true;$script:FooterStatus.Text='Cancelling...'}})
$script:RefreshSd.Add_Click({try{Refresh-SdTargets}catch{Show-Error $_}});$script:EjectSd.Add_Click({Invoke-SafeEject});$script:SdTargets.Add_SelectionChanged({Apply-SdLifecycle|Out-Null;Update-SelectionSummary});$script:RefreshAll.Add_Click({Invoke-RefreshAll});$script:ApplyChanges.Add_Click({Invoke-ApplySelected});$script:SearchBox.Add_TextChanged({Apply-Filter});$script:GameGrid.Add_CurrentCellChanged({Update-SelectionSummary});$script:GameGrid.Add_CellEditEnding({$window.Dispatcher.BeginInvoke([action]{Update-SelectionSummary})|Out-Null})
$script:BrowseLibrary.Add_Click({$path=Select-Folder $script:LibraryPath.Text;if($path){$script:LibraryPath.Text=$path;Save-Preferences}});$script:BrowseCache.Add_Click({$path=Select-Folder $script:CachePath.Text;if($path){$script:CachePath.Text=$path;Save-Preferences}});$script:BrowseBoot9.Add_Click({$dialog=New-Object Microsoft.Win32.OpenFileDialog;$dialog.Filter='boot9 file|boot9.bin|All files|*.*';if($dialog.ShowDialog()){$script:Boot9Path.Text=$dialog.FileName}})
$script:SetupTools.Add_Click({try{Set-Busy $true 'Setting up helper tools';Set-Progress 'Setting up helper tools' 'Downloading and verifying pinned tools...' 0 0;& (Join-Path $PSScriptRoot 'setup-library-tools.ps1');$script:SetupTools.Visibility='Collapsed'}catch{Show-Error $_}finally{Set-Busy $false 'Ready'}})
$window.Add_Loaded({$staleCount=Remove-StaleManagerWork;if($staleCount){Add-Log "Removed $staleCount stale disposable work folder(s)."};$preferences=Get-ThreeDSManagerState -Name 'preferences.json';if($preferences){$script:LibraryPath.Text=[string]$preferences.LibraryRoot;$script:CachePath.Text=[string]$preferences.InstallReadyRoot;if($preferences.PSObject.Properties['Boot9Path']){$script:Boot9Path.Text=[string]$preferences.Boot9Path}};$guided=Get-ThreeDSManagerState -Name 'guided-install.json';if($guided){$script:GuidedInstall=$guided};$savedIndex=Get-ThreeDSManagerState -Name 'library-index.json';if($savedIndex){$script:LibraryCache=@($savedIndex|ForEach-Object{$_})};$savedFailures=Get-ThreeDSManagerState -Name 'preparation-failures.json';if($savedFailures){$failureValues=if($savedFailures.PSObject.Properties['Failures']){$savedFailures.Failures}else{$savedFailures};$script:PreparationFailures=@($failureValues|ForEach-Object{$_})};$pendingRemoval=Get-ThreeDSManagerState -Name 'pending-removal.json';if($pendingRemoval -and $pendingRemoval.Status -eq 'Awaiting console removal'){$script:PendingRemoval=$pendingRemoval};$tools=Get-ThreeDSToolchain;if($tools.Ready){$script:SetupTools.Visibility='Collapsed'};try{Refresh-SdTargets;$script:LastDriveSignature=Get-RemovableSignature;if($script:SdTargets.SelectedItem -and $tools.Ready -and $script:LibraryPath.Text -and $script:CachePath.Text){$window.Dispatcher.BeginInvoke([action]{Invoke-RefreshAll})|Out-Null}else{Set-Progress 'Waiting for the SD card' 'Connect the 3DS SD card; the game list will update automatically.' 0 0}}catch{Show-Error $_};$script:DeviceTimer.Start();Add-Log "Private manager state: $(Get-ThreeDSManagerDataRoot)"})
$window.Add_Closing({param($sender,$eventArgs);if($script:Busy){$eventArgs.Cancel=$true;[Windows.MessageBox]::Show($window,'A game operation is still running. Wait for it to finish before closing the app.','3DS Game Installer','OK','Warning')|Out-Null;return};Save-Preferences;$script:Timer.Stop();$script:DeviceTimer.Stop();if($script:OwnsInstanceMutex){$script:InstanceMutex.ReleaseMutex();$script:OwnsInstanceMutex=$false};$script:InstanceMutex.Dispose()});[void]$window.ShowDialog()
