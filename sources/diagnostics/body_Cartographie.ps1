# ==================================================================================
#  CARTOGRAPHIE RÉSEAU (100 % PowerShell natif, sans nmap)
#  Découverte (ping + ARP), ports TCP courants, fabricant (MAC), système (TTL), classement.
# ==================================================================================
$ErrorActionPreference = 'SilentlyContinue'
$script:PortTimeoutMs = 500; $script:PingTimeoutMs = 700
$Rubriques = [ordered]@{
  'synth'  = @('Vue d''ensemble', '🗺️')
  'infra'  = @('Infrastructure', '🖧')
  'postes' = @('Postes et serveurs', '🖥️')
  'autres' = @('Imprimantes, caméras et objets', '🖨️')
  'risque' = @('Services sensibles', '⚠️')
}
$Prerequis = "À lancer depuis un poste du réseau à cartographier. Aucune installation ni droit administrateur nécessaire. N'analyser que des réseaux dont on a la charge ou l'autorisation. La détection du système (TTL) et du fabricant (MAC) est indicative ; les appareils derrière un routeur n'ont pas d'adresse MAC visible."

# ---------------------------------------------------------------------------
# Tables de correspondance (ports -> langage clair, ports sensibles)
# ---------------------------------------------------------------------------
$PortLabels = @{
    21="Transfert de fichiers (FTP)"; 22="Administration a distance securisee (SSH)";
    23="Administration a distance NON securisee (Telnet)"; 25="Envoi d'e-mails";
    53="Annuaire internet (DNS)"; 80="Page web (non securisee)";
    110="Reception d'e-mails"; 135="Service systeme Windows";
    139="Partage de fichiers Windows"; 143="Reception d'e-mails";
    161="Supervision reseau (SNMP)"; 389="Annuaire d'entreprise (LDAP)";
    443="Page web securisee (HTTPS)"; 445="Partage de fichiers Windows";
    515="Impression"; 554="Flux video (camera)"; 587="Envoi d'e-mails";
    631="Impression"; 902="Service VMware ESXi"; 903="Service VMware ESXi";
    993="Reception d'e-mails"; 995="Reception d'e-mails";
    1300="Administration pare-feu (Stormshield)";
    1433="Base de donnees Microsoft SQL"; 1883="Domotique (MQTT)";
    3306="Base de donnees MySQL"; 3389="Bureau a distance Windows (RDP)";
    4433="Administration pare-feu (SonicWall)";
    5000="Interface NAS Synology"; 5001="Interface NAS Synology";
    5432="Base de donnees PostgreSQL"; 5900="Prise de controle a distance (VNC)";
    6379="Base de donnees Redis"; 8006="Interface Proxmox";
    8080="Application web"; 8123="Home Assistant (domotique)";
    8291="Administration Mikrotik (Winbox)";
    8443="Application web securisee"; 9100="Impression"; 27017="Base de donnees MongoDB"
}
$Sensitive = @{
    23="Telnet n'est pas chiffre : a desactiver si possible.";
    21="FTP transmet souvent les mots de passe en clair.";
    3389="Bureau a distance ouvert : cible classique d'attaques.";
    5900="Prise de controle a distance : a proteger par un mot de passe fort.";
    445="Partage de fichiers Windows : historiquement vise par des virus (ex. WannaCry).";
    161="Supervision reseau : souvent laissee avec le mot de passe par defaut.";
    3306="Base de donnees accessible sur le reseau : normalement a restreindre.";
    5432="Base de donnees accessible sur le reseau : normalement a restreindre.";
    1433="Base de donnees accessible sur le reseau : normalement a restreindre.";
    27017="Base de donnees accessible sur le reseau : normalement a restreindre.";
    6379="Base de donnees accessible sur le reseau : normalement a restreindre."
}

function Get-PortLabel([int]$p, [string]$svc) {
    if ($PortLabels.ContainsKey($p)) { return $PortLabels[$p] }
    if ($svc) { return "Service $svc (port $p)" }
    return "Port $p"
}

function ConvertTo-HtmlText([string]$s) {
    if ($null -eq $s) { return "" }
    return $s.Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;').Replace('"','&quot;')
}

