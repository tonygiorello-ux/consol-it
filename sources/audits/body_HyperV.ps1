# ==================================================================================
#  AUDIT HYPER-V
# ==================================================================================
$Rubriques = [ordered]@{
  'hote'  = @('Hôte et ressources', '🖥️')
  'vms'   = @('Machines virtuelles', '🧩')
  'snap'  = @('Points de contrôle (snapshots)', '📸')
  'disk'  = @('Stockage et disques virtuels', '💽')
  'res'   = @('Réseau', '🔌')
  'repl'  = @('Réplication et cluster', '🔁')
  'jour'  = @('Journaux', '📜')
}
$Prerequis = "À lancer sur l'hôte Hyper-V, ou depuis un poste avec WinRM vers l'hôte. Compte administrateur de l'hôte (ou membre de « Administrateurs Hyper-V »). Lecture seule : aucune modification."

Show-Titre 'Audit Hyper-V' "Hôte, VM, points de contrôle, démarrage automatique, mémoire, disques, réseau, réplication, journaux.`nLecture seule : le script ne modifie rien."
$client = Ask-Text 'Client / site (pour le rapport)' ''
$cible = Get-Cible 'Hyper-V (hôte)' 'Indiquer l''hôte Hyper-V. Entrée si ce script tourne déjà dessus.'

