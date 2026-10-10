# ==================================================================================
#  DIAGNOSTIC SANTÉ MATÉRIELLE
# ==================================================================================
$ErrorActionPreference = 'SilentlyContinue'
$Rubriques = [ordered]@{
  'disk'  = @('Disques', '💽')
  'per'   = @('Périphériques et mémoire', '🔧')
  'bat'   = @('Batterie', '🔋')
}
$Prerequis = "À lancer sur le poste concerné en administrateur (compteurs de fiabilité des disques, capacité de la batterie). Lecture seule : aucune modification."
Show-Titre 'Diagnostic santé matérielle' "Disques (santé, SMART, usure SSD), périphériques en erreur, mémoire, batterie.`nLecture seule : le script ne modifie rien."
$script:Cibles.Add($env:COMPUTERNAME)
$h = $env:COMPUTERNAME
if (-not (Test-EstAdmin)) { Add-Check -Rubrique 'disk' -Titre 'Droits du diagnostic' -Statut 'INFO' -Resume 'Lancé sans droits administrateur : usure SSD et capacité batterie peuvent manquer' -Cible $h }

Show-Etape 'Disques'
$pd = @(Get-PhysicalDisk)
if ($pd.Count) {
  $rows = @(foreach ($d in $pd) {
    $rc = $d | Get-StorageReliabilityCounter
    [pscustomobject]@{ Disque = $d.FriendlyName; Type = [string]$d.MediaType; Bus = [string]$d.BusType; Taille_Go = [math]::Round($d.Size / 1GB); Sante = [string]$d.HealthStatus; Etat = [string]$d.OperationalStatus
      Usure_Pct = $(if ($rc -and $null -ne $rc.Wear) { $rc.Wear } else { '' }); Temperature_C = $(if ($rc -and $rc.Temperature) { $rc.Temperature } else { '' }); Heures = $(if ($rc -and $rc.PowerOnHours) { $rc.PowerOnHours } else { '' })
      ErreursLecture = $(if ($rc) { $rc.ReadErrorsUncorrected } else { '' }) }
  })
  $bad = @($rows | Where-Object { $_.Sante -and $_.Sante -ne 'Healthy' })
  Add-Check -Rubrique 'disk' -Titre 'Santé des disques' -Statut $(if ($bad.Count) { 'CRIT' } else { 'OK' }) -Resume $(if ($bad.Count) { "Mauvaise santé : $(($bad | ForEach-Object { $_.Disque }) -join ', ')" } else { "$($rows.Count) disque(s) sain(s)" }) -Table (To-Table $rows) -Cible $h `
    -Reco $(if ($bad.Count) { 'Sauvegarder les données immédiatement et remplacer le disque (outil de diagnostic du constructeur pour confirmer).' })
  foreach ($r in @($rows | Where-Object { $_.Usure_Pct -ne '' -and [int]$_.Usure_Pct -gt 0 })) {
    $w = [int]$r.Usure_Pct
    Add-Check -Rubrique 'disk' -Titre "Usure du SSD $($r.Disque)" -Statut $(if ($w -ge 80) { 'CRIT' } elseif ($w -ge 50) { 'ATT' } else { 'OK' }) -Resume "$w % d'usure" -Cible $h `
      -Reco $(if ($w -ge 50) { 'Indicateur d''usure remonté par le SSD : planifier son remplacement avant la fin de vie (le disque passe en lecture seule).' })
  }
} else { Add-Check -Rubrique 'disk' -Titre 'Santé des disques' -Statut 'INFO' -Resume 'Get-PhysicalDisk indisponible' -Cible $h }
$sp = @(Get-CimInstance -Namespace root\wmi -Class MSStorageDriver_FailurePredictStatus)
if ($sp.Count) { $f = @($sp | Where-Object { $_.PredictFailure }); Add-Check -Rubrique 'disk' -Titre 'SMART : prédiction de panne' -Statut $(if ($f.Count) { 'CRIT' } else { 'OK' }) -Resume $(if ($f.Count) { 'Un disque signale une panne imminente' } else { 'Aucune défaillance prédite' }) -Cible $h -Reco $(if ($f.Count) { 'Sauvegarde immédiate et remplacement.' }) }

