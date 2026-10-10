# ==================================================================================
#  DIAGNOSTIC LENTEUR RÉSEAU
# ==================================================================================
$ErrorActionPreference = 'SilentlyContinue'
$Rubriques = [ordered]@{
  'lien'  = @('Lien et Wi-Fi', '🔌')
  'ip'    = @('Adressage et passerelle', '🧭')
  'dns'   = @('DNS', '📖')
  'wan'   = @('Internet', '🌐')
  'ctx'   = @('Carte, proxy et VPN', '🛡️')
}
$Prerequis = "À lancer sur le poste concerné, sans élévation nécessaire. Le test de débit télécharge 15 Mo depuis speed.cloudflare.com. Lecture seule : aucune modification."
Show-Titre 'Diagnostic lenteur réseau' "Lien et Wi-Fi, adressage IP, passerelle, DNS, latence Internet, débit, utilisation, erreurs de carte, proxy et VPN.`nLecture seule : le script ne modifie rien."
$script:Cibles.Add($env:COMPUTERNAME)
$h = $env:COMPUTERNAME
$debit = Ask-YesNo 'Mesurer le débit descendant (téléchargement de 15 Mo) ?' $true

function Ping-Stats([string]$cible, [int]$n = 4) {
  $ok = @(); $ping = New-Object System.Net.NetworkInformation.Ping
  for ($i = 0; $i -lt $n; $i++) { try { $r = $ping.Send($cible, 1500); if ($r.Status -eq 'Success') { $ok += $r.RoundtripTime } } catch { } }
  [pscustomobject]@{ Cible = $cible; Latence_ms = $(if ($ok.Count) { [math]::Round(($ok | Measure-Object -Average).Average) } else { $null }); Perte_Pct = [math]::Round(($n - $ok.Count) * 100 / $n); Recus = "$($ok.Count)/$n" }
}

# --- Lien
Show-Etape 'Lien et Wi-Fi'
$up = @(Get-NetAdapter -Physical | Where-Object { $_.Status -eq 'Up' })
$rows = @($up | ForEach-Object { [pscustomobject]@{ Interface = $_.Name; Type = $(if ($_.PhysicalMediaType) { [string]$_.PhysicalMediaType } else { [string]$_.MediaType }); Lien_Mbps = [math]::Round([double]$_.TransmitLinkSpeed / 1e6); Duplex = $_.FullDuplex; Description = $_.InterfaceDescription } })
if (-not $up.Count) { Add-Check -Rubrique 'lien' -Titre 'Cartes réseau actives' -Statut 'CRIT' -Resume 'Aucune carte physique connectée' -Cible $h -Reco 'Vérifier le câble, le Wi-Fi ou le mode avion.' }
foreach ($a in $up) {
  $mbps = [math]::Round([double]$a.TransmitLinkSpeed / 1e6)
  $wifi = ("$($a.PhysicalMediaType)" -match '802\.11') -or ("$($a.InterfaceDescription)" -match 'Wi-?Fi|Wireless|sans fil')
  if (-not $wifi) {
    Add-Check -Rubrique 'lien' -Titre "Lien Ethernet $($a.Name)" -Statut $(if ($mbps -le 10) { 'CRIT' } elseif ($mbps -le 100 -or $a.FullDuplex -eq $false) { 'ATT' } else { 'OK' }) -Resume "$mbps Mbps · $(if ($a.FullDuplex -eq $false) { 'HALF-DUPLEX' } else { 'full-duplex' })" -Table (To-Table @($rows | Where-Object { $_.Interface -eq $a.Name })) -Cible $h `
      -Reco $(if ($mbps -le 10) { 'Lien négocié à 10 Mbps : câble défectueux, port réseau dégradé ou switch à problème. Tester un autre câble et un autre port.' } elseif ($mbps -le 100) { 'Lien à 100 Mbps alors que le matériel est souvent Gigabit : vérifier le câble (catégorie, état), le port du switch ou la carte.' } elseif ($a.FullDuplex -eq $false) { 'Le half-duplex provoque collisions et fortes lenteurs : laisser l''autonégociation des deux côtés.' })
  }
}
$wl = netsh wlan show interfaces 2>$null
if ($wl -and ($wl -match 'SSID')) {
  $sig = $null; $ssid = ''
  $l = $wl | Where-Object { $_ -match 'Signal' } | Select-Object -First 1; if ($l -match '(\d+)\s*%') { $sig = [int]$Matches[1] }
  $l = $wl | Where-Object { $_ -match '^\s*SSID\s*:' } | Select-Object -First 1; if ($l -match ':\s*(.+)$') { $ssid = $Matches[1].Trim() }
  if ($null -ne $sig) {
    Add-Check -Rubrique 'lien' -Titre "Signal Wi-Fi ($ssid)" -Statut $(if ($sig -lt 40) { 'CRIT' } elseif ($sig -lt 60) { 'ATT' } else { 'OK' }) -Resume "$sig %" -Brut ($wl -join "`n") -Cible $h `
      -Reco $(if ($sig -lt 60) { 'Signal faible ou moyen : débit réduit et pertes. Se rapprocher du point d''accès, supprimer les obstacles, ou tester en filaire pour comparer.' })
  }
}

