$env:COMPUTERNAME = 'PC-TECH'; $env:USERDOMAIN = 'CONTOSO'; $env:USERNAME = 'tony'
$script:Reponses = New-Object System.Collections.Queue
function Read-Host($p) { if ($script:Reponses.Count) { $a = $script:Reponses.Dequeue() } else { $a = '' }; Write-Host "$p > $a" -ForegroundColor DarkGray; $a }
function Invoke-Item($p) { Write-Host "[ouvrir] $p" }
function Get-DossierRapports { $d = (Join-Path ([IO.Path]::GetTempPath()) 'console-it-tests'); New-Item -ItemType Directory $d -Force | Out-Null; $d }
function Test-Ssh { $true }
$now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
function Invoke-SshLot($cible, $cmds) {
  # vérifie la construction de la commande comme le ferait le moteur
  $seq = ($cmds.Keys | ForEach-Object { 'echo @@@' + $_ + '@@@; { ' + $cmds[$_] + '; } 2>&1' }) -join '; '
  $script:SeqVue = $seq
  if ([string]$cible -match 'esx2') { return [pscustomobject]@{ Ok = $false; Code = 255; Brut = 'ssh: connect to host esx2 port 22: Connection timed out'; Sorties = $null } }
  $o = [ordered]@{}; foreach ($k in $cmds.Keys) { $o[$k] = $script:FXS[$k] }
  [pscustomobject]@{ Ok = $true; Code = 0; Brut = ''; Sorties = $o }
}
if ($script:TYPE -eq 'ESXi') {
  'Contoso SA', 'esx1.contoso.local, esx2', 'root', '22' | ForEach-Object { $script:Reponses.Enqueue($_) }
  $script:FXS = @{
    ver = "   Product: VMware ESXi`n   Version: 7.0.3`n   Build: Releasebuild-21930508`n   Update: 3`n   Patch: 95"
    name = "   Domain Name: contoso.local`n   Fully Qualified Domain Name: esx1.contoso.local`n   Host Name: esx1"
    up = '8640000000000'
    sum = "(vim.host.Summary) {`n   hardware = (vim.host.Summary.HardwareSummary) {`n      memorySize = 274877906944,`n      cpuMhz = 2400,`n      numCpuCores = 16,`n   },`n   rebootRequired = false,`n   quickStats = (vim.host.Summary.QuickStats) {`n      overallCpuUsage = 9800,`n      overallMemoryUsage = 236000,`n   },`n   overallStatus = `"yellow`",`n   runtime = { inMaintenanceMode = false, }`n}"
    cert = "subject=CN = esx1.contoso.local`nnotAfter=Jan  5 10:00:00 2027 GMT"
    ds = "Mount Point,Volume Name,UUID,Mounted,Type,Size,Free,`n/vmfs/volumes/aaa,DS-SSD,aaa,true,VMFS-6,2199023255552,197912092999,`n/vmfs/volumes/bbb,DS-SATA,bbb,true,VMFS-6,4398046511104,2638827906662,`n/vmfs/volumes/ccc,OSDATA-x,ccc,true,VMFS-L,128849018880,100000000000,"
    vms = "Vmid      Name                   File                          Guest OS          Version   Annotation`n1      SRV-AD01        [DS-SSD] SRV-AD01/SRV-AD01.vmx        windows2019srv_64Guest   vmx-15`n2      SRV FICHIERS   [DS-SATA] SRV FICHIERS/SRV FICHIERS.vmx   windows2019srv_64Guest   vmx-11   Serveur de fichiers"
    pwr = "PWR|1|Powered on`nPWR|2|Powered off"
    snap = "SNAP|1|Avant mise a jour|1/15/2025 10:32:11`nSNAP|2|VEEAM BACKUP TEMPORARY SNAPSHOT|$((Get-Date).AddDays(-5).ToString('M/d/yyyy H:mm:ss', [Globalization.CultureInfo]::InvariantCulture))"
    nic = "AdminStatus,Description,Driver,Duplex,Link,LinkStatus,MACAddress,MTU,Name,PCIDevice,Speed,`nUp,Intel X710,i40en,Full,Up,Up,00:11:22:33:44:55,1500,vmnic0,0000:3b:00.0,10000,`nUp,Intel X710,i40en,Half,Down,Down,00:11:22:33:44:56,1500,vmnic1,0000:3b:00.1,0,"
    vmk = "AddressType,DHCPDNS,Gateway,IPv4Address,IPv4Broadcast,IPv4Netmask,Name,`nSTATIC,false,10.0.0.254,10.0.0.21,10.0.0.255,255.255.255.0,vmk0,"
    vsw = "vSwitch0`n   Name: vSwitch0`n   Uplinks: vmnic0, vmnic1`n   Portgroups: VM Network, Management Network"
    dev = "Device,DisplayName,IsLocal,IsSSD,Size,Status,`nnaa.600,Local DELL Disk (naa.600),true,true,2097152,on,"
    path = "Adapter,Device,RuntimeName,State,`nvmhba0,naa.600,vmhba0:C2:T0:L0,active,"
    ipmi = 'IPMI-INDISPONIBLE'
    ntp = "   Enabled: false`n   Servers:"
    syslg = "   Local Log Output: /scratch/log`n   Remote Host: <none>"
    lic = "[`n  serial: 0J4XX-XXXXX`n  vmodl key: esx.enterprisePlus.cpuPackage`n  name: VMware vSphere 7 Enterprise Plus`n  ]"
    log = "2025-03-01T10:00:00Z cpu3:2097)WARNING: NMP: nmp_DeviceRequestFastDeviceProbe: NMP device naa.600 state in doubt; requested fast path state update..."
    date = [string]($now - 145)
  }
}
if ($script:TYPE -eq 'vCenter') {
  'Contoso SA', 'vcenter.contoso.local', 'root', '22' | ForEach-Object { $script:Reponses.Enqueue($_) }
  $script:FXS = @{
    ver = 'VMware VirtualCenter 7.0.3 build-22357613'
    svc = "Running:`n applmgmt lookupsvc lwsmd vmafdd vmcad vmdird vmware-envoy vmware-pod vmware-rhttpproxy vmware-sps vmware-stsd vmware-vapi-endpoint vmware-vmon vmware-vpostgres vmware-vpxd-svcs vsphere-ui`nStopped:`n vmcam vmware-imagebuilder vmware-netdumper vmware-rbd-watchdog vmware-vcha vpxd vmware-content-library vmware-perfcharts"
    cert = "CERT|MACHINE_SSL_CERT|__MACHINE_CERT|Mar 12 10:00:00 2027 GMT`nCERT|vpxd|vpxd|$((Get-Date).AddDays(20).ToString('MMM d HH:mm:ss yyyy', [Globalization.CultureInfo]::InvariantCulture)) GMT`nCERT|TRUSTED_ROOTS|abcd|Feb  1 00:00:00 2022 GMT`nCERT|BACKUP_STORE|bkp|Jan  1 00:00:00 2020 GMT"
    df = "Filesystem     1024-blocks    Used Available Capacity Mounted on`n/dev/sda3         11208380 6215872   4404912      59% /`n/dev/mapper/log_vg-log 10255636 9416228 298736 97% /storage/log`n/dev/mapper/db_vg-db 10255636 8416228 1298736 84% /storage/db"
    up = ' 10:12:01 up 412 days,  3:01,  0 users,  load average: 0.42, 0.51, 0.55'
    root = "Last password change                                    : Jan 10, 2026`nPassword expires                                        : $((Get-Date).AddDays(10).ToString('MMM dd, yyyy', [Globalization.CultureInfo]::InvariantCulture))`nAccount expires                                         : never"
    ntp = '      Local time: Sat 2026-10-10'
    dns = "nameserver 10.0.0.10`n`nvcenter.contoso.local"
    bkp = ''
    date = [string]($now - 3)
  }
}
