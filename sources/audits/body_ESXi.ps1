# ==================================================================================
#  AUDIT VMWARE ESXi (via SSH)
# ==================================================================================
$script:CorrectionsLocales = $false   # commandes à lancer dans la session SSH, pas sur ce poste
$Rubriques = [ordered]@{
  'sante' = @('Santé et ressources', '❤️')
  'stock' = @('Stockage', '💽')
  'vms'   = @('Machines virtuelles et snapshots', '🧩')
  'res'   = @('Réseau', '🔌')
  'secu'  = @('Version, licence et sécurité', '🛡️')
}
$Prerequis = "Client OpenSSH sur ce poste (inclus dans Windows 10/11 et Server 2019+). Service SSH démarré sur chaque hôte ESXi (vSphere Client > Hôte > Configurer > Services > SSH > Démarrer ; à arrêter après l'audit). Compte root (ou compte avec rôle Administrateur). Le mot de passe est demandé par ssh pour chaque hôte. Lecture seule : aucune modification."

Show-Titre 'Audit VMware ESXi' "Santé matérielle, CPU/RAM, datastores, snapshots, VM, réseau, certificat, version, licence.`nConnexion SSH à chaque hôte, lecture seule."
if (-not (Test-Ssh)) { throw 'Client SSH absent : installation nécessaire avant l''audit.' }
$client = Ask-Text 'Client / site (pour le rapport)' ''
$hotes = @()
while (-not $hotes.Count) {
  $hotes = @((Ask-Text 'Hôte(s) ESXi à auditer (nom ou IP, séparés par des virgules)' '') -split '[,; ]+' | Where-Object { $_ })
  if (-not $hotes.Count) { Write-Host '  Indiquer au moins un hôte.' -ForegroundColor Yellow }
}
$user = Ask-Text 'Compte SSH' 'root'
$port = Ask-Text 'Port SSH' '22'

$Cmds = [ordered]@{
  ver   = 'esxcli system version get'
  name  = 'esxcli system hostname get'
  up    = 'esxcli system stats uptime get'
  sum   = 'vim-cmd hostsvc/hostsummary'
  cert  = 'openssl x509 -in /etc/vmware/ssl/rui.crt -noout -subject -enddate'
  ds    = 'esxcli --formatter=csv storage filesystem list'
  vms   = 'vim-cmd vmsvc/getallvms'
  pwr   = @'
for v in $(vim-cmd vmsvc/getallvms 2>/dev/null | awk 'NR>1 && $1 ~ /^[0-9]+$/ {print $1}'); do echo "PWR|$v|$(vim-cmd vmsvc/power.getstate $v 2>/dev/null | tail -1)"; done
'@
  snap  = @'
for v in $(vim-cmd vmsvc/getallvms 2>/dev/null | awk 'NR>1 && $1 ~ /^[0-9]+$/ {print $1}'); do vim-cmd vmsvc/snapshot.get $v 2>/dev/null | awk -v id=$v -F': ' '/Snapshot Name/{n=$2} /Snapshot Created On/{print "SNAP|" id "|" n "|" $2}'; done
'@
  nic   = 'esxcli --formatter=csv network nic list'
  vmk   = 'esxcli --formatter=csv network ip interface ipv4 get'
  vsw   = 'esxcli network vswitch standard list'
  dev   = 'esxcli --formatter=csv storage core device list'
  path  = 'esxcli --formatter=csv storage core path list'
  ipmi  = 'esxcli --formatter=csv hardware ipmi sdr list 2>/dev/null || echo IPMI-INDISPONIBLE'
  ntp   = 'esxcli system ntp get 2>/dev/null || grep -E "^server" /etc/ntp.conf'
  syslg = 'esxcli system syslog config get'
  lic   = 'vim-cmd vimsvc/license --show'
  log   = 'grep -iE "APD|PDL|lost access|permanently inaccessible|failed H:0x" /var/log/vmkernel.log | tail -n 25'
  date  = 'date -u +%s'
}

