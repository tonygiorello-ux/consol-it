# ==================================================================================
#  AUDIT VEEAM BACKUP & REPLICATION
# ==================================================================================
$Rubriques = [ordered]@{
  'srv'   = @('Serveur et licence', '🖥️')
  'jobs'  = @('Travaux de sauvegarde', '🗂️')
  'repo'  = @('Dépôts (espace)', '💽')
  'conf'  = @('Sauvegarde de configuration', '🧾')
  'infra' = @('Infrastructure gérée', '🔌')
}
$Prerequis = "À lancer sur le serveur Veeam Backup & Replication (v10 à v12), ou depuis un poste avec WinRM vers ce serveur. Compte administrateur Veeam. PowerShell 5.1 (Windows PowerShell) recommandé. Lecture seule : aucune modification."

Show-Titre 'Audit Veeam Backup & Replication' "Licence, version, travaux (dernier résultat, ancienneté), dépôts, sauvegarde de configuration.`nLecture seule : le script ne modifie rien."
$client = Ask-Text 'Client / site (pour le rapport)' ''
$cible = Get-Cible 'Veeam' 'Indiquer le serveur Veeam B&R. Entrée si ce script tourne déjà dessus.'
$maxH = 0; if (-not [int]::TryParse((Ask-Text 'Âge maximal acceptable de la dernière sauvegarde (heures)' '30'), [ref]$maxH)) { $maxH = 30 }

