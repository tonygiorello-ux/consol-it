# ==================================================================================
#  DIAGNOSTIC LENTEUR OFFICE (Outlook / Word / Excel)
# ==================================================================================
$ErrorActionPreference = 'SilentlyContinue'
$Rubriques = [ordered]@{
  'inst'   = @('Installation Office', '📦')
  'compl'  = @('Compléments', '🧩')
  'outl'   = @('Outlook', '📧')
  'word'   = @('Word et Excel', '📝')
  'env'    = @('Poste et plantages', '🖥️')
}
$Prerequis = "À lancer dans la SESSION de l'utilisateur concerné (lecture de son profil Office), sans élévation. Fermer Outlook, Word et Excel avant, pour des mesures fiables. Lecture seule : aucune modification."
Show-Titre 'Diagnostic lenteur Office' "Compléments, fichiers OST/PST, cache des pièces jointes, imprimante par défaut, accélération matérielle, modèles de démarrage, OneDrive, ressources, plantages.`nLecture seule : le script ne modifie rien."
$script:Cibles.Add($env:COMPUTERNAME)
$h = $env:COMPUTERNAME

# --- Version installée
$verKeys = @()
foreach ($root in 'HKCU:\Software\Microsoft\Office', 'HKLM:\SOFTWARE\Microsoft\Office') { if (Test-Path $root) { Get-ChildItem $root | Where-Object { $_.PSChildName -match '^\d+\.\d+$' } | ForEach-Object { $verKeys += $_.PSChildName } } }
$ver = $verKeys | Sort-Object { [double]$_ } -Descending | Select-Object -First 1
if (-not $ver) { $ver = '16.0' }
$c2r = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration'
$canaux = @{ '492350f6-3a01-4f97-b9c0-c7c6ddf67d60' = 'Canal actuel (Current)'; '55336b82-a18d-4dd6-b5f6-9e5095c314a6' = 'Entreprise mensuel'; '7ffbc6bf-bc32-4f92-8982-f9dd17fd3114' = 'Semi-annuel entreprise'; 'b8f9b850-328d-4355-9145-c59439a0c4cf' = 'Semi-annuel (aperçu)'; '64256afe-f5d9-4f86-8936-8840a6a4f5be' = 'Current (aperçu)'; '5440fd1f-7ecb-4221-8110-145efaa6372f' = 'Bêta' }
$canal = [string]$c2r.UpdateChannel; foreach ($k in $canaux.Keys) { if ($canal -like "*$k*") { $canal = $canaux[$k] } }
$info = [pscustomobject]@{ Utilisateur = $env:USERNAME; Version = $ver; Build = $c2r.VersionToReport; Architecture = $c2r.Platform; Produits = $c2r.ProductReleaseIds; Canal = $canal }
Add-Check -Rubrique 'inst' -Titre 'Installation Office' -Statut 'INFO' -Resume $(if ($c2r) { "Click-to-Run $($c2r.VersionToReport) · $($c2r.Platform) · $canal" } else { 'Office MSI (non Click-to-Run) ou non détecté : build et canal indisponibles' }) -Table (To-Table @($info)) -Cible $h