# --- Adressage
Show-Etape 'Adressage et passerelle'
$cfgs = @(Get-NetIPConfiguration | Where-Object { $_.IPv4Address })
$ipRows = @($cfgs | ForEach-Object { [pscustomobject]@{ Interface = $_.InterfaceAlias; IPv4 = ($_.IPv4Address.IPAddress -join ', '); Passerelle = ($_.IPv4DefaultGateway.NextHop -join ', '); DNS = (($_.DNSServer | Where-Object { $_.AddressFamily -eq 2 }).ServerAddresses -join ', ') } })
$apipa = @($cfgs | Where-Object { ($_.IPv4Address.IPAddress -join ' ') -match '^169\.254\.' })
$prim = $cfgs | Where-Object { $_.IPv4DefaultGateway } | Select-Object -First 1
Add-Check -Rubrique 'ip' -Titre 'Configuration IP' -Statut $(if ($apipa.Count) { 'CRIT' } elseif (-not $prim) { 'ATT' } else { 'OK' }) `
  -Resume $(if ($apipa.Count) { "Adresse APIPA (169.254.x.x) sur $(($apipa | ForEach-Object { $_.InterfaceAlias }) -join ', ') : pas de réponse DHCP" } elseif (-not $prim) { 'Aucune passerelle par défaut' } else { "$($prim.InterfaceAlias) : $($prim.IPv4Address.IPAddress -join ', ')" }) -Table (To-Table $ipRows) -Cible $h `
  -Reco $(if ($apipa.Count) { 'Le poste n''a pas obtenu d''adresse du serveur DHCP : vérifier câble, port, VLAN et serveur DHCP, puis renouveler le bail.' } elseif (-not $prim) { 'Sans passerelle, rien n''est joignable hors du sous-réseau : vérifier la configuration IP.' }) `
  -Cmds $(if ($apipa.Count) { @(Cmd 'Renouveler l''adresse IP' 'ipconfig /release; ipconfig /renew') })
$gw = $prim.IPv4DefaultGateway.NextHop | Select-Object -First 1
if ($gw) {
  $g = Ping-Stats $gw 4
  Add-Check -Rubrique 'ip' -Titre "Passerelle $gw (réseau local)" -Statut $(if ($null -eq $g.Latence_ms) { 'CRIT' } elseif ($g.Perte_Pct -gt 0 -or $g.Latence_ms -gt 10) { 'ATT' } else { 'OK' }) `
    -Resume $(if ($null -eq $g.Latence_ms) { 'Injoignable' } else { "$($g.Latence_ms) ms · $($g.Perte_Pct) % de perte" }) -Table (To-Table @($g)) -Cible $h `
    -Reco $(if ($null -eq $g.Latence_ms) { 'Coupure du réseau local (câble, switch, port) ou passerelle qui refuse le ping : vérifier en priorité.' } elseif ($g.Perte_Pct -gt 0) { 'Pertes sur le réseau local : câble abîmé, port ou switch instable, ou Wi-Fi faible.' } elseif ($g.Latence_ms -gt 10) { 'Sur un réseau local la latence doit rester sous 5 ms : surcharge, Wi-Fi faible ou matériel à vérifier.' })
}

# --- DNS
Show-Etape 'DNS'
$dnsSrv = @(Get-DnsClientServerAddress -AddressFamily IPv4 | Where-Object { $_.ServerAddresses } | Select-Object -ExpandProperty ServerAddresses -Unique)
$dp = @($dnsSrv | ForEach-Object { Ping-Stats $_ 3 })
$mort = @($dp | Where-Object { $null -eq $_.Latence_ms })
if ($dp.Count) { Add-Check -Rubrique 'dns' -Titre 'Serveurs DNS configurés' -Statut $(if ($mort.Count -eq $dp.Count) { 'CRIT' } elseif ($mort.Count) { 'ATT' } else { 'OK' }) -Resume $(if ($mort.Count) { "Ne répond pas au ping : $(($mort | ForEach-Object { $_.Cible }) -join ', ')" } else { "$($dp.Count) serveur(s), tous répondent" }) -Table (To-Table $dp) -Cible $h -Reco $(if ($mort.Count) { 'Un serveur DNS muet ralentit ou bloque la navigation (souvent un contrôleur de domaine éteint, ou un ancien DNS resté dans le DHCP).' }) }
$cibles = @(); if ($env:USERDNSDOMAIN) { $cibles += $env:USERDNSDOMAIN }; $cibles += 'www.microsoft.com'
$res = @(foreach ($t in $cibles) {
  $ok = $false; $ms = $null
  try { $ms = [math]::Round((Measure-Command { Resolve-DnsName $t -Type A -DnsOnly -ErrorAction Stop | Out-Null }).TotalMilliseconds); $ok = $true } catch { }
  [pscustomobject]@{ Nom = $t; Resolution_ms = $(if ($ok) { $ms } else { 'ÉCHEC' }) }
})
$ech = @($res | Where-Object { $_.Resolution_ms -eq 'ÉCHEC' }); $lent = @($res | Where-Object { $_.Resolution_ms -ne 'ÉCHEC' -and [int]$_.Resolution_ms -gt 300 })
Add-Check -Rubrique 'dns' -Titre 'Temps de résolution DNS' -Statut $(if ($ech.Count) { 'CRIT' } elseif ($lent.Count) { 'ATT' } else { 'OK' }) -Resume (($res | ForEach-Object { "$($_.Nom) : $($_.Resolution_ms)$(if ($_.Resolution_ms -ne 'ÉCHEC') { ' ms' })" }) -join ' · ') -Table (To-Table $res) -Cible $h `
  -Reco $(if ($ech.Count) { 'Le nom ne se résout pas : problème de DNS (serveur, suffixe, connectivité). Cause typique de « tout est lent, rien ne charge ».' } elseif ($lent.Count) { 'Résolution lente : serveur DNS surchargé ou distant, impression de lenteur générale.' }) `
  -Cmds $(if ($ech.Count -or $lent.Count) { @(CmdUser 'Vider le cache DNS du poste' 'ipconfig /flushdns') })

# --- Internet
Show-Etape 'Internet'
$wan = @('1.1.1.1', '8.8.8.8' | ForEach-Object { Ping-Stats $_ 4 })
$best = $wan | Where-Object { $null -ne $_.Latence_ms } | Sort-Object Latence_ms | Select-Object -First 1
$perte = @($wan | Where-Object { $_.Perte_Pct -gt 0 })
Add-Check -Rubrique 'wan' -Titre 'Latence vers Internet' -Statut $(if (-not $best) { 'CRIT' } elseif ($best.Latence_ms -gt 100 -or $perte.Count) { 'ATT' } else { 'OK' }) `
  -Resume $(if (-not $best) { 'Aucune adresse publique ne répond (ou ping ICMP filtré par le pare-feu)' } else { "$($best.Latence_ms) ms vers $($best.Cible)$(if ($perte.Count) { ' · pertes de paquets' })" }) -Table (To-Table $wan) -Cible $h `
  -Reco $(if (-not $best) { 'Coupure Internet, passerelle hors service, ou ICMP bloqué en sortie : vérifier avec un navigateur.' } elseif ($best.Latence_ms -gt 100) { 'Latence élevée : liaison saturée, Wi-Fi faible, ou problème chez l''opérateur ou le VPN.' } elseif ($perte.Count) { 'Pertes vers l''extérieur : liaison instable (opérateur, routeur, saturation).' })
if ($debit) {
  try {
    $tmp = Join-Path $env:TEMP 'consoleit-debit.bin'
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
    $sw = [Diagnostics.Stopwatch]::StartNew(); (New-Object Net.WebClient).DownloadFile('https://speed.cloudflare.com/__down?bytes=15000000', $tmp); $sw.Stop()
    $oct = (Get-Item $tmp).Length; Remove-Item $tmp -Force
    $mbps = [math]::Round(($oct * 8 / 1e6) / $sw.Elapsed.TotalSeconds, 1)
    Add-Check -Rubrique 'wan' -Titre 'Débit descendant (indicatif)' -Statut $(if ($mbps -lt 5) { 'ATT' } else { 'OK' }) -Resume "$mbps Mbps ($([math]::Round($oct / 1MB, 1)) Mo en $([math]::Round($sw.Elapsed.TotalSeconds, 1)) s)" -Cible $h `
      -Reco $(if ($mbps -lt 5) { 'Débit très bas : liaison saturée, Wi-Fi faible, bridage du proxy ou problème opérateur. À relancer et à comparer avec la latence.' } else { 'Mesure indicative (serveur distant, proxy, charge) : relancer plusieurs fois en cas de doute.' })
  } catch { Add-Check -Rubrique 'wan' -Titre 'Débit descendant (indicatif)' -Statut 'INFO' -Resume "Test non concluant : $($_.Exception.Message)" -Cible $h }
}

