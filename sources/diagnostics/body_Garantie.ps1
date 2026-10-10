# ==================================================================================
#  FICHE GARANTIE PC (identification matérielle)
# ==================================================================================
$ErrorActionPreference = 'SilentlyContinue'
$Rubriques = [ordered]@{
  'id'    = @('Identification', '🏷️')
  'comp'  = @('Composants', '🔩')
  'perif' = @('Batterie, écrans et réseau', '🔋')
}
$Prerequis = "À lancer sur le poste concerné, en administrateur pour obtenir les numéros de série complets (disques, batterie). Produit aussi une fiche texte (dans le dossier des rapports) et la copie dans le presse-papiers. Lecture seule."
Show-Titre 'Fiche garantie PC' "Numéro de série / Service Tag, code service express Dell, modèle, BIOS, mémoire, disques, batterie, écrans, adresses MAC.`nLecture seule : le script ne modifie rien."
$script:Cibles.Add($env:COMPUTERNAME)
$h = $env:COMPUTERNAME
function Clean($s) { if ($null -eq $s) { '' } else { ([string]$s).Trim() } }
function Edid($a) { if (-not $a) { '' } else { (($a | Where-Object { $_ -ne 0 }) | ForEach-Object { [char]$_ }) -join '' } }
function Express([string]$tag) {
  $tag = (Clean $tag).ToUpper(); if ($tag.Length -lt 5 -or $tag.Length -gt 8) { return $null }
  $ch = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ'; $v = [bigint]0
  foreach ($c in $tag.ToCharArray()) { $i = $ch.IndexOf([string]$c); if ($i -lt 0) { return $null }; $v = $v * 36 + $i }
  $v.ToString()
}

