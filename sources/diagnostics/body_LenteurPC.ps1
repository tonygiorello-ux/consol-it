# ==================================================================================
#  DIAGNOSTIC LENTEUR PC
# ==================================================================================
$ErrorActionPreference = 'SilentlyContinue'
$Rubriques = [ordered]@{
  'sys'   = @('Système', '🖥️')
  'cpu'   = @('Processeur et mémoire', '⚡')
  'disk'  = @('Disques', '💽')
  'boot'  = @('Démarrage', '🚀')
  'evt'   = @('Antivirus et journaux', '📜')
}
$Prerequis = "À lancer sur le poste concerné, idéalement pendant la lenteur. Droits administrateur conseillés (SMART, état des disques, journaux). Lecture seule : aucune modification."
Show-Titre 'Diagnostic lenteur PC' "Uptime, processeur, mémoire, disques (espace, type, santé, latence), démarrage, redémarrage en attente, antivirus, erreurs système.`nLecture seule : le script ne modifie rien."
$script:Cibles.Add($env:COMPUTERNAME)
$h = $env:COMPUTERNAME
if (-not (Test-EstAdmin)) { Add-Check -Rubrique 'sys' -Titre 'Droits du diagnostic' -Statut 'INFO' -Resume 'Lancé sans droits administrateur : SMART, état des disques physiques et certains journaux peuvent manquer.' -Cible $h }

# --- Système et uptime
Show-Etape 'Système'
$os = Get-CimInstance Win32_OperatingSystem; $cs = Get-CimInstance Win32_ComputerSystem; $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
if ($os) {
  $up = (Get-Date) - $os.LastBootUpTime
  $sys = [pscustomobject]@{ Machine = $h; Utilisateur = $env:USERNAME; OS = "$($os.Caption) $($os.Version)"; Modele = "$($cs.Manufacturer) $($cs.Model)"; Processeur = $cpu.Name
    Coeurs = "$($cpu.NumberOfCores) / $($cpu.NumberOfLogicalProcessors)"; RAM_Go = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1); Demarre = $os.LastBootUpTime; Uptime = ('{0} j {1} h {2} min' -f $up.Days, $up.Hours, $up.Minutes) }
  $j = [int]$up.TotalDays
  Add-Check -Rubrique 'sys' -Titre 'Durée depuis le dernier redémarrage' -Statut $(if ($j -ge 7) { 'ATT' } else { 'OK' }) -Resume "Démarré il y a $($sys.Uptime)" -Table (To-Table @($sys)) -Cible $h `
    -Reco $(if ($j -ge 7) { 'Un uptime élevé accumule fuites mémoire et processus bloqués : un redémarrage résout souvent une lenteur progressive (attention : « Arrêter » ne remet pas à zéro avec le démarrage rapide, il faut « Redémarrer »).' }) `
    -Cmds $(if ($j -ge 7) { @(Cmd 'Redémarrer le poste' 'Restart-Computer -Force') })
} else { Add-Check -Rubrique 'sys' -Titre 'Informations système' -Statut 'ATT' -Resume 'Lecture WMI impossible' -Cible $h }

