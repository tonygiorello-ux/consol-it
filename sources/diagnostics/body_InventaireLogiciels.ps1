# ==================================================================================
#  INVENTAIRE DES LOGICIELS
# ==================================================================================
$ErrorActionPreference = 'SilentlyContinue'
$Rubriques = [ordered]@{
  'inv'  = @('Logiciels installés', '📦')
  'obs'  = @('Versions obsolètes', '⏳')
  'acc'  = @('Prise en main à distance', '🖱️')
}
$Prerequis = "À lancer sur le poste concerné ; sans élévation, les logiciels installés pour d'autres utilisateurs (profil) ne sont pas listés. Produit aussi un export CSV dans le dossier des rapports. Lecture seule."
Show-Titre 'Inventaire des logiciels' "Logiciels installés (machine et utilisateur), versions hors support, outils de prise en main à distance, export CSV.`nLecture seule : le script ne modifie rien."
$script:Cibles.Add($env:COMPUTERNAME)
$h = $env:COMPUTERNAME

Show-Etape 'Lecture des logiciels installés'
$cles = @{ 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' = 'Machine (64 bits)'; 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' = 'Machine (32 bits)'; 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*' = "Utilisateur $env:USERNAME" }
$log = @(foreach ($k in $cles.Keys) {
  Get-ItemProperty $k | Where-Object { $_.DisplayName -and -not $_.SystemComponent -and -not $_.ParentKeyName -and $_.DisplayName -notmatch '^(Update for|Security Update|Mise à jour|KB\d+)' } | ForEach-Object {
    $d = ''; if ($_.InstallDate -match '^(\d{4})(\d{2})(\d{2})$') { $d = "$($Matches[3])/$($Matches[2])/$($Matches[1])" }
    [pscustomobject]@{ Logiciel = ([string]$_.DisplayName).Trim(); Version = [string]$_.DisplayVersion; Editeur = ([string]$_.Publisher).Trim(); Installe = $d; Portee = $cles[$k]; Taille_Mo = $(if ($_.EstimatedSize) { [math]::Round($_.EstimatedSize / 1024) } else { '' }) }
  }
}) | Sort-Object Logiciel, Version -Unique
$csv = Join-Path (Get-DossierRapports) ("Logiciels_{0}_{1:yyyyMMdd_HHmm}.csv" -f $h, $script:Debut)
$log | Export-Csv $csv -NoTypeInformation -Encoding UTF8 -Delimiter ';'
$ed = @($log | Group-Object Editeur | Sort-Object Count -Descending | Select-Object -First 8 | ForEach-Object { "$(if ($_.Name) { $_.Name } else { '(inconnu)' }) ($($_.Count))" })
Add-Check -Rubrique 'inv' -Titre 'Logiciels installés' -Statut 'INFO' -Resume "$($log.Count) logiciel(s) · principaux éditeurs : $($ed -join ', ')" -Table (To-Table $log @('Logiciel', 'Version', 'Editeur', 'Installe', 'Portee', 'Taille_Mo') 1000) -Cible $h `
  -Cmds @(Lien 'Ouvrir l''export CSV' $csv)
$appx = @(Get-AppxPackage | Where-Object { -not $_.IsFramework -and $_.SignatureKind -eq 'Store' -and $_.Name -notmatch '^Microsoft\.(Windows|VCLibs|NET|UI|Services|Xbox|Gaming|DesktopAppInstaller|StorePurchaseApp|WebMediaExtensions|HEVC|VP9|Web|HEIF|Raw|AV1)' } | ForEach-Object { [pscustomobject]@{ Application = $_.Name; Version = [string]$_.Version; Editeur = ($_.Publisher -replace '^CN=([^,]+).*', '$1') } })
if ($appx.Count) { Add-Check -Rubrique 'inv' -Titre "Applications du Microsoft Store ($env:USERNAME)" -Statut 'INFO' -Resume "$($appx.Count) application(s)" -Table (To-Table $appx) -Cible $h }

Show-Etape 'Versions obsolètes'
# motif, motif de version (facultatif), libellé, statut
$regles = @(
  @('Adobe Flash', '', 'Adobe Flash Player : abandonné depuis 2020, vecteur d''attaque connu', 'CRIT'),
  @('Silverlight', '', 'Microsoft Silverlight : fin de support en 2021', 'ATT'),
  @('^Java( \d+)? Update|^Java\(TM\)|^Java 8', '', 'Java 8 (Oracle) : mises à jour publiques payantes, souvent oublié et vulnérable ; le retirer s''il n''est plus utile', 'ATT'),
  @('Microsoft Office.*2010|Office 14', '', 'Office 2010 : plus de correctifs de sécurité depuis 2020', 'CRIT'),
  @('Microsoft Office.*2013|Office 15', '', 'Office 2013 : plus de correctifs de sécurité depuis 2023', 'CRIT'),
  @('Microsoft Office.*(2016|2019)', '', 'Office 2016 / 2019 : fin de support le 14 octobre 2025', 'ATT'),
  @('Skype for Business 2015|Lync', '', 'Lync / Skype for Business 2015 : hors support', 'ATT'),
  @('Adobe Reader XI|Adobe Acrobat (X|XI|2015|2017)\b', '', 'Version d''Adobe Reader / Acrobat hors support', 'ATT'),
  @('^Python 2\.', '', 'Python 2 : fin de vie depuis 2020', 'ATT'),
  @('Internet Explorer', '', 'Internet Explorer : retiré, ne doit plus servir', 'ATT'),
  @('WinRAR', '^[1-6]\.', 'WinRAR antérieur à la 7 : vulnérabilités corrigées dans les versions récentes', 'ATT'),
  @('7-Zip', '^(9|1[0-9]|2[0-3])\.', '7-Zip antérieur à la 24 : vulnérabilités corrigées dans les versions récentes', 'ATT')
)
$obs = @(foreach ($l in $log) { foreach ($r in $regles) { if ($l.Logiciel -match $r[0] -and (-not $r[1] -or $l.Version -match $r[1])) { [pscustomobject]@{ Logiciel = $l.Logiciel; Version = $l.Version; Probleme = $r[2]; Gravite = $r[3] }; break } } })
$crit = @($obs | Where-Object { $_.Gravite -eq 'CRIT' })
Add-Check -Rubrique 'obs' -Titre 'Logiciels hors support ou à risque' -Statut $(if ($crit.Count) { 'CRIT' } elseif ($obs.Count) { 'ATT' } else { 'OK' }) -Resume $(if ($obs.Count) { "$($obs.Count) logiciel(s) : $(($obs | ForEach-Object { $_.Logiciel }) -join ', ')" } else { 'Aucun logiciel obsolète connu détecté' }) -Table (To-Table $obs) -Cible $h `
  -Reco $(if ($obs.Count) { 'Désinstaller ce qui ne sert plus, mettre à jour le reste (winget upgrade --all couvre une bonne partie des logiciels courants). Liste indicative : elle ne remplace pas un scanner de vulnérabilités.' }) `
  -Cmds $(if ($obs.Count) { @((Ouvrir 'Ouvrir Applications installées' 'ms-settings:appsfeatures'), (Cmd 'Lister les mises à jour disponibles (winget)' 'winget upgrade')) })
$dbl = @($log | Group-Object Logiciel | Where-Object { $_.Count -gt 1 -and $_.Name -notmatch 'Visual C\+\+|\.NET|Runtime' } | ForEach-Object { [pscustomobject]@{ Logiciel = $_.Name; Versions = (($_.Group | ForEach-Object { $_.Version }) -join ' / ') } })
if ($dbl.Count) { Add-Check -Rubrique 'obs' -Titre 'Logiciels installés en plusieurs versions' -Statut 'INFO' -Resume "$($dbl.Count) logiciel(s)" -Table (To-Table $dbl) -Cible $h -Reco 'Une ancienne version restée installée à côté de la nouvelle reste vulnérable : la désinstaller si elle n''est plus utilisée.' }

Show-Etape 'Prise en main à distance'
$rmm = @($log | Where-Object { $_.Logiciel -match 'TeamViewer|AnyDesk|RustDesk|ScreenConnect|ConnectWise Control|Splashtop|LogMeIn|Chrome Remote Desktop|UltraVNC|TightVNC|RealVNC|VNC Server|Remote Utilities|NinjaRMM|Atera|N-able|Supremo|DWAgent|Zoho Assist|GoTo Resolve' } | ForEach-Object { [pscustomobject]@{ Logiciel = $_.Logiciel; Version = $_.Version; Editeur = $_.Editeur; Installe = $_.Installe } })
$svc = @(Get-Service | Where-Object { $_.DisplayName -match 'TeamViewer|AnyDesk|RustDesk|ScreenConnect|Splashtop|LogMeIn|VNC|Remote Utilities|Supremo|DWAgent' } | ForEach-Object { [pscustomobject]@{ Service = $_.DisplayName; Etat = [string]$_.Status; Demarrage = [string]$_.StartType } })
Add-Check -Rubrique 'acc' -Titre 'Outils de prise en main à distance' -Statut $(if ($rmm.Count -gt 1) { 'ATT' } elseif ($rmm.Count) { 'INFO' } else { 'OK' }) -Resume $(if ($rmm.Count) { (($rmm | ForEach-Object { $_.Logiciel }) -join ', ') } else { 'Aucun outil de prise en main tiers installé' }) `
  -Table (To-Table $(if ($svc.Count) { $svc } else { $rmm })) -Cible $h `
  -Reco $(if ($rmm.Count) { 'Vérifier que chaque outil est connu et légitime (outil de l''infogérance) : un outil de prise en main installé par un tiers est le premier signe d''une arnaque au faux support ou d''une intrusion. Désinstaller ceux qui ne sont pas utilisés.' })

Save-Audit ("Inventaire-Logiciels_{0}_{1:yyyyMMdd_HHmm}.html" -f $h, $script:Debut) 'Inventaire des logiciels' '' $Rubriques $Prerequis