Show-Etape 'Identification'
$bios = Get-CimInstance Win32_BIOS; $cs = Get-CimInstance Win32_ComputerSystem; $csp = Get-CimInstance Win32_ComputerSystemProduct
$os = Get-CimInstance Win32_OperatingSystem; $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1; $enc = Get-CimInstance Win32_SystemEnclosure
$fab = Clean $cs.Manufacturer; $mod = Clean $cs.Model
$serie = Clean $bios.SerialNumber; if (-not $serie -or $serie -match 'O\.E\.M|Default|None|To be filled') { $serie = Clean $csp.IdentifyingNumber }
$express = if ($fab -match 'Dell') { Express $serie } else { $null }
$user = Clean $cs.UserName; if (-not $user) { $user = "$env:USERDOMAIN\$env:USERNAME" }
$id = [ordered]@{ Fabricant = $fab; Modele = $mod; NumeroSerie = $serie }
if ($express) { $id.CodeServiceExpress = $express }
if (Clean $cs.SystemFamily) { $id.Famille = Clean $cs.SystemFamily }
if (Clean $cs.SystemSKUNumber) { $id.SKU = Clean $cs.SystemSKUNumber }
$at = Clean $enc.SMBIOSAssetTag; if ($at -and $at -notmatch 'O\.E\.M|Default|None|Asset|No Asset') { $id.AssetTag = $at }
$id.NomMachine = $h; $id.UtilisateurConnecte = $user; $id.UUID = Clean $csp.UUID
$liens = @()
if ($serie) {
  if ($fab -match 'Dell') { $liens += [ordered]@{ t = 'web'; l = 'Garantie Dell (Service Tag)'; u = "https://www.dell.com/support/home/fr-fr/product-support/servicetag/$serie/overview" } }
  elseif ($fab -match 'Lenovo') { $liens += [ordered]@{ t = 'web'; l = 'Garantie Lenovo'; u = "https://pcsupport.lenovo.com/fr/fr/products/$serie/warranty" } }
  elseif ($fab -match 'HP|Hewlett') { $liens += [ordered]@{ t = 'web'; l = 'Vérifier la garantie HP'; u = 'https://support.hp.com/fr-fr/check-warranty' } }
}
Add-Check -Rubrique 'id' -Titre 'Identification du poste' -Statut 'INFO' -Resume "$fab $mod · N° de série $serie$(if ($express) { " · code express $express" })" -Table (To-Table @([pscustomobject]$id)) -Cmds $liens -Cible $h
$bd = $bios.ReleaseDate; $ageB = if ($bd) { [int]((Get-Date) - [datetime]$bd).TotalDays } else { $null }
Add-Check -Rubrique 'id' -Titre 'BIOS / firmware' -Statut $(if ($null -ne $ageB -and $ageB -gt 1095) { 'ATT' } else { 'INFO' }) -Resume "$(Clean $bios.Manufacturer) $(Clean $bios.SMBIOSBIOSVersion) du $(if ($bd) { ([datetime]$bd).ToString('dd/MM/yyyy') } else { '?' })" -Cible $h `
  -Reco $(if ($null -ne $ageB -and $ageB -gt 1095) { 'BIOS de plus de 3 ans : les constructeurs publient des correctifs de sécurité et de stabilité. Vérifier la dernière version sur le site du constructeur.' })
$ageOs = if ($os.InstallDate) { [int]((Get-Date) - $os.InstallDate).TotalDays } else { $null }
Add-Check -Rubrique 'id' -Titre 'Système d''exploitation' -Statut 'INFO' -Resume "$(Clean $os.Caption) $(Clean $os.OSArchitecture) · version $(Clean $os.Version) · installé le $(if ($os.InstallDate) { $os.InstallDate.ToString('dd/MM/yyyy') } else { '?' })" -Cible $h

Show-Etape 'Composants'
$ramTot = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
Add-Check -Rubrique 'comp' -Titre 'Processeur' -Statut 'INFO' -Resume "$(Clean $cpu.Name) · $($cpu.NumberOfCores) cœurs / $($cpu.NumberOfLogicalProcessors) logiques" -Cible $h
$mods = @(Get-CimInstance Win32_PhysicalMemory | ForEach-Object { [pscustomobject]@{ Emplacement = Clean $_.DeviceLocator; Go = [math]::Round($_.Capacity / 1GB); Fabricant = Clean $_.Manufacturer; Reference = Clean $_.PartNumber; NumeroSerie = Clean $_.SerialNumber; MHz = $_.Speed } })
Add-Check -Rubrique 'comp' -Titre 'Mémoire' -Statut 'INFO' -Resume "$ramTot Go en $($mods.Count) barrette(s)" -Table (To-Table $mods) -Cible $h
$disks = @(Get-PhysicalDisk | ForEach-Object { [pscustomobject]@{ Modele = Clean $_.FriendlyName; NumeroSerie = Clean $_.SerialNumber; Taille_Go = [math]::Round($_.Size / 1GB); Type = [string]$_.MediaType; Bus = [string]$_.BusType; Sante = [string]$_.HealthStatus } })
if (-not $disks.Count) { $disks = @(Get-CimInstance Win32_DiskDrive | ForEach-Object { [pscustomobject]@{ Modele = Clean $_.Model; NumeroSerie = Clean $_.SerialNumber; Taille_Go = [math]::Round($_.Size / 1GB); Type = ''; Bus = $_.InterfaceType; Sante = '' } }) }
Add-Check -Rubrique 'comp' -Titre 'Disques' -Statut 'INFO' -Resume (($disks | ForEach-Object { "$($_.Modele) $($_.Taille_Go) Go" }) -join ' · ') -Table (To-Table $disks) -Cible $h

Show-Etape 'Batterie, écrans et réseau'
$portable = $false; foreach ($c in @($enc.ChassisTypes)) { if (@(8, 9, 10, 11, 12, 14, 18, 21, 30, 31, 32) -contains [int]$c) { $portable = $true } }
$bat = Get-CimInstance Win32_Battery | Select-Object -First 1
if ($bat) {
  $ds = Get-CimInstance -Namespace root\wmi -ClassName BatteryStaticData | Select-Object -First 1
  $fc = (Get-CimInstance -Namespace root\wmi -ClassName BatteryFullChargedCapacity | Select-Object -First 1).FullChargedCapacity
  $dc = $ds.DesignedCapacity; $us = if ($dc -and $fc -and [double]$dc -gt 0) { [math]::Round((1 - [double]$fc / [double]$dc) * 100) } else { $null }
  $bo = [pscustomobject]@{ Batterie = Clean $bat.Name; Fabricant = Clean $ds.ManufactureName; NumeroSerie = Clean $ds.SerialNumber; Capacite_origine_mWh = $dc; Capacite_actuelle_mWh = $fc; Usure_Pct = $us; Charge_Pct = $bat.EstimatedChargeRemaining }
  Add-Check -Rubrique 'perif' -Titre 'Batterie' -Statut $(if ($null -ne $us -and $us -ge 40) { 'ATT' } else { 'INFO' }) -Resume $(if ($null -ne $us) { "Usure estimée $us %" } else { 'Capacité non lue (relancer en administrateur)' }) -Table (To-Table @($bo)) -Cible $h `
    -Reco $(if ($null -ne $us -and $us -ge 40) { 'Usure importante : à signaler dans la demande de garantie si le poste est couvert.' })
} else { Add-Check -Rubrique 'perif' -Titre 'Batterie' -Statut 'INFO' -Resume $(if ($portable) { 'Portable, mais batterie non détectée (absente, retirée ou non exposée)' } else { 'Poste fixe : pas de batterie' }) -Cible $h }
$mons = @(Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID | ForEach-Object { [pscustomobject]@{ Fabricant = Edid $_.ManufacturerName; Modele = Edid $_.UserFriendlyName; NumeroSerie = Edid $_.SerialNumberID; Annee = $_.YearOfManufacture } })
Add-Check -Rubrique 'perif' -Titre 'Écrans' -Statut 'INFO' -Resume "$($mons.Count) écran(s) détecté(s)" -Table (To-Table $mons) -Cible $h
$net = @(Get-CimInstance Win32_NetworkAdapter -Filter 'PhysicalAdapter=true' | Where-Object { $_.MACAddress } | ForEach-Object { [pscustomobject]@{ Adaptateur = Clean $_.Name; MAC = $_.MACAddress } })
Add-Check -Rubrique 'perif' -Titre 'Adresses MAC' -Statut 'INFO' -Resume "$($net.Count) carte(s) physique(s)" -Table (To-Table $net) -Cible $h