# ---------------------------------------------------------------------------
# Classification d'un appareil a partir de ses ports / OS / fabricant
# Renvoie : Type, Icon (entite HTML), Desc
# ---------------------------------------------------------------------------
function Get-DeviceClass($h) {
    $ports  = $h.Ports.Keys
    $vendor = ("" + $h.Vendor).ToLower()
    $os     = ("" + $h.Os).ToLower()
    function Has { param([int[]]$list) foreach ($x in $list) { if ($ports -contains $x) { return $true } } return $false }

    $netVendor = $vendor -match 'cisco|meraki|tp.?link|alcatel|aruba|ubiquiti|unifi|mikrotik|juniper|extreme|zyxel|d.?link|ruckus|netgear'
    $fwVendor  = $vendor -match 'sonicwall|stormshield|netasq|fortinet|fortigate|palo.?alto|watchguard|check.?point|sophos'
    $vmVendor  = $vendor -match 'vmware'

    if ($fwVendor -or (Has 1300,4433)) {
        return [pscustomobject]@{ Type="Pare-feu (firewall)"; Icon="&#128737;&#65039;"; Desc="Protege le reseau et filtre les connexions entrantes et sortantes." }
    }
    if ($netVendor -or $ports -contains 8291) {
        return [pscustomobject]@{ Type="Commutateur / Equipement reseau"; Icon="&#128256;"; Desc="Switch, routeur ou point d'acces qui relie les appareils du reseau." }
    }
    if ((Has 902,903) -or ($vmVendor -and $ports -contains 443 -and -not ($ports -contains 3389))) {
        return [pscustomobject]@{ Type="Hyperviseur VMware (ESXi)"; Icon="&#129521;"; Desc="Serveur qui heberge plusieurs machines virtuelles." }
    }
    if ($vmVendor) {
        return [pscustomobject]@{ Type="Machine virtuelle (VMware)"; Icon="&#128421;"; Desc="Serveur virtuel heberge sur un hyperviseur VMware." }
    }
    if ($h.IsGateway -or ($ports -contains 53 -and (Has 80,443))) {
        return [pscustomobject]@{ Type="Box internet / Routeur"; Icon="&#128225;"; Desc="C'est la porte d'entree vers internet de ton reseau." }
    }
    if (Has 9100,515,631) {
        return [pscustomobject]@{ Type="Imprimante reseau"; Icon="&#128424;"; Desc="Imprimante accessible par tout le reseau." }
    }
    if ($ports -contains 554 -or $vendor -match "hikvision|dahua|axis") {
        return [pscustomobject]@{ Type="Camera de surveillance"; Icon="&#128247;"; Desc="Camera qui diffuse un flux video sur le reseau." }
    }
    if ((Has 5000,5001) -or $vendor -match "synology|qnap" -or ($ports -contains 445 -and $ports -contains 548)) {
        return [pscustomobject]@{ Type="Serveur de stockage (NAS)"; Icon="&#128190;"; Desc="Stockage de fichiers partage sur le reseau." }
    }
    if ($ports -contains 8006 -or (Has 902,903)) {
        return [pscustomobject]@{ Type="Serveur de virtualisation"; Icon="&#129521;"; Desc="Machine qui heberge plusieurs serveurs virtuels." }
    }
    if (Has 3306,5432,1433,27017,6379,5984) {
        return [pscustomobject]@{ Type="Serveur de base de donnees"; Icon="&#128451;"; Desc="Stocke des donnees pour des applications." }
    }
    if ($os -match "windows" -or $ports -contains 3389 -or ($ports -contains 445 -and $ports -contains 139)) {
        return [pscustomobject]@{ Type="Ordinateur Windows"; Icon="&#128421;"; Desc="Poste de travail ou serveur Windows." }
    }
    if ($os -match "mac|darwin" -or ($vendor -match "apple" -and $ports.Count -ge 2)) {
        return [pscustomobject]@{ Type="Ordinateur Apple (Mac)"; Icon="&#128421;"; Desc="Ordinateur de la gamme Apple." }
    }
    if ($vendor -match "apple|samsung|xiaomi|huawei|google" -and $ports.Count -lt 3) {
        return [pscustomobject]@{ Type="Smartphone / Tablette"; Icon="&#128241;"; Desc="Appareil mobile connecte au reseau." }
    }
    if ($ports -contains 1883 -or $ports -contains 8123) {
        return [pscustomobject]@{ Type="Objet connecte / Domotique"; Icon="&#127968;"; Desc="Appareil de maison connectee." }
    }
    if (Has 80,443,8080,8443) {
        return [pscustomobject]@{ Type="Serveur web / Application"; Icon="&#127760;"; Desc="Heberge un site ou une application web." }
    }
    if ($ports -contains 22) {
        return [pscustomobject]@{ Type="Serveur ou appareil Linux"; Icon="&#128039;"; Desc="Machine administrable a distance (Linux/Unix)." }
    }
    return [pscustomobject]@{ Type="Appareil inconnu"; Icon="&#10067;"; Desc="Type non identifie automatiquement." }
}

