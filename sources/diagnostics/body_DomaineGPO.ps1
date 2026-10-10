# ==================================================================================
#  DIAGNOSTIC DOMAINE ET GPO (poste)
# ==================================================================================
$ErrorActionPreference = 'SilentlyContinue'
$Rubriques = [ordered]@{
  'dom'  = @('Domaine et canal sécurisé', '🏢')
  'tps'  = @('Heure', '🕒')
  'gpo'  = @('Stratégies de groupe', '📋')
  'lec'  = @('Lecteurs réseau', '🗂️')
}
$Prerequis = "À lancer sur le poste concerné en administrateur (canal sécurisé, rapport GPO ordinateur). Les lecteurs réseau et les GPO utilisateur sont ceux de la session qui exécute le script. Lecture seule : aucune modification."
Show-Titre 'Diagnostic domaine et GPO' "Appartenance au domaine, canal sécurisé, contrôleur joint, synchronisation de l'heure, application des GPO, lecteurs réseau.`nLecture seule : le script ne modifie rien."
$script:Cibles.Add($env:COMPUTERNAME)
$h = $env:COMPUTERNAME
$cs = Get-CimInstance Win32_ComputerSystem

if (-not $cs.PartOfDomain) {
  Add-Check -Rubrique 'dom' -Titre 'Appartenance au domaine' -Statut 'INFO' -Resume "Poste hors domaine (groupe de travail $($cs.Workgroup))" -Cible $h
} else {
  $dom = $cs.Domain
  Show-Etape 'Domaine'
  $sc = $false; try { $sc = Test-ComputerSecureChannel -ErrorAction Stop } catch { }
  $dc = Cap { nltest /dsgetdc:$dom }
  Add-Check -Rubrique 'dom' -Titre "Relation d'approbation avec $dom" -Statut $(if ($sc) { 'OK' } else { 'CRIT' }) -Resume $(if ($sc) { "Canal sécurisé valide · serveur d'ouverture de session $env:LOGONSERVER" } else { 'Canal sécurisé ROMPU (ou contrôleur injoignable, ou script lancé sans droits administrateur)' }) -Brut $dc -Cible $h `
    -Reco $(if (-not $sc) { 'Symptôme typique : « La relation d''approbation entre cette station de travail et le domaine principal a échoué ». Réparer avec un compte du domaine autorisé à joindre des postes ; sinon sortir et rejoindre le domaine.' }) `
    -Cmds $(if (-not $sc) { @(Cmd 'Réparer le canal sécurisé' 'Test-ComputerSecureChannel -Repair -Credential (Get-Credential -Message "Compte du domaine (DOMAINE\admin)")') })
  $dcName = if ($dc -match '(?m)^\s*DC:\s*\\\\(\S+)') { $Matches[1] } else { '' }
  $site = if ($dc -match '(?m)Client Site Name:\s*(\S+)|Nom du site client\s*:\s*(\S+)') { "$($Matches[1])$($Matches[2])" } else { '' }
  Add-Check -Rubrique 'dom' -Titre 'Contrôleur de domaine joint' -Statut $(if ($dcName) { 'OK' } else { 'ATT' }) -Resume $(if ($dcName) { "$dcName$(if ($site) { " · site $site" })" } else { 'Aucun contrôleur trouvé : DNS du poste à vérifier (il doit pointer vers les contrôleurs)' }) -Cible $h
  $nla = @(Get-NetConnectionProfile | ForEach-Object { [pscustomobject]@{ Interface = $_.InterfaceAlias; Reseau = $_.Name; Categorie = [string]$_.NetworkCategory } })
  $pasDom = @($nla | Where-Object { $_.Categorie -ne 'DomainAuthenticated' })
  if ($nla.Count) { Add-Check -Rubrique 'dom' -Titre 'Profil réseau' -Statut $(if ($pasDom.Count -eq $nla.Count) { 'ATT' } else { 'OK' }) -Resume (($nla | ForEach-Object { "$($_.Interface) : $($_.Categorie)" }) -join ' · ') -Table (To-Table $nla) -Cible $h -Reco $(if ($pasDom.Count -eq $nla.Count) { 'Aucune carte en profil « Domaine » : le poste ne voit pas de contrôleur (hors site sans VPN, ou DNS incorrect). Les GPO et les scripts de connexion ne s''appliquent pas.' }) }

  Show-Etape 'Heure'
  $w = Cap { w32tm /query /status }
  $src = if ($w -match '(?m)^Source\s*:\s*(.+)$') { $Matches[1].Trim() } else { '' }
  $libre = $src -match 'CMOS|Local|Free'
  Add-Check -Rubrique 'tps' -Titre 'Source de temps' -Statut $(if ($libre -or -not $src) { 'ATT' } else { 'OK' }) -Resume $(if ($src) { $src } else { 'Non lue' }) -Brut $w -Cible $h `
    -Reco $(if ($libre) { 'Le poste n''est pas synchronisé sur le domaine : au-delà de 5 minutes d''écart, Kerberos refuse l''authentification.' }) `
    -Cmds $(if ($libre) { @(Cmd 'Resynchroniser sur la hiérarchie du domaine' 'w32tm /config /syncfromflags:domhier /update; Restart-Service w32time; w32tm /resync /force') })

  Show-Etape 'Stratégies de groupe'
  $gp = Join-Path (Get-DossierRapports) ("GPO_{0}_{1:yyyyMMdd_HHmm}.html" -f $h, $script:Debut)
  & gpresult /h $gp /f 2>&1 | Out-Null
  $r = Cap { gpresult /r /scope:computer }
  $gpEv = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-GroupPolicy'; Level = 1, 2, 3; StartTime = (Get-Date).AddDays(-7) } -MaxEvents 30)
  $dern = if ($r -match '(?m)(Last time Group Policy was applied|Dernière application de la stratégie de groupe)\s*:\s*(.+)$') { $Matches[2].Trim() } else { '' }
  Add-Check -Rubrique 'gpo' -Titre 'Application des GPO (ordinateur)' -Statut $(if (@($gpEv | Where-Object { $_.Level -le 2 }).Count) { 'ATT' } else { 'OK' }) -Resume "$(if ($dern) { "Dernière application : $dern · " })$($gpEv.Count) avertissement(s) / erreur(s) GroupPolicy sur 7 jours" -Brut $r `
    -Table (To-Table @($gpEv | Select-Object -First 15 | ForEach-Object { [pscustomobject]@{ Date = $_.TimeCreated; Id = $_.Id; Niveau = $_.LevelDisplayName; Message = (($_.Message -split "`n")[0]).Trim() } })) -Cible $h `
    -Reco $(if ($gpEv.Count) { 'Erreurs 1058 / 1030 : SYSVOL injoignable (DNS, réseau, VPN). 1129 : pas de connectivité au contrôleur au démarrage.' }) `
    -Cmds @((Cmd 'Forcer l''application des GPO' 'gpupdate /force'), (Lien 'Ouvrir le rapport GPO complet (gpresult)' $gp))

  Show-Etape 'Lecteurs réseau'
  $maps = @(Get-CimInstance Win32_NetworkConnection | ForEach-Object { [pscustomobject]@{ Lecteur = $_.LocalName; Chemin = $_.RemoteName; Etat = [string]$_.ConnectionState; Statut = [string]$_.Status } })
  $bad = @($maps | Where-Object { $_.Etat -eq 'Disconnected' -or $_.Statut -match 'Unavailable|Error' })
  Add-Check -Rubrique 'lec' -Titre "Lecteurs réseau de $env:USERNAME" -Statut $(if ($bad.Count) { 'ATT' } elseif ($maps.Count) { 'OK' } else { 'INFO' }) -Resume $(if ($maps.Count) { "$($maps.Count) lecteur(s)$(if ($bad.Count) { ", $($bad.Count) déconnecté(s)" })" } else { 'Aucun lecteur réseau dans cette session' }) -Table (To-Table $maps) -Cible $h `
    -Reco $(if ($bad.Count) { 'Lecteur déconnecté : serveur injoignable (hors site, VPN), partage renommé, ou droits retirés.' })
}

Save-Audit ("Diagnostic-Domaine_{0}_{1:yyyyMMdd_HHmm}.html" -f $h, $script:Debut) 'Diagnostic domaine et GPO' '' $Rubriques $Prerequis