# --- Fiche texte (presse-papiers + fichier)
$t = @('===== FICHE GARANTIE =====', "Date          : $($script:Debut.ToString('dd/MM/yyyy HH:mm'))", "Machine       : $h", "Utilisateur   : $user", "Fabricant     : $fab", "Modèle        : $mod", "N° de série   : $serie")
if ($express) { $t += "Code express  : $express" }
if ($id.SKU) { $t += "SKU           : $($id.SKU)" }
$t += "BIOS          : $(Clean $bios.SMBIOSBIOSVersion) ($(if ($bd) { ([datetime]$bd).ToString('dd/MM/yyyy') }))"
$t += "Processeur    : $(Clean $cpu.Name)"; $t += "Mémoire       : $ramTot Go"; $t += 'Disques       :'
foreach ($d in $disks) { $t += "  - $($d.Modele) | $($d.Taille_Go) Go | SN $($d.NumeroSerie)" }
$t += "OS            : $(Clean $os.Caption) $(Clean $os.OSArchitecture)"
$fiche = $t -join "`r`n"
$txt = Join-Path (Get-DossierRapports) ("Garantie_{0}_{1:yyyyMMdd_HHmm}.txt" -f $h, $script:Debut)
[IO.File]::WriteAllText($txt, $fiche, (New-Object Text.UTF8Encoding $true))
$clip = $false; try { Set-Clipboard -Value $fiche -ErrorAction Stop; $clip = $true } catch { }
Add-Check -Rubrique 'id' -Titre 'Fiche à joindre à la demande de garantie' -Statut 'INFO' -Resume "$(if ($clip) { 'Copiée dans le presse-papiers · ' })enregistrée dans $txt" -Brut $fiche -Cible $h `
  -Cmds @([ordered]@{ t = 'copy'; l = 'Copier la fiche'; c = $fiche; h = 'Coller dans le formulaire ou l''e-mail de demande de garantie.' })
Write-Host ''; Write-Host "  N° de série : $serie$(if ($express) { "   ·   code express : $express" })" -ForegroundColor Yellow

Save-Audit ("Fiche-Garantie_{0}_{1:yyyyMMdd_HHmm}.html" -f $h, $script:Debut) 'Fiche garantie PC' '' $Rubriques $Prerequis