Show-Etape 'Périphériques et mémoire'
$codes = @{ 1 = 'Mal configuré'; 3 = 'Pilote corrompu'; 10 = 'Démarrage impossible'; 12 = 'Ressources insuffisantes'; 14 = 'Redémarrage requis'; 18 = 'Réinstaller le pilote'; 22 = 'Désactivé'; 28 = 'Pilote non installé'; 31 = 'Pilote indisponible'; 39 = 'Pilote manquant ou corrompu'; 43 = 'Arrêté par Windows (défaillance signalée)'; 45 = 'Non connecté' }
$pnp = @(Get-CimInstance Win32_PnPEntity | Where-Object { $null -ne $_.ConfigManagerErrorCode -and $_.ConfigManagerErrorCode -ne 0 -and $_.ConfigManagerErrorCode -ne 45 })
$prows = @($pnp | ForEach-Object { $c = [int]$_.ConfigManagerErrorCode; [pscustomobject]@{ Peripherique = $_.Name; Classe = $_.PNPClass; Code = $c; Probleme = $(if ($codes.ContainsKey($c)) { $codes[$c] } else { 'Erreur' }) } })
$desact = @($prows | Where-Object { $_.Code -eq 22 }); $vrai = @($prows | Where-Object { $_.Code -ne 22 })
Add-Check -Rubrique 'per' -Titre 'Périphériques en erreur' -Statut $(if ($vrai.Count) { 'ATT' } elseif ($desact.Count) { 'INFO' } else { 'OK' }) -Resume $(if ($prows.Count) { "$($vrai.Count) en erreur, $($desact.Count) désactivé(s)" } else { 'Aucun' }) -Table (To-Table $prows) -Cible $h `
  -Reco $(if ($vrai.Count) { 'Pilotes manquants ou matériel défaillant : installer le pilote du constructeur (outil de mise à jour Dell / HP / Lenovo) ou vérifier le matériel. Code 43 : souvent un périphérique USB ou un GPU défaillant.' }) `
  -Cmds $(if ($vrai.Count) { @(CmdUser 'Ouvrir le Gestionnaire de périphériques' 'Start-Process devmgmt.msc') })
$ram = @(Get-CimInstance Win32_PhysicalMemory)
if ($ram.Count) {
  $tot = [math]::Round((($ram | Measure-Object Capacity -Sum).Sum) / 1GB)
  $vit = @($ram | ForEach-Object { $_.ConfiguredClockSpeed } | Select-Object -Unique)
  Add-Check -Rubrique 'per' -Titre 'Mémoire installée' -Statut $(if ($tot -lt 8) { 'ATT' } else { 'OK' }) -Resume "$tot Go en $($ram.Count) barrette(s)" -Table (To-Table @($ram | ForEach-Object { [pscustomobject]@{ Emplacement = $_.DeviceLocator; Go = [math]::Round($_.Capacity / 1GB); MHz = $_.Speed; MHz_configure = $_.ConfiguredClockSpeed; Fabricant = $_.Manufacturer; Reference = ([string]$_.PartNumber).Trim() } })) -Cible $h `
    -Reco $(if ($tot -lt 8) { 'Moins de 8 Go : insuffisant pour Windows 11 avec Office, Teams et un navigateur. Prévoir une extension si un emplacement est libre.' } elseif ($vit.Count -gt 1) { 'Barrettes de vitesses différentes : la mémoire tourne à la vitesse de la plus lente.' })
}

Show-Etape 'Batterie'
$portable = $false; foreach ($c in @((Get-CimInstance Win32_SystemEnclosure).ChassisTypes)) { if (@(8, 9, 10, 11, 12, 14, 18, 21, 30, 31, 32) -contains [int]$c) { $portable = $true } }
if ($portable) {
  $bat = Join-Path (Get-DossierRapports) ("Batterie_{0}_{1:yyyyMMdd_HHmm}.html" -f $h, $script:Debut)
  & powercfg /batteryreport /output $bat 2>&1 | Out-Null
  $des = @((Get-CimInstance -Namespace root\wmi -Class BatteryStaticData).DesignedCapacity)[0]
  $full = @((Get-CimInstance -Namespace root\wmi -Class BatteryFullChargedCapacity).FullChargedCapacity)[0]
  if ($des -and $full -and $des -gt 0) {
    $w = [math]::Round((1 - ($full / $des)) * 100)
    Add-Check -Rubrique 'bat' -Titre 'Usure de la batterie' -Statut $(if ($w -ge 40) { 'CRIT' } elseif ($w -ge 25) { 'ATT' } else { 'OK' }) -Resume "$w % d'usure (capacité $full mWh sur $des mWh d'origine)" -Cible $h `
      -Reco $(if ($w -ge 25) { 'Autonomie réduite d''autant. Au-delà de 40 %, prévoir le remplacement (souvent couvert si le poste est encore sous garantie).' })
  } else { Add-Check -Rubrique 'bat' -Titre 'Usure de la batterie' -Statut 'INFO' -Resume 'Capacité non lue : voir le rapport batterie détaillé' -Cible $h }
  $l = Lien 'Ouvrir le rapport batterie Windows' $bat
  Add-Check -Rubrique 'bat' -Titre 'Rapport batterie Windows' -Statut 'INFO' -Resume $(if ($l) { "Généré : $bat" } else { 'Non généré (droits administrateur ?)' }) -Cmds @($l) -Cible $h
} else { Add-Check -Rubrique 'bat' -Titre 'Batterie' -Statut 'INFO' -Resume 'Poste fixe : pas de batterie' -Cible $h }

Save-Audit ("Diagnostic-Materiel_{0}_{1:yyyyMMdd_HHmm}.html" -f $h, $script:Debut) 'Diagnostic santé matérielle' '' $Rubriques $Prerequis
