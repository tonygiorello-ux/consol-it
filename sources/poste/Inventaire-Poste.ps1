<#
  Inventaire-Poste.ps1  (v2)
  Photographie complète de l'environnement utilisateur AVANT migration de poste.

  A LANCER SUR L'ANCIEN PC, DANS LA SESSION DE L'UTILISATEUR, PowerShell NON élevé
  (sinon HKCU et les chemins pointent sur le compte admin).

  Ne jamais écrire la sortie sur le Bureau : ça ajoute une icône et casse la disposition.
  Sans -Destination, le script estime le volume à copier, liste les supports (clé / disque USB,
  disques locaux, lecteurs réseau) avec leur espace libre et demande où créer le dossier Migration.

  Produit, dans <Destination>\<PC>_<utilisateur>_<date> :
    - inventaire.json            : toutes les données (lu par Restaure-Poste.ps1)
    - fichiers_manifeste.csv     : liste de chaque fichier du profil (comparaison après copie)
    - Rapport_Inventaire.html    : récapitulatif lisible, à montrer à l'utilisateur
    - capture_bureau.png, exports registre, copies (fond, signatures, favoris...)

  Usage :
    powershell -ExecutionPolicy Bypass -File .\Inventaire-Poste.ps1                          (choix interactif du support)
    powershell -ExecutionPolicy Bypass -File .\Inventaire-Poste.ps1 -Destination E:\Migration (sans question)
#>
param(
  [string]$Destination,  # vide = choix interactif du support (clé USB, disque externe, C:, réseau)
  [switch]$SansLanceur   # ne pas installer le lanceur (boutons « ▶ » de la page Préparation)
)

$ErrorActionPreference = 'Continue'

# --- DPI aware AVANT tout appel Forms : captures et résolutions en pixels physiques
if (-not ('DpiFix' -as [type])) {
Add-Type @'
using System; using System.Runtime.InteropServices;
public class DpiFix { [DllImport("user32.dll")] public static extern bool SetProcessDPIAware(); }
'@
}
[DpiFix]::SetProcessDPIAware() | Out-Null
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

# ============================================================== Choix du support de destination
function Format-Taille($b) { $b = [double]$b; if ($b -ge 1TB) { '{0:N2} To' -f ($b / 1TB) } elseif ($b -ge 1GB) { '{0:N1} Go' -f ($b / 1GB) } else { '{0:N0} Mo' -f ($b / 1MB) } }
function Measure-DossierRapide([string]$dir) {
  # Taille et plus gros fichier, sans les fichiers OneDrive « en ligne uniquement » ; tolérant aux accès refusés
  $tot = [int64]0; $max = [int64]0; $nb = 0
  $pile = New-Object System.Collections.Generic.Stack[string]; $pile.Push($dir)
  while ($pile.Count) {
    $d = $pile.Pop()
    try {
      foreach ($f in [IO.Directory]::EnumerateFiles($d)) {
        try { $fi = New-Object IO.FileInfo $f; if ([int64]$fi.Attributes -band 0x441000) { continue }; $tot += $fi.Length; $nb++; if ($fi.Length -gt $max) { $max = $fi.Length } } catch { }
      }
    } catch { }
    try { foreach ($sd in [IO.Directory]::EnumerateDirectories($d)) { try { if (-not ([IO.File]::GetAttributes($sd) -band [IO.FileAttributes]::ReparsePoint)) { $pile.Push($sd) } } catch { } } } catch { }
  }
  [pscustomobject]@{ Octets = $tot; Max = $max; Fichiers = $nb }
}
function Get-EstimationCopie {
  $usf = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
  $dl = ''; try { $dl = [Environment]::ExpandEnvironmentVariables([string](Get-ItemProperty $usf -ErrorAction Stop).'{374DE290-123F-4565-9164-39C4925E467B}') } catch { }
  if (-not $dl) { $dl = Join-Path $env:USERPROFILE 'Downloads' }
  $od = @($env:OneDrive, $env:OneDriveCommercial, $env:OneDriveConsumer) | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') + '\' }
  $tot = [int64]0; $max = [int64]0; $noms = @()
  $kf = [ordered]@{ Bureau = [Environment]::GetFolderPath('Desktop'); Documents = [Environment]::GetFolderPath('MyDocuments'); Images = [Environment]::GetFolderPath('MyPictures')
                    Musique = [Environment]::GetFolderPath('MyMusic'); Vidéos = [Environment]::GetFolderPath('MyVideos'); Téléchargements = $dl }
  $vus = @()
  foreach ($k in $kf.Keys) {
    $p = [string]$kf[$k]
    if (-not $p -or $p.StartsWith('\\') -or -not (Test-Path -LiteralPath $p)) { continue }
    $pp = $p.TrimEnd('\') + '\'
    if (@($od | Where-Object { $pp.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) }).Count) { continue }   # synchronisé : reviendra par OneDrive
    if ($vus -contains $pp) { continue }; $vus += $pp
    $m = Measure-DossierRapide $p
    $tot += $m.Octets; if ($m.Max -gt $max) { $max = $m.Max }; if ($m.Fichiers) { $noms += $k }
  }
  [pscustomobject]@{ Octets = $tot; Max = $max; Dossiers = $noms }
}
function Get-Supports {
  $l = @()
  foreach ($d in @(Get-CimInstance Win32_LogicalDisk -ErrorAction SilentlyContinue | Where-Object { @(2, 3, 4) -contains [int]$_.DriveType -and $_.Size })) {
    $usb = [int]$d.DriveType -eq 2
    if (-not $usb -and [int]$d.DriveType -eq 3) {
      try { if ([string](Get-Partition -DriveLetter $d.DeviceID.TrimEnd(':') -ErrorAction Stop | Get-Disk -ErrorAction Stop).BusType -eq 'USB') { $usb = $true } } catch { }
    }
    $type = if ([int]$d.DriveType -eq 4) { 'Réseau' } elseif ($usb) { 'USB' } elseif ($d.DeviceID -ieq $env:SystemDrive) { 'Système' } else { 'Disque local' }
    $l += [pscustomobject]@{ Lettre = $d.DeviceID; Nom = [string]$d.VolumeName; Type = $type; FS = [string]$d.FileSystem; Libre = [int64]$d.FreeSpace; Total = [int64]$d.Size }
  }
  $l
}
function Test-Support([string]$chemin, $est) {
  # Crée le dossier, vérifie l'écriture, l'espace et le système de fichiers ; $true si on peut continuer
  try { New-Item -ItemType Directory -Path $chemin -Force -ErrorAction Stop | Out-Null; $t = Join-Path $chemin ('_test_ecriture_' + [guid]::NewGuid().ToString('N') + '.tmp'); [IO.File]::WriteAllText($t, 'ok'); Remove-Item -LiteralPath $t -Force }
  catch { Write-Host "  Impossible d'écrire dans $chemin : $($_.Exception.Message)" -ForegroundColor Red; return $false }
  $racine = [IO.Path]::GetPathRoot((Resolve-Path -LiteralPath $chemin).Path)
  $besoin = [int64]($est.Octets * 1.05) + 300MB
  try {
    $di = New-Object IO.DriveInfo $racine
    if ($di.AvailableFreeSpace -lt $besoin) {
      Write-Host ("  Espace insuffisant sur {0} : {1} libres pour environ {2} à copier." -f $racine, (Format-Taille $di.AvailableFreeSpace), (Format-Taille $besoin)) -ForegroundColor Red
      if ((Read-Host '  Utiliser ce support quand même ? (o/N)') -notmatch '^[oOyY]') { return $false }
    }
    if ($di.DriveFormat -match '^FAT' -and $est.Max -ge 4GB) {
      Write-Host ("  {0} est en {1} : un fichier de plus de 4 Go ne peut pas y être copié (plus gros fichier trouvé : {2}, souvent un PST)." -f $racine, $di.DriveFormat, (Format-Taille $est.Max)) -ForegroundColor Red
      Write-Host '  Reformater le support en exFAT ou NTFS, ou en choisir un autre.' -ForegroundColor Yellow
      if ((Read-Host '  Utiliser ce support quand même ? (o/N)') -notmatch '^[oOyY]') { return $false }
    }
  } catch { Write-Host "  Espace libre non vérifiable sur $racine (partage réseau ?)." -ForegroundColor Yellow }
  $true
}
function Select-Destination {
  Write-Host ''
  Write-Host '==== Où créer le dossier de migration ? ====' -ForegroundColor Cyan
  Write-Host '  Estimation du volume des données à copier (quelques secondes à quelques minutes)...' -ForegroundColor Gray
  $est = Get-EstimationCopie
  Write-Host ("  Données locales à copier : environ {0}{1}{2}" -f (Format-Taille $est.Octets),
    $(if ($est.Dossiers.Count) { ' (' + ($est.Dossiers -join ', ') + ')' } else { '' }),
    $(if ($est.Max -ge 1GB) { ' · plus gros fichier : ' + (Format-Taille $est.Max) } else { '' }))
  Write-Host '  (hors dossiers synchronisés par OneDrive, qui reviennent seuls ; PST rangés ailleurs en plus)' -ForegroundColor DarkGray
  $besoin = [int64]($est.Octets * 1.05) + 300MB
  $sup = @(Get-Supports)
  $defaut = $null
  $i = 0
  Write-Host ''
  foreach ($s in $sup) {
    $i++
    $assez = $s.Libre -ge $besoin
    $fatKo = $s.FS -match '^FAT' -and $est.Max -ge 4GB
    $note = if (-not $assez) { 'espace insuffisant' } elseif ($fatKo) { "$($s.FS) : fichier > 4 Go impossible" } else { 'OK' }
    if (-not $defaut -and $assez -and -not $fatKo -and $s.Type -eq 'USB') { $defaut = $i }
    $col = if ($note -ne 'OK') { 'DarkYellow' } elseif ($s.Type -eq 'USB') { 'Green' } else { 'Gray' }
    Write-Host ("  [{0}] {1,-3} {2,-13} {3,-22} {4,-6} libre {5,9} / {6,9}   {7}" -f $i, $s.Lettre, $s.Type, $(if ($s.Nom.Length -gt 22) { $s.Nom.Substring(0, 21) + '…' } else { $s.Nom }), $s.FS, (Format-Taille $s.Libre), (Format-Taille $s.Total), $note) -ForegroundColor $col
  }
  if (-not $defaut) { $i = 0; foreach ($s in $sup) { $i++; if (-not $defaut -and $s.Libre -ge $besoin -and $s.Type -ne 'Réseau' -and -not ($s.FS -match '^FAT' -and $est.Max -ge 4GB)) { $defaut = $i } } }
  if (-not $sup.Count) { Write-Host '  Aucun support détecté.' -ForegroundColor Yellow }
  Write-Host ''
  Write-Host '  Brancher la clé ou le disque USB avant de répondre (taper R pour actualiser la liste).' -ForegroundColor DarkGray
  while ($true) {
    $q = '  Numéro du support, ou chemin complet (ex. E:\Migration, \\serveur\partage\Migration)'
    if ($defaut) { $q += " [Entrée = $defaut : $($sup[$defaut - 1].Lettre)]" }
    $r = ([string](Read-Host $q)).Trim().Trim('"')
    if ($r -match '^[rR]$') { return (Select-Destination) }
    if (-not $r -and $defaut) { $r = [string]$defaut }
    if (-not $r) { continue }
    if ($r -match '^\d+$' -and [int]$r -ge 1 -and [int]$r -le $sup.Count) { $chemin = $sup[[int]$r - 1].Lettre + '\Migration' }
    elseif ($r -match '^[a-zA-Z]:\\?$') { $chemin = $r.Substring(0, 2).ToUpper() + '\Migration' }
    else { $chemin = $r }
    $bureau = [Environment]::GetFolderPath('Desktop')
    if ($bureau -and [IO.Path]::GetFullPath($chemin).StartsWith($bureau, [StringComparison]::OrdinalIgnoreCase)) {
      Write-Host '  Pas sur le Bureau : le dossier ajouterait une icône et fausserait la disposition relevée.' -ForegroundColor Yellow; continue
    }
    if (Test-Support $chemin $est) { Write-Host "  Dossier de migration : $chemin" -ForegroundColor Green; return $chemin }
  }
}
if (-not $Destination) { $Destination = Select-Destination }

$debut = Get-Date
$root  = Join-Path $Destination ("{0}_{1}_{2:yyyyMMdd_HHmm}" -f $env:COMPUTERNAME, $env:USERNAME, $debut)
New-Item -ItemType Directory -Path $root -Force | Out-Null
$root = (Resolve-Path -LiteralPath $root).Path   # chemin absolu : le script de copie généré doit fonctionner depuis n'importe où
New-Item -ItemType Directory -Path (Join-Path $root 'registre') -Force | Out-Null
$log = Join-Path $root '_journal.txt'
$script:alertes = New-Object System.Collections.Generic.List[string]

# ============================================================== Fonctions utilitaires
function Log($m)       { $l = "[{0:HH:mm:ss}] {1}" -f (Get-Date), $m; Write-Host $l; $l | Out-File $log -Append -Encoding UTF8 }
function Alerte($m)    { $script:alertes.Add($m); Log "ATTENTION : $m" }
function New-Sub($n)   { $p = Join-Path $root $n; New-Item -ItemType Directory -Path $p -Force | Out-Null; $p }
function RegExp($k,$f) { reg export $k (Join-Path $root "registre\$f.reg") /y 2>$null | Out-Null; if ($LASTEXITCODE -eq 0) { Log "Registre exporté : $k" } }
function CopySafe($s,$d) {
  if ($s -and (Test-Path $s)) {
    try { Copy-Item $s $d -Recurse -Force -ErrorAction SilentlyContinue } catch { Log "Copie partielle de $s : $($_.Exception.Message)" }
    Log "Copié : $s"; return $true
  }
  Log "Absent : $s"; return $false
}
function RegVal($path, $name) { try { (Get-ItemProperty -Path $path -Name $name -ErrorAction Stop).$name } catch { $null } }
function AccentHex($v) {
  if ($null -eq $v) { return $null }
  $u = [int64]$v -band 4294967295   # DWORD lu en signé ou non signé selon la version : on garde les 32 bits
  $h = '{0:X8}' -f $u
  '#' + $h.Substring(6,2) + $h.Substring(4,2) + $h.Substring(2,2)
}
function Dec($v) { if ($v -is [byte[]]) { [Text.Encoding]::Unicode.GetString($v).TrimEnd([char]0) } else { [string]$v } }

function Capture-Bureau($path) {
  try {
    $sh = New-Object -ComObject Shell.Application
    $sh.MinimizeAll(); Start-Sleep -Seconds 2
    $vs  = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $bmp = New-Object System.Drawing.Bitmap $vs.Width, $vs.Height
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($vs.Left, $vs.Top, 0, 0, $bmp.Size)
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose(); $sh.UndoMinimizeAll()
    Log "Capture du bureau OK ($($vs.Width)x$($vs.Height))"; return $true
  } catch { Log "Capture échouée : $_"; return $false }
}

$script:sysIconNames = [ordered]@{
  '{20D04FE0-3AEA-1069-A2D8-08002B30309D}' = 'Ce PC'
  '{645FF040-5081-101B-9F08-00AA002F954E}' = 'Corbeille'
  '{59031a47-3f72-44a7-89c5-5595fe6b30ee}' = 'Dossier utilisateur'
  '{F02C1A0D-BE21-4350-88B0-7367FC96EF3C}' = 'Réseau'
  '{5399E694-6CE5-4D6C-8FCE-1D8870FDCBA0}' = 'Panneau de configuration'
}
function Get-SysIcons {
  $k = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel'
  $r = [ordered]@{}
  foreach ($g in $script:sysIconNames.Keys) {
    $v = RegVal $k $g
    if ($null -eq $v) { $shown = ($script:sysIconNames[$g] -eq 'Corbeille') } else { $shown = ($v -eq 0) }
    $r[$script:sysIconNames[$g]] = $shown
  }
  $r
}

