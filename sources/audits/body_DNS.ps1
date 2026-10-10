# ==================================================================================
#  AUDIT DNS (serveur DNS Windows)
# ==================================================================================
$Rubriques = [ordered]@{
  'svc'   = @('Service et configuration', '🖥️')
  'resol' = @('Résolution et redirecteurs', '🌐')
  'zones' = @('Zones', '📚')
  'nett'  = @('Nettoyage (vieillissement)', '🧹')
  'jour'  = @('Journal d''événements', '📜')
}
$Prerequis = "À lancer sur le serveur DNS, ou depuis un poste avec WinRM vers ce serveur. Compte administrateur (lecture). Module DnsServer présent sur le serveur (rôle DNS). Lecture seule : aucune modification, les corrections sont proposées sous forme de commandes."

Show-Titre 'Audit DNS' "Service, redirecteurs, résolution externe, zones, mises à jour dynamiques, vieillissement et nettoyage.`nLecture seule : le script ne modifie rien."
$client = Ask-Text 'Client / site (pour le rapport)' ''
$cible = Get-Cible 'DNS' 'Indiquer le serveur DNS (souvent un contrôleur de domaine). Entrée si ce script tourne déjà dessus.'
$testExt = Ask-Text 'Nom externe à résoudre pour le test' 'www.microsoft.com'