# ---------------------------------------------------------------------------
# Acquisition native (sans nmap) : ports a tester + table OUI fabricants
# ---------------------------------------------------------------------------
$script:ScanPorts = @(21,22,23,25,53,80,110,135,139,143,389,443,445,515,548,554,
    587,631,902,903,993,995,1300,1433,1883,3306,3389,4433,5000,5001,5432,5900,6379,
    8006,8080,8123,8291,8443,9100,27017)

# Prefixes OUI (3 premiers octets MAC) -> fabricant. Couverture partielle mais
# enrichie pour l'infrastructure reseau (switch/routeur/AP, pare-feu, hyperviseurs).
# Un fabricant absent n'empeche pas la classification : les ports prennent le relais.
$script:OuiVendors = @{
    # --- Stockage / NAS ---
    '001132'='Synology'; '00089B'='QNAP'; '245EBE'='QNAP';
    # --- Cameras ---
    'C056E3'='Hikvision'; '4419B6'='Hikvision'; 'BCAD28'='Hikvision';
    '3CEF8C'='Dahua'; '9002A9'='Dahua'; '00408C'='Axis'; 'ACCC8E'='Axis';
    # --- Postes / mobiles ---
    '001B63'='Apple'; '0025BC'='Apple'; '3C0754'='Apple'; '3C22FB'='Apple';
    'ACBC32'='Apple'; 'F09938'='Apple'; 'A45E60'='Apple'; 'DCA904'='Apple'; 'F4F15A'='Apple';
    '0012FB'='Samsung'; '342387'='Samsung'; '5C0A5B'='Samsung'; '781FDB'='Samsung';
    '8C7712'='Samsung'; 'BC1485'='Samsung'; 'E8508B'='Samsung';
    '286C07'='Xiaomi'; '640980'='Xiaomi'; '508F4C'='Xiaomi';
    '001882'='Huawei'; '4846FB'='Huawei'; '80FB06'='Huawei';
    '3C5AB4'='Google'; 'F4F5D8'='Google'; 'DAA119'='Google';
    '001B78'='HP'; '3CD92B'='HP'; '705A0F'='HP'; 'D85ED3'='HP'; '9CB654'='HP'; '0025B3'='HP';
    '001422'='Dell'; '180373'='Dell'; 'B8CA3A'='Dell'; 'F8BC12'='Dell'; '001EC9'='Dell';
    '001B21'='Intel'; '3C970E'='Intel'; '94659C'='Intel'; 'A08869'='Intel';
    'B827EB'='Raspberry Pi'; 'DCA632'='Raspberry Pi'; 'E45F01'='Raspberry Pi'; '28CDC1'='Raspberry Pi';
    '00155D'='Microsoft (Hyper-V)'; '3417EB'='Microsoft'; '7C1E52'='Microsoft';
    # --- Cisco / Meraki ---
    '00000C'='Cisco'; '000142'='Cisco'; '000143'='Cisco'; '000A41'='Cisco'; '000A8A'='Cisco';
    '000E38'='Cisco'; '000F34'='Cisco'; '001120'='Cisco'; '0011BB'='Cisco'; '001AA1'='Cisco';
    '001B0C'='Cisco'; '001B54'='Cisco'; '001D45'='Cisco'; '001E14'='Cisco'; '002414'='Cisco';
    '0021D8'='Cisco'; '00257F'='Cisco'; '2C3ECF'='Cisco'; '58971E'='Cisco'; '6C416A'='Cisco';
    '88F031'='Cisco'; 'F4CFE2'='Cisco';
    '00180A'='Cisco Meraki'; '881544'='Cisco Meraki'; 'E0553D'='Cisco Meraki'; '0C8DDB'='Cisco Meraki'; 'AC17C8'='Cisco Meraki';
    # --- TP-Link ---
    '001D0F'='TP-Link'; '50C7BF'='TP-Link'; 'EC086B'='TP-Link'; '14CC20'='TP-Link';
    'A0F3C1'='TP-Link'; 'B0487A'='TP-Link'; 'C46E1F'='TP-Link'; 'F4F26D'='TP-Link';
    '30DE4B'='TP-Link'; '6032B1'='TP-Link'; '98DAC4'='TP-Link'; 'AC84C6'='TP-Link'; '5C628B'='TP-Link';
    # --- Alcatel-Lucent Enterprise (OmniSwitch / OmniAccess) ---
    '00809F'='Alcatel-Lucent'; '008039'='Alcatel-Lucent'; '00D095'='Alcatel-Lucent';
    '2CFAA2'='Alcatel-Lucent'; '34E70B'='Alcatel-Lucent'; 'E8E732'='Alcatel-Lucent'; '80AA9D'='Alcatel-Lucent';
    # --- Ubiquiti (UniFi : switch/AP/routeur/firewall) ---
    '00156D'='Ubiquiti'; '24A43C'='Ubiquiti'; '788A20'='Ubiquiti'; 'FCECDA'='Ubiquiti';
    '0418D6'='Ubiquiti'; '44D9E7'='Ubiquiti'; '687251'='Ubiquiti'; '802AA8'='Ubiquiti';
    'B4FBE4'='Ubiquiti'; 'DC9FDB'='Ubiquiti'; 'F09FC2'='Ubiquiti'; '7483C2'='Ubiquiti';
    'E063DA'='Ubiquiti'; '18E829'='Ubiquiti'; '245A4C'='Ubiquiti';
    # --- Aruba (HPE Networking) ---
    '000B86'='Aruba (HPE)'; '6CF37F'='Aruba (HPE)'; '186472'='Aruba (HPE)'; '204C03'='Aruba (HPE)';
    '40E3D6'='Aruba (HPE)'; '84D47E'='Aruba (HPE)'; '94B40F'='Aruba (HPE)'; 'ACA31E'='Aruba (HPE)'; 'D8C7C8'='Aruba (HPE)';
    # --- MikroTik ---
    '4C5E0C'='MikroTik'; '64D154'='MikroTik'; '6C3B6B'='MikroTik'; '744D28'='MikroTik';
    'B869F4'='MikroTik'; 'C4AD34'='MikroTik'; 'D4CA6D'='MikroTik'; 'E48D8C'='MikroTik';
    '08555D'='MikroTik'; '2CC81B'='MikroTik'; '48A98A'='MikroTik'; 'DC2C6E'='MikroTik'; 'CC2DE0'='MikroTik';
    # --- Juniper ---
    '2C6BF5'='Juniper'; '3CFB48'='Juniper'; '5C5EAB'='Juniper'; '842FE9'='Juniper';
    '4C961C'='Juniper'; 'F4CC55'='Juniper'; 'F8C001'='Juniper'; '28A24B'='Juniper'; '002688'='Juniper';
    # --- Netgear ---
    '00095B'='Netgear'; '204E7F'='Netgear'; '9C3DCF'='Netgear'; '2C3033'='Netgear'; 'A040A0'='Netgear';
    # --- Pare-feu (firewall) ---
    '0006B1'='SonicWall'; '0017C5'='SonicWall'; '18B169'='SonicWall'; '2CB8ED'='SonicWall'; 'C0EAE4'='SonicWall';
    '00090F'='Fortinet'; '04D590'='Fortinet'; '085B0E'='Fortinet'; '704CA5'='Fortinet';
    '906CAC'='Fortinet'; 'E81CBA'='Fortinet'; 'FC609B'='Fortinet'; '90F652'='Fortinet';
    # --- VMware (hyperviseur / VM) ---
    '000C29'='VMware'; '005056'='VMware'; '000569'='VMware'; '001C14'='VMware';
    # --- Box / IoT / divers ---
    '001F3F'='AVM (FRITZ!Box)'; '3810D5'='AVM (FRITZ!Box)';
    '000E58'='Sonos'; '5CAAFD'='Sonos';
    '240AC4'='Espressif (IoT)'; '30AEA4'='Espressif (IoT)'; '84F3EB'='Espressif (IoT)';
    'A42BB0'='Technicolor'; '44322F'='Technicolor'
}