$Collecte = {
  $r = @{ Host = $env:COMPUTERNAME; Erreurs = @() }
  $r.Services = @(Get-Service -Name 'Veeam*' -ErrorAction SilentlyContinue | ForEach-Object { [pscustomobject]@{ Service = $_.Name; Nom = $_.DisplayName; Etat = [string]$_.Status; Demarrage = [string]$_.StartType } })
  $chg = $false
  try { Import-Module Veeam.Backup.PowerShell -DisableNameChecking -WarningAction SilentlyContinue -ErrorAction Stop; $chg = $true } catch { }
  if (-not $chg) { try { Add-PSSnapin VeeamPSSnapIn -ErrorAction Stop; $chg = $true } catch { $r.Erreurs += "Module Veeam introuvable : $($_.Exception.Message)" } }
  $r.Module = $chg
  if (-not $chg) { return $r }
  $WarningPreference = 'SilentlyContinue'
  try { $i = Get-VBRBackupServerInfo -ErrorAction Stop; $r.Version = [string]$i.Build } catch { }
  if (-not $r.Version) { try { $r.Version = (Get-Item "$env:ProgramFiles\Veeam\Backup and Replication\Console\veeam.backup.shell.exe" -ErrorAction Stop).VersionInfo.ProductVersion } catch { } }
  try {
    $l = Get-VBRInstalledLicense -ErrorAction Stop
    $r.Licence = [pscustomobject]@{ Edition = [string]$l.Edition; Type = [string]$l.Type; Statut = [string]$l.Status; Expiration = $l.ExpirationDate; Support = $l.SupportExpirationDate; Proprietaire = $l.LicensedTo
      Instances = $(try { "$($l.InstanceLicenseSummary.UsedInstancesNumber) / $($l.InstanceLicenseSummary.LicensedInstancesNumber)" } catch { '' }) }
  } catch { $r.Erreurs += "Licence : $($_.Exception.Message)" }
  $jobs = @()
  try {
    foreach ($j in @(Get-VBRJob -ErrorAction Stop)) {
      $s = $null; try { $s = $j.FindLastSession() } catch { }
      $jobs += [pscustomobject]@{ Travail = $j.Name; Type = [string]$j.JobType; Planifie = [bool]$j.IsScheduleEnabled; Actif = -not [bool]$j.IsDisabled
        Resultat = $(if ($s) { [string]$s.Result } else { 'Jamais exécuté' }); Etat = $(if ($s) { [string]$s.State } else { '' })
        Fin = $(if ($s -and $s.EndTime -and $s.EndTime.Year -gt 2000) { $s.EndTime } else { $null }); Debut = $(if ($s) { $s.CreationTime } else { $null })
        Cible = $(try { $j.GetTargetRepository().Name } catch { '' }) }
    }
  } catch { $r.Erreurs += "Travaux : $($_.Exception.Message)" }
  # travaux agents (v11+)
  try {
    $cs = @(Get-VBRComputerBackupJobSession -ErrorAction Stop)
    foreach ($j in @(Get-VBRComputerBackupJob -ErrorAction Stop)) {
      $s = $cs | Where-Object { $_.JobId -eq $j.Id } | Sort-Object CreationTime -Descending | Select-Object -First 1
      $jobs += [pscustomobject]@{ Travail = $j.Name; Type = 'Agent'; Planifie = [bool]$j.ScheduleEnabled; Actif = [bool]$j.JobEnabled
        Resultat = $(if ($s) { [string]$s.Result } else { 'Jamais exécuté' }); Etat = $(if ($s) { [string]$s.State } else { '' })
        Fin = $(if ($s -and $s.EndTime -and $s.EndTime.Year -gt 2000) { $s.EndTime } else { $null }); Debut = $(if ($s) { $s.CreationTime } else { $null }); Cible = $(try { $j.BackupRepository.Name } catch { '' }) }
    }
  } catch { }
  $r.Jobs = $jobs
  $r.Repos = @(try { Get-VBRBackupRepository -ErrorAction Stop | ForEach-Object {
    $tot = $null; $free = $null
    try { $c = $_.GetContainer(); $tot = $c.CachedTotalSpace.InBytes; $free = $c.CachedFreeSpace.InBytes } catch { }
    if (-not $tot) { try { $tot = $_.Info.CachedTotalSpace; $free = $_.Info.CachedFreeSpace } catch { } }
    [pscustomobject]@{ Depot = $_.Name; Type = [string]$_.Type; Chemin = $_.Path; TotalGo = $(if ($tot) { [math]::Round($tot / 1GB, 0) } else { $null }); LibreGo = $(if ($tot) { [math]::Round($free / 1GB, 0) } else { $null }); LibrePct = $(if ($tot) { [math]::Round($free * 100 / $tot, 1) } else { $null })
      Immuable = $(try { [bool]$_.GetImmutabilitySettings().IsEnabled } catch { $null }) } } } catch { $r.Erreurs += "Dépôts : $($_.Exception.Message)" })
  $r.Sobr = @(try { Get-VBRBackupRepository -ScaleOut -ErrorAction Stop | ForEach-Object { [pscustomobject]@{ Depot = $_.Name; Extents = (@($_.Extent | ForEach-Object { $_.Name }) -join ', ') } } } catch { })
  try {
    $cb = Get-VBRConfigurationBackupJob -ErrorAction Stop
    $r.ConfBackup = [pscustomobject]@{ Active = [bool]$cb.Enabled; Resultat = [string]$cb.LastResult; Etat = [string]$cb.LastState; Chiffree = $(try { [bool]$cb.EncryptionOptions.Enabled } catch { $null }); Depot = $(try { $cb.Repository.Name } catch { '' }); Planifiee = $(try { [bool]$cb.ScheduleOptions.Enabled } catch { $null }) }
  } catch { $r.Erreurs += "Sauvegarde de configuration : $($_.Exception.Message)" }
  $r.Serveurs = @(try { Get-VBRServer -ErrorAction Stop | ForEach-Object { [pscustomobject]@{ Serveur = $_.Name; Type = [string]$_.Type; Description = $_.Description } } } catch { })
  $r.Proxies = @(try { Get-VBRViProxy -ErrorAction Stop | ForEach-Object { [pscustomobject]@{ Proxy = $_.Name; Type = 'VMware'; Actif = -not [bool]$_.IsDisabled } } } catch { }) + @(try { Get-VBRHvProxy -ErrorAction Stop | ForEach-Object { [pscustomobject]@{ Proxy = $_.Name; Type = 'Hyper-V'; Actif = -not [bool]$_.IsDisabled } } } catch { })
  $r.Events = @(try { Get-WinEvent -FilterHashtable @{ LogName = 'Veeam Backup'; Level = 1, 2; StartTime = (Get-Date).AddDays(-7) } -MaxEvents 200 -ErrorAction Stop | ForEach-Object { [pscustomobject]@{ Date = $_.TimeCreated; Id = $_.Id; Message = (($_.Message -split "`r?`n")[0]) } } } catch { })
  $r
}

