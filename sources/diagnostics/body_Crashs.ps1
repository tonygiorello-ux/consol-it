# ==================================================================================
#  DIAGNOSTIC CRASHS ET REDÉMARRAGES
# ==================================================================================
$ErrorActionPreference = 'SilentlyContinue'
$Rubriques = [ordered]@{
  'arr'   = @('Arrêts et coupures', '⚡')
  'bsod'  = @('Écrans bleus', '🟦')
  'hw'    = @('Erreurs matérielles', '🔧')
  'app'   = @('Applications', '🧩')
}
$Prerequis = "À lancer sur le poste concerné en administrateur (lecture du dossier Minidump). Analyse des 30 derniers jours. Lecture seule : aucune modification."
Show-Titre 'Diagnostic crashs et redémarrages' "Arrêts inattendus, coupures brutales (Kernel-Power 41), écrans bleus, fichiers de vidage, erreurs matérielles WHEA, plantages d'applications.`nLecture seule : le script ne modifie rien."
$script:Cibles.Add($env:COMPUTERNAME)
$h = $env:COMPUTERNAME
$depuis = (Get-Date).AddDays(-30)

Show-Etape 'Arrêts et coupures'
$os = Get-CimInstance Win32_OperatingSystem; $up = (Get-Date) - $os.LastBootUpTime
Add-Check -Rubrique 'arr' -Titre 'Dernier démarrage' -Statut 'INFO' -Resume "Le $($os.LastBootUpTime.ToString('dd/MM/yyyy HH:mm')) (il y a $($up.Days) j $($up.Hours) h)" -Cible $h
$un = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 6008; StartTime = $depuis })
Add-Check -Rubrique 'arr' -Titre 'Arrêts inattendus (30 jours)' -Statut $(if ($un.Count -ge 3) { 'ATT' } elseif ($un.Count) { 'INFO' } else { 'OK' }) -Resume $(if ($un.Count) { "$($un.Count) arrêt(s) non propre(s) (événement 6008)" } else { 'Aucun' }) `
  -Table (To-Table @($un | ForEach-Object { [pscustomobject]@{ Date = $_.TimeCreated; Detail = (($_.Message -split "`n")[0]).Trim() } })) -Cible $h `
  -Reco $(if ($un.Count) { 'Extinctions non propres : coupure de courant, bouton maintenu, plantage ou gel. À croiser avec les coupures Kernel-Power et les écrans bleus.' })