function Get-Vendor([string]$mac) {
    if (-not $mac) { return $null }
    $clean = ($mac -replace '[:-]', '').ToUpper()
    if ($clean.Length -lt 6) { return $null }
    $oui = $clean.Substring(0, 6)
    if ($script:OuiVendors.ContainsKey($oui)) { return $script:OuiVendors[$oui] }
    return $null
}

# Genere la liste des IP d'une plage CIDR (a.b.c.d/n). Limite a 4096 adresses.
function Get-IpRange([string]$cidr) {
    $parts = $cidr -split '/'
    $ipStr = $parts[0].Trim()
    $prefix = if ($parts.Count -gt 1) { [int]$parts[1] } else { 24 }
    if ($prefix -lt 8 -or $prefix -gt 32) { throw "Prefixe CIDR invalide : /$prefix" }
    $bytes = ([System.Net.IPAddress]::Parse($ipStr)).GetAddressBytes()
    [Array]::Reverse($bytes)
    $baseInt = [uint32][System.BitConverter]::ToUInt32($bytes, 0)
    $hostBits = 32 - $prefix
    $size = [uint32][math]::Pow(2, $hostBits)
    if ($size -gt 4096) { throw "Plage trop grande ($size adresses). Utilise un masque /20 ou plus precis." }
    $maskInt = [uint32]([math]::Pow(2, 32) - [math]::Pow(2, $hostBits))
    $network = [uint32]($baseInt -band $maskInt)
    $list = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $size; $i++) {
        if ($prefix -le 30 -and ($i -eq 0 -or $i -eq ($size - 1))) { continue }
        $cur = [uint32]($network + $i)
        $cb = [System.BitConverter]::GetBytes($cur); [Array]::Reverse($cb)
        $list.Add(([System.Net.IPAddress]::new($cb)).ToString())
    }
    return $list
}

