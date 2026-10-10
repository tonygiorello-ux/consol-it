# ==================================================================================
#  DIAGNOSTIC MISE EN VEILLE
# ==================================================================================
$ErrorActionPreference = 'SilentlyContinue'
$Rubriques = [ordered]@{
  'modes'  = @('Modes et réglages', '🌙')
  'bloc'   = @('Blocages et réveils', '⏰')
  'rapp'   = @('Rapports Windows', '📄')
}
$Prerequis = "À lancer sur le poste concerné en administrateur (powercfg /requests, sleepstudy et diagnostic des transitions l'exigent). Lecture seule : aucune modification."
Show-Titre 'Diagnostic mise en veille' "Modes de veille disponibles, délais configurés, mises en veille effectives, blocages actifs, réveils, rapports Windows.`nLecture seule : le script ne modifie rien."
$script:Cibles.Add($env:COMPUTERNAME)
$h = $env:COMPUTERNAME
if (-not (Test-EstAdmin)) { Add-Check -Rubrique 'modes' -Titre 'Droits du diagnostic' -Statut 'ATT' -Resume 'Lancé sans droits administrateur : blocages actifs et rapports Windows indisponibles' -Cible $h }

Show-Etape 'Modes de veille'
$a = Cap { powercfg /a }
$dispo = @(); foreach ($ln in (($a -replace "`r", '') -split "`n")) { if ($ln -match 'ne sont pas disponibles|not available') { break }; $dispo += $ln }
$d = $dispo -join "`n"
$moderne = $d -match 'S0'; $s3 = $d -match 'S3'; $s12 = $d -match '\(S[12]\)'; $hib = $d -match 'S4|prolong|ibernat'
$mode = if ($moderne) { 'Veille moderne (S0 Low Power Idle) : le poste reste connecté en veille' } elseif ($s3) { 'Veille classique S3' } elseif ($s12) { 'Veille partielle S1 / S2 uniquement' } else { 'Aucune mise en veille disponible' }
Add-Check -Rubrique 'modes' -Titre 'Mode de veille disponible' -Statut $(if ($moderne -or $s3) { 'OK' } elseif ($s12) { 'INFO' } else { 'ATT' }) -Resume "$mode · hibernation $(if ($hib) { 'disponible' } else { 'indisponible ou désactivée' })" -Brut $a -Cible $h `
  -Reco $(if (-not ($moderne -or $s3 -or $s12)) { 'Aucun état de veille : pilote graphique de base, hyperviseur ou stratégie. Voir la partie « non disponibles » de la sortie brute.' } elseif ($moderne) { 'En veille moderne, le poste peut se réveiller pour le réseau et les notifications : consommation et chauffe en sacoche possibles.' })
function FmtSec($s) { if ($null -eq $s) { 'inconnu' } elseif ($s -eq 0) { 'Jamais' } elseif ($s -lt 60) { "$s s" } else { '{0} min' -f [math]::Round($s / 60) } }
$q = Cap { powercfg /query SCHEME_CURRENT SUB_SLEEP STANDBYIDLE }
$hx = @([regex]::Matches($q, '0x[0-9a-fA-F]{8}') | ForEach-Object { [Convert]::ToInt64($_.Value, 16) })
$ac = $null; $dc = $null; if ($hx.Count -ge 2) { $ac = $hx[-2]; $dc = $hx[-1] }
$st = if ($ac -eq 0 -and $dc -eq 0) { 'ATT' } elseif ($null -eq $ac) { 'INFO' } else { 'OK' }
Add-Check -Rubrique 'modes' -Titre 'Délai avant mise en veille' -Statut $st -Resume "Secteur : $(FmtSec $ac) · batterie : $(FmtSec $dc)" -Brut $q -Cible $h `
  -Reco $(if ($st -eq 'ATT') { 'Le poste ne se met jamais en veille seul. Définir un délai si souhaité (ex. 30 min sur secteur, 15 min sur batterie).' }) `
  -Cmds $(if ($st -eq 'ATT') { @(Cmd 'Veille après 30 min (secteur) / 15 min (batterie)' 'powercfg /change standby-timeout-ac 30; powercfg /change standby-timeout-dc 15') })
$ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 42; StartTime = (Get-Date).AddDays(-7) })
Add-Check -Rubrique 'modes' -Titre 'Mises en veille effectives (7 jours)' -Statut $(if ($ev.Count) { 'OK' } else { 'INFO' }) -Resume $(if ($ev.Count) { "$($ev.Count) entrée(s) en veille" } else { 'Aucune : le poste ne se met pas en veille, ou il est rarement laissé inactif' }) `
  -Table (To-Table @($ev | Select-Object -First 15 | ForEach-Object { [pscustomobject]@{ EntreeEnVeille = $_.TimeCreated } })) -Cible $h

