# ==================================================================================
#  AUDIT ACTIVE DIRECTORY
# ==================================================================================
$Rubriques = [ordered]@{
  'dc'      = @('Contrôleurs et services', '🖥️')
  'repl'    = @('Réplication et santé (dcdiag)', '🔁')
  'fsmo'    = @('Rôles FSMO et niveaux', '👑')
  'temps'   = @('Synchronisation de l''heure', '🕒')
  'mdp'     = @('Mots de passe et comptes', '🔐')
  'secu'    = @('Sécurité de l''annuaire', '🛡️')
  'entra'   = @('Entra Connect (Azure AD Connect)', '☁️')
}
$Prerequis = "À lancer sur un contrôleur de domaine, ou depuis un poste du domaine avec WinRM vers le contrôleur. Compte administrateur du domaine (lecture). Lecture seule : aucune modification."

Show-Titre 'Audit Active Directory' "Contrôleurs, réplication, FSMO, heure, mots de passe, comptes, Entra Connect.`nLecture seule : le script ne modifie rien."
$client = Ask-Text 'Client / site (pour le rapport)' ''
$cible = Get-Cible 'AD (contrôleur de domaine)' 'Indiquer un contrôleur de domaine. Entrée si ce script tourne déjà sur un contrôleur.'

$Collecte = {
  $r = @{ Host = $env:COMPUTERNAME; Erreurs = @() }
  function Txt($sb) { try { (& $sb 2>&1 | Out-String -Width 250) } catch { "[ERREUR] $($_.Exception.Message)" } }
  $r.Services = @(Get-Service -Name NTDS, DNS, Netlogon, kdc, W32Time, DFSR, ADWS -ErrorAction SilentlyContinue | ForEach-Object { [pscustomobject]@{ Service = $_.Name; Nom = $_.DisplayName; Etat = [string]$_.Status; Demarrage = [string]$_.StartType } })
  try {
    Import-Module ActiveDirectory -ErrorAction Stop
    $d = Get-ADDomain; $f = Get-ADForest
    $r.Domaine = [pscustomobject]@{ DNSRoot = $d.DNSRoot; NetBIOS = $d.NetBIOSName; DomainMode = [string]$d.DomainMode; ForestMode = [string]$f.ForestMode
      PDC = $d.PDCEmulator; RID = $d.RIDMaster; Infra = $d.InfrastructureMaster; Schema = $f.SchemaMaster; Naming = $f.DomainNamingMaster; SID = $d.DomainSID.Value; Forest = $f.Name }
    $r.DCs = @(Get-ADDomainController -Filter * | ForEach-Object { [pscustomobject]@{ Nom = $_.HostName; Site = $_.Site; IP = $_.IPv4Address; OS = $_.OperatingSystem; GC = $_.IsGlobalCatalog; RODC = $_.IsReadOnly } })
    $pp = Get-ADDefaultDomainPasswordPolicy
    $r.Pwd = [pscustomobject]@{ MinLength = $pp.MinPasswordLength; Complexity = $pp.ComplexityEnabled; MaxAgeDays = [int]$pp.MaxPasswordAge.TotalDays; History = $pp.PasswordHistoryCount; LockoutThreshold = $pp.LockoutThreshold; LockoutMin = [int]$pp.LockoutDuration.TotalMinutes }
    $r.FGPP = @(Get-ADFineGrainedPasswordPolicy -Filter * -ErrorAction SilentlyContinue | ForEach-Object { [pscustomobject]@{ Nom = $_.Name; Priorite = $_.Precedence; LongueurMin = $_.MinPasswordLength; Complexite = $_.ComplexityEnabled; AppliqueeA = (@($_.AppliesTo) | ForEach-Object { ($_ -split ',')[0] -replace '^CN=' }) -join ', ' } })
    $limite = (Get-Date).AddDays(-90)
    $users = @(Get-ADUser -Filter 'Enabled -eq $true' -Properties LastLogonTimestamp, PasswordNeverExpires, PasswordLastSet, Description, whenCreated)
    $r.NbUsers = $users.Count
    $r.Inactifs = @($users | Where-Object { ($_.LastLogonTimestamp -and [datetime]::FromFileTime($_.LastLogonTimestamp) -lt $limite) -or (-not $_.LastLogonTimestamp -and $_.whenCreated -lt $limite) } | ForEach-Object {
      [pscustomobject]@{ Compte = $_.SamAccountName; Nom = $_.Name; DerniereConnexion = $(if ($_.LastLogonTimestamp) { [datetime]::FromFileTime($_.LastLogonTimestamp) } else { 'jamais' }); Description = $_.Description } })
    $r.SansExpiration = @($users | Where-Object { $_.PasswordNeverExpires } | ForEach-Object { [pscustomobject]@{ Compte = $_.SamAccountName; Nom = $_.Name; MotDePasseDefini = $_.PasswordLastSet; Description = $_.Description } })
    $r.NbOrdinateursInactifs = @(Get-ADComputer -Filter 'Enabled -eq $true' -Properties LastLogonTimestamp | Where-Object { $_.LastLogonTimestamp -and [datetime]::FromFileTime($_.LastLogonTimestamp) -lt $limite }).Count
    $r.Admins = @(Get-ADGroupMember -Identity "$($d.DomainSID.Value)-512" -Recursive | ForEach-Object { [pscustomobject]@{ Compte = $_.SamAccountName; Nom = $_.Name; Type = $_.objectClass } })
    $r.EntAdmins = @(try { Get-ADGroupMember -Identity "$((Get-ADDomain -Identity $f.RootDomain).DomainSID.Value)-519" -Recursive -ErrorAction Stop | ForEach-Object { $_.SamAccountName } } catch { })
    $r.Krbtgt = (Get-ADUser krbtgt -Properties PasswordLastSet).PasswordLastSet
    $r.AdminInvite = Get-ADUser -Identity "$($d.DomainSID.Value)-500" -Properties Enabled, PasswordLastSet, LastLogonTimestamp | ForEach-Object { [pscustomobject]@{ Compte = $_.SamAccountName; Actif = $_.Enabled; MotDePasse = $_.PasswordLastSet } }
    $r.Corbeille = [bool](@((Get-ADOptionalFeature -Filter "Name -like 'Recycle Bin Feature'").EnabledScopes).Count)
    $r.ModuleAD = $true
  } catch { $r.ModuleAD = $false; $r.Erreurs += "Module ActiveDirectory : $($_.Exception.Message)" }
  $r.Dcdiag = Txt { dcdiag /test:Replications /test:NetLogons /test:Services /test:Advertising /test:FsmoCheck /test:SysVolCheck /test:KccEvent /test:MachineAccount }
  $r.ReplCsv = Txt { repadmin /showrepl * /csv }
  $r.ReplSummary = Txt { repadmin /replsummary }
  $r.Fsmo = Txt { netdom query fsmo }
  $r.W32Status = Txt { w32tm /query /status }
  $r.W32Source = Txt { w32tm /query /source }
  $r.W32Monitor = Txt { w32tm /monitor /nowarn }
  $r.Partages = @(Get-SmbShare -Name SYSVOL, NETLOGON -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
  if (Get-Module -ListAvailable -Name ADSync) {
    try {
      Import-Module ADSync -ErrorAction Stop
      $s = Get-ADSyncScheduler
      $r.Sync = [pscustomobject]@{ CycleActif = $s.SyncCycleEnabled; Intervalle = [string]$s.CurrentlyEffectiveSyncCycleInterval; Prochain = $s.NextSyncCycleStartTimeInUTC; Staging = $s.StagingModeEnabled; EnCours = $s.SyncCycleInProgress }
      $r.SyncRuns = @(try { Get-ADSyncRunProfileResult -NumberRequested 15 -ErrorAction Stop | ForEach-Object { [pscustomobject]@{ Connecteur = $_.ConnectorName; Profil = $_.RunProfileName; Resultat = $_.Result; Debut = $_.StartDate; Fin = $_.EndDate } } } catch { })
    } catch { $r.Erreurs += "Entra Connect : $($_.Exception.Message)" }
  }
  $r
}

Show-Etape "Collecte sur $($cible.Nom) (dcdiag et w32tm /monitor peuvent prendre une minute)..."
try { $r = Invoke-Cible $cible $Collecte } catch { $r = $null; Add-Check -Rubrique 'dc' -Titre 'Collecte' -Statut 'CRIT' -Resume "Collecte impossible : $($_.Exception.Message)" }

if ($r) {
  Show-Etape 'Analyse'
  $dom = $r.Domaine
  foreach ($e in @($r.Erreurs)) { Add-Check -Rubrique 'dc' -Titre 'Erreur de collecte' -Statut 'ATT' -Resume $e }

  # --- Services du contrôleur
  $ko = @($r.Services | Where-Object { $_.Etat -ne 'Running' -and $_.Demarrage -ne 'Disabled' })
  Add-Check -Rubrique 'dc' -Titre "Services AD sur $($r.Host)" -Statut $(if ($ko.Count) { 'CRIT' } else { 'OK' }) -Resume $(if ($ko.Count) { "Arrêté(s) : $(($ko | ForEach-Object { $_.Service }) -join ', ')" } else { 'NTDS, DNS, Netlogon, KDC, W32Time, DFSR, ADWS démarrés' }) -Table (To-Table $r.Services) -Cible $r.Host `
    -Reco $(if ($ko.Count) { 'Démarrer les services arrêtés et consulter le journal Directory Service / DFS Replication.' }) -Cmds $(if ($ko.Count) { @(Cmd 'Démarrer les services arrêtés' (($ko | ForEach-Object { "Start-Service $($_.Service)" }) -join '; ')) })
  $sh = @('SYSVOL', 'NETLOGON') | Where-Object { @($r.Partages) -notcontains $_ }
  Add-Check -Rubrique 'dc' -Titre 'Partages SYSVOL et NETLOGON' -Statut $(if ($sh) { 'CRIT' } else { 'OK' }) -Resume $(if ($sh) { "Absent(s) : $($sh -join ', ') — les GPO et scripts de connexion ne sont pas servis" } else { 'Publiés' }) -Cible $r.Host
  if ($r.ModuleAD) {
    $nb = @($r.DCs).Count
    Add-Check -Rubrique 'dc' -Titre 'Contrôleurs de domaine' -Statut $(if ($nb -lt 2) { 'ATT' } else { 'OK' }) -Resume $(if ($nb -lt 2) { "Un seul contrôleur : aucune redondance (panne = plus d'authentification)" } else { "$nb contrôleurs" }) -Table (To-Table $r.DCs) `
      -Reco $(if ($nb -lt 2) { 'Ajouter un second contrôleur de domaine (idéalement sur un autre hôte physique).' })
    $vieux = @($r.DCs | Where-Object { $_.OS -match '2008|2012' })
    if ($vieux.Count) { Add-Check -Rubrique 'dc' -Titre 'Systèmes des contrôleurs' -Statut 'ATT' -Resume "Windows Server hors support : $(($vieux | ForEach-Object { $_.Nom }) -join ', ')" -Reco 'Planifier le remplacement par un contrôleur sous Windows Server 2019 / 2022 / 2025.' }
  } else { Add-Check -Rubrique 'dc' -Titre 'Module ActiveDirectory' -Statut 'CRIT' -Resume 'Indisponible sur la cible : les contrôles de l''annuaire ne peuvent pas être faits' -Reco 'Lancer le script sur un contrôleur de domaine (ou installer RSAT AD DS).' }

  # --- dcdiag
  $dd = Repair-Text $r.Dcdiag
  $tests = @([regex]::Matches($dd, '(?im)^\s*\.{3,}\s*(\S+)\s+(?:a\s+)?(r[ée]ussi|[ée]chou[ée]|passed|failed)\s+(?:le\s+|au\s+)?test\s+(\S+)') | ForEach-Object {
    [pscustomobject]@{ Serveur = $_.Groups[1].Value; Test = $_.Groups[3].Value; Resultat = $(if ($_.Groups[2].Value -match '^(r|p)') { 'Réussi' } else { 'Échec' }) } })
  $echecs = @($tests | Where-Object { $_.Resultat -eq 'Échec' })
  Add-Check -Rubrique 'repl' -Titre 'Diagnostic dcdiag' -Statut $(if ($echecs.Count) { 'CRIT' } elseif ($tests.Count) { 'OK' } else { 'ATT' }) `
    -Resume $(if ($echecs.Count) { "Test(s) en échec : $(($echecs | ForEach-Object { $_.Test }) -join ', ')" } elseif ($tests.Count) { "$($tests.Count) tests réussis" } else { 'Résultat non interprétable : lire la sortie brute' }) `
    -Table (To-Table $tests) -Brut $dd -Cible $r.Host -Reco $(if ($echecs.Count) { 'Lire le détail de chaque test en échec dans la sortie brute ; relancer dcdiag /v /test:<test> pour le détail.' })
  # --- réplication (repadmin /showrepl /csv)
  $csv = @()
  try { $lignes = (Repair-Text $r.ReplCsv) -split "`n" | Where-Object { $_ -match ',' }; if ($lignes.Count -gt 1) { $csv = @($lignes | ConvertFrom-Csv) } } catch { }
  if ($csv.Count -and $csv[0].PSObject.Properties.Name -contains 'Number of Failures') {
    $repl = @($csv | ForEach-Object { [pscustomobject]@{ Destination = $_.'Destination DSA'; Source = $_.'Source DSA'; Contexte = $_.'Naming Context'; Echecs = [int]$_.'Number of Failures'; DernierSucces = $_.'Last Success Time'; DerniereErreur = $_.'Last Failure Status' } })
    $ke = @($repl | Where-Object { $_.Echecs -gt 0 })
    Add-Check -Rubrique 'repl' -Titre 'Réplication entre contrôleurs' -Statut $(if ($ke.Count) { 'CRIT' } else { 'OK' }) -Resume $(if ($ke.Count) { "$($ke.Count) lien(s) en échec" } else { "$($repl.Count) lien(s) de réplication sans échec" }) `
      -Table (To-Table $repl) -Brut (Repair-Text $r.ReplSummary) -Reco $(if ($ke.Count) { 'Identifier la cause (DNS, pare-feu, heure, tombstone) avec repadmin /showrepl ; forcer ensuite une synchronisation.' }) `
      -Cmds $(if ($ke.Count) { @(Cmd 'Forcer la réplication de tous les contextes' 'repadmin /syncall /AdeP') })
  } elseif (@($r.DCs).Count -lt 2) {
    Add-Check -Rubrique 'repl' -Titre 'Réplication entre contrôleurs' -Statut 'INFO' -Resume 'Un seul contrôleur : pas de réplication' -Brut (Repair-Text $r.ReplSummary)
  } else {
    Add-Check -Rubrique 'repl' -Titre 'Réplication entre contrôleurs' -Statut 'ATT' -Resume 'Sortie repadmin non interprétable : lire la sortie brute' -Brut ((Repair-Text $r.ReplSummary) + "`n" + (Repair-Text $r.ReplCsv))
  }

  # --- FSMO et niveaux fonctionnels
  if ($dom) {
    $roles = @(
      [pscustomobject]@{ Role = 'Émulateur PDC'; Detenteur = $dom.PDC }, [pscustomobject]@{ Role = 'Maître RID'; Detenteur = $dom.RID },
      [pscustomobject]@{ Role = 'Maître d''infrastructure'; Detenteur = $dom.Infra }, [pscustomobject]@{ Role = 'Maître de schéma'; Detenteur = $dom.Schema },
      [pscustomobject]@{ Role = 'Maître d''attribution de noms'; Detenteur = $dom.Naming })
    $dcNoms = @($r.DCs | ForEach-Object { $_.Nom.ToLower() })
    $orph = @($roles | Where-Object { $dcNoms -notcontains ([string]$_.Detenteur).ToLower() })
    Add-Check -Rubrique 'fsmo' -Titre 'Rôles FSMO' -Statut $(if ($orph.Count) { 'CRIT' } else { 'OK' }) -Resume $(if ($orph.Count) { "Rôle(s) détenu(s) par un contrôleur absent : $(($orph | ForEach-Object { $_.Role }) -join ', ')" } else { 'Tous les rôles sont détenus par des contrôleurs présents' }) `
      -Table (To-Table $roles) -Brut (Repair-Text $r.Fsmo) -Reco $(if ($orph.Count) { 'Saisir (seize) les rôles orphelins sur un contrôleur sain avec Move-ADDirectoryServerOperationMasterRole -Force, après avoir vérifié que l''ancien contrôleur ne reviendra pas.' })
    $niv = "$($dom.DomainMode) / forêt $($dom.ForestMode)"
    Add-Check -Rubrique 'fsmo' -Titre 'Niveaux fonctionnels' -Statut $(if ($niv -match '2003|2008') { 'ATT' } else { 'OK' }) -Resume "Domaine $niv" -Reco $(if ($niv -match '2003|2008') { 'Relever les niveaux fonctionnels (2016 minimum) une fois tous les contrôleurs à jour : bénéfices sécurité (Kerberos, corbeille AD...).' })
  }

  # --- Heure
  $src = (Repair-Text $r.W32Source).Trim()
  $estPdc = $dom -and ($dom.PDC -split '\.')[0] -ieq $r.Host
  $libre = $src -match 'Local CMOS Clock|Free-running|Horloge CMOS|horloge.*libre'
  Add-Check -Rubrique 'temps' -Titre "Source de temps de $($r.Host)$(if ($estPdc) { ' (émulateur PDC)' })" -Statut $(if ($libre -and $estPdc) { 'CRIT' } elseif ($libre) { 'ATT' } else { 'OK' }) -Resume "Source : $src" -Brut (Repair-Text $r.W32Status) -Cible $r.Host `
    -Reco $(if ($libre -and $estPdc) { 'L''émulateur PDC est la référence de temps du domaine : le synchroniser sur des serveurs NTP externes.' } elseif ($libre) { 'Un contrôleur non-PDC doit suivre la hiérarchie du domaine (NT5DS).' }) `
    -Cmds $(if ($libre -and $estPdc) { @(Cmd 'Configurer le PDC sur le pool NTP français' 'w32tm /config /manualpeerlist:"0.fr.pool.ntp.org,0x8 1.fr.pool.ntp.org,0x8 2.fr.pool.ntp.org,0x8" /syncfromflags:manual /reliable:yes /update; Restart-Service w32time; w32tm /resync /force') } elseif ($libre) { @(Cmd 'Suivre la hiérarchie du domaine' 'w32tm /config /syncfromflags:domhier /update; Restart-Service w32time; w32tm /resync /force') })
  $mon = Repair-Text $r.W32Monitor
  $offs = @([regex]::Matches($mon, '(?ms)^(\S+)\[[^\]]*\]:.*?NTP:\s*([+-]?[\d\.,]+)s') | ForEach-Object { [pscustomobject]@{ Serveur = $_.Groups[1].Value; Decalage_s = [math]::Round([double]($_.Groups[2].Value -replace ',', '.'), 3) } })
  if ($offs.Count) {
    $max = ($offs | ForEach-Object { [math]::Abs($_.Decalage_s) } | Measure-Object -Maximum).Maximum
    Add-Check -Rubrique 'temps' -Titre 'Décalage horaire entre contrôleurs' -Statut $(if ($max -gt 60) { 'CRIT' } elseif ($max -gt 2) { 'ATT' } else { 'OK' }) -Resume "Écart maximal : $max s (Kerberos tolère 5 minutes)" -Table (To-Table $offs) -Brut $mon
  } else { Add-Check -Rubrique 'temps' -Titre 'Décalage horaire entre contrôleurs' -Statut 'INFO' -Resume 'Non mesuré (sortie w32tm /monitor non interprétable)' -Brut $mon }

  # --- Mots de passe et comptes
  if ($r.ModuleAD) {
    $p = $r.Pwd
    $pb = @(); if ($p.MinLength -lt 12) { $pb += "longueur minimale $($p.MinLength) (12 recommandé)" }; if (-not $p.Complexity) { $pb += 'complexité désactivée' }
    if ($p.LockoutThreshold -eq 0) { $pb += 'aucun verrouillage après échecs' }; if ($p.History -lt 12) { $pb += "historique $($p.History) (12+ recommandé)" }
    Add-Check -Rubrique 'mdp' -Titre 'Stratégie de mot de passe du domaine' -Statut $(if ($pb.Count) { 'ATT' } else { 'OK' }) -Resume $(if ($pb.Count) { $pb -join ' ; ' } else { "Longueur $($p.MinLength), complexité, verrouillage à $($p.LockoutThreshold) échecs" }) `
      -Table (To-Table @([pscustomobject]@{ LongueurMin = $p.MinLength; Complexite = $p.Complexity; DureeMax_j = $p.MaxAgeDays; Historique = $p.History; SeuilVerrouillage = $p.LockoutThreshold; DureeVerrouillage_min = $p.LockoutMin })) `
      -Reco $(if ($pb.Count) { 'Recommandations ANSSI : 12 caractères minimum, complexité, verrouillage (ex. 10 échecs / 15 min). À valider avec le client avant application (GPO Default Domain Policy).' })
    if (@($r.FGPP).Count) { Add-Check -Rubrique 'mdp' -Titre 'Stratégies affinées (FGPP)' -Statut 'INFO' -Resume "$(@($r.FGPP).Count) stratégie(s)" -Table (To-Table $r.FGPP) }
    $ina = @($r.Inactifs)
    Add-Check -Rubrique 'mdp' -Titre 'Comptes utilisateurs inactifs depuis 90 jours' -Statut $(if ($ina.Count) { 'ATT' } else { 'OK' }) -Resume "$($ina.Count) compte(s) actif(s) sans connexion depuis 90 jours sur $($r.NbUsers)" -Table (To-Table $ina) `
      -Reco $(if ($ina.Count) { 'Désactiver les comptes des personnes parties (après validation du client) ; ils restent exploitables par un attaquant.' })
    $sx = @($r.SansExpiration)
    Add-Check -Rubrique 'mdp' -Titre 'Mots de passe qui n''expirent jamais' -Statut $(if ($sx.Count -gt 5) { 'ATT' } elseif ($sx.Count) { 'INFO' } else { 'OK' }) -Resume "$($sx.Count) compte(s)" -Table (To-Table $sx) `
      -Reco $(if ($sx.Count) { 'Réserver cette option aux comptes de service (idéalement remplacés par des gMSA) ; la retirer des comptes nominatifs.' })
    if ($r.NbOrdinateursInactifs) { Add-Check -Rubrique 'mdp' -Titre 'Ordinateurs inactifs depuis 90 jours' -Statut 'INFO' -Resume "$($r.NbOrdinateursInactifs) compte(s) ordinateur à nettoyer" }

    # --- Sécurité
    $adm = @($r.Admins)
    Add-Check -Rubrique 'secu' -Titre 'Membres des Admins du domaine' -Statut $(if ($adm.Count -gt 5) { 'ATT' } else { 'OK' }) -Resume "$($adm.Count) membre(s)$(if (@($r.EntAdmins).Count) { ' · Administrateurs de l''entreprise : ' + (@($r.EntAdmins) -join ', ') })" -Table (To-Table $adm) `
      -Reco $(if ($adm.Count -gt 5) { 'Limiter les Admins du domaine au strict nécessaire ; utiliser des comptes d''administration dédiés, distincts des comptes de travail.' })
    if ($r.Krbtgt) {
      $age = [int]((Get-Date) - [datetime]$r.Krbtgt).TotalDays
      Add-Check -Rubrique 'secu' -Titre 'Mot de passe du compte krbtgt' -Statut $(if ($age -gt 365) { 'ATT' } else { 'OK' }) -Resume "Changé il y a $age jour(s)" `
        -Reco $(if ($age -gt 365) { 'Renouveler le mot de passe krbtgt (deux fois, à 24 h d''intervalle minimum) avec le script officiel Microsoft New-KrbtgtKeys.ps1.' })
    }
    Add-Check -Rubrique 'secu' -Titre 'Corbeille Active Directory' -Statut $(if ($r.Corbeille) { 'OK' } else { 'ATT' }) -Resume $(if ($r.Corbeille) { 'Activée' } else { 'Désactivée : un objet supprimé ne peut pas être restauré simplement' }) `
      -Cmds $(if (-not $r.Corbeille -and $dom) { @(Cmd 'Activer la corbeille AD (irréversible, sans impact)' "Enable-ADOptionalFeature 'Recycle Bin Feature' -Scope ForestOrConfigurationSet -Target $(Q $dom.Forest) -Confirm:`$false") })
    if ($r.AdminInvite) { Add-Check -Rubrique 'secu' -Titre 'Compte Administrateur intégré (RID 500)' -Statut 'INFO' -Resume "$($r.AdminInvite.Compte) · actif : $($r.AdminInvite.Actif) · mot de passe changé le $(if ($r.AdminInvite.MotDePasse) { ([datetime]$r.AdminInvite.MotDePasse).ToString('dd/MM/yyyy') } else { '?' })" }
  }

  # --- Entra Connect
  if ($r.Sync) {
    $s = $r.Sync
    Add-Check -Rubrique 'entra' -Titre 'Planificateur de synchronisation' -Statut $(if (-not $s.CycleActif) { 'CRIT' } elseif ($s.Staging) { 'ATT' } else { 'OK' }) `
      -Resume $(if (-not $s.CycleActif) { 'Cycle de synchronisation désactivé' } elseif ($s.Staging) { 'Serveur en mode intermédiaire (staging) : il ne synchronise pas' } else { "Actif, toutes les $($s.Intervalle)" }) -Table (To-Table @($s)) `
      -Cmds $(if (-not $s.CycleActif) { @(Cmd 'Réactiver le cycle de synchronisation' 'Set-ADSyncScheduler -SyncCycleEnabled $true') })
    $runs = @($r.SyncRuns); $err = @($runs | Where-Object { $_.Resultat -and $_.Resultat -ne 'success' })
    if ($runs.Count) { Add-Check -Rubrique 'entra' -Titre 'Dernières exécutions' -Statut $(if ($err.Count) { 'ATT' } else { 'OK' }) -Resume $(if ($err.Count) { "$($err.Count) exécution(s) en erreur sur les $($runs.Count) dernières" } else { "$($runs.Count) dernières exécutions sans erreur" }) -Table (To-Table $runs) -Cmds @(Cmd 'Lancer une synchronisation delta' 'Start-ADSyncSyncCycle -PolicyType Delta') }
  } else { Add-Check -Rubrique 'entra' -Titre 'Entra Connect' -Statut 'INFO' -Resume "Non installé sur $($r.Host) (à auditer sur le serveur qui l'héberge, le cas échéant)" }
}

$nomCible = if ($cible) { $cible.Nom } else { 'inconnu' }
Save-Audit ("Audit-AD_{0}_{1:yyyyMMdd_HHmm}.html" -f $nomCible, $script:Debut) 'Audit Active Directory' $client $Rubriques $Prerequis