# Ping sweep parallele (async) -> table @{ ip = ttl } des hotes qui repondent.
function Invoke-PingSweep($ips, [int]$timeout) {
    $alive = @{}
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($ip in $ips) {
        $png = New-Object System.Net.NetworkInformation.Ping
        $items.Add([pscustomobject]@{ Ip = $ip; Ping = $png; Task = $png.SendPingAsync($ip, $timeout) })
    }
    foreach ($it in $items) {
        try {
            $r = $it.Task.GetAwaiter().GetResult()
            if ($r.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                $ttl = 0; if ($r.Options) { $ttl = [int]$r.Options.Ttl }
                $alive[$it.Ip] = $ttl
            }
        } catch { }
        finally { try { $it.Ping.Dispose() } catch { } }
    }
    return $alive
}

# Table ARP (Get-NetNeighbor, fallback arp -a) -> @{ ip = mac }.
function Get-MacMap {
    $map = @{}
    try {
        $nb = Get-NetNeighbor -AddressFamily IPv4 -ErrorAction Stop |
              Where-Object { $_.LinkLayerAddress -and
                             $_.LinkLayerAddress -notmatch '^(00-00-00-00-00-00|FF-FF-FF-FF-FF-FF)$' -and
                             $_.State -in @('Reachable', 'Stale', 'Permanent', 'Delay', 'Probe') }
        foreach ($n in $nb) { $map[[string]$n.IPAddress] = [string]$n.LinkLayerAddress }
    } catch {
        foreach ($line in (arp -a)) {
            if ($line -match '(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\s+([0-9A-Fa-f]{2}([-:][0-9A-Fa-f]{2}){5})') {
                $map[$matches[1]] = ($matches[2] -replace ':', '-').ToUpper()
            }
        }
    }
    return $map
}

# Reverse DNS parallele -> @{ ip = hostname }.
function Resolve-Hostnames($ips) {
    $map = @{}
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($ip in $ips) {
        try { $items.Add([pscustomobject]@{ Ip = $ip; Task = [System.Net.Dns]::GetHostEntryAsync($ip) }) } catch { }
    }
    foreach ($it in $items) {
        try {
            $he = $it.Task.GetAwaiter().GetResult()
            if ($he -and $he.HostName) { $map[$it.Ip] = $he.HostName }
        } catch { }
    }
    return $map
}