$Collecte = {
  param($testExt)
  $r = @{ Host = $env:COMPUTERNAME; Erreurs = @() }
  $svc = Get-Service DNS -ErrorAction SilentlyContinue
  $r.Service = if ($svc) { [pscustomobject]@{ Etat = [string]$svc.Status; Demarrage = [string]$svc.StartType } } else { $null }
  try {
    Import-Module DnsServer -ErrorAction Stop
    $fw = Get-DnsServerForwarder -ErrorAction Stop
    $r.Redirecteurs = @($fw.IPAddress | ForEach-Object { $_.IPAddressToString })
    $r.RedirTimeout = $fw.Timeout; $r.RedirRacine = $fw.UseRootHint
    $r.TestsRedir = @($r.Redirecteurs | ForEach-Object {
      $ip = $_; $sw = [Diagnostics.Stopwatch]::StartNew()
      try { $null = Resolve-DnsName -Name $testExt -Server $ip -DnsOnly -QuickTimeout -ErrorAction Stop; $ok = $true; $msg = '' } catch { $ok = $false; $msg = $_.Exception.Message }
      [pscustomobject]@{ Redirecteur = $ip; Repond = $ok; Duree_ms = [int]$sw.ElapsedMilliseconds; Erreur = $msg } })
    $rec = Get-DnsServerRecursion -ErrorAction SilentlyContinue
    $r.Recursion = if ($rec) { [bool]$rec.Enable } else { $null }
    $r.Zones = @(Get-DnsServerZone | Where-Object { -not $_.IsAutoCreated -and $_.ZoneName -ne 'TrustAnchors' } | ForEach-Object {
      $z = $_; $ag = $null
      if ($z.ZoneType -eq 'Primary') { try { $ag = Get-DnsServerZoneAging -Name $z.ZoneName -ErrorAction Stop } catch { } }
      [pscustomobject]@{ Zone = $z.ZoneName; Type = [string]$z.ZoneType; Inverse = [bool]$z.IsReverseLookupZone; IntegreeAD = [bool]$z.IsDsIntegrated
        Replication = [string]$z.ReplicationScope; MiseAJour = [string]$z.DynamicUpdate; Vieillissement = $(if ($ag) { [bool]$ag.AgingEnabled } else { $null })
        NonActualisation = $(if ($ag) { [string]$ag.NoRefreshInterval } else { '' }); Actualisation = $(if ($ag) { [string]$ag.RefreshInterval } else { '' })
        Suspendue = [bool]$z.IsPaused; Arretee = [bool]$z.IsShutdown } })
    $sc = Get-DnsServerScavenging -ErrorAction SilentlyContinue
    $r.Nettoyage = if ($sc) { [pscustomobject]@{ Actif = [bool]$sc.ScavengingState; Intervalle = [string]$sc.ScavengingInterval; Dernier = $sc.LastScavengeTime } } else { $null }
    # enregistrements dynamiques anciens (zones directes intégrées AD)
    $limite = (Get-Date).AddDays(-30)
    $r.Anciens = @($r.Zones | Where-Object { $_.Type -eq 'Primary' -and -not $_.Inverse -and $_.Zone -notmatch '^_msdcs\.' } | ForEach-Object {
      $zn = $_.Zone
      try {
        $rr = @(Get-DnsServerResourceRecord -ZoneName $zn -RRType A -ErrorAction Stop | Where-Object { $_.Timestamp })
        $old = @($rr | Where-Object { $_.Timestamp -lt $limite })
        [pscustomobject]@{ Zone = $zn; Dynamiques = $rr.Count; PlusDe30j = $old.Count; PlusAncien = $(if ($old.Count) { ($old | Sort-Object Timestamp | Select-Object -First 1).Timestamp } else { $null }) }
      } catch { } })
    $st = Get-DnsServerSetting -All -ErrorAction SilentlyContinue
    $r.Ecoute = if ($st) { @($st.ListeningIPAddress | ForEach-Object { [string]$_ }) } else { @() }
    $r.Module = $true
  } catch { $r.Module = $false; $r.Erreurs += "Module DnsServer : $($_.Exception.Message)" }
  # résolution par ce serveur lui-même
  $t = @()
  foreach ($n in @($testExt)) {
    try { $a = Resolve-DnsName -Name $n -Server 127.0.0.1 -DnsOnly -ErrorAction Stop | Where-Object { $_.IPAddress } | Select-Object -First 1; $t += [pscustomobject]@{ Nom = $n; Resultat = 'OK'; Reponse = $a.IPAddress } }
    catch { $t += [pscustomobject]@{ Nom = $n; Resultat = 'ECHEC'; Reponse = $_.Exception.Message } }
  }
  $dom = $null; try { $dom = (Get-CimInstance Win32_ComputerSystem).Domain } catch { }
  if ($dom -and $dom -notmatch '^WORKGROUP$') {
    $r.Domaine = $dom
    foreach ($n in @("_ldap._tcp.dc._msdcs.$dom", "_kerberos._tcp.$dom")) {
      try { $s = @(Resolve-DnsName -Name $n -Type SRV -Server 127.0.0.1 -DnsOnly -ErrorAction Stop | Where-Object { $_.NameTarget }); $t += [pscustomobject]@{ Nom = $n; Resultat = 'OK'; Reponse = (($s | ForEach-Object { $_.NameTarget }) -join ', ') } }
      catch { $t += [pscustomobject]@{ Nom = $n; Resultat = 'ECHEC'; Reponse = $_.Exception.Message } }
    }
  }
  $r.Tests = $t
  # DNS configurés sur les cartes du serveur
  $r.Clients = @(Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.ServerAddresses } | ForEach-Object { [pscustomobject]@{ Carte = $_.InterfaceAlias; ServeursDNS = ($_.ServerAddresses -join ', ') } })
  $r.Events = @(try { Get-WinEvent -FilterHashtable @{ LogName = 'DNS Server'; Level = 1, 2, 3; StartTime = (Get-Date).AddDays(-7) } -MaxEvents 300 -ErrorAction Stop | ForEach-Object { [pscustomobject]@{ Date = $_.TimeCreated; Niveau = $_.LevelDisplayName; Id = $_.Id; Message = (($_.Message -split "`r?`n")[0]) } } } catch { })
  $r
}

Show-Etape "Collecte sur $($cible.Nom)..."
try { $r = Invoke-Cible $cible $Collecte @($testExt) } catch { $r = $null; Add-Check -Rubrique 'svc' -Titre 'Collecte' -Statut 'CRIT' -Resume "Collecte impossible : $($_.Exception.Message)" }