Show-Etape "Collecte sur $($cible.Nom) (chargement du module Veeam : 10 à 30 s)..."
try { $r = Invoke-Cible $cible $Collecte } catch { $r = $null; Add-Check -Rubrique 'srv' -Titre 'Collecte' -Statut 'CRIT' -Resume "Collecte impossible : $($_.Exception.Message)" }

if ($r) {
  Show-Etape 'Analyse'
  foreach ($e in @($r.Erreurs)) { Add-Check -Rubrique 'srv' -Titre 'Erreur de collecte' -Statut 'ATT' -Resume $e }
  $h = $r.Host; $now = Get-Date

  # --- Services, version, licence
  $sv = @($r.Services); $ko = @($sv | Where-Object { $_.Etat -ne 'Running' -and $_.Demarrage -eq 'Automatic' })
  if (-not $sv.Count) { Add-Check -Rubrique 'srv' -Titre 'Services Veeam' -Statut 'CRIT' -Resume "Aucun service Veeam sur $h : ce n'est pas le serveur Veeam B&R" -Cible $h }
  else { Add-Check -Rubrique 'srv' -Titre 'Services Veeam' -Statut $(if ($ko.Count) { 'CRIT' } else { 'OK' }) -Resume $(if ($ko.Count) { "Arrêté(s) : $(($ko | ForEach-Object { $_.Nom }) -join ', ')" } else { "$($sv.Count) service(s), les services automatiques sont démarrés" }) -Table (To-Table $sv) -Cible $h -Cmds $(if ($ko.Count) { @(Cmd 'Démarrer les services Veeam arrêtés' (($ko | ForEach-Object { "Start-Service $(Q $_.Service)" }) -join '; ')) }) }
  if ($r.Module) {
    $v = [string]$r.Version; $maj = 0; if ($v -match '^(\d+)') { $maj = [int]$Matches[1] }
    Add-Check -Rubrique 'srv' -Titre 'Version de Veeam B&R' -Statut $(if ($maj -and $maj -lt 11) { 'CRIT' } elseif ($maj -eq 11) { 'ATT' } elseif ($maj) { 'OK' } else { 'INFO' }) -Resume $(if ($v) { "Build $v" } else { 'Non déterminée' }) -Cible $h `
      -Reco $(if ($maj -and $maj -le 11) { 'Version hors support (v11 : fin de support en février 2024). Mettre à jour vers la dernière version (v12.x ou ultérieure) : correctifs de sécurité critiques (CVE exploitées par des rançongiciels).' } else { 'Comparer ce numéro avec la liste des builds Veeam (KB2680) pour appliquer le dernier correctif cumulatif : plusieurs failles critiques ont été corrigées dans les mises à jour mineures.' }) `
      -Cmds @([ordered]@{ t = 'web'; l = 'Liste des builds Veeam (KB2680)'; u = 'https://www.veeam.com/kb2680' })
    if ($r.Licence) {
      $L = $r.Licence; $jl = if ($L.Expiration) { [int]([datetime]$L.Expiration - $now).TotalDays } else { $null }; $js = if ($L.Support) { [int]([datetime]$L.Support - $now).TotalDays } else { $null }
      $st = if ($L.Statut -notmatch 'Valid' -or ($null -ne $jl -and $jl -lt 0)) { 'CRIT' } elseif (($null -ne $jl -and $jl -lt 30) -or ($null -ne $js -and $js -lt 0)) { 'CRIT' } elseif (($null -ne $jl -and $jl -lt 60) -or ($null -ne $js -and $js -lt 60)) { 'ATT' } else { 'OK' }
      $res = "$($L.Edition) · $($L.Type) · $($L.Statut)"
      if ($null -ne $jl) { $res += " · expire dans $jl j" }; if ($null -ne $js) { $res += $(if ($js -lt 0) { " · support expiré depuis $(-$js) j" } else { " · support : $js j" }) }
      Add-Check -Rubrique 'srv' -Titre 'Licence' -Statut $st -Resume $res -Table (To-Table @($L)) -Cible $h -Reco $(if ($st -ne 'OK') { 'Renouveler la licence / le support avant échéance : sans support, plus de mises à jour ; licence expirée = sauvegardes arrêtées.' })
    }

    # --- Travaux
    $jobs = @($r.Jobs)
    if (-not $jobs.Count) { Add-Check -Rubrique 'jobs' -Titre 'Travaux' -Statut 'CRIT' -Resume 'Aucun travail de sauvegarde configuré' -Cible $h }
    foreach ($j in $jobs) {
      $ageH = if ($j.Fin) { [int]($now - [datetime]$j.Fin).TotalHours } else { $null }
      $st = if (-not $j.Actif) { 'INFO' } elseif ($j.Resultat -eq 'Failed') { 'CRIT' } elseif ($j.Resultat -eq 'Jamais exécuté') { 'ATT' } elseif ($j.Planifie -and $null -ne $ageH -and $ageH -gt ($maxH * 2)) { 'CRIT' } elseif ($j.Resultat -eq 'Warning' -or ($j.Planifie -and $null -ne $ageH -and $ageH -gt $maxH) -or -not $j.Planifie) { 'ATT' } else { 'OK' }
      $res = if (-not $j.Actif) { 'Travail désactivé' } else { "$($j.Resultat)$(if ($j.Fin) { ' · terminé le ' + ([datetime]$j.Fin).ToString('dd/MM/yyyy HH:mm') + " (il y a $ageH h)" } elseif ($j.Etat -match 'Working') { ' · en cours' })$(if (-not $j.Planifie) { ' · non planifié' })" }
      Add-Check -Rubrique 'jobs' -Titre "$($j.Travail) ($($j.Type))" -Statut $st -Resume $res -Cible $h -Table (To-Table @($j)) `
        -Reco $(switch ($st) { 'CRIT' { if ($j.Resultat -eq 'Failed') { 'Ouvrir la session dans la console Veeam (Historique) pour lire l''erreur exacte de chaque VM, corriger puis relancer.' } else { "Aucune sauvegarde réussie depuis plus de $($maxH * 2) h : vérifier la planification et le résultat de la dernière session." } } 'ATT' { if (-not $j.Planifie) { 'Travail non planifié : ne s''exécute que manuellement. Vérifier que c''est voulu.' } else { 'Lire l''avertissement dans la console Veeam (souvent espace disque, VMware Tools, snapshot).' } } default { '' } }) `
        -Cmds $(if ($st -in 'CRIT', 'ATT' -and $j.Actif -and $j.Type -ne 'Agent') { @(Cmd 'Relancer ce travail (sur le serveur Veeam)' "Start-VBRJob -Job (Get-VBRJob -Name $(Q $j.Travail)) -RunAsync") })
    }

    # --- Dépôts
    foreach ($d in @($r.Repos)) {
      $p = $d.LibrePct
      $st = if ($null -eq $p) { 'INFO' } elseif ($p -lt 10) { 'CRIT' } elseif ($p -lt 20) { 'ATT' } else { 'OK' }
      Add-Check -Rubrique 'repo' -Titre "Dépôt $($d.Depot)" -Statut $st -Resume $(if ($null -eq $p) { "$($d.Type) · espace non communiqué" } else { "$p % libre ($($d.LibreGo) Go sur $($d.TotalGo) Go) · $($d.Type)$(if ($d.Immuable) { ' · immuable' })" }) -Table (To-Table @($d)) -Cible $h `
        -Reco $(if ($st -in 'CRIT', 'ATT') { 'Libérer de l''espace (rétention, suppression des sauvegardes orphelines dans « Disk (Orphaned) ») ou agrandir le dépôt. Sous 10 %, les fusions échouent.' })
    }
    $imm = @($r.Repos | Where-Object { $_.Immuable })
    if (@($r.Repos).Count) { Add-Check -Rubrique 'repo' -Titre 'Copie immuable ou hors ligne' -Statut $(if ($imm.Count) { 'OK' } else { 'ATT' }) -Resume $(if ($imm.Count) { "Dépôt(s) immuable(s) : $(($imm | ForEach-Object { $_.Depot }) -join ', ')" } else { 'Aucun dépôt immuable détecté' }) -Cible $h -Reco $(if (-not $imm.Count) { 'Règle 3-2-1-1-0 : prévoir une copie immuable (dépôt Linux durci, objet S3 avec Object Lock) ou hors ligne (bande, disque déconnecté) pour résister à un rançongiciel. Vérifier aussi les copies vers le cloud (Cloud Connect).' }) }
    if (@($r.Sobr).Count) { Add-Check -Rubrique 'repo' -Titre 'Dépôts scale-out (SOBR)' -Statut 'INFO' -Resume "$(@($r.Sobr).Count) dépôt(s)" -Table (To-Table $r.Sobr) -Cible $h }

    # --- Sauvegarde de configuration
    if ($r.ConfBackup) {
      $c = $r.ConfBackup
      $st = if (-not $c.Active) { 'CRIT' } elseif ($c.Resultat -eq 'Failed') { 'CRIT' } elseif ($c.Chiffree -eq $false -or $c.Resultat -eq 'Warning') { 'ATT' } else { 'OK' }
      Add-Check -Rubrique 'conf' -Titre 'Sauvegarde de la configuration Veeam' -Statut $st -Resume "Active : $($c.Active) · dernier résultat : $($c.Resultat) · chiffrée : $($c.Chiffree) · dépôt : $($c.Depot)" -Table (To-Table @($c)) -Cible $h `
        -Reco $(if ($st -ne 'OK') { 'Indispensable pour reconstruire le serveur Veeam. L''activer, la chiffrer (sinon les mots de passe enregistrés ne sont pas sauvegardés) et la placer sur un dépôt différent du serveur lui-même.' }) `
        -Cmds $(if (-not $c.Active) { @(Cmd 'Activer la sauvegarde de configuration' 'Enable-VBRConfigurationBackupJob') })
    }

    # --- Infrastructure
    Add-Check -Rubrique 'infra' -Titre 'Serveurs gérés' -Statut 'INFO' -Resume "$(@($r.Serveurs).Count) serveur(s)" -Table (To-Table $r.Serveurs) -Cible $h
    $px = @($r.Proxies | Where-Object { $_ })
    if ($px.Count) { Add-Check -Rubrique 'infra' -Titre 'Proxys de sauvegarde' -Statut $(if (@($px | Where-Object { -not $_.Actif }).Count) { 'ATT' } else { 'OK' }) -Resume "$($px.Count) proxy(s)" -Table (To-Table $px) -Cible $h }
    $ev = @($r.Events)
    Add-Check -Rubrique 'infra' -Titre 'Journal « Veeam Backup » (7 jours, erreurs)' -Statut $(if ($ev.Count -gt 10) { 'ATT' } elseif ($ev.Count) { 'INFO' } else { 'OK' }) -Resume "$($ev.Count) erreur(s)" -Table (To-Table ($ev | Select-Object -First 100)) -Cible $h
  }
}

$nomCible = if ($cible) { $cible.Nom } else { 'inconnu' }
Save-Audit ("Audit-Veeam_{0}_{1:yyyyMMdd_HHmm}.html" -f $nomCible, $script:Debut) 'Audit Veeam Backup & Replication' $client $Rubriques $Prerequis