# --- Compléments
Show-Etape 'Compléments'
function Get-Complements([string]$app) {
  $l = @()
  foreach ($p in "HKLM:\SOFTWARE\Microsoft\Office\$app\Addins", "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Office\$app\Addins", "HKCU:\Software\Microsoft\Office\$app\Addins") {
    if (Test-Path $p) {
      Get-ChildItem $p | ForEach-Object {
        $pr = Get-ItemProperty $_.PSPath; $lb = [int]$pr.LoadBehavior
        $etat = switch ($lb) { 3 { 'Actif (démarrage)' } 9 { 'Actif (démarrage)' } 8 { 'À la demande' } 16 { '1re utilisation' } { $_ -in 0, 1, 2 } { 'Inactif' } default { "LoadBehavior=$lb" } }
        $l += [pscustomobject]@{ Application = $app; Complement = $(if ($pr.FriendlyName) { $pr.FriendlyName } else { $_.PSChildName }); Chargement = $etat; Cle = $_.PSChildName }
      }
    }
  }
  $l
}
$adds = @(foreach ($a in 'Outlook', 'Word', 'Excel') { Get-Complements $a }) | Sort-Object Application, Complement -Unique
foreach ($a in 'Outlook', 'Word', 'Excel') {
  $act = @($adds | Where-Object { $_.Application -eq $a -and $_.Chargement -like 'Actif*' })
  $dis = "HKCU:\Software\Microsoft\Office\$ver\$a\Resiliency\DisabledItems"
  $nDis = if (Test-Path $dis) { @((Get-Item $dis).GetValueNames()).Count } else { 0 }
  $st = if ($act.Count -ge 5 -or $nDis) { 'ATT' } elseif ($act.Count) { 'OK' } else { 'OK' }
  Add-Check -Rubrique 'compl' -Titre "Compléments $a" -Statut $st -Resume ("{0} actif(s) au démarrage{1}" -f $act.Count, $(if ($nDis) { " · $nDis élément(s) désactivé(s) par Office après plantage" } else { '' })) `
    -Table (To-Table @($adds | Where-Object { $_.Application -eq $a }) @('Complement', 'Chargement', 'Cle')) -Cible $h `
    -Reco $(if ($act.Count -ge 5) { "Chaque complément chargé au démarrage ralentit $a. Désactiver l'inutile : Fichier > Options > Compléments > Gérer : Compléments COM > Atteindre. Tester avec « $($a.ToLower()) /safe » pour confirmer qu'un complément est en cause." } elseif ($nDis) { 'Office a désactivé des compléments à cause de plantages ou de lenteurs : Fichier > Options > Compléments > Gérer : Éléments désactivés.' }) `
    -Cmds $(if ($st -eq 'ATT') { @(CmdUser "Lancer $a en mode sans échec (sans compléments)" "Start-Process $(@{ Outlook = 'outlook.exe'; Word = 'winword.exe'; Excel = 'excel.exe' }[$a]) -ArgumentList '/safe'") })
}

# --- Outlook : OST / PST
Show-Etape 'Outlook'
$fich = @()
$mesDocs = [Environment]::GetFolderPath('MyDocuments')
$dossiersOutlook = @((Join-Path $env:LOCALAPPDATA 'Microsoft\Outlook')) + $(if ($mesDocs) { @((Join-Path $mesDocs 'Fichiers Outlook'), (Join-Path $mesDocs 'Outlook Files')) } else { @() })
foreach ($d in $dossiersOutlook) {
  if (Test-Path $d) { Get-ChildItem $d -Include *.ost, *.pst -Recurse | ForEach-Object { $fich += [pscustomobject]@{ Fichier = $_.Name; Type = $_.Extension.TrimStart('.').ToUpper(); Taille_Go = [math]::Round($_.Length / 1GB, 2); Modifie = $_.LastWriteTime; Dossier = $_.DirectoryName } } }
}
if ($fich.Count) {
  $max = ($fich | Measure-Object Taille_Go -Maximum).Maximum
  $gros = @($fich | Where-Object { $_.Taille_Go -ge 25 })
  Add-Check -Rubrique 'outl' -Titre 'Fichiers de données Outlook (OST / PST)' -Statut $(if ($max -ge 50) { 'CRIT' } elseif ($max -ge 25) { 'ATT' } else { 'OK' }) `
    -Resume $(if ($gros.Count) { "Volumineux : $(($gros | ForEach-Object { "$($_.Fichier) ($($_.Taille_Go) Go)" }) -join ', ')" } else { "$($fich.Count) fichier(s), le plus gros fait $max Go" }) -Table (To-Table ($fich | Sort-Object Taille_Go -Descending)) -Cible $h `
    -Reco $(if ($max -ge 25) { 'Au-delà de 25 à 50 Go, Outlook ralentit (recherche, indexation, ouverture). Réduire la période hors connexion (Paramètres du compte > Exchange > curseur « Conserver hors connexion »), archiver, ou recréer le profil.' })
} else { Add-Check -Rubrique 'outl' -Titre 'Fichiers de données Outlook (OST / PST)' -Statut 'INFO' -Resume 'Aucun OST / PST dans les emplacements standard' -Cible $h }
$stf = (Get-ItemProperty "HKCU:\Software\Microsoft\Office\$ver\Outlook\Security" -Name OutlookSecureTempFolder).OutlookSecureTempFolder
if ($stf -and (Test-Path $stf)) {
  $it = @(Get-ChildItem $stf -Recurse -File); $mo = if ($it.Count) { [math]::Round((($it | Measure-Object Length -Sum).Sum) / 1MB, 1) } else { 0 }
  $att = $it.Count -ge 500 -or $mo -ge 500
  Add-Check -Rubrique 'outl' -Titre 'Cache des pièces jointes Outlook' -Statut $(if ($att) { 'ATT' } else { 'OK' }) -Resume "$($it.Count) fichier(s) · $mo Mo" -Cible $h `
    -Reco $(if ($att) { 'Ce dossier accumule les pièces jointes ouvertes et peut ralentir Outlook : le vider, Outlook fermé.' }) `
    -Cmds $(if ($att) { @(CmdUser 'Vider le cache (Outlook fermé)' "if (Get-Process OUTLOOK -ErrorAction SilentlyContinue) { Write-Host 'Fermer Outlook avant.' -ForegroundColor Yellow } else { Get-ChildItem $(Q $stf) -Recurse -File | Remove-Item -Force -ErrorAction SilentlyContinue; Write-Host 'Cache vidé.' -ForegroundColor Green }") })
}

# --- Word / Excel
Show-Etape 'Word et Excel'
$def = Get-CimInstance Win32_Printer | Where-Object { $_.Default } | Select-Object -First 1
if ($def) {
  $off = [bool]$def.WorkOffline; $net = ([bool]$def.Network) -or ("$($def.PortName)" -match '^\\\\|^(WSD|IP_|TCP)')
  Add-Check -Rubrique 'word' -Titre 'Imprimante par défaut' -Statut $(if ($off -and -not $net) { 'ATT' } elseif ($off) { 'INFO' } else { 'OK' }) -Resume "$($def.Name) ($(if ($net) { 'réseau' } else { 'locale' })) · $(if ($off) { 'HORS LIGNE' } else { 'en ligne' }) · port $($def.PortName)" -Cible $h `
    -Reco $(if ($off -and -not $net) { 'Une imprimante par défaut hors ligne fige Word et Excel à l''ouverture : définir une imprimante toujours disponible (ex. Microsoft Print to PDF).' } elseif ($off) { 'Normal si le poste n''est pas sur le réseau de l''agence. Devient une cause de lenteur seulement si l''imprimante reste injoignable sur site.' }) `
    -Cmds $(if ($off) { @(CmdUser 'Mettre « Microsoft Print to PDF » par défaut' "(Get-CimInstance Win32_Printer -Filter `"Name='Microsoft Print to PDF'`") | Invoke-CimMethod -MethodName SetDefaultPrinter | Out-Null") })
} else { Add-Check -Rubrique 'word' -Titre 'Imprimante par défaut' -Statut 'INFO' -Resume 'Aucune imprimante par défaut' -Cible $h }
$hw = [int](Get-ItemProperty "HKCU:\Software\Microsoft\Office\$ver\Common\Graphics").DisableHardwareAcceleration
Add-Check -Rubrique 'word' -Titre 'Accélération graphique matérielle d''Office' -Statut 'INFO' -Resume $(if ($hw -eq 1) { 'Désactivée' } else { 'Activée (par défaut)' }) -Cible $h `
  -Reco 'Piste à tester si l''affichage saccade (défilement, frappe) avec un pilote graphique ancien : Fichier > Options > Options avancées > Affichage.'
$normal = Join-Path $env:APPDATA 'Microsoft\Templates\Normal.dotm'
if (Test-Path $normal) {
  $nMo = [math]::Round((Get-Item $normal).Length / 1MB, 2)
  Add-Check -Rubrique 'word' -Titre 'Modèle Normal.dotm' -Statut $(if ($nMo -ge 3) { 'ATT' } else { 'OK' }) -Resume "$nMo Mo" -Cible $h `
    -Reco $(if ($nMo -ge 3) { 'Un Normal.dotm gonflé (macros, styles, corruption) ralentit Word : le renommer, Word en recrée un propre au prochain lancement (les styles personnels sont perdus).' }) `
    -Cmds $(if ($nMo -ge 3) { @(CmdUser 'Renommer Normal.dotm (Word fermé)' "Rename-Item $(Q $normal) ('Normal_' + (Get-Date -Format yyyyMMdd) + '.dotm')") })
}
$demar = @()
foreach ($p in @(@('Word', (Join-Path $env:APPDATA 'Microsoft\Word\STARTUP')), @('Excel', (Join-Path $env:APPDATA 'Microsoft\Excel\XLSTART')))) { if (Test-Path $p[1]) { Get-ChildItem $p[1] -File | ForEach-Object { $demar += [pscustomobject]@{ Application = $p[0]; Fichier = $_.Name; Taille_Ko = [math]::Round($_.Length / 1KB) } } } }
$xo = Get-ItemProperty "HKCU:\Software\Microsoft\Office\$ver\Excel\Options"
if ($xo) { $xo.PSObject.Properties | Where-Object { $_.Name -match '^OPEN\d*$' } | ForEach-Object { $demar += [pscustomobject]@{ Application = 'Excel (OPEN)'; Fichier = [string]$_.Value; Taille_Ko = '' } } }
Add-Check -Rubrique 'word' -Titre 'Modèles et macros chargés au démarrage' -Statut 'INFO' -Resume "$($demar.Count) élément(s) chargé(s) à chaque ouverture de Word / Excel" -Table (To-Table $demar) -Cible $h `
  -Reco $(if ($demar.Count) { 'Les modèles globaux (STARTUP, XLSTART) et les compléments OPEN se chargent à chaque ouverture : retirer l''inutile accélère le lancement.' })

