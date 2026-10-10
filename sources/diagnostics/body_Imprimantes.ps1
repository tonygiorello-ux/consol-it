# ==================================================================================
#  DIAGNOSTIC IMPRIMANTES
# ==================================================================================
$ErrorActionPreference = 'SilentlyContinue'
$Rubriques = [ordered]@{
  'svc'  = @('Spouleur', '⚙️')
  'imp'  = @('Imprimantes', '🖨️')
  'file' = @('Files et pilotes', '📄')
}
$Prerequis = "À lancer dans la SESSION de l'utilisateur concerné (ses imprimantes réseau et son imprimante par défaut lui sont propres), sans élévation. Les corrections du spouleur demandent un PowerShell administrateur. Lecture seule."
Show-Titre 'Diagnostic imprimantes' "Spouleur, imprimantes (état, hors ligne, défaut), ports, files d'impression bloquées, pilotes, erreurs du journal.`nLecture seule : le script ne modifie rien."
$script:Cibles.Add($env:COMPUTERNAME)
$h = $env:COMPUTERNAME

Show-Etape 'Spouleur'
$sp = Get-Service -Name Spooler
if ($sp) {
  Add-Check -Rubrique 'svc' -Titre 'Service Spouleur d''impression' -Statut $(if ($sp.Status -ne 'Running') { 'CRIT' } else { 'OK' }) -Resume "$($sp.Status) · démarrage $($sp.StartType)" -Cible $h `
    -Reco $(if ($sp.Status -ne 'Running') { 'Aucune impression possible tant que le spouleur est arrêté.' }) -Cmds $(if ($sp.Status -ne 'Running') { @(Cmd 'Démarrer le spouleur' 'Set-Service Spooler -StartupType Automatic; Start-Service Spooler') })
}
$evt = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-PrintService/Admin'; Level = 1, 2; StartTime = (Get-Date).AddDays(-7) } -MaxEvents 50)
if ($evt.Count) { Add-Check -Rubrique 'svc' -Titre 'Erreurs d''impression (7 jours)' -Statut 'ATT' -Resume "$($evt.Count) erreur(s) dans le journal PrintService" -Table (To-Table @($evt | Select-Object -First 20 | ForEach-Object { [pscustomobject]@{ Date = $_.TimeCreated; Id = $_.Id; Message = (($_.Message -split "`n")[0]).Trim() } })) -Cible $h -Reco 'Lire le message : pilote en échec (808), accès refusé au serveur d''impression, port injoignable.' }

Show-Etape 'Imprimantes'
$pr = @(Get-Printer)
$def = (Get-CimInstance Win32_Printer | Where-Object { $_.Default }).Name
if ($pr.Count) {
  $rows = @($pr | ForEach-Object { [pscustomobject]@{ Imprimante = $_.Name; Type = [string]$_.Type; Pilote = $_.DriverName; Port = $_.PortName; Etat = [string]$_.PrinterStatus; HorsLigne = [bool]$_.WorkOffline; Partagee = [bool]$_.Shared; Defaut = $(if ($_.Name -eq $def) { 'Oui' } else { '' }) } })
  $off = @($rows | Where-Object { $_.HorsLigne -or $_.Etat -match 'Offline|Error|Erreur' })
  Add-Check -Rubrique 'imp' -Titre 'Imprimantes installées' -Statut $(if ($off.Count) { 'ATT' } else { 'OK' }) -Resume "$($rows.Count) imprimante(s)$(if ($off.Count) { " · hors ligne ou en erreur : $(($off | ForEach-Object { $_.Imprimante }) -join ', ')" })" -Table (To-Table $rows) -Cible $h `
    -Reco $(if ($off.Count) { 'Vérifier que l''imprimante est allumée et joignable (adresse IP, câble, Wi-Fi), puis la remettre en ligne dans Paramètres > Imprimantes.' })
  Add-Check -Rubrique 'imp' -Titre 'Imprimante par défaut' -Statut $(if ($def) { 'INFO' } else { 'ATT' }) -Resume $(if ($def) { $def } else { 'Aucune imprimante par défaut' }) -Cible $h `
    -Reco $(if (-not $def) { 'Sans imprimante par défaut, certaines applications refusent d''imprimer ou ralentissent.' }) -Cmds @(CmdUser 'Ouvrir les paramètres des imprimantes' 'Start-Process ms-settings:printers')
  $ports = @(Get-PrinterPort | Where-Object { $_.PrinterHostAddress } | ForEach-Object { $ok = $false; try { $c = New-Object Net.Sockets.TcpClient; $ok = $c.ConnectAsync($_.PrinterHostAddress, $(if ($_.PortNumber) { $_.PortNumber } else { 9100 })).Wait(1500); $c.Close() } catch { }; [pscustomobject]@{ Port = $_.Name; Adresse = $_.PrinterHostAddress; PortTCP = $_.PortNumber; Joignable = $ok } })
  if ($ports.Count) {
    $ko = @($ports | Where-Object { -not $_.Joignable })
    Add-Check -Rubrique 'imp' -Titre 'Joignabilité des imprimantes réseau (ports TCP/IP)' -Statut $(if ($ko.Count) { 'ATT' } else { 'OK' }) -Resume $(if ($ko.Count) { "Injoignable : $(($ko | ForEach-Object { $_.Adresse }) -join ', ')" } else { "$($ports.Count) port(s) joignable(s)" }) -Table (To-Table $ports) -Cible $h `
      -Reco $(if ($ko.Count) { 'Imprimante éteinte, adresse IP changée (réservation DHCP absente) ou hors du réseau actuel (télétravail).' })
  }
} else {
  $w = @(Get-CimInstance Win32_Printer | ForEach-Object { [pscustomobject]@{ Imprimante = $_.Name; Pilote = $_.DriverName; Defaut = $_.Default; HorsLigne = $_.WorkOffline } })
  Add-Check -Rubrique 'imp' -Titre 'Imprimantes installées' -Statut 'INFO' -Resume $(if ($w.Count) { "$($w.Count) imprimante(s) (lecture WMI)" } else { 'Aucune imprimante installée' }) -Table (To-Table $w) -Cible $h
}

Show-Etape 'Files et pilotes'
$jobs = @($pr | ForEach-Object { Get-PrintJob -PrinterName $_.Name })
if ($jobs.Count) {
  $stuck = @($jobs | Where-Object { $_.SubmittedTime -and $_.SubmittedTime -lt (Get-Date).AddHours(-1) })
  Add-Check -Rubrique 'file' -Titre 'Files d''impression' -Statut $(if ($stuck.Count) { 'ATT' } else { 'INFO' }) -Resume "$($jobs.Count) travail(aux) en file$(if ($stuck.Count) { ", dont $($stuck.Count) bloqué(s) depuis plus d'1 h" })" `
    -Table (To-Table @($jobs | ForEach-Object { [pscustomobject]@{ Imprimante = $_.PrinterName; Id = $_.Id; Document = $_.DocumentName; Etat = [string]$_.JobStatus; Soumis = $_.SubmittedTime; Pages = $_.TotalPages } })) -Cible $h `
    -Reco $(if ($stuck.Count) { 'Un travail bloqué empêche les suivants de sortir : purger la file.' }) `
    -Cmds $(if ($stuck.Count) { @(Cmd 'Purger toutes les files (redémarre le spouleur)' "Stop-Service Spooler -Force; Remove-Item `"`$env:SystemRoot\System32\spool\PRINTERS\*`" -Force -ErrorAction SilentlyContinue; Start-Service Spooler") })
} else { Add-Check -Rubrique 'file' -Titre 'Files d''impression' -Statut 'OK' -Resume 'Vides' -Cible $h }
$dr = @(Get-PrinterDriver | ForEach-Object { [pscustomobject]@{ Pilote = $_.Name; Fabricant = $_.Manufacturer; Version = $(if ($_.DriverVersion) { $v = [uint64]$_.DriverVersion; '{0}.{1}.{2}.{3}' -f ($v -shr 48), (($v -shr 32) -band 0xFFFF), (($v -shr 16) -band 0xFFFF), ($v -band 0xFFFF) } else { '' }); Environnement = $_.PrinterEnvironment } })
$gen = @($dr | Where-Object { $_.Pilote -match '^(Microsoft IPP Class Driver|Generic|Microsoft PCL6 Class Driver|Microsoft PS Class Driver)' })
Add-Check -Rubrique 'file' -Titre 'Pilotes d''impression' -Statut 'INFO' -Resume "$($dr.Count) pilote(s)$(if ($gen.Count) { " dont $($gen.Count) générique(s)" })" -Table (To-Table $dr) -Cible $h `
  -Reco $(if ($gen.Count) { 'Un pilote générique Microsoft imprime, mais sans les options du constructeur (bacs, recto verso, agrafage) : installer le pilote du fabricant si ces options manquent.' })

Save-Audit ("Diagnostic-Imprimantes_{0}_{1:yyyyMMdd_HHmm}.html" -f $h, $script:Debut) 'Diagnostic imprimantes' '' $Rubriques $Prerequis