# Teste une liste de ports TCP sur un hote (connexions async) -> ports ouverts.
function Test-HostPorts([string]$ip, $ports, [int]$timeout) {
    $open = New-Object System.Collections.Generic.List[int]
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($port in $ports) {
        $cli = New-Object System.Net.Sockets.TcpClient
        try { $items.Add([pscustomobject]@{ Port = $port; Client = $cli; Task = $cli.ConnectAsync($ip, $port) }) }
        catch { try { $cli.Dispose() } catch { } }
    }
    foreach ($it in $items) {
        try { if ($it.Task.Wait($timeout) -and $it.Client.Connected) { $open.Add([int]$it.Port) } } catch { }
        try { $it.Client.Close() } catch { }
    }
    return ($open | Sort-Object)
}

# Passerelle par defaut (pour marquer la box).
function Get-Gateway {
    try { return (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop |
                  Sort-Object RouteMetric | Select-Object -First 1).NextHop } catch { return $null }
}

# Orchestration : decouverte -> services -> objets hote (meme contrat que l'ancien parseur).
function Invoke-NativeScan([string]$target) {
    $ips = Get-IpRange $target
    Write-Host "Decouverte des hotes sur $($ips.Count) adresses (ping + ARP)..." -ForegroundColor Cyan
    $alive = Invoke-PingSweep $ips $script:PingTimeoutMs
    $macMap = Get-MacMap
    $aliveSet = New-Object System.Collections.Generic.List[string]
    foreach ($ip in $alive.Keys) { if (-not $aliveSet.Contains($ip)) { $aliveSet.Add($ip) } }
    foreach ($ip in $macMap.Keys) { if (($ips -contains $ip) -and -not $aliveSet.Contains($ip)) { $aliveSet.Add($ip) } }
    Write-Host "$($aliveSet.Count) hote(s) actif(s). Analyse des services..." -ForegroundColor Cyan
    $names = Resolve-Hostnames $aliveSet
    $gw = Get-Gateway
    $result = @()
    $idx = 0; $tot = [math]::Max(1, $aliveSet.Count)
    $ordered = $aliveSet | Sort-Object { try { [version]$_ } catch { $_ } }
    foreach ($ip in $ordered) {
        $idx++
        Write-Host ("`r  Analyse de {0} ({1}/{2})   " -f $ip, $idx, $tot) -NoNewline -ForegroundColor Gray
        $openPorts = Test-HostPorts $ip $script:ScanPorts $script:PortTimeoutMs
        $ports = @{}; foreach ($p in $openPorts) { $ports[[int]$p] = $null }
        $mac = $null; if ($macMap.ContainsKey($ip)) { $mac = $macMap[$ip] }
        $vendor = Get-Vendor $mac
        $ttl = 0; if ($alive.ContainsKey($ip)) { $ttl = [int]$alive[$ip] }
        $os = $null
        if ($ttl -ge 200) { $os = 'Equipement reseau' }
        elseif ($ttl -ge 100) { $os = 'Windows' }
        elseif ($ttl -ge 60) { $os = 'Linux/Unix' }
        $isGw = ($gw -and $ip -eq $gw) -or ($ip -like '*.1') -or ($ip -like '*.254')
        $hn = $null; if ($names.ContainsKey($ip)) { $hn = $names[$ip] }
        $result += [pscustomobject]@{ Ip = $ip; Mac = $mac; Vendor = $vendor; Os = $os; Hostname = $hn; Ports = $ports; IsGateway = $isGw }
    }
    Write-Host ""
    return $result
}
function Get-LocalNetwork {
  try {
    $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop | Sort-Object RouteMetric | Select-Object -First 1
    $cfg = Get-NetIPAddress -AddressFamily IPv4 -InterfaceIndex $route.InterfaceIndex -ErrorAction Stop | Where-Object { $_.IPAddress -notlike '169.254.*' } | Select-Object -First 1
    if ($cfg) {
      $pl = [int]$cfg.PrefixLength; if ($pl -lt 20) { $pl = 24 }   # au plus 4096 adresses ; /24 par défaut sur un très grand réseau
      $b = ([System.Net.IPAddress]::Parse($cfg.IPAddress)).GetAddressBytes(); [Array]::Reverse($b)
      $n = [System.BitConverter]::ToUInt32($b, 0) -band [uint32]([math]::Pow(2, 32) - [math]::Pow(2, 32 - $pl))
      $nb = [System.BitConverter]::GetBytes([uint32]$n); [Array]::Reverse($nb)
      return "$(([System.Net.IPAddress]::new($nb)).ToString())/$pl"
    }
  } catch { }
  $null
}

