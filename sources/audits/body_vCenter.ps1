# ==================================================================================
#  AUDIT VMWARE vCENTER (VCSA, via SSH)
# ==================================================================================
$Rubriques = [ordered]@{
  'svc'  = @('Services', '⚙️')
  'cert' = @('Certificats', '🔏')
  'sys'  = @('Système de l''appliance', '🖥️')
  'secu' = @('Version et comptes', '🛡️')
}
$Prerequis = "Client OpenSSH sur ce poste. SSH activé sur l'appliance (VAMI https://vcenter:5480 > Accès > SSH ; à désactiver après l'audit). Compte root de l'appliance. Le shell de root doit être bash (sinon le script indique la commande pour basculer). Lecture seule : aucune modification."

Show-Titre 'Audit VMware vCenter (VCSA)' "Services, certificats (tous les magasins VECS), espace disque, version, expiration du mot de passe root.`nConnexion SSH à l'appliance, lecture seule."
if (-not (Test-Ssh)) { throw 'Client SSH absent : installation nécessaire avant l''audit.' }
$client = Ask-Text 'Client / site (pour le rapport)' ''
$vc = ''
while (-not $vc) { $vc = Ask-Text 'vCenter (nom ou IP de l''appliance)' '' }
$user = Ask-Text 'Compte SSH' 'root'
$port = Ask-Text 'Port SSH' '22'

$Cmds = [ordered]@{
  ver   = 'vpxd -v'
  svc   = 'service-control --status --all'
  cert  = @'
VC=/usr/lib/vmware-vmafd/bin/vecs-cli; for s in $($VC store list); do $VC entry list --store "$s" --text 2>/dev/null | awk -v st="$s" '/^Alias/{a=$NF} /Not After/{sub(/.*Not After *: */,""); print "CERT|" st "|" a "|" $0}'; done
'@
  df    = 'df -P -x tmpfs -x devtmpfs -x overlay 2>/dev/null || df -P'
  up    = 'uptime'
  root  = 'chage -l root'
  ntp   = 'timedatectl 2>/dev/null | head -n 8; grep -E "^server" /etc/ntp.conf 2>/dev/null'
  dns   = 'cat /etc/resolv.conf | grep -v "^#"; echo; hostname -f'
  bkp   = 'ls -1t /var/log/vmware/applmgmt/backup.log* 2>/dev/null | head -1 | xargs -r tail -n 5'
  date  = 'date -u +%s'
}
$Coeur = 'vpxd', 'vmware-vpxd-svcs', 'vsphere-ui', 'lookupsvc', 'vmafdd', 'vmdird', 'vmcad', 'vmware-stsd', 'vmware-vapi-endpoint', 'vmware-vpostgres', 'rhttpproxy', 'envoy', 'vmware-cis-license', 'vmware-eam', 'vmware-sps', 'vmonapi', 'vmware-vmon', 'applmgmt', 'vmware-trustmanagement', 'vlcm', 'vmware-content-library'
$NormalementArretes = 'vmcam', 'vmware-imagebuilder', 'vmware-netdumper', 'vmware-rbd-watchdog', 'vmware-vcha', 'vmware-pod', 'vsan-dps', 'vmware-mbcs', 'vmware-hvc', 'vmware-vsan-health', 'vmware-certificatemanagement', 'vmware-topologysvc', 'wcp'

function Test-Coeur($n) { ($Coeur -contains $n) -or ($Coeur -contains ($n -replace '^vmware-', '')) -or ($Coeur -contains "vmware-$n") }
function Get-DateCert2([string]$s) {
  $s = ($s -replace '\s+', ' ').Trim() -replace ' GMT$', ''
  foreach ($f in 'MMM d HH:mm:ss yyyy', 'MMM dd HH:mm:ss yyyy') { try { return [datetime]::ParseExact($s, $f, [Globalization.CultureInfo]::InvariantCulture) } catch { } }
  $null
}

