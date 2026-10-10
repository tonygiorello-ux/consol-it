# ==================================================================================
#  DIAGNOSTIC SÉCURITÉ ET CONFORMITÉ (poste)
# ==================================================================================
$ErrorActionPreference = 'SilentlyContinue'
$Rubriques = [ordered]@{
  'av'   = @('Antivirus', '🛡️')
  'chif' = @('Chiffrement', '🔐')
  'maj'  = @('Mises à jour', '🔄')
  'conf' = @('Configuration', '⚙️')
}
$Prerequis = "À lancer sur le poste concerné en administrateur (état BitLocker, pare-feu, comptes locaux). Lecture seule : aucune modification."
Show-Titre 'Diagnostic sécurité et conformité' "Antivirus, BitLocker, correctifs Windows, redémarrage en attente, pare-feu, comptes administrateurs locaux, UAC, RDP, SMBv1.`nLecture seule : le script ne modifie rien."
$script:Cibles.Add($env:COMPUTERNAME)
$h = $env:COMPUTERNAME
if (-not (Test-EstAdmin)) { Add-Check -Rubrique 'av' -Titre 'Droits du diagnostic' -Statut 'ATT' -Resume 'Lancé sans droits administrateur : BitLocker et une partie de la configuration ne peuvent pas être lus' -Cible $h }

Show-Etape 'Antivirus'
$mp = Get-MpComputerStatus
$tiers = @(Get-CimInstance -Namespace root\SecurityCenter2 -Class AntiVirusProduct | Where-Object { $_.displayName -notmatch 'Windows Defender|Microsoft Defender' })
if ($mp -and $mp.AntivirusEnabled -and -not ($tiers.Count -and $mp.AMRunningMode -match 'Passive|Passif')) {
  $st = if (-not $mp.RealTimeProtectionEnabled) { 'CRIT' } elseif ($mp.AntivirusSignatureAge -gt 7) { 'ATT' } else { 'OK' }
  Add-Check -Rubrique 'av' -Titre 'Microsoft Defender' -Statut $st -Resume "Temps réel : $(if ($mp.RealTimeProtectionEnabled) { 'actif' } else { 'DÉSACTIVÉ' }) · définitions de $($mp.AntivirusSignatureAge) j · mode $($mp.AMRunningMode)" `
    -Table (To-Table @([pscustomobject]@{ TempsReel = $mp.RealTimeProtectionEnabled; Definitions = $mp.AntivirusSignatureLastUpdated; Age_j = $mp.AntivirusSignatureAge; AnalyseRapide = $mp.QuickScanEndTime; AnalyseComplete = $mp.FullScanEndTime; Inviolabilite = $mp.IsTamperProtected })) -Cible $h `
    -Reco $(if ($st -eq 'CRIT') { 'Protection en temps réel coupée : la réactiver immédiatement (vérifier qu''aucune GPO ou outil ne la désactive).' } elseif ($st -eq 'ATT') { 'Définitions anciennes : le poste ne reçoit plus les mises à jour de l''antivirus (Windows Update bloqué, WSUS).' }) `
    -Cmds $(if ($st -eq 'CRIT') { @(Cmd 'Réactiver la protection temps réel' 'Set-MpPreference -DisableRealtimeMonitoring $false') } elseif ($st -eq 'ATT') { @(Cmd 'Mettre à jour les définitions' 'Update-MpSignature') })
  $thr = @(Get-MpThreatDetection | Where-Object { $_.InitialDetectionTime -gt (Get-Date).AddDays(-30) })
  Add-Check -Rubrique 'av' -Titre 'Menaces détectées (30 jours)' -Statut $(if (@($thr | Where-Object { $_.ActionSuccess -eq $false }).Count) { 'CRIT' } elseif ($thr.Count) { 'ATT' } else { 'OK' }) -Resume $(if ($thr.Count) { "$($thr.Count) détection(s)" } else { 'Aucune' }) `
    -Table (To-Table @($thr | ForEach-Object { $t = Get-MpThreat -ThreatID $_.ThreatID; [pscustomobject]@{ Date = $_.InitialDetectionTime; Menace = $t.ThreatName; Fichier = ($_.Resources -join ', '); Traitee = $_.ActionSuccess } })) -Cible $h `
    -Reco $(if ($thr.Count) { 'Vérifier la nature de la menace et l''origine (pièce jointe, clé USB, téléchargement). Lancer une analyse complète si une menace n''a pas été traitée.' }) `
    -Cmds $(if ($thr.Count) { @(Cmd 'Lancer une analyse rapide' 'Start-MpScan -ScanType QuickScan') })
} elseif ($tiers.Count) {
  Add-Check -Rubrique 'av' -Titre 'Antivirus tiers' -Statut 'INFO' -Resume (($tiers | ForEach-Object { $_.displayName }) -join ', ') -Table (To-Table @($tiers | ForEach-Object { [pscustomobject]@{ Antivirus = $_.displayName; Etat = ('0x{0:X}' -f $_.productState); Actif = $(if ((($_.productState -shr 12) -band 0xF) -eq 1) { 'Oui' } else { 'Non' }); AJour = $(if ((($_.productState -shr 4) -band 0xF) -eq 0) { 'Oui' } else { 'Non' }) } })) -Cible $h `
    -Reco 'Vérifier l''état dans la console de l''éditeur (colonnes Actif / À jour déduites du Centre de sécurité).'
} else { Add-Check -Rubrique 'av' -Titre 'Antivirus' -Statut 'CRIT' -Resume 'Aucun antivirus actif détecté' -Cible $h -Reco 'Réactiver Microsoft Defender ou installer l''antivirus de l''entreprise.' }

Show-Etape 'Chiffrement'
$bde = @(Get-BitLockerVolume)
if ($bde.Count) {
  $sys = $bde | Where-Object { $_.MountPoint -eq $env:SystemDrive } | Select-Object -First 1
  $rec = @($sys.KeyProtector | Where-Object { [string]$_.KeyProtectorType -eq 'RecoveryPassword' })
  $st = if (-not $sys -or [string]$sys.ProtectionStatus -ne 'On') { 'ATT' } elseif (-not $rec.Count) { 'ATT' } else { 'OK' }
  Add-Check -Rubrique 'chif' -Titre "BitLocker sur $env:SystemDrive" -Statut $st -Resume $(if ([string]$sys.ProtectionStatus -ne 'On') { "Non protégé ($([string]$sys.VolumeStatus))" } elseif (-not $rec.Count) { 'Actif mais AUCUNE clé de récupération' } else { "Actif · $($rec.Count) clé(s) de récupération" }) `
    -Table (To-Table @($bde | ForEach-Object { [pscustomobject]@{ Volume = $_.MountPoint; Etat = [string]$_.VolumeStatus; Protection = [string]$_.ProtectionStatus; Chiffre_Pct = $_.EncryptionPercentage; Methode = [string]$_.EncryptionMethod; Protecteurs = (($_.KeyProtector | ForEach-Object { [string]$_.KeyProtectorType }) -join ', ') } })) -Cible $h `
    -Reco $(if ([string]$sys.ProtectionStatus -ne 'On') { 'Un portable volé non chiffré expose toutes ses données (RGPD). Activer BitLocker en sauvegardant la clé dans AD / Entra ID.' } elseif (-not $rec.Count) { 'Sans clé de récupération, une mise à jour du BIOS ou un changement de carte mère peut rendre le disque illisible : ajouter et sauvegarder une clé.' }) `
    -Cmds $(if ($st -eq 'ATT' -and [string]$sys.ProtectionStatus -eq 'On') { @(Cmd 'Ajouter une clé de récupération' "Add-BitLockerKeyProtector -MountPoint $env:SystemDrive -RecoveryPasswordProtector; (Get-BitLockerVolume $env:SystemDrive).KeyProtector | Where-Object KeyProtectorType -eq 'RecoveryPassword'") })
} else { $mb = Cap { manage-bde -status }; Add-Check -Rubrique 'chif' -Titre 'BitLocker' -Statut 'INFO' -Resume 'État non lu par PowerShell (droits administrateur ou édition Famille)' -Brut $mb -Cible $h }

