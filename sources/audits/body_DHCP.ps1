# ==================================================================================
#  AUDIT DHCP (serveur DHCP Windows)
# ==================================================================================
$Rubriques = [ordered]@{
  'svc'    = @('Service et autorisation', '🖥️')
  'scopes' = @('Étendues et occupation', '📊')
  'opt'    = @('Options distribuées', '⚙️')
  'ha'     = @('Haute disponibilité', '🔀')
  'base'   = @('Base, sauvegarde et journaux', '💾')
}
$Prerequis = "À lancer sur le serveur DHCP, ou depuis un poste avec WinRM vers ce serveur. Compte administrateur (lecture ; membre de « Administrateurs DHCP » au minimum). Lecture seule : aucune modification."

Show-Titre 'Audit DHCP' "Service, autorisation AD, étendues (occupation), options, basculement, sauvegarde de la base.`nLecture seule : le script ne modifie rien."
$client = Ask-Text 'Client / site (pour le rapport)' ''
$cible = Get-Cible 'DHCP' 'Indiquer le serveur DHCP. Entrée si ce script tourne déjà dessus.'

$Collecte = {
  $r = @{ Host = $env:COMPUTERNAME; Erreurs = @() }
  $svc = Get-Service DHCPServer -ErrorAction SilentlyContinue
  $r.Service = if ($svc) { [pscustomobject]@{ Etat = [string]$svc.Status; Demarrage = [string]$svc.StartType } } else { $null }
  try {
    Import-Module DhcpServer -ErrorAction Stop
    $set = Get-DhcpServerSetting -ErrorAction Stop
    $r.Reglages = [pscustomobject]@{ Autorise = [bool]$set.IsAuthorized; Domaine = [bool]$set.IsDomainJoined; DetectionConflits = $set.ConflictDetectionAttempts; BootpDynamique = [bool]$set.DynamicBootp }
    $r.Autorises = @(try { Get-DhcpServerInDC -ErrorAction Stop | ForEach-Object { [pscustomobject]@{ Serveur = $_.DnsName; IP = [string]$_.IPAddress } } } catch { })
    $r.Scopes = @(Get-DhcpServerv4Scope -ErrorAction Stop | ForEach-Object {
      $s = $_; $st = Get-DhcpServerv4ScopeStatistics -ScopeId $s.ScopeId -ErrorAction SilentlyContinue
      $o = @(Get-DhcpServerv4OptionValue -ScopeId $s.ScopeId -ErrorAction SilentlyContinue)
      $res = @(Get-DhcpServerv4Reservation -ScopeId $s.ScopeId -ErrorAction SilentlyContinue).Count
      [pscustomobject]@{ Etendue = [string]$s.ScopeId; Nom = $s.Name; Etat = [string]$s.State; Debut = [string]$s.StartRange; Fin = [string]$s.EndRange; Masque = [string]$s.SubnetMask
        Bail = [string]$s.LeaseDuration; Utilisees = $(if ($st) { [int]$st.InUse } else { $null }); Libres = $(if ($st) { [int]$st.Free } else { $null }); Pourcent = $(if ($st) { [math]::Round($st.PercentageInUse, 1) } else { $null })
        Reservations = $res
        Routeur = (@($o | Where-Object { $_.OptionId -eq 3 } | ForEach-Object { $_.Value }) -join ', ')
        DNS = (@($o | Where-Object { $_.OptionId -eq 6 } | ForEach-Object { $_.Value }) -join ', ')
        DomaineDNS = (@($o | Where-Object { $_.OptionId -eq 15 } | ForEach-Object { $_.Value }) -join ', ') } })
    $so = @(Get-DhcpServerv4OptionValue -ErrorAction SilentlyContinue)
    $r.OptServeur = [pscustomobject]@{ Routeur = (@($so | Where-Object { $_.OptionId -eq 3 } | ForEach-Object { $_.Value }) -join ', '); DNS = (@($so | Where-Object { $_.OptionId -eq 6 } | ForEach-Object { $_.Value }) -join ', '); DomaineDNS = (@($so | Where-Object { $_.OptionId -eq 15 } | ForEach-Object { $_.Value }) -join ', ') }
    $r.OptServeurListe = @($so | ForEach-Object { [pscustomobject]@{ Option = $_.OptionId; Nom = $_.Name; Valeur = ($_.Value -join ', ') } })
    $r.Failover = @(try { Get-DhcpServerv4Failover -ErrorAction Stop | ForEach-Object { [pscustomobject]@{ Relation = $_.Name; Partenaire = $_.PartnerServer; Mode = [string]$_.Mode; Etat = [string]$_.State; Etendues = (@($_.ScopeId | ForEach-Object { [string]$_ }) -join ', '); Repartition = $_.LoadBalancePercent } } } catch { })
    $db = Get-DhcpServerDatabase -ErrorAction SilentlyContinue
    $r.Base = if ($db) { [pscustomobject]@{ Fichier = $db.FileName; Sauvegarde = $db.BackupPath; IntervalleMin = $db.BackupInterval; Nettoyage = $db.CleanupInterval } } else { $null }
    if ($db -and $db.BackupPath -and (Test-Path $db.BackupPath)) { $r.DerniereSauvegarde = (Get-ChildItem $db.BackupPath -Recurse -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime }
    $au = Get-DhcpServerAuditLog -ErrorAction SilentlyContinue
    $r.Audit = if ($au) { [bool]$au.Enable } else { $null }
    $dc = Get-DhcpServerv4DnsSetting -ErrorAction SilentlyContinue
    $r.DnsMaj = if ($dc) { [pscustomobject]@{ MiseAJour = [string]$dc.DynamicUpdates; SupprimerALaFin = [bool]$dc.DeleteDnsRROnLeaseExpiry } } else { $null }
    $cr = Get-DhcpServerDnsCredential -ErrorAction SilentlyContinue
    $r.DnsCompte = if ($cr -and $cr.UserName) { "$($cr.DomainName)\$($cr.UserName)" } else { '' }
    $r.EstDC = [bool](Get-Service NTDS -ErrorAction SilentlyContinue)
    $r.Module = $true
  } catch { $r.Module = $false; $r.Erreurs += "Module DhcpServer : $($_.Exception.Message)" }
  # les DNS distribués répondent-ils ?
  $ips = @(); foreach ($s in @($r.Scopes) + @($r.OptServeur)) { if ($s -and $s.DNS) { $ips += ($s.DNS -split ',\s*') } }
  $r.TestsDns = @($ips | Where-Object { $_ } | Select-Object -Unique | ForEach-Object {
    $ip = $_; try { $null = Resolve-DnsName -Name 'www.microsoft.com' -Server $ip -DnsOnly -QuickTimeout -ErrorAction Stop; [pscustomobject]@{ DNS = $ip; Repond = $true } } catch { [pscustomobject]@{ DNS = $ip; Repond = $false } } })
  $r.Events = @(try { Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Dhcp-Server/Admin'; Level = 1, 2, 3; StartTime = (Get-Date).AddDays(-7) } -MaxEvents 200 -ErrorAction Stop | ForEach-Object { [pscustomobject]@{ Date = $_.TimeCreated; Niveau = $_.LevelDisplayName; Id = $_.Id; Message = (($_.Message -split "`r?`n")[0]) } } } catch { })
  $r
}

Show-Etape "Collecte sur $($cible.Nom)..."
try { $r = Invoke-Cible $cible $Collecte } catch { $r = $null; Add-Check -Rubrique 'svc' -Titre 'Collecte' -Statut 'CRIT' -Resume "Collecte impossible : $($_.Exception.Message)" }

if ($r) {
  Show-Etape 'Analyse'
  foreach ($e in @($r.Erreurs)) { Add-Check -Rubrique 'svc' -Titre 'Erreur de collecte' -Statut 'ATT' -Resume $e }
  $h = $r.Host

  # --- Service et autorisation
  if (-not $r.Service) { Add-Check -Rubrique 'svc' -Titre 'Service Serveur DHCP' -Statut 'CRIT' -Resume "Rôle DHCP absent sur $h" -Cible $h }
  else {
    $ok = $r.Service.Etat -eq 'Running'
    Add-Check -Rubrique 'svc' -Titre 'Service Serveur DHCP' -Statut $(if ($ok) { 'OK' } else { 'CRIT' }) -Resume "$($r.Service.Etat) · démarrage $($r.Service.Demarrage)" -Cible $h -Cmds $(if (-not $ok) { @(Cmd 'Démarrer le service DHCP' 'Start-Service DHCPServer') })
  }
  if ($r.Module) {
    $g = $r.Reglages
    if ($g.Domaine) {
      Add-Check -Rubrique 'svc' -Titre 'Autorisation dans Active Directory' -Statut $(if ($g.Autorise) { 'OK' } else { 'CRIT' }) -Resume $(if ($g.Autorise) { 'Serveur autorisé' } else { 'Serveur NON autorisé : il ne distribue aucune adresse' }) -Table (To-Table $r.Autorises) -Cible $h `
        -Cmds $(if (-not $g.Autorise) { @(Cmd 'Autoriser ce serveur dans AD' "Add-DhcpServerInDC -DnsName $(Q $h)") })
    } else { Add-Check -Rubrique 'svc' -Titre 'Autorisation dans Active Directory' -Statut 'INFO' -Resume 'Serveur hors domaine (groupe de travail) : pas d''autorisation AD' -Cible $h }
    Add-Check -Rubrique 'svc' -Titre 'Détection de conflits d''adresses' -Statut 'INFO' -Resume $(if ($g.DetectionConflits) { "$($g.DetectionConflits) tentative(s) de ping avant attribution" } else { 'Désactivée (normal ; à activer temporairement après une restauration de base)' }) -Cible $h

    # --- Étendues
    $sc = @($r.Scopes)
    if (-not $sc.Count) { Add-Check -Rubrique 'scopes' -Titre 'Étendues IPv4' -Statut 'ATT' -Resume 'Aucune étendue configurée' -Cible $h }
    foreach ($s in $sc) {
      $p = $s.Pourcent; $act = $s.Etat -eq 'Active'
      $stat = if (-not $act) { 'INFO' } elseif ($null -eq $p) { 'ATT' } elseif ($p -ge 95) { 'CRIT' } elseif ($p -ge 85) { 'ATT' } else { 'OK' }
      Add-Check -Rubrique 'scopes' -Titre "Étendue $($s.Etendue) — $($s.Nom)" -Statut $stat `
        -Resume $(if (-not $act) { 'Étendue désactivée' } else { "$p % occupée ($($s.Utilisees) utilisées, $($s.Libres) libres) · plage $($s.Debut) - $($s.Fin) · bail $($s.Bail) · $($s.Reservations) réservation(s)" }) `
        -Table (To-Table @($s) @('Etendue', 'Nom', 'Etat', 'Debut', 'Fin', 'Masque', 'Bail', 'Utilisees', 'Libres', 'Pourcent', 'Reservations')) -Cible $h `
        -Reco $(if ($stat -in 'ATT', 'CRIT' -and $act -and $null -ne $p) { 'Étendue presque pleine : nouveaux appareils sans adresse. Élargir la plage, raccourcir le bail (ex. 1 jour pour un réseau invités) ou supprimer les baux obsolètes.' }) `
        -Cmds $(if ($stat -in 'ATT', 'CRIT' -and $act -and $null -ne $p) { @(Cmd 'Raccourcir le bail à 1 jour' "Set-DhcpServerv4Scope -ScopeId $($s.Etendue) -LeaseDuration 1.00:00:00") })
    }

    # --- Options
    $os = $r.OptServeur
    Add-Check -Rubrique 'opt' -Titre 'Options au niveau du serveur' -Statut 'INFO' -Resume "$(@($r.OptServeurListe).Count) option(s)" -Table (To-Table $r.OptServeurListe) -Cible $h
    foreach ($s in @($sc | Where-Object { $_.Etat -eq 'Active' })) {
      $rt = if ($s.Routeur) { $s.Routeur } else { $os.Routeur }; $dn = if ($s.DNS) { $s.DNS } else { $os.DNS }; $dd = if ($s.DomaineDNS) { $s.DomaineDNS } else { $os.DomaineDNS }
      $manque = @(); if (-not $rt) { $manque += 'passerelle (003)' }; if (-not $dn) { $manque += 'serveurs DNS (006)' }; if (-not $dd -and $r.Reglages.Domaine) { $manque += 'nom de domaine DNS (015)' }
      $pub = $dn -match '(^|, )(8\.8\.[48]\.[48]|1\.1\.1\.1|1\.0\.0\.1|9\.9\.9\.9)'
      Add-Check -Rubrique 'opt' -Titre "Options de l'étendue $($s.Etendue)" -Statut $(if ($manque.Count -and $manque -match 'passerelle|DNS \(') { 'CRIT' } elseif ($manque.Count -or ($pub -and $r.Reglages.Domaine)) { 'ATT' } else { 'OK' }) `
        -Resume $(if ($manque.Count) { "Manquant : $($manque -join ', ')" } else { "Passerelle $rt · DNS $dn · domaine $dd" }) -Cible $h `
        -Reco $(if ($pub -and $r.Reglages.Domaine) { 'Un DNS public est distribué à des postes du domaine : ils ne trouveront pas toujours les contrôleurs. Ne distribuer que les DNS internes.' } elseif ($manque.Count) { 'Compléter les options manquantes (au niveau de l''étendue ou du serveur).' }) `
        -Cmds $(if ($manque -match 'DNS \(') { @(Cmd 'Définir les DNS de l''étendue (adapter)' "Set-DhcpServerv4OptionValue -ScopeId $($s.Etendue) -DnsServer 192.168.1.10") })
    }
    $td = @($r.TestsDns); $ko = @($td | Where-Object { -not $_.Repond })
    if ($td.Count) { Add-Check -Rubrique 'opt' -Titre 'DNS distribués : réponse' -Statut $(if ($ko.Count) { 'CRIT' } else { 'OK' }) -Resume $(if ($ko.Count) { "Ne répond pas : $(($ko | ForEach-Object { $_.DNS }) -join ', ')" } else { 'Tous les DNS distribués répondent' }) -Table (To-Table $td) -Cible $h }
    if ($r.DnsMaj) {
      $cmpt = $r.EstDC -and -not $r.DnsCompte
      Add-Check -Rubrique 'opt' -Titre 'Inscription DNS par le DHCP' -Statut $(if ($cmpt) { 'ATT' } else { 'INFO' }) -Resume "Mise à jour : $($r.DnsMaj.MiseAJour) · suppression à l'expiration : $($r.DnsMaj.SupprimerALaFin)$(if ($r.DnsCompte) { ' · compte ' + $r.DnsCompte })" -Cible $h `
        -Reco $(if ($cmpt) { 'DHCP installé sur un contrôleur sans compte dédié pour les mises à jour DNS : les enregistrements sont créés au nom du contrôleur (risque de détournement). Déclarer un compte utilisateur dédié sans privilège.' }) `
        -Cmds $(if ($cmpt) { @(Cmd 'Déclarer le compte d''inscription DNS' 'Set-DhcpServerDnsCredential -Credential (Get-Credential -Message "Compte dédié DHCP-DNS")') })
    }

    # --- Haute disponibilité
    $fo = @($r.Failover)
    if ($fo.Count) {
      $koF = @($fo | Where-Object { $_.Etat -ne 'Normal' })
      Add-Check -Rubrique 'ha' -Titre 'Basculement DHCP (failover)' -Statut $(if ($koF.Count) { 'CRIT' } else { 'OK' }) -Resume $(if ($koF.Count) { "Relation(s) hors état Normal : $(($koF | ForEach-Object { $_.Relation + ' (' + $_.Etat + ')' }) -join ', ')" } else { "$($fo.Count) relation(s) en état Normal" }) -Table (To-Table $fo) -Cible $h `
        -Reco $(if ($koF.Count) { 'Vérifier la communication avec le partenaire (TCP 647) et l''heure des deux serveurs ; après retour, répliquer la configuration.' }) `
        -Cmds $(if ($koF.Count) { @($koF | ForEach-Object { Cmd "Répliquer la relation $($_.Relation)" "Invoke-DhcpServerv4FailoverReplication -Name $(Q $_.Relation) -Force" }) })
      $hors = @($sc | Where-Object { $_.Etat -eq 'Active' -and (($fo | ForEach-Object { $_.Etendues }) -join ', ') -notmatch [regex]::Escape($_.Etendue) })
      if ($hors.Count) { Add-Check -Rubrique 'ha' -Titre 'Étendues hors basculement' -Statut 'ATT' -Resume (($hors | ForEach-Object { $_.Etendue }) -join ', ') -Cible $h -Reco 'Ajouter ces étendues à la relation de basculement (Add-DhcpServerv4FailoverScope).' }
    } else {
      Add-Check -Rubrique 'ha' -Titre 'Basculement DHCP (failover)' -Statut 'ATT' -Resume 'Aucun basculement : si ce serveur tombe, plus aucun appareil n''obtient d''adresse à l''expiration des baux' -Cible $h `
        -Reco 'Configurer un basculement en équilibrage de charge avec un second serveur Windows (Add-DhcpServerv4Failover), ou au minimum documenter la procédure de restauration.'
    }

    # --- Base
    if ($r.Base) {
      $ls = $r.DerniereSauvegarde
      $age = if ($ls) { [int]((Get-Date) - [datetime]$ls).TotalHours } else { $null }
      Add-Check -Rubrique 'base' -Titre 'Sauvegarde automatique de la base' -Statut $(if ($null -eq $age) { 'ATT' } elseif ($age -gt 48) { 'ATT' } else { 'OK' }) `
        -Resume $(if ($null -eq $age) { "Aucun fichier dans $($r.Base.Sauvegarde)" } else { "Dernière sauvegarde il y a $age h dans $($r.Base.Sauvegarde) (toutes les $($r.Base.IntervalleMin) min)" }) -Table (To-Table @($r.Base)) -Cible $h `
        -Reco 'Cette sauvegarde reste sur le serveur : l''inclure dans la sauvegarde (Veeam...) ou exporter régulièrement la configuration.' `
        -Cmds @(Cmd 'Exporter configuration et baux' ("Export-DhcpServer -File " + (Q 'C:\Sauvegardes\dhcp-export.xml') + " -Leases -Force"))
    }
    if ($null -ne $r.Audit) { Add-Check -Rubrique 'base' -Titre 'Journal d''audit DHCP' -Statut $(if ($r.Audit) { 'OK' } else { 'ATT' }) -Resume $(if ($r.Audit) { 'Activé (traçabilité des baux)' } else { 'Désactivé : impossible de savoir quel appareil avait quelle adresse' }) -Cible $h -Cmds $(if (-not $r.Audit) { @(Cmd 'Activer le journal d''audit' 'Set-DhcpServerAuditLog -Enable $true') }) }
  }
  $ev = @($r.Events); $err = @($ev | Where-Object { $_.Niveau -match 'Erreur|Error|Critique|Critical' })
  Add-Check -Rubrique 'base' -Titre 'Journal DHCP Server (7 derniers jours)' -Statut $(if ($err.Count -gt 5) { 'ATT' } elseif ($ev.Count) { 'INFO' } else { 'OK' }) -Resume $(if ($ev.Count) { "$($err.Count) erreur(s), $($ev.Count - $err.Count) avertissement(s)" } else { 'Aucune erreur ni avertissement' }) -Table (To-Table ($ev | Select-Object -First 100)) -Cible $h
}

$nomCible = if ($cible) { $cible.Nom } else { 'inconnu' }
Save-Audit ("Audit-DHCP_{0}_{1:yyyyMMdd_HHmm}.html" -f $nomCible, $script:Debut) 'Audit DHCP' $client $Rubriques $Prerequis