function Read-EsxCsv([string]$t) {
  $l = @(($t -split "`r?`n") | Where-Object { $_.Trim() })
  if ($l.Count -lt 1 -or $l[0] -notmatch ',') { return @() }
  if ($l[0].EndsWith(',')) { $l = @($l | ForEach-Object { $_ -replace ',$', '' }) }
  try { @($l | ConvertFrom-Csv) } catch { @() }
}
function PV($o, [string[]]$noms) { foreach ($n in $noms) { if ($o.PSObject.Properties.Name -contains $n) { return $o.$n } }; $null }
function Get-Champ([string]$t, [string]$nom) { if ($t -match "(?m)^\s*$([regex]::Escape($nom))\s*[=:]\s*`"?([^`",\r\n]*)`"?") { $Matches[1].Trim() } else { '' } }
function Get-DateCert([string]$t) {
  if ($t -match 'notAfter=(\w{3})\s+(\d+)\s+(\d+:\d+:\d+)\s+(\d{4})') {
    try { return [datetime]::ParseExact("$($Matches[1]) $($Matches[2]) $($Matches[3]) $($Matches[4])", 'MMM d HH:mm:ss yyyy', [Globalization.CultureInfo]::InvariantCulture) } catch { }
  }
  $null
}
function Get-DateEsx([string]$s) {
  $s = $s.Trim()
  foreach ($f in 'M/d/yyyy H:mm:ss', 'M/d/yyyy h:mm:ss tt', 'yyyy-MM-ddTHH:mm:ss', 'dd/MM/yyyy HH:mm:ss') { try { return [datetime]::ParseExact($s, $f, [Globalization.CultureInfo]::InvariantCulture) } catch { } }
  try { [datetime]::Parse($s, [Globalization.CultureInfo]::InvariantCulture) } catch { $null }
}

$plusieurs = $hotes.Count -gt 1
foreach ($hn in $hotes) {
  Show-Etape "Hôte $hn"
  $dest = "$user@$hn"; if ($port -and $port -ne '22') { $dest = @('-p', $port, $dest) }
  $res = Invoke-SshLot $dest $Cmds
  $fin = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  $px = if ($plusieurs) { "$hn · " } else { '' }
  if (-not $res.Ok) {
    Add-Check -Rubrique 'sante' -Titre "${px}Connexion SSH" -Statut 'CRIT' -Resume "Connexion impossible à $hn (code $($res.Code))" -Brut $res.Brut -Cible $hn `
      -Reco 'Vérifier : service SSH démarré sur l''hôte, pare-feu (TCP 22), compte et mot de passe. Le mode verrouillage (lockdown) bloque aussi SSH.'
    continue
  }
  $script:Cibles.Add($hn)
  $o = $res.Sorties; $now = Get-Date
  $sum = [string]$o.sum

  # --- Santé et ressources
  $vers = [string]$o.ver; $nomH = Get-Champ $o.name 'Fully Qualified Domain Name'; if (-not $nomH) { $nomH = $hn }
  $upS = 0; if ([string]$o.up -match '(\d+)') { $upS = [double]$Matches[1] / 1000000 }
  $upJ = [int]($upS / 86400)
  $etat = Get-Champ $sum 'overallStatus'
  $maint = (Get-Champ $sum 'inMaintenanceMode') -eq 'true'
  $reboot = (Get-Champ $sum 'rebootRequired') -eq 'true'
  Add-Check -Rubrique 'sante' -Titre "${px}État global de l'hôte" -Statut $(if ($etat -eq 'red') { 'CRIT' } elseif ($etat -eq 'yellow' -or $maint) { 'ATT' } elseif ($etat -eq 'green') { 'OK' } else { 'INFO' }) `
    -Resume "$nomH · état « $(if ($etat) { $etat } else { 'inconnu' }) »$(if ($maint) { ' · EN MODE MAINTENANCE' })$(if ($reboot) { ' · redémarrage requis' }) · en service depuis $upJ j" -Brut $sum -Cible $hn `
    -Reco $(if ($etat -in 'red', 'yellow') { 'Ouvrir vSphere Client > Hôte > Surveiller > État du matériel et Alarmes pour identifier le composant (disque, alimentation, ventilateur, mémoire).' } elseif ($maint) { 'Sortir l''hôte du mode maintenance si l''intervention est terminée.' }) `
    -Cmds $(if ($maint) { @(Cmd 'Sortir du mode maintenance (SSH ESXi)' 'esxcli system maintenanceMode set --enable false') })
  $mhz = [double](Get-Champ $sum 'cpuMhz'); $cores = [double](Get-Champ $sum 'numCpuCores'); $cpuU = [double](Get-Champ $sum 'overallCpuUsage')
  $memB = [double](Get-Champ $sum 'memorySize'); $memU = [double](Get-Champ $sum 'overallMemoryUsage')
  if ($mhz -and $cores) {
    $cpuP = [math]::Round($cpuU * 100 / ($mhz * $cores), 0)
    Add-Check -Rubrique 'sante' -Titre "${px}Processeur" -Statut $(if ($cpuP -ge 90) { 'CRIT' } elseif ($cpuP -ge 75) { 'ATT' } else { 'OK' }) -Resume "$cpuP % utilisé ($cpuU MHz sur $([int]($mhz * $cores)) MHz, $cores cœurs)" -Cible $hn
  }
  if ($memB) {
    $memP = [math]::Round($memU * 1MB * 100 / $memB, 0)
    Add-Check -Rubrique 'sante' -Titre "${px}Mémoire" -Statut $(if ($memP -ge 95) { 'CRIT' } elseif ($memP -ge 85) { 'ATT' } else { 'OK' }) -Resume "$memP % utilisée ($([math]::Round($memU / 1024, 1)) Go sur $([math]::Round($memB / 1GB, 0)) Go)" -Cible $hn `
      -Reco $(if ($memP -ge 85) { 'Risque de compression / swap mémoire : réduire la mémoire des VM surdimensionnées ou répartir la charge.' })
  }
  $ipmi = [string]$o.ipmi
  if ($ipmi -and $ipmi -notmatch 'IPMI-INDISPONIBLE') {
    $sdr = Read-EsxCsv $ipmi
    $badS = @($sdr | Where-Object { (PV $_ @('Status', 'HealthState')) -match 'Red|Yellow|Critical|Warning|Fail' })
    if ($sdr.Count) { Add-Check -Rubrique 'sante' -Titre "${px}Capteurs matériels (IPMI)" -Statut $(if ($badS.Count) { 'ATT' } else { 'OK' }) -Resume $(if ($badS.Count) { "$($badS.Count) capteur(s) en alerte" } else { "$($sdr.Count) capteur(s) sans alerte" }) -Table (To-Table $sdr) -Cible $hn }
  }
  # heure
  $dRemote = 0; if ([string]$o.date -match '(\d{9,})') { $dRemote = [double]$Matches[1] }
  if ($dRemote) {
    $ecart = [math]::Abs($fin - $dRemote)
    Add-Check -Rubrique 'sante' -Titre "${px}Heure de l'hôte" -Statut $(if ($ecart -gt 300) { 'CRIT' } elseif ($ecart -gt 60) { 'ATT' } else { 'OK' }) -Resume "Écart avec ce poste : $([int]$ecart) s" -Brut ([string]$o.ntp) -Cible $hn `
      -Reco $(if ($ecart -gt 60) { 'Configurer NTP sur l''hôte (vSphere Client > Configurer > Configuration de l''heure) avec les mêmes sources que le domaine ; un décalage casse les sauvegardes, l''authentification AD et les journaux.' }) `
      -Cmds $(if ($ecart -gt 60) { @(Cmd 'Configurer NTP (SSH ESXi 7.0 U1+, adapter le serveur)' 'esxcli system ntp set --server=0.fr.pool.ntp.org --server=1.fr.pool.ntp.org --enabled=true') })
  }

  # --- Stockage
  $ds = @(Read-EsxCsv $o.ds | Where-Object { (PV $_ @('Type')) -match 'VMFS-[56]$|NFS|vsan' })
  if (-not $ds.Count) { Add-Check -Rubrique 'stock' -Titre "${px}Datastores" -Statut 'ATT' -Resume 'Aucun datastore lu (sortie non interprétable)' -Brut ([string]$o.ds) -Cible $hn }
  foreach ($d in $ds) {
    $sz = [double](PV $d @('Size')); $fr = [double](PV $d @('Free')); $nm = PV $d @('VolumeName', 'Volume Name'); $mt = PV $d @('Mounted')
    if (-not $sz) { continue }
    $p = [math]::Round($fr * 100 / $sz, 1)
    Add-Check -Rubrique 'stock' -Titre "${px}Datastore $nm" -Statut $(if ($mt -match 'false') { 'CRIT' } elseif ($p -lt 10) { 'CRIT' } elseif ($p -lt 20) { 'ATT' } else { 'OK' }) `
      -Resume "$(if ($mt -match 'false') { 'NON MONTÉ · ' })$p % libre ($([math]::Round($fr / 1GB, 0)) Go sur $([math]::Round($sz / 1GB, 0)) Go) · $(PV $d @('Type'))" -Cible $hn `
      -Reco $(if ($p -lt 20) { 'Un datastore plein fige les VM (snapshots et disques fins ne peuvent plus grossir). Supprimer les snapshots, les VM et ISO inutiles, ou déplacer des VM (Storage vMotion).' })
  }
  $dev = @(Read-EsxCsv $o.dev)
  if ($dev.Count) {
    $kd = @($dev | Where-Object { (PV $_ @('Status')) -and (PV $_ @('Status')) -ne 'on' })
    $rows = @($dev | ForEach-Object { [pscustomobject]@{ Peripherique = PV $_ @('Device'); Nom = PV $_ @('DisplayName', 'Display Name'); TailleGo = [math]::Round([double](PV $_ @('Size')) / 1024, 0); Statut = PV $_ @('Status'); SSD = PV $_ @('IsSSD', 'Is SSD'); Local = PV $_ @('IsLocal', 'Is Local') } })
    Add-Check -Rubrique 'stock' -Titre "${px}Périphériques de stockage" -Statut $(if ($kd.Count) { 'CRIT' } else { 'OK' }) -Resume $(if ($kd.Count) { "$($kd.Count) périphérique(s) hors ligne ou en erreur" } else { "$($dev.Count) périphérique(s) en ligne" }) -Table (To-Table $rows) -Cible $hn
  }
  $pa = @(Read-EsxCsv $o.path)
  if ($pa.Count) {
    $dead = @($pa | Where-Object { (PV $_ @('State')) -eq 'dead' })
    Add-Check -Rubrique 'stock' -Titre "${px}Chemins de stockage (multipath)" -Statut $(if ($dead.Count) { 'CRIT' } else { 'OK' }) -Resume $(if ($dead.Count) { "$($dead.Count) chemin(s) mort(s) sur $($pa.Count)" } else { "$($pa.Count) chemin(s), aucun mort" }) `
      -Table (To-Table @($pa | ForEach-Object { [pscustomobject]@{ Chemin = PV $_ @('RuntimeName', 'Runtime Name'); Peripherique = PV $_ @('Device'); Adaptateur = PV $_ @('Adapter'); Etat = PV $_ @('State') } })) -Cible $hn `
      -Reco $(if ($dead.Count) { 'Chemin vers la baie perdu (câble, port de switch, contrôleur de baie) : la redondance n''est plus assurée.' })
  }
  $lg = ([string]$o.log).Trim()
  Add-Check -Rubrique 'stock' -Titre "${px}Pertes d'accès au stockage (vmkernel.log)" -Statut $(if ($lg) { 'ATT' } else { 'OK' }) -Resume $(if ($lg) { 'Événements APD / PDL / pertes d''accès récents dans le journal' } else { 'Aucune perte d''accès dans le journal courant' }) -Brut $lg -Cible $hn

  # --- VM
  $vmMap = @{}; $vmRows = @()
  foreach ($ln in (([string]$o.vms) -split "`r?`n")) {
    if ($ln -match '^(\d+)\s+(.+?)\s+(\[[^\]]+\]\s+.+?\.vmx)\s+(\S+)\s+(vmx-\d+)') { $vmMap[$Matches[1]] = $Matches[2]; $vmRows += [pscustomobject]@{ Vmid = $Matches[1]; VM = $Matches[2]; Fichier = $Matches[3]; OS = $Matches[4]; Version = $Matches[5]; Alimentation = '' } }
  }
  foreach ($ln in (([string]$o.pwr) -split "`r?`n")) { if ($ln -match '^PWR\|(\d+)\|(.*)$') { $id = $Matches[1]; $st = $Matches[2].Trim(); $vmRows | Where-Object { $_.Vmid -eq $id } | ForEach-Object { $_.Alimentation = $st } } }
  $on = @($vmRows | Where-Object { $_.Alimentation -match 'on' -and $_.Alimentation -notmatch 'off' })
  Add-Check -Rubrique 'vms' -Titre "${px}Machines virtuelles" -Statut 'INFO' -Resume "$($vmRows.Count) VM enregistrée(s), $($on.Count) allumée(s)" -Table (To-Table $vmRows @('Vmid', 'VM', 'Alimentation', 'OS', 'Version', 'Fichier')) -Brut $(if (-not $vmRows.Count) { [string]$o.vms }) -Cible $hn
  $old = @($vmRows | Where-Object { $_.Version -match 'vmx-(\d+)' -and [int]($_.Version -replace 'vmx-', '') -lt 13 })
  if ($old.Count) { Add-Check -Rubrique 'vms' -Titre "${px}Version matérielle des VM" -Statut 'INFO' -Resume "Matériel virtuel ancien (< vmx-13) : $(($old | ForEach-Object { $_.VM + ' (' + $_.Version + ')' }) -join ', ')" -Cible $hn -Reco 'Mettre à niveau la compatibilité de la VM (VM éteinte, après sauvegarde) lors d''une prochaine maintenance.' }
  $snaps = @()
  foreach ($ln in (([string]$o.snap) -split "`r?`n")) {
    if ($ln -match '^SNAP\|(\d+)\|(.*?)\|(.*)$') {
      $dt = Get-DateEsx $Matches[3]
      $snaps += [pscustomobject]@{ VM = $(if ($vmMap[$Matches[1]]) { $vmMap[$Matches[1]] } else { "Vmid $($Matches[1])" }); Snapshot = $Matches[2].Trim(); Cree = $(if ($dt) { $dt } else { $Matches[3].Trim() }); AgeJours = $(if ($dt) { [int]($now - $dt).TotalDays } else { $null }) }
    }
  }
  $sC = @($snaps | Where-Object { $_.AgeJours -gt 30 }); $sA = @($snaps | Where-Object { $_.AgeJours -gt 3 -and $_.AgeJours -le 30 })
  Add-Check -Rubrique 'vms' -Titre "${px}Snapshots" -Statut $(if ($sC.Count) { 'CRIT' } elseif ($sA.Count) { 'ATT' } elseif ($snaps.Count) { 'INFO' } else { 'OK' }) `
    -Resume $(if ($snaps.Count) { "$($snaps.Count) snapshot(s) · $($sC.Count) de plus de 30 jours · $($sA.Count) de 4 à 30 jours" } else { 'Aucun snapshot' }) -Table (To-Table $snaps) -Cible $hn `
    -Reco $(if ($sC.Count -or $sA.Count) { 'VMware recommande de ne pas conserver un snapshot plus de 72 h : le fichier delta grossit, ralentit la VM et peut remplir le datastore. Supprimer (« Tout supprimer » fusionne) après accord ; un snapshot laissé par la sauvegarde signale un échec de nettoyage.' })

  # --- Réseau
  $nics = @(Read-EsxCsv $o.nic)
  if ($nics.Count) {
    $down = @($nics | Where-Object { (PV $_ @('LinkStatus', 'Link Status', 'Link')) -match 'Down' -and (PV $_ @('AdminStatus', 'Admin Status')) -match 'Up' })
    $rows = @($nics | ForEach-Object { [pscustomobject]@{ Carte = PV $_ @('Name'); Lien = PV $_ @('LinkStatus', 'Link Status', 'Link'); Vitesse = PV $_ @('Speed'); Duplex = PV $_ @('Duplex'); Pilote = PV $_ @('Driver'); MAC = PV $_ @('MACAddress', 'MAC Address'); MTU = PV $_ @('MTU'); Description = PV $_ @('Description') } })
    Add-Check -Rubrique 'res' -Titre "${px}Cartes physiques (vmnic)" -Statut $(if ($down.Count) { 'ATT' } else { 'OK' }) -Resume $(if ($down.Count) { "Lien coupé : $(($down | ForEach-Object { PV $_ @('Name') }) -join ', ')" } else { "$($nics.Count) carte(s), liens actifs" }) -Table (To-Table $rows) -Cible $hn `
      -Reco $(if ($down.Count) { 'Si la carte fait partie d''un vSwitch, la redondance réseau est perdue : vérifier câble et port du switch. Sinon, ignorer (carte non câblée).' })
  }
  $vmk = @(Read-EsxCsv $o.vmk)
  if ($vmk.Count) { Add-Check -Rubrique 'res' -Titre "${px}Interfaces VMkernel" -Statut 'INFO' -Resume "$($vmk.Count) interface(s)" -Table (To-Table @($vmk | ForEach-Object { [pscustomobject]@{ Interface = PV $_ @('Name'); IP = PV $_ @('IPv4Address', 'IPv4 Address'); Masque = PV $_ @('IPv4Netmask', 'IPv4 Netmask'); Passerelle = PV $_ @('Gateway'); Type = PV $_ @('AddressType', 'Address Type') } })) -Cible $hn }
  Add-Check -Rubrique 'res' -Titre "${px}vSwitch standard" -Statut 'INFO' -Resume 'Configuration des commutateurs virtuels' -Brut ([string]$o.vsw) -Cible $hn

  # --- Version, licence, sécurité
  $v = Get-Champ $vers 'Version'; $b = Get-Champ $vers 'Build'; $u = Get-Champ $vers 'Update'
  $maj = 0; if ($v -match '^(\d+)') { $maj = [int]$Matches[1] }
  Add-Check -Rubrique 'secu' -Titre "${px}Version ESXi" -Statut $(if ($maj -and $maj -lt 7) { 'CRIT' } elseif ($maj -eq 7) { 'ATT' } elseif ($maj) { 'OK' } else { 'INFO' }) -Resume "ESXi $v Update $u · $b" -Brut $vers -Cible $hn `
    -Reco $(if ($maj -and $maj -lt 7) { 'Version hors support (aucun correctif de sécurité). Planifier la migration vers ESXi 8 (vérifier la compatibilité matérielle VMware).' } elseif ($maj -eq 7) { 'vSphere 7 n''a plus de support général depuis octobre 2025 : planifier le passage en version 8 (matériel compatible, licence Broadcom).' } else { 'Vérifier que le dernier correctif de la branche est appliqué (avis de sécurité VMSA).' })
  $cd = Get-DateCert $o.cert
  if ($cd) {
    $j = [int]($cd - $now).TotalDays
    Add-Check -Rubrique 'secu' -Titre "${px}Certificat de l'hôte" -Statut $(if ($j -lt 30) { 'CRIT' } elseif ($j -lt 90) { 'ATT' } else { 'OK' }) -Resume $(if ($j -lt 0) { "Expiré depuis $(-$j) jour(s) ($($cd.ToString('dd/MM/yyyy')))" } else { "Expire le $($cd.ToString('dd/MM/yyyy')) (dans $j j)" }) -Brut ([string]$o.cert) -Cible $hn `
      -Reco $(if ($j -lt 90) { 'Renouveler : depuis vCenter (Hôte > Configurer > Certificat > Renouveler) ou, pour un hôte autonome, /sbin/generate-certificates puis redémarrage des agents de gestion.' })
  } else { Add-Check -Rubrique 'secu' -Titre "${px}Certificat de l'hôte" -Statut 'INFO' -Resume 'Date non lue' -Brut ([string]$o.cert) -Cible $hn }
  $lic = [string]$o.lic
  $eval = $lic -match '(?i)evaluation|eval mode'
  $exp = ''; if ($lic -match '(?i)expirationDate\s*[=:]\s*"?([^",\r\n]+)') { $exp = $Matches[1].Trim() }
  Add-Check -Rubrique 'secu' -Titre "${px}Licence" -Statut $(if ($eval) { 'CRIT' } else { 'INFO' }) -Resume $(if ($eval) { 'Mode évaluation : l''hôte se déconnectera / les VM ne pourront plus démarrer à l''expiration' } else { "Licence installée$(if ($exp) { ' · expiration ' + $exp })" }) -Brut $lic -Cible $hn
  $sl = [string]$o.syslg
  $rh = Get-Champ $sl 'Remote Host'
  Add-Check -Rubrique 'secu' -Titre "${px}Journalisation distante (syslog)" -Statut $(if (-not $rh -or $rh -match '<none>') { 'ATT' } else { 'OK' }) -Resume $(if (-not $rh -or $rh -match '<none>') { 'Aucun serveur syslog : les journaux sont perdus au redémarrage (ESXi sur carte SD/USB) et inexploitables après un incident' } else { "Envoyés vers $rh" }) -Brut $sl -Cible $hn `
    -Cmds $(if (-not $rh -or $rh -match '<none>') { @(Cmd 'Déclarer un serveur syslog (SSH ESXi, adapter)' 'esxcli system syslog config set --loghost=udp://192.168.1.20:514; esxcli system syslog reload; esxcli network firewall ruleset set -r syslog -e true') })
  Add-Check -Rubrique 'secu' -Titre "${px}Service SSH" -Statut 'ATT' -Resume 'Actif (nécessaire pour cet audit) : à arrêter une fois l''intervention terminée' -Cible $hn `
    -Reco 'Un SSH laissé ouvert est une porte d''entrée pour les rançongiciels ciblant ESXi.' -Cmds @(Cmd 'Arrêter SSH sur l''hôte (dans la session SSH ESXi)' 'vim-cmd hostsvc/disable_ssh; vim-cmd hostsvc/stop_ssh')
}

Save-Audit ("Audit-ESXi_{0}_{1:yyyyMMdd_HHmm}.html" -f (($hotes | Select-Object -First 1) -replace '[^\w\.-]', '_'), $script:Debut) 'Audit VMware ESXi' $client $Rubriques $Prerequis
