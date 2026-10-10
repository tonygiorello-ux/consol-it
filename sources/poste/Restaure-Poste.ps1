<#
  Restaure-Poste.ps1  (v2) — compagnon de Inventaire-Poste.ps1 (v2)

  A LANCER SUR LE NOUVEAU PC, DANS LA SESSION DE L'UTILISATEUR, PowerShell NON élevé.

  Pré-requis AVANT de lancer :
    1. Première ouverture de session faite + gpupdate /force
    2. Résolution, mise à l'échelle et disposition des écrans réglées comme sur l'ancien PC
    3. Données utilisateur déjà copiées (Bureau, Documents, Images...)
    4. Edge / Chrome, Outlook, Word, Teams lancés UNE fois (création des profils) puis FERMÉS
    5. Logiciels installés (sinon les raccourcis et épingles pointent dans le vide)

  Usage :
    Restauration + contrôle :  .\Restaure-Poste.ps1   (cherche le dossier d'inventaire sur les lecteurs, clé USB comprise)
                               .\Restaure-Poste.ps1 -Source "E:\Migration\ANCIENPC_jdupont_20261012_0915"
    Contrôle seul (à relancer après les corrections manuelles, ne modifie rien) :
                               .\Restaure-Poste.ps1 -Source "E:\Migration\..." -VerifierSeulement
    Sans -Restaurer ni -VerifierSeulement, le script demande le mode avant de commencer.

  Produit dans le dossier source :
    Rapport_Migration_<date>.html      : comparaison ancien / nouveau poste, écarts, check-list manuelle
    _fichiers_manquants_<date>.csv     : liste exhaustive des fichiers absents ou différents
    capture_bureau_nouveau_<date>.png  : capture du nouveau bureau (comparaison avant / après)
    _sauvegarde_nouveau_pc_<date>\     : état du nouveau PC avant restauration (retour arrière)
#>
param(
  [string]$Source,
  [switch]$VerifierSeulement,
  [switch]$Restaurer,        # restauration sans question (sinon le mode est demandé)
  [switch]$SansLanceur,      # ne pas installer le lanceur de corrections (boutons « Appliquer » du rapport)
  [switch]$RetirerLanceur    # retirer le lanceur de corrections puis quitter
)

$ErrorActionPreference = 'Continue'
$script:LanceurDir = Join-Path $env:LOCALAPPDATA 'MigrationPoste'
$script:LanceurKey = 'HKCU:\Software\Classes\migfix'
if ($RetirerLanceur) {
  Remove-Item $script:LanceurKey -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item $script:LanceurDir -Recurse -Force -ErrorAction SilentlyContinue
  Write-Host 'Lanceur de corrections retiré.' -ForegroundColor Green
  return
}
if ($VerifierSeulement -and $Restaurer) { throw 'Choisir -Restaurer OU -VerifierSeulement, pas les deux.' }
if (-not $VerifierSeulement -and -not $Restaurer) {
  Write-Host ''
  Write-Host '==== Que faire ? ====' -ForegroundColor Cyan
  Write-Host '  [1] Restaurer puis contrôler : remet en place l''environnement de l''ancien poste (MODIFIE ce poste ;'
  Write-Host '      l''état actuel est sauvegardé avant, pour retour arrière)'
  Write-Host '  [2] Vérifier seulement : compare ancien / nouveau poste et régénère le rapport, sans rien modifier'
  do { $choix = ([string](Read-Host '  Choix (1 ou 2)')).Trim() } until ($choix -eq '1' -or $choix -eq '2')
  if ($choix -eq '2') { $VerifierSeulement = [switch]$true } else { $Restaurer = [switch]$true }
}
if ($VerifierSeulement) { Write-Host 'Mode : VÉRIFICATION SEULE — rien ne sera modifié sur ce poste.' -ForegroundColor Green }
else { Write-Host 'Mode : RESTAURATION — l''environnement de l''ancien poste va être appliqué à ce poste.' -ForegroundColor Yellow }
function Find-Inventaires {
  # Cherche les dossiers d'inventaire (inventaire.json) sur tous les lecteurs : racine, \Migration\*, et un niveau en dessous
  $res = @()
  foreach ($d in @(Get-CimInstance Win32_LogicalDisk -ErrorAction SilentlyContinue | Where-Object { @(2, 3, 4) -contains [int]$_.DriveType -and $_.Size })) {
    $r = $d.DeviceID + '\'
    $cands = @($r) + @(Get-ChildItem -LiteralPath $r -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch '^(Windows|Program Files.*|ProgramData|Users|PerfLogs|Recovery|\$.*|System Volume Information|Config\.Msi|Intel|AMD|NVIDIA|Drivers)$' } | Select-Object -ExpandProperty FullName)
    foreach ($c in $cands) {
      foreach ($dir in @($c) + @(Get-ChildItem -LiteralPath $c -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)) {
        $j = Join-Path $dir 'inventaire.json'
        if (Test-Path -LiteralPath $j) {
          $res += [pscustomobject]@{ Chemin = $dir; Lecteur = $d.DeviceID; Date = (Get-Item -LiteralPath $j).LastWriteTime
            Donnees = (Test-Path -LiteralPath (Join-Path $dir 'Donnees\_copie.json')) }
        }
      }
    }
  }
  @($res | Sort-Object Chemin -Unique | Sort-Object Date -Descending)
}
if (-not $Source) {
  while (-not $Source) {
    Write-Host ''
    Write-Host '==== Dossier d''inventaire à restaurer ====' -ForegroundColor Cyan
    Write-Host '  Recherche sur les lecteurs (clé / disque USB, disques, lecteurs réseau)...' -ForegroundColor Gray
    $trouves = @(Find-Inventaires)
    $i = 0
    foreach ($t in $trouves) {
      $i++
      $nom = Split-Path $t.Chemin -Leaf
      $mine = $nom -match ('_' + [regex]::Escape($env:USERNAME) + '_')
      Write-Host ("  [{0}] {1}   {2:dd/MM/yyyy HH:mm}   {3}{4}" -f $i, $t.Chemin, $t.Date, $(if ($t.Donnees) { 'données copiées' } else { 'sans copie des données' }), $(if ($mine) { '   <- cet utilisateur' } else { '' })) -ForegroundColor $(if ($mine) { 'Green' } else { 'Gray' })
    }
    if (-not $trouves.Count) { Write-Host '  Aucun dossier d''inventaire trouvé. Brancher la clé / le disque USB puis taper R, ou saisir le chemin.' -ForegroundColor Yellow }
    $defaut = 0
    for ($k = 0; $k -lt $trouves.Count; $k++) { if ((Split-Path $trouves[$k].Chemin -Leaf) -match ('_' + [regex]::Escape($env:USERNAME) + '_')) { $defaut = $k + 1; break } }
    if (-not $defaut -and $trouves.Count -eq 1) { $defaut = 1 }
    $q = '  Numéro, chemin complet du dossier, ou R pour relancer la recherche'
    if ($defaut) { $q += " [Entrée = $defaut]" }
    $rep = ([string](Read-Host $q)).Trim().Trim('"')
    if ($rep -match '^[rR]$') { continue }
    if (-not $rep -and $defaut) { $rep = [string]$defaut }
    if ($rep -match '^\d+$' -and [int]$rep -ge 1 -and [int]$rep -le $trouves.Count) { $Source = $trouves[[int]$rep - 1].Chemin }
    elseif ($rep) {
      if (Test-Path -LiteralPath (Join-Path $rep 'inventaire.json')) { $Source = $rep }
      else { Write-Host "  Pas de inventaire.json dans $rep" -ForegroundColor Red }
    }
  }
}
if (-not (Test-Path -LiteralPath $Source)) { throw "Dossier source introuvable : $Source" }
$Source = (Resolve-Path -LiteralPath $Source).Path
Write-Host "Dossier source : $Source" -ForegroundColor Green
$jsonPath = Join-Path $Source 'inventaire.json'
if (-not (Test-Path $jsonPath)) { throw "inventaire.json absent dans $Source : relancer Inventaire-Poste.ps1 (v2) sur l'ancien poste." }
$inv = Get-Content $jsonPath -Raw -Encoding UTF8 | ConvertFrom-Json

if (-not ('W32' -as [type])) {
Add-Type @'
using System; using System.Runtime.InteropServices;
public class W32 {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  public static extern int SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni);
}
'@
}
[W32]::SetProcessDPIAware() | Out-Null
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

$debut   = Get-Date
$stamp   = '{0:yyyyMMdd_HHmm}' -f $debut
$journal = Join-Path $Source "_journal_restauration_$stamp.txt"
$bak     = Join-Path $Source "_sauvegarde_nouveau_pc_$stamp"
$script:actions   = New-Object System.Collections.Generic.List[string]
$script:incidents = New-Object System.Collections.Generic.List[string]
$script:checks    = New-Object System.Collections.Generic.List[object]
$wsh = New-Object -ComObject WScript.Shell

# ============================================================== Fonctions utilitaires
function Log($m)      { $l = "[{0:HH:mm:ss}] {1}" -f (Get-Date), $m; Write-Host $l; $l | Out-File $journal -Append -Encoding UTF8 }
function Action($m)   { $script:actions.Add($m); Log "Restauré : $m" }
function Incident($m) { $script:incidents.Add($m); Write-Host "  -> PROBLEME : $m" -ForegroundColor Yellow; $m | Out-File $journal -Append -Encoding UTF8 }
function Src($r)      { Join-Path $Source $r }
function Ask($q)      { (Read-Host "$q (o/N)") -match '^[oOyY]' }
function RegVal($path, $name) { try { (Get-ItemProperty -Path $path -Name $name -ErrorAction Stop).$name } catch { $null } }
function Backup-Key($key, $name) { reg export $key (Join-Path $bak "$name.reg") /y 2>$null | Out-Null }
function AccentHex($v) {
  if ($null -eq $v) { return $null }
  $u = [int64]$v -band 4294967295   # DWORD lu en signé ou non signé selon la version : on garde les 32 bits
  $h = '{0:X8}' -f $u
  '#' + $h.Substring(6,2) + $h.Substring(4,2) + $h.Substring(2,2)
}
function Dec($v) { if ($v -is [byte[]]) { [Text.Encoding]::Unicode.GetString($v).TrimEnd([char]0) } else { [string]$v } }