# --- Processeur
Show-Etape 'Processeur et mémoire'
$ech = @(); for ($i = 0; $i -lt 3; $i++) { $v = (Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor | Where-Object { $_.Name -eq '_Total' }).PercentProcessorTime; if ($null -ne $v) { $ech += [int]$v }; Start-Sleep -Milliseconds 800 }
$topCpu = @(Get-Process | Sort-Object CPU -Descending | Select-Object -First 8 | ForEach-Object { [pscustomobject]@{ Processus = $_.ProcessName; TempsCPU_s = [math]::Round($_.CPU); RAM_Mo = [math]::Round($_.WorkingSet64 / 1MB); PID = $_.Id } })
if ($ech.Count) {
  $moy = [math]::Round(($ech | Measure-Object -Average).Average)
  Add-Check -Rubrique 'cpu' -Titre 'Charge du processeur' -Statut $(if ($moy -ge 85) { 'CRIT' } elseif ($moy -ge 60) { 'ATT' } else { 'OK' }) -Resume "$moy % en moyenne sur 3 mesures" -Table (To-Table $topCpu) -Cible $h `
    -Reco $(if ($moy -ge 60) { 'Regarder le processus en tête (mise à jour, antivirus, indexation, processus emballé). Le temps CPU affiché est cumulé depuis le lancement du processus.' }) `
    -Cmds $(if ($moy -ge 60) { @(CmdUser 'Ouvrir le Gestionnaire des tâches' 'Start-Process taskmgr') })
} else { Add-Check -Rubrique 'cpu' -Titre 'Charge du processeur' -Statut 'INFO' -Resume 'Compteur indisponible' -Table (To-Table $topCpu) -Cible $h }
# --- Mémoire
if ($os) {
  $tot = [double]$os.TotalVisibleMemorySize; $lib = [double]$os.FreePhysicalMemory
  $pct = [math]::Round((($tot - $lib) / $tot) * 100)
  $topMem = @(Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 8 | ForEach-Object { [pscustomobject]@{ Processus = $_.ProcessName; RAM_Mo = [math]::Round($_.WorkingSet64 / 1MB); PID = $_.Id } })
  Add-Check -Rubrique 'cpu' -Titre 'Mémoire vive' -Statut $(if ($pct -ge 90) { 'CRIT' } elseif ($pct -ge 80) { 'ATT' } else { 'OK' }) -Resume "$pct % utilisée ($([math]::Round($lib / 1MB, 1)) Go libres sur $([math]::Round($tot / 1MB, 1)) Go)" -Table (To-Table $topMem) -Cible $h `
    -Reco $(if ($pct -ge 90) { 'Le système manque de mémoire et utilise le disque (fichier d''échange) : lenteurs majeures. Fermer les gros consommateurs (navigateur, Teams, Outlook) ou ajouter de la RAM.' } elseif ($pct -ge 80) { 'Peu de marge mémoire : surveiller les gros consommateurs ci-dessus.' })
}
$pf = @(Get-CimInstance Win32_PageFileUsage | ForEach-Object { [pscustomobject]@{ Fichier = $_.Name; Taille_Mo = $_.AllocatedBaseSize; Utilise_Mo = $_.CurrentUsage; Pic_Mo = $_.PeakUsage } })
if ($pf.Count) { Add-Check -Rubrique 'cpu' -Titre 'Fichier d''échange' -Statut 'INFO' -Resume "Pic d'utilisation : $(($pf | Measure-Object Pic_Mo -Sum).Sum) Mo" -Table (To-Table $pf) -Cible $h }

# --- Disques
Show-Etape 'Disques'
$sd = $env:SystemDrive
$vols = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object { [pscustomobject]@{ Lecteur = $_.DeviceID; Taille_Go = [math]::Round($_.Size / 1GB, 1); Libre_Go = [math]::Round($_.FreeSpace / 1GB, 1); Libre_Pct = $(if ($_.Size) { [math]::Round($_.FreeSpace * 100 / $_.Size) } else { 0 }) } })
$vs = $vols | Where-Object { $_.Lecteur -eq $sd } | Select-Object -First 1
if ($vs) {
  $st = if ($vs.Libre_Pct -lt 10 -or $vs.Libre_Go -lt 10) { 'CRIT' } elseif ($vs.Libre_Pct -lt 15) { 'ATT' } else { 'OK' }
  Add-Check -Rubrique 'disk' -Titre "Espace libre sur le disque système ($sd)" -Statut $st -Resume "$($vs.Libre_Pct) % libre ($($vs.Libre_Go) Go sur $($vs.Taille_Go) Go)" -Table (To-Table $vols) -Cible $h `
    -Reco $(if ($st -ne 'OK') { 'Windows a besoin d''espace libre (fichier d''échange, mises à jour, cache). Vider la corbeille et les fichiers temporaires, lancer le Nettoyage de disque (y compris « fichiers système »).' }) `
    -Cmds $(if ($st -ne 'OK') { @((CmdUser 'Vider les fichiers temporaires et la corbeille' 'Remove-Item "$env:TEMP\*" -Recurse -Force -ErrorAction SilentlyContinue; Clear-RecycleBin -Force -ErrorAction SilentlyContinue'), (Cmd 'Ouvrir le Nettoyage de disque' "cleanmgr /d $($sd.TrimEnd(':'))")) })
}
$pd = @(Get-PhysicalDisk | ForEach-Object { [pscustomobject]@{ Disque = $_.FriendlyName; Type = [string]$_.MediaType; Taille_Go = [math]::Round($_.Size / 1GB); Sante = [string]$_.HealthStatus; Etat = [string]$_.OperationalStatus } })
if ($pd.Count) {
  $bad = @($pd | Where-Object { $_.Sante -and $_.Sante -ne 'Healthy' }); $hdd = @($pd | Where-Object { $_.Type -eq 'HDD' })
  Add-Check -Rubrique 'disk' -Titre 'Disques physiques' -Statut $(if ($bad.Count) { 'CRIT' } elseif ($hdd.Count) { 'ATT' } else { 'OK' }) `
    -Resume $(if ($bad.Count) { "Mauvaise santé : $(($bad | ForEach-Object { $_.Disque + ' (' + $_.Sante + ')' }) -join ', ')" } elseif ($hdd.Count) { "Disque mécanique (HDD) : $(($hdd | ForEach-Object { $_.Disque }) -join ', ')" } else { "$($pd.Count) disque(s) sain(s), SSD" }) -Table (To-Table $pd) -Cible $h `
    -Reco $(if ($bad.Count) { 'Sauvegarder les données immédiatement et prévoir le remplacement du disque.' } elseif ($hdd.Count) { 'Un disque dur mécanique est la première cause de lenteur ressentie : le remplacement par un SSD transforme la réactivité du poste.' })
} else { Add-Check -Rubrique 'disk' -Titre 'Disques physiques' -Statut 'INFO' -Resume 'Get-PhysicalDisk indisponible (droits administrateur requis ou ancien système)' -Cible $h }
$smart = @(Get-CimInstance -Namespace root\wmi -ClassName MSStorageDriver_FailurePredictStatus)
if ($smart.Count) {
  $f = @($smart | Where-Object { $_.PredictFailure })
  Add-Check -Rubrique 'disk' -Titre 'SMART : prédiction de panne' -Statut $(if ($f.Count) { 'CRIT' } else { 'OK' }) -Resume $(if ($f.Count) { 'Un disque signale une panne imminente' } else { 'Aucune défaillance prédite' }) -Cible $h -Reco $(if ($f.Count) { 'Sauvegarde immédiate et remplacement du disque.' })
}
$perf = Get-CimInstance Win32_PerfFormattedData_PerfDisk_PhysicalDisk | Where-Object { $_.Name -eq '_Total' }
if ($perf) {
  $ms = [math]::Round([double]$perf.AvgDisksecPerTransfer * 1000, 1)
  Add-Check -Rubrique 'disk' -Titre 'Latence du disque' -Statut $(if ($ms -gt 25) { 'ATT' } else { 'OK' }) -Resume "$ms ms par transfert · file d'attente $([int]$perf.CurrentDiskQueueLength) · activité $([int]$perf.PercentDiskTime) %" -Cible $h `
    -Reco $(if ($ms -gt 25) { 'Au-delà de 25 ms, le disque ralentit tout le système (souvent un HDD usé ou saturé). Mesure instantanée : relancer pendant la lenteur.' })
}