$kp = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 41; ProviderName = 'Microsoft-Windows-Kernel-Power'; StartTime = $depuis })
if ($kp.Count) {
  $rows = @($kp | Select-Object -First 15 | ForEach-Object { $x = [xml]$_.ToXml(); $bc = ($x.Event.EventData.Data | Where-Object { $_.Name -eq 'BugcheckCode' }).'#text'; [pscustomobject]@{ Date = $_.TimeCreated; BugCheck = $(if ($bc -and $bc -ne '0') { '0x{0:X}' -f [int64]$bc } else { 'aucun (coupure d''alimentation ou gel)' }) } })
  Add-Check -Rubrique 'arr' -Titre 'Coupures brutales (Kernel-Power 41)' -Statut $(if ($kp.Count -ge 3) { 'CRIT' } else { 'ATT' }) -Resume "$($kp.Count) en 30 jours" -Table (To-Table $rows) -Cible $h `
    -Reco 'BugCheck à 0 : coupure d''alimentation, bouton maintenu, surchauffe ou gel matériel (vérifier alimentation, onduleur, température, mise à jour du BIOS). BugCheck renseigné : voir les écrans bleus.'
} else { Add-Check -Rubrique 'arr' -Titre 'Coupures brutales (Kernel-Power 41)' -Statut 'OK' -Resume 'Aucune' -Cible $h }

Show-Etape 'Écrans bleus'
$bc = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 1001; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'; StartTime = $depuis })
Add-Check -Rubrique 'bsod' -Titre 'Écrans bleus (BugCheck, 30 jours)' -Statut $(if ($bc.Count) { 'CRIT' } else { 'OK' }) -Resume $(if ($bc.Count) { "$($bc.Count) écran(s) bleu(s)" } else { 'Aucun' }) `
  -Table (To-Table @($bc | ForEach-Object { [pscustomobject]@{ Date = $_.TimeCreated; Detail = (($_.Message -replace '\s+', ' ').Trim()) } })) -Cible $h `
  -Reco $(if ($bc.Count) { 'Le code 0x... indique la famille de panne (ex. 0x1A mémoire, 0x9F pilote/alimentation, 0x133 pilote). Analyser le fichier de vidage avec WinDbg ou BlueScreenView pour identifier le pilote fautif.' })
$dumps = @(@(Get-ChildItem "$env:SystemRoot\Minidump\*.dmp") + @(Get-Item "$env:SystemRoot\MEMORY.DMP") | Where-Object { $_ })
$rec = @($dumps | Where-Object { $_.LastWriteTime -gt $depuis })
Add-Check -Rubrique 'bsod' -Titre 'Fichiers de vidage (dumps)' -Statut $(if ($rec.Count) { 'CRIT' } elseif ($dumps.Count) { 'INFO' } else { 'OK' }) -Resume $(if ($dumps.Count) { "$($dumps.Count) fichier(s), dont $($rec.Count) de moins de 30 jours" } else { 'Aucun (ou dossier non lisible sans droits administrateur)' }) `
  -Table (To-Table @($dumps | Sort-Object LastWriteTime -Descending | ForEach-Object { [pscustomobject]@{ Fichier = $_.FullName; Date = $_.LastWriteTime; Taille_Mo = [math]::Round($_.Length / 1MB, 1) } })) -Cible $h `
  -Cmds $(if ($dumps.Count) { @(Cmd 'Ouvrir le dossier des vidages' "explorer.exe $(Q "$env:SystemRoot\Minidump")") })

Show-Etape 'Erreurs matérielles'
$wh = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger'; StartTime = $depuis })
if ($wh.Count) {
  $err = @($wh | Where-Object { $_.Level -le 2 })
  Add-Check -Rubrique 'hw' -Titre 'Erreurs matérielles WHEA (30 jours)' -Statut $(if ($err.Count) { 'CRIT' } else { 'ATT' }) -Resume "$($wh.Count) événement(s) dont $($err.Count) erreur(s)" -Table (To-Table @($wh | Select-Object -First 15 | ForEach-Object { [pscustomobject]@{ Date = $_.TimeCreated; Id = $_.Id; Niveau = $_.LevelDisplayName; Detail = (($_.Message -split "`n")[0]).Trim() } })) -Cible $h `
    -Reco 'Erreurs processeur, mémoire ou PCIe remontées par le matériel. Si récurrent : test mémoire, températures, mise à jour du BIOS et des pilotes de chipset.' -Cmds @(Cmd 'Planifier un test mémoire au redémarrage' 'mdsched.exe')
} else { Add-Check -Rubrique 'hw' -Titre 'Erreurs matérielles WHEA (30 jours)' -Statut 'OK' -Resume 'Aucune' -Cible $h }
$td = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Display'; Id = 4101; StartTime = $depuis })
if ($td.Count) { Add-Check -Rubrique 'hw' -Titre 'Pilote graphique réinitialisé (TDR)' -Statut 'ATT' -Resume "$($td.Count) réinitialisation(s) du pilote d'affichage" -Cible $h -Reco 'Écran noir ou gel bref puis reprise : mettre à jour le pilote graphique (site du constructeur du PC).' }

Show-Etape 'Applications'
$ap = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'Application Error', 'Application Hang'; StartTime = (Get-Date).AddDays(-7) })
$g = @($ap | ForEach-Object { if ($_.Message -match '(?i)^[^:]*:\s*([^\s,]+\.exe)') { $Matches[1] } else { 'inconnue' } } | Group-Object | Sort-Object Count -Descending | Select-Object -First 10 | ForEach-Object { [pscustomobject]@{ Application = $_.Name; Plantages_7j = $_.Count } })
Add-Check -Rubrique 'app' -Titre 'Plantages d''applications (7 jours)' -Statut $(if ($ap.Count -gt 10) { 'ATT' } elseif ($ap.Count) { 'INFO' } else { 'OK' }) -Resume $(if ($ap.Count) { "$($ap.Count) plantage(s) ou blocage(s)" } else { 'Aucun' }) -Table (To-Table $g) -Cible $h `
  -Reco $(if ($ap.Count -gt 10) { 'Une application qui plante en boucle : la réparer ou la réinstaller. Si plusieurs applications plantent, suspecter le système (sfc /scannow) ou la mémoire.' }) `
  -Cmds $(if ($ap.Count -gt 10) { @(Cmd 'Vérifier les fichiers système' 'sfc /scannow') })

Save-Audit ("Diagnostic-Crashs_{0}_{1:yyyyMMdd_HHmm}.html" -f $h, $script:Debut) 'Diagnostic crashs et redémarrages' '' $Rubriques $Prerequis