function Count-Urls($n) {
  if ($null -eq $n) { return 0 }
  $c = 0
  if ($n.type -eq 'url') { $c++ }
  if ($n.children) { foreach ($ch in $n.children) { $c += (Count-Urls $ch) } }
  $c
}
function Get-BookmarkCount($file) {
  if (-not (Test-Path $file)) { return 0 }
  try {
    $j = Get-Content $file -Raw -Encoding UTF8 | ConvertFrom-Json
    $t = 0
    foreach ($r in $j.roots.PSObject.Properties) { if ($r.Value -is [psobject]) { $t += (Count-Urls $r.Value) } }
    $t
  } catch { -1 }
}
function Get-ExtName($extDir) {
  $v = Get-ChildItem $extDir -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
  if (-not $v) { return $null }
  try { $j = Get-Content (Join-Path $v.FullName 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
  $n = [string]$j.name
  if ($n -match '^__MSG_(.+)__$') {
    $key = $Matches[1]
    foreach ($loc in @('fr', [string]$j.default_locale, 'en', 'en_US')) {
      if (-not $loc) { continue }
      $mm = Join-Path $v.FullName "_locales\$loc\messages.json"
      if (Test-Path $mm) {
        try {
          $msgs = Get-Content $mm -Raw -Encoding UTF8 | ConvertFrom-Json
          $p = $msgs.PSObject.Properties | Where-Object { $_.Name -ieq $key } | Select-Object -First 1
          if ($p) { return [string]$p.Value.message }
        } catch { }
      }
    }
  }
  $n
}
function Get-OutlookDefaultSig {
  $out = @()
  Get-ChildItem 'HKCU:\Software\Microsoft\Office\16.0\Outlook\Profiles' -ErrorAction SilentlyContinue | ForEach-Object {
    $prof = $_.PSChildName
    Get-ChildItem (Join-Path $_.PSPath '9375CFF0413111d3B88A00104B2A6676') -ErrorAction SilentlyContinue | ForEach-Object {
      $p = Get-ItemProperty $_.PSPath
      $acct = Dec $p.'Account Name'
      $new  = Dec $p.'New Signature'
      $rep  = Dec $p.'Reply-Forward Signature'
      if ($acct -and ($new -or $rep)) { $out += [ordered]@{ Profil = $prof; Compte = $acct; Nouveau = $new; Reponse = $rep } }
    }
  }
  $out
}
function Get-WifiNames {
  @(netsh wlan show profiles 2>$null | ForEach-Object { if ($_ -match '^\s+\S.*?\s:\s(.+)$') { $Matches[1].Trim() } })
}
function Get-CredTargets {
  $auto = 'MicrosoftOffice|virtualapp/didlogical|OneDrive Cached|msteams|MicrosoftAccount|WindowsLive|SSO_POP|XboxLive|AzureAD|Microsoft_OC|OneAuth|MSIX'
  @(cmdkey /list 2>$null | ForEach-Object { if ($_ -match '^\s*(Target|Cible)\s*:\s*(.+?)\s*$') { $Matches[2] } } | Where-Object { $_ -notmatch $auto })
}
$script:virtualPrinters = 'Microsoft Print to PDF','Microsoft XPS Document Writer','Fax','OneNote*','Send To OneNote*','Adobe PDF','PDF24*','Microsoft Office Document Image Writer*'
function Is-Virtual($n) { [bool]($script:virtualPrinters | Where-Object { $n -like $_ }) }
function Get-Apps {
  $keys = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
          'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
          'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
  Get-ItemProperty $keys -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -and -not $_.SystemComponent -and -not $_.ParentKeyName } |
    Sort-Object DisplayName -Unique |
    ForEach-Object { [ordered]@{ Nom = [string]$_.DisplayName; Version = [string]$_.DisplayVersion; Editeur = [string]$_.Publisher } }
}
function Get-KnownFolders {
  $usf = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
  $dl  = RegVal $usf '{374DE290-123F-4565-9164-39C4925E467B}'
  if ($dl) { $dl = [Environment]::ExpandEnvironmentVariables($dl) } else { $dl = Join-Path $env:USERPROFILE 'Downloads' }
  [ordered]@{
    'Bureau'          = [Environment]::GetFolderPath('Desktop')
    'Documents'       = [Environment]::GetFolderPath('MyDocuments')
    'Images'          = [Environment]::GetFolderPath('MyPictures')
    'Musique'         = [Environment]::GetFolderPath('MyMusic')
    'Videos'          = [Environment]::GetFolderPath('MyVideos')
    'Telechargements' = $dl
  }
}
# Comptes OneDrive + tous les dossiers synchronisés (racine OneDrive, bibliothèques SharePoint/Teams, raccourcis)
function Get-OneDriveMounts {
  $out = @()
  $urls = @{}
  Get-ChildItem 'HKCU:\Software\SyncEngines\Providers\OneDrive' -ErrorAction SilentlyContinue | ForEach-Object {
    $pp = Get-ItemProperty $_.PSPath
    if ($pp.MountPoint -and $pp.UrlNamespace) { $urls[([string]$pp.MountPoint).TrimEnd('\')] = [string]$pp.UrlNamespace }
  }
  Get-ChildItem 'HKCU:\Software\Microsoft\OneDrive\Accounts' -ErrorAction SilentlyContinue | ForEach-Object {
    $accKey = $_.PSPath
    $acc = Get-ItemProperty $accKey
    $email = [string]$acc.UserEmail
    if (-not $email) { return }
    $root = [string]$acc.UserFolder
    $paths = New-Object System.Collections.Generic.List[string]
    if ($root) { $paths.Add($root) }
    $cache = Join-Path $accKey 'ScopeIdToMountPointPathCache'
    if (Test-Path $cache) {
      $cp = Get-ItemProperty $cache
      foreach ($n in (Get-Item $cache).Property) { if ($cp.$n) { $paths.Add([string]$cp.$n) } }
    }
    Get-ChildItem (Join-Path $accKey 'Tenants') -ErrorAction SilentlyContinue | ForEach-Object {
      foreach ($n in $_.Property) { if ($n -like '?:\*') { $paths.Add($n) } }
    }
    $seen = @{}
    foreach ($p in $paths) {
      $k = $p.TrimEnd('\')
      if (-not $k -or $seen.ContainsKey($k)) { continue }
      $seen[$k] = 1
      $isRoot = $root -and ($k -ieq $root.TrimEnd('\'))
      $leaf = Split-Path $k -Leaf
      $out += [pscustomobject]@{
        Compte = $email
        Type   = $(if ($isRoot) { 'OneDrive' } else { 'Bibliotheque' })
        Nom    = $leaf
        Chemin = $k
        Cle    = $(if ($isRoot) { "OneDrive|$email" } else { "Biblio|$leaf" })
        Url    = [string]$urls[$k]
      }
    }
  }
  $out
}
# Parcours récursif tolérant aux erreurs : un dossier illisible n'interrompt pas le parcours,
# les jonctions et liens symboliques (« Application Data », « Mes documents »...) sont ignorés,
# les dossiers OneDrive (points d'analyse de type « cloud ») sont bien parcourus.
function Get-FilesSafe([string]$Path, [string]$Filter = '*') {
  if (-not $Path -or -not [IO.Directory]::Exists($Path)) { return }
  $stack = New-Object System.Collections.Generic.Stack[string]
  $stack.Push($Path)
  while ($stack.Count -gt 0) {
    $di = New-Object IO.DirectoryInfo ($stack.Pop())
    try { $di.GetFiles($Filter) } catch { }
    $subs = @(); try { $subs = $di.GetDirectories() } catch { }
    foreach ($sd in $subs) {
      if ($sd.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        $lt = $null
        try { $lt = (Get-Item -LiteralPath $sd.FullName -Force -ErrorAction Stop).LinkType } catch { continue }
        if ($lt) { continue }
      }
      $stack.Push($sd.FullName)
    }
  }
}
function Is-Excluded($full, $excl) {
  foreach ($e in $excl) { if ($full.StartsWith($e, [StringComparison]::OrdinalIgnoreCase)) { return $true } }
  return $false
}

# --- Actions proposées dans le rapport (mêmes types que Restaure-Poste.ps1)
function Q($s) { "'" + ([string]$s -replace "'", "''") + "'" }
function AOpen($l, $u) { [ordered]@{ t = 'open'; l = $l; u = $u } }
function AWeb($l, $u)  { [ordered]@{ t = 'web';  l = $l; u = $u } }
function ANav($l, $u)  { [ordered]@{ t = 'nav';  l = $l; u = $u } }
function ACopy($l, $txt, $hint) { [ordered]@{ t = 'copy'; l = $l; c = $txt; h = $hint } }
function ACmd($l, $c, $adm = $false, $auto = $false) { [ordered]@{ t = 'cmd'; l = $l; c = $c; adm = [bool]$adm; auto = [bool]$auto } }
$script:LanceurDir = Join-Path $env:LOCALAPPDATA 'MigrationPoste'
$script:LanceurKey = 'HKCU:\Software\Classes\migfix'

# ============================================================== Lanceur de corrections (liens migfix: du rapport)
# Le lien ne contient qu'un identifiant : les commandes sont lues dans actions.json (écrit par ce script).
# Le lanceur refuse tout lien inconnu, un rapport périmé, et se retire seul après 14 jours.
$script:LanceurPs1 = @'
param([string]$Url)
Add-Type -AssemblyName System.Windows.Forms
$titre = 'Migration du poste'
function Msg($t, $i = 'Information') { [void][System.Windows.Forms.MessageBox]::Show($t, $titre, 'OK', $i) }
function Q($s) { "'" + ([string]$s -replace "'", "''") + "'" }
$dir = Split-Path -Parent $PSCommandPath
$m = [regex]::Match([string]$Url, '^migfix:(?://)?(\d{8}_\d{4})/([a-z0-9]{1,12})/?$')
if (-not $m.Success) { Msg "Lien de correction non reconnu." 'Warning'; exit }
$f = Join-Path $dir 'actions.json'
if (-not (Test-Path $f)) { Msg "Aucune correction disponible : relancez le contrôle." 'Warning'; exit }
$d = Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json
if ((Get-Date).ToString('yyyyMMddHHmm') -gt [string]$d.expire) {   # format texte : jamais converti en date par ConvertFrom-Json
  Remove-Item 'HKCU:\Software\Classes\migfix' -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
  Msg "Le lanceur de corrections a expiré et a été retiré." 'Warning'; exit
}
if ([string]$d.stamp -ne $m.Groups[1].Value) { Msg "Ce rapport n'est plus le dernier : ouvrez le rapport du contrôle du $($d.date)." 'Warning'; exit }
$a = @($d.actions) | Where-Object { $_.id -eq $m.Groups[2].Value } | Select-Object -First 1
if (-not $a) { Msg "Correction introuvable dans le dernier rapport." 'Warning'; exit }
$cmdTxt = if ($a.cmd.Length -gt 1200) { $a.cmd.Substring(0, 1200) + ' […]' } else { $a.cmd }
$txt = "$($a.label)`n`n" + $(if ($a.adm) { "Droits administrateur nécessaires : le contrôle de compte d'utilisateur va s'ouvrir.`n`n" } else { '' }) + "Commande exécutée :`n$cmdTxt"
if ([System.Windows.Forms.MessageBox]::Show($txt, "$titre — appliquer ?", 'OKCancel', 'Question') -ne 'OK') { exit }
$run = "`$Host.UI.RawUI.WindowTitle = 'Migration du poste — correction'`r`nWrite-Host $(Q $a.label) -ForegroundColor Cyan`r`nWrite-Host ''`r`n" +
       "try {`r`n$($a.cmd)`r`nWrite-Host ''; Write-Host 'Terminé.' -ForegroundColor Green`r`n} catch { Write-Host ('Erreur : ' + `$_.Exception.Message) -ForegroundColor Red }`r`n" +
       "Write-Host ''; Write-Host 'Pour mettre à jour le rapport : bouton « Relancer le contrôle ». Vous pouvez fermer cette fenêtre.'"
$rf = Join-Path $dir ("run_" + $a.id + ".ps1")
[IO.File]::WriteAllText($rf, $run, (New-Object System.Text.UTF8Encoding $true))
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$arg = "-NoProfile -NoExit -ExecutionPolicy Bypass -Command `"& ([scriptblock]::Create([IO.File]::ReadAllText($(Q $rf))))`""
if ($a.adm) { Start-Process $ps -Verb RunAs -ArgumentList $arg } else { Start-Process $ps -ArgumentList $arg }
'@
function Install-Lanceur($stamp, $actions) {
  try {
    New-Item -ItemType Directory -Path $script:LanceurDir -Force | Out-Null
    $utf8 = New-Object System.Text.UTF8Encoding $true
    [IO.File]::WriteAllText((Join-Path $script:LanceurDir 'lanceur.ps1'), $script:LanceurPs1, $utf8)
    $data = [ordered]@{ stamp = $stamp; date = (Get-Date).ToString('dd/MM/yyyy HH:mm'); expire = (Get-Date).AddDays(14).ToString('yyyyMMddHHmm'); actions = @($actions) }
    [IO.File]::WriteAllText((Join-Path $script:LanceurDir 'actions.json'), ($data | ConvertTo-Json -Depth 5), $utf8)
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    New-Item -Path "$($script:LanceurKey)\shell\open\command" -Force | Out-Null
    Set-Item -Path $script:LanceurKey -Value 'URL:Corrections de migration du poste'
    New-ItemProperty -Path $script:LanceurKey -Name 'URL Protocol' -Value '' -PropertyType String -Force | Out-Null
    Set-Item -Path "$($script:LanceurKey)\shell\open\command" -Value "`"$ps`" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$(Join-Path $script:LanceurDir 'lanceur.ps1')`" `"%1`""
    Log "Lanceur de corrections installé ($(@($actions).Count) action(s), valable 14 jours)"
    return $true
  } catch { Log "Lanceur de corrections non installé : $($_.Exception.Message)"; return $false }
}

# ============================================================== Modèle du script Copie-Donnees.ps1 (personnalisé à la fin de l'inventaire)
$script:CopieTpl = @'
<#
  Copie-Donnees.ps1 — généré par Inventaire-Poste.ps1 le __DATE__ pour __USER__

  Copie les données LOCALES de l'utilisateur dans le dossier de migration (sous-dossier Donnees),
  puis vérifie la copie fichier par fichier à partir du manifeste de l'inventaire.
  Les dossiers synchronisés par OneDrive ne sont pas copiés : ils reviendront par OneDrive.

  A lancer sur l'ANCIEN poste, dans la session de l'utilisateur, après l'inventaire.
  Restaure-Poste.ps1 recopiera ensuite ces données à leur place sur le nouveau poste.
#>
$ErrorActionPreference = 'Continue'
$Racine = __RACINE__
if ($PSScriptRoot -and (Test-Path (Join-Path $PSScriptRoot 'inventaire.json'))) { $Racine = $PSScriptRoot }
$Dest = Join-Path $Racine 'Donnees'
$Log  = Join-Path $Dest 'robocopy_copie.log'

# Plan de copie établi par l'inventaire
$Dossiers = @(
__DOSSIERS__
)
$Pst = @(
__PST__
)
$Hors = @(
__HORS__
)

try { $Host.UI.RawUI.WindowTitle = 'Migration du poste — copie des données' } catch { }
New-Item -ItemType Directory -Path $Dest -Force | Out-Null
Remove-Item (Join-Path $Dest '_copie_manquants.csv') -Force -ErrorAction SilentlyContinue
Write-Host "Copie des données de $env:USERNAME vers $Dest" -ForegroundColor Cyan
Write-Host ("{0} dossier(s), {1} fichier(s) PST, {2} dossier(s) hors profil" -f $Dossiers.Count, $Pst.Count, $Hors.Count)

# 1. Outlook doit être fermé pour copier les PST
if ($Pst.Count -and (Get-Process OUTLOOK -ErrorAction SilentlyContinue)) {
  Write-Host "Outlook est ouvert : fermeture demandée (un PST ouvert ne peut pas être copié)..." -ForegroundColor Yellow
  Get-Process OUTLOOK -ErrorAction SilentlyContinue | ForEach-Object { [void]$_.CloseMainWindow() }
  $t = 0; while ((Get-Process OUTLOOK -ErrorAction SilentlyContinue) -and $t -lt 30) { Start-Sleep -Seconds 1; $t++ }
  if (Get-Process OUTLOOK -ErrorAction SilentlyContinue) { Read-Host "Fermez Outlook puis appuyez sur Entrée" | Out-Null }
}

# 2. Espace disponible sur le support de destination
$need = [int64]0
foreach ($d in $Dossiers) { $need += [int64]$d.Octets }
foreach ($p in $Pst) { $need += [int64]$p.Octets }
try {
  $free = (New-Object System.IO.DriveInfo ([IO.Path]::GetPathRoot($Dest))).AvailableFreeSpace
  Write-Host ("Volume à copier : {0:N1} Go (hors dossiers hors profil) — espace libre : {1:N1} Go" -f ($need / 1GB), ($free / 1GB))
  if ($free -lt [int64]($need * 1.05)) {
    Write-Host "Espace insuffisant sur le support de destination." -ForegroundColor Red
    if ((Read-Host "Continuer quand même ? (o/N)") -notmatch '^[oOyY]') { return }
  }
} catch { Write-Host "Espace libre non vérifiable (partage réseau ?)." -ForegroundColor Yellow }

function Copy-Rc($src, $dst, $label, $file) {
  Write-Host ''; Write-Host "-> $label" -ForegroundColor Cyan
  if (-not (Test-Path -LiteralPath $src)) { Write-Host "   Source introuvable : $src" -ForegroundColor Red; return 16 }
  New-Item -ItemType Directory -Path $dst -Force | Out-Null
  if ($file) { $a = @($src, $dst, $file, '/COPY:DAT', '/R:1', '/W:1', '/NP', '/NJH', "/LOG+:$Log", '/TEE') }
  else       { $a = @($src, $dst, '/E', '/COPY:DAT', '/XJ', '/R:1', '/W:1', '/NP', '/NDL', '/NFL', '/NJH', "/LOG+:$Log", '/TEE') }
  & robocopy @a | Out-Host
  $rc = $LASTEXITCODE
  if ($rc -ge 8) { Write-Host "   Erreurs de copie (code $rc) : voir $Log" -ForegroundColor Red } else { Write-Host "   OK" -ForegroundColor Green }
  $rc
}

# 3. Copie
$codes = @()
foreach ($d in $Dossiers) { $codes += [pscustomobject]@{ Element = $d.Libelle; Code = (Copy-Rc $d.Source (Join-Path $Dest $d.Cible) $d.Libelle $null) } }
foreach ($p in $Pst) {
  $leaf = Split-Path $p.Source -Leaf
  $codes += [pscustomobject]@{ Element = "PST $leaf"; Code = (Copy-Rc (Split-Path $p.Source -Parent) (Join-Path $Dest $p.Cible) "PST $leaf" $leaf) }
}
foreach ($h in $Hors) { $codes += [pscustomobject]@{ Element = "Hors profil $($h.Source)"; Code = (Copy-Rc $h.Source (Join-Path $Dest $h.Cible) "Hors profil $($h.Source)" $null) } }

# 4. Vérification fichier par fichier à partir du manifeste
Write-Host ''; Write-Host "Vérification de la copie..." -ForegroundColor Cyan
$man = Join-Path $Racine 'fichiers_manifeste.csv'
$verif = @(); $manquants = 0
if (Test-Path $man) {
  $byKey = @{}
  foreach ($r in (Import-Csv $man -Delimiter ';')) {
    if (-not $byKey.ContainsKey($r.Dossier)) { $byKey[$r.Dossier] = New-Object System.Collections.Generic.List[object] }
    $byKey[$r.Dossier].Add($r)
  }
  foreach ($d in $Dossiers) {
    $exp = New-Object System.Collections.Generic.List[object]
    if ($byKey.ContainsKey($d.Cle)) { $exp = $byKey[$d.Cle] }
    $base = Join-Path $Dest $d.Cible
    $miss = @($exp | Where-Object { -not (Test-Path -LiteralPath (Join-Path $base $_.Relatif)) })
    $manquants += $miss.Count
    $verif += [pscustomobject]@{ Dossier = $d.Libelle; Attendus = $exp.Count; Copies = $exp.Count - $miss.Count; Manquants = $miss.Count }
    if ($miss.Count) {
      $miss | ForEach-Object { [pscustomobject]@{ Dossier = $d.Libelle; Fichier = $_.Relatif } } |
        Export-Csv (Join-Path $Dest '_copie_manquants.csv') -Append -NoTypeInformation -Encoding UTF8 -Delimiter ';'
    }
  }
}
$pstOk = @($Pst | ForEach-Object { [pscustomobject]@{ Fichier = $_.Source; Copie = (Test-Path -LiteralPath (Join-Path (Join-Path $Dest $_.Cible) (Split-Path $_.Source -Leaf))) } })
$erreurs = @($codes | Where-Object { $_.Code -ge 8 })
$ok = ($manquants -eq 0) -and (@($pstOk | Where-Object { -not $_.Copie }).Count -eq 0) -and ($erreurs.Count -eq 0)

$resume = [ordered]@{
  date = (Get-Date).ToString('dd/MM/yyyy HH:mm'); ok = $ok
  dossiers = $verif; pst = $pstOk; codes = $codes; manquants = $manquants
}
$resume | ConvertTo-Json -Depth 4 | Out-File (Join-Path $Dest '_copie.json') -Encoding UTF8

Write-Host ''
$verif | Format-Table -AutoSize | Out-Host
if ($ok) {
  Write-Host "COPIE COMPLÈTE : tous les fichiers sont dans $Dest" -ForegroundColor Green
} else {
  Write-Host "COPIE INCOMPLÈTE : $manquants fichier(s) manquant(s), $($erreurs.Count) erreur(s) de copie." -ForegroundColor Red
  Write-Host "Détail : $(Join-Path $Dest '_copie_manquants.csv') et $Log" -ForegroundColor Red
  Write-Host "Relancer la copie après correction (les fichiers déjà copiés ne sont pas recopiés)." -ForegroundColor Yellow
}
Write-Host ''
Write-Host "Transporter ensuite le dossier complet : $Racine" -ForegroundColor Cyan
'@

# ============================================================== Rendu HTML (interface commune aux deux scripts)
# Le rapport est une page autonome : les données sont intégrées en JSON et affichées par le script JavaScript ci-dessous.
$script:UiCss = @'
:root{--bg:#f3f5f8;--panel:#fff;--ink:#16202c;--mute:#5f6b7a;--line:#e2e7ee;--soft:#f7f9fb;
--side:#0e2540;--side2:#143153;--sideInk:#c9d7e8;--accent:#1f4e8c;--accentbg:#e9f1fb;
--ok:#16784b;--okbg:#e2f4ea;--warn:#8a5100;--warnbg:#fdf0d8;--bad:#b42318;--badbg:#fde6e3;--info:#4a5565;--infobg:#edf0f4;
--r:14px;--sh:0 1px 2px rgba(16,32,48,.05),0 2px 8px rgba(16,32,48,.04)}
@media (prefers-color-scheme:dark){:root{--bg:#0d1218;--panel:#161e28;--ink:#e5ebf2;--mute:#98a4b3;--line:#263241;--soft:#1b2430;
--side:#0a1a2c;--side2:#10263f;--accent:#7fb0ef;--accentbg:#16273c;
--ok:#5fd39a;--okbg:#122b1d;--warn:#f0b45a;--warnbg:#33250d;--bad:#ff8b80;--badbg:#391613;--info:#b4bfcc;--infobg:#202a36;--sh:none}}
*{box-sizing:border-box}
html{scroll-behavior:smooth}
body{margin:0;font-family:"Segoe UI",system-ui,-apple-system,sans-serif;font-size:14.5px;line-height:1.5;background:var(--bg);color:var(--ink)}
a{color:var(--accent)}
.mute{color:var(--mute)}
.app{display:grid;grid-template-columns:272px minmax(0,1fr);min-height:100vh}

/* ---------- Barre latérale ---------- */
aside{background:linear-gradient(180deg,var(--side),var(--side2));color:var(--sideInk);position:sticky;top:0;height:100vh;overflow-y:auto;padding:22px 14px 18px;display:flex;flex-direction:column}
.brand{font-size:11.5px;letter-spacing:.12em;text-transform:uppercase;opacity:.65;padding:0 10px}
.who{padding:8px 10px 18px;border-bottom:1px solid rgba(255,255,255,.08);margin-bottom:10px}
.who b{display:block;color:#fff;font-size:16px;line-height:1.3;margin-top:4px}
.who span{display:block;font-size:12.5px;opacity:.75;margin-top:4px}
nav{display:flex;flex-direction:column;gap:2px}
nav .grp{font-size:11px;text-transform:uppercase;letter-spacing:.1em;opacity:.55;margin:16px 10px 6px}
nav a{display:flex;align-items:center;gap:10px;padding:8px 10px;border-radius:10px;color:inherit;text-decoration:none;font-size:14px;line-height:1.25}
nav a:hover{background:rgba(255,255,255,.07);color:#fff}
nav a.on{background:rgba(255,255,255,.15);color:#fff;font-weight:600}
nav .ni{width:20px;text-align:center;flex:none}
nav .nl{flex:1;min-width:0}
.dot{width:9px;height:9px;border-radius:50%;flex:none;margin:0 5px}
.dot.ok{background:#4cc98a}.dot.warn{background:#f0b45a}.dot.bad{background:#ff6b5e}.dot.info{background:#8fa0b3}
.badge{font-size:11.5px;font-weight:700;border-radius:999px;padding:1px 8px;background:rgba(255,255,255,.13);color:#fff;flex:none}
.badge.bad{background:#d63b2e}.badge.warn{background:#f0b45a;color:#2b1b00}.badge.ok{background:rgba(76,201,138,.28);color:#c9f3dc}
.side-foot{margin-top:auto;padding-top:18px;display:flex;flex-direction:column;gap:8px}
.side-foot small{font-size:11.5px;opacity:.55;padding:0 10px;word-break:break-all}

/* ---------- Contenu ---------- */
main{padding:30px 36px 70px;min-width:0}
.view{display:none;max-width:1120px;animation:fade .18s ease}
.view.on{display:block}
@keyframes fade{from{opacity:.4;transform:translateY(4px)}to{opacity:1;transform:none}}
.crumb{font-size:13px;color:var(--mute);margin-bottom:6px}
.crumb a{text-decoration:none}
.vh{margin-bottom:20px}
.vh h1{font-size:25px;margin:0;display:flex;gap:10px;align-items:center;letter-spacing:-.01em}
.vh p{margin:6px 0 0;color:var(--mute)}
h2.sec{font-size:17px;margin:28px 0 12px;display:flex;align-items:center;gap:10px}
h2.sec a{font-size:13px;font-weight:600;margin-left:auto;text-decoration:none}
.panel{background:var(--panel);border:1px solid var(--line);border-radius:var(--r);padding:18px 20px;margin-bottom:16px;box-shadow:var(--sh);min-width:0}
.panel h3{font-size:15px;margin:0 0 12px;display:flex;align-items:center;gap:8px}
.panel h3 .cnt{font-weight:500;color:var(--mute);font-size:13px;margin-left:auto}
.cols{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:16px}
.cols>.panel{margin-bottom:0}
.stack{display:flex;flex-direction:column;gap:16px}

/* Bandeau verdict */
.hero{display:flex;gap:26px;align-items:center;border-radius:18px;padding:24px 26px;margin-bottom:18px;border:1px solid transparent}
.hero.ok{background:var(--okbg);color:var(--ok)}.hero.warn{background:var(--warnbg);color:var(--warn)}.hero.bad{background:var(--badbg);color:var(--bad)}.hero.neutral{background:var(--accentbg);color:var(--accent)}
.hero h1{margin:0 0 6px;font-size:22px;line-height:1.25}
.hero p{margin:0;color:var(--ink);opacity:.85;max-width:640px}
.hero .cta{display:flex;gap:10px;flex-wrap:wrap;margin-top:14px}
.ring{--p:0;--c:var(--ok);width:116px;height:116px;border-radius:50%;background:conic-gradient(var(--c) calc(var(--p)*1%),rgba(127,140,160,.22) 0);display:grid;place-items:center;flex:none}
.ring span{background:var(--panel);width:90px;height:90px;border-radius:50%;display:grid;place-items:center;text-align:center;font-size:25px;font-weight:700;line-height:1.05;color:var(--ink)}
.ring small{display:block;font-size:11px;font-weight:500;color:var(--mute)}
.btn{display:inline-flex;align-items:center;gap:8px;border:1px solid var(--line);background:var(--panel);color:var(--ink);border-radius:10px;padding:8px 14px;font:inherit;font-size:13.5px;font-weight:600;text-decoration:none;cursor:pointer}
.btn:hover{border-color:var(--accent)}
.btn.primary{background:var(--accent);border-color:var(--accent);color:#fff}
@media (prefers-color-scheme:dark){.btn.primary{color:#0d1218}}
.btn.ghost{background:rgba(255,255,255,.08);border-color:rgba(255,255,255,.14);color:#fff;justify-content:center}
.strip{display:flex;flex-wrap:wrap;gap:8px 22px;font-size:13.5px;color:var(--mute);margin:-4px 0 18px}
.strip b{color:var(--ink)}

/* KPI */
.kpis{display:grid;grid-template-columns:repeat(auto-fit,minmax(170px,1fr));gap:12px;margin-bottom:18px}
.kpi{display:block;background:var(--panel);border:1px solid var(--line);border-radius:var(--r);padding:14px 16px;text-decoration:none;color:inherit;box-shadow:var(--sh);transition:border-color .15s,transform .15s}
a.kpi:hover{border-color:var(--accent);transform:translateY(-1px)}
.kpi b{display:block;font-size:27px;font-weight:700;letter-spacing:-.02em;line-height:1.2}
.kpi span{color:var(--mute);font-size:13px}
.kpi.ok b{color:var(--ok)}.kpi.warn b{color:var(--warn)}.kpi.bad b{color:var(--bad)}.kpi.acc b{color:var(--accent)}

/* Tuiles de rubriques */
.tiles{display:grid;grid-template-columns:repeat(auto-fill,minmax(230px,1fr));gap:12px}
.tile{display:flex;flex-direction:column;gap:8px;background:var(--panel);border:1px solid var(--line);border-left:4px solid var(--line);border-radius:12px;padding:13px 15px;text-decoration:none;color:inherit;box-shadow:var(--sh);transition:transform .15s,border-color .15s}
.tile:hover{transform:translateY(-1px);border-color:var(--accent)}
.tile.ok{border-left-color:var(--ok)}.tile.warn{border-left-color:#e3a33b}.tile.bad{border-left-color:var(--bad)}
.tile .tt{display:flex;gap:8px;align-items:center;font-weight:600}
.tile .ts{font-size:12.5px;color:var(--mute)}
.bar{height:6px;border-radius:99px;background:var(--infobg);overflow:hidden;display:flex}
.bar i{display:block;height:100%}
.bar .b-ok{background:var(--ok)}.bar .b-warn{background:#e3a33b}.bar .b-bad{background:var(--bad)}

/* Captures */
.shots{display:grid;grid-template-columns:1fr 1fr;gap:14px}
.shots figure,.fig{margin:0}
.shots img,.fig img{width:100%;border-radius:10px;border:1px solid var(--line);display:block;cursor:zoom-in;background:var(--soft)}
figcaption{font-size:12.5px;color:var(--mute);margin-top:6px;text-align:center}
.lb{position:fixed;inset:0;background:rgba(5,10,18,.86);display:none;place-items:center;z-index:50;cursor:zoom-out;padding:24px}
.lb.on{display:grid}.lb img{max-width:100%;max-height:100%;border-radius:8px}

/* Barre d'outils / filtres */
.toolbar{display:flex;gap:10px;align-items:center;flex-wrap:wrap;margin-bottom:14px;position:sticky;top:0;z-index:5;background:var(--bg);padding:8px 0}
.seg{display:flex;background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:3px;gap:2px;flex-wrap:wrap}
.seg button{border:0;background:transparent;font:inherit;font-size:13px;font-weight:600;color:var(--mute);padding:6px 11px;border-radius:7px;cursor:pointer;display:flex;gap:6px;align-items:center}
.seg button.on{background:var(--accentbg);color:var(--accent)}
.seg button i{font-style:normal;font-size:11.5px;background:var(--infobg);border-radius:99px;padding:0 7px;color:var(--mute)}
.search{flex:1;min-width:200px;border:1px solid var(--line);background:var(--panel);color:var(--ink);border-radius:10px;padding:9px 12px 9px 34px;font:inherit;font-size:13.5px;background-image:url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='16' height='16' fill='none' stroke='%238a96a6' stroke-width='2'%3E%3Ccircle cx='7' cy='7' r='5'/%3E%3Cpath d='m11 11 4 4'/%3E%3C/svg%3E");background-repeat:no-repeat;background-position:11px 50%}
.search:focus,.seg button:focus-visible,.btn:focus-visible{outline:2px solid var(--accent);outline-offset:1px}
.empty{text-align:center;color:var(--mute);padding:26px;border:1px dashed var(--line);border-radius:12px;display:none}
.empty.show{display:block}
.allgood{text-align:center;padding:34px 20px;background:var(--okbg);color:var(--ok);border-radius:var(--r);font-weight:600}
.allgood span{display:block;font-size:34px;margin-bottom:6px}

/* Lignes de contrôle */
.item{background:var(--panel);border:1px solid var(--line);border-left:4px solid var(--line);border-radius:12px;padding:12px 16px;margin-bottom:8px;box-shadow:var(--sh)}
.item.s-OK{border-left-color:var(--ok)}.item.s-ECART{border-left-color:var(--bad)}.item.s-MANUEL{border-left-color:#e3a33b}.item.s-INFO{border-left-color:#9aa7b6}
.ihead{display:flex;gap:12px;align-items:flex-start;justify-content:space-between}
.ihead .el{font-weight:600;word-break:break-word}
.ihead .cat{display:block;font-weight:500;font-size:12px;color:var(--mute)}
.cmp{display:grid;grid-template-columns:minmax(0,1fr) 24px minmax(0,1fr);gap:6px;align-items:start;margin-top:8px;font-size:13.5px}
.cmp small{display:block;font-size:11px;text-transform:uppercase;letter-spacing:.06em;color:var(--mute);margin-bottom:2px}
.cmp .v{word-break:break-word}
.cmp .arr{color:var(--mute);text-align:center;padding-top:16px}
.act{margin-top:10px;font-size:13px;background:var(--soft);border-radius:8px;padding:8px 10px}
.item.s-ECART .act{background:var(--badbg)}.item.s-MANUEL .act{background:var(--warnbg)}
.act b{margin-right:4px}
.pill{display:inline-block;padding:2px 10px;border-radius:999px;font-size:12px;font-weight:700;white-space:nowrap;flex:none}
.pill.ok{background:var(--okbg);color:var(--ok)}.pill.bad{background:var(--badbg);color:var(--bad)}.pill.warn{background:var(--warnbg);color:var(--warn)}.pill.info{background:var(--infobg);color:var(--info)}
.chk{display:inline-flex;gap:8px;align-items:center;cursor:pointer;font-weight:700;font-size:13px;color:var(--warn);white-space:nowrap;flex:none;user-select:none}
.chk input{width:20px;height:20px;accent-color:var(--ok);cursor:pointer}
.item.done{opacity:.55}.item.done .chk{color:var(--ok)}
.progress{background:var(--panel);border:1px solid var(--line);border-radius:var(--r);padding:14px 18px;margin-bottom:16px;display:flex;gap:16px;align-items:center}
.progress .bar{flex:1;height:10px}
.progress b{font-size:15px;white-space:nowrap}

/* Tableaux, listes */
.tw{overflow-x:auto}
table{width:100%;border-collapse:collapse;font-size:13.5px}
th{text-align:left;color:var(--mute);font-weight:600;font-size:12.5px;border-bottom:1px solid var(--line);padding:7px 10px;white-space:nowrap}
td{border-bottom:1px solid var(--line);padding:8px 10px;vertical-align:top;word-break:break-word}
tr:last-child td{border-bottom:none}
td.n,th.n{text-align:right;white-space:nowrap}
.kv{display:grid;grid-template-columns:minmax(150px,auto) 1fr;gap:8px 18px;margin:0}
.kv dt{color:var(--mute)}.kv dd{margin:0;font-weight:500;word-break:break-word}
.chips{display:flex;flex-wrap:wrap;gap:6px}
.chips span{background:var(--infobg);border-radius:8px;padding:4px 10px;font-size:13px}
.sw{display:inline-block;width:14px;height:14px;border-radius:4px;vertical-align:-2px;border:1px solid var(--line);margin-right:6px}
.alert{display:flex;gap:12px;align-items:flex-start;background:var(--warnbg);border-radius:12px;padding:12px 14px;margin-bottom:8px}
.alert span{font-size:18px;line-height:1.2}
.legend{display:grid;grid-template-columns:auto 1fr;gap:10px 14px;align-items:center}
.note{font-size:12.5px;color:var(--mute);margin-top:8px}
.foot{color:var(--mute);font-size:12.5px;margin-top:30px}

@media (max-width:980px){.cols{grid-template-columns:1fr}}
@media (max-width:860px){
  .app{grid-template-columns:1fr}
  aside{position:sticky;height:auto;z-index:20;padding:12px 12px 8px}
  .who{padding:4px 6px 8px;margin-bottom:6px}.who span,.brand,.side-foot,nav .grp{display:none}
  nav{flex-direction:row;overflow-x:auto;gap:4px;padding-bottom:4px}
  nav a{white-space:nowrap;flex:none}
  main{padding:20px 16px 50px}
  .hero{flex-direction:column;align-items:flex-start}
  .shots{grid-template-columns:1fr}
  .cmp{grid-template-columns:1fr}.cmp .arr{display:none}
}
@media print{
  body{background:#fff;font-size:12px}
  aside,.toolbar,.lb,.hero .cta,.btn{display:none!important}
  .app{display:block} main{padding:0}
  .view{display:block!important;max-width:none;break-before:page;animation:none}
  .view:first-child{break-before:auto}
  .item,.panel,.tile,.kpi{break-inside:avoid;box-shadow:none}
  .hero,.pill,.badge,.bar i,.item{-webkit-print-color-adjust:exact;print-color-adjust:exact}
}

/* Actions de correction */
.acts{display:flex;flex-wrap:wrap;gap:8px;margin-top:10px;align-items:flex-start}
.abtn{display:inline-flex;align-items:center;gap:6px;border:1px solid var(--line);background:var(--panel);color:var(--accent);border-radius:9px;padding:6px 11px;font:inherit;font-size:13px;font-weight:600;text-decoration:none;cursor:pointer;line-height:1.3}
.abtn:hover{border-color:var(--accent);background:var(--accentbg)}
.abtn.main{background:var(--accent);border-color:var(--accent);color:#fff}
.abtn.main:hover{filter:brightness(1.08);background:var(--accent)}
@media (prefers-color-scheme:dark){.abtn.main{color:#0d1218}}
.abtn i{font-style:normal;font-size:11px;font-weight:700;background:var(--warnbg);color:var(--warn);border-radius:6px;padding:0 6px}
.cmdw{display:inline-flex;flex-direction:column;gap:4px;max-width:100%}
.cmdd summary{font-size:11.5px;color:var(--mute);cursor:pointer;list-style:none;padding-left:4px}
.cmdd summary::-webkit-details-marker{display:none}
.cmdd code{display:block;margin-top:4px;font:12px/1.45 Consolas,"Cascadia Mono",monospace;background:var(--soft);border:1px solid var(--line);border-radius:8px;padding:8px 10px;white-space:pre-wrap;word-break:break-all;max-width:760px}
.bundle{display:flex;gap:12px;align-items:center;flex-wrap:wrap;background:var(--accentbg);border-radius:var(--r);padding:14px 16px;margin-bottom:16px}
.bundle p{margin:0;flex:1;min-width:240px;font-size:13.5px}
.toast{position:fixed;left:50%;bottom:26px;transform:translate(-50%,20px);background:#13263f;color:#fff;padding:12px 18px;border-radius:12px;font-size:14px;box-shadow:0 8px 24px rgba(0,0,0,.25);opacity:0;pointer-events:none;transition:opacity .2s,transform .2s;z-index:60;max-width:min(560px,92vw)}
.toast.on{opacity:1;transform:translate(-50%,0)}
.toast b{display:block;margin-bottom:2px}
.flash{animation:flash 1.6s ease}
@keyframes flash{0%,40%{box-shadow:0 0 0 3px var(--accent)}100%{box-shadow:var(--sh)}}
@media print{.acts,.bundle,.toast{display:none!important}}
.stxt{margin:8px 0 0;font-size:13.5px;line-height:1.5}
.item.step.done{opacity:.6}
code{font:12.5px Consolas,"Cascadia Mono",monospace;background:var(--soft);border:1px solid var(--line);border-radius:6px;padding:1px 6px}
'@
$script:UiJs = @'
(function () {
'use strict';
var D = JSON.parse(document.getElementById('data').textContent);

/* ================================================================ Outils */
function arr(x) { return x == null ? [] : (Array.isArray(x) ? x : [x]); }
function esc(s) { return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]; }); }
function val(v) {
  v = v == null ? '' : String(v);
  if (/^#[0-9a-f]{6}$/i.test(v)) { return '<span class="sw" style="background:' + v + '"></span>' + esc(v); }
  return v ? esc(v) : '<span class="mute">—</span>';
}
function num(n) { return (+n || 0).toLocaleString('fr-FR'); }
function size(b) {
  b = +b || 0;
  if (b >= 1073741824) { return (b / 1073741824).toLocaleString('fr-FR', { maximumFractionDigits: 2 }) + ' Go'; }
  if (b >= 1048576) { return Math.round(b / 1048576).toLocaleString('fr-FR') + ' Mo'; }
  if (b >= 1024) { return Math.round(b / 1024) + ' Ko'; }
  return b + ' o';
}
function plural(n, s, p) { return num(n) + ' ' + (n > 1 ? (p || s + 's') : s); }
var ST = { OK: { l: 'Conforme', c: 'ok' }, ECART: { l: 'Écart', c: 'bad' }, MANUEL: { l: 'À vérifier', c: 'warn' }, INFO: { l: 'Info', c: 'info' } };
var ORDER = { ECART: 0, MANUEL: 1, OK: 2, INFO: 3 };
function pill(s) { var x = ST[s] || ST.INFO; return '<span class="pill ' + x.c + '">' + x.l + '</span>'; }
function vh(title, sub, icon, crumb) {
  return (crumb ? '<div class="crumb"><a href="#synthese">Synthèse</a> › ' + esc(crumb) + '</div>' : '') +
    '<header class="vh"><h1>' + (icon ? '<span>' + icon + '</span>' : '') + esc(title) + '</h1>' + (sub ? '<p>' + sub + '</p>' : '') + '</header>';
}
function panel(title, body, extra) {
  return '<div class="panel">' + (title ? '<h3>' + title + (extra ? '<span class="cnt">' + extra + '</span>' : '') + '</h3>' : '') + body + '</div>';
}
function table(head, rows, cls, id) {
  rows = arr(rows);
  if (!rows.length) { return '<p class="mute">Aucun élément.</p>'; }
  return '<div class="tw"><table' + (id ? ' id="' + id + '"' : '') + '><thead><tr>' +
    head.map(function (h) { var n = h.charAt(0) === '#'; return '<th' + (n ? ' class="n"' : '') + '>' + esc(n ? h.slice(1) : h) + '</th>'; }).join('') +
    '</tr></thead><tbody>' + rows.map(function (r) {
      return '<tr>' + r.map(function (c, i) { var n = head[i] && head[i].charAt(0) === '#'; return '<td' + (n ? ' class="n"' : '') + '>' + c + '</td>'; }).join('') + '</tr>';
    }).join('') + '</tbody></table></div>';
}
function kv(pairs) {
  return '<dl class="kv">' + pairs.filter(function (p) { return p; }).map(function (p) { return '<dt>' + esc(p[0]) + '</dt><dd>' + p[1] + '</dd>'; }).join('') + '</dl>';
}
function chips(items) {
  items = arr(items).filter(function (x) { return x; });
  return items.length ? '<div class="chips">' + items.map(function (x) { return '<span>' + esc(x) + '</span>'; }).join('') + '</div>' : '<p class="mute">Aucun élément.</p>';
}
function searchBox(target, ph) { return '<input class="search" type="search" data-tq="' + target + '" placeholder="' + esc(ph || 'Rechercher…') + '">'; }
var uid = 0;

/* ================================================================ Coquille : menu + vues + navigation */
function shell(o) {
  var nav = o.nav.map(function (n) {
    if (n.grp) { return '<div class="grp">' + esc(n.grp) + '</div>'; }
    var lead = n.dot ? '<span class="dot ' + n.dot + '"></span>' : '<span class="ni">' + (n.icon || '') + '</span>';
    var badge = (n.badge !== undefined && n.badge !== null && n.badge !== '') ?
      '<span class="badge ' + (n.badgeCls || '') + '"' + (n.badgeId ? ' id="' + n.badgeId + '"' : '') + '>' + n.badge + '</span>' : '';
    return '<a href="#' + n.id + '" data-id="' + n.id + '">' + lead + '<span class="nl">' + esc(n.label) + '</span>' + badge + '</a>';
  }).join('');
  var views = Object.keys(o.views).map(function (k) { return '<section class="view" id="v-' + k + '">' + o.views[k] + '</section>'; }).join('');
  document.getElementById('app').innerHTML =
    '<div class="app"><aside><div class="brand">' + esc(o.brand) + '</div><div class="who"><b>' + esc(o.title) + '</b><span>' + esc(o.sub) + '</span></div>' +
    '<nav>' + nav + '</nav><div class="side-foot"><button class="btn ghost" type="button" onclick="window.print()">🖨️ Imprimer / PDF</button>' + (o.foot || '') + '</div></aside>' +
    '<main>' + views + '</main></div><div id="lb" class="lb"><img alt=""></div><div id="toast" class="toast"></div>';
  window.addEventListener('hashchange', route);
  route();
}
function route() {
  var id = (location.hash || '').slice(1), anchor = null;
  if (id && !document.getElementById('v-' + id) && document.getElementById(id)) {
    anchor = document.getElementById(id); var pv = anchor.closest('.view'); id = pv ? pv.id.slice(2) : 'synthese';
  }
  if (!id || !document.getElementById('v-' + id)) { id = 'synthese'; }
  [].forEach.call(document.querySelectorAll('.view'), function (v) { v.classList.toggle('on', v.id === 'v-' + id); });
  [].forEach.call(document.querySelectorAll('nav a'), function (a) {
    var on = a.getAttribute('data-id') === id;
    a.classList.toggle('on', on);
    if (on && a.scrollIntoView && window.innerWidth <= 860) { a.scrollIntoView({ block: 'nearest', inline: 'center' }); }
  });
  if (anchor) { setTimeout(function () { anchor.scrollIntoView({ behavior: 'smooth', block: 'start' }); anchor.classList.add('flash'); setTimeout(function () { anchor.classList.remove('flash'); }, 1700); }, 60); }
  else { window.scrollTo(0, 0); }
}
/* Filtres, recherche, agrandissement des images */
function applyList(wrap) {
  var f = wrap.getAttribute('data-f') || 'all';
  var q = (wrap.querySelector('[data-lq]') || {}).value || '';
  q = q.toLowerCase().trim();
  var shown = 0;
  [].forEach.call(wrap.querySelectorAll('.item'), function (it) {
    var ok = (f === 'all' || it.getAttribute('data-s') === f) && (!q || it.getAttribute('data-t').indexOf(q) >= 0);
    it.style.display = ok ? '' : 'none';
    if (ok) { shown++; }
  });
  var e = wrap.querySelector('.empty'); if (e) { e.classList.toggle('show', shown === 0); }
}
document.addEventListener('click', function (e) {
  var b = e.target.closest ? e.target.closest('[data-f]') : null;
  if (b && b.tagName === 'BUTTON') {
    var w = b.closest('.lst');
    w.setAttribute('data-f', b.getAttribute('data-f'));
    [].forEach.call(w.querySelectorAll('.seg button'), function (x) { x.classList.toggle('on', x === b); });
    applyList(w); return;
  }
  var z = e.target.closest ? e.target.closest('[data-zoom]') : null;
  var lb = document.getElementById('lb');
  if (z) { lb.querySelector('img').src = z.getAttribute('data-zoom'); lb.classList.add('on'); return; }
  if (lb && lb.classList.contains('on') && e.target.closest('#lb')) { lb.classList.remove('on'); }
});
function toast(title, hint) {
  var t = document.getElementById('toast'); if (!t) { return; }
  t.innerHTML = '<b>' + esc(title) + '</b>' + esc(hint || '');
  t.classList.add('on'); clearTimeout(toast.h); toast.h = setTimeout(function () { t.classList.remove('on'); }, 4200);
}
function copyText(txt, ok) {
  function fallback() {
    var ta = document.createElement('textarea'); ta.value = txt; ta.style.position = 'fixed'; ta.style.opacity = '0';
    document.body.appendChild(ta); ta.select(); var r = false; try { r = document.execCommand('copy'); } catch (e) { }
    document.body.removeChild(ta); r ? ok() : prompt('Copier manuellement (Ctrl+C) :', txt);
  }
  if (navigator.clipboard && navigator.clipboard.writeText) { navigator.clipboard.writeText(txt).then(ok, fallback); } else { fallback(); }
}
document.addEventListener('click', function (e) {
  var l = e.target.closest ? e.target.closest('[data-launch]') : null;
  if (l) { toast('Ouverture du lanceur de corrections', 'Le navigateur demande d\u2019ouvrir Windows PowerShell : accepter, puis confirmer la correction dans la fenêtre qui s\u2019affiche.'); return; }
  var c = e.target.closest ? e.target.closest('[data-copy]') : null;
  if (!c) { return; }
  var hint = c.getAttribute('data-hint') || '';
  copyText(c.getAttribute('data-copy'), function () { toast(c.getAttribute('data-done') || 'Copié dans le presse-papiers', hint); });
});
document.addEventListener('keydown', function (e) { if (e.key === 'Escape') { var lb = document.getElementById('lb'); if (lb) { lb.classList.remove('on'); } } });
document.addEventListener('input', function (e) {
  var t = e.target;
  if (t.hasAttribute('data-lq')) { applyList(t.closest('.lst')); }
  if (t.hasAttribute('data-tq')) {
    var tb = document.getElementById(t.getAttribute('data-tq')); var q = t.value.toLowerCase().trim();
    if (tb) { [].forEach.call(tb.querySelectorAll('tbody tr'), function (r) { r.style.display = !q || r.textContent.toLowerCase().indexOf(q) >= 0 ? '' : 'none'; }); }
  }
});

/* Liste filtrable de contrôles */
function itemHtml(k, o) {
  o = o || {};
  var t = (k.e + ' ' + k.a + ' ' + k.n + ' ' + (k.note || '') + ' ' + (o.catName || '')).toLowerCase();
  var right = o.check ? '<label class="chk"><input type="checkbox" data-k="' + esc(k.c + '|' + k.e) + '"><span>Fait</span></label>' : pill(k.s);
  var actLbl = k.s === 'OK' || k.s === 'INFO' ? 'Remarque :' : 'À faire :';
  return '<div class="item s-' + k.s + '" data-s="' + k.s + '" data-t="' + esc(t) + '">' +
    '<div class="ihead"><div class="el">' + (o.catName ? '<span class="cat">' + esc(o.catName) + '</span>' : '') + esc(k.e) + '</div>' + right + '</div>' +
    '<div class="cmp"><div><small>Ancien poste</small><div class="v">' + val(k.a) + '</div></div><div class="arr">→</div><div><small>Nouveau poste</small><div class="v">' + val(k.n) + '</div></div></div>' +
    (k.note ? '<div class="act"><b>' + actLbl + '</b>' + esc(k.note) + '</div>' : '') + actsHtml(k) + '</div>';
}
var HINT_PS = 'Collez dans PowerShell ouvert dans la session de l\u2019utilisateur (sans élévation), puis Entrée.';
var HINT_ADM = 'Collez dans PowerShell lancé « en tant qu\u2019administrateur », puis Entrée.';
var LAUNCH = (D.meta && D.meta.launch) || D.launch || '';
function runLabel(l) {
  var rules = [[/^Copier la commande de correction$/, 'Appliquer la correction'], [/^Copier la commande d'installation$/, 'Installer'],
    [/^Copier la commande de recopie$/, 'Recopier'], [/^Copier la commande de restauration( du menu)?$/, 'Restaurer'],
    [/^Copier la recherche winget$/, 'Rechercher avec winget'], [/^Copier la commande d'import du \.pfx$/, 'Importer le certificat (.pfx)'],
    [/^Copier la commande de redémarrage$/, 'Redémarrer le poste'], [/^Copier la commande de retrait du lanceur$/, 'Retirer le lanceur'],
    [/^Copier la commande de fermeture d'Outlook, Office et Teams$/, 'Fermer Outlook, Office et Teams'], [/^Copier la commande de copie des données$/, 'Lancer la copie des données'],
    [/^Copier la commande d'export des réseaux Wi-Fi$/, 'Exporter les réseaux Wi-Fi'], [/^Copier la commande d'export du certificat$/, 'Exporter le certificat'],
    [/^Copier la commande d'import de ce certificat$/, 'Importer ce certificat'], [/^Copier la commande d'import de ce réseau$/, 'Importer ce réseau Wi-Fi'],
    [/^Copier la commande de suppression des fichiers sensibles$/, 'Supprimer les fichiers sensibles'],
    [/^Copier la commande pour (.*)$/, function (m, a) { return a.charAt(0).toUpperCase() + a.slice(1); }]];
  for (var i = 0; i < rules.length; i++) { if (rules[i][0].test(l)) { return l.replace(rules[i][0], rules[i][1]); } }
  return l.replace(/^Copier /, '');
}
function actsHtml(k) {
  var a = arr(k.x); if (!a.length || k.s === 'OK') { return ''; }
  var first = true;
  return '<div class="acts">' + a.map(function (x) {
    var cls = 'abtn' + (first ? ' main' : ''); first = false;
    if (x.t === 'open') { return '<a class="' + cls + '" href="' + esc(x.u) + '" title="Windows demandera de confirmer l\u2019ouverture">⚙️ ' + esc(x.l) + '</a>'; }
    if (x.t === 'web') { return '<a class="' + cls + '" href="' + esc(x.u) + '" target="_blank" rel="noopener">🌐 ' + esc(x.l) + '</a>'; }
    if (x.t === 'nav') { return '<a class="' + cls + '" href="' + esc(x.u) + '">↗ ' + esc(x.l) + '</a>'; }
    if (x.t === 'copy') { return '<button type="button" class="' + cls + '" data-copy="' + esc(x.c) + '" data-hint="' + esc(x.h || '') + '">📋 ' + esc(x.l) + '</button>'; }
    var copyBtn = '<button type="button" class="abtn' + (LAUNCH && x.id ? '' : (cls.indexOf('main') > 0 ? ' main' : '')) + '" data-copy="' + esc(x.c) + '" data-done="Commande copiée" data-hint="' + esc(x.adm ? HINT_ADM : HINT_PS) + '">' + (LAUNCH && x.id ? '📋 Copier' : '⌨️ ' + esc(x.l) + (x.adm ? ' <i>admin</i>' : '')) + '</button>';
    if (LAUNCH && x.id) {
      return '<span class="cmdw"><a class="' + cls + '" href="' + esc(LAUNCH + x.id) + '" data-launch="1">▶ ' + esc(runLabel(x.l)) + (x.adm ? ' <i>admin</i>' : '') + '</a>' +
        '<details class="cmdd"><summary>▸ voir / copier la commande</summary><code>' + esc(x.c) + '</code>' + copyBtn + '</details></span>';
    }
    return '<span class="cmdw">' + copyBtn + '<details class="cmdd"><summary>▸ voir la commande</summary><code>' + esc(x.c) + '</code></details></span>';
  }).join('') + '</div>';
}
function filterList(items, o) {
  o = o || {};
  items = items.slice().sort(function (a, b) { return ORDER[a.s] - ORDER[b.s]; });
  var c = { ECART: 0, MANUEL: 0, OK: 0, INFO: 0 };
  items.forEach(function (k) { c[k.s]++; });
  var btn = function (f, l, n) { return '<button type="button" data-f="' + f + '"' + (f === 'all' ? ' class="on"' : '') + '>' + l + '<i>' + n + '</i></button>'; };
  var seg = btn('all', 'Tout', items.length) + (c.ECART ? btn('ECART', 'Écarts', c.ECART) : '') + (c.MANUEL ? btn('MANUEL', 'À vérifier', c.MANUEL) : '') +
    (c.OK ? btn('OK', 'Conformes', c.OK) : '') + (c.INFO ? btn('INFO', 'Info', c.INFO) : '');
  return '<div class="lst" data-f="all"><div class="toolbar"><div class="seg">' + seg + '</div><input class="search" type="search" data-lq placeholder="Rechercher dans cette rubrique…"></div>' +
    items.map(function (k) { return itemHtml(k, o); }).join('') + '<div class="empty">Aucun élément ne correspond.</div></div>';
}
function bar(n, total) {
  if (!total) { return '<div class="bar"></div>'; }
  var w = function (x) { return (x * 100 / total).toFixed(2) + '%'; };
  return '<div class="bar"><i class="b-ok" style="width:' + w(n.OK + n.INFO) + '"></i><i class="b-warn" style="width:' + w(n.MANUEL) + '"></i><i class="b-bad" style="width:' + w(n.ECART) + '"></i></div>';
}

/* ================================================================ RAPPORT DE MIGRATION */
function migration() {
  var m = D.meta, checks = arr(D.checks), cats = arr(D.cats), files = D.files || {};
  var byId = {};
  cats.forEach(function (c) {
    c.items = checks.filter(function (k) { return k.c === c.id; });
    c.n = { OK: 0, ECART: 0, MANUEL: 0, INFO: 0 };
    c.items.forEach(function (k) { c.n[k.s]++; });
    c.state = c.n.ECART ? 'bad' : (c.n.MANUEL ? 'warn' : 'ok');
    byId[c.id] = c;
  });
  cats = cats.filter(function (c) { return c.items.length; });
  var ec = checks.filter(function (k) { return k.s === 'ECART'; });
  var man = checks.filter(function (k) { return k.s === 'MANUEL'; });
  var cnt = D.counts;

  // ---- verdict
  var hcls, htitle, htext, cta = '';
  if (!ec.length && !man.length) { hcls = 'ok'; htitle = 'Migration conforme'; htext = "L'environnement a été retrouvé à l'identique sur le nouveau poste. Tous les contrôles sont au vert."; }
  else if (!ec.length) {
    hcls = 'warn'; htitle = 'Restauration conforme — ' + plural(man.length, 'vérification') + ' à faire ensemble';
    htext = "Tout ce qui pouvait être contrôlé automatiquement est identique à l'ancien poste. Il reste quelques points à valider visuellement ou à faire par l'utilisateur lui-même (mots de passe, Windows Hello…).";
    cta = '<a class="btn primary" href="#verifier">Commencer les vérifications →</a>';
  } else {
    hcls = 'bad'; htitle = plural(ec.length, 'écart') + ' à corriger avant validation';
    htext = "Chaque écart est détaillé avec l'action à mener. Une fois corrigés, relancer le contrôle (paramètre -VerifierSeulement) pour régénérer ce rapport.";
    cta = '<a class="btn primary" href="#corriger">Voir les écarts →</a>' + (man.length ? '<a class="btn" href="#verifier">Vérifications à faire (' + man.length + ')</a>' : '');
  }
  var rerunBtn = LAUNCH ? '<a class="btn" href="' + esc(LAUNCH + 'rerun') + '" data-launch="1">🔁 Relancer le contrôle</a>' : m.rerun ? '<button type="button" class="btn" data-copy="' + esc(m.rerun) + '" data-done="Commande de contrôle copiée" data-hint="' + esc(HINT_PS) + '">🔁 Relancer le contrôle</button>' : '';
  cta += rerunBtn;
  var ringC = D.score >= 95 ? 'var(--ok)' : (D.score >= 80 ? '#e3a33b' : 'var(--bad)');

  // ---- check-list mémorisée
  var store = 'migration-' + m.id, done = {};
  try { done = JSON.parse(localStorage.getItem(store) || '{}'); } catch (e) { done = {}; }

  var views = {};

  // ---- Synthèse
  var shots = '<div class="shots">' +
    (m.capAvant ? '<figure><img src="' + esc(m.capAvant) + '" data-zoom="' + esc(m.capAvant) + '" alt="Avant"><figcaption>Avant — ' + esc(m.ancien) + ' (' + esc(m.dateInv) + ')</figcaption></figure>' : '<figure><p class="mute">Capture de l\'ancien poste indisponible.</p></figure>') +
    (m.capApres ? '<figure><img src="' + esc(m.capApres) + '" data-zoom="' + esc(m.capApres) + '" alt="Après"><figcaption>Après — ' + esc(m.nouveau) + ' (' + esc(m.dateCtl) + ')</figcaption></figure>' : '<figure><p class="mute">Capture du nouveau poste indisponible.</p></figure>') +
    '</div><p class="note">Cliquer sur une capture pour l\'agrandir.</p>';
  var tiles = cats.map(function (c) {
    var t = c.n.ECART ? plural(c.n.ECART, 'écart') + (c.n.MANUEL ? ' · ' + c.n.MANUEL + ' à vérifier' : '') :
      (c.n.MANUEL ? c.n.MANUEL + ' à vérifier' : 'Tout est conforme ✓');
    return '<a class="tile ' + c.state + '" href="#' + c.id + '"><div class="tt"><span>' + c.icon + '</span>' + esc(c.nom) + '</div>' + bar(c.n, c.items.length) + '<div class="ts">' + t + ' · ' + plural(c.items.length, 'contrôle') + '</div></a>';
  }).join('');
  views.synthese =
    '<div class="hero ' + hcls + '"><div class="ring" style="--p:' + D.score + ';--c:' + ringC + '"><span>' + D.score + ' %<small>conforme</small></span></div>' +
    '<div><h1>' + esc(htitle) + '</h1><p>' + esc(htext) + '</p><div class="cta">' + cta + '</div></div></div>' +
    '<div class="strip"><span>Ancien poste : <b>' + esc(m.ancien) + '</b> · ' + esc(m.ancienOs) + '</span><span>Nouveau poste : <b>' + esc(m.nouveau) + '</b> · ' + esc(m.nouveauOs) + '</span><span>Relevé du ' + esc(m.dateInv) + ' · contrôle du ' + esc(m.dateCtl) + '</span></div>' +
    '<div class="kpis">' +
    '<a class="kpi ok" href="#' + (cats[0] ? cats[0].id : 'synthese') + '"><b>' + num(cnt.ok) + '</b><span>contrôles conformes</span></a>' +
    '<a class="kpi ' + (ec.length ? 'bad' : 'ok') + '" href="#corriger"><b>' + ec.length + '</b><span>écarts à corriger</span></a>' +
    '<a class="kpi warn" href="#verifier"><b id="kpiDone">0 / ' + man.length + '</b><span>vérifications faites</span></a>' +
    (files.total ? '<a class="kpi ' + (files.ok === files.total ? 'ok' : 'bad') + '" href="#fichiers"><b>' + num(files.ok) + ' / ' + num(files.total) + '</b><span>fichiers retrouvés</span></a>' : '') +
    (m.verifOnly ? '' : '<a class="kpi acc" href="#restauration"><b>' + arr(D.actions).length + '</b><span>éléments restaurés automatiquement</span></a>') +
    '</div>' +
    '<h2 class="sec">État par rubrique</h2><div class="tiles">' + tiles + '</div>' +
    '<h2 class="sec" id="captures">Le bureau, avant et après</h2>' + panel('', shots);

  // ---- À corriger
  var autos = [];
  ec.forEach(function (k) { arr(k.x).forEach(function (x) { if (x.t === 'cmd' && x.auto) { autos.push('# ' + (byId[k.c] ? byId[k.c].nom : '') + ' — ' + k.e + '\n' + x.c); } }); });
  var bundle = '<div class="bundle"><p><b>Corriger en une fois.</b> ' + (autos.length ? autos.length + ' écart(s) se corrigent automatiquement' + (LAUNCH ? ' : un clic les applique tous, après confirmation.' : ' : un seul copier-coller dans PowerShell les applique tous.') + ' Les autres demandent une action indiquée sur leur fiche.' : 'Aucun écart ne se corrige automatiquement : suivre l\u2019action indiquée sur chaque fiche.') + '</p>' +
    (autos.length && LAUNCH ? '<a class="btn primary" href="' + esc(LAUNCH + 'all') + '" data-launch="1">▶ Appliquer toutes les corrections (' + autos.length + ')</a>' : '') +
    (autos.length && !LAUNCH ? '<button type="button" class="btn primary" data-copy="' + esc('# Corrections générées par le rapport de migration — ' + m.dateCtl + '\n' + autos.join('\n\n')) + '" data-done="' + autos.length + ' corrections copiées" data-hint="' + esc(HINT_PS) + '">⌨️ Copier toutes les corrections (' + autos.length + ')</button>' : '') + rerunBtn + '</div>';
  views.corriger = (ec.length ? '' : '') + vh('Écarts à corriger', ec.length ? plural(ec.length, 'point') + " où le nouveau poste diffère de l'ancien. Chaque fiche indique l'action à mener." : '', '❗', 'Écarts à corriger') +
    (ec.length ? bundle : '') + (ec.length ? cats.filter(function (c) { return c.n.ECART; }).map(function (c) {
      return '<h2 class="sec"><span>' + c.icon + '</span>' + esc(c.nom) + '<a href="#' + c.id + '">Voir la rubrique →</a></h2>' +
        c.items.filter(function (k) { return k.s === 'ECART'; }).map(function (k) { return itemHtml(k); }).join('');
    }).join('') : '<div class="allgood"><span>✓</span>Aucun écart : tout ce qui a été contrôlé automatiquement est identique à l\'ancien poste.</div>');

  // ---- À vérifier ensemble
  views.verifier = vh('Vérifications à faire ensemble', "Ces points ne peuvent pas être contrôlés par le script : à valider avec l'utilisateur, puis cocher « Fait ». Les coches sont mémorisées dans ce navigateur.", '✅', 'Vérifications') +
    (man.length ? '<div class="progress"><b id="progTxt"></b><div class="bar"><i class="b-ok" id="progBar" style="width:0"></i></div></div>' +
      cats.filter(function (c) { return c.n.MANUEL; }).map(function (c) {
        return '<h2 class="sec"><span>' + c.icon + '</span>' + esc(c.nom) + '</h2>' +
          c.items.filter(function (k) { return k.s === 'MANUEL'; }).map(function (k) { return itemHtml(k, { check: true }); }).join('');
      }).join('') : '<div class="allgood"><span>✓</span>Aucune vérification manuelle en attente.</div>');

  // ---- Rubriques
  cats.forEach(function (c) {
    var sub = [c.n.OK ? plural(c.n.OK, 'élément conforme', 'éléments conformes') : '', c.n.ECART ? plural(c.n.ECART, 'écart') : '', c.n.MANUEL ? c.n.MANUEL + ' à vérifier' : ''].filter(Boolean).join(' · ');
    var extra = '';
    if (c.id === 'fichiers' && arr(files.rows).length) {
      extra = panel('Comparaison dossier par dossier', table(['Dossier', 'Emplacement', '#Avant', '#Après', '#Absents', '#Taille différente', 'Statut'],
        arr(files.rows).map(function (r) { return [esc(r.lib) + (r.note ? '<div class="note">' + esc(r.note) + '</div>' : ''), esc(r.loc || ''), num(r.avant), num(r.apres), r.abs ? '<b style="color:var(--bad)">' + num(r.abs) + '</b>' : '0', r.diff ? '<b style="color:var(--bad)">' + num(r.diff) + '</b>' : '0', pill(r.s)]; })));
      var miss = arr(files.missing);
      if (miss.length) {
        extra += '<div id="liste-fichiers"></div>' + panel('Fichiers absents ou différents', searchBox('tMiss', 'Rechercher un fichier…') + '<div style="height:10px"></div>' +
          table(['Dossier', 'Fichier', '#Taille', 'Problème'], miss.map(function (x) { return [esc(x.d), esc(x.f), size(x.t), esc(x.p)]; }), '', 'tMiss') +
          (files.missingTotal > miss.length ? '<p class="note">Affichage limité à ' + num(miss.length) + ' fichiers sur ' + num(files.missingTotal) + '.</p>' : '') +
          (m.csv ? '<p class="note">Liste complète : ' + esc(m.csv) + ' (dans le dossier de migration).</p>' : ''), plural(files.missingTotal, 'fichier'));
      }
      extra = '<div class="stack" style="margin-bottom:16px">' + extra + '</div>';
    }
    views[c.id] = vh(c.nom, sub, c.icon, c.nom) + extra + filterList(c.items);
  });

  // ---- Restauration
  if (!m.verifOnly) {
    views.restauration = vh('Ce qui a été restauré automatiquement', plural(arr(D.actions).length, 'élément') + ' remis en place par le script.', '⚙️', 'Restauration') +
      panel('Éléments restaurés', '<div class="chips">' + arr(D.actions).map(function (a) { return '<span>✓ ' + esc(a) + '</span>'; }).join('') + '</div>') +
      (arr(D.incidents).length ? panel('Problèmes rencontrés pendant la restauration', arr(D.incidents).map(function (x) { return '<div class="alert"><span>⚠️</span><div>' + esc(x) + '</div></div>'; }).join('')) : '') +
      panel('Retour arrière', '<p>L\'état du nouveau poste avant restauration a été sauvegardé dans <b>' + esc(m.bak) + '</b> (fichiers .reg à réimporter, Explorateur arrêté).</p>');
  }

  // ---- Aide
  views.aide = vh('Comment lire ce rapport', '', 'ℹ️', 'Aide') +
    panel('Les statuts', '<div class="legend">' + pill('OK') + '<span>Identique à l\'ancien poste.</span>' + pill('ECART') + '<span>Différent de l\'ancien poste : une action est indiquée pour corriger.</span>' +
      pill('MANUEL') + '<span>Ne peut pas être contrôlé automatiquement : à valider avec l\'utilisateur (check-list).</span>' + pill('INFO') + '<span>Pour information, aucune action attendue (ex. composant propre à l\'ancien matériel).</span></div>') +
    panel('Chaque fiche', '<p>Chaque contrôle compare la valeur relevée sur <b>l\'ancien poste</b> (à gauche) avec celle du <b>nouveau poste</b> (à droite). Le cadre coloré en dessous indique l\'action à mener.</p><p>Dans chaque rubrique, les boutons <b>Écarts / À vérifier / Conformes</b> filtrent la liste, et la zone de recherche trouve un élément par son nom.</p>') +
    panel('Les boutons d\u2019action', '<p>Chaque point à corriger propose une action, le bouton bleu étant la principale :</p><div class="legend">' +
      '<span class="abtn">⚙️ Ouvrir…</span><span>Ouvre directement la bonne page des Paramètres Windows ou du Store (Windows demande de confirmer).</span>' +
      (LAUNCH ? '<span class="abtn main">▶ Appliquer…</span><span>Lance la correction sur ce poste : le navigateur demande d\u2019ouvrir Windows PowerShell, puis une fenêtre affiche la commande exacte et demande confirmation. « admin » ouvre le contrôle de compte d\u2019utilisateur. Le lanceur ne connaît que les corrections de ce rapport ; il expire après 14 jours ou se retire avec le dernier contrôle final.</span>' : '') +
      '<span class="abtn">⌨️ Copier la commande</span><span>Copie la commande exacte de correction : la coller dans PowerShell ouvert dans la session de l\u2019utilisateur. « admin » = PowerShell lancé en administrateur. « voir la commande » l\u2019affiche avant de l\u2019exécuter.</span>' +
      '<span class="abtn">📋 Copier l\u2019adresse</span><span>Pour les réglages des navigateurs (edge://, chrome://) que les liens ne peuvent pas ouvrir : coller dans la barre d\u2019adresse.</span>' +
      '<span class="abtn">🌐 Ouvrir…</span><span>Ouvre une page web (boutique d\u2019extensions, bibliothèque SharePoint…).</span></div>' +
      '<p class="note">Sur la page « Écarts à corriger », le bouton « Copier toutes les corrections » regroupe toutes les commandes automatiques en un seul copier-coller.</p>') +
    panel('Régénérer le rapport', '<p>Après les corrections, relancer :</p><p><code>Restaure-Poste.ps1 -Source "…\\' + esc(m.id) + '" -VerifierSeulement</code></p><p class="note">Ce mode ne modifie rien sur le poste : il refait uniquement la comparaison.</p>');

  // ---- Menu
  var nav = [{ id: 'synthese', label: 'Synthèse', icon: '🏠' },
    { id: 'corriger', label: 'Écarts à corriger', icon: '❗', badge: ec.length ? ec.length : '✓', badgeCls: ec.length ? 'bad' : 'ok' },
    { id: 'verifier', label: 'Vérifications', icon: '✅', badge: man.length || '✓', badgeCls: man.length ? 'warn' : 'ok', badgeId: 'navDone' },
    { grp: 'Rubriques' }];
  cats.forEach(function (c) { var p = c.n.ECART + c.n.MANUEL; nav.push({ id: c.id, label: c.nom, dot: c.state, badge: p || '', badgeCls: c.n.ECART ? 'bad' : 'warn' }); });
  nav.push({ grp: 'Rapport' });
  if (!m.verifOnly) { nav.push({ id: 'restauration', label: 'Restauration', icon: '⚙️' }); }
  nav.push({ id: 'aide', label: 'Comment lire ce rapport', icon: 'ℹ️' });

  shell({ brand: 'Rapport de migration', title: m.who, sub: m.ancien + ' → ' + m.nouveau, nav: nav, views: views,
    foot: '<small>' + (m.verifOnly ? 'Contrôle seul — aucune modification' : 'Sauvegarde : ' + esc(m.bak)) + '</small>' });

  // ---- état des coches
  var boxes = document.querySelectorAll('input[data-k]');
  function upd() {
    var n = 0;
    [].forEach.call(boxes, function (b) { if (b.checked) { n++; } b.closest('.item').classList.toggle('done', b.checked); });
    var t = n + ' / ' + boxes.length;
    var k = document.getElementById('kpiDone'); if (k) { k.textContent = t; }
    var pt = document.getElementById('progTxt'); if (pt) { pt.textContent = t + ' faites'; }
    var pb = document.getElementById('progBar'); if (pb) { pb.style.width = (boxes.length ? n * 100 / boxes.length : 100) + '%'; }
    var nb = document.getElementById('navDone'); if (nb) { var r = boxes.length - n; nb.textContent = r || '✓'; nb.className = 'badge ' + (r ? 'warn' : 'ok'); }
  }
  [].forEach.call(boxes, function (b) {
    if (done[b.getAttribute('data-k')]) { b.checked = true; }
    b.addEventListener('change', function () {
      done[b.getAttribute('data-k')] = b.checked;
      try { localStorage.setItem(store, JSON.stringify(done)); } catch (e) { }
      upd();
    });
  });
  upd();
}

/* ================================================================ RAPPORT D'INVENTAIRE */
function inventaire() {
  var I = D.inv, X = D.extra, views = {};
  var todoN = arr(D.prep).filter(function (p) { return p.etat !== 'auto'; }).length;
  var lumi = { '0': 'Sombre', '1': 'Clair' }, onoff = { '0': 'Désactivé', '1': 'Activé' };
  function lab(map, v, def) { v = v == null || v === '' ? def : String(v); return map[v] || (v == null ? 'Par défaut' : v); }
  var alertes = arr(I.Alertes), items = arr(I.Bureau && I.Bureau.Elements), navs = arr(I.Navigateurs), od = arr(I.OneDriveMontages);
  var dossiers = arr(I.Dossiers), apps = arr(I.Logiciels), printers = arr(I.Imprimantes), drives = arr(I.Lecteurs);
  var opt = I.Options || {};

  // ---- Synthèse
  views.synthese =
    '<div class="hero neutral"><div class="ring" style="--p:100;--c:var(--ok)"><span>✓<small>relevé</small></span></div><div><h1>Votre environnement a été entièrement relevé</h1>' +
    '<p>Ce rapport liste tout ce qui sera retrouvé à l\'identique sur le nouveau poste. Aucune modification n\'a été faite sur cet ordinateur.</p>' +
    '<div class="cta"><a class="btn primary" href="#preparation">Préparer la migration (' + plural(todoN, 'étape') + ') →</a>' + (alertes.length ? '<a class="btn" href="#attention">Points d\'attention (' + alertes.length + ')</a>' : '') + '</div></div></div>' +
    '<div class="strip"><span>Poste : <b>' + esc(I.Meta.Ordinateur) + '</b></span><span>' + esc(I.Systeme.OS) + ' (build ' + esc(I.Systeme.Build) + ')</span><span>' + esc(I.Systeme.Fabricant) + ' ' + esc(I.Systeme.Modele) + '</span><span>Relevé le ' + esc(I.Meta.Date) + '</span></div>' +
    '<div class="kpis">' +
    '<a class="kpi acc" href="#bureau"><b>' + items.length + '</b><span>éléments sur le Bureau</span></a>' +
    '<a class="kpi acc" href="#barre"><b>' + arr(I.Epingles).length + '</b><span>applications épinglées</span></a>' +
    '<a class="kpi acc" href="#logiciels"><b>' + apps.length + '</b><span>logiciels installés</span></a>' +
    '<a class="kpi acc" href="#impression"><b>' + printers.length + ' · ' + drives.length + '</b><span>imprimantes · lecteurs réseau</span></a>' +
    '<a class="kpi acc" href="#navigateurs"><b>' + num(X.favTotal) + '</b><span>favoris internet</span></a>' +
    '<a class="kpi acc" href="#fichiers"><b>' + num(X.totalFichiers) + '</b><span>fichiers (' + size(X.totalOctets) + ')</span></a>' +
    '</div>' +
    (X.capture ? '<h2 class="sec">Le bureau au moment du relevé</h2>' + panel('', '<figure class="fig"><img src="' + esc(X.capture) + '" data-zoom="' + esc(X.capture) + '" alt="Bureau"></figure><p class="note">Cliquer pour agrandir. Cette capture servira de référence pour comparer le nouveau poste.</p>') : '');

  // ---- Préparation de la migration (à faire sur ce poste)
  var prep = arr(D.prep), pstore = 'prep-' + (D.id || ''), pdone = {};
  try { pdone = JSON.parse(localStorage.getItem(pstore) || '{}'); } catch (e) { pdone = {}; }
  var ET = { auto: 'Fait par l\u2019inventaire', todo: 'À faire', reco: 'Recommandé' };
  views.preparation = vh('Préparer la migration', 'À faire sur ce poste, dans l\u2019ordre, avant de passer au nouveau poste. Les boutons ▶ lancent l\u2019action après confirmation ; cocher chaque étape une fois faite.', '🧳', 'Préparation') +
    '<div class="progress"><b id="prepTxt"></b><div class="bar"><i class="b-ok" id="prepBar" style="width:0"></i></div></div>' +
    prep.map(function (p, i) {
      var chk = p.etat === 'auto' ? '<span class="pill ok">✓ Fait</span>' : '<label class="chk"><input type="checkbox" data-p="' + esc(p.id) + '"><span>Fait</span></label>';
      var st = p.etat === 'auto' ? 'OK' : (p.etat === 'todo' ? 'MANUEL' : 'INFO');
      return '<div class="item step s-' + st + '"><div class="ihead"><div class="el"><span class="cat">Étape ' + (i + 1) + ' · ' + (ET[p.etat] || 'À faire') + '</span>' + esc(p.titre) + '</div>' + chk + '</div>' +
        '<p class="stxt">' + esc(p.texte) + '</p>' + actsHtml({ x: p.x, s: 'MANUEL' }) + '</div>';
    }).join('') +
    '<div class="bundle"><p><b>Ensuite :</b> transporter le dossier de migration complet sur le nouveau poste et y lancer <code>Restaure-Poste.ps1 -Source "…\\' + esc(D.id || '') + '"</code>. Les données copiées seront remises en place automatiquement, puis tout sera contrôlé.</p></div>';

  // ---- Points d'attention
  views.attention = vh('Points d\'attention pour la migration', 'Ce qui demandera une action ou une décision le jour du changement de poste.', '⚠️', 'Points d\'attention') +
    (alertes.length ? alertes.map(function (a) { return '<div class="alert"><span>⚠️</span><div>' + esc(a) + '</div></div>'; }).join('') : '<div class="allgood"><span>✓</span>Aucun point d\'attention particulier.</div>');

  // ---- Bureau & apparence
  var fe = I.FondEcran || {}, th = I.Theme || {}, so = I.Souris || {};
  var screens = arr(I.Ecrans).map(function (e) { return e.Largeur + ' × ' + e.Hauteur + (e.Principal ? ' (principal)' : ''); }).join(' + ');
  var sysIcons = I.Bureau && I.Bureau.IconesSysteme ? Object.keys(I.Bureau.IconesSysteme).filter(function (k) { return I.Bureau.IconesSysteme[k]; }) : [];
  views.bureau = vh('Bureau et apparence', 'Fond d\'écran, couleurs, écrans et contenu du Bureau.', '🎨', 'Bureau et apparence') +
    '<div class="cols">' +
    panel('Fond d\'écran', (X.apercu ? '<figure class="fig" style="margin-bottom:12px"><img src="' + esc(X.apercu) + '" data-zoom="' + esc(X.apercu) + '" alt="Fond"></figure>' : '') +
      kv([['Image', val(fe.FichierCopie || (fe.Chemin ? fe.Chemin : 'Couleur unie'))], ['Ajustement', val(fe.Libelle)]])) +
    '<div class="stack">' +
    panel('Couleurs et thème', kv([['Mode Windows', esc(lab(lumi, th.SystemeClair, '1'))], ['Mode des applications', esc(lab(lumi, th.AppsClair, '1'))],
      ['Couleur d\'accentuation', val(th.Accent)], ['Transparence', esc(lab(onoff, th.Transparence, '1'))]])) +
    panel('Écrans et souris', kv([['Écrans', val(screens)], ['Mise à l\'échelle', I.DPI ? Math.round(I.DPI / 96 * 100) + ' %' : '100 %'],
      ['Vitesse du pointeur', val(so.Vitesse)], ['Boutons', so.BoutonsInverses == '1' ? 'Inversés (gaucher)' : 'Normal']])) +
    '</div></div><div style="height:16px"></div>' +
    panel('Contenu du Bureau', '<p class="note" style="margin-top:0">Icônes système affichées : ' + esc(sysIcons.join(', ') || 'aucune') + '</p>' + searchBox('tBur') + '<div style="height:10px"></div>' +
      table(['Élément', 'Type', 'Bureau'], items.map(function (i) { return [esc(i.Nom), esc(i.Type), i.Emplacement === 'Public' ? 'Tous les utilisateurs' : 'Personnel']; }), '', 'tBur'), plural(items.length, 'élément'));

  // ---- Barre des tâches
  var glom = { '0': 'Toujours regrouper', '1': 'Si la barre est pleine', '2': 'Jamais' }, search = { '0': 'Masquée', '1': 'Icône', '2': 'Zone de recherche', '3': 'Bouton' };
  var w11 = (+I.Systeme.Build) >= 22000;
  views.barre = vh('Barre des tâches et menu Démarrer', '', '📌', 'Barre des tâches') +
    panel('Applications épinglées dans la barre des tâches', chips(I.Epingles), plural(arr(I.Epingles).length, 'application')) +
    '<div class="cols">' +
    panel('Réglages de la barre', kv([['Alignement', w11 ? esc(lab({ '0': 'À gauche', '1': 'Centré' }, opt.TaskbarAl, '1')) : 'À gauche (Windows 10)'],
      ['Regroupement des boutons', esc(lab(glom, opt.TaskbarGlomLevel, '0'))], ['Recherche', esc(lab(search, opt.SearchboxTaskbarMode, '2'))],
      ['Bouton Affichage des tâches', esc(lab({ '0': 'Masqué', '1': 'Affiché' }, opt.ShowTaskViewButton, '1'))]])) +
    panel('Menu Démarrer', '<p class="note" style="margin-top:0">' + esc((I.MenuDemarrer && I.MenuDemarrer.Type) || 'Non relevé') + '</p>' + (arr(I.MenuDemarrer && I.MenuDemarrer.Epingles).length ? chips(I.MenuDemarrer.Epingles) : '<p class="mute">Disposition sauvegardée telle quelle.</p>')) +
    '</div><div style="height:16px"></div>' +
    panel('Explorateur de fichiers', kv([['Extensions des fichiers', esc(lab({ '0': 'Affichées', '1': 'Masquées' }, opt.HideFileExt, '1'))], ['Fichiers cachés', esc(lab({ '1': 'Affichés', '2': 'Masqués' }, opt.Hidden, '2'))],
      ['Ouverture sur', esc(lab({ '1': 'Ce PC', '2': 'Accès rapide / Accueil', '3': 'Téléchargements', '4': 'OneDrive' }, opt.LaunchTo, '2'))], ['Dossiers épinglés (Accès rapide)', I.AccesRapide ? 'Sauvegardés' : 'Aucun']]));

  // ---- Impression & lecteurs
  views.impression = vh('Imprimantes et lecteurs réseau', '', '🖨️', 'Imprimantes et lecteurs') +
    panel('Imprimantes', table(['Imprimante', 'Type', 'Pilote'], printers.map(function (p) {
      return [esc(p.Nom) + (p.Nom === I.ImprimanteDefaut ? ' <span class="pill ok">par défaut</span>' : ''), p.Virtuelle ? 'Virtuelle' : (p.Reseau ? 'Partagée (serveur)' : '<span class="pill warn">Locale / IP</span>'), esc(p.Pilote)];
    })), plural(printers.length, 'imprimante')) +
    panel('Lecteurs réseau', table(['Lecteur', 'Chemin réseau'], drives.map(function (d) { return ['<b>' + esc(d.Lettre) + ':</b>', esc(d.Chemin)]; })), plural(drives.length, 'lecteur'));

  // ---- Navigateurs
  var startLbl = function (n) { return n.Demarrage ? esc(n.Demarrage) + (arr(n.PagesDemarrage).length ? '<div class="note">' + arr(n.PagesDemarrage).map(esc).join('<br>') + '</div>' : '') : '<span class="mute">Par défaut</span>'; };
  views.navigateurs = vh('Navigateurs internet', 'Favoris et réglages transférés ; les mots de passe enregistrés sont à transférer séparément.', '🌐', 'Navigateurs') +
    (navs.length ? navs.map(function (n) {
      var ex = arr(n.Extensions);
      return panel(esc(n.Navigateur) + ' · ' + esc(n.NomAffiche || n.Profil), kv([['Favoris', num(n.Favoris)], ['Page d\'accueil', val(n.PageAccueil)], ['Au démarrage', startLbl(n)],
        ['Barre des favoris', n.BarreFavoris ? 'Affichée' : 'Masquée'], ['Extensions', ex.length ? chips(ex.map(function (e) { return e.Nom || e.Id; })) : '<span class="mute">Aucune</span>']]));
    }).join('') : '<p class="mute">Aucun profil Edge ou Chrome trouvé.</p>') +
    (arr(I.Firefox).length ? '<div class="alert"><span>🦊</span><div>Firefox est utilisé (' + esc(arr(I.Firefox).join(', ')) + ') : à transférer via Firefox Sync.</div></div>' : '');

  // ---- Office
  var of = I.Office || {};
  views.office = vh('Outlook, Office et Teams', '', '✉️', 'Outlook et Office') +
    '<div class="cols">' +
    panel('Signatures Outlook', chips(of.Signatures) + (arr(of.SignatureDefaut).length ? '<div style="height:10px"></div>' + table(['Compte', 'Nouveaux messages', 'Réponses'], arr(of.SignatureDefaut).map(function (s) { return [esc(s.Compte), val(s.Nouveau), val(s.Reponse)]; })) : ''), plural(arr(of.Signatures).length, 'signature')) +
    panel('Modèles et dictionnaires', chips(arr(of.Modeles).concat(arr(of.Dictionnaires)))) +
    '</div><div style="height:16px"></div>' +
    panel('Fichiers PST (archives Outlook)', table(['Fichier', '#Taille'], arr(of.PST).map(function (p) { return [esc(p.Chemin), size(p.Octets)]; })), plural(arr(of.PST).length, 'fichier')) +
    panel('Divers', kv([['Arrière-plans Teams', num(arr(of.FondsTeams).length)], ['Polices personnelles', arr(of.Polices).length ? chips(of.Polices) : 'Aucune'], ['Pense-bêtes', of.PenseBetes ? 'Utilisés' : 'Non']]));

  // ---- OneDrive
  if (od.length || arr(I.OneDrive).length) {
    var kfm = dossiers.filter(function (d) { return ['Bureau', 'Documents', 'Images'].indexOf(d.Cle) >= 0 && d.Emplacement === 'OneDrive'; }).map(function (d) { return d.Libelle; });
    views.onedrive = vh('OneDrive et SharePoint', 'Comptes connectés et dossiers synchronisés.', '☁️', 'OneDrive') +
      panel('Dossiers synchronisés', table(['Type', 'Dossier', 'Compte'], od.map(function (o) { return [o.Type === 'OneDrive' ? 'OneDrive personnel' : 'Bibliothèque SharePoint / Teams', esc(o.Nom), esc(o.Compte)]; })), plural(od.length, 'dossier')) +
      panel('Sauvegarde des dossiers dans OneDrive', kfm.length ? chips(kfm) : '<p class="mute">Aucun dossier (Bureau, Documents, Images) sauvegardé dans OneDrive.</p>');
  }

  // ---- Fichiers
  views.fichiers = vh('Vos fichiers', plural(X.totalFichiers, 'fichier') + ' · ' + size(X.totalOctets) + ' — chaque fichier est listé pour être recompté sur le nouveau poste.', '📁', 'Fichiers') +
    panel('Par dossier', table(['Dossier', 'Emplacement', '#Fichiers', '#Taille', '#En ligne uniquement'], dossiers.map(function (d) {
      return [esc(d.Libelle), esc(d.Emplacement || '—'), num(d.Fichiers), size(d.Octets), num(d.EnLigneSeul)];
    }))) +
    (arr(I.HorsProfil).length ? panel('Données hors du profil', '<p class="note" style="margin-top:0">Ces dossiers ne sont ni copiés ni comparés automatiquement : à confirmer avec l\'utilisateur.</p>' +
      table(['Dossier', 'Modifié le'], arr(I.HorsProfil).map(function (h) { return [esc(h.Chemin), esc(h.Modifie)]; }))) : '');

  // ---- Logiciels
  views.logiciels = vh('Logiciels installés', plural(apps.length, 'logiciel'), '🧩', 'Logiciels') +
    panel('', searchBox('tApps', 'Rechercher un logiciel…') + '<div style="height:10px"></div>' + table(['Logiciel', 'Version', 'Éditeur'], apps.map(function (a) { return [esc(a.Nom), esc(a.Version), esc(a.Editeur)]; }), '', 'tApps')) +
    '<div class="cols">' + panel('Lancés au démarrage', chips(I.Demarrage)) + panel('Applications du Microsoft Store', chips(I.ApplisStore)) + '</div>';

  // ---- Accès
  var certs = arr(I.Certificats);
  views.acces = vh('Accès et sécurité', '', '🔐', 'Accès et sécurité') +
    panel('Certificats personnels', table(['Certificat', 'Émetteur', 'Expire le', 'Clé privée'], certs.map(function (c) {
      return [esc(String(c.Sujet).split(',')[0].replace(/^\s*(CN|E|OU|O)=/, '')), esc(String(c.Emetteur).split(',')[0].replace(/^\s*(CN|E|OU|O)=/, '')), esc(c.Expire) + (c.Expire_ ? ' <span class="pill info">expiré</span>' : ''), c.ClePrivee ? '<span class="pill warn">Oui</span>' : 'Non'];
    })), plural(certs.length, 'certificat')) +
    '<div class="cols">' + panel('Réseaux Wi-Fi enregistrés', chips(I.Wifi)) + panel('Identifiants enregistrés', chips(I.Identifiants)) + '</div><div style="height:16px"></div>' +
    panel('Langue et région', kv([['Langues', esc(arr(I.Langues).map(function (l) { return l.Langue; }).join(', '))], ['Claviers', esc(arr(I.Langues).map(function (l) { return l.Claviers; }).join(' | '))], ['Format régional', val(I.Region)], ['Mode d\'alimentation', val(I.PlanAlimentation)]]));

  var nav = [{ id: 'synthese', label: 'Synthèse', icon: '🏠' }, { id: 'preparation', label: 'Préparation', icon: '🧳', badge: todoN || '✓', badgeCls: todoN ? 'warn' : 'ok', badgeId: 'navPrep' }, { id: 'attention', label: 'Points d\'attention', icon: '⚠️', badge: alertes.length || '✓', badgeCls: alertes.length ? 'warn' : 'ok' },
    { grp: 'Environnement' }, { id: 'bureau', label: 'Bureau et apparence', icon: '🎨' }, { id: 'barre', label: 'Barre des tâches', icon: '📌' },
    { id: 'impression', label: 'Imprimantes et lecteurs', icon: '🖨️' }, { id: 'navigateurs', label: 'Navigateurs', icon: '🌐' }, { id: 'office', label: 'Outlook et Office', icon: '✉️' }];
  if (views.onedrive) { nav.push({ id: 'onedrive', label: 'OneDrive et SharePoint', icon: '☁️' }); }
  nav.push({ grp: 'Données' }, { id: 'fichiers', label: 'Fichiers', icon: '📁', badge: num(X.totalFichiers) }, { id: 'logiciels', label: 'Logiciels', icon: '🧩', badge: apps.length }, { id: 'acces', label: 'Accès et sécurité', icon: '🔐' });
  shell({ brand: 'Inventaire du poste', title: X.who, sub: I.Meta.Ordinateur + ' · ' + I.Meta.Date, nav: nav, views: views, foot: '<small>Durée du relevé : ' + esc(X.duree) + '</small>' });
  var pboxes = document.querySelectorAll('input[data-p]');
  function pupd() {
    var n = 0;
    [].forEach.call(pboxes, function (b) { if (b.checked) { n++; } b.closest('.item').classList.toggle('done', b.checked); });
    var t = document.getElementById('prepTxt'); if (t) { t.textContent = n + ' / ' + pboxes.length + ' étapes faites'; }
    var br = document.getElementById('prepBar'); if (br) { br.style.width = (pboxes.length ? n * 100 / pboxes.length : 100) + '%'; }
    var nb = document.getElementById('navPrep'); if (nb) { var r = pboxes.length - n; nb.textContent = r || '✓'; nb.className = 'badge ' + (r ? 'warn' : 'ok'); }
  }
  [].forEach.call(pboxes, function (b) {
    if (pdone[b.getAttribute('data-p')]) { b.checked = true; }
    b.addEventListener('change', function () { pdone[b.getAttribute('data-p')] = b.checked; try { localStorage.setItem(pstore, JSON.stringify(pdone)); } catch (e) { } pupd(); });
  });
  pupd();
}

if (D.type === 'migration') { migration(); } else { inventaire(); }
})();
'@
function Write-Report($path, $title, $data) {
  $json = ($data | ConvertTo-Json -Depth 10 -Compress) -replace '</', '<\/'
  $t = [System.Net.WebUtility]::HtmlEncode($title)
  $html = "<!doctype html>`n<html lang=`"fr`"><head><meta charset=`"utf-8`"><meta name=`"viewport`" content=`"width=device-width,initial-scale=1`"><title>$t</title><style>`n$($script:UiCss)`n</style></head>`n<body><div id=`"app`"></div>`n<script type=`"application/json`" id=`"data`">$json</script>`n<script>`n$($script:UiJs)`n</script></body></html>"
  [IO.File]::WriteAllText($path, $html, (New-Object System.Text.UTF8Encoding $true))
}
function Go($bytes) { $b = [double]$bytes; if ($b -ge 1GB) { '{0:N2} Go' -f ($b / 1GB) } elseif ($b -ge 1MB) { '{0:N0} Mo' -f ($b / 1MB) } else { '{0:N0} Ko' -f [math]::Ceiling($b / 1KB) } }
function Mo($bytes) { '{0:N0} Mo' -f ([double]$bytes / 1MB) }

# ============================================================== Collecte
$inv = [ordered]@{}
Log "Inventaire de $env:USERDOMAIN\$env:USERNAME sur $env:COMPUTERNAME"

# --- Nom complet (annuaire, 5 s max)
$nomComplet = $env:USERNAME
try {
  $s = [adsisearcher]"(sAMAccountName=$env:USERNAME)"
  $s.ClientTimeout = [TimeSpan]::FromSeconds(5); $s.ServerTimeLimit = [TimeSpan]::FromSeconds(5)
  $r = $s.FindOne(); if ($r -and $r.Properties.displayname) { $nomComplet = [string]$r.Properties.displayname[0] }
} catch { }

$inv.Meta = [ordered]@{
  VersionInventaire = 2
  Date        = $debut.ToString('dd/MM/yyyy HH:mm')
  Ordinateur  = $env:COMPUTERNAME
  Utilisateur = $env:USERNAME
  Domaine     = $env:USERDOMAIN
  NomComplet  = $nomComplet
  Profil      = $env:USERPROFILE
}

# ---------------------------------------------------------------- 1. Capture
$inv.Capture = Capture-Bureau (Join-Path $root 'capture_bureau.png')

# ---------------------------------------------------------------- 2. Système & affichage
$sys = New-Sub 'systeme'
$os = Get-CimInstance Win32_OperatingSystem; $cs = Get-CimInstance Win32_ComputerSystem
$inv.Systeme = [ordered]@{
  OS = [string]$os.Caption; Version = [string]$os.Version; Build = [int]$os.BuildNumber
  Architecture = [string]$os.OSArchitecture; Fabricant = [string]$cs.Manufacturer; Modele = [string]$cs.Model
}
$win11 = $inv.Systeme.Build -ge 22000
$inv.Ecrans = @([System.Windows.Forms.Screen]::AllScreens | ForEach-Object {
  [ordered]@{ Nom = $_.DeviceName; Principal = [bool]$_.Primary; Largeur = $_.Bounds.Width; Hauteur = $_.Bounds.Height; X = $_.Bounds.X; Y = $_.Bounds.Y }
})
$inv.DPI = RegVal 'HKCU:\Control Panel\Desktop\WindowMetrics' 'AppliedDPI'
RegExp 'HKCU\Control Panel\Desktop\PerMonitorSettings' 'echelle_par_ecran'
$inv.Langues = @(Get-WinUserLanguageList | ForEach-Object { [ordered]@{ Langue = $_.LanguageTag; Claviers = (@($_.InputMethodTips) -join ', ') } })
$inv.Region  = (Get-Culture).Name
$plan = (powercfg /getactivescheme) -join ' '
$inv.PlanAlimentation = if ($plan -match '\((.+)\)') { $Matches[1] } else { $plan }
gpresult /h "$sys\gpresult.html" /f 2>$null | Out-Null
Log "Système / affichage OK"
if (-not $win11) { Alerte "Ancien poste en Windows 10 : le menu Démarrer ne peut pas être transféré tel quel vers Windows 11 (épingles listées ci-dessous, à refaire à la main)." }

# ---------------------------------------------------------------- 3. Fond d'écran, thème, souris
$wp = New-Sub 'fond_ecran_theme'
$desk = Get-ItemProperty 'HKCU:\Control Panel\Desktop'
$styles = @{ '10' = 'Remplir'; '6' = 'Ajuster'; '2' = 'Étirer'; '0' = 'Centrer'; '22' = 'Étendre sur les écrans' }
$styleLib = $styles[[string]$desk.WallpaperStyle]
if ([string]$desk.WallpaperStyle -eq '0' -and [string]$desk.TileWallpaper -eq '1') { $styleLib = 'Mosaïque' }
$copie = $null
if ($desk.WallPaper -and (Test-Path $desk.WallPaper -PathType Leaf)) {
  if (CopySafe $desk.WallPaper $wp) { $copie = Split-Path $desk.WallPaper -Leaf }
}
CopySafe "$env:APPDATA\Microsoft\Windows\Themes" $wp | Out-Null
$apercu = $null
$srcImg = if ($copie) { Join-Path $wp $copie } else { Join-Path $wp 'Themes\TranscodedWallpaper' }
if (Test-Path $srcImg) {
  $ext = [IO.Path]::GetExtension($srcImg); if (-not $ext) { $ext = '.jpg' }
  $apercu = "apercu_fond$ext"
  Copy-Item $srcImg (Join-Path $wp $apercu) -Force
}
$inv.FondEcran = [ordered]@{
  Chemin = [string]$desk.WallPaper; Style = [string]$desk.WallpaperStyle; Mosaique = [string]$desk.TileWallpaper
  Libelle = $styleLib; FichierCopie = $copie; Apercu = $apercu
  CouleurUnie = RegVal 'HKCU:\Control Panel\Colors' 'Background'
}
if (-not $desk.WallPaper) { Alerte "Pas d'image de fond : couleur unie ou diaporama/Spotlight (à vérifier dans Paramètres > Personnalisation)." }
$pz = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
$inv.Theme = [ordered]@{
  AppsClair = RegVal $pz 'AppsUseLightTheme'; SystemeClair = RegVal $pz 'SystemUsesLightTheme'
  Transparence = RegVal $pz 'EnableTransparency'; CouleurBarres = RegVal $pz 'ColorPrevalence'
  Accent = AccentHex (RegVal 'HKCU:\Software\Microsoft\Windows\DWM' 'AccentColor')
  AccentTitres = RegVal 'HKCU:\Software\Microsoft\Windows\DWM' 'ColorPrevalence'
}
$inv.Souris = [ordered]@{
  Vitesse = RegVal 'HKCU:\Control Panel\Mouse' 'MouseSensitivity'
  DoubleClic = RegVal 'HKCU:\Control Panel\Mouse' 'DoubleClickSpeed'
  BoutonsInverses = RegVal 'HKCU:\Control Panel\Mouse' 'SwapMouseButtons'
}
RegExp 'HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'theme_clair_sombre'
RegExp 'HKCU\Software\Microsoft\Windows\DWM' 'couleur_accentuation'
RegExp 'HKCU\Control Panel\Desktop' 'panneau_bureau'
RegExp 'HKCU\Control Panel\Mouse' 'souris'

# ---------------------------------------------------------------- 4. Bureau
$bur = New-Sub 'bureau'
$desktopPath = [Environment]::GetFolderPath('Desktop')
$publicDesk  = [Environment]::GetFolderPath('CommonDesktopDirectory')
$wsh = New-Object -ComObject WScript.Shell
$items = @()
foreach ($pair in @(@('Utilisateur', $desktopPath), @('Public', $publicDesk))) {
  if (-not $pair[1] -or -not (Test-Path -LiteralPath $pair[1])) { continue }
  Get-ChildItem $pair[1] -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'desktop.ini' } | ForEach-Object {
    $cible = ''
    if ($_.Extension -eq '.lnk') { try { $cible = $wsh.CreateShortcut($_.FullName).TargetPath } catch { } }
    $type = if ($_.PSIsContainer) { 'Dossier' } elseif ($_.Extension -in '.lnk','.url') { 'Raccourci' } else { 'Fichier' }
    $items += [ordered]@{ Emplacement = $pair[0]; Nom = $_.Name; Type = $type; Cible = $cible }
  }
}
$raccourcis = New-Sub 'bureau\raccourcis'
Get-ChildItem $desktopPath -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.lnk','.url' } |
  Copy-Item -Destination $raccourcis -Force
$bagK = 'HKCU:\Software\Microsoft\Windows\Shell\Bags\1\Desktop'
$inv.Bureau = [ordered]@{
  Chemin = $desktopPath; OneDrive = ($desktopPath -like '*OneDrive*')
  Elements = $items
  FFlags = RegVal $bagK 'FFlags'; IconSize = RegVal $bagK 'IconSize'
  IconesSysteme = Get-SysIcons
}
RegExp 'HKCU\Software\Microsoft\Windows\Shell\Bags\1\Desktop' 'bureau_disposition_icones'
RegExp 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons' 'bureau_icones_systeme'
if ($inv.Bureau.OneDrive) { Alerte "Le Bureau est synchronisé dans OneDrive : il reviendra via OneDrive, ne pas le recopier par-dessus (doublons)." }
Log "Bureau OK ($($items.Count) éléments)"

# ---------------------------------------------------------------- 5. Barre des tâches, menu Démarrer, Explorateur
$tb = New-Sub 'barre_taches_demarrer'
$pinDir = "$env:APPDATA\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar"
CopySafe $pinDir $tb | Out-Null
$inv.Epingles = @(Get-ChildItem $pinDir -File -Filter *.lnk -ErrorAction SilentlyContinue | ForEach-Object { $_.BaseName })
RegExp 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband' 'barre_taches'
RegExp 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'explorateur_options'
RegExp 'HKCU\Software\Microsoft\Windows\CurrentVersion\Search' 'recherche_barre_taches'
$adv = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
$opts = [ordered]@{}
foreach ($n in 'HideFileExt','Hidden','ShowSuperHidden','LaunchTo','NavPaneShowAllFolders','TaskbarAl','TaskbarGlomLevel','TaskbarSmallIcons','TaskbarSi','ShowTaskViewButton','ShowSecondsInSystemClock') {
  $opts[$n] = RegVal $adv $n
}
$opts['SearchboxTaskbarMode'] = RegVal 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'SearchboxTaskbarMode'
$inv.Options = $opts

$start = [ordered]@{ Type = ''; Epingles = @() }
if ($win11) {
  $sd = "$env:LOCALAPPDATA\Packages\Microsoft.Windows.StartMenuExperienceHost_cw5n1h2txyewy\LocalState"
  CopySafe $sd "$tb\StartMenu_LocalState" | Out-Null
  $start.Type = 'Windows 11 (start.bin)'
} else {
  try {
    Export-StartLayout -Path "$tb\start_layout_win10.xml"
    $x = Get-Content "$tb\start_layout_win10.xml" -Raw
    $pins = @()
    $pins += [regex]::Matches($x, 'DesktopApplicationLinkPath="([^"]+)"') | ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_.Groups[1].Value) }
    $pins += [regex]::Matches($x, 'AppUserModelID="([^"]+)"') | ForEach-Object { ($_.Groups[1].Value -split '!')[0] -replace '_[a-z0-9]{13}$','' }
    $start.Type = 'Windows 10 (vignettes)'; $start.Epingles = @($pins | Select-Object -Unique)
    Log "Export-StartLayout OK"
  } catch { Log "Export-StartLayout échoué : $_" }
}
$inv.MenuDemarrer = $start
$inv.AccesRapide = CopySafe "$env:APPDATA\Microsoft\Windows\Recent\AutomaticDestinations\f01b4d95cf55d32a.automaticDestinations-ms" "$tb\acces_rapide.automaticDestinations-ms"
RegExp 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' 'dossiers_utilisateur_redirections'
RegExp 'HKCU\Software\Microsoft\OneDrive\Accounts' 'onedrive_comptes'
$inv.OneDrive = @(Get-ChildItem 'HKCU:\Software\Microsoft\OneDrive\Accounts' -ErrorAction SilentlyContinue | ForEach-Object {
  $p = Get-ItemProperty $_.PSPath
  if ($p.UserEmail) { [ordered]@{ Compte = [string]$p.UserEmail; Dossier = [string]$p.UserFolder } }
})
$odMounts = @(Get-OneDriveMounts)
$inv.OneDriveMontages = $odMounts
$inv.OneDriveActif = [bool](Get-Process OneDrive -ErrorAction SilentlyContinue)
if ($odMounts.Count) {
  Alerte "OneDrive : avant d'éteindre l'ancien poste, vérifier que l'icône OneDrive indique « à jour » (aucun fichier en attente d'envoi), sinon les dernières modifications seraient perdues."
  $libs = @($odMounts | Where-Object { $_.Type -ne 'OneDrive' })
  if ($libs.Count) { Alerte "$($libs.Count) bibliothèque(s) SharePoint / Teams synchronisée(s), à resynchroniser sur le nouveau poste : $(($libs | ForEach-Object { $_.Nom }) -join ', ')." }
}

# ---------------------------------------------------------------- 6. Lecteurs réseau & imprimantes
RegExp 'HKCU\Network' 'lecteurs_reseau'
$drives = [ordered]@{}
Get-CimInstance Win32_MappedLogicalDisk -ErrorAction SilentlyContinue | ForEach-Object {
  $l = $_.Name.TrimEnd(':'); $drives[$l] = [ordered]@{ Lettre = $l; Chemin = [string]$_.ProviderName; Persistant = $false }
}
Get-ChildItem 'HKCU:\Network' -ErrorAction SilentlyContinue | ForEach-Object {
  $l = $_.PSChildName; $rp = (Get-ItemProperty $_.PSPath).RemotePath
  if ($drives.Contains($l)) { $drives[$l].Persistant = $true }
  else { $drives[$l] = [ordered]@{ Lettre = $l; Chemin = [string]$rp; Persistant = $true } }
}
$inv.Lecteurs = @($drives.Values)
$inv.Imprimantes = @(Get-Printer -ErrorAction SilentlyContinue | ForEach-Object {
  [ordered]@{ Nom = $_.Name; Pilote = [string]$_.DriverName; Port = [string]$_.PortName; Type = [string]$_.Type
              Reseau = ($_.Name -like '\\*'); Virtuelle = (Is-Virtual $_.Name) }
})
$inv.ImprimanteDefaut = [string](Get-CimInstance Win32_Printer -Filter 'Default=TRUE' -ErrorAction SilentlyContinue).Name
$locales = @($inv.Imprimantes | Where-Object { -not $_.Reseau -and -not $_.Virtuelle })
if ($locales.Count) { Alerte "$($locales.Count) imprimante(s) locale(s)/IP : pilote et droits admin nécessaires sur le nouveau poste ($(($locales | ForEach-Object { $_.Nom }) -join ', '))." }

# ---------------------------------------------------------------- 7. Applications
$app = New-Sub 'applications'
$inv.Logiciels = @(Get-Apps)
$inv.ApplisStore = @(Get-AppxPackage -ErrorAction SilentlyContinue | Where-Object { -not $_.IsFramework -and $_.SignatureKind -eq 'Store' } | ForEach-Object { $_.Name })
$inv.Demarrage = @(Get-CimInstance Win32_StartupCommand -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.Name } | Select-Object -Unique)
if (Get-Command winget -ErrorAction SilentlyContinue) { winget export -o "$app\winget.json" --accept-source-agreements 2>$null | Out-Null }
Log "Applications OK ($($inv.Logiciels.Count))"

# ---------------------------------------------------------------- 8. Navigateurs
$nav = New-Sub 'navigateurs'
$restoreLib = @{ '1' = 'Restaurer la session précédente'; '4' = 'Ouvrir des pages spécifiques'; '5' = 'Nouvel onglet' }
$browsers = [ordered]@{ 'Edge' = "$env:LOCALAPPDATA\Microsoft\Edge\User Data"; 'Chrome' = "$env:LOCALAPPDATA\Google\Chrome\User Data" }
$navs = @()
foreach ($b in $browsers.Keys) {
  $ud = $browsers[$b]
  if (-not (Test-Path $ud)) { continue }
  $names = @{}
  try {
    $ls = Get-Content (Join-Path $ud 'Local State') -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($p in $ls.profile.info_cache.PSObject.Properties) { $names[$p.Name] = [string]$p.Value.name }
  } catch { }
  Get-ChildItem $ud -Directory | Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' } | ForEach-Object {
    $d = Join-Path $nav "$b\$($_.Name)"; New-Item $d -ItemType Directory -Force | Out-Null
    CopySafe (Join-Path $_.FullName 'Bookmarks') $d | Out-Null
    CopySafe (Join-Path $_.FullName 'Preferences') $d | Out-Null
    $exts = @()
    $extRoot = Join-Path $_.FullName 'Extensions'
    if (Test-Path $extRoot) {
      Get-ChildItem $extRoot -Directory | Where-Object { $_.Name -ne 'Temp' } | ForEach-Object {
        $exts += [ordered]@{ Id = $_.Name; Nom = (Get-ExtName $_.FullName) }
      }
    }
    $home_ = ''; $mode = ''; $urls = @(); $bar = $null
    try {
      $pj = Get-Content (Join-Path $_.FullName 'Preferences') -Raw -Encoding UTF8 | ConvertFrom-Json
      $home_ = [string]$pj.homepage; $mode = $restoreLib[[string]$pj.session.restore_on_startup]
      $urls = @($pj.session.startup_urls); $bar = $pj.bookmark_bar.show_on_all_tabs
    } catch { }
    $navs += [ordered]@{
      Navigateur = $b; Profil = $_.Name; NomAffiche = $names[$_.Name]
      Favoris = Get-BookmarkCount (Join-Path $_.FullName 'Bookmarks')
      Extensions = $exts; PageAccueil = $home_; Demarrage = $mode; PagesDemarrage = $urls; BarreFavoris = $bar
    }
  }
}
$inv.Navigateurs = $navs
$inv.Firefox = @()
if (Test-Path "$env:APPDATA\Mozilla\Firefox\Profiles") {
  $inv.Firefox = @((Get-ChildItem "$env:APPDATA\Mozilla\Firefox\Profiles" -Directory).Name)
  Alerte "Firefox utilisé : favoris et mots de passe à transférer via Firefox Sync ou export manuel."
}
if ($navs.Count) { Alerte "Mots de passe enregistrés dans les navigateurs : non exportés par sécurité (synchronisation du compte ou export/import CSV à faire)." }

# ---------------------------------------------------------------- 9. Office / Outlook / Teams / divers
$off = New-Sub 'office'
CopySafe "$env:APPDATA\Microsoft\Signatures" $off | Out-Null
CopySafe "$env:APPDATA\Microsoft\Templates"  $off | Out-Null
CopySafe "$env:APPDATA\Microsoft\UProof"     $off | Out-Null
Get-ChildItem "$env:APPDATA\Microsoft\Office" -Filter *.acl -ErrorAction SilentlyContinue | Copy-Item -Destination $off -Force
$pst = @(Get-FilesSafe $env:USERPROFILE '*.pst' |
         ForEach-Object { [ordered]@{ Chemin = $_.FullName; Octets = $_.Length } })
CopySafe "$env:LOCALAPPDATA\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\Backgrounds\Uploads" "$off\teams_arriere_plans" | Out-Null
$penseBetes = CopySafe "$env:LOCALAPPDATA\Packages\Microsoft.MicrosoftStickyNotes_8wekyb3d8bbwe\LocalState" "$off\pense_betes"
CopySafe "$env:LOCALAPPDATA\Microsoft\Windows\Fonts" "$off\polices_utilisateur" | Out-Null
$inv.Office = [ordered]@{
  Signatures      = @(Get-ChildItem "$env:APPDATA\Microsoft\Signatures" -Filter *.htm -ErrorAction SilentlyContinue | ForEach-Object { $_.BaseName })
  SignatureDefaut = @(Get-OutlookDefaultSig)
  Modeles         = @(Get-FilesSafe "$env:APPDATA\Microsoft\Templates" | ForEach-Object { $_.Name })
  Dictionnaires   = @(Get-ChildItem "$env:APPDATA\Microsoft\UProof" -Filter *.dic -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
  ProfilsOutlook  = @(Get-ChildItem 'HKCU:\Software\Microsoft\Office\16.0\Outlook\Profiles' -ErrorAction SilentlyContinue | ForEach-Object { $_.PSChildName })
  PST             = $pst
  FondsTeams      = @(Get-ChildItem "$off\teams_arriere_plans" -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '*_thumb*' } | ForEach-Object { $_.Name })
  PenseBetes      = [bool]$penseBetes
  Polices         = @(Get-ChildItem "$env:LOCALAPPDATA\Microsoft\Windows\Fonts" -File -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
}
if ($pst.Count) { Alerte "$($pst.Count) fichier(s) PST ($(Go (($pst | ForEach-Object { $_.Octets } | Measure-Object -Sum).Sum))) : à copier puis rattacher dans Outlook, Outlook fermé." }

# ---------------------------------------------------------------- 10. Sécurité & accès
$inv.Certificats = @(Get-ChildItem Cert:\CurrentUser\My -ErrorAction SilentlyContinue | ForEach-Object {
  [ordered]@{ Sujet = $_.Subject; Emetteur = $_.Issuer; Expire = $_.NotAfter.ToString('dd/MM/yyyy'); ClePrivee = [bool]$_.HasPrivateKey; Empreinte = $_.Thumbprint
              Expire_ = ($_.NotAfter -lt (Get-Date)) }
})
$certPk = @($inv.Certificats | Where-Object { $_.ClePrivee -and -not $_.Expire_ -and $_.Emetteur -notmatch 'MS-Organization|Microsoft Intune|Token Signing' })
if ($certPk.Count) { Alerte "$($certPk.Count) certificat(s) personnel(s) avec clé privée (signature, impôts, banque...) : export .pfx à faire avec l'accord de l'utilisateur." }
$inv.Wifi = Get-WifiNames
$inv.Identifiants = Get-CredTargets

# ---------------------------------------------------------------- 11. Dossiers & manifeste des fichiers
$manifest = Join-Path $root 'fichiers_manifeste.csv'
$folders = Get-KnownFolders
$libelles = @{ 'Bureau' = 'Bureau'; 'Documents' = 'Documents'; 'Images' = 'Images'; 'Musique' = 'Musique'; 'Videos' = 'Vidéos'; 'Telechargements' = 'Téléchargements' }
$odRoots = @($odMounts | ForEach-Object { $_.Chemin.TrimEnd('\') + '\' })
function Get-Loc($p) {
  if (-not $p) { return '' }
  if ($p -like '\\*') { return 'Serveur (redirection)' }
  if (Is-Excluded ($p.TrimEnd('\') + '\') $odRoots) { return 'OneDrive' }
  if ($p -like '*OneDrive*') { return 'OneDrive' }
  'Local'
}
# Liste des dossiers à inventorier : dossiers connus + racine OneDrive + bibliothèques synchronisées
$scan = @()
foreach ($k in $folders.Keys) { $scan += [pscustomobject]@{ Cle = $k; Libelle = $libelles[$k]; Chemin = $folders[$k]; Emplacement = (Get-Loc $folders[$k]) } }
foreach ($m in $odMounts) {
  if ($scan | Where-Object { $_.Chemin -and $_.Chemin.TrimEnd('\') -ieq $m.Chemin }) { continue }
  $lib = if ($m.Type -eq 'OneDrive') { "OneDrive ($($m.Compte))" } else { "SharePoint / Teams : $($m.Nom)" }
  $scan += [pscustomobject]@{ Cle = $m.Cle; Libelle = $lib; Chemin = $m.Chemin; Emplacement = $(if ($m.Type -eq 'OneDrive') { 'OneDrive' } else { 'SharePoint' }) }
}
$dossiers = @()
foreach ($s in $scan) {
  $p = $s.Chemin; $k = $s.Cle; $n = 0; $sum = [int64]0; $cloud = 0
  if ($p -and (Test-Path -LiteralPath $p)) {
    Log "Manifeste : $p"
    $pp = $p.TrimEnd('\') + '\'
    # sous-dossiers déjà inventoriés pour leur compte (ex. Bureau redirigé dans OneDrive) : exclus pour ne pas compter deux fois
    $excl = @($scan | Where-Object { $_.Chemin -and ($_.Chemin.TrimEnd('\') + '\') -ine $pp -and ($_.Chemin.TrimEnd('\') + '\').StartsWith($pp, [StringComparison]::OrdinalIgnoreCase) } |
              ForEach-Object { $_.Chemin.TrimEnd('\') + '\' })
    $base = $pp.Length
    Get-FilesSafe $p |
      Where-Object { $_.Name -ne 'desktop.ini' -and -not (Is-Excluded $_.FullName $excl) } | ForEach-Object {
        $n++; $sum += $_.Length
        $online = (([int]$_.Attributes -band 0x00400000) -ne 0) -or (([int]$_.Attributes -band 0x1000) -ne 0)
        if ($online) { $cloud++ }
        [pscustomobject]@{ Dossier = $k; Relatif = $_.FullName.Substring($base); Octets = $_.Length; Modifie = $_.LastWriteTime.ToString('s'); EnLigneSeul = $online }
      } | Export-Csv $manifest -Append -NoTypeInformation -Encoding UTF8 -Delimiter ';'
  }
  $dossiers += [ordered]@{ Cle = $k; Libelle = $s.Libelle; Chemin = $p; Fichiers = $n; Octets = $sum; EnLigneSeul = $cloud; Emplacement = $s.Emplacement }
  if ($s.Emplacement -eq 'Serveur (redirection)') { Alerte "Dossier $($s.Libelle) redirigé vers un serveur ($p) : il revient avec la GPO, rien à copier, mais l'accès dépend du réseau/VPN." }
}

# ---------------------------------------------------------------- 12. Données hors profil (C:\, autres disques)
$std = 'Windows','Program Files','Program Files (x86)','ProgramData','Users','PerfLogs','$Recycle.Bin','$WinREAgent','Recovery',
       'System Volume Information','Config.Msi','Documents and Settings','Intel','AMD','NVIDIA','Drivers','Dell','HP','Lenovo',
       'SWSetup','OneDriveTemp','inetpub','MSOCache','$SysReset','$Windows.~BT','$Windows.~WS','ESD','Temp','tmp','XboxGames','$GetCurrent'
$destRoot = [IO.Path]::GetPathRoot((Resolve-Path $Destination).Path)
$hors = @()
foreach ($d in @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue)) {
  $dr = "$($d.DeviceID)\"
  if ($dr -ieq $destRoot -and $d.DeviceID -ine $env:SystemDrive) { continue }   # disque de sauvegarde USB
  Get-ChildItem -LiteralPath $dr -Directory -Force -ErrorAction SilentlyContinue |
    Where-Object { $std -notcontains $_.Name -and -not ($_.Attributes -band [IO.FileAttributes]::System) -and
                   -not $root.StartsWith($_.FullName, [StringComparison]::OrdinalIgnoreCase) } |
    ForEach-Object { $hors += [ordered]@{ Chemin = $_.FullName; Modifie = $_.LastWriteTime.ToString('dd/MM/yyyy') } }
}
$inv.HorsProfil = $hors
if ($hors.Count) { Alerte "Dossiers hors du profil utilisateur (non pris en charge automatiquement) : $(($hors | ForEach-Object { $_.Chemin }) -join ', '). Vérifier avec l'utilisateur s'ils contiennent ses données." }
$inv.Dossiers = $dossiers
$totalFichiers = ($dossiers | ForEach-Object { $_.Fichiers } | Measure-Object -Sum).Sum
$totalOctets   = ($dossiers | ForEach-Object { $_.Octets }   | Measure-Object -Sum).Sum
$cloudTotal    = ($dossiers | ForEach-Object { $_.EnLigneSeul } | Measure-Object -Sum).Sum
if ($cloudTotal) { Alerte "$cloudTotal fichier(s) OneDrive « en ligne uniquement » : ils reviendront par OneDrive, inutile de les copier." }
Log "Manifeste OK ($totalFichiers fichiers, $(Go $totalOctets))"

# ---------------------------------------------------------------- 13. Plan de copie des données + script Copie-Donnees.ps1
$winName = @{ 'Bureau' = 'Desktop'; 'Documents' = 'Documents'; 'Images' = 'Pictures'; 'Musique' = 'Music'; 'Videos' = 'Videos'; 'Telechargements' = 'Downloads' }
$planDossiers = @($dossiers | Where-Object { $_.Emplacement -eq 'Local' -and $_.Fichiers -gt 0 -and $winName.ContainsKey($_.Cle) } | ForEach-Object {
  [ordered]@{ Cle = $_.Cle; Libelle = $_.Libelle; Source = $_.Chemin; Cible = $winName[$_.Cle]; Octets = [int64]$_.Octets }
})
# PST : seulement ceux qui ne sont ni dans un dossier déjà copié, ni dans OneDrive
$copiedRoots = @($planDossiers | ForEach-Object { $_.Source.TrimEnd('\') + '\' })
$planPst = @($pst | Where-Object { -not (Is-Excluded $_.Chemin $copiedRoots) -and -not (Is-Excluded $_.Chemin $odRoots) } | ForEach-Object {
  $par = Split-Path $_.Chemin -Parent
  $rel = if ($par.StartsWith($env:USERPROFILE, [StringComparison]::OrdinalIgnoreCase)) { $par.Substring($env:USERPROFILE.Length).TrimStart('\') } else { '_autres\' + ($par -replace ':', '') }
  [ordered]@{ Source = $_.Chemin; Cible = ('PST\' + $rel).TrimEnd('\'); Octets = [int64]$_.Octets }
})
$planHors = @($hors | ForEach-Object { [ordered]@{ Source = $_.Chemin; Cible = 'HorsProfil\' + ($_.Chemin -replace ':', '') } })
$inv.CopiePlan = [ordered]@{ Dossiers = $planDossiers; Pst = $planPst; Hors = $planHors }

function PsList($items, [string[]]$props) {
  if (-not @($items).Count) { return '' }
  (@($items) | ForEach-Object { $it = $_; '  [pscustomobject]@{ ' + (($props | ForEach-Object { "$_ = $(Q $it[$_])" }) -join '; ') + ' }' }) -join ",`r`n"
}
$copieScript = $script:CopieTpl.Replace('__DATE__', $debut.ToString('dd/MM/yyyy HH:mm')).Replace('__USER__', "$env:USERDOMAIN\$env:USERNAME").Replace('__RACINE__', (Q $root)).
  Replace('__DOSSIERS__', (PsList $planDossiers @('Cle', 'Libelle', 'Source', 'Cible', 'Octets'))).
  Replace('__PST__', (PsList $planPst @('Source', 'Cible', 'Octets'))).
  Replace('__HORS__', (PsList $planHors @('Source', 'Cible')))
$copiePath = Join-Path $root 'Copie-Donnees.ps1'
[IO.File]::WriteAllText($copiePath, $copieScript, (New-Object System.Text.UTF8Encoding $true))
Log "Script de copie généré : $copiePath"

# ---------------------------------------------------------------- 14. Check-list de préparation de l'ancien poste
$donnees = Join-Path $root 'Donnees'
$prep = New-Object System.Collections.Generic.List[object]
function Step($id, $titre, $texte, $etat, $acts = @()) { $prep.Add([ordered]@{ id = $id; titre = $titre; texte = $texte; etat = $etat; x = @($acts | Where-Object { $_ }) }) }
$runScript = { param($path) "& ([scriptblock]::Create([IO.File]::ReadAllText($(Q $path))))" }
$openDir = { param($dir) "New-Item -ItemType Directory -Path $(Q $dir) -Force | Out-Null; explorer.exe $(Q $dir)" }

$favN = ($navs | ForEach-Object { [math]::Max(0, $_.Favoris) } | Measure-Object -Sum).Sum
Step 'auto' 'Configuration sauvegardée par l''inventaire' ("Déjà fait : fond d'écran, disposition des icônes, barre des tâches, menu Démarrer, options de l'Explorateur, raccourcis du Bureau, favoris ($favN), signatures Outlook ($(@($inv.Office.Signatures).Count)), modèles Office, polices, imprimantes et lecteurs réseau. Restaure-Poste.ps1 les remettra en place.") 'auto'

$odStartCmd = '$o = @("$env:LOCALAPPDATA\Microsoft\OneDrive\OneDrive.exe", "$env:ProgramFiles\Microsoft OneDrive\OneDrive.exe", "${env:ProgramFiles(x86)}\Microsoft OneDrive\OneDrive.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1; if ($o) { Start-Process $o } else { Write-Host "OneDrive introuvable" }'
if ($odMounts.Count) {
  Step 'onedrive' 'Vérifier que OneDrive est « à jour »' "Icône nuage OneDrive (zone de notification) : elle doit indiquer « à jour », sans fichier en attente d'envoi. Sinon les dernières modifications seraient perdues en changeant de poste. Les dossiers synchronisés ($(($odMounts | ForEach-Object { $_.Nom }) -join ', ')) ne sont pas copiés : ils reviendront par OneDrive." 'todo' @((ACmd 'Copier la commande pour ouvrir OneDrive' $odStartCmd))
}

$closeCmd = "foreach (`$n in 'OUTLOOK', 'ms-teams', 'Teams', 'WINWORD', 'EXCEL', 'POWERPNT') { Get-Process `$n -ErrorAction SilentlyContinue | ForEach-Object { [void]`$_.CloseMainWindow() } }; Start-Sleep -Seconds 8; " +
            "`$r = @(Get-Process OUTLOOK, WINWORD, EXCEL, POWERPNT -ErrorAction SilentlyContinue); if (`$r.Count) { Write-Host ('Encore ouvert : ' + ((`$r | ForEach-Object { `$_.ProcessName }) -join ', ') + ' (enregistrer et fermer à la main)') -ForegroundColor Yellow } else { Write-Host 'Office et Teams sont fermés.' -ForegroundColor Green }"
Step 'office' 'Fermer Outlook, Office et Teams' "Indispensable avant la copie : un PST ou un document ouvert ne peut pas être copié correctement. L'action demande une fermeture normale (l'utilisateur peut enregistrer son travail)." $(if ($planPst.Count) { 'todo' } else { 'reco' }) @((ACmd 'Copier la commande de fermeture d''Outlook, Office et Teams' $closeCmd))

$volCopie = (($planDossiers | ForEach-Object { $_.Octets }) + ($planPst | ForEach-Object { $_.Octets }) | Measure-Object -Sum).Sum
try {
  $libreDest = (New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($root))).AvailableFreeSpace
  if ($volCopie -and $libreDest -lt [int64]($volCopie * 1.05)) { Alerte "Espace insuffisant sur $([IO.Path]::GetPathRoot($root)) pour la copie des données : $(Go $libreDest) libres pour $(Go $volCopie) à copier. Déplacer le dossier $root sur un support plus grand avant de lancer Copie-Donnees.ps1 (il fonctionne depuis son nouvel emplacement)." }
} catch { }
if ($planDossiers.Count -or $planPst.Count -or $planHors.Count) {
  $quoi = @()
  if ($planDossiers.Count) { $quoi += ($planDossiers | ForEach-Object { "$($_.Libelle) ($(Go $_.Octets))" }) -join ', ' }
  if ($planPst.Count) { $quoi += "$($planPst.Count) fichier(s) PST" }
  if ($planHors.Count) { $quoi += "dossiers hors profil : $(($planHors | ForEach-Object { $_.Source }) -join ', ')" }
  Step 'copie' 'Copier les données locales' ("À copier : $($quoi -join ' ; '). Total ≈ $(Go $volCopie) (hors dossiers hors profil). Destination : $donnees. Le script vérifie l'espace libre, copie avec robocopy (relançable sans tout recopier) puis contrôle chaque fichier à partir du manifeste.") 'todo' @(
    (ACmd 'Copier la commande de copie des données' (& $runScript $copiePath)),
    (ACmd 'Copier la commande pour ouvrir le dossier de copie' (& $openDir $donnees)))
} else {
  Step 'copie' 'Copier les données locales' "Rien à copier : les dossiers de l'utilisateur sont synchronisés par OneDrive ou redirigés sur un serveur." 'auto'
}

$pwdUrl = @{ 'Edge' = 'edge://settings/passwords'; 'Chrome' = 'chrome://password-manager/settings' }
$i = 0
foreach ($nv in $navs) {
  $i++
  $dir = Join-Path $donnees 'Navigateurs'
  Step "pwd$i" "Mots de passe $($nv.Navigateur) · $(if ($nv.NomAffiche) { $nv.NomAffiche } else { $nv.Profil })" ("Si l'utilisateur se connecte à son compte dans le navigateur (synchronisation), les mots de passe reviendront seuls : rien à faire. Sinon : ouvrir la page des mots de passe, « Exporter », enregistrer le fichier CSV dans $dir. Fichier sensible : il sera importé puis supprimé sur le nouveau poste.") 'reco' @(
    (ACopy "Copier l'adresse de la page des mots de passe" $pwdUrl[$nv.Navigateur] "Collez dans la barre d'adresse de $($nv.Navigateur) puis « Exporter les mots de passe »"),
    (ACmd 'Copier la commande pour ouvrir le dossier de destination' (& $openDir $dir)))
}
foreach ($f in @($inv.Firefox)) { Step "ff" 'Firefox' "Firefox est utilisé : vérifier que la synchronisation Firefox est active (compte Firefox), elle transférera favoris et mots de passe." 'reco' }

$i = 0
foreach ($c in $certPk) {
  $i++
  $cn = (([string]$c.Sujet -split ',')[0] -replace '^\s*(CN|E|OU|O)=', '')
  $pfx = Join-Path (Join-Path $donnees 'Certificats') "$($c.Empreinte).pfx"
  $cmd = "New-Item -ItemType Directory -Path $(Q (Split-Path $pfx -Parent)) -Force | Out-Null; `$pw = Read-Host 'Mot de passe de protection du fichier .pfx (à noter pour l''import)' -AsSecureString; " +
         "Export-PfxCertificate -Cert $(Q "Cert:\CurrentUser\My\$($c.Empreinte)") -FilePath $(Q $pfx) -Password `$pw -ChainOption BuildChain | Out-Null; Write-Host 'Certificat exporté : $($pfx -replace "'", "''")' -ForegroundColor Green"
  Step "cert$i" "Exporter le certificat « $cn »" "Certificat personnel avec clé privée (expire le $($c.Expire)) : signature, impôts, banque… À exporter avec l'accord de l'utilisateur. Si Windows refuse (« clé non exportable »), il faudra le redemander à l'émetteur." 'todo' @((ACmd 'Copier la commande d''export du certificat' $cmd))
}

if (@($inv.Wifi).Count) {
  $wdir = Join-Path $donnees 'Wifi'
  Step 'wifi' 'Exporter les réseaux Wi-Fi' ("$(@($inv.Wifi).Count) réseau(x) enregistré(s) : $(@($inv.Wifi) -join ', '). Exporte les profils avec leur clé (droits administrateur) pour que le nouveau poste s'y connecte sans redemander le mot de passe. Fichiers sensibles (mots de passe en clair) : supprimés après l'import.") 'reco' @(
    (ACmd 'Copier la commande d''export des réseaux Wi-Fi' "New-Item -ItemType Directory -Path $(Q $wdir) -Force | Out-Null; netsh wlan export profile key=clear folder=$(Q $wdir)" $true))
}

if (-not $win11) {
  Step 'start' 'Photographier le menu Démarrer' "Passage de Windows 10 à 11 : les vignettes du menu Démarrer ne se transfèrent pas. Prendre une photo du menu ouvert (épingles relevées : $(@($inv.MenuDemarrer.Epingles).Count))." 'todo'
}
Step 'licences' 'Relever les logiciels sous licence' "Repérer avec l'utilisateur les logiciels dont la licence est liée au poste (comptabilité, Adobe, logiciels métier) : il faudra les désactiver ici et les activer sur le nouveau poste." 'todo' @((ANav 'Voir la liste des logiciels' '#logiciels'))
Step 'transport' 'Transporter le dossier de migration' "Copier ou emporter le dossier complet $root (inventaire + Donnees) jusqu'au nouveau poste, puis lancer Restaure-Poste.ps1 avec -Source sur ce dossier. Garder l'ancien poste intact quelques semaines." 'todo' @((ACmd 'Copier la commande pour ouvrir le dossier de migration' "explorer.exe $(Q $root)"))

# Lanceur de corrections : rend les boutons « ▶ » de la page Préparation exécutables
$stampInv = '{0:yyyyMMdd_HHmm}' -f $debut
$launchActions = New-Object System.Collections.Generic.List[object]
$nAct = 0
foreach ($s in $prep) {
  foreach ($a in @($s.x)) {
    if ($a -and $a.t -eq 'cmd') { $nAct++; $a['id'] = "p$nAct"; $launchActions.Add([ordered]@{ id = "p$nAct"; label = "Préparation — $($s.titre)"; cmd = $a.c; adm = [bool]$a.adm }) }
  }
}
$launchOk = $false
if (-not $SansLanceur) { $launchOk = Install-Lanceur $stampInv $launchActions.ToArray() }

$inv.Alertes = @($script:alertes)
$inv | ConvertTo-Json -Depth 8 | Out-File (Join-Path $root 'inventaire.json') -Encoding UTF8
Log "inventaire.json écrit"

# ============================================================== Rapport HTML
$favTotal = ($navs | ForEach-Object { [math]::Max(0, $_.Favoris) } | Measure-Object -Sum).Sum
$who = if ($nomComplet -ne $env:USERNAME) { "$nomComplet ($env:USERDOMAIN\$env:USERNAME)" } else { "$env:USERDOMAIN\$env:USERNAME" }
$data = [ordered]@{
  type  = 'inventaire'
  inv   = $inv
  prep  = $prep.ToArray()
  launch = $(if ($launchOk) { "migfix:$stampInv/" } else { '' })
  id    = (Split-Path $root -Leaf)
  extra = [ordered]@{
    who           = $who
    totalFichiers = [int64]$totalFichiers
    totalOctets   = [int64]$totalOctets
    favTotal      = [int64]$favTotal
    capture       = $(if ($inv.Capture) { 'capture_bureau.png' } else { '' })
    apercu        = $(if ($apercu) { "fond_ecran_theme/$apercu" } else { '' })
    duree         = ('{0} min' -f [math]::Round(((Get-Date) - $debut).TotalMinutes, 1))
  }
}
$htmlPath = Join-Path $root 'Rapport_Inventaire.html'
Write-Report $htmlPath "Inventaire — $who" $data
Log "Rapport HTML : $htmlPath"
Log "Terminé -> $root"
Invoke-Item $htmlPath