Show-Etape "Appliance $vc"
$dest = "$user@$vc"; if ($port -and $port -ne '22') { $dest = @('-p', $port, $dest) }
$res = Invoke-SshLot $dest $Cmds
$fin = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
if (-not $res.Ok) {
  $appsh = $res.Brut -match '(?i)Unknown command|appliancesh|Command>'
  Add-Check -Rubrique 'svc' -Titre 'Connexion SSH' -Statut 'CRIT' -Resume $(if ($appsh) { 'Connecté, mais le shell de root est « appliancesh » : les commandes ne peuvent pas être exécutées' } else { "Connexion impossible à $vc (code $($res.Code))" }) -Brut $res.Brut -Cible $vc `
    -Reco $(if ($appsh) { 'Se connecter une fois en SSH, taper « shell », puis passer root sur bash (commande ci-dessous) ; relancer l''audit. Pour revenir ensuite au shell d''origine : chsh -s /bin/appliancesh root' } else { 'Vérifier : SSH activé dans la VAMI (port 5480 > Accès), pare-feu TCP 22, mot de passe root (non expiré).' }) `
    -Cmds $(if ($appsh) { @(Cmd 'Passer le shell de root sur bash (dans la session SSH, après « shell »)' 'chsh -s /bin/bash root') })
} else {
  $script:Cibles.Add($vc)
  $o = $res.Sorties; $now = Get-Date

  # --- Services
  $txt = [string]$o.svc; $etats = @{}; $cur = ''
  foreach ($ln in ($txt -split "`r?`n")) {
    if ($ln -match '^\s*(Running|Stopped|StartPending|StopPending)\s*:\s*(.*)$') { $cur = $Matches[1]; $ln = $Matches[2] }
    if ($cur) { foreach ($t in ($ln -split '\s+' | Where-Object { $_ })) { $etats[$t] = $cur } }
  }
  if ($etats.Count) {
    $rows = @($etats.Keys | Sort-Object | ForEach-Object { [pscustomobject]@{ Service = $_; Etat = $etats[$_]; Essentiel = $(if (Test-Coeur $_) { 'oui' } else { '' }) } })
    $kc = @($rows | Where-Object { $_.Etat -ne 'Running' -and (Test-Coeur $_.Service) })
    $ko = @($rows | Where-Object { $_.Etat -ne 'Running' -and -not (Test-Coeur $_.Service) -and $NormalementArretes -notcontains $_.Service })
    Add-Check -Rubrique 'svc' -Titre 'Services vCenter' -Statut $(if ($kc.Count) { 'CRIT' } elseif ($ko.Count) { 'ATT' } else { 'OK' }) `
      -Resume $(if ($kc.Count) { "Service(s) essentiel(s) arrêté(s) : $(($kc | ForEach-Object { $_.Service }) -join ', ')" } elseif ($ko.Count) { "Arrêté(s) : $(($ko | ForEach-Object { $_.Service }) -join ', ') (à vérifier selon les fonctions utilisées)" } else { "$(@($rows | Where-Object { $_.Etat -eq 'Running' }).Count) service(s) démarré(s), les arrêtés sont normalement arrêtés" }) `
      -Table (To-Table ($rows | Sort-Object @{ e = { if ($_.Etat -eq 'Running') { 1 } else { 0 } } }, Service)) -Brut $txt -Cible $vc `
      -Reco $(if ($kc.Count) { 'Démarrer les services (commande ci-dessous dans la session SSH). En cas d''échec, lire /var/log/vmware/vmon/vmon.log ; une cause fréquente est un certificat expiré (voir rubrique Certificats) ou une partition pleine.' }) `
      -Cmds $(if ($kc.Count -or $ko.Count) { @(Cmd 'Démarrer tous les services (SSH vCenter)' 'service-control --start --all') })
  } else { Add-Check -Rubrique 'svc' -Titre 'Services vCenter' -Statut 'ATT' -Resume 'Sortie de service-control non interprétable' -Brut $txt -Cible $vc }

  # --- Certificats
  $certs = @()
  foreach ($ln in (([string]$o.cert) -split "`r?`n")) {
    if ($ln -match '^CERT\|([^|]*)\|([^|]*)\|(.*)$') {
      $d = Get-DateCert2 $Matches[3]
      $certs += [pscustomobject]@{ Magasin = $Matches[1]; Alias = $Matches[2]; Expiration = $(if ($d) { $d } else { $Matches[3] }); Jours = $(if ($d) { [int]($d - $now).TotalDays } else { $null }) }
    }
  }
  if ($certs.Count) {
    $actifs = @($certs | Where-Object { $_.Magasin -notmatch '^BACKUP_STORE|TRUSTED_ROOT_CRLS' -and $null -ne $_.Jours })
    $cE = @($actifs | Where-Object { $_.Magasin -ne 'TRUSTED_ROOTS' -and $_.Jours -lt 30 }); $cW = @($actifs | Where-Object { $_.Magasin -ne 'TRUSTED_ROOTS' -and $_.Jours -ge 30 -and $_.Jours -lt 90 })
    $rE = @($actifs | Where-Object { $_.Magasin -eq 'TRUSTED_ROOTS' -and $_.Jours -lt 0 })
    $msl = @($certs | Where-Object { $_.Magasin -eq 'MACHINE_SSL_CERT' } | Select-Object -First 1)
    Add-Check -Rubrique 'cert' -Titre 'Certificat machine SSL (interface web)' -Statut $(if (-not $msl.Count) { 'INFO' } elseif ($msl[0].Jours -lt 30) { 'CRIT' } elseif ($msl[0].Jours -lt 90) { 'ATT' } else { 'OK' }) `
      -Resume $(if ($msl.Count) { "Expire le $(if ($msl[0].Expiration -is [datetime]) { $msl[0].Expiration.ToString('dd/MM/yyyy') } else { $msl[0].Expiration }) (dans $($msl[0].Jours) j)" } else { 'Non trouvé' }) -Cible $vc
    Add-Check -Rubrique 'cert' -Titre 'Certificats des services (VECS)' -Statut $(if ($cE.Count) { 'CRIT' } elseif ($cW.Count -or $rE.Count) { 'ATT' } else { 'OK' }) `
      -Resume $(if ($cE.Count) { "$($cE.Count) certificat(s) expiré(s) ou expirant sous 30 jours : $(($cE | ForEach-Object { $_.Magasin + '/' + $_.Alias }) -join ', ')" } elseif ($cW.Count) { "$($cW.Count) certificat(s) expirant sous 90 jours" } elseif ($rE.Count) { "$($rE.Count) racine(s) de confiance expirée(s) (à nettoyer)" } else { "$($actifs.Count) certificat(s) valides plus de 90 jours" }) `
      -Table (To-Table ($certs | Sort-Object @{ e = { if ($null -eq $_.Jours) { 99999 } else { $_.Jours } } })) -Cible $vc `
      -Reco $(if ($cE.Count -or $cW.Count) { 'Renouveler avec /usr/lib/vmware-vmca/bin/certificate-manager (option 8 : réinitialiser tous les certificats) après un instantané de l''appliance, ou depuis vSphere Client > Administration > Certificats. Un certificat expiré empêche les services de démarrer.' } elseif ($rE.Count) { 'Les racines expirées de TRUSTED_ROOTS peuvent bloquer une mise à jour : les supprimer avec vecs-cli / dir-cli après vérification (KB VMware 2146011).' } else { 'Le certificat de signature STS n''est pas dans VECS : le vérifier avec le script officiel checksts.py (KB 79248), il expire souvent sur les vCenter installés en 6.5 / 6.7.' })
  } else { Add-Check -Rubrique 'cert' -Titre 'Certificats (VECS)' -Statut 'ATT' -Resume 'Aucun certificat lu' -Brut ([string]$o.cert) -Cible $vc }

  # --- Système
  $parts = @()
  foreach ($ln in (([string]$o.df) -split "`r?`n")) { if ($ln -match '^(\S+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)%\s+(\S+)$') { $parts += [pscustomobject]@{ Partition = $Matches[6]; Peripherique = $Matches[1]; TailleGo = [math]::Round([double]$Matches[2] / 1MB, 1); UtiliseGo = [math]::Round([double]$Matches[3] / 1MB, 1); Utilisation = [int]$Matches[5] } } }
  $pC = @($parts | Where-Object { $_.Utilisation -ge 90 }); $pA = @($parts | Where-Object { $_.Utilisation -ge 80 -and $_.Utilisation -lt 90 })
  Add-Check -Rubrique 'sys' -Titre 'Espace disque des partitions' -Statut $(if ($pC.Count) { 'CRIT' } elseif ($pA.Count) { 'ATT' } elseif ($parts.Count) { 'OK' } else { 'INFO' }) `
    -Resume $(if ($pC.Count) { "Pleine(s) à 90 % ou plus : $(($pC | ForEach-Object { $_.Partition + ' (' + $_.Utilisation + ' %)' }) -join ', ')" } elseif ($pA.Count) { "À 80 % ou plus : $(($pA | ForEach-Object { $_.Partition + ' (' + $_.Utilisation + ' %)' }) -join ', ')" } else { "$($parts.Count) partition(s) sous 80 %" }) `
    -Table (To-Table ($parts | Sort-Object Utilisation -Descending)) -Cible $vc `
    -Reco $(if ($pC.Count -or $pA.Count) { '/storage/log ou /storage/archive pleins font tomber vpxd ou la base. Purger les anciens journaux/archives (KB selon la partition) ou agrandir le disque de la VM puis lancer l''extension automatique (KB 2145603).' })
  $up = ([string]$o.up).Trim()
  Add-Check -Rubrique 'sys' -Titre 'Disponibilité et charge' -Statut 'INFO' -Resume $up -Cible $vc
  $dR = 0; if ([string]$o.date -match '(\d{9,})') { $dR = [double]$Matches[1] }
  if ($dR) { $ec = [math]::Abs($fin - $dR); Add-Check -Rubrique 'sys' -Titre 'Heure de l''appliance' -Statut $(if ($ec -gt 300) { 'CRIT' } elseif ($ec -gt 60) { 'ATT' } else { 'OK' }) -Resume "Écart avec ce poste : $([int]$ec) s" -Brut ([string]$o.ntp) -Cible $vc -Reco $(if ($ec -gt 60) { 'Configurer NTP dans la VAMI (port 5480 > Heure) : un décalage avec les hôtes ou l''AD casse l''authentification SSO.' }) }
  Add-Check -Rubrique 'sys' -Titre 'Résolution DNS' -Statut 'INFO' -Resume 'Serveurs DNS et nom complet de l''appliance' -Brut ([string]$o.dns) -Cible $vc
  $bk = ([string]$o.bkp).Trim()
  Add-Check -Rubrique 'sys' -Titre 'Sauvegarde basée sur fichiers (VAMI)' -Statut $(if (-not $bk) { 'ATT' } elseif ($bk -match '(?i)fail|error') { 'ATT' } else { 'INFO' }) -Resume $(if ($bk) { 'Dernières lignes du journal de sauvegarde' } else { 'Aucun journal de sauvegarde : la sauvegarde planifiée de la VAMI ne semble pas configurée' }) -Brut $bk -Cible $vc `
    -Reco $(if (-not $bk) { 'Configurer la sauvegarde planifiée dans la VAMI (port 5480 > Sauvegarde) vers un partage SMB/NFS/SFTP : c''est la seule méthode de restauration supportée par VMware.' })

  # --- Version et compte root
  $ver = ([string]$o.ver).Trim()
  $maj = 0; if ($ver -match '(\d+)\.(\d+)\.(\d+)') { $maj = [int]$Matches[1] }
  Add-Check -Rubrique 'secu' -Titre 'Version de vCenter' -Statut $(if ($maj -and $maj -lt 7) { 'CRIT' } elseif ($maj -eq 7) { 'ATT' } elseif ($maj) { 'OK' } else { 'INFO' }) -Resume $ver -Cible $vc `
    -Reco $(if ($maj -and $maj -lt 7) { 'vCenter hors support et exposé à des failles critiques exploitées : migrer vers vCenter 8.' } elseif ($maj -eq 7) { 'vSphere 7 n''a plus de support général depuis octobre 2025 : planifier le passage en version 8.' } else { 'Vérifier les avis de sécurité VMSA et appliquer le dernier correctif (VAMI > Mise à jour).' })
  $ch = [string]$o.root
  $pe = ''; if ($ch -match '(?im)^Password expires\s*:\s*(.+)$') { $pe = $Matches[1].Trim() }
  $pd = $null; if ($pe -and $pe -notmatch 'never') { try { $pd = [datetime]::ParseExact($pe, 'MMM dd, yyyy', [Globalization.CultureInfo]::InvariantCulture) } catch { } }
  $jr = if ($pd) { [int]($pd - $now).TotalDays } else { $null }
  Add-Check -Rubrique 'secu' -Titre 'Expiration du mot de passe root' -Statut $(if ($null -ne $jr -and $jr -lt 15) { 'CRIT' } elseif ($null -ne $jr -and $jr -lt 45) { 'ATT' } else { 'OK' }) `
    -Resume $(if ($pd) { "Expire le $($pd.ToString('dd/MM/yyyy')) (dans $jr j)" } elseif ($pe) { "Expiration : $pe" } else { 'Non lue' }) -Brut $ch -Cible $vc `
    -Reco $(if ($null -ne $jr -and $jr -lt 45) { 'Un mot de passe root expiré verrouille l''accès à la VAMI et à SSH (récupération par redémarrage en mode init=/bin/bash). Le changer maintenant et le consigner dans le coffre de mots de passe.' }) `
    -Cmds $(if ($null -ne $jr -and $jr -lt 45) { @(Cmd 'Changer le mot de passe root (SSH vCenter)' 'passwd root') })
  Add-Check -Rubrique 'secu' -Titre 'Service SSH' -Statut 'ATT' -Resume 'Actif (nécessaire pour cet audit) : à désactiver dans la VAMI une fois l''intervention terminée' -Cible $vc
}

Save-Audit ("Audit-vCenter_{0}_{1:yyyyMMdd_HHmm}.html" -f ($vc -replace '[^\w\.-]', '_'), $script:Debut) 'Audit VMware vCenter' $client $Rubriques $Prerequis