Show-Etape 'Blocages et réveils'
$req = Cap { powercfg /requests }
$entrees = @((($req -replace "`r", '') -split "`n") | Where-Object { $_ -match '^\s*\[' })
Add-Check -Rubrique 'bloc' -Titre 'Blocages actifs de la veille' -Statut $(if ($entrees.Count) { 'ATT' } else { 'OK' }) -Resume $(if ($entrees.Count) { "$($entrees.Count) processus ou pilote(s) maintiennent le poste éveillé" } else { 'Aucun' }) -Brut $req -Cible $h `
  -Reco $(if ($entrees.Count) { 'Voir la sortie brute (sections DISPLAY, SYSTEM, AWAYMODE, EXECUTION). Un lecteur multimédia, un navigateur avec une vidéo ou un partage ouvert sont des causes fréquentes. Une exception peut être ajoutée avec powercfg /requestsoverride.' })
$lw = Cap { powercfg /lastwake }; $wt = Cap { powercfg /waketimers }; $wa = Cap { powercfg /devicequery wake_armed }
$timers = $wt -notmatch 'Aucune|no active|There are no'
$nbDev = @(($wa -split "`r?`n") | Where-Object { $_.Trim() -and $_ -notmatch 'NONE|AUCUN' }).Count
Add-Check -Rubrique 'bloc' -Titre 'Réveils' -Statut 'INFO' -Resume "$(if ($timers) { 'Minuteries de réveil actives' } else { 'Aucune minuterie de réveil' }) · $nbDev périphérique(s) autorisé(s) à réveiller" -Brut "== Dernier réveil ==`n$lw`n`n== Minuteries de réveil ==`n$wt`n`n== Périphériques autorisés à réveiller ==`n$wa" -Cible $h `
  -Reco $(if ($timers -or $nbDev) { 'Réveils intempestifs : désactiver « Autoriser ce périphérique à sortir l''ordinateur du mode veille » (carte réseau, souris) dans le Gestionnaire de périphériques, ou les minuteurs de réveil dans les options d''alimentation.' })

Show-Etape 'Rapports Windows'
$dir = Get-DossierRapports; $stamp = $script:Debut.ToString('yyyyMMdd_HHmm')
$sdx = Join-Path $dir "Veille-Transitions_$h`_$stamp.html"; $ssy = Join-Path $dir "Veille-Sleepstudy_$h`_$stamp.html"
& powercfg /systemsleepdiagnostics /output $sdx 2>&1 | Out-Null
& powercfg /sleepstudy /output $ssy 2>&1 | Out-Null
$liens = @((Lien 'Diagnostic des transitions de veille' $sdx), (Lien 'Rapport sleepstudy (veille moderne)' $ssy)) | Where-Object { $_ }
Add-Check -Rubrique 'rapp' -Titre 'Rapports détaillés de Windows' -Statut 'INFO' -Resume $(if ($liens.Count) { "$($liens.Count) rapport(s) généré(s) dans $dir" } else { 'Rapports non générés (droits administrateur requis, ou veille moderne absente pour sleepstudy)' }) -Cmds $liens -Cible $h

Save-Audit ("Diagnostic-Veille_{0}_{1:yyyyMMdd_HHmm}.html" -f $h, $script:Debut) 'Diagnostic mise en veille' '' $Rubriques $Prerequis