if ($r) {
  Show-Etape 'Analyse'
  foreach ($e in @($r.Erreurs)) { Add-Check -Rubrique 'svc' -Titre 'Erreur de collecte' -Statut 'ATT' -Resume $e }
  $h = $r.Host

  # --- Service
  if (-not $r.Service) { Add-Check -Rubrique 'svc' -Titre 'Service DNS Server' -Statut 'CRIT' -Resume "Rôle DNS absent sur $h" -Cible $h -Reco 'Vérifier le nom du serveur : ce n''est pas un serveur DNS Windows.' }
  else {
    $ok = $r.Service.Etat -eq 'Running'
    Add-Check -Rubrique 'svc' -Titre 'Service DNS Server' -Statut $(if ($ok) { 'OK' } else { 'CRIT' }) -Resume "$($r.Service.Etat) · démarrage $($r.Service.Demarrage)" -Cible $h `
      -Cmds $(if (-not $ok) { @(Cmd 'Démarrer le service DNS' 'Start-Service DNS') })
  }
  if ($r.Module) {
    $ec = @($r.Ecoute)
    Add-Check -Rubrique 'svc' -Titre 'Adresses d''écoute' -Statut 'INFO' -Resume $(if ($ec.Count) { $ec -join ', ' } else { 'Toutes les adresses' }) -Cible $h
    if ($null -ne $r.Recursion) {
      Add-Check -Rubrique 'svc' -Titre 'Récursivité' -Statut $(if ($r.Recursion) { 'OK' } else { 'ATT' }) -Resume $(if ($r.Recursion) { 'Activée : le serveur résout les noms Internet pour les clients' } else { 'Désactivée : les clients ne peuvent pas résoudre les noms Internet via ce serveur' }) -Cible $h
    }
  }
  # cartes réseau du serveur
  $cl = @($r.Clients)
  if ($cl.Count) {
    $pub = @($cl | Where-Object { $_.ServeursDNS -match '(^|, )(8\.8\.[48]\.[48]|1\.1\.1\.1|1\.0\.0\.1|9\.9\.9\.9|208\.67\.22[02]\.22[02])' })
    Add-Check -Rubrique 'svc' -Titre 'DNS configurés sur les cartes du serveur' -Statut $(if ($pub.Count -and $r.Domaine) { 'ATT' } else { 'OK' }) `
      -Resume $(if ($pub.Count -and $r.Domaine) { 'Un DNS public est configuré sur une carte : il ne connaît pas le domaine (échecs aléatoires d''authentification, de GPO)' } else { 'Pas de DNS public sur les cartes' }) -Table (To-Table $cl) -Cible $h `
      -Reco $(if ($pub.Count -and $r.Domaine) { 'Sur un serveur du domaine, ne déclarer que les DNS internes (contrôleurs) ; les DNS publics vont dans les redirecteurs.' })
  }

  # --- Redirecteurs
  if ($r.Module) {
    $tr = @($r.TestsRedir); $ko = @($tr | Where-Object { -not $_.Repond })
    if (-not @($r.Redirecteurs).Count) {
      Add-Check -Rubrique 'resol' -Titre 'Redirecteurs' -Statut 'ATT' -Resume 'Aucun redirecteur : résolution Internet par les serveurs racine (plus lente, moins maîtrisée)' -Cible $h `
        -Reco 'Déclarer deux redirecteurs (DNS du FAI ou public de confiance).' -Cmds @(Cmd 'Déclarer des redirecteurs (adapter les adresses)' 'Set-DnsServerForwarder -IPAddress 1.1.1.1, 9.9.9.9 -PassThru')
    } else {
      Add-Check -Rubrique 'resol' -Titre 'Redirecteurs' -Statut $(if ($ko.Count -eq $tr.Count) { 'CRIT' } elseif ($ko.Count) { 'ATT' } elseif ($tr.Count -lt 2) { 'ATT' } else { 'OK' }) `
        -Resume $(if ($ko.Count) { "$($ko.Count) redirecteur(s) sur $($tr.Count) ne répond(ent) pas" } elseif ($tr.Count -lt 2) { 'Un seul redirecteur : aucune redondance' } else { "$($tr.Count) redirecteurs, tous répondent" }) `
        -Table (To-Table $tr) -Cible $h -Reco $(if ($ko.Count) { 'Remplacer les redirecteurs qui ne répondent plus (ancien FAI, ancien pare-feu...).' } elseif ($tr.Count -lt 2) { 'Ajouter un second redirecteur.' }) `
        -Cmds $(if ($ko.Count) { @(Cmd 'Retirer les redirecteurs muets' ("Remove-DnsServerForwarder -IPAddress " + (($ko | ForEach-Object { $_.Redirecteur }) -join ', ') + " -Force")) })
    }
  }
  foreach ($t in @($r.Tests)) {
    $srv = $t.Nom -match '^_'
    Add-Check -Rubrique 'resol' -Titre "Résolution de $($t.Nom)" -Statut $(if ($t.Resultat -eq 'OK') { 'OK' } else { 'CRIT' }) -Resume $t.Reponse -Cible $h `
      -Reco $(if ($t.Resultat -ne 'OK') { if ($srv) { 'Les enregistrements SRV du domaine sont introuvables : les postes ne trouvent plus de contrôleur. Relancer l''enregistrement (Netlogon) sur chaque contrôleur.' } else { 'Le serveur ne résout pas Internet : vérifier redirecteurs, récursivité et pare-feu sortant (UDP/TCP 53).' } }) `
      -Cmds $(if ($t.Resultat -ne 'OK' -and $srv) { @(Cmd 'Réenregistrer les SRV du contrôleur' 'nltest /dsregdns; Restart-Service Netlogon') })
  }

  # --- Zones
  if ($r.Module) {
    $zones = @($r.Zones)
    Add-Check -Rubrique 'zones' -Titre 'Zones hébergées' -Statut 'INFO' -Resume "$($zones.Count) zone(s) dont $(@($zones | Where-Object { $_.Inverse }).Count) inverse(s)" -Table (To-Table $zones @('Zone', 'Type', 'IntegreeAD', 'Replication', 'MiseAJour', 'Vieillissement')) -Cible $h
    $arr = @($zones | Where-Object { $_.Suspendue -or $_.Arretee })
    if ($arr.Count) { Add-Check -Rubrique 'zones' -Titre 'Zones suspendues ou arrêtées' -Statut 'CRIT' -Resume (($arr | ForEach-Object { $_.Zone }) -join ', ') -Cible $h -Cmds @($arr | ForEach-Object { Cmd "Reprendre la zone $($_.Zone)" "Resume-DnsServerZone -Name $(Q $_.Zone)" }) }
    $nonSec = @($zones | Where-Object { $_.Type -eq 'Primary' -and $_.MiseAJour -eq 'NonsecureAndSecure' })
    Add-Check -Rubrique 'zones' -Titre 'Mises à jour dynamiques' -Statut $(if ($nonSec.Count) { 'ATT' } else { 'OK' }) `
      -Resume $(if ($nonSec.Count) { "Non sécurisées acceptées sur : $(($nonSec | ForEach-Object { $_.Zone }) -join ', ')" } else { 'Aucune zone n''accepte de mise à jour non sécurisée' }) -Cible $h `
      -Reco $(if ($nonSec.Count) { 'N''importe quel appareil peut créer ou écraser un enregistrement. Passer en « Sécurisé uniquement » les zones intégrées AD (vérifier avant les appareils hors domaine qui s''inscrivent eux-mêmes).' }) `
      -Cmds @($nonSec | Where-Object { $_.IntegreeAD } | ForEach-Object { Cmd "Sécuriser la zone $($_.Zone)" "Set-DnsServerPrimaryZone -Name $(Q $_.Zone) -DynamicUpdate Secure" })
    $dirAd = @($zones | Where-Object { $_.Type -eq 'Primary' -and $_.IntegreeAD -and -not $_.Inverse -and $_.Zone -notmatch '^_msdcs\.' })
    $inv = @($zones | Where-Object { $_.Inverse })
    if ($dirAd.Count -and -not $inv.Count) { Add-Check -Rubrique 'zones' -Titre 'Zones de recherche inversée' -Statut 'ATT' -Resume 'Aucune zone inverse : nslookup et certains outils affichent des erreurs, journaux sans noms' -Cible $h -Reco 'Créer la zone inverse du réseau local (ex. Add-DnsServerPrimaryZone -NetworkId 192.168.1.0/24 -ReplicationScope Domain).' }
  }

  # --- Nettoyage
  if ($r.Module) {
    $sc = $r.Nettoyage
    $agKo = @($r.Zones | Where-Object { $_.Type -eq 'Primary' -and $_.IntegreeAD -and $_.Zone -notmatch '^_msdcs\.' -and $_.Vieillissement -eq $false })
    if ($sc) {
      Add-Check -Rubrique 'nett' -Titre 'Nettoyage automatique du serveur' -Statut $(if ($sc.Actif) { 'OK' } else { 'ATT' }) `
        -Resume $(if ($sc.Actif) { "Actif, intervalle $($sc.Intervalle)$(if ($sc.Dernier) { ' · dernier passage ' + ([datetime]$sc.Dernier).ToString('dd/MM/yyyy') })" } else { 'Désactivé : les enregistrements des postes disparus s''accumulent (mauvaises résolutions, adresses réutilisées)' }) -Cible $h `
        -Reco $(if (-not $sc.Actif) { 'Activer le nettoyage sur UN seul serveur DNS, avec un intervalle de 7 jours, et le vieillissement sur les zones dynamiques. Délai : les enregistrements anciens ne sont supprimés qu''après NoRefresh + Refresh (14 jours).' }) `
        -Cmds $(if (-not $sc.Actif) { @(Cmd 'Activer le nettoyage (7 jours) sur ce serveur' 'Set-DnsServerScavenging -ScavengingState $true -ScavengingInterval 7.00:00:00 -RefreshInterval 7.00:00:00 -NoRefreshInterval 7.00:00:00') })
    }
    Add-Check -Rubrique 'nett' -Titre 'Vieillissement des zones dynamiques' -Statut $(if ($agKo.Count) { 'ATT' } else { 'OK' }) `
      -Resume $(if ($agKo.Count) { "Désactivé sur : $(($agKo | ForEach-Object { $_.Zone }) -join ', ')" } else { 'Activé sur toutes les zones dynamiques intégrées AD' }) -Cible $h `
      -Table (To-Table @($r.Zones | Where-Object { $_.Type -eq 'Primary' }) @('Zone', 'Vieillissement', 'NonActualisation', 'Actualisation')) `
      -Cmds @($agKo | ForEach-Object { Cmd "Activer le vieillissement sur $($_.Zone)" "Set-DnsServerZoneAging -Name $(Q $_.Zone) -Aging `$true -RefreshInterval 7.00:00:00 -NoRefreshInterval 7.00:00:00" })
    $anc = @($r.Anciens | Where-Object { $_ })
    if ($anc.Count) {
      $tot = ($anc | Measure-Object PlusDe30j -Sum).Sum
      Add-Check -Rubrique 'nett' -Titre 'Enregistrements dynamiques de plus de 30 jours' -Statut $(if ($tot -gt 50) { 'ATT' } elseif ($tot) { 'INFO' } else { 'OK' }) -Resume "$tot enregistrement(s) A non rafraîchi(s) depuis 30 jours" -Table (To-Table $anc) -Cible $h `
        -Reco $(if ($tot) { 'Ce sont souvent des postes disparus. Ils seront supprimés automatiquement une fois le nettoyage et le vieillissement actifs.' })
    }
  }

  # --- Journal
  $ev = @($r.Events)
  $err = @($ev | Where-Object { $_.Niveau -match 'Erreur|Error|Critique|Critical' })
  Add-Check -Rubrique 'jour' -Titre 'Journal DNS Server (7 derniers jours)' -Statut $(if ($err.Count -gt 10) { 'ATT' } elseif ($ev.Count) { 'INFO' } else { 'OK' }) `
    -Resume $(if ($ev.Count) { "$($err.Count) erreur(s), $($ev.Count - $err.Count) avertissement(s)" } else { 'Aucune erreur ni avertissement' }) -Table (To-Table ($ev | Select-Object -First 100)) -Cible $h `
    -Reco $(if ($err.Count -gt 10) { 'Regrouper par Id dans le tableau : 4013 (AD pas prêt au démarrage) est bénin s''il est isolé ; 4000/4007 signalent un problème de zone intégrée AD.' })
}

$nomCible = if ($cible) { $cible.Nom } else { 'inconnu' }
Save-Audit ("Audit-DNS_{0}_{1:yyyyMMdd_HHmm}.html" -f $nomCible, $script:Debut) 'Audit DNS' $client $Rubriques $Prerequis