function Import-Reg($file, $label, [string[]]$exclude) {
  $f = Src "registre\$file.reg"
  if (-not (Test-Path $f)) { Log "Pas d'export pour $file (absent sur l'ancien PC)"; return }
  $content = Get-Content $f -Encoding Unicode
  if ($exclude) {
    $content = $content | Where-Object { $line = $_; -not ($exclude | Where-Object { $line -like "`"$_`"=*" }) }
  }
  $tmp = Join-Path $env:TEMP "restaure_$file.reg"
  $content | Out-File $tmp -Encoding Unicode
  reg import $tmp 2>$null | Out-Null
  $ok = ($LASTEXITCODE -eq 0)
  Remove-Item $tmp -Force -ErrorAction SilentlyContinue
  if ($ok) { Action $label } else { Incident "Import du registre échoué : $label ($file.reg)" }
}

function Ensure-Closed([string[]]$names, $label) {
  if (-not (Get-Process -Name $names -ErrorAction SilentlyContinue)) { return $true }
  Read-Host "$label est ouvert. Ferme-le puis appuie sur Entrée" | Out-Null
  if (Get-Process -Name $names -ErrorAction SilentlyContinue) {
    if (Ask "$label tourne encore en arrière-plan. Forcer la fermeture ?") {
      Stop-Process -Name $names -Force -ErrorAction SilentlyContinue; Start-Sleep -Seconds 2
    } else { return $false }
  }
  return $true
}

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
    return $true
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
function Get-OutlookDefaultSig {
  $out = @()
  Get-ChildItem 'HKCU:\Software\Microsoft\Office\16.0\Outlook\Profiles' -ErrorAction SilentlyContinue | ForEach-Object {
    $prof = $_.PSChildName
    Get-ChildItem (Join-Path $_.PSPath '9375CFF0413111d3B88A00104B2A6676') -ErrorAction SilentlyContinue | ForEach-Object {
      $p = Get-ItemProperty $_.PSPath
      $acct = Dec $p.'Account Name'
      $new  = Dec $p.'New Signature'
      $rep  = Dec $p.'Reply-Forward Signature'
      if ($acct) { $out += [pscustomobject]@{ Profil = $prof; Compte = $acct; Nouveau = $new; Reponse = $rep } }
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
function Get-Apps {
  $keys = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
          'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
          'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
  Get-ItemProperty $keys -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -and -not $_.SystemComponent -and -not $_.ParentKeyName } |
    Sort-Object DisplayName -Unique |
    ForEach-Object { [pscustomobject]@{ Nom = [string]$_.DisplayName; Version = [string]$_.DisplayVersion } }
}
function Norm($s) { ([string]$s -replace '\(.*?\)', '' -replace '[\d\.\-_,]+', ' ' -replace '\s+', ' ').Trim().ToLower() }
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
# Traduit un chemin de l'ancien profil vers le nouveau (si le dossier de profil a changé de nom, ex. jdupont.ENTREPRISE)
function Tr($p) {
  $op = [string]$inv.Meta.Profil
  if ($op -and $p -and ([string]$p).StartsWith($op, [StringComparison]::OrdinalIgnoreCase)) { return $env:USERPROFILE + ([string]$p).Substring($op.Length) }
  $p
}
function Props($o) { if ($null -eq $o) { @() } else { @($o.PSObject.Properties) } }

# --- Contrôles
function Check($cat, $elt, $old, $new, $statut, $note = '', $acts = @()) {
  if ($statut -eq 'OK') { $acts = @() }   # rien à corriger : pas de bouton
  $script:checks.Add([pscustomobject]@{ Categorie = $cat; Element = [string]$elt; Ancien = [string]$old; Nouveau = [string]$new; Statut = $statut; Note = [string]$note; Acts = @($acts | Where-Object { $_ }) })
}

# --- Actions proposées dans le rapport (une correction = une action)
#   open : lien direct (ms-settings:, ms-windows-store:, msteams:)   web : site / boutique / SharePoint
#   nav  : autre page du rapport   copy : texte à coller (adresse edge://, chemin)   cmd : commande PowerShell prête à coller
function Q($s) { "'" + ([string]$s -replace "'", "''") + "'" }
function AOpen($l, $u) { [ordered]@{ t = 'open'; l = $l; u = $u } }
function AWeb($l, $u)  { [ordered]@{ t = 'web';  l = $l; u = $u } }
function ANav($l, $u)  { [ordered]@{ t = 'nav';  l = $l; u = $u } }
function ACopy($l, $txt, $hint) { [ordered]@{ t = 'copy'; l = $l; c = $txt; h = $hint } }
function ACmd($l, $c, $adm = $false, $auto = $false) { [ordered]@{ t = 'cmd'; l = $l; c = $c; adm = [bool]$adm; auto = [bool]$auto } }
function ExplorerWrap($inner) {
  "Stop-Process -Name explorer -Force; Start-Sleep -Seconds 1; $inner; Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue; Start-Sleep -Seconds 2; if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }"
}
function RegFix($path, $name, $raw, $type = 'DWord') {
  if ([string]$raw -eq '') { return "Remove-ItemProperty -Path $(Q $path) -Name $(Q $name) -ErrorAction SilentlyContinue" }
  $v = if ($type -eq 'String') { Q $raw } else { [string][int64]$raw }
  "if (-not (Test-Path $(Q $path))) { New-Item -Path $(Q $path) -Force | Out-Null }; Set-ItemProperty -Path $(Q $path) -Name $(Q $name) -Value $v -Type $type"
}
function St($cond) { if ($cond) { 'OK' } else { 'ECART' } }
# $reg (facultatif) : @{ p = clé ; n = valeur ; t = 'DWord'|'String' ; v = valeur à forcer ; x = 'explorer'|'wrap' ; o = 'ms-settings:...' }
function CmpVal($cat, $label, $old, $new, $map, $defOld, $defNew, $note = '', $reg = $null, $acts = @()) {
  $o = [string]$old; if ($o -eq '') { $o = [string]$defOld }
  $n = [string]$new; if ($n -eq '') { $n = [string]$defNew }
  $ol = if ($map -and $map.ContainsKey($o)) { $map[$o] } elseif ($o -eq '') { 'Par défaut' } else { $o }
  $nl = if ($map -and $map.ContainsKey($n)) { $map[$n] } elseif ($n -eq '') { 'Par défaut' } else { $n }
  $st = St ($o -eq $n)
  $a = @()
  if ($reg -and $reg.p) {
    $raw = if ($reg.ContainsKey('v')) { $reg.v } else { $old }
    if ([string]$raw -eq '' -and [string]$defOld -ne [string]$defNew) { $raw = $defOld }   # valeur par défaut différente entre les deux versions de Windows
    $t = if ($reg.t) { $reg.t } else { 'DWord' }
    $cmd = RegFix $reg.p $reg.n $raw $t
    if ($reg.x -eq 'explorer') { $cmd += '; Stop-Process -Name explorer -Force' } elseif ($reg.x -eq 'wrap') { $cmd = ExplorerWrap $cmd }
    $a += ACmd 'Copier la commande de correction' $cmd $false $true
  }
  if ($reg -and $reg.o) { $a += AOpen 'Ouvrir le réglage Windows' $reg.o }
  $a += @($acts)
  Check $cat $label $ol $nl $st $(if ($st -ne 'OK') { $note } else { '' }) $a
}

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

# ============================================================== 0. Contrôles préalables
$C_ECR = 'Écrans et affichage'; $C_PER = 'Personnalisation'; $C_BUR = 'Bureau'
$C_BAR = 'Barre des tâches et menu Démarrer'; $C_EXP = 'Explorateur de fichiers'; $C_LEC = 'Lecteurs réseau'
$C_IMP = 'Imprimantes'; $C_LOG = 'Logiciels'; $C_NAV = 'Navigateurs internet'; $C_OFF = 'Outlook, Office et Teams'
$C_OD = 'OneDrive et SharePoint'; $C_FIC = 'Fichiers'; $C_SEC = 'Accès et sécurité'; $C_LAN = 'Langue et région'; $C_FIN = 'Contrôles finaux'

$srcBuild = [int]$inv.Systeme.Build
$dstOs    = Get-CimInstance Win32_OperatingSystem
$dstBuild = [int]$dstOs.BuildNumber
$srcWin11 = $srcBuild -ge 22000; $dstWin11 = $dstBuild -ge 22000
Log "Source : $($inv.Meta.Ordinateur) / $($inv.Meta.Utilisateur) ($($inv.Systeme.OS) build $srcBuild) -> cible : $env:COMPUTERNAME / $env:USERNAME (build $dstBuild)"

if ($inv.Meta.Utilisateur -and $inv.Meta.Utilisateur -ne $env:USERNAME) {
  Write-Warning "L'inventaire appartient à '$($inv.Meta.Utilisateur)' mais la session est '$env:USERNAME'."
  if (-not (Ask "Continuer quand même ?")) { exit }
}

$oldScreens = (@($inv.Ecrans) | ForEach-Object { "$($_.Largeur)x$($_.Hauteur)" } | Sort-Object) -join ' + '
$newScreens = ([System.Windows.Forms.Screen]::AllScreens | ForEach-Object { "$($_.Bounds.Width)x$($_.Bounds.Height)" } | Sort-Object) -join ' + '
$dstDpi = [string](RegVal 'HKCU:\Control Panel\Desktop\WindowMetrics' 'AppliedDPI')
if (-not $VerifierSeulement -and ($oldScreens -ne $newScreens -or ([string]$inv.DPI -and $dstDpi -and [string]$inv.DPI -ne $dstDpi))) {
  Write-Warning "Écrans ancien : $oldScreens (DPI $($inv.DPI)) / nouveau : $newScreens (DPI $dstDpi)"
  Write-Warning "Résolution ou mise à l'échelle différente : la disposition des icônes sera décalée."
  if (-not (Ask "Continuer quand même ?")) { exit }
}

$pinDir   = "$env:APPDATA\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar"
$startDir = "$env:LOCALAPPDATA\Packages\Microsoft.Windows.StartMenuExperienceHost_cw5n1h2txyewy\LocalState"
$qaFile   = "$env:APPDATA\Microsoft\Windows\Recent\AutomaticDestinations\f01b4d95cf55d32a.automaticDestinations-ms"
$browserData = @{ 'Edge' = "$env:LOCALAPPDATA\Microsoft\Edge\User Data"; 'Chrome' = "$env:LOCALAPPDATA\Google\Chrome\User Data" }
$browserProc = @{ 'Edge' = 'msedge'; 'Chrome' = 'chrome' }

# ======================================================================================
#                                    RESTAURATION
# ======================================================================================
if (-not $VerifierSeulement) {

  # ------------------------------------------------------------ 1. Sauvegarde de l'état actuel
  New-Item -ItemType Directory -Path $bak -Force | Out-Null
  Backup-Key 'HKCU\Software\Microsoft\Windows\Shell\Bags\1\Desktop'                    'bureau_disposition_icones'
  Backup-Key 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons' 'bureau_icones_systeme'
  Backup-Key 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband'         'barre_taches'
  Backup-Key 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'         'explorateur_options'
  Backup-Key 'HKCU\Software\Microsoft\Windows\CurrentVersion\Search'                    'recherche_barre_taches'
  Backup-Key 'HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'        'theme_clair_sombre'
  Backup-Key 'HKCU\Software\Microsoft\Windows\DWM'                                      'couleur_accentuation'
  Backup-Key 'HKCU\Control Panel\Desktop'                                               'panneau_bureau'
  Backup-Key 'HKCU\Control Panel\Mouse'                                                 'souris'
  Backup-Key 'HKCU\Network'                                                             'lecteurs_reseau'
  if (Test-Path $pinDir)   { Copy-Item $pinDir   "$bak\TaskBar_pins"         -Recurse -Force }
  if (Test-Path $startDir) { Copy-Item $startDir "$bak\StartMenu_LocalState" -Recurse -Force }
  if (Test-Path $qaFile)   { Copy-Item $qaFile   $bak -Force }
  Log "Etat actuel sauvegardé dans $bak"

  # ------------------------------------------------------------ 1b. Recopie des données préparées sur l'ancien poste (dossier Donnees)
  $donnees = Join-Path $Source 'Donnees'
  $plan = $inv.CopiePlan
  if ((Test-Path $donnees) -and $plan) {
    $known = Get-KnownFolders
    $items = @()
    foreach ($d in @($plan.Dossiers)) {
      $src = Join-Path $donnees $d.Cible
      if ((Test-Path -LiteralPath $src) -and $known[$d.Cle]) { $items += [pscustomobject]@{ Label = "Données $($d.Libelle)"; Src = $src; Dst = $known[$d.Cle]; File = $null } }
    }
    foreach ($p in @($plan.Pst)) {
      $src = Join-Path $donnees $p.Cible; $leaf = Split-Path $p.Source -Leaf
      if (Test-Path -LiteralPath (Join-Path $src $leaf)) { $items += [pscustomobject]@{ Label = "PST $leaf"; Src = $src; Dst = (Split-Path (Tr $p.Source) -Parent); File = $leaf } }
    }
    foreach ($h in @($plan.Hors)) {
      $src = Join-Path $donnees $h.Cible
      if (Test-Path -LiteralPath $src) { $items += [pscustomobject]@{ Label = "Hors profil $($h.Source)"; Src = $src; Dst = $h.Source; File = $null } }
    }
    if ($items.Count) {
      Write-Host "`nDonnées préparées sur l'ancien poste ($($items.Count) élément(s)) :" -ForegroundColor Cyan
      $items | ForEach-Object { Write-Host "  $($_.Label)  ->  $($_.Dst)" }
      if (Ask "Les recopier maintenant à leur place ? (un fichier plus récent sur ce poste n'est jamais écrasé)") {
        if ($items | Where-Object { $_.File }) { [void](Ensure-Closed @('OUTLOOK') 'Outlook') }
        $rlog = Join-Path $donnees 'robocopy_restauration.log'
        foreach ($it in $items) {
          New-Item -ItemType Directory -Path $it.Dst -Force -ErrorAction SilentlyContinue | Out-Null
          if ($it.File) { $a = @($it.Src, $it.Dst, $it.File, '/COPY:DAT', '/R:1', '/W:1', '/NP', '/NJH', '/NJS', '/XO', "/LOG+:$rlog") }
          else          { $a = @($it.Src, $it.Dst, '/E', '/COPY:DAT', '/XJ', '/R:1', '/W:1', '/NP', '/NJH', '/NJS', '/NDL', '/NFL', '/XO', "/LOG+:$rlog") }
          Write-Host "  Copie : $($it.Label)..."
          & robocopy @a | Out-Null
          if ($LASTEXITCODE -ge 8) {
            $hint = if ($it.Dst -notlike "$env:USERPROFILE*") { ' — dossier hors profil : relancer la copie en administrateur si l''accès est refusé' } else { '' }
            Incident "$($it.Label) : erreurs de copie (code $LASTEXITCODE, voir $rlog)$hint"
          } else { Action "$($it.Label) : recopié" }
        }
      } else { Log "Recopie des données reportée (boutons « Recopier » dans le rapport)" }
    }
    # Réseaux Wi-Fi exportés : import pour l'utilisateur courant (sans droits administrateur)
    $wx = @(Get-ChildItem (Join-Path $donnees 'Wifi') -Filter *.xml -ErrorAction SilentlyContinue)
    if ($wx.Count) {
      $nw = 0
      foreach ($x in $wx) { cmd /c ('netsh wlan add profile filename="{0}" user=current' -f $x.FullName) 2>&1 | Out-Null; if ($LASTEXITCODE -eq 0) { $nw++ } }
      if ($nw) { Action "$nw réseau(x) Wi-Fi importé(s)" } else { Incident "Import des réseaux Wi-Fi impossible (carte Wi-Fi désactivée ?)" }
    }
  }

  # ------------------------------------------------------------ 2. Raccourcis du Bureau
  $desktopPath = [Environment]::GetFolderPath('Desktop')
  $srcLnk = Src 'bureau\raccourcis'
  if (Test-Path $srcLnk) {
    $n = 0
    Get-ChildItem -LiteralPath $srcLnk -File | ForEach-Object {
      $dst = Join-Path $desktopPath $_.Name
      if (-not (Test-Path -LiteralPath $dst)) { Copy-Item -LiteralPath $_.FullName -Destination $dst; $n++ }
    }
    if ($n) { Action "$n raccourci(s) ajouté(s) sur le Bureau" }
  }

  # ------------------------------------------------------------ 3. Phase Explorateur arrêté
  Write-Host "`nL'Explorateur va être redémarré (le bureau disparaît quelques secondes)." -ForegroundColor Cyan
  Read-Host "Entrée pour continuer" | Out-Null

  Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
  if ($dstWin11) { Stop-Process -Name StartMenuExperienceHost -Force -ErrorAction SilentlyContinue }
  Start-Sleep -Seconds 1

  Import-Reg 'bureau_disposition_icones' 'Disposition des icônes du Bureau'
  Import-Reg 'bureau_icones_systeme'     'Icônes système du Bureau (Ce PC, Corbeille...)'

  $srcPins = Src 'barre_taches_demarrer\TaskBar'
  if (Test-Path $srcPins) {
    New-Item -ItemType Directory -Path $pinDir -Force | Out-Null
    Copy-Item "$srcPins\*" $pinDir -Recurse -Force
    Action "Épingles de la barre des tâches ($(@($inv.Epingles).Count))"
  }
  Import-Reg 'barre_taches'           'Ordre de la barre des tâches'
  Import-Reg 'explorateur_options'    "Options de l'Explorateur et de la barre des tâches" @('TaskbarDa')
  Import-Reg 'recherche_barre_taches' 'Zone de recherche de la barre des tâches'
  if ($dstWin11 -and -not $srcWin11) {
    try { Set-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name TaskbarAl -Value 0 -Type DWord -ErrorAction Stop; Action 'Barre des tâches alignée à gauche (comme sous Windows 10)' }
    catch { Incident "Alignement de la barre des tâches non modifié : $($_.Exception.Message)" }
  }

  $srcQa = Src 'barre_taches_demarrer\acces_rapide.automaticDestinations-ms'
  if (Test-Path $srcQa) { Copy-Item $srcQa $qaFile -Force; Action 'Dossiers épinglés dans Accès rapide' }

  $srcStart = Src 'barre_taches_demarrer\StartMenu_LocalState'
  if ($srcWin11 -and $dstWin11 -and (Test-Path $srcStart)) {
    Get-ChildItem $srcStart -Filter 'start*.bin' | ForEach-Object { Copy-Item $_.FullName $startDir -Force }
    Action 'Épingles du menu Démarrer'
  }

  # Second arrêt forcé : si l'Explorateur a redémarré seul pendant l'import, il est jeté sans sauvegarder
  Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 2
  if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
  Start-Sleep -Seconds 3
  Log "Explorateur redémarré"

  # ------------------------------------------------------------ 4. Fond d'écran, thème, souris
  $fe = $inv.FondEcran
  if (-not $fe.Chemin -and $fe.CouleurUnie) {
    Set-ItemProperty 'HKCU:\Control Panel\Colors' -Name Background -Value $fe.CouleurUnie
    [W32]::SystemParametersInfo(20, 0, '', 3) | Out-Null
    Action "Fond d'écran : couleur unie ($($fe.CouleurUnie))"
  } else {
    $img = $null
    if ($fe.FichierCopie) { $c = Src ("fond_ecran_theme\" + $fe.FichierCopie); if (Test-Path -LiteralPath $c) { $img = $c } }
    if (-not $img) { $t = Src 'fond_ecran_theme\Themes\TranscodedWallpaper'; if (Test-Path $t) { $img = $t } }
    if ($img) {
      $wpPath = Tr ([string]$fe.Chemin)
      $parent = if ($wpPath) { Split-Path $wpPath -Parent } else { '' }
      if ($fe.FichierCopie -and $parent -and (Test-Path -LiteralPath $parent) -and ($parent -notlike '*\Themes*')) { $target = $wpPath }
      else {
        $name = Split-Path $img -Leaf
        if (-not [IO.Path]::GetExtension($name)) { $name = "$name.jpg" }
        $dir = Join-Path $env:LOCALAPPDATA 'FondEcran'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $target = Join-Path $dir $name
      }
      Copy-Item -LiteralPath $img -Destination $target -Force
      try {
        if ([string]$fe.Style -ne '')    { Set-ItemProperty 'HKCU:\Control Panel\Desktop' -Name WallpaperStyle -Value ([string]$fe.Style) -ErrorAction Stop }
        if ([string]$fe.Mosaique -ne '') { Set-ItemProperty 'HKCU:\Control Panel\Desktop' -Name TileWallpaper  -Value ([string]$fe.Mosaique) -ErrorAction Stop }
        if ([W32]::SystemParametersInfo(20, 0, $target, 3) -eq 0) { throw "SystemParametersInfo a refusé l'image" }
        Action "Fond d'écran ($(Split-Path $target -Leaf), $($fe.Libelle))"
      } catch { Incident "Fond d'écran non appliqué : $($_.Exception.Message)" }
    } else { Incident "Fond d'écran : aucune image trouvée dans l'inventaire" }
  }
  Import-Reg 'theme_clair_sombre'   'Mode clair / sombre'
  Import-Reg 'couleur_accentuation' "Couleur d'accentuation"
  Import-Reg 'souris'               'Réglages de la souris'

  # ------------------------------------------------------------ 5. Lecteurs réseau & imprimantes
  Import-Reg 'lecteurs_reseau' 'Lecteurs réseau (actifs à la prochaine ouverture de session)'
  foreach ($p in @($inv.Imprimantes)) {
    if (-not $p.Reseau -or (Get-Printer -Name $p.Nom -ErrorAction SilentlyContinue)) { continue }
    try { Add-Printer -ConnectionName $p.Nom -ErrorAction Stop; Action "Imprimante $($p.Nom)" }
    catch { Incident "Imprimante $($p.Nom) non connectée : $($_.Exception.Message)" }
  }
  if ($inv.ImprimanteDefaut) {
    Set-ItemProperty 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Windows' -Name LegacyDefaultPrinterMode -Value 1 -Type DWord -ErrorAction SilentlyContinue
    try { (New-Object -ComObject WScript.Network).SetDefaultPrinter($inv.ImprimanteDefaut); Action "Imprimante par défaut : $($inv.ImprimanteDefaut)" }
    catch { Incident "Imprimante par défaut non définie : $($inv.ImprimanteDefaut)" }
  }

  # ------------------------------------------------------------ 6. Navigateurs (favoris)
  foreach ($b in 'Edge','Chrome') {
    $srcB = Src "navigateurs\$b"
    if (-not (Test-Path $srcB)) { continue }
    if (-not (Ensure-Closed @($browserProc[$b]) $b)) { Incident "$b resté ouvert : favoris non restaurés"; continue }
    Get-ChildItem $srcB -Directory | ForEach-Object {
      $dstP = Join-Path $browserData[$b] $_.Name
      $bm = Join-Path $_.FullName 'Bookmarks'
      if (-not (Test-Path $bm)) { return }
      if (-not (Test-Path $dstP)) { Incident "$b profil '$($_.Name)' inexistant : lancer $b une fois puis relancer le script"; return }
      $cur = Join-Path $dstP 'Bookmarks'
      if (Test-Path $cur) { Copy-Item $cur "$cur.avant_restauration_$stamp" -Force }
      Copy-Item $bm $cur -Force
      Action "Favoris $b ($($_.Name))"
    }
  }

  # ------------------------------------------------------------ 7. Office, Teams, polices
  if (Ensure-Closed @('OUTLOOK','WINWORD','EXCEL','POWERPNT') 'Office') {
    $map = [ordered]@{
      'office\Signatures' = @("$env:APPDATA\Microsoft\Signatures", 'Signatures Outlook')
      'office\Templates'  = @("$env:APPDATA\Microsoft\Templates", 'Modèles Office (dont Normal.dotm)')
      'office\UProof'     = @("$env:APPDATA\Microsoft\UProof", 'Dictionnaire personnel')
    }
    foreach ($k in $map.Keys) {
      $s = Src $k; $d = $map[$k][0]
      if (-not (Test-Path $s)) { continue }
      New-Item -ItemType Directory -Path $d -Force | Out-Null
      if ($k -eq 'office\Templates' -and (Test-Path "$d\Normal.dotm")) { Copy-Item "$d\Normal.dotm" "$bak\Normal.dotm" -Force }
      Copy-Item "$s\*" $d -Recurse -Force
      Action $map[$k][1]
    }
    $acl = @(Get-ChildItem (Src 'office') -Filter *.acl -ErrorAction SilentlyContinue)
    if ($acl.Count) { $acl | Copy-Item -Destination "$env:APPDATA\Microsoft\Office" -Force; Action 'Corrections automatiques Office' }
  } else { Incident 'Office resté ouvert : signatures, modèles et dictionnaire non restaurés' }

  $teamsSrc = Src 'office\teams_arriere_plans'
  $teamsDst = "$env:LOCALAPPDATA\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\Backgrounds\Uploads"
  if (Test-Path $teamsSrc) {
    if (Test-Path (Split-Path $teamsDst -Parent)) {
      New-Item -ItemType Directory -Path $teamsDst -Force | Out-Null
      Copy-Item "$teamsSrc\*" $teamsDst -Force; Action 'Arrière-plans Teams'
    } else { Incident 'Teams jamais lancé : arrière-plans non copiés (lancer Teams puis relancer le script)' }
  }

  $fontSrc = Src 'office\polices_utilisateur'
  if (Test-Path $fontSrc) {
    $fontDst = "$env:LOCALAPPDATA\Microsoft\Windows\Fonts"
    New-Item -ItemType Directory -Path $fontDst -Force | Out-Null
    $fk = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts'
    if (-not (Test-Path $fk)) { New-Item $fk -Force | Out-Null }
    $nf = 0
    Get-ChildItem $fontSrc -File | Where-Object { $_.Extension -in '.ttf','.otf','.ttc' } | ForEach-Object {
      $d = Join-Path $fontDst $_.Name
      try {
        Copy-Item -LiteralPath $_.FullName -Destination $d -Force -ErrorAction Stop
        $suffix = if ($_.Extension -eq '.otf') { '(OpenType)' } else { '(TrueType)' }
        Set-ItemProperty $fk -Name "$($_.BaseName) $suffix" -Value $d -ErrorAction Stop
        $nf++
      } catch { Incident "Police $($_.Name) non installée : $($_.Exception.Message)" }
    }
    if ($nf) { Action "$nf police(s) personnelle(s)" }
  }
  Log "Restauration terminée : $($script:actions.Count) action(s), $($script:incidents.Count) problème(s)"
}

# ======================================================================================
#                          CONTRÔLE : ANCIEN POSTE  vs  NOUVEAU POSTE
# ======================================================================================
Log "Contrôle de conformité en cours..."
# Racine du support de migration (clé USB « E: » ou partage « \\serveur\partage ») : sert aux commandes de recopie
$usb = ([IO.Path]::GetPathRoot((Resolve-Path $Source).Path)).TrimEnd('\')
$donnees = Join-Path (Resolve-Path $Source).Path 'Donnees'
$plan = $inv.CopiePlan

# ------------------------------------------------------------ Écrans
$aDisp = AOpen "Ouvrir Paramètres > Affichage" 'ms-settings:display'
$oldS = @(@($inv.Ecrans) | Sort-Object { [int]$_.X }, { [int]$_.Y })
$newS = @([System.Windows.Forms.Screen]::AllScreens | Sort-Object { $_.Bounds.X }, { $_.Bounds.Y })
$noteEcr = "Écart normal si l'écran du nouveau portable n'a pas la même résolution native : régler la mise à l'échelle pour un rendu équivalent."
Check $C_ECR "Nombre d'écrans" $oldS.Count $newS.Count $(if ($oldS.Count -eq $newS.Count) { 'OK' } else { 'MANUEL' }) $(if ($oldS.Count -ne $newS.Count) { "Brancher les mêmes écrans que sur l'ancien poste pour comparer." }) @($aDisp)
for ($i = 0; $i -lt [math]::Max($oldS.Count, $newS.Count); $i++) {
  $o = if ($i -lt $oldS.Count) { "$($oldS[$i].Largeur) × $($oldS[$i].Hauteur)$(if ($oldS[$i].Principal) { ' · principal' })" } else { '—' }
  $n = if ($i -lt $newS.Count) { "$($newS[$i].Bounds.Width) × $($newS[$i].Bounds.Height)$(if ($newS[$i].Primary) { ' · principal' })" } else { '—' }
  Check $C_ECR "Écran $($i + 1)" $o $n $(if ($o -eq $n) { 'OK' } else { 'MANUEL' }) $(if ($o -ne $n) { $noteEcr }) @($aDisp)
}
$pct = { param($d) if ($d) { '{0} %' -f [math]::Round([int]$d / 96 * 100) } else { '100 %' } }
$oPct = & $pct $inv.DPI; $nPct = & $pct $dstDpi
Check $C_ECR "Mise à l'échelle" $oPct $nPct $(if ($oPct -eq $nPct) { 'OK' } else { 'MANUEL' }) $(if ($oPct -ne $nPct) { "Régler l'échelle sur $oPct" }) @($aDisp)
Check $C_ECR 'Système' "$($inv.Systeme.OS) (build $srcBuild)" "$($dstOs.Caption) (build $dstBuild)" 'INFO'

# ------------------------------------------------------------ Personnalisation
$fe = $inv.FondEcran
$styles = @{ '10' = 'Remplir'; '6' = 'Ajuster'; '2' = 'Étirer'; '0' = 'Centrer'; '22' = 'Étendre sur les écrans' }
$curDesk = Get-ItemProperty 'HKCU:\Control Panel\Desktop'
$curWp = [string]$curDesk.WallPaper
$aBg = AOpen "Ouvrir Paramètres > Arrière-plan" 'ms-settings:personalization-background'
$spi = "Add-Type -Namespace Mig -Name U -MemberDefinition '[DllImport(`"user32.dll`", CharSet = CharSet.Unicode)] public static extern int SystemParametersInfo(int a, int b, string c, int d);' -ErrorAction SilentlyContinue"
if (-not $fe.Chemin) {
  $curCol = RegVal 'HKCU:\Control Panel\Colors' 'Background'
  $cmd = "Set-ItemProperty 'HKCU:\Control Panel\Colors' -Name Background -Value $(Q $fe.CouleurUnie); $spi; [Mig.U]::SystemParametersInfo(20, 0, '', 3)"
  Check $C_PER "Fond d'écran" "Couleur unie ($($fe.CouleurUnie))" $(if ($curWp) { Split-Path $curWp -Leaf } else { "Couleur unie ($curCol)" }) (St ((-not $curWp) -and $curCol -eq $fe.CouleurUnie)) '' @((ACmd 'Copier la commande de correction' $cmd $false $true), $aBg)
} else {
  $srcImg = $null
  if ($fe.FichierCopie) { $c = Src ("fond_ecran_theme\" + $fe.FichierCopie); if (Test-Path -LiteralPath $c) { $srcImg = $c } }
  if (-not $srcImg) { $t = Src 'fond_ecran_theme\Themes\TranscodedWallpaper'; if (Test-Path $t) { $srcImg = $t } }
  $same = $false
  if ($srcImg -and $curWp -and (Test-Path -LiteralPath $curWp -PathType Leaf)) {
    $same = (Get-FileHash -LiteralPath $curWp).Hash -eq (Get-FileHash -LiteralPath $srcImg).Hash
  }
  $oldName = if ($fe.FichierCopie) { $fe.FichierCopie } else { Split-Path ([string]$fe.Chemin) -Leaf }
  $note = ''
  if (-not $same) {
    $note = "Image différente : la commande recopie l'image d'origine depuis le dossier de migration et l'applique avec le même ajustement."
    if (RegVal 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\System' 'Wallpaper') { $note += " Attention : une GPO impose un fond d'écran." }
  }
  $wpActs = @()
  if ($srcImg) {
    $ext = [IO.Path]::GetExtension($srcImg); if (-not $ext) { $ext = '.jpg' }
    $dstImg = Join-Path (Join-Path $env:LOCALAPPDATA 'FondEcran') ((Split-Path $srcImg -Leaf) -replace '\.[^.]*$', '' ) ; $dstImg += $ext
    $cmd = "New-Item -ItemType Directory -Path $(Q (Split-Path $dstImg -Parent)) -Force | Out-Null; Copy-Item -LiteralPath $(Q $srcImg) -Destination $(Q $dstImg) -Force; " +
           "Set-ItemProperty 'HKCU:\Control Panel\Desktop' -Name WallpaperStyle -Value $(Q $fe.Style); Set-ItemProperty 'HKCU:\Control Panel\Desktop' -Name TileWallpaper -Value $(Q $fe.Mosaique); " +
           "$spi; [Mig.U]::SystemParametersInfo(20, 0, $(Q $dstImg), 3)"
    $wpActs += ACmd 'Copier la commande de correction' $cmd $false $true
  }
  $wpActs += $aBg
  Check $C_PER "Image du fond d'écran" $oldName $(if ($curWp) { Split-Path $curWp -Leaf } else { 'Aucune' }) (St $same) $note $wpActs
  $oStyle = if ([string]$fe.Style -eq '0' -and [string]$fe.Mosaique -eq '1') { 'Mosaïque' } else { $styles[[string]$fe.Style] }
  $nStyle = if ([string]$curDesk.WallpaperStyle -eq '0' -and [string]$curDesk.TileWallpaper -eq '1') { 'Mosaïque' } else { $styles[[string]$curDesk.WallpaperStyle] }
  $cmd = "Set-ItemProperty 'HKCU:\Control Panel\Desktop' -Name WallpaperStyle -Value $(Q $fe.Style); Set-ItemProperty 'HKCU:\Control Panel\Desktop' -Name TileWallpaper -Value $(Q $fe.Mosaique); $spi; [Mig.U]::SystemParametersInfo(20, 0, (Get-ItemProperty 'HKCU:\Control Panel\Desktop').WallPaper, 3)"
  Check $C_PER "Ajustement de l'image" $oStyle $nStyle (St ($oStyle -eq $nStyle)) "Remettre l'ajustement « $oStyle »" @((ACmd 'Copier la commande de correction' $cmd $false $true), $aBg)
}
$pz = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
$dwm = 'HKCU:\Software\Microsoft\Windows\DWM'
$mouse = 'HKCU:\Control Panel\Mouse'
$lumi = @{ '0' = 'Sombre'; '1' = 'Clair' }; $onoff = @{ '0' = 'Désactivé'; '1' = 'Activé' }
CmpVal $C_PER 'Mode Windows'           $inv.Theme.SystemeClair (RegVal $pz 'SystemUsesLightTheme') $lumi '1' '1' '' @{ p = $pz; n = 'SystemUsesLightTheme'; o = 'ms-settings:colors' }
CmpVal $C_PER 'Mode des applications'  $inv.Theme.AppsClair    (RegVal $pz 'AppsUseLightTheme')    $lumi '1' '1' '' @{ p = $pz; n = 'AppsUseLightTheme'; o = 'ms-settings:colors' }
CmpVal $C_PER 'Effets de transparence' $inv.Theme.Transparence (RegVal $pz 'EnableTransparency')   $onoff '1' '1' '' @{ p = $pz; n = 'EnableTransparency'; o = 'ms-settings:colors' }
CmpVal $C_PER "Couleur d'accentuation" $inv.Theme.Accent (AccentHex (RegVal $dwm 'AccentColor')) $null '' '' "Choisir la couleur $($inv.Theme.Accent) dans Couleurs > Couleur d'accentuation (manuel)" $null @((AOpen "Ouvrir Paramètres > Couleurs" 'ms-settings:colors'))
CmpVal $C_PER "Couleur sur Démarrer et barre des tâches" $inv.Theme.CouleurBarres (RegVal $pz 'ColorPrevalence') $onoff '0' '0' '' @{ p = $pz; n = 'ColorPrevalence'; o = 'ms-settings:colors' }
CmpVal $C_PER "Couleur sur les barres de titre" $inv.Theme.AccentTitres (RegVal $dwm 'ColorPrevalence') $onoff '0' '0' '' @{ p = $dwm; n = 'ColorPrevalence'; o = 'ms-settings:colors' }
CmpVal $C_PER 'Vitesse du pointeur'    $inv.Souris.Vitesse     (RegVal $mouse 'MouseSensitivity') $null '10' '10' 'Effet à la prochaine ouverture de session' @{ p = $mouse; n = 'MouseSensitivity'; t = 'String'; o = 'ms-settings:mousetouchpad' }
CmpVal $C_PER 'Vitesse du double-clic' $inv.Souris.DoubleClic  (RegVal $mouse 'DoubleClickSpeed') $null '500' '500' 'Effet à la prochaine ouverture de session' @{ p = $mouse; n = 'DoubleClickSpeed'; t = 'String'; o = 'ms-settings:mousetouchpad' }
CmpVal $C_PER 'Boutons de la souris'   $inv.Souris.BoutonsInverses (RegVal $mouse 'SwapMouseButtons') @{ '0' = 'Normal'; '1' = 'Inversés (gaucher)' } '0' '0' 'Effet à la prochaine ouverture de session' @{ p = $mouse; n = 'SwapMouseButtons'; t = 'String'; o = 'ms-settings:mousetouchpad' }

# ------------------------------------------------------------ Bureau
$curDeskPath = [Environment]::GetFolderPath('Desktop')
$pubDeskPath = [Environment]::GetFolderPath('CommonDesktopDirectory')
foreach ($e in @($inv.Bureau.Elements)) {
  $p1 = Join-Path $curDeskPath $e.Nom; $p2 = if ($pubDeskPath) { Join-Path $pubDeskPath $e.Nom } else { $null }
  $where = $null
  if (Test-Path -LiteralPath $p1) { $where = $p1 } elseif ($p2 -and (Test-Path -LiteralPath $p2)) { $where = $p2 }
  $st = St $where; $note = ''; $acts = @()
  if ($where -and $e.Cible) {
    $t = $e.Cible; try { $t = $wsh.CreateShortcut($where).TargetPath } catch { }
    if ($t -and -not (Test-Path -LiteralPath $t)) {
      $st = 'ECART'; $note = "Le raccourci pointe vers un programme absent ($t) : installer le logiciel."
      $acts += ANav 'Voir les logiciels manquants' '#logiciels'
    }
  }
  if (-not $where) {
    $srcL = Join-Path (Src 'bureau\raccourcis') $e.Nom
    if ($e.Type -eq 'Raccourci' -and (Test-Path -LiteralPath $srcL)) {
      $note = 'Raccourci manquant : la commande le recopie depuis le dossier de migration.'
      $acts += ACmd 'Copier la commande de correction' "Copy-Item -LiteralPath $(Q $srcL) -Destination $(Q $p1)" $false $true
    } elseif ($e.Type -eq 'Raccourci') { $note = "Raccourci de l'ancien Bureau public (installé avec le logiciel)" ; $acts += ANav 'Voir les logiciels manquants' '#logiciels' }
    else { $note = 'Donnée non recopiée : relancer la copie du Bureau.'; $acts += ANav 'Voir la rubrique Fichiers' '#fichiers' }
  }
  $o = "$($e.Type)$(if ($e.Emplacement -eq 'Public') { ' · tous les utilisateurs' })"
  Check $C_BUR $e.Nom $o $(if ($where) { 'Présent' } else { 'Absent' }) $st $note $acts
}
$bagK = 'HKCU:\Software\Microsoft\Windows\Shell\Bags\1\Desktop'
$ff = RegVal $bagK 'FFlags'
$yn = @{ 'True' = 'Oui'; 'False' = 'Non' }
if ($null -ne $inv.Bureau.FFlags -and $null -ne $ff) {
  $rg = @{ p = $bagK; n = 'FFlags'; v = $inv.Bureau.FFlags; x = 'wrap' }
  CmpVal $C_BUR 'Réorganisation automatique des icônes' ([string](([int64]$inv.Bureau.FFlags -band 1) -ne 0)) ([string](([int64]$ff -band 1) -ne 0)) $yn '' '' 'Ou : clic droit sur le Bureau > Affichage' $rg
  CmpVal $C_BUR 'Aligner les icônes sur la grille'     ([string](([int64]$inv.Bureau.FFlags -band 4) -ne 0)) ([string](([int64]$ff -band 4) -ne 0)) $yn '' '' 'Ou : clic droit sur le Bureau > Affichage' $rg
}
CmpVal $C_BUR 'Taille des icônes' $inv.Bureau.IconSize (RegVal $bagK 'IconSize') @{ '32' = 'Petites'; '48' = 'Moyennes'; '96' = 'Grandes' } '48' '48' 'Ou : clic droit sur le Bureau > Affichage' @{ p = $bagK; n = 'IconSize'; x = 'wrap' }
$curSys = Get-SysIcons
$sysGuid = @{}; foreach ($g in $script:sysIconNames.Keys) { $sysGuid[$script:sysIconNames[$g]] = $g }
foreach ($p in (Props $inv.Bureau.IconesSysteme)) {
  $want = if ([string]$p.Value -eq 'True') { 0 } else { 1 }
  CmpVal $C_BUR "Icône « $($p.Name) »" ([string]$p.Value) ([string]$curSys[$p.Name]) @{ 'True' = 'Affichée'; 'False' = 'Masquée' } '' '' '' @{ p = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel'; n = $sysGuid[$p.Name]; v = $want; x = 'explorer'; o = 'ms-settings:themes' }
}
Check $C_BUR 'Position des icônes' 'Voir capture « avant »' 'Voir capture « après »' 'MANUEL' "Comparer les deux captures avec l'utilisateur" @((ANav 'Voir les captures avant / après' '#captures'))

# ------------------------------------------------------------ Barre des tâches & Démarrer
$aTb = 'ms-settings:taskbar'
$curPins = @(Get-ChildItem $pinDir -File -Filter *.lnk -ErrorAction SilentlyContinue | ForEach-Object { $_.BaseName })
foreach ($p in @($inv.Epingles)) {
  $ok = $curPins -contains $p
  Check $C_BAR "Épingle « $p »" 'Épinglée' $(if ($ok) { 'Épinglée' } else { 'Absente' }) (St $ok) $(if (-not $ok) { "Windows ne permet pas d'épingler par script : menu Démarrer > clic droit sur « $p » > Épingler à la barre des tâches" })
}
if (@($inv.Epingles).Count) { Check $C_BAR "Ordre des épingles" 'Voir capture « avant »' 'Voir capture « après »' 'MANUEL' "Vérifier l'ordre des icônes ; glisser-déposer pour les réordonner" @((ANav 'Voir les captures avant / après' '#captures')) }
$opt = $inv.Options
$adv = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
$srch = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search'
if ($dstWin11) {
  $defAlOld = if ($srcWin11) { '1' } else { '0' }
  CmpVal $C_BAR 'Alignement de la barre' $opt.TaskbarAl (RegVal $adv 'TaskbarAl') @{ '0' = 'À gauche'; '1' = 'Centré' } $defAlOld '1' '' @{ p = $adv; n = 'TaskbarAl'; x = 'explorer'; o = $aTb }
}
CmpVal $C_BAR 'Regroupement des boutons' $opt.TaskbarGlomLevel (RegVal $adv 'TaskbarGlomLevel') @{ '0' = 'Toujours regrouper'; '1' = 'Si la barre est pleine'; '2' = 'Jamais' } '0' '0' '' @{ p = $adv; n = 'TaskbarGlomLevel'; x = 'explorer'; o = $aTb }
CmpVal $C_BAR 'Bouton « Affichage des tâches »' $opt.ShowTaskViewButton (RegVal $adv 'ShowTaskViewButton') @{ '0' = 'Masqué'; '1' = 'Affiché' } '1' '1' '' @{ p = $adv; n = 'ShowTaskViewButton'; x = 'explorer'; o = $aTb }
CmpVal $C_BAR 'Recherche dans la barre' $opt.SearchboxTaskbarMode (RegVal $srch 'SearchboxTaskbarMode') @{ '0' = 'Masquée'; '1' = 'Icône'; '2' = 'Zone de recherche'; '3' = 'Bouton' } '2' '2' '' @{ p = $srch; n = 'SearchboxTaskbarMode'; x = 'explorer'; o = $aTb }
CmpVal $C_BAR "Secondes dans l'horloge" $opt.ShowSecondsInSystemClock (RegVal $adv 'ShowSecondsInSystemClock') @{ '0' = 'Non'; '1' = 'Oui' } '0' '0' '' @{ p = $adv; n = 'ShowSecondsInSystemClock'; x = 'explorer'; o = $aTb }
if ($srcWin11 -eq $dstWin11) {
  if (-not $dstWin11) { CmpVal $C_BAR 'Petites icônes' $opt.TaskbarSmallIcons (RegVal $adv 'TaskbarSmallIcons') @{ '0' = 'Non'; '1' = 'Oui' } '0' '0' '' @{ p = $adv; n = 'TaskbarSmallIcons'; x = 'explorer'; o = $aTb } }
} else {
  Check $C_BAR 'Options propres à Windows 10' 'Petites icônes, taille de la barre' 'Non disponibles sous Windows 11' 'INFO'
}
$aStart = AOpen "Ouvrir Paramètres > Démarrer" 'ms-settings:personalization-start'
$srcStartBin = Get-ChildItem (Src 'barre_taches_demarrer\StartMenu_LocalState') -Filter 'start*.bin' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($srcWin11 -and $dstWin11 -and $srcStartBin) {
  $dstBin = Join-Path $startDir $srcStartBin.Name
  $same = (Test-Path $dstBin) -and ((Get-FileHash $dstBin).Hash -eq (Get-FileHash $srcStartBin.FullName).Hash)
  $cmd = "Stop-Process -Name StartMenuExperienceHost -Force -ErrorAction SilentlyContinue; Copy-Item -LiteralPath $(Q $srcStartBin.FullName) -Destination $(Q $dstBin) -Force"
  Check $C_BAR 'Épingles du menu Démarrer' 'Disposition relevée' $(if ($same) { 'Disposition restaurée' } else { 'Modifiée depuis' }) $(if ($same) { 'OK' } else { 'MANUEL' }) "Ouvrir le menu Démarrer et comparer (une appli non installée disparaît du menu). La commande remet la disposition d'origine." @((ACmd 'Copier la commande de restauration du menu' $cmd), $aStart)
} else {
  $list = @($inv.MenuDemarrer.Epingles) -join ', '
  Check $C_BAR 'Épingles du menu Démarrer' $inv.MenuDemarrer.Type 'À refaire à la main' 'MANUEL' $(if ($list) { "Épingles d'origine : $list" } else { "Voir les photos prises sur l'ancien poste" }) @($aStart)
}
if ($inv.AccesRapide) {
  $srcQa = Src 'barre_taches_demarrer\acces_rapide.automaticDestinations-ms'
  $same = (Test-Path $qaFile) -and (Test-Path $srcQa) -and ((Get-FileHash $qaFile).Hash -eq (Get-FileHash $srcQa).Hash)
  $cmd = ExplorerWrap "Copy-Item -LiteralPath $(Q $srcQa) -Destination $(Q $qaFile) -Force"
  Check $C_EXP 'Dossiers épinglés (Accès rapide)' 'Relevés' $(if ($same) { 'Restaurés' } else { 'Modifiés depuis' }) $(if ($same) { 'OK' } else { 'MANUEL' }) "Ouvrir l'Explorateur et vérifier les dossiers épinglés ; la commande remet ceux de l'ancien poste." @((ACmd 'Copier la commande de restauration' $cmd))
}

# ------------------------------------------------------------ Explorateur
CmpVal $C_EXP 'Extensions des fichiers' $opt.HideFileExt (RegVal $adv 'HideFileExt') @{ '0' = 'Affichées'; '1' = 'Masquées' } '1' '1' '' @{ p = $adv; n = 'HideFileExt'; x = 'explorer' }
CmpVal $C_EXP 'Fichiers cachés' $opt.Hidden (RegVal $adv 'Hidden') @{ '1' = 'Affichés'; '2' = 'Masqués' } '2' '2' '' @{ p = $adv; n = 'Hidden'; x = 'explorer' }
CmpVal $C_EXP 'Fichiers système protégés' $opt.ShowSuperHidden (RegVal $adv 'ShowSuperHidden') @{ '0' = 'Masqués'; '1' = 'Affichés' } '0' '0' '' @{ p = $adv; n = 'ShowSuperHidden'; x = 'explorer' }
CmpVal $C_EXP "Ouverture de l'Explorateur sur" $opt.LaunchTo (RegVal $adv 'LaunchTo') @{ '1' = 'Ce PC'; '2' = 'Accès rapide / Accueil'; '3' = 'Téléchargements'; '4' = 'OneDrive' } '2' '2' '' @{ p = $adv; n = 'LaunchTo'; x = 'explorer' }
CmpVal $C_EXP 'Volet de navigation : tous les dossiers' $opt.NavPaneShowAllFolders (RegVal $adv 'NavPaneShowAllFolders') @{ '0' = 'Non'; '1' = 'Oui' } '0' '0' '' @{ p = $adv; n = 'NavPaneShowAllFolders'; x = 'explorer' }

# ------------------------------------------------------------ Lecteurs réseau
$mapped = @{}
Get-CimInstance Win32_MappedLogicalDisk -ErrorAction SilentlyContinue | ForEach-Object { $mapped[$_.Name.TrimEnd(':')] = [string]$_.ProviderName }
foreach ($d in @($inv.Lecteurs)) {
  $l = $d.Lettre; $reg = RegVal "HKCU:\Network\$l" 'RemotePath'; $acts = @()
  $fix = "net use $($l): $(Q $d.Chemin) /persistent:yes"
  if ($mapped.ContainsKey($l)) { $n = $mapped[$l]; $st = St ($n -eq $d.Chemin); $note = ''; if ($st -ne 'OK') { $fix = "net use $($l): /delete /y; $fix"; $note = "La lettre $($l): pointe ailleurs" } }
  elseif ($reg) { $n = $reg; $st = St ($reg -eq $d.Chemin); $note = 'Se reconnectera à la prochaine ouverture de session (VPN monté si hors site)'; if ($st -ne 'OK') { $fix = "net use $($l): /delete /y; $fix" } }
  else { $n = 'Non connecté'; $st = 'ECART'; $note = "Lecteur absent (si une GPO le mappe normalement, lancer gpupdate /force avec le VPN monté)" }
  if ($st -ne 'OK') { $acts += ACmd 'Copier la commande de correction' $fix $false $true }
  Check $C_LEC "Lecteur $($l):" $d.Chemin $n $st $note $acts
}
if (@($inv.Lecteurs).Count) { Check $C_LEC 'Accès aux lecteurs' 'Fonctionnel' 'À tester' 'MANUEL' "Ouvrir un fichier sur chaque lecteur avec l'utilisateur" }

# ------------------------------------------------------------ Imprimantes
$aPr = AOpen "Ouvrir Paramètres > Imprimantes" 'ms-settings:printers'
$curPr = @(Get-Printer -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
foreach ($p in @($inv.Imprimantes)) {
  $ok = $curPr -contains $p.Nom
  if ($p.Virtuelle) { Check $C_IMP $p.Nom 'Imprimante virtuelle' $(if ($ok) { 'Présente' } else { 'Absente' }) $(if ($ok) { 'OK' } else { 'INFO' }); continue }
  $type = if ($p.Reseau) { 'Partagée (serveur)' } else { 'Locale / IP' }
  $note = ''; $acts = @()
  if (-not $ok) {
    if ($p.Reseau) {
      $note = "Si la connexion échoue : vérifier le serveur d'impression et la stratégie Point and Print"
      $acts += ACmd 'Copier la commande de correction' "Add-Printer -ConnectionName $(Q $p.Nom)" $false $true
    } else {
      $hostIp = if ($p.Port -match '^IP_(.+)$') { $Matches[1] } elseif ($p.Port -match '^\d{1,3}(\.\d{1,3}){3}$') { $p.Port } else { $null }
      if ($hostIp) {
        $note = "Installer d'abord le pilote « $($p.Pilote) », puis lancer la commande en administrateur"
        $acts += ACmd 'Copier la commande d''installation' "Add-PrinterPort -Name $(Q $p.Port) -PrinterHostAddress $(Q $hostIp) -ErrorAction SilentlyContinue; Add-Printer -Name $(Q $p.Nom) -DriverName $(Q $p.Pilote) -PortName $(Q $p.Port)" $true
      } else { $note = "Imprimante locale (port $($p.Port)) : installer le pilote « $($p.Pilote) » du fabricant" }
    }
    $acts += $aPr
  }
  Check $C_IMP $p.Nom $type $(if ($ok) { 'Installée' } else { 'Absente' }) (St $ok) $note $acts
}
$curDef = [string](Get-CimInstance Win32_Printer -Filter 'Default=TRUE' -ErrorAction SilentlyContinue).Name
if ($inv.ImprimanteDefaut) {
  $cmd = "Set-ItemProperty 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Windows' -Name LegacyDefaultPrinterMode -Value 1 -Type DWord; (New-Object -ComObject WScript.Network).SetDefaultPrinter($(Q $inv.ImprimanteDefaut))"
  Check $C_IMP 'Imprimante par défaut' $inv.ImprimanteDefaut $curDef (St ($curDef -eq $inv.ImprimanteDefaut)) 'Installer d''abord l''imprimante si elle est absente' @((ACmd 'Copier la commande de correction' $cmd $false $true), $aPr)
}
if (@($inv.Imprimantes | Where-Object { -not $_.Virtuelle }).Count) { Check $C_IMP "Test d'impression" 'Fonctionnel' 'À tester' 'MANUEL' "Imprimer une page de test sur l'imprimante par défaut" @($aPr) }

# ------------------------------------------------------------ Logiciels
$techRx = '(?i)(redistributable|runtime|update for|hotfix|security update|\bKB\d{6,}|driver|pilote|\bSDK\b|\.NET|framework|language pack|module linguistique|webview2|visual c\+\+|edge update|machine-wide|click-to-run|realtek|intel\(r\)|^intel |nvidia|synaptics|^dell |^hp |^lenovo |bios|firmware|chipset|thunderbolt|bluetooth|touchpad|support ?assist|management engine|^microsoft update health|^windows pc health)'
$curApps = @(Get-Apps)
$exact = @{}; $norm = @{}
foreach ($a in $curApps) { $exact[$a.Nom] = $a.Version; $k = Norm $a.Nom; if ($k -and -not $norm.ContainsKey($k)) { $norm[$k] = $a } }
foreach ($a in @($inv.Logiciels)) {
  $tech = $a.Nom -match $techRx; $k = Norm $a.Nom
  if ($exact.ContainsKey($a.Nom)) {
    $v = $exact[$a.Nom]
    Check $C_LOG $a.Nom $a.Version "Installé $v" 'OK' $(if ($v -ne $a.Version -and $a.Version) { 'Version différente' })
  } elseif ($k -and $norm.ContainsKey($k)) {
    Check $C_LOG $a.Nom $a.Version "$($norm[$k].Nom) $($norm[$k].Version)" 'OK' 'Autre version installée'
  } elseif ($tech) {
    Check $C_LOG $a.Nom $a.Version 'Non installé' 'INFO' "Composant technique ou propre à l'ancien matériel"
  } else {
    $q = ($a.Nom -replace '\s*\(.*?\)', '' -replace '\s+[\d\.]+$', '').Trim()
    Check $C_LOG $a.Nom $a.Version 'Non installé' 'ECART' "À installer (ou à confirmer comme inutile avec l'utilisateur)" @(
      (ACmd 'Copier la recherche winget' "winget search $(Q $q)"),
      (AOpen 'Chercher dans le Microsoft Store' ("ms-windows-store://search/?query=" + [uri]::EscapeDataString($q))),
      (AWeb 'Chercher le site de l''éditeur' ("https://www.bing.com/search?q=" + [uri]::EscapeDataString("$q $($a.Editeur) téléchargement"))))
  }
}
$curStore = @(Get-AppxPackage -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
foreach ($s in @($inv.ApplisStore)) {
  if ($curStore -notcontains $s) {
    $q = ($s -split '\.')[-1]
    Check $C_LOG "Appli Store : $s" 'Installée' 'Absente' 'INFO' 'À installer depuis le Microsoft Store si utilisée' @((AOpen 'Chercher dans le Microsoft Store' ("ms-windows-store://search/?query=" + [uri]::EscapeDataString($q))))
  }
}
$curRun = @(Get-CimInstance Win32_StartupCommand -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.Name })
foreach ($s in @($inv.Demarrage)) {
  if ($curRun -notcontains $s) { Check $C_LOG "Lancement au démarrage : $s" 'Actif' 'Absent' 'INFO' "Se met en place à l'installation du logiciel ; sinon l'activer dans Applications de démarrage" @((AOpen 'Ouvrir Applications de démarrage' 'ms-settings:startupapps')) }
}

# ------------------------------------------------------------ Navigateurs
$setUrl = @{ 'Edge' = @{ start = 'edge://settings/startHomePage'; pwd = 'edge://settings/passwords'; look = 'edge://settings/appearance' }
             'Chrome' = @{ start = 'chrome://settings/onStartup'; pwd = 'chrome://password-manager/settings'; look = 'chrome://settings/appearance' } }
$hintAddr = "Collez dans la barre d'adresse du navigateur (ces pages ne peuvent pas s'ouvrir depuis un lien)"
foreach ($nv in @($inv.Navigateurs)) {
  $b = $nv.Navigateur; $u = $setUrl[$b]
  $lab = "$b · $(if ($nv.NomAffiche) { $nv.NomAffiche } else { $nv.Profil })"
  $dp = Join-Path $browserData[$b] $nv.Profil
  if (-not (Test-Path $dp)) { Check $C_NAV "$lab — profil" 'Existant' 'Absent' 'ECART' "Lancer $b une fois (création du profil) puis relancer la restauration" @((ACmd "Copier la commande pour lancer $b" "Start-Process $($browserProc[$b])")); continue }
  $cnt = Get-BookmarkCount (Join-Path $dp 'Bookmarks')
  $srcBm = Src "navigateurs\$b\$($nv.Profil)\Bookmarks"
  $bmActs = @()
  if (Test-Path $srcBm) { $bmActs += ACmd 'Copier la commande de correction' "Stop-Process -Name $($browserProc[$b]) -Force -ErrorAction SilentlyContinue; Start-Sleep -Seconds 2; Copy-Item -LiteralPath $(Q $srcBm) -Destination $(Q (Join-Path $dp 'Bookmarks')) -Force" $false $true }
  Check $C_NAV "$lab — favoris" "$($nv.Favoris) favoris" "$cnt favoris" (St ($cnt -ge $nv.Favoris)) "La commande ferme $b et remet les favoris de l'ancien poste" $bmActs
  $pj = $null; try { $pj = Get-Content (Join-Path $dp 'Preferences') -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
  $restoreLib = @{ '1' = 'Restaurer la session précédente'; '4' = 'Ouvrir des pages spécifiques'; '5' = 'Nouvel onglet' }
  $oStart = "$($nv.Demarrage) $(@($nv.PagesDemarrage) -join ', ')".Trim()
  $nStart = if ($pj) { "$($restoreLib[[string]$pj.session.restore_on_startup]) $(@($pj.session.startup_urls) -join ', ')".Trim() } else { '' }
  if ($oStart) {
    $acts = @((ACopy "Copier l'adresse du réglage ($($u.start))" $u.start $hintAddr))
    if (@($nv.PagesDemarrage).Count) { $acts += ACopy 'Copier les pages à ajouter' (@($nv.PagesDemarrage) -join "`r`n") 'Une adresse par ligne, à ajouter dans « Ouvrir des pages spécifiques »' }
    Check $C_NAV "$lab — au démarrage" $oStart $nStart $(if ($oStart -eq $nStart) { 'OK' } else { 'MANUEL' }) "Régler « $($nv.Demarrage) »" $acts
  }
  if ($nv.PageAccueil) {
    Check $C_NAV "$lab — page d'accueil" $nv.PageAccueil $(if ($pj) { [string]$pj.homepage }) $(if ($pj -and [string]$pj.homepage -eq $nv.PageAccueil) { 'OK' } else { 'MANUEL' }) "Saisir $($nv.PageAccueil) comme page d'accueil" @((ACopy "Copier l'adresse du réglage" $u.start $hintAddr), (ACopy "Copier l'adresse de la page d'accueil" $nv.PageAccueil 'À coller dans le champ « page d''accueil »'))
  }
  if ($null -ne $nv.BarreFavoris) {
    $nb = if ($pj) { $pj.bookmark_bar.show_on_all_tabs } else { $null }
    CmpVal $C_NAV "$lab — barre des favoris" ([string]$nv.BarreFavoris) ([string]$nb) @{ 'True' = 'Affichée'; 'False' = 'Masquée' } 'False' 'False' "Raccourci clavier Ctrl+Maj+B dans $b" $null @((ACopy "Copier l'adresse du réglage" $u.look $hintAddr))
  }
  $have = @(Get-ChildItem (Join-Path $dp 'Extensions') -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
  foreach ($e in @($nv.Extensions)) {
    $nm = if ($e.Nom) { $e.Nom } else { $e.Id }
    $ok = $have -contains $e.Id
    $acts = @()
    if ($b -eq 'Edge') { $acts += AWeb 'Ouvrir dans la boutique Edge' "https://microsoftedge.microsoft.com/addons/detail/$($e.Id)" }
    $acts += AWeb 'Ouvrir dans le Chrome Web Store' "https://chromewebstore.google.com/detail/$($e.Id)"
    Check $C_NAV "$lab — extension « $nm »" 'Installée' $(if ($ok) { 'Installée' } else { 'Absente' }) $(if ($ok) { 'OK' } else { 'MANUEL' }) $(if (-not $ok) { "Revient seule si la synchronisation du navigateur est active ; sinon l'installer depuis la boutique (ouvrir le lien dans $b)" }) $acts
  }
  $navDir = Join-Path $donnees 'Navigateurs'
  $csvs = @(Get-ChildItem $navDir -Filter *.csv -ErrorAction SilentlyContinue)
  $pnote = if ($csvs.Count) { "Fichier(s) exporté(s) trouvé(s) ($(($csvs | ForEach-Object { $_.Name }) -join ', ')) : page des mots de passe > Importer, puis supprimer le fichier" } else { "Activer la synchronisation du compte dans $b, ou importer le CSV exporté sur l'ancien poste puis le supprimer" }
  $pacts = @((ACopy "Copier l'adresse du gestionnaire de mots de passe" $u.pwd $hintAddr))
  if ($csvs.Count) { $pacts += ACmd 'Copier la commande pour ouvrir le dossier des fichiers exportés' "explorer.exe $(Q $navDir)" }
  Check $C_NAV "$lab — mots de passe enregistrés" 'Enregistrés' 'Non transférés automatiquement' 'MANUEL' $pnote $pacts
}
foreach ($f in @($inv.Firefox)) { Check $C_NAV "Firefox · $f" 'Utilisé' 'À transférer' 'MANUEL' 'Installer Firefox puis se connecter à Firefox Sync' @((AWeb 'Télécharger Firefox' 'https://www.mozilla.org/fr/firefox/new/')) }

# ------------------------------------------------------------ Office, Outlook, Teams
$sigDst = "$env:APPDATA\Microsoft\Signatures"
foreach ($s in @($inv.Office.Signatures)) {
  $ok = Test-Path -LiteralPath (Join-Path $sigDst "$s.htm")
  $cmd = "New-Item -ItemType Directory -Path $(Q $sigDst) -Force | Out-Null; Copy-Item -Path $(Q ((Src 'office\Signatures') + '\' + ($s -replace '([\[\]\*\?])', '`$1') + '*')) -Destination $(Q $sigDst) -Recurse -Force"
  Check $C_OFF "Signature « $s »" 'Présente' $(if ($ok) { 'Présente' } else { 'Absente' }) (St $ok) 'Outlook fermé' @((ACmd 'Copier la commande de correction' $cmd $false $true))
}
$curSig = @(Get-OutlookDefaultSig)
foreach ($d in @($inv.Office.SignatureDefaut)) {
  $m = $curSig | Where-Object { $_.Compte -eq $d.Compte } | Select-Object -First 1
  $oTxt = "Nouveaux : $($d.Nouveau) · Réponses : $($d.Reponse)"
  if ($m) { $nTxt = "Nouveaux : $($m.Nouveau) · Réponses : $($m.Reponse)"; $ok = ($m.Nouveau -eq $d.Nouveau -and $m.Reponse -eq $d.Reponse) }
  else { $nTxt = 'Non définie'; $ok = $false }
  Check $C_OFF "Signature par défaut ($($d.Compte))" $oTxt $nTxt $(if ($ok) { 'OK' } else { 'MANUEL' }) "Outlook > Fichier > Options > Courrier > Signatures : choisir « $($d.Nouveau) » (nouveaux) et « $($d.Reponse) » (réponses)" @((ACmd 'Copier la commande pour ouvrir Outlook' 'Start-Process outlook'))
}
if (@($inv.Office.Signatures).Count -and -not @($inv.Office.SignatureDefaut).Count) {
  Check $C_OFF 'Signature par défaut' 'Non relevée' 'À vérifier' 'MANUEL' 'Vérifier dans Outlook la signature des nouveaux messages et des réponses' @((ACmd 'Copier la commande pour ouvrir Outlook' 'Start-Process outlook'))
}
$tplDst = "$env:APPDATA\Microsoft\Templates"
$tplSrcRoot = Src 'office\Templates'
$curTpl = @(Get-FilesSafe $tplDst | ForEach-Object { $_.Name })
$tplSrc = @{}; Get-FilesSafe $tplSrcRoot | ForEach-Object { if (-not $tplSrc.ContainsKey($_.Name)) { $tplSrc[$_.Name] = $_.FullName } }
foreach ($t in @($inv.Office.Modeles)) {
  $ok = $curTpl -contains $t; $acts = @()
  if (-not $ok -and $tplSrc.ContainsKey($t)) {
    $dst = $tplDst + $tplSrc[$t].Substring($tplSrcRoot.Length)
    $acts += ACmd 'Copier la commande de correction' "New-Item -ItemType Directory -Path $(Q (Split-Path $dst -Parent)) -Force | Out-Null; Copy-Item -LiteralPath $(Q $tplSrc[$t]) -Destination $(Q $dst) -Force" $false $true
  }
  Check $C_OFF "Modèle « $t »" 'Présent' $(if ($ok) { 'Présent' } else { 'Absent' }) (St $ok) 'Word fermé' $acts
}
$dicDst = "$env:APPDATA\Microsoft\UProof"
foreach ($t in @($inv.Office.Dictionnaires)) {
  $ok = Test-Path -LiteralPath (Join-Path $dicDst $t)
  $cmd = "New-Item -ItemType Directory -Path $(Q $dicDst) -Force | Out-Null; Copy-Item -LiteralPath $(Q (Join-Path (Src 'office\UProof') $t)) -Destination $(Q $dicDst) -Force"
  Check $C_OFF "Dictionnaire « $t »" 'Présent' $(if ($ok) { 'Présent' } else { 'Absent' }) (St $ok) 'Office fermé' @((ACmd 'Copier la commande de correction' $cmd $false $true))
}
$fontDst = "$env:LOCALAPPDATA\Microsoft\Windows\Fonts"
foreach ($t in @($inv.Office.Polices)) {
  $ok = Test-Path -LiteralPath (Join-Path $fontDst $t)
  $suffix = if ($t -like '*.otf') { '(OpenType)' } else { '(TrueType)' }
  $cmd = "New-Item -ItemType Directory -Path $(Q $fontDst) -Force | Out-Null; Copy-Item -LiteralPath $(Q (Join-Path (Src 'office\polices_utilisateur') $t)) -Destination $(Q $fontDst) -Force; " +
         "if (-not (Test-Path 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts')) { New-Item 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts' -Force | Out-Null }; " +
         "Set-ItemProperty 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts' -Name $(Q ("$([IO.Path]::GetFileNameWithoutExtension($t)) $suffix")) -Value $(Q (Join-Path $fontDst $t))"
  Check $C_OFF "Police « $t »" 'Installée' $(if ($ok) { 'Installée' } else { 'Absente' }) (St $ok) 'Relancer les applications Office après correction' @((ACmd 'Copier la commande de correction' $cmd $false $true))
}
if (@($inv.Office.FondsTeams).Count) {
  $teamsDst = "$env:LOCALAPPDATA\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\Backgrounds\Uploads"
  $tb = @(Get-ChildItem $teamsDst -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '*_thumb*' })
  $cmd = "New-Item -ItemType Directory -Path $(Q $teamsDst) -Force | Out-Null; Copy-Item -Path $(Q ((Src 'office\teams_arriere_plans') + '\*')) -Destination $(Q $teamsDst) -Force"
  Check $C_OFF 'Arrière-plans Teams' "$(@($inv.Office.FondsTeams).Count) image(s)" "$($tb.Count) image(s)" (St ($tb.Count -ge @($inv.Office.FondsTeams).Count)) 'Teams lancé au moins une fois, puis fermé' @((ACmd 'Copier la commande de correction' $cmd $false $true))
}
foreach ($p in @($inv.Office.PST)) {
  $np = Tr $p.Chemin
  $ok = Test-Path -LiteralPath $np
  if ($ok) {
    Check $C_OFF "Fichier PST $(Split-Path $p.Chemin -Leaf)" "$(Mo $p.Octets) · $($p.Chemin)" "Présent · $np" 'MANUEL' "Vérifier qu'il est ouvert dans Outlook ; sinon Fichier > Ouvrir et exporter > Ouvrir un fichier de données Outlook" @((ACopy 'Copier le chemin du PST' $np 'À coller dans la fenêtre « Ouvrir un fichier de données Outlook »'), (ACmd 'Copier la commande pour ouvrir Outlook' 'Start-Process outlook'))
  } else {
    $pp2 = @($plan.Pst) | Where-Object { $_.Source -eq $p.Chemin } | Select-Object -First 1
    if ($pp2) {
      $srcPst = Join-Path (Join-Path $donnees $pp2.Cible) (Split-Path $p.Chemin -Leaf)
      Check $C_OFF "Fichier PST $(Split-Path $p.Chemin -Leaf)" "$(Mo $p.Octets) · $($p.Chemin)" "Absent : $np" 'ECART' "Recopier le PST (Outlook fermé), puis le rattacher dans Outlook" @((ACmd 'Copier la commande de recopie' "Get-Process OUTLOOK -ErrorAction SilentlyContinue | ForEach-Object { [void]`$_.CloseMainWindow() }; Start-Sleep -Seconds 5; New-Item -ItemType Directory -Path $(Q (Split-Path $np -Parent)) -Force | Out-Null; Copy-Item -LiteralPath $(Q $srcPst) -Destination $(Q $np)"))
    } else {
      Check $C_OFF "Fichier PST $(Split-Path $p.Chemin -Leaf)" "$(Mo $p.Octets) · $($p.Chemin)" "Absent : $np" 'ECART' "Ce PST était dans un dossier recopié (Documents…) ou synchronisé par OneDrive : vérifier la copie de ce dossier" @((ANav 'Voir la rubrique Fichiers' '#fichiers'))
    }
  }
}
if (@($inv.Office.ProfilsOutlook).Count) {
  $npf = @(Get-ChildItem 'HKCU:\Software\Microsoft\Office\16.0\Outlook\Profiles' -ErrorAction SilentlyContinue)
  Check $C_OFF 'Profil Outlook' (@($inv.Office.ProfilsOutlook) -join ', ') $(if ($npf.Count) { ($npf | ForEach-Object { $_.PSChildName }) -join ', ' } else { 'Aucun' }) $(if ($npf.Count) { 'OK' } else { 'MANUEL' }) 'Ouvrir Outlook une fois : le profil se crée automatiquement' @((ACmd 'Copier la commande pour ouvrir Outlook' 'Start-Process outlook'))
}
if ($inv.Office.PenseBetes) { Check $C_OFF 'Pense-bêtes' 'Utilisés' 'À vérifier' 'MANUEL' 'Ouvrir Pense-bêtes : ils reviennent via le compte Microsoft 365' @((AOpen 'Chercher Pense-bêtes dans le Store' 'ms-windows-store://search/?query=Sticky%20Notes')) }

# ------------------------------------------------------------ OneDrive et SharePoint
$folders   = Get-KnownFolders
$newMounts = @(Get-OneDriveMounts)
$odRunning = [bool](Get-Process OneDrive -ErrorAction SilentlyContinue)
$odRoots   = @($newMounts | ForEach-Object { $_.Chemin.TrimEnd('\') + '\' })
function Get-Loc($p) {
  if (-not $p) { return '' }
  if ($p -like '\\*') { return 'Serveur (redirection)' }
  if (Is-Excluded ($p.TrimEnd('\') + '\') $odRoots) { return 'OneDrive' }
  if ($p -like '*OneDrive*') { return 'OneDrive' }
  'Local'
}
$odStart = '$o = @("$env:LOCALAPPDATA\Microsoft\OneDrive\OneDrive.exe", "$env:ProgramFiles\Microsoft OneDrive\OneDrive.exe", "${env:ProgramFiles(x86)}\Microsoft OneDrive\OneDrive.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1; Start-Process $o'
$oldMounts = @($inv.OneDriveMontages)
if (@($inv.OneDrive).Count -or $oldMounts.Count) {
  Check $C_OD 'Application OneDrive' 'Active' $(if ($odRunning) { 'Active' } else { 'Arrêtée' }) (St $odRunning) 'Démarrer OneDrive' @((ACmd 'Copier la commande de correction' $odStart $false $true))
}
foreach ($acc in @($inv.OneDrive)) {
  $ok = [bool]($newMounts | Where-Object { $_.Type -eq 'OneDrive' -and $_.Compte -eq $acc.Compte })
  Check $C_OD "Compte $($acc.Compte)" 'Connecté' $(if ($ok) { 'Connecté' } else { 'Non connecté' }) (St $ok) "Lancer OneDrive et se connecter avec $($acc.Compte) (l'utilisateur saisit son mot de passe / MFA)" @((ACmd 'Copier la commande pour lancer OneDrive' $odStart), (ACopy "Copier l'adresse e-mail du compte" $acc.Compte 'À coller dans la fenêtre de connexion OneDrive'))
}
foreach ($m in @($oldMounts | Where-Object { $_.Type -ne 'OneDrive' })) {
  $n = $newMounts | Where-Object { $_.Cle -eq $m.Cle } | Select-Object -First 1
  $acts = @(); if ($m.Url) { $acts += AWeb 'Ouvrir la bibliothèque dans SharePoint' $m.Url }
  Check $C_OD "Bibliothèque « $($m.Nom) »" 'Synchronisée' $(if ($n) { 'Synchronisée' } else { 'Non synchronisée' }) (St $n) 'Ouvrir la bibliothèque puis cliquer sur « Synchroniser » (ou « Ajouter un raccourci à Mes fichiers »)' $acts
}
foreach ($d in @($inv.Dossiers | Where-Object { $_.Cle -in 'Bureau','Documents','Images' })) {
  $nl = Get-Loc $folders[$d.Cle]
  if ($d.Emplacement -ne 'OneDrive' -and $nl -ne 'OneDrive') { continue }
  Check $C_OD "Sauvegarde du dossier $($d.Libelle) dans OneDrive" $(if ($d.Emplacement -eq 'OneDrive') { 'Activée' } else { 'Désactivée' }) $(if ($nl -eq 'OneDrive') { 'Activée' } else { 'Désactivée' }) (St ($d.Emplacement -eq $nl)) 'OneDrive > Paramètres > Synchroniser et sauvegarder > Gérer la sauvegarde' @((AOpen 'Ouvrir Paramètres > Sauvegarde Windows' 'ms-settings:backup'), (ACmd 'Copier la commande pour lancer OneDrive' $odStart))
}

# ------------------------------------------------------------ Fichiers
$filesData = New-Object System.Collections.Generic.List[object]; $missingAll = New-Object System.Collections.Generic.List[object]
$man = Src 'fichiers_manifeste.csv'
$winName = @{ 'Bureau' = 'Desktop'; 'Documents' = 'Documents'; 'Images' = 'Pictures'; 'Musique' = 'Music'; 'Videos' = 'Videos'; 'Telechargements' = 'Downloads' }
# Dossiers à comparer côté nouveau poste : dossiers connus + montages OneDrive retrouvés par leur clé
$newPaths = @{}
foreach ($k in $folders.Keys) { $newPaths[$k] = $folders[$k] }
foreach ($m in $newMounts) { if (-not $newPaths.ContainsKey($m.Cle)) { $newPaths[$m.Cle] = $m.Chemin } }
$allNewRoots = @($inv.Dossiers | ForEach-Object { $newPaths[$_.Cle] } | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') + '\' })
$filesOldTotal = 0; $filesOkTotal = 0
if (Test-Path $man) {
  Log "Comparaison des fichiers (peut prendre quelques minutes)..."
  $byFolder = @{}
  foreach ($f in (Import-Csv $man -Delimiter ';')) {
    if (-not $byFolder.ContainsKey($f.Dossier)) { $byFolder[$f.Dossier] = New-Object System.Collections.Generic.List[object] }
    $byFolder[$f.Dossier].Add($f)
  }
  foreach ($dInfo in @($inv.Dossiers)) {
    $key = $dInfo.Cle
    $old = New-Object System.Collections.Generic.List[object]
    if ($byFolder.ContainsKey($key)) { $old = $byFolder[$key] }
    $newPath = $newPaths[$key]
    $idx = @{}; $newBytes = [int64]0
    $present = $newPath -and (Test-Path -LiteralPath $newPath)
    if ($present) {
      $pp = $newPath.TrimEnd('\') + '\'
      $excl = @($allNewRoots | Where-Object { $_ -ine $pp -and $_.StartsWith($pp, [StringComparison]::OrdinalIgnoreCase) })
      $base = $pp.Length
      Get-FilesSafe $newPath |
        Where-Object { $_.Name -ne 'desktop.ini' -and -not (Is-Excluded $_.FullName $excl) } | ForEach-Object {
          $idx[$_.FullName.Substring($base)] = $_.Length; $newBytes += $_.Length
        }
    }
    $miss = 0; $diff = 0
    foreach ($f in $old) {
      if (-not $idx.ContainsKey($f.Relatif)) { $miss++; $missingAll.Add([pscustomobject]@{ Dossier = $dInfo.Libelle; Fichier = $f.Relatif; Taille = [int64]$f.Octets; Probleme = 'Absent' }) }
      elseif ($f.EnLigneSeul -ne 'True' -and [int64]$idx[$f.Relatif] -ne [int64]$f.Octets) { $diff++; $missingAll.Add([pscustomobject]@{ Dossier = $dInfo.Libelle; Fichier = $f.Relatif; Taille = [int64]$f.Octets; Probleme = "Taille différente ($([int64]$idx[$f.Relatif]) octets)" }) }
    }
    $oldN = $old.Count; $filesOldTotal += $oldN; $filesOkTotal += ($oldN - $miss - $diff)
    $oTxt = "{0:N0} fichiers · {1}" -f $oldN, (Go $dInfo.Octets)
    $nTxt = "{0:N0} fichiers · {1}" -f $idx.Count, (Go $newBytes)
    $note = @(); if ($miss) { $note += "$miss fichier(s) absent(s)" }; if ($diff) { $note += "$diff fichier(s) de taille différente" }
    $cloudSide = $dInfo.Emplacement -in 'OneDrive','SharePoint'
    $acts = @()
    if ($miss -or $diff) {
      if ($cloudSide) {
        $note += $(if (-not $present) { 'dossier non synchronisé sur ce poste' } else { "si OneDrive n'a pas fini sa première synchronisation, relancer le contrôle plus tard" })
        $acts += ANav 'Voir la rubrique OneDrive' '#onedrive'
      } elseif ($winName.ContainsKey($key) -and $newPath) {
        $pd = @($plan.Dossiers) | Where-Object { $_.Cle -eq $key } | Select-Object -First 1
        $srcData = if ($pd) { Join-Path $donnees $pd.Cible } else { Join-Path $donnees $winName[$key] }
        $note += "la commande recopie uniquement les fichiers manquants ou différents depuis $srcData (à adapter si les données sont ailleurs)"
        $acts += ACmd 'Copier la commande de recopie' "robocopy $(Q $srcData) $(Q $newPath) /E /COPY:DAT /XJ /R:1 /W:1 /NP /XO /LOG+:$(Q (Join-Path $donnees 'robocopy_correction.log'))"
      }
      $acts += ANav 'Voir la liste des fichiers' '#liste-fichiers'
    }
    $st = if ($oldN -eq 0) { 'INFO' } else { St (($miss + $diff) -eq 0) }
    Check $C_FIC $dInfo.Libelle $oTxt $nTxt $st ($note -join ' ; ') $acts
    $filesData.Add([ordered]@{ lib = $dInfo.Libelle; loc = $dInfo.Emplacement; avant = $oldN; apres = $idx.Count; abs = $miss; diff = $diff; s = $st; note = ($note -join ' ; ') })
  }
  if ($missingAll.Count) {
    $missingAll | Export-Csv (Join-Path $Source "_fichiers_manquants_$stamp.csv") -NoTypeInformation -Encoding UTF8 -Delimiter ';'
  }
} else {
  Check $C_FIC 'Manifeste des fichiers' 'Absent' '—' 'MANUEL' 'Comparer manuellement le contenu des dossiers'
}
if ($inv.Meta.Profil) {
  $same = [string]$inv.Meta.Profil -ieq $env:USERPROFILE
  Check $C_FIC 'Dossier de profil' $inv.Meta.Profil $env:USERPROFILE (St $same) $(if (-not $same) { 'Profil créé sous un autre nom (un profil existait déjà ?) : les chemins des PST et les raccourcis vers des fichiers personnels ont été recalculés, vérifier ceux qui restent en écart' })
}
$cj = Join-Path $donnees '_copie.json'
$copieFaite = $filesOldTotal -gt 0 -and $filesOkTotal -eq $filesOldTotal
if (Test-Path $cj) {
  $cs = Get-Content $cj -Raw -Encoding UTF8 | ConvertFrom-Json
  $tot = (@($cs.dossiers) | ForEach-Object { [int]$_.Attendus } | Measure-Object -Sum).Sum
  $cop = (@($cs.dossiers) | ForEach-Object { [int]$_.Copies } | Measure-Object -Sum).Sum
  Check $C_FIC "Copie des données sur l'ancien poste" "$cop / $tot fichier(s) copié(s) le $($cs.date)" $(if ($cs.ok) { 'Complète' } else { 'Incomplète' }) (St ([bool]$cs.ok)) "Fichiers non copiés : voir Donnees\_copie_manquants.csv ; relancer Copie-Donnees.ps1 sur l'ancien poste si c'est encore possible"
} elseif (@($plan.Dossiers).Count -or @($plan.Pst).Count) {
  Check $C_FIC "Copie des données sur l'ancien poste" 'Prévue (Copie-Donnees.ps1)' 'Dossier Donnees absent' $(if ($copieFaite) { 'INFO' } else { 'ECART' }) $(if ($copieFaite) { 'Les fichiers sont pourtant tous présents : copie faite autrement' } else { "Lancer Copie-Donnees.ps1 sur l'ancien poste (page Préparation du rapport d'inventaire), puis relancer la restauration" })
}
foreach ($h in @($inv.HorsProfil)) {
  $ok = Test-Path -LiteralPath $h.Chemin
  $ph = @($plan.Hors) | Where-Object { $_.Source -eq $h.Chemin } | Select-Object -First 1
  $srcH = if ($ph) { Join-Path $donnees $ph.Cible } else { Join-Path $donnees ('HorsProfil\' + ($h.Chemin -replace ':', '')) }
  Check $C_FIC "Hors profil : $($h.Chemin)" "Présent (modifié le $($h.Modifie))" $(if ($ok) { 'Présent' } else { 'Absent' }) $(if ($ok) { 'OK' } else { 'MANUEL' }) "Confirmer avec l'utilisateur s'il faut recopier ce dossier (commande à adapter si la copie n'est pas dans $srcH)" @((ACmd 'Copier la commande de recopie' "robocopy $(Q $srcH) $(Q $h.Chemin) /E /COPY:DAT /XJ /R:1 /W:1 /NP" $true))
}

# ------------------------------------------------------------ Accès et sécurité
$curThumb = @(Get-ChildItem Cert:\CurrentUser\My -ErrorAction SilentlyContinue | ForEach-Object { $_.Thumbprint })
$pfxCmd = "Import-PfxCertificate -FilePath (Read-Host 'Chemin du fichier .pfx') -CertStoreLocation Cert:\CurrentUser\My -Password (Read-Host 'Mot de passe du .pfx' -AsSecureString) -Exportable"
foreach ($c in @($inv.Certificats)) {
  if ($c.Expire_ -or $c.Emetteur -match 'MS-Organization|Microsoft Intune|Token Signing') { continue }
  $ok = $curThumb -contains $c.Empreinte
  $cn = (([string]$c.Sujet -split ',')[0] -replace '^\s*(CN|E|OU|O)=', '')
  $st = if ($ok) { 'OK' } elseif ($c.ClePrivee) { 'MANUEL' } else { 'INFO' }
  $pfxFile = Join-Path $donnees "Certificats\$($c.Empreinte).pfx"
  if (Test-Path -LiteralPath $pfxFile) {
    $imp = "Import-PfxCertificate -FilePath $(Q $pfxFile) -CertStoreLocation Cert:\CurrentUser\My -Password (Read-Host 'Mot de passe choisi lors de l''export du .pfx' -AsSecureString) -Exportable | Out-Null; Write-Host 'Certificat importé.' -ForegroundColor Green"
    Check $C_SEC "Certificat « $cn »" "Expire le $($c.Expire) · avec clé privée" $(if ($ok) { 'Présent' } else { 'Absent (fichier exporté trouvé)' }) $st $(if (-not $ok) { "Importer le fichier exporté sur l'ancien poste (saisir le mot de passe choisi à l'export)" }) @((ACmd "Copier la commande d'import de ce certificat" $imp), (ACmd 'Copier la commande pour ouvrir les certificats' 'certmgr.msc'))
  } else {
    Check $C_SEC "Certificat « $cn »" "Expire le $($c.Expire)$(if ($c.ClePrivee) { ' · avec clé privée' })" $(if ($ok) { 'Présent' } else { 'Absent' }) $st $(if (-not $ok -and $c.ClePrivee) { "Exporter en .pfx sur l'ancien poste (page Préparation de l'inventaire), puis l'importer ici" }) @((ACmd "Copier la commande d'import du .pfx" $pfxCmd), (ACmd 'Copier la commande pour ouvrir les certificats' 'certmgr.msc'))
  }
}
$curWifi = Get-WifiNames
foreach ($w in @($inv.Wifi)) {
  $ok = $curWifi -contains $w
  $wacts = @()
  $wf = @(Get-ChildItem (Join-Path $donnees 'Wifi') -Filter *.xml -ErrorAction SilentlyContinue | Where-Object { (Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue) -match ('<name>' + [regex]::Escape([Security.SecurityElement]::Escape($w)) + '</name>') }) | Select-Object -First 1
  if ($wf) { $wacts += ACmd "Copier la commande d'import de ce réseau" ("cmd /c 'netsh wlan add profile filename=`"{0}`" user=current'" -f ($wf.FullName -replace "'", "''")) $false $true }
  $wacts += AOpen 'Ouvrir Paramètres > Wi-Fi' 'ms-settings:network-wifi'
  Check $C_SEC "Wi-Fi « $w »" 'Enregistré' $(if ($ok) { 'Enregistré' } else { 'Absent' }) $(if ($ok) { 'OK' } else { 'MANUEL' }) $(if (-not $ok) { if ($wf) { "Profil exporté trouvé : l'importer" } else { "Se connecter une fois au réseau « $w » (mot de passe requis)" } }) $wacts
}
$curCred = Get-CredTargets
foreach ($t in @($inv.Identifiants)) {
  $ok = $curCred -contains $t
  Check $C_SEC "Identifiant « $t »" 'Enregistré' $(if ($ok) { 'Enregistré' } else { 'Absent' }) $(if ($ok) { 'OK' } else { 'MANUEL' }) $(if (-not $ok) { 'Sera redemandé à la première connexion : cocher « Mémoriser »' }) @((ACmd "Copier la commande pour ouvrir le Gestionnaire d'identification" 'control /name Microsoft.CredentialManager'))
}

# ------------------------------------------------------------ Langue et région
$oL = @($inv.Langues | ForEach-Object { $_.Langue }) -join ', '
$nLst = @(Get-WinUserLanguageList)
$nL = @($nLst | ForEach-Object { $_.LanguageTag }) -join ', '
$cmdL = @(); $i = 0
foreach ($lg in @($inv.Langues)) {
  if ($i -eq 0) { $cmdL += "`$l = New-WinUserLanguageList $(Q $lg.Langue)" } else { $cmdL += "`$l.Add($(Q $lg.Langue))" }
  $cmdL += "`$l[$i].InputMethodTips.Clear()"
  foreach ($tip in @(([string]$lg.Claviers) -split ',\s*' | Where-Object { $_ })) { $cmdL += "`$l[$i].InputMethodTips.Add($(Q $tip))" }
  $i++
}
$cmdL += 'Set-WinUserLanguageList $l -Force'
$aLang = @((ACmd 'Copier la commande de correction' ($cmdL -join '; ') $false $true), (AOpen 'Ouvrir Paramètres > Langue' 'ms-settings:regionlanguage'))
Check $C_LAN 'Langues' $oL $nL (St ($oL -eq $nL)) '' $aLang
$oK = @($inv.Langues | ForEach-Object { $_.Claviers }) -join ' | '
$nK = @($nLst | ForEach-Object { @($_.InputMethodTips) -join ', ' }) -join ' | '
Check $C_LAN 'Dispositions de clavier' $oK $nK (St ($oK -eq $nK)) '' $aLang
$nR = (Get-Culture).Name
Check $C_LAN 'Format régional' $inv.Region $nR (St ($inv.Region -eq $nR)) 'Effet à la prochaine ouverture des applications' @((ACmd 'Copier la commande de correction' "Set-Culture $(Q $inv.Region)" $false $true), (AOpen 'Ouvrir Paramètres > Format régional' 'ms-settings:regionformatting'))

# ------------------------------------------------------------ Contrôles finaux (toujours manuels)
Check $C_FIN 'Ouverture de session hors VPN' 'Fonctionnelle' 'À tester' 'MANUEL' 'Redémarrer et ouvrir la session sans VPN : les identifiants doivent être en cache' @((ACmd 'Copier la commande de redémarrage' 'Restart-Computer'))
Check $C_FIN 'Windows Hello (code PIN, empreinte, visage)' 'Configuré' 'À configurer' 'MANUEL' "Par l'utilisateur lui-même" @((AOpen 'Ouvrir Paramètres > Options de connexion' 'ms-settings:signinoptions'))
Check $C_FIN 'Messagerie' 'Fonctionnelle' 'À tester' 'MANUEL' 'Envoyer et recevoir un e-mail de test' @((ACmd 'Copier la commande pour ouvrir Outlook' 'Start-Process outlook'))
Check $C_FIN 'Teams' 'Fonctionnel' 'À tester' 'MANUEL' 'Appel test : micro, haut-parleurs, caméra' @((AOpen 'Ouvrir Teams' 'msteams:'))
Check $C_FIN 'Documents Office récents' 'Accessibles' 'À tester' 'MANUEL' 'Ouvrir un document Word et un classeur Excel récents' @((ACmd 'Copier la commande pour ouvrir Word' 'Start-Process winword'))
Check $C_FIN 'Licences logicielles' 'Actives' 'À vérifier' 'MANUEL' "Activer les logiciels liés à la machine (et les désactiver sur l'ancien poste)" @((ANav 'Voir les logiciels' '#logiciels'))
Check $C_FIN "Validation par l'utilisateur" '—' 'À faire' 'MANUEL' 'Parcourir ce rapport et les captures avant / après ensemble' @((ANav 'Voir les captures avant / après' '#captures'))
$sens = @('Navigateurs', 'Certificats', 'Wifi') | ForEach-Object { Join-Path $donnees $_ } | Where-Object { Test-Path $_ }
if ($sens.Count) {
  $rm = ($sens | ForEach-Object { "Remove-Item $(Q $_) -Recurse -Force -ErrorAction SilentlyContinue" }) -join '; '
  Check $C_FIN 'Effacer les fichiers sensibles du support' 'Exportés pour la migration' 'Encore présents' 'MANUEL' "Après import : supprimer les mots de passe (CSV), certificats (.pfx) et profils Wi-Fi exportés du dossier de migration ($(($sens | ForEach-Object { Split-Path $_ -Leaf }) -join ', '))" @((ACmd 'Copier la commande de suppression des fichiers sensibles' "$rm; Write-Host 'Fichiers sensibles supprimés.' -ForegroundColor Green"))
}
if (-not $SansLanceur) {
  $cleanCmd = "Remove-Item 'HKCU:\Software\Classes\migfix' -Recurse -Force -ErrorAction SilentlyContinue; Remove-Item $(Q $script:LanceurDir) -Recurse -Force -ErrorAction SilentlyContinue; Write-Host 'Lanceur de corrections retiré.'"
  Check $C_FIN 'Retirer le lanceur de corrections' 'Installé pour la migration' 'À retirer en fin de migration' 'MANUEL' "Dernière étape : retire les boutons « Appliquer » de ce poste (sinon retrait automatique après 14 jours)" @((ACmd 'Copier la commande de retrait du lanceur' $cleanCmd))
}

# ------------------------------------------------------------ Capture du nouveau bureau
$capNew = "capture_bureau_nouveau_$stamp.png"
$capOk = Capture-Bureau (Join-Path $Source $capNew)

# ======================================================================================
#                                     RAPPORT HTML
# ======================================================================================
$all    = $script:checks.ToArray()
$nOk    = @($all | Where-Object Statut -eq 'OK').Count
$nEcart = @($all | Where-Object Statut -eq 'ECART').Count
$nMan   = @($all | Where-Object Statut -eq 'MANUEL').Count
$nInfo  = @($all | Where-Object Statut -eq 'INFO').Count
$score  = if (($nOk + $nEcart) -gt 0) { [math]::Floor($nOk * 100 / ($nOk + $nEcart)) } else { 100 }
$who    = if ($inv.Meta.NomComplet -and $inv.Meta.NomComplet -ne $inv.Meta.Utilisateur) { "$($inv.Meta.NomComplet) ($($inv.Meta.Domaine)\$($inv.Meta.Utilisateur))" } else { "$($inv.Meta.Domaine)\$($inv.Meta.Utilisateur)" }

# Identifiants des commandes pour le lanceur (lien migfix:<stamp>/<id>)
$launchActions = New-Object System.Collections.Generic.List[object]
$nAct = 0; $allAuto = @()
foreach ($c in $all) {
  foreach ($a in @($c.Acts)) {
    if ($a -and $a.t -eq 'cmd') {
      $nAct++; $a['id'] = "a$nAct"
      $launchActions.Add([ordered]@{ id = "a$nAct"; label = "$($c.Categorie) — $($c.Element)"; cmd = $a.c; adm = [bool]$a.adm })
      if ($a.auto -and $c.Statut -eq 'ECART') { $allAuto += "Write-Host $(Q "— $($c.Categorie) : $($c.Element)") -ForegroundColor Yellow`r`n$($a.c)" }
    }
  }
}
$rerunCmd = "& $(Q $PSCommandPath) -Source $(Q (Resolve-Path $Source).Path) -VerifierSeulement"
$launchActions.Add([ordered]@{ id = 'rerun'; label = 'Relancer le contrôle et régénérer le rapport'; cmd = $rerunCmd; adm = $false })
if ($allAuto.Count) { $launchActions.Add([ordered]@{ id = 'all'; label = "Appliquer les $($allAuto.Count) corrections automatiques"; cmd = ($allAuto -join "`r`n"); adm = $false }) }
$launchOk = $false
if (-not $SansLanceur) { $launchOk = Install-Lanceur $stamp $launchActions.ToArray() }

$catDefs = @(
  [ordered]@{ id = 'ecrans';      nom = $C_ECR; icon = '🖥️' }, [ordered]@{ id = 'perso';       nom = $C_PER; icon = '🎨' },
  [ordered]@{ id = 'bureau';      nom = $C_BUR; icon = '🗂️' }, [ordered]@{ id = 'barre';       nom = $C_BAR; icon = '📌' },
  [ordered]@{ id = 'explorateur'; nom = $C_EXP; icon = '📂' }, [ordered]@{ id = 'lecteurs';    nom = $C_LEC; icon = '🔗' },
  [ordered]@{ id = 'imprimantes'; nom = $C_IMP; icon = '🖨️' }, [ordered]@{ id = 'navigateurs'; nom = $C_NAV; icon = '🌐' },
  [ordered]@{ id = 'office';      nom = $C_OFF; icon = '✉️' }, [ordered]@{ id = 'onedrive';    nom = $C_OD;  icon = '☁️' },
  [ordered]@{ id = 'fichiers';    nom = $C_FIC; icon = '📁' }, [ordered]@{ id = 'securite';    nom = $C_SEC; icon = '🔐' },
  [ordered]@{ id = 'langue';      nom = $C_LAN; icon = '🌍' }, [ordered]@{ id = 'logiciels';   nom = $C_LOG; icon = '🧩' },
  [ordered]@{ id = 'final';       nom = $C_FIN; icon = '🏁' })
$catId = @{}; foreach ($c in $catDefs) { $catId[$c.nom] = $c.id }

$data = [ordered]@{
  type = 'migration'
  meta = [ordered]@{
    who = $who; ancien = [string]$inv.Meta.Ordinateur; ancienOs = [string]$inv.Systeme.OS
    nouveau = $env:COMPUTERNAME; nouveauOs = [string]$dstOs.Caption
    dateInv = [string]$inv.Meta.Date; dateCtl = $debut.ToString('dd/MM/yyyy HH:mm')
    verifOnly = [bool]$VerifierSeulement; bak = (Split-Path $bak -Leaf); id = (Split-Path $Source -Leaf)
    csv = $(if ($missingAll.Count) { "_fichiers_manquants_$stamp.csv" } else { '' })
    capAvant = $(if ($inv.Capture) { 'capture_bureau.png' } else { '' })
    capApres = $(if ($capOk) { $capNew } else { '' })
    rerun = $rerunCmd
    launch = $(if ($launchOk) { "migfix:$stamp/" } else { '' })
  }
  score  = [int]$score
  counts = [ordered]@{ ok = $nOk; ecart = $nEcart; man = $nMan; info = $nInfo }
  files  = [ordered]@{
    ok = [int]$filesOkTotal; total = [int]$filesOldTotal; rows = $filesData.ToArray(); missingTotal = $missingAll.Count
    missing = @($missingAll | Select-Object -First 1000 | ForEach-Object { [ordered]@{ d = $_.Dossier; f = $_.Fichier; t = [int64]$_.Taille; p = $_.Probleme } })
  }
  cats      = $catDefs
  checks    = @($all | ForEach-Object { [ordered]@{ c = $catId[$_.Categorie]; e = $_.Element; a = $_.Ancien; n = $_.Nouveau; s = $_.Statut; note = $_.Note; x = @($_.Acts) } })
  actions   = $script:actions.ToArray()
  incidents = $script:incidents.ToArray()
}
$htmlPath = Join-Path $Source "Rapport_Migration_$stamp.html"
Write-Report $htmlPath "Migration — $who" $data
Log "Rapport : $htmlPath  ($nOk conformes, $nEcart écarts, $nMan à vérifier)"
Write-Host "`nTerminé. Rapport : $htmlPath" -ForegroundColor Green
Invoke-Item $htmlPath