# --- Poste et plantages
Show-Etape 'Poste et plantages'
$docs = [Environment]::GetFolderPath('MyDocuments')
$od = ($env:OneDrive -and $docs -like "$env:OneDrive*") -or ($docs -match 'OneDrive')
Add-Check -Rubrique 'env' -Titre 'Emplacement des documents' -Statut 'INFO' -Resume $(if ($od) { "Synchronisés par OneDrive : $docs" } else { $docs }) -Cible $h `
  -Reco $(if ($od) { 'Ouvrir ou enregistrer de gros fichiers dans un dossier OneDrive en cours de synchronisation peut ralentir : tester en local, vérifier que OneDrive n''est pas bloqué.' })
$os = Get-CimInstance Win32_OperatingSystem
if ($os) {
  $pct = [math]::Round((([double]$os.TotalVisibleMemorySize - [double]$os.FreePhysicalMemory) / [double]$os.TotalVisibleMemorySize) * 100)
  $vol = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'"; $lib = if ($vol.Size) { [math]::Round($vol.FreeSpace * 100 / $vol.Size) } else { $null }
  $pr = @(Get-Process OUTLOOK, WINWORD, EXCEL, OneDrive, SearchIndexer, ms-teams | ForEach-Object { [pscustomobject]@{ Processus = $_.ProcessName; RAM_Mo = [math]::Round($_.WorkingSet64 / 1MB); PID = $_.Id } })
  $st = if ($pct -ge 90 -or ($null -ne $lib -and $lib -lt 10)) { 'CRIT' } elseif ($pct -ge 80) { 'ATT' } else { 'OK' }
  Add-Check -Rubrique 'env' -Titre 'Ressources du poste' -Statut $st -Resume "Mémoire utilisée $pct % · disque système $lib % libre" -Table (To-Table $pr) -Cible $h `
    -Reco $(if ($st -ne 'OK') { 'Outlook et les gros classeurs Excel souffrent du manque de mémoire ou d''espace disque : fermer des applications, libérer de l''espace. Lancer le diagnostic lenteur PC pour le détail.' })
}
$ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'Application Error', 'Application Hang'; StartTime = (Get-Date).AddDays(-7) } | Where-Object { $_.Message -match 'OUTLOOK|WINWORD|EXCEL' })
$rows = @($ev | ForEach-Object { [pscustomobject]@{ Date = $_.TimeCreated; Application = $(if ($_.Message -match 'OUTLOOK') { 'Outlook' } elseif ($_.Message -match 'WINWORD') { 'Word' } else { 'Excel' }); Type = $(if ($_.ProviderName -eq 'Application Hang') { 'Blocage' } else { 'Plantage' }); Module = $(if ($_.Message -match '(?i)(?:module|nom du module)[^:]*:\s*([^\s,]+)') { $Matches[1] } else { '' }) } })
Add-Check -Rubrique 'env' -Titre 'Plantages et blocages Office (7 jours)' -Statut $(if ($ev.Count) { 'ATT' } else { 'OK' }) -Resume $(if ($ev.Count) { "$($ev.Count) événement(s)" } else { 'Aucun' }) -Table (To-Table $rows) -Cible $h `
  -Reco $(if ($ev.Count) { 'Souvent un complément instable (voir rubrique Compléments, colonne Module) ou un fichier de données corrompu. Réparer Office si les plantages persistent.' }) `
  -Cmds $(if ($ev.Count) { @(Ouvrir 'Réparer Office (Applications installées > Microsoft 365 > Modifier)' 'ms-settings:appsfeatures') })

Save-Audit ("Diagnostic-Office_{0}_{1:yyyyMMdd_HHmm}.html" -f $h, $script:Debut) 'Diagnostic lenteur Office' '' $Rubriques $Prerequis