# --- Carte, proxy, VPN
Show-Etape 'Carte, proxy et VPN'
if ($prim) {
  $s1 = Get-NetAdapterStatistics -Name $prim.InterfaceAlias; Start-Sleep -Seconds 2; $s2 = Get-NetAdapterStatistics -Name $prim.InterfaceAlias
  if ($s1 -and $s2) {
    $in = [math]::Round((($s2.ReceivedBytes - $s1.ReceivedBytes) * 8 / 1e6) / 2, 1); $out = [math]::Round((($s2.SentBytes - $s1.SentBytes) * 8 / 1e6) / 2, 1)
    $errT = [double]$s2.ReceivedPacketErrors + [double]$s2.OutboundPacketErrors
    $er = [pscustomobject]@{ Reception_Mbps = $in; Emission_Mbps = $out; Erreurs_reception = $s2.ReceivedPacketErrors; Erreurs_emission = $s2.OutboundPacketErrors; Rejets_reception = $s2.ReceivedDiscardedPackets; Rejets_emission = $s2.OutboundDiscardedPackets }
    Add-Check -Rubrique 'ctx' -Titre "Utilisation et erreurs de la carte $($prim.InterfaceAlias)" -Statut $(if ($errT -gt 100) { 'ATT' } else { 'OK' }) -Resume "Instantané : $in Mbps reçus, $out Mbps émis · $([int]$errT) erreur(s) de paquets" -Table (To-Table @($er)) -Cible $h `
      -Reco $(if ($errT -gt 100) { 'Des erreurs de paquets indiquent un câble abîmé, un port dégradé ou un pilote à mettre à jour.' } else { 'Si le trafic reste élevé sans raison, un processus sature la liaison (sauvegarde, synchronisation, mises à jour, OneDrive).' })
  }
}
$ie = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$vpnA = @(Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -match 'SonicWall|NetExtender|SSL ?VPN|WireGuard|AnyConnect|GlobalProtect|PANGP|FortiClient|OpenVPN|TAP-Windows' } | Where-Object { Get-NetIPAddress -InterfaceIndex $_.ifIndex -AddressFamily IPv4 | Where-Object { $_.IPAddress -notmatch '^169\.254\.' } })
$vpnW = @(@(Get-VpnConnection) + @(Get-VpnConnection -AllUserConnection) | Where-Object { $_.ConnectionStatus -eq 'Connected' })
$ctx = [pscustomobject]@{ Proxy = $(if ([int]$ie.ProxyEnable -eq 1) { "Oui : $($ie.ProxyServer)" } else { 'Non' }); ScriptPAC = $ie.AutoConfigURL; VPN = ((@($vpnA | ForEach-Object { $_.InterfaceDescription }) + @($vpnW | ForEach-Object { $_.Name })) -join ', ') }
$vpnOn = $vpnA.Count -or $vpnW.Count
Add-Check -Rubrique 'ctx' -Titre 'Proxy et VPN' -Statut 'INFO' -Resume "Proxy : $($ctx.Proxy)$(if ($ie.AutoConfigURL) { ' · script PAC' }) · VPN : $(if ($vpnOn) { $ctx.VPN } else { 'aucun actif' })" -Table (To-Table @($ctx)) -Cible $h `
  -Reco $(if ($vpnOn) { 'Le trafic passe par le VPN : latence et débit sont naturellement dégradés. Comparer VPN connecté et déconnecté.' } elseif ($ie.AutoConfigURL) { 'Un script PAC lent ou injoignable ajoute un délai à chaque connexion web.' })

Save-Audit ("Diagnostic-Reseau_{0}_{1:yyyyMMdd_HHmm}.html" -f $h, $script:Debut) 'Diagnostic lenteur réseau' '' $Rubriques $Prerequis