Show-Titre 'Cartographie réseau' "Découverte des appareils (ping + ARP), services ouverts, fabricant, type d'appareil, services sensibles.`nLecture seule : aucune modification, aucun outil installé."
$script:Cibles.Add($env:COMPUTERNAME)
$h = $env:COMPUTERNAME
$auto = Get-LocalNetwork
$Target = $null
while (-not $Target) {
  $rep = Ask-Text "Plage à analyser au format CIDR (ex. 192.168.1.0/24, 4096 adresses maximum)$(if ($auto) { '' } else { ' — réseau local non détecté' })" $auto
  if ($rep -match '^\d{1,3}(\.\d{1,3}){3}(/\d{1,2})?$') { try { $null = Get-IpRange $rep; $Target = $rep } catch { Write-Host "  $($_.Exception.Message)" -ForegroundColor Red } }
  elseif ($rep) { Write-Host '  Format attendu : a.b.c.d/nn' -ForegroundColor Yellow }
}
Show-Etape "Analyse de $Target (1 à 5 minutes selon la taille de la plage)"
$hotes = @()
try { $hotes = @(Invoke-NativeScan $Target) } catch { Add-Check -Rubrique 'synth' -Titre 'Analyse du réseau' -Statut 'CRIT' -Resume "Échec : $($_.Exception.Message)" -Cible $h }

Show-Etape 'Classement des appareils'
$rows = @(foreach ($x in $hotes) {
  $c = Get-DeviceClass $x
  $svc = @($x.Ports.Keys | Sort-Object | ForEach-Object { Get-PortLabel ([int]$_) $null } | Select-Object -Unique)
  $sens = @($x.Ports.Keys | Sort-Object | Where-Object { $Sensitive.ContainsKey([int]$_) })
  [pscustomobject]@{ IP = $x.Ip; Nom = $x.Hostname; Type = $c.Type; Fabricant = $x.Vendor; Systeme = $x.Os; MAC = $x.Mac; Ports = (($x.Ports.Keys | Sort-Object) -join ', '); Services = ($svc -join ' · '); Sensibles = $sens }
})
$rows = @($rows | Sort-Object @{ e = { if ($_.Type -eq 'Box internet / Routeur') { 0 } else { 5 } } }, Type, @{ e = { try { [version]$_.IP } catch { [version]'255.255.255.255' } } })
$cols = @('IP', 'Nom', 'Type', 'Fabricant', 'Systeme', 'Services', 'MAC')