$Collecte = {
  $r = @{ Host = $env:COMPUTERNAME; Erreurs = @() }
  try { Import-Module Hyper-V -ErrorAction Stop; $r.Module = $true } catch { $r.Module = $false; $r.Erreurs += "Module Hyper-V : $($_.Exception.Message)"; return $r }
  $os = Get-CimInstance Win32_OperatingSystem
  $vh = Get-VMHost
  $r.Hote = [pscustomobject]@{ Nom = $env:COMPUTERNAME; OS = $os.Caption; Build = $os.BuildNumber; Demarrage = $os.LastBootUpTime; Processeurs = $vh.LogicalProcessorCount
    MemoireGo = [math]::Round($vh.MemoryCapacity / 1GB, 1); MemoireLibreGo = [math]::Round($os.FreePhysicalMemory * 1KB / 1GB, 1); CheminVM = $vh.VirtualMachinePath; CheminDisques = $vh.VirtualHardDiskPath; NUMA = [bool]$vh.NumaSpanningEnabled }
  $r.Services = @(Get-Service vmms, vmcompute -ErrorAction SilentlyContinue | ForEach-Object { [pscustomobject]@{ Service = $_.Name; Nom = $_.DisplayName; Etat = [string]$_.Status } })
  $vms = @(Get-VM)
  $r.VMs = @($vms | ForEach-Object {
    $v = $_
    [pscustomobject]@{ VM = $v.Name; Etat = [string]$v.State; Statut = [string]$v.Status; Uptime = $(if ($v.Uptime.TotalSeconds) { '{0}j {1}h' -f $v.Uptime.Days, $v.Uptime.Hours } else { '' }); vCPU = $v.ProcessorCount
      MemDemarrageGo = [math]::Round($v.MemoryStartup / 1GB, 1); MemAttribueeGo = [math]::Round($v.MemoryAssigned / 1GB, 1); MemDynamique = [bool]$v.DynamicMemoryEnabled; MemMaxGo = $(if ($v.DynamicMemoryEnabled) { [math]::Round($v.MemoryMaximum / 1GB, 1) } else { $null })
      Generation = $v.Generation; Version = [string]$v.Version; Heartbeat = [string]$v.Heartbeat; ServicesIntegration = [string]$v.IntegrationServicesState
      DemarrageAuto = [string]$v.AutomaticStartAction; DelaiDemarrage = $v.AutomaticStartDelay; ArretAuto = [string]$v.AutomaticStopAction; Replication = [string]$v.ReplicationHealth; Chemin = $v.Path } })
  $r.Snaps = @($vms | Get-VMSnapshot -ErrorAction SilentlyContinue | ForEach-Object { [pscustomobject]@{ VM = $_.VMName; Point = $_.Name; Cree = $_.CreationTime; Type = [string]$_.SnapshotType } })
  $r.Disques = @($vms | Get-VMHardDiskDrive -ErrorAction SilentlyContinue | ForEach-Object {
    $d = $_; $o = [ordered]@{ VM = $d.VMName; Controleur = "$($d.ControllerType) $($d.ControllerNumber):$($d.ControllerLocation)"; Fichier = $d.Path; Existe = $false; Type = ''; TailleMaxGo = $null; TailleFichierGo = $null; Parent = ''; Erreur = '' }
    if ($d.Path) {
      $o.Existe = Test-Path -LiteralPath $d.Path
      try { $h = Get-VHD -Path $d.Path -ErrorAction Stop; $o.Type = [string]$h.VhdType; $o.TailleMaxGo = [math]::Round($h.Size / 1GB, 1); $o.TailleFichierGo = [math]::Round($h.FileSize / 1GB, 1); $o.Parent = $h.ParentPath } catch { $o.Erreur = $_.Exception.Message }
    } else { $o.Fichier = '(disque physique pass-through)'; $o.Existe = $true }
    [pscustomobject]$o })
  $r.Volumes = @(Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveType -eq 'Fixed' -and $_.Size -gt 5GB } | ForEach-Object {
    [pscustomobject]@{ Volume = $(if ($_.DriveLetter) { "$($_.DriveLetter):" } else { $_.FileSystemLabel }); Nom = $_.FileSystemLabel; SystemeFichiers = $_.FileSystemType; TailleGo = [math]::Round($_.Size / 1GB, 0); LibreGo = [math]::Round($_.SizeRemaining / 1GB, 0); LibrePct = [math]::Round($_.SizeRemaining * 100 / $_.Size, 1); Sante = [string]$_.HealthStatus } })
  $r.Switches = @(Get-VMSwitch -ErrorAction SilentlyContinue | ForEach-Object { [pscustomobject]@{ Commutateur = $_.Name; Type = [string]$_.SwitchType; Carte = $_.NetAdapterInterfaceDescription; Partage = [bool]$_.AllowManagementOS; SET = [bool]$_.EmbeddedTeamingEnabled } })
  $r.Cartes = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | ForEach-Object { [pscustomobject]@{ Carte = $_.Name; Description = $_.InterfaceDescription; Etat = [string]$_.Status; Vitesse = $_.LinkSpeed; Pilote = $_.DriverVersion; DatePilote = $_.DriverDate } })
  $r.VNics = @($vms | Get-VMNetworkAdapter -ErrorAction SilentlyContinue | ForEach-Object { [pscustomobject]@{ VM = $_.VMName; Carte = $_.Name; Commutateur = $_.SwitchName; MAC = $_.MacAddress; VLAN = $(try { (Get-VMNetworkAdapterVlan -VMNetworkAdapter $_).AccessVlanId } catch { '' }); IP = (@($_.IPAddresses | Where-Object { $_ -notmatch ':' }) -join ', '); Connectee = [bool]$_.Connected } })
  $r.Repl = @(try { Get-VMReplication -ErrorAction Stop | ForEach-Object { [pscustomobject]@{ VM = $_.VMName; Mode = [string]$_.Mode; Etat = [string]$_.State; Sante = [string]$_.Health; Derniere = $_.LastReplicationTime; Partenaire = $(if ($_.Mode -eq 'Primary') { $_.ReplicaServer } else { $_.PrimaryServer }); FrequenceSec = $_.FrequencySec } } } catch { })
  if (Get-Service ClusSvc -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Running' }) {
    try {
      Import-Module FailoverClusters -ErrorAction Stop
      $r.Cluster = (Get-Cluster).Name
      $r.Noeuds = @(Get-ClusterNode | ForEach-Object { [pscustomobject]@{ Noeud = $_.Name; Etat = [string]$_.State } })
      $r.CSV = @(Get-ClusterSharedVolume | ForEach-Object { $p = $_.SharedVolumeInfo.Partition; [pscustomobject]@{ CSV = $_.Name; Etat = [string]$_.State; Proprietaire = [string]$_.OwnerNode; TailleGo = [math]::Round($p.Size / 1GB, 0); LibreGo = [math]::Round($p.FreeSpace / 1GB, 0); LibrePct = [math]::Round($p.PercentFree, 1) } })
    } catch { $r.Erreurs += "Cluster : $($_.Exception.Message)" }
  }
  $r.Events = @(try { Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Hyper-V-VMMS-Admin', 'Microsoft-Windows-Hyper-V-Worker-Admin'; Level = 1, 2; StartTime = (Get-Date).AddDays(-7) } -MaxEvents 200 -ErrorAction Stop | ForEach-Object { [pscustomobject]@{ Date = $_.TimeCreated; Journal = ($_.LogName -replace 'Microsoft-Windows-Hyper-V-', ''); Id = $_.Id; Message = (($_.Message -split "`r?`n")[0]) } } } catch { })
  $r.Systeme = @(try { Get-WinEvent -FilterHashtable @{ LogName = 'System'; Level = 1, 2; StartTime = (Get-Date).AddDays(-7) } -MaxEvents 300 -ErrorAction Stop | Where-Object { $_.ProviderName -match 'disk|Ntfs|stor|iScsi|mpio|Kernel-Power|WHEA|volmgr' } | ForEach-Object { [pscustomobject]@{ Date = $_.TimeCreated; Source = $_.ProviderName; Id = $_.Id; Message = (($_.Message -split "`r?`n")[0]) } } } catch { })
  $r
}

Show-Etape "Collecte sur $($cible.Nom)..."
try { $r = Invoke-Cible $cible $Collecte } catch { $r = $null; Add-Check -Rubrique 'hote' -Titre 'Collecte' -Statut 'CRIT' -Resume "Collecte impossible : $($_.Exception.Message)" }

if ($r) {
  Show-Etape 'Analyse'
  foreach ($e in @($r.Erreurs)) { Add-Check -Rubrique 'hote' -Titre 'Erreur de collecte' -Statut $(if ($r.Module) { 'ATT' } else { 'CRIT' }) -Resume $e }
  $h = $r.Host; $now = Get-Date
  if ($r.Module) {
    # --- Hôte
    $ho = $r.Hote
    $upj = if ($ho.Demarrage) { [int]($now - [datetime]$ho.Demarrage).TotalDays } else { 0 }
    Add-Check -Rubrique 'hote' -Titre "Hôte $h" -Statut $(if ($upj -gt 90) { 'ATT' } else { 'INFO' }) -Resume "$($ho.OS) (build $($ho.Build)) · $($ho.Processeurs) processeurs logiques · $($ho.MemoireGo) Go · démarré il y a $upj j" -Table (To-Table @($ho)) -Cible $h `
      -Reco $(if ($upj -gt 90) { 'Hôte non redémarré depuis plus de 90 jours : les mises à jour Windows ne sont probablement pas appliquées. Planifier une fenêtre de maintenance.' })
    $ks = @($r.Services | Where-Object { $_.Etat -ne 'Running' })
    Add-Check -Rubrique 'hote' -Titre 'Service de gestion Hyper-V (VMMS)' -Statut $(if (@($r.Services | Where-Object { $_.Service -eq 'vmms' -and $_.Etat -eq 'Running' }).Count) { 'OK' } else { 'CRIT' }) -Resume (($r.Services | ForEach-Object { "$($_.Service) : $($_.Etat)" }) -join ' · ') -Cible $h `
      -Cmds $(if ($ks.Count) { @(Cmd 'Démarrer le service VMMS' 'Start-Service vmms') })
    $vms = @($r.VMs); $run = @($vms | Where-Object { $_.Etat -eq 'Running' })
    $memRun = ($run | Measure-Object MemAttribueeGo -Sum).Sum; $memStart = ($vms | Where-Object { $_.DemarrageAuto -ne 'Nothing' -or $_.Etat -eq 'Running' } | Measure-Object MemDemarrageGo -Sum).Sum
    $libre = $ho.MemoireLibreGo
    $pct = if ($ho.MemoireGo) { [math]::Round(($memStart + 4) * 100 / $ho.MemoireGo, 0) } else { 0 }
    Add-Check -Rubrique 'hote' -Titre 'Mémoire de l''hôte' -Statut $(if ($libre -lt 2 -or $pct -gt 100) { 'CRIT' } elseif ($libre -lt 4 -or $pct -gt 90) { 'ATT' } else { 'OK' }) `
      -Resume "$memRun Go attribués aux VM démarrées · $libre Go libres · mémoire de démarrage des VM à démarrage automatique + 4 Go pour l'hôte = $pct % de la RAM" -Cible $h `
      -Reco $(if ($pct -gt 90 -or $libre -lt 4) { 'Au redémarrage de l''hôte, toutes les VM ne pourront pas démarrer (mémoire de démarrage insuffisante). Réduire la mémoire de démarrage, activer la mémoire dynamique ou ajouter de la RAM.' })
    $vcpu = ($run | Measure-Object vCPU -Sum).Sum
    if ($ho.Processeurs) { $ratio = [math]::Round($vcpu / $ho.Processeurs, 1); Add-Check -Rubrique 'hote' -Titre 'Processeurs virtuels' -Statut $(if ($ratio -gt 4) { 'ATT' } else { 'INFO' }) -Resume "$vcpu vCPU sur $($ho.Processeurs) processeurs logiques (ratio ${ratio}:1)" -Cible $h }

    # --- VM
    Add-Check -Rubrique 'vms' -Titre 'Inventaire des VM' -Statut 'INFO' -Resume "$($vms.Count) VM dont $($run.Count) démarrée(s)" -Table (To-Table $vms @('VM', 'Etat', 'Uptime', 'vCPU', 'MemDemarrageGo', 'MemAttribueeGo', 'MemDynamique', 'Generation', 'Version', 'Heartbeat', 'DemarrageAuto', 'ArretAuto')) -Cible $h
    $off = @($vms | Where-Object { $_.Etat -ne 'Running' })
    if ($off.Count) { Add-Check -Rubrique 'vms' -Titre 'VM non démarrées' -Statut $(if (@($off | Where-Object { $_.Etat -notmatch '^Off$' }).Count) { 'ATT' } else { 'INFO' }) -Resume (($off | ForEach-Object { "$($_.VM) ($($_.Etat))" }) -join ', ') -Cible $h -Reco 'Vérifier qu''il s''agit de VM volontairement arrêtées (modèles, anciennes VM). Une VM « Saved » ou « Paused » peut signaler un manque d''espace disque.' }
    $hb = @($run | Where-Object { $_.Heartbeat -and $_.Heartbeat -notmatch 'Ok' })
    if ($hb.Count) { Add-Check -Rubrique 'vms' -Titre 'Pulsation (heartbeat) des VM' -Statut 'ATT' -Resume "Pas de réponse du système invité : $(($hb | ForEach-Object { "$($_.VM) ($($_.Heartbeat))" }) -join ', ')" -Cible $h -Reco 'Système invité figé ou services d''intégration absents : ouvrir la console de la VM.' }
    $na = @($run | Where-Object { $_.DemarrageAuto -eq 'Nothing' })
    Add-Check -Rubrique 'vms' -Titre 'Démarrage automatique' -Statut $(if ($na.Count) { 'ATT' } else { 'OK' }) -Resume $(if ($na.Count) { "VM démarrées qui ne redémarreront pas avec l'hôte : $(($na | ForEach-Object { $_.VM }) -join ', ')" } else { 'Toutes les VM démarrées redémarreront avec l''hôte' }) -Cible $h `
      -Reco $(if ($na.Count) { 'Après une coupure ou une mise à jour de l''hôte, ces VM resteront éteintes. Échelonner les délais (contrôleur de domaine d''abord).' }) `
      -Cmds @($na | ForEach-Object { Cmd "Démarrage automatique pour $($_.VM)" "Set-VM -Name $(Q $_.VM) -AutomaticStartAction Start -AutomaticStartDelay 60" })
    $to = @($vms | Where-Object { $_.ArretAuto -eq 'TurnOff' })
    if ($to.Count) { Add-Check -Rubrique 'vms' -Titre 'Action à l''arrêt de l''hôte' -Statut 'ATT' -Resume "Coupure brutale configurée : $(($to | ForEach-Object { $_.VM }) -join ', ')" -Cible $h -Reco 'Préférer « Arrêter le système invité » (ShutDown) ou « Enregistrer » (Save).' -Cmds @($to | ForEach-Object { Cmd "Arrêt propre pour $($_.VM)" "Set-VM -Name $(Q $_.VM) -AutomaticStopAction ShutDown" }) }
    $is = @($run | Where-Object { $_.ServicesIntegration -and $_.ServicesIntegration -notmatch 'Up to date|À jour' })
    if ($is.Count) { Add-Check -Rubrique 'vms' -Titre 'Services d''intégration' -Statut 'ATT' -Resume (($is | ForEach-Object { "$($_.VM) : $($_.ServicesIntegration)" }) -join ' · ') -Cible $h -Reco 'Mettre à jour le système invité (Windows Update pour les invités récents) ou les services d''intégration.' }
    $vold = @($vms | Where-Object { $_.Version -match '^[5-7]\.' })
    if ($vold.Count) { Add-Check -Rubrique 'vms' -Titre 'Version de configuration des VM' -Statut 'INFO' -Resume "Ancienne version : $(($vold | ForEach-Object { "$($_.VM) ($($_.Version))" }) -join ', ')" -Cible $h -Reco 'Mettre à niveau la configuration (VM arrêtée, irréversible) pour profiter des fonctions récentes, après vérification de la compatibilité avec la sauvegarde / réplication.' -Cmds @($vold | ForEach-Object { Cmd "Mettre à niveau $($_.VM) (VM arrêtée)" "Update-VMVersion -Name $(Q $_.VM) -Confirm:`$false" }) }

    # --- Points de contrôle
    $sn = @($r.Snaps | ForEach-Object { $a = [int]($now - [datetime]$_.Cree).TotalDays; $_ | Add-Member -NotePropertyName AgeJours -NotePropertyValue $a -PassThru })
    $crit = @($sn | Where-Object { $_.AgeJours -gt 30 }); $att = @($sn | Where-Object { $_.AgeJours -gt 7 -and $_.AgeJours -le 30 })
    Add-Check -Rubrique 'snap' -Titre 'Points de contrôle' -Statut $(if ($crit.Count) { 'CRIT' } elseif ($att.Count) { 'ATT' } elseif ($sn.Count) { 'INFO' } else { 'OK' }) `
      -Resume $(if ($sn.Count) { "$($sn.Count) point(s) de contrôle · $($crit.Count) de plus de 30 jours · $($att.Count) de 8 à 30 jours" } else { 'Aucun point de contrôle' }) -Table (To-Table $sn @('VM', 'Point', 'Cree', 'AgeJours', 'Type')) -Cible $h `
      -Reco $(if ($crit.Count -or $att.Count) { 'Un point de contrôle n''est pas une sauvegarde : le fichier .avhdx grossit et dégrade les performances. Supprimer ceux qui ne servent plus (la fusion se fait à chaud) après accord du client.' }) `
      -Cmds @(($crit + $att) | Select-Object -First 10 | ForEach-Object { Cmd "Supprimer « $($_.Point) » ($($_.VM))" "Get-VMSnapshot -VMName $(Q $_.VM) -Name $(Q $_.Point) | Remove-VMSnapshot" })

    # --- Disques
    $dk = @($r.Disques)
    $absents = @($dk | Where-Object { -not $_.Existe -or $_.Erreur })
    $snapVM = @($r.Snaps | ForEach-Object { $_.VM } | Select-Object -Unique)
    $orph = @($dk | Where-Object { $_.Fichier -match '\.avhdx?$' -and $snapVM -notcontains $_.VM })
    Add-Check -Rubrique 'disk' -Titre 'Disques virtuels' -Statut $(if ($absents.Count -or $orph.Count) { 'CRIT' } else { 'OK' }) `
      -Resume $(if ($absents.Count) { "Disque introuvable ou illisible : $(($absents | ForEach-Object { $_.VM + ' → ' + $_.Fichier }) -join ' ; ')" } elseif ($orph.Count) { "VM tournant sur un disque de différenciation sans point de contrôle : $(($orph | ForEach-Object { $_.VM }) -join ', ')" } else { "$($dk.Count) disque(s), tous accessibles" }) `
      -Table (To-Table $dk @('VM', 'Controleur', 'Fichier', 'Type', 'TailleMaxGo', 'TailleFichierGo', 'Existe')) -Cible $h `
      -Reco $(if ($orph.Count) { 'Fusion inachevée (souvent après une sauvegarde interrompue) : le .avhdx grossit sans fin. Arrêter la VM, fusionner le disque dans son parent (Edit Disk / Merge-VHD) après une sauvegarde, puis rattacher le .vhdx.' } elseif ($absents.Count) { 'Vérifier le chemin du disque (déplacé, volume absent, droits).' })
    $dyn = @($dk | Where-Object { $_.Type -eq 'Dynamic' })
    if ($dyn.Count) {
      $prov = ($dk | Measure-Object TailleMaxGo -Sum).Sum
      Add-Check -Rubrique 'disk' -Titre 'Disques dynamiques (surallocation)' -Statut 'INFO' -Resume "$($dyn.Count) disque(s) dynamique(s) · capacité totale promise aux VM : $([math]::Round($prov,0)) Go" -Cible $h -Reco 'Comparer à l''espace libre des volumes ci-dessous : si les disques dynamiques grossissent jusqu''à leur taille maximale, le volume peut se remplir et les VM se mettre en pause.'
    }
    foreach ($v in @($r.Volumes)) {
      $p = $v.LibrePct
      Add-Check -Rubrique 'disk' -Titre ("Volume $($v.Volume) $($v.Nom)").Trim() -Statut $(if ($p -lt 10 -or $v.Sante -notmatch 'Healthy|Sain') { 'CRIT' } elseif ($p -lt 20) { 'ATT' } else { 'OK' }) -Resume "$p % libre ($($v.LibreGo) Go sur $($v.TailleGo) Go) · $($v.SystemeFichiers) · santé $($v.Sante)" -Cible $h `
        -Reco $(if ($p -lt 20) { 'Un volume plein met les VM en pause (état Paused-Critical). Supprimer les points de contrôle inutiles, déplacer des VM ou agrandir le volume.' })
    }

    # --- Réseau
    Add-Check -Rubrique 'res' -Titre 'Commutateurs virtuels' -Statut $(if (@($r.Switches).Count) { 'INFO' } else { 'ATT' }) -Resume "$(@($r.Switches).Count) commutateur(s)" -Table (To-Table $r.Switches) -Cible $h
    $nd = @($r.Cartes | Where-Object { $_.Etat -ne 'Up' }); $sw = @($r.Switches | ForEach-Object { $_.Carte })
    $ndUsed = @($nd | Where-Object { $sw -contains $_.Description })
    Add-Check -Rubrique 'res' -Titre 'Cartes réseau physiques' -Statut $(if ($ndUsed.Count) { 'CRIT' } elseif ($nd.Count) { 'INFO' } else { 'OK' }) -Resume $(if ($ndUsed.Count) { "Carte d'un commutateur virtuel déconnectée : $(($ndUsed | ForEach-Object { $_.Carte }) -join ', ')" } else { "$(@($r.Cartes).Count) carte(s)$(if ($nd.Count) { ' · ' + $nd.Count + ' non connectée(s)' })" }) -Table (To-Table $r.Cartes) -Cible $h
    $nc = @($r.VNics | Where-Object { -not $_.Connectee -or -not $_.Commutateur })
    Add-Check -Rubrique 'res' -Titre 'Cartes réseau des VM' -Statut $(if ($nc.Count) { 'ATT' } else { 'OK' }) -Resume $(if ($nc.Count) { "Non connectée(s) à un commutateur : $(($nc | ForEach-Object { $_.VM + '/' + $_.Carte }) -join ', ')" } else { "$(@($r.VNics).Count) carte(s), toutes connectées" }) -Table (To-Table $r.VNics) -Cible $h

    # --- Réplication et cluster
    $rp = @($r.Repl)
    if ($rp.Count) {
      $ko = @($rp | Where-Object { $_.Sante -ne 'Normal' })
      Add-Check -Rubrique 'repl' -Titre 'Réplica Hyper-V' -Statut $(if (@($ko | Where-Object { $_.Sante -eq 'Critical' }).Count) { 'CRIT' } elseif ($ko.Count) { 'ATT' } else { 'OK' }) -Resume $(if ($ko.Count) { "Santé dégradée : $(($ko | ForEach-Object { $_.VM + ' (' + $_.Sante + ')' }) -join ', ')" } else { "$($rp.Count) VM répliquée(s), santé normale" }) -Table (To-Table $rp) -Cible $h `
        -Cmds @($ko | Where-Object { $_.Mode -eq 'Primary' } | ForEach-Object { Cmd "Reprendre la réplication de $($_.VM)" "Resume-VMReplication -VMName $(Q $_.VM); Resume-VMReplication -VMName $(Q $_.VM) -Resynchronize" })
    } else { Add-Check -Rubrique 'repl' -Titre 'Réplica Hyper-V' -Statut 'INFO' -Resume 'Aucune VM répliquée' -Cible $h }
    if ($r.Cluster) {
      $kn = @($r.Noeuds | Where-Object { $_.Etat -ne 'Up' })
      Add-Check -Rubrique 'repl' -Titre "Cluster $($r.Cluster)" -Statut $(if ($kn.Count) { 'CRIT' } else { 'OK' }) -Resume $(if ($kn.Count) { "Nœud(s) indisponible(s) : $(($kn | ForEach-Object { $_.Noeud + ' (' + $_.Etat + ')' }) -join ', ')" } else { "$(@($r.Noeuds).Count) nœud(s) actifs" }) -Table (To-Table $r.Noeuds) -Cible $h
      foreach ($c in @($r.CSV)) { Add-Check -Rubrique 'repl' -Titre "Volume partagé $($c.CSV)" -Statut $(if ($c.Etat -ne 'Online' -or $c.LibrePct -lt 10) { 'CRIT' } elseif ($c.LibrePct -lt 20) { 'ATT' } else { 'OK' }) -Resume "$($c.Etat) · $($c.LibrePct) % libre ($($c.LibreGo) Go sur $($c.TailleGo) Go) · propriétaire $($c.Proprietaire)" -Cible $h }
    }
  }
  # --- Journaux
  $ev = @($r.Events)
  Add-Check -Rubrique 'jour' -Titre 'Journaux Hyper-V (7 jours, erreurs)' -Statut $(if ($ev.Count -gt 10) { 'ATT' } elseif ($ev.Count) { 'INFO' } else { 'OK' }) -Resume "$($ev.Count) erreur(s)" -Table (To-Table ($ev | Select-Object -First 100)) -Cible $h
  $sy = @($r.Systeme)
  Add-Check -Rubrique 'jour' -Titre 'Erreurs disque / stockage / matériel (journal Système, 7 jours)' -Statut $(if ($sy.Count) { 'ATT' } else { 'OK' }) -Resume $(if ($sy.Count) { "$($sy.Count) erreur(s) (disque, NTFS, stockage, WHEA, alimentation)" } else { 'Aucune' }) -Table (To-Table ($sy | Select-Object -First 100)) -Cible $h `
    -Reco $(if ($sy.Count) { 'Des erreurs disque ou WHEA annoncent souvent une panne matérielle : vérifier l''état du RAID dans l''outil du constructeur (iDRAC, iLO, XClarity...).' })
}

$nomCible = if ($cible) { $cible.Nom } else { 'inconnu' }
Save-Audit ("Audit-HyperV_{0}_{1:yyyyMMdd_HHmm}.html" -f $nomCible, $script:Debut) 'Audit Hyper-V' $client $Rubriques $Prerequis
