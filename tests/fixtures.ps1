# Données factices pour tester l'analyse et le rendu des scripts d'audit
$env:COMPUTERNAME = 'SRV-AD01'; $env:USERDOMAIN = 'CONTOSO'; $env:USERNAME = 'tony'
$script:Reponses = New-Object System.Collections.Queue
function Read-Host($p) { if ($script:Reponses.Count) { $a = $script:Reponses.Dequeue() } else { $a = '' }; Write-Host "$p > $a" -ForegroundColor DarkGray; $a }
function Invoke-Item($p) { Write-Host "[ouvrir] $p" }
function Get-DossierRapports { $d = (Join-Path ([IO.Path]::GetTempPath()) 'console-it-tests'); New-Item -ItemType Directory $d -Force | Out-Null; $d }
function Test-Ssh { $true }
function Invoke-Cible($cible, $bloc, $arguments) { $script:FX }
function P { param([hashtable]$h) [pscustomobject]$h }
$J = (Get-Date)
switch ($script:TYPE) {
'AD' {
  'Contoso SA' | ForEach-Object { $script:Reponses.Enqueue($_) }; $script:Reponses.Enqueue('')
  $script:FX = @{ Host = 'SRV-AD01'; Erreurs = @(); ModuleAD = $true
    Services = @((P @{Service='NTDS';Nom='Services de domaine AD';Etat='Running';Demarrage='Automatic'}), (P @{Service='DFSR';Nom='Réplication DFS';Etat='Stopped';Demarrage='Automatic'}), (P @{Service='W32Time';Nom='Temps Windows';Etat='Running';Demarrage='Automatic'}))
    Domaine = P @{ DNSRoot='contoso.local'; NetBIOS='CONTOSO'; DomainMode='Windows2012R2Domain'; ForestMode='Windows2012R2Forest'; PDC='SRV-AD01.contoso.local'; RID='SRV-AD01.contoso.local'; Infra='SRV-AD01.contoso.local'; Schema='OLD-DC.contoso.local'; Naming='SRV-AD01.contoso.local'; SID='S-1-5-21-1'; Forest='contoso.local' }
    DCs = @((P @{Nom='SRV-AD01.contoso.local';Site='Paris';IP='10.0.0.10';OS='Windows Server 2022 Standard';GC=$true;RODC=$false}))
    Pwd = P @{ MinLength=7; Complexity=$true; MaxAgeDays=42; History=24; LockoutThreshold=0; LockoutMin=30 }
    FGPP = @(); NbUsers = 84
    Inactifs = @((P @{Compte='jdupont';Nom='Jean Dupont';DerniereConnexion=$J.AddDays(-200);Description='Parti 2025'}), (P @{Compte='stagiaire';Nom='Stagiaire';DerniereConnexion='jamais';Description=''}))
    SansExpiration = @((P @{Compte='svc-backup';Nom='Service sauvegarde';MotDePasseDefini=$J.AddDays(-900);Description='Veeam'}))
    NbOrdinateursInactifs = 12
    Admins = @((P @{Compte='Administrateur';Nom='Administrateur';Type='user'}), (P @{Compte='tony';Nom='Tony';Type='user'}))
    EntAdmins = @('Administrateur'); Krbtgt = $J.AddDays(-1500); AdminInvite = P @{ Compte='Administrateur'; Actif=$true; MotDePasse=$J.AddDays(-700) }; Corbeille = $false
    Dcdiag = "Diagnostic du serveur d'annuaire`n`n   Test de démarrage : Connectivity`n         ......................... Le test Connectivity de SRV-AD01 a réussi`n         ......................... SRV-AD01 a réussi le test Replications`n         ......................... SRV-AD01 a échoué au test SysVolCheck`n         ......................... SRV-AD01 a réussi le test NetLogons"
    ReplCsv = ''; ReplSummary = 'Replication Summary Start Time: ...'; Fsmo = "Contrôleur de schéma        OLD-DC.contoso.local`nMaître d'attribution de noms SRV-AD01.contoso.local"
    W32Status = "Indicateur de dérive : 0(aucun avertissement)`nStrate : 1 (référence principale - synchronisée par radio)`nSource : Local CMOS Clock"
    W32Source = 'Local CMOS Clock'; W32Monitor = "SRV-AD01.contoso.local[10.0.0.10:123]:`n    ICMP: 0ms de délai`n    NTP: +0.0000000s de décalage par rapport à SRV-AD01.contoso.local"
    Partages = @('NETLOGON')
    Sync = P @{ CycleActif=$true; Intervalle='00:30:00'; Prochain=$J.AddMinutes(12); Staging=$false; EnCours=$false }
    SyncRuns = @((P @{Connecteur='contoso.onmicrosoft.com - AAD';Profil='Export';Resultat='success';Debut=$J.AddMinutes(-20);Fin=$J.AddMinutes(-19)}), (P @{Connecteur='contoso.local';Profil='Delta Import';Resultat='completed-export-errors';Debut=$J.AddMinutes(-21);Fin=$J.AddMinutes(-20)}))
  }
}
'DNS' {
  'Contoso SA', '', 'www.microsoft.com' | ForEach-Object { $script:Reponses.Enqueue($_) }
  $script:FX = @{ Host = 'SRV-AD01'; Erreurs = @(); Module = $true; Domaine = 'contoso.local'
    Service = P @{ Etat='Running'; Demarrage='Automatic' }
    Redirecteurs = @('8.8.8.8', '192.168.1.254'); TestsRedir = @((P @{Redirecteur='8.8.8.8';Repond=$true;Duree_ms=24;Erreur=''}), (P @{Redirecteur='192.168.1.254';Repond=$false;Duree_ms=2010;Erreur='Délai expiré'}))
    Recursion = $true
    Zones = @((P @{Zone='contoso.local';Type='Primary';Inverse=$false;IntegreeAD=$true;Replication='Domain';MiseAJour='Secure';Vieillissement=$false;NonActualisation='7.00:00:00';Actualisation='7.00:00:00';Suspendue=$false;Arretee=$false}),
              (P @{Zone='_msdcs.contoso.local';Type='Primary';Inverse=$false;IntegreeAD=$true;Replication='Forest';MiseAJour='Secure';Vieillissement=$false;NonActualisation='';Actualisation='';Suspendue=$false;Arretee=$false}),
              (P @{Zone='partenaire.fr';Type='Primary';Inverse=$false;IntegreeAD=$true;Replication='Domain';MiseAJour='NonsecureAndSecure';Vieillissement=$true;NonActualisation='7.00:00:00';Actualisation='7.00:00:00';Suspendue=$false;Arretee=$false}))
    Nettoyage = P @{ Actif=$false; Intervalle='7.00:00:00'; Dernier=$null }
    Anciens = @((P @{Zone='contoso.local';Dynamiques=140;PlusDe30j=63;PlusAncien=$J.AddDays(-800)}))
    Ecoute = @()
    Tests = @((P @{Nom='www.microsoft.com';Resultat='OK';Reponse='23.45.67.89'}), (P @{Nom='_ldap._tcp.dc._msdcs.contoso.local';Resultat='OK';Reponse='srv-ad01.contoso.local'}))
    Clients = @((P @{Carte='Ethernet0';ServeursDNS='127.0.0.1, 8.8.8.8'}))
    Events = @((P @{Date=$J.AddDays(-1);Niveau='Avertissement';Id=4013;Message='Le serveur DNS attend que les services de domaine AD signalent...'}))
  }
}
'DHCP' {
  'Contoso SA', '' | ForEach-Object { $script:Reponses.Enqueue($_) }
  $script:FX = @{ Host = 'SRV-AD01'; Erreurs = @(); Module = $true; EstDC = $true; DnsCompte = ''
    Service = P @{ Etat='Running'; Demarrage='Automatic' }
    Reglages = P @{ Autorise=$true; Domaine=$true; DetectionConflits=0; BootpDynamique=$false }
    Autorises = @((P @{Serveur='srv-ad01.contoso.local';IP='10.0.0.10'}))
    Scopes = @((P @{Etendue='10.0.0.0';Nom='LAN';Etat='Active';Debut='10.0.0.100';Fin='10.0.0.200';Masque='255.255.255.0';Bail='8.00:00:00';Utilisees=93;Libres=8;Pourcent=92.1;Reservations=12;Routeur='10.0.0.254';DNS='10.0.0.10';DomaineDNS=''}),
               (P @{Etendue='10.0.50.0';Nom='Invités';Etat='Active';Debut='10.0.50.10';Fin='10.0.50.250';Masque='255.255.255.0';Bail='1.00:00:00';Utilisees=20;Libres=221;Pourcent=8.3;Reservations=0;Routeur='';DNS='8.8.8.8';DomaineDNS=''}))
    OptServeur = P @{ Routeur=''; DNS=''; DomaineDNS='contoso.local' }
    OptServeurListe = @((P @{Option=15;Nom='DNS Domain Name';Valeur='contoso.local'}))
    Failover = @()
    Base = P @{ Fichier='C:\Windows\system32\dhcp\dhcp.mdb'; Sauvegarde='C:\Windows\system32\dhcp\backup'; IntervalleMin=60; Nettoyage=60 }
    DerniereSauvegarde = $J.AddMinutes(-40); Audit = $true
    DnsMaj = P @{ MiseAJour='OnClientRequest'; SupprimerALaFin=$true }
    TestsDns = @((P @{DNS='10.0.0.10';Repond=$true}), (P @{DNS='8.8.8.8';Repond=$true}))
    Events = @()
  }
}
'Veeam' {
  'Contoso SA', '', '30' | ForEach-Object { $script:Reponses.Enqueue($_) }
  $script:FX = @{ Host = 'SRV-VBR'; Erreurs = @(); Module = $true; Version = '12.1.2.172'
    Services = @((P @{Service='VeeamBackupSvc';Nom='Veeam Backup Service';Etat='Running';Demarrage='Automatic'}), (P @{Service='VeeamCloudSvc';Nom='Veeam Cloud Connect Service';Etat='Stopped';Demarrage='Manual'}))
    Licence = P @{ Edition='EnterprisePlus'; Type='Subscription'; Statut='Valid'; Expiration=$J.AddDays(45); Support=$J.AddDays(45); Proprietaire='Contoso'; Instances='18 / 20' }
    Jobs = @((P @{Travail='Sauvegarde VM nuit';Type='Backup';Planifie=$true;Actif=$true;Resultat='Success';Etat='Stopped';Fin=$J.AddHours(-9);Debut=$J.AddHours(-10);Cible='Repo NAS'}),
             (P @{Travail='Copie externalisée';Type='BackupSync';Planifie=$true;Actif=$true;Resultat='Failed';Etat='Stopped';Fin=$J.AddHours(-20);Debut=$J.AddHours(-22);Cible='Cloud'}),
             (P @{Travail='Agent portables';Type='Agent';Planifie=$true;Actif=$true;Resultat='Warning';Etat='Stopped';Fin=$J.AddHours(-80);Debut=$J.AddHours(-81);Cible='Repo NAS'}),
             (P @{Travail='Ancien SQL';Type='Backup';Planifie=$false;Actif=$false;Resultat='Success';Etat='Stopped';Fin=$J.AddDays(-300);Debut=$J.AddDays(-300);Cible='Repo NAS'}))
    Repos = @((P @{Depot='Repo NAS';Type='CifsShare';Chemin='\\nas\veeam';TotalGo=8000;LibreGo=1200;LibrePct=15;Immuable=$false}), (P @{Depot='Default Backup Repository';Type='WinLocal';Chemin='C:\Backup';TotalGo=200;LibreGo=150;LibrePct=75;Immuable=$false}))
    Sobr = @()
    ConfBackup = P @{ Active=$true; Resultat='Success'; Etat='Stopped'; Chiffree=$false; Depot='Default Backup Repository'; Planifiee=$true }
    Serveurs = @((P @{Serveur='SRV-VBR';Type='Local';Description='Backup server'}), (P @{Serveur='HV01';Type='HvServer';Description=''}))
    Proxies = @(); Events = @()
  }
}
'HyperV' {
  'Contoso SA', '' | ForEach-Object { $script:Reponses.Enqueue($_) }
  $script:FX = @{ Host = 'HV01'; Erreurs = @(); Module = $true
    Hote = P @{ Nom='HV01'; OS='Microsoft Windows Server 2019 Standard'; Build='17763'; Demarrage=$J.AddDays(-140); Processeurs=32; MemoireGo=128; MemoireLibreGo=3.1; CheminVM='D:\Hyper-V'; CheminDisques='D:\Hyper-V\Disques'; NUMA=$true }
    Services = @((P @{Service='vmms';Nom='Gestion d''ordinateurs virtuels Hyper-V';Etat='Running'}))
    VMs = @((P @{VM='SRV-AD01';Etat='Running';Statut='Opération normale';Uptime='40j 2h';vCPU=4;MemDemarrageGo=8;MemAttribueeGo=8;MemDynamique=$false;MemMaxGo=$null;Generation=2;Version='9.0';Heartbeat='OkApplicationsUnknown';ServicesIntegration='Up to date';DemarrageAuto='StartIfRunning';DelaiDemarrage=0;ArretAuto='Save';Replication='NotApplicable';Chemin='D:\Hyper-V'}),
            (P @{VM='SRV-APP';Etat='Running';Statut='Opération normale';Uptime='40j 2h';vCPU=8;MemDemarrageGo=64;MemAttribueeGo=64;MemDynamique=$false;MemMaxGo=$null;Generation=2;Version='9.0';Heartbeat='OkApplicationsHealthy';ServicesIntegration='Update required';DemarrageAuto='Nothing';DelaiDemarrage=0;ArretAuto='TurnOff';Replication='Warning';Chemin='D:\Hyper-V'}),
            (P @{VM='SRV-RDS';Etat='Running';Statut='Opération normale';Uptime='3j 1h';vCPU=8;MemDemarrageGo=32;MemAttribueeGo=40;MemDynamique=$true;MemMaxGo=48;Generation=1;Version='5.0';Heartbeat='OkApplicationsUnknown';ServicesIntegration='Up to date';DemarrageAuto='Start';DelaiDemarrage=120;ArretAuto='ShutDown';Replication='NotApplicable';Chemin='D:\Hyper-V'}),
            (P @{VM='MODELE-W11';Etat='Off';Statut='';Uptime='';vCPU=2;MemDemarrageGo=4;MemAttribueeGo=0;MemDynamique=$true;MemMaxGo=8;Generation=2;Version='10.0';Heartbeat='';ServicesIntegration='';DemarrageAuto='Nothing';DelaiDemarrage=0;ArretAuto='Save';Replication='NotApplicable';Chemin='D:\Hyper-V'}))
    Snaps = @((P @{VM='SRV-APP';Point='Avant MAJ ERP';Cree=$J.AddDays(-95);Type='Standard'}), (P @{VM='SRV-RDS';Point='Test';Cree=$J.AddDays(-10);Type='Standard'}))
    Disques = @((P @{VM='SRV-AD01';Controleur='SCSI 0:0';Fichier='D:\Hyper-V\SRV-AD01.vhdx';Existe=$true;Type='Dynamic';TailleMaxGo=127;TailleFichierGo=45;Parent='';Erreur=''}),
                (P @{VM='SRV-APP';Controleur='SCSI 0:0';Fichier='D:\Hyper-V\SRV-APP_A1B2.avhdx';Existe=$true;Type='Differencing';TailleMaxGo=500;TailleFichierGo=180;Parent='D:\Hyper-V\SRV-APP.vhdx';Erreur=''}),
                (P @{VM='SRV-AD01';Controleur='SCSI 0:1';Fichier='D:\Hyper-V\SRV-AD01-data_9F3C.avhdx';Existe=$true;Type='Differencing';TailleMaxGo=200;TailleFichierGo=12;Parent='D:\Hyper-V\SRV-AD01-data.vhdx';Erreur=''}))
    Volumes = @((P @{Volume='C:';Nom='';SystemeFichiers='NTFS';TailleGo=120;LibreGo=40;LibrePct=33.3;Sante='Healthy'}), (P @{Volume='D:';Nom='VMs';SystemeFichiers='ReFS';TailleGo=2000;LibreGo=230;LibrePct=11.5;Sante='Healthy'}))
    Switches = @((P @{Commutateur='LAN';Type='External';Carte='Intel X710 #1';Partage=$true;SET=$false}))
    Cartes = @((P @{Carte='NIC1';Description='Intel X710 #1';Etat='Up';Vitesse='10 Gbps';Pilote='1.12';DatePilote='2021-03-01'}), (P @{Carte='NIC2';Description='Intel X710 #2';Etat='Disconnected';Vitesse='0 bps';Pilote='1.12';DatePilote='2021-03-01'}))
    VNics = @((P @{VM='SRV-AD01';Carte='Carte réseau';Commutateur='LAN';MAC='00155D000101';VLAN=0;IP='10.0.0.10';Connectee=$true}), (P @{VM='MODELE-W11';Carte='Carte réseau';Commutateur='';MAC='00155D000109';VLAN=0;IP='';Connectee=$false}))
    Repl = @((P @{VM='SRV-APP';Mode='Primary';Etat='Replicating';Sante='Warning';Derniere=$J.AddHours(-30);Partenaire='HV02';FrequenceSec=300}))
    Events = @((P @{Date=$J.AddDays(-2);Journal='VMMS-Admin';Id=18012;Message='Échec de la création du point de contrôle pour SRV-APP'}))
    Systeme = @()
  }
}
}