Show-Etape 'Mises à jour'
$hf = @(Get-HotFix | Where-Object { $_.InstalledOn } | Sort-Object InstalledOn -Descending)
if ($hf.Count) {
  $age = ((Get-Date) - $hf[0].InstalledOn).Days
  Add-Check -Rubrique 'maj' -Titre 'Derniers correctifs Windows' -Statut $(if ($age -gt 60) { 'CRIT' } elseif ($age -gt 40) { 'ATT' } else { 'OK' }) -Resume "Dernier correctif il y a $age j ($($hf[0].HotFixID))" `
    -Table (To-Table @($hf | Select-Object -First 8 | ForEach-Object { [pscustomobject]@{ Correctif = $_.HotFixID; InstalleLe = $_.InstalledOn.ToString('dd/MM/yyyy'); Description = $_.Description } })) -Cible $h `
    -Reco $(if ($age -gt 40) { 'Windows publie un correctif cumulatif chaque mois : au-delà de 40 jours, le poste a raté au moins une mise à jour de sécurité. Vérifier Windows Update (erreurs, WSUS, service arrêté).' }) `
    -Cmds $(if ($age -gt 40) { @(CmdUser 'Ouvrir Windows Update' 'Start-Process ms-settings:windowsupdate') })
}
$rz = @(); if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $rz += 'CBS' }; if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $rz += 'Windows Update' }
Add-Check -Rubrique 'maj' -Titre 'Redémarrage en attente' -Statut $(if ($rz.Count) { 'ATT' } else { 'OK' }) -Resume $(if ($rz.Count) { "Oui ($($rz -join ', ')) : les correctifs installés ne sont pas actifs" } else { 'Aucun' }) -Cible $h -Cmds $(if ($rz.Count) { @(Cmd 'Redémarrer le poste' 'Restart-Computer -Force') })
$os = Get-CimInstance Win32_OperatingSystem; $dv = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').DisplayVersion
Add-Check -Rubrique 'maj' -Titre 'Version de Windows' -Statut $(if ($os.Caption -match 'Windows 10') { 'ATT' } else { 'OK' }) -Resume "$($os.Caption) $dv (build $($os.BuildNumber))" -Cible $h `
  -Reco $(if ($os.Caption -match 'Windows 10') { 'Windows 10 n''a plus de support gratuit depuis le 14 octobre 2025 (sauf ESU) : planifier la migration vers Windows 11.' })

Show-Etape 'Configuration'
$fw = @(Get-NetFirewallProfile | ForEach-Object { [pscustomobject]@{ Profil = $_.Name; Actif = [bool]$_.Enabled; Entrant = [string]$_.DefaultInboundAction } })
$offFw = @($fw | Where-Object { -not $_.Actif })
if ($fw.Count) { Add-Check -Rubrique 'conf' -Titre 'Pare-feu Windows' -Statut $(if ($offFw.Count) { 'ATT' } else { 'OK' }) -Resume $(if ($offFw.Count) { "Désactivé sur : $(($offFw | ForEach-Object { $_.Profil }) -join ', ')" } else { 'Actif sur tous les profils' }) -Table (To-Table $fw) -Cible $h -Cmds $(if ($offFw.Count) { @(Cmd 'Réactiver le pare-feu' 'Set-NetFirewallProfile -Profile Domain,Private,Public -Enabled True') }) }
$adm = @(Get-LocalGroupMember -SID 'S-1-5-32-544' | ForEach-Object { [pscustomobject]@{ Membre = $_.Name; Type = [string]$_.ObjectClass; Source = [string]$_.PrincipalSource } })
$adm0 = @(Get-LocalUser | Where-Object { $_.SID -like '*-500' })
if ($adm.Count) {
  $user = "$env:USERDOMAIN\$env:USERNAME"; $uAdm = @($adm | Where-Object { $_.Membre -eq $user })
  Add-Check -Rubrique 'conf' -Titre 'Administrateurs locaux' -Statut $(if ($adm.Count -gt 4) { 'ATT' } else { 'INFO' }) -Resume "$($adm.Count) membre(s)$(if ($uAdm.Count) { " · l'utilisateur $user est administrateur" })$(if ($adm0 -and $adm0[0].Enabled) { ' · compte Administrateur intégré ACTIF' })" -Table (To-Table $adm) -Cible $h `
    -Reco 'Un utilisateur administrateur de son poste installe ce qu''il veut et donne plus de prise à un logiciel malveillant. Préférer LAPS pour le compte local et des comptes d''administration dédiés.'
}
$uac = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System').EnableLUA
$rdp = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server').fDenyTSConnections
$nla = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp').UserAuthentication
$smb1 = (Get-SmbServerConfiguration).EnableSMB1Protocol
$cfg = [pscustomobject]@{ UAC = $(if ($uac -eq 0) { 'DÉSACTIVÉ' } else { 'Actif' }); BureauADistance = $(if ($rdp -eq 0) { 'Autorisé' } else { 'Interdit' }); NLA = $(if ($rdp -eq 0) { if ($nla -eq 1) { 'Oui' } else { 'NON' } } else { '' }); SMBv1 = $(if ($smb1) { 'ACTIF' } else { 'Désactivé' }) }
$pb = @(); if ($uac -eq 0) { $pb += 'UAC désactivé' }; if ($smb1) { $pb += 'SMBv1 actif' }; if ($rdp -eq 0 -and $nla -ne 1) { $pb += 'Bureau à distance sans NLA' }
Add-Check -Rubrique 'conf' -Titre 'Durcissement de base' -Statut $(if ($pb.Count) { 'ATT' } else { 'OK' }) -Resume $(if ($pb.Count) { $pb -join ' · ' } else { "UAC actif, SMBv1 désactivé$(if ($rdp -eq 0) { ', Bureau à distance avec NLA' })" }) -Table (To-Table @($cfg)) -Cible $h `
  -Reco $(if ($pb.Count) { 'SMBv1 est le protocole exploité par WannaCry ; l''UAC limite l''effet d''un clic malveillant ; NLA protège le Bureau à distance.' }) `
  -Cmds @(@(if ($smb1) { Cmd 'Désactiver SMBv1' 'Set-SmbServerConfiguration -EnableSMB1Protocol $false -Force' }) + @(if ($rdp -eq 0 -and $nla -ne 1) { Cmd 'Exiger NLA pour le Bureau à distance' "Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name UserAuthentication -Value 1" }))

Save-Audit ("Diagnostic-Securite_{0}_{1:yyyyMMdd_HHmm}.html" -f $h, $script:Debut) 'Diagnostic sécurité et conformité' '' $Rubriques $Prerequis