if ($rows.Count) {
  $parType = @($rows | Group-Object Type | Sort-Object Count -Descending | ForEach-Object { [pscustomobject]@{ Type = $_.Name; Nombre = $_.Count } })
  Add-Check -Rubrique 'synth' -Titre "Réseau $Target" -Statut 'INFO' -Resume "$($rows.Count) appareil(s) actif(s) · $(@($rows | Where-Object { $_.Sensibles.Count }).Count) avec un service sensible" -Table (To-Table $parType) -Cible $Target
  Add-Check -Rubrique 'synth' -Titre 'Tous les appareils détectés' -Statut 'INFO' -Resume "$($rows.Count) appareil(s), triés par type" -Table (To-Table $rows $cols 4096) -Cible $Target
  $inconnus = @($rows | Where-Object { $_.Type -eq 'Appareil inconnu' })
  if ($inconnus.Count) { Add-Check -Rubrique 'synth' -Titre 'Appareils non identifiés' -Statut $(if ($inconnus.Count -gt 5) { 'ATT' } else { 'INFO' }) -Resume "$($inconnus.Count) appareil(s) sans service ni fabricant reconnu" -Table (To-Table $inconnus $cols) -Cible $Target -Reco 'Les identifier (étiquette, table DHCP, interface du switch) : un appareil inconnu sur le réseau d''une entreprise doit avoir un propriétaire.' }
  $cat = [ordered]@{
    infra  = 'Pare-feu|Commutateur|Box internet|Hyperviseur|virtualisation|NAS|base de donnees'
    postes = 'Ordinateur|Machine virtuelle|Serveur web|Linux|Smartphone'
    autres = 'Imprimante|Camera|Objet connecte'
  }
  foreach ($k in $cat.Keys) {
    foreach ($g in @($rows | Where-Object { $_.Type -match $cat[$k] } | Group-Object Type)) {
      Add-Check -Rubrique $k -Titre $g.Name -Statut 'INFO' -Resume "$($g.Count) appareil(s) : $((@($g.Group | Select-Object -First 6 | ForEach-Object { if ($_.Nom) { "$($_.Nom) ($($_.IP))" } else { $_.IP } })) -join ', ')$(if ($g.Count -gt 6) { '…' })" -Table (To-Table $g.Group $cols) -Cible $Target
    }
  }

  # --- Services sensibles, regroupés par risque
  $groupes = @(
    @{ Ports = @(23); Titre = 'Telnet (administration non chiffrée)'; Statut = 'CRIT'; Reco = 'Telnet transmet identifiants et commandes en clair : le désactiver au profit de SSH ou HTTPS (switchs, imprimantes, anciens équipements).' },
    @{ Ports = @(21); Titre = 'FTP (transfert non chiffré)'; Statut = 'ATT'; Reco = 'FTP transmet souvent les mots de passe en clair : préférer SFTP / FTPS ou désactiver le service (NAS, copieurs).' },
    @{ Ports = @(5900); Titre = 'VNC (prise de contrôle à distance)'; Statut = 'ATT'; Reco = 'Vérifier que chaque serveur VNC est légitime et protégé par un mot de passe fort ; ne jamais l''exposer sur Internet.' },
    @{ Ports = @(3389); Titre = 'Bureau à distance (RDP) ouvert'; Statut = 'ATT'; Reco = 'Normal sur un serveur, plus discutable sur un poste. Vérifier NLA, les comptes autorisés, et que le port n''est pas redirigé depuis Internet par le pare-feu.' },
    @{ Ports = @(1433, 3306, 5432, 27017, 6379); Titre = 'Bases de données accessibles sur le réseau'; Statut = 'ATT'; Reco = 'Une base de données joignable par tous les postes est rarement nécessaire : restreindre l''accès au pare-feu (serveur d''application uniquement).' },
    @{ Ports = @(161); Titre = 'SNMP (supervision)'; Statut = 'ATT'; Reco = 'Souvent laissé avec la communauté par défaut « public » : la changer ou passer en SNMPv3.' },
    @{ Ports = @(445); Titre = 'Partage de fichiers Windows (SMB)'; Statut = 'INFO'; Reco = 'Normal sur les serveurs de fichiers et les postes Windows. Vérifier que SMBv1 est désactivé partout (diagnostic sécurité) et que les NAS / copieurs ne l''imposent pas.' }
  )
  foreach ($gr in $groupes) {
    $sel = @($rows | Where-Object { $p = $_.Ports -split ', '; @($gr.Ports | Where-Object { $p -contains [string]$_ }).Count })
    if ($sel.Count) { Add-Check -Rubrique 'risque' -Titre $gr.Titre -Statut $gr.Statut -Resume "$($sel.Count) appareil(s) : $((@($sel | Select-Object -First 8 | ForEach-Object { if ($_.Nom) { "$($_.Nom) ($($_.IP))" } else { $_.IP } })) -join ', ')$(if ($sel.Count -gt 8) { '…' })" -Table (To-Table $sel $cols) -Reco $gr.Reco -Cible $Target }
  }
  if (-not @($rows | Where-Object { $_.Sensibles.Count }).Count) { Add-Check -Rubrique 'risque' -Titre 'Services sensibles' -Statut 'OK' -Resume 'Aucun service sensible détecté parmi les ports testés' -Cible $Target }
} elseif ($hotes -is [array]) {
  Add-Check -Rubrique 'synth' -Titre "Réseau $Target" -Statut 'ATT' -Resume 'Aucun appareil actif trouvé' -Cible $Target -Reco 'Vérifier la plage saisie et la connexion du poste à ce réseau (un VPN ne transmet pas les requêtes ARP).'
}
Add-Check -Rubrique 'synth' -Titre 'Méthode' -Statut 'INFO' -Resume "Ports TCP testés : $($script:ScanPorts -join ', ')" -Cible $Target -Reco 'Un port fermé ici peut être filtré par le pare-feu de l''appareil. Pour une analyse plus poussée (versions des services, UDP), utiliser nmap.'

Save-Audit ("Cartographie-Reseau_{0}_{1:yyyyMMdd_HHmm}.html" -f ($Target -replace '[^\d\.]', '-'), $script:Debut) 'Cartographie réseau' '' $Rubriques $Prerequis
