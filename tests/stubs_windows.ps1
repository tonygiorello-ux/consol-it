# Commandes Windows simulées pour exécuter les diagnostics hors Windows (tests de fumée).
# Les valeurs déclenchent volontairement des cas « attention » et « critique ».
$env:COMPUTERNAME = 'PC-TEST'; $env:USERDOMAIN = 'CONTOSO'; $env:USERNAME = 'tony'; $env:USERDNSDOMAIN = 'contoso.local'
if (-not $env:SystemDrive) { $env:SystemDrive = 'C:' }
if (-not $env:SystemRoot) { $env:SystemRoot = '/tmp/winroot' }
if (-not $env:LOCALAPPDATA) { $env:LOCALAPPDATA = '/tmp/winlocal' }
if (-not $env:APPDATA) { $env:APPDATA = '/tmp/winroaming' }
if (-not $env:TEMP) { $env:TEMP = [IO.Path]::GetTempPath() }
$script:Reponses = New-Object System.Collections.Queue
function Read-Host($p) { if ($script:Reponses.Count) { $a = $script:Reponses.Dequeue() } else { $a = '' }; Write-Host "$p > $a" -ForegroundColor DarkGray; $a }
function Invoke-Item($p) { Write-Host "[ouvrir] $p" }
function Get-DossierRapports { $d = (Join-Path ([IO.Path]::GetTempPath()) 'console-it-tests'); New-Item -ItemType Directory $d -Force | Out-Null; $d }
function Test-EstAdmin { $false }
function Set-Clipboard { }
function Start-Sleep { }
$__Maint = Get-Date
function P([hashtable]$h) { [pscustomobject]$h }