# --- Démarrage
Show-Etape 'Démarrage'
$su = @(Get-CimInstance Win32_StartupCommand | ForEach-Object { [pscustomobject]@{ Nom = $_.Name; Emplacement = $_.Location; Commande = $_.Command } })
Add-Check -Rubrique 'boot' -Titre 'Programmes au démarrage' -Statut $(if ($su.Count -ge 15) { 'ATT' } else { 'OK' }) -Resume "$($su.Count) programme(s) lancé(s) à l'ouverture de session" -Table (To-Table $su) -Cible $h `
  -Reco $(if ($su.Count -ge 15) { 'Un démarrage surchargé ralentit l''ouverture de session : désactiver l''inutile (Gestionnaire des tâches > Applications de démarrage).' }) `
  -Cmds $(if ($su.Count -ge 15) { @(CmdUser 'Ouvrir les applications de démarrage' 'Start-Process ms-settings:startupapps') })
$bt = Get-WinEvent -LogName 'Microsoft-Windows-Diagnostics-Performance/Operational' -FilterXPath '*[System[(EventID=100)]]' -MaxEvents 1
if ($bt) {
  $x = [xml]$bt.ToXml(); $ms = ($x.Event.EventData.Data | Where-Object { $_.Name -eq 'BootTime' }).'#text'
  if ($ms) { $s = [math]::Round([double]$ms / 1000, 1); Add-Check -Rubrique 'boot' -Titre 'Durée du dernier démarrage' -Statut $(if ($s -gt 90) { 'ATT' } else { 'OK' }) -Resume "$s s (le $($bt.TimeCreated.ToString('dd/MM/yyyy HH:mm')))" -Cible $h -Reco $(if ($s -gt 90) { 'Démarrage long : croiser avec le nombre de programmes au démarrage et l''état du disque.' }) }
}
$rz = @()
if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $rz += 'maintenance des composants (CBS)' }
if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $rz += 'Windows Update' }
if ((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations).PendingFileRenameOperations) { $rz += 'renommage de fichiers' }
Add-Check -Rubrique 'boot' -Titre 'Redémarrage en attente' -Statut $(if ($rz.Count) { 'ATT' } else { 'OK' }) -Resume $(if ($rz.Count) { "Oui : $($rz -join ', ')" } else { 'Aucun' }) -Cible $h `
  -Reco $(if ($rz.Count) { 'Redémarrer pour finaliser les mises à jour : une installation inachevée peut ralentir le poste.' }) -Cmds $(if ($rz.Count) { @(Cmd 'Redémarrer le poste' 'Restart-Computer -Force') })

# --- Antivirus et journaux
Show-Etape 'Antivirus et journaux'
$av = @(Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntiVirusProduct | ForEach-Object { $_.displayName } | Select-Object -Unique)
if ($av.Count) {
  Add-Check -Rubrique 'evt' -Titre 'Antivirus' -Statut $(if ($av.Count -gt 1) { 'ATT' } else { 'OK' }) -Resume ($av -join ', ') -Cible $h `
    -Reco $(if ($av.Count -gt 1) { 'Deux antivirus actifs se surveillent mutuellement et ralentissent fortement le poste : n''en garder qu''un (Defender se désactive seul quand un antivirus tiers est actif ; vérifier qu''un ancien antivirus n''est pas resté installé).' })
}
$errs = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Level = 1, 2; StartTime = (Get-Date).AddDays(-3) } -MaxEvents 200)
$grp = @($errs | Group-Object ProviderName | Sort-Object Count -Descending | Select-Object -First 10 | ForEach-Object { [pscustomobject]@{ Source = $_.Name; Erreurs_3j = $_.Count } })
$dErr = @($errs | Where-Object { $_.ProviderName -match 'disk|Ntfs|storahci|stornvme' -or $_.Id -in 7, 11, 51, 153 })
$wh = @($errs | Where-Object { $_.ProviderName -match 'WHEA' })
Add-Check -Rubrique 'evt' -Titre 'Erreurs du journal Système (3 jours)' -Statut $(if ($dErr.Count) { 'CRIT' } elseif ($wh.Count) { 'ATT' } elseif ($errs.Count) { 'INFO' } else { 'OK' }) `
  -Resume $(if ($dErr.Count) { "$($dErr.Count) erreur(s) disque / stockage sur $($errs.Count)" } elseif ($wh.Count) { "$($wh.Count) erreur(s) matérielle(s) WHEA" } else { "$($errs.Count) erreur(s)" }) -Table (To-Table $grp) -Cible $h `
  -Reco $(if ($dErr.Count) { 'Des erreurs d''entrée/sortie disque annoncent souvent une panne : sauvegarder puis vérifier le disque (chkdsk, SMART, outil du constructeur).' } elseif ($wh.Count) { 'Erreurs matérielles (processeur, mémoire, bus) : tester la mémoire si la lenteur s''accompagne d''instabilités.' }) `
  -Cmds $(if ($dErr.Count) { @(Cmd 'Analyser le disque système (sans réparation)' "chkdsk $sd /scan") } elseif ($wh.Count) { @(Cmd 'Planifier un test mémoire au redémarrage' 'mdsched.exe') })

Save-Audit ("Diagnostic-LenteurPC_{0}_{1:yyyyMMdd_HHmm}.html" -f $h, $script:Debut) 'Diagnostic lenteur PC' '' $Rubriques $Prerequis