function Get-CimInstance {
  param([Parameter(Position = 0)][string]$ClassName, [string]$Namespace, [string]$Filter, [string]$Class)
  if ($Class) { $ClassName = $Class }
  switch ($ClassName) {
    'Win32_OperatingSystem' { P @{ Caption = 'Microsoft Windows 10 Professionnel'; Version = '10.0.19045'; BuildNumber = '19045'; LastBootUpTime = $__Maint.AddDays(-12); TotalVisibleMemorySize = 8388608; FreePhysicalMemory = 524288; InstallDate = $__Maint.AddYears(-3); OSArchitecture = '64 bits' } }
    'Win32_ComputerSystem' { P @{ Manufacturer = 'Dell Inc.'; Model = 'Latitude 5490'; TotalPhysicalMemory = 8GB; PartOfDomain = $true; Domain = 'contoso.local'; Workgroup = ''; UserName = 'CONTOSO\tony'; SystemFamily = 'Latitude'; SystemSKUNumber = '0817' } }
    'Win32_ComputerSystemProduct' { P @{ IdentifyingNumber = 'ABC1234'; UUID = '4C4C4544-0042-3110-8030-B4C04F313233' } }
    'Win32_BIOS' { P @{ Manufacturer = 'Dell Inc.'; SMBIOSBIOSVersion = '1.18.0'; SerialNumber = 'ABC1234'; ReleaseDate = $__Maint.AddYears(-4) } }
    'Win32_Processor' { P @{ Name = 'Intel(R) Core(TM) i5-8350U'; NumberOfCores = 4; NumberOfLogicalProcessors = 8 } }
    'Win32_SystemEnclosure' { P @{ ChassisTypes = @(10); SMBIOSAssetTag = '' } }
    'Win32_PerfFormattedData_PerfOS_Processor' { P @{ Name = '_Total'; PercentProcessorTime = 72 } }
    'Win32_PerfFormattedData_PerfDisk_PhysicalDisk' { P @{ Name = '_Total'; AvgDisksecPerTransfer = 0.041; CurrentDiskQueueLength = 3; PercentDiskTime = 88 } }
    'Win32_LogicalDisk' { P @{ DeviceID = 'C:'; Size = 237GB; FreeSpace = 9GB; DriveType = 3 } }
    'Win32_PageFileUsage' { P @{ Name = 'C:\pagefile.sys'; AllocatedBaseSize = 4096; CurrentUsage = 1800; PeakUsage = 3900 } }
    'Win32_StartupCommand' { 1..17 | ForEach-Object { P @{ Name = "Prog$_"; Location = 'HKCU\...\Run'; Command = "C:\prog$_.exe" } } }
    'Win32_PhysicalMemory' { P @{ DeviceLocator = 'DIMM1'; Capacity = 4GB; Speed = 2400; ConfiguredClockSpeed = 2400; Manufacturer = 'Samsung'; PartNumber = 'M471A5244'; SerialNumber = '1234' }; P @{ DeviceLocator = 'DIMM2'; Capacity = 4GB; Speed = 2666; ConfiguredClockSpeed = 2400; Manufacturer = 'Hynix'; PartNumber = 'HMA851'; SerialNumber = '5678' } }
    'Win32_PnPEntity' { P @{ Name = 'Périphérique inconnu'; PNPClass = 'Unknown'; ConfigManagerErrorCode = 28 }; P @{ Name = 'Carte Bluetooth'; PNPClass = 'Bluetooth'; ConfigManagerErrorCode = 22 } }
    'Win32_Printer' { P @{ Name = 'COPIEUR AGENCE'; Default = $true; WorkOffline = $true; Network = $true; PortName = 'IP_10.0.0.50'; DriverName = 'Kyocera' } }
    'Win32_NetworkConnection' { P @{ LocalName = 'S:'; RemoteName = '\\srv\partage'; ConnectionState = 'Disconnected'; Status = 'Unavailable' } }
    'Win32_DiskDrive' { P @{ Model = 'Samsung SSD'; SerialNumber = 'S3Z'; Size = 256GB; InterfaceType = 'SCSI' } }
    'Win32_Battery' { P @{ Name = 'DELL 1VX1H'; EstimatedChargeRemaining = 87 } }
    'Win32_NetworkAdapter' { P @{ Name = 'Intel Ethernet'; MACAddress = '00:11:22:33:44:55' } }
    'MSStorageDriver_FailurePredictStatus' { P @{ PredictFailure = $false } }
    'BatteryStaticData' { P @{ DesignedCapacity = 68000; ManufactureName = 'SMP'; SerialNumber = '1234' } }
    'BatteryFullChargedCapacity' { P @{ FullChargedCapacity = 39000 } }
    'WmiMonitorID' { P @{ ManufacturerName = [int[]][char[]]'DEL'; UserFriendlyName = [int[]][char[]]'DELL P2419H'; SerialNumberID = [int[]][char[]]'CN0ABC'; YearOfManufacture = 2020 } }
    'AntiVirusProduct' { P @{ displayName = 'Windows Defender'; productState = 397568 }; P @{ displayName = 'Sophos Endpoint'; productState = 266240 } }
    default { $null }
  }
}
function Invoke-CimMethod { }
function Get-PhysicalDisk { P @{ FriendlyName = 'ST1000LM035'; MediaType = 'HDD'; Size = 1TB; HealthStatus = 'Warning'; OperationalStatus = 'OK'; BusType = 'SATA'; SerialNumber = 'WD123' } }
function Get-StorageReliabilityCounter { P @{ Wear = 0; Temperature = 41; PowerOnHours = 21000; ReadErrorsUncorrected = 3 } }
function Get-WinEvent {
  param([hashtable]$FilterHashtable, [string]$LogName, [string]$FilterXPath, [int]$MaxEvents)
  $ln = if ($FilterHashtable) { $FilterHashtable.LogName } else { $LogName }
  $id = if ($FilterHashtable) { $FilterHashtable.Id } else { $null }
  if ($ln -match 'Diagnostics-Performance') { $e = P @{ TimeCreated = $__Maint.AddDays(-1) }; $e | Add-Member ScriptMethod ToXml { '<Event><EventData><Data Name="BootTime">95000</Data></EventData></Event>' }; return $e }
  if ($id -eq 41) { $e = P @{ TimeCreated = $__Maint.AddDays(-2); Id = 41; Level = 1; LevelDisplayName = 'Critique'; Message = 'Le système a redémarré sans arrêt correct.'; ProviderName = 'Microsoft-Windows-Kernel-Power' }; $e | Add-Member ScriptMethod ToXml { '<Event><EventData><Data Name="BugcheckCode">0</Data></EventData></Event>' }; return $e }
  if ($id -eq 6008) { return P @{ TimeCreated = $__Maint.AddDays(-2); Id = 6008; Message = "L'arrêt système précédent n'était pas prévu."; ProviderName = 'EventLog' } }
  if ($ln -eq 'System') { return @((P @{ TimeCreated = $__Maint.AddHours(-5); Id = 7; Level = 2; LevelDisplayName = 'Erreur'; ProviderName = 'disk'; Message = 'Le périphérique a un bloc défectueux.' }), (P @{ TimeCreated = $__Maint.AddHours(-6); Id = 1058; Level = 2; LevelDisplayName = 'Erreur'; ProviderName = 'Microsoft-Windows-GroupPolicy'; Message = 'Échec du traitement de la stratégie de groupe.' })) }
  if ($ln -eq 'Application') { return P @{ TimeCreated = $__Maint.AddDays(-1); Id = 1000; ProviderName = 'Application Error'; Message = 'Nom de l''application défaillante : OUTLOOK.EXE, version : 16.0, nom du module défaillant : mso.dll' } }
  $null
}
function Get-Process { P @{ ProcessName = 'chrome'; CPU = 512.3; WorkingSet64 = 900MB; Id = 1234 }; P @{ ProcessName = 'OUTLOOK'; CPU = 120.1; WorkingSet64 = 400MB; Id = 2222 } }
function Get-Service { param($Name) P @{ Name = 'Spooler'; DisplayName = 'Spouleur d''impression'; Status = 'Running'; StartType = 'Automatic' } }
function Get-NetAdapter { param([switch]$Physical) P @{ Name = 'Ethernet'; Status = 'Up'; TransmitLinkSpeed = 100000000; FullDuplex = $true; PhysicalMediaType = '802.3'; MediaType = '802.3'; InterfaceDescription = 'Intel(R) Ethernet'; ifIndex = 5 } }
function Get-NetIPConfiguration { P @{ InterfaceAlias = 'Ethernet'; IPv4Address = (P @{ IPAddress = '10.0.0.42' }); IPv4DefaultGateway = (P @{ NextHop = '10.0.0.254' }); DNSServer = @((P @{ AddressFamily = 2; ServerAddresses = @('10.0.0.10', '10.0.0.11') })) } }
function Get-DnsClientServerAddress { P @{ InterfaceAlias = 'Ethernet'; ServerAddresses = @('10.0.0.10', '10.0.0.11') } }
function Get-NetAdapterStatistics { P @{ ReceivedBytes = 1000000; SentBytes = 500000; ReceivedPacketErrors = 150; OutboundPacketErrors = 0; ReceivedDiscardedPackets = 2; OutboundDiscardedPackets = 0 } }
function Get-NetRoute { P @{ NextHop = '10.0.0.254'; InterfaceIndex = 5; RouteMetric = 0 } }
function Get-NetIPAddress { P @{ IPAddress = '10.0.0.42'; PrefixLength = 24 } }
function Get-NetNeighbor { @() }
function Get-VpnConnection { @() }
function Get-NetConnectionProfile { P @{ InterfaceAlias = 'Ethernet'; Name = 'contoso.local'; NetworkCategory = 'DomainAuthenticated' } }
function Resolve-DnsName { param($Name) if ($Name -match 'contoso') { throw 'DNS name does not exist' }; P @{ IPAddress = '1.2.3.4' } }
function Get-Printer { P @{ Name = 'COPIEUR AGENCE'; Type = 'Local'; DriverName = 'Microsoft IPP Class Driver'; PortName = 'IP_10.0.0.50'; PrinterStatus = 'Offline'; WorkOffline = $true; Shared = $false } }
function Get-PrinterPort { P @{ Name = 'IP_10.0.0.50'; PrinterHostAddress = '127.0.0.1'; PortNumber = 9 } }
function Get-PrintJob { param($PrinterName) P @{ PrinterName = $PrinterName; Id = 4; DocumentName = 'Facture.pdf'; JobStatus = 'Error'; SubmittedTime = $__Maint.AddHours(-3); TotalPages = 2 } }
function Get-PrinterDriver { P @{ Name = 'Microsoft IPP Class Driver'; Manufacturer = 'Microsoft'; DriverVersion = 2814750890000384; PrinterEnvironment = 'Windows x64' } }
function Get-MpComputerStatus { P @{ AntivirusEnabled = $true; RealTimeProtectionEnabled = $true; AntivirusSignatureAge = 12; AntivirusSignatureLastUpdated = $__Maint.AddDays(-12); QuickScanEndTime = $__Maint.AddDays(-3); FullScanEndTime = $null; AMRunningMode = 'Normal'; IsTamperProtected = $true } }
function Get-MpThreatDetection { P @{ ThreatID = 1; InitialDetectionTime = $__Maint.AddDays(-4); Resources = @('file:_C:\Users\tony\Downloads\crack.exe'); ActionSuccess = $true } }
function Get-MpThreat { P @{ ThreatName = 'HackTool:Win32/Keygen' } }
function Get-BitLockerVolume { P @{ MountPoint = 'C:'; VolumeStatus = 'FullyDecrypted'; ProtectionStatus = 'Off'; EncryptionPercentage = 0; EncryptionMethod = 'None'; KeyProtector = @() } }
function Get-HotFix { P @{ HotFixID = 'KB5034441'; InstalledOn = $__Maint.AddDays(-75); Description = 'Security Update' } }
function Get-NetFirewallProfile { P @{ Name = 'Domain'; Enabled = $true; DefaultInboundAction = 'Block' }; P @{ Name = 'Public'; Enabled = $false; DefaultInboundAction = 'Block' } }
function Get-LocalGroupMember { P @{ Name = 'CONTOSO\tony'; ObjectClass = 'Utilisateur'; PrincipalSource = 'ActiveDirectory' }; P @{ Name = 'PC-TEST\Administrateur'; ObjectClass = 'Utilisateur'; PrincipalSource = 'Local' } }
function Get-LocalUser { P @{ Name = 'Administrateur'; SID = 'S-1-5-21-1-500'; Enabled = $true } }
function Get-SmbServerConfiguration { P @{ EnableSMB1Protocol = $true } }
function Test-ComputerSecureChannel { $false }
function Get-AppxPackage { P @{ Name = 'SpotifyAB.SpotifyMusic'; Version = '1.2'; Publisher = 'CN=Spotify AB, O=Spotify'; IsFramework = $false; SignatureKind = 'Store' } }
function Get-ItemProperty {
  param([Parameter(Position = 0)]$Path, [string]$Name)
  $p = [string]($Path | Select-Object -First 1)
  if ($p -match 'Uninstall') { return @((P @{ DisplayName = 'Adobe Flash Player 32 NPAPI'; DisplayVersion = '32.0'; Publisher = 'Adobe'; InstallDate = '20190101' }), (P @{ DisplayName = 'TeamViewer'; DisplayVersion = '15.1'; Publisher = 'TeamViewer'; InstallDate = '20240301' }), (P @{ DisplayName = 'AnyDesk'; DisplayVersion = '8.0'; Publisher = 'AnyDesk'; InstallDate = '20250101' }), (P @{ DisplayName = '7-Zip 19.00'; DisplayVersion = '19.00'; Publisher = 'Igor Pavlov' }), (P @{ DisplayName = 'Microsoft Office Professionnel Plus 2016'; DisplayVersion = '16.0'; Publisher = 'Microsoft' })) }
  if ($p -match 'ClickToRun') { return P @{ VersionToReport = '16.0.17928.20156'; Platform = 'x64'; ProductReleaseIds = 'O365BusinessRetail'; UpdateChannel = 'http://officecdn/492350f6-3a01-4f97-b9c0-c7c6ddf67d60' } }
  if ($p -match 'Terminal Server\\WinStations') { return P @{ UserAuthentication = 0 } }
  if ($p -match 'Terminal Server') { return P @{ fDenyTSConnections = 0 } }
  if ($p -match 'Policies\\System') { return P @{ EnableLUA = 1 } }
  if ($p -match 'Windows NT\\CurrentVersion') { return P @{ DisplayVersion = '22H2' } }
  if ($p -match 'Internet Settings') { return P @{ ProxyEnable = 0 } }
  $null
}
function Test-Path { param([Parameter(Position = 0)]$Path, $LiteralPath) $x = if ($LiteralPath) { $LiteralPath } else { $Path }; if ([string]$x -match '^HK|RebootRequired') { return ([string]$x -match 'RebootRequired|Classes\\consoleit') }; Microsoft.PowerShell.Management\Test-Path -LiteralPath $x }
function Get-ChildItem { param([Parameter(Position = 0)]$Path, $Include, [switch]$Recurse, [switch]$File, [switch]$Directory, [switch]$Force, $Filter, $LiteralPath) @() }
function Get-Item { param([Parameter(Position = 0)]$Path, $LiteralPath) $x = if ($LiteralPath) { $LiteralPath } else { $Path }; if ([string]$x -match '^HK|MEMORY') { return $null }; Microsoft.PowerShell.Management\Get-Item -LiteralPath $x }
# commandes natives Windows
function powercfg { "Les états de veille suivants sont disponibles sur ce système :`n    Veille (S3)`n`nLes états de veille suivants ne sont pas disponibles sur ce système :`n    Veille (S1)`n`nIndex du paramètre de courant alternatif actuel : 0x00000000`nIndex du paramètre de courant continu actuel : 0x00000000`n[PROCESS] \Device\HarddiskVolume3\chrome.exe" }
function netsh { '' }
function nltest { "           DC: \\SRV-AD01.contoso.local`n      Address: \\10.0.0.10`n Client Site Name: Rennes" }
function w32tm { "Source : Local CMOS Clock" }
function gpresult { "Dernière application de la stratégie de groupe : 10/10/2026 à 09:12:44" }
function manage-bde { 'BitLocker' }
function ipconfig { '' }
