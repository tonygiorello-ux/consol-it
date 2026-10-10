# ==================================================================================
#  MOTEUR COMMUN (identique dans chaque script d'audit)
#  Questions interactives, connexion à la cible, collecte des contrôles, rapport HTML.
# ==================================================================================
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$script:Debut  = Get-Date
$script:Checks = New-Object System.Collections.Generic.List[object]
$script:Cibles = New-Object System.Collections.Generic.List[string]
$script:CorrectionsLocales = $true   # $false dès que la cible est distante : les commandes doivent alors tourner sur la cible

# --- Réparation des accents des outils natifs (dcdiag, repadmin, w32tm, ssh...) ---
try { [System.Text.Encoding]::RegisterProvider([System.Text.CodePagesEncodingProvider]::Instance) } catch { }
$script:CpOem = $null; $script:CpAnsi = $null
try { $script:CpOem  = [System.Text.Encoding]::GetEncoding(850) } catch { }
try { $script:CpAnsi = [System.Text.Encoding]::GetEncoding(1252) } catch { }
$script:CpUtf8 = New-Object System.Text.UTF8Encoding($false)
$script:RxGood = '[àâäçèéêëîïôöùûüÀÂÇÈÉÊÎÔœ°«»' + [char]0x2019 + ']'
$script:RxBad  = '[ÚÞÓÛþ¶¨' + [char]0x201A + 'Š‡ˆ├®Ã┬┐└┘┌│─░▒▓█¦�]'
function Get-FrScore([string]$s) { ([regex]::Matches($s, $script:RxGood).Count * 2) - ([regex]::Matches($s, $script:RxBad).Count * 3) }
function Repair-Line([string]$s) {
  if (-not $s -or $s -notmatch '[^\x00-\x7F]') { return $s }
  $best = $s; $bs = Get-FrScore $s
  foreach ($p in @(@($script:CpOem, $script:CpAnsi), @($script:CpAnsi, $script:CpOem), @($script:CpOem, $script:CpUtf8), @($script:CpAnsi, $script:CpUtf8))) {
    if (-not $p[0] -or -not $p[1]) { continue }
    try { $c = $p[1].GetString($p[0].GetBytes($s)) } catch { continue }
    $sc = Get-FrScore $c
    if ($sc -gt $bs) { $best = $c; $bs = $sc }
  }
  $best
}
function Repair-Text([string]$t) { (($t -split "`r?`n") | ForEach-Object { Repair-Line $_ }) -join "`n" }

# --- Console ---
function Show-Titre($titre, $texte) {
  try { $Host.UI.RawUI.WindowTitle = $titre } catch { }
  Write-Host ''
  Write-Host ('=' * 78) -ForegroundColor DarkCyan
  Write-Host "  $titre" -ForegroundColor Cyan
  if ($texte) { foreach ($l in ($texte -split "`n")) { Write-Host "  $l" -ForegroundColor Gray } }
  Write-Host ('=' * 78) -ForegroundColor DarkCyan
}
function Show-Etape($t) { Write-Host ''; Write-Host "-> $t" -ForegroundColor Cyan }
function Ask-Text($question, $defaut = '') {
  $suffix = if ($defaut) { " [$defaut]" } else { '' }
  $r = Read-Host "  $question$suffix"
  if ([string]::IsNullOrWhiteSpace($r)) { return $defaut }
  $r.Trim()
}
function Ask-YesNo($question, [bool]$defaut = $true) {
  $suffix = if ($defaut) { ' (O/n)' } else { ' (o/N)' }
  $r = Read-Host "  $question$suffix"
  if ([string]::IsNullOrWhiteSpace($r)) { return $defaut }
  $r -match '^[oOyY]'
}
function Q($s) { "'" + ([string]$s -replace "'", "''") + "'" }

# --- Cible Windows : locale ou distante (WinRM), avec identifiants au choix ---
function Test-Locale($nom) {
  if (-not $nom) { return $true }
  $n = $nom.Trim().ToLower()
  $locaux = @('.', 'localhost', '127.0.0.1', '::1', $env:COMPUTERNAME.ToLower())
  try { $locaux += ([System.Net.Dns]::GetHostEntry('localhost').HostName.ToLower()); $locaux += ([System.Net.Dns]::GetHostName().ToLower()) } catch { }
  $court = ($n -split '\.')[0]
  ($locaux -contains $n) -or ($court -eq $env:COMPUTERNAME.ToLower())
}
function Get-Cible($role, $indice) {
  while ($true) {
    Write-Host ''
    if ($indice) { Write-Host "  $indice" -ForegroundColor DarkGray }
    $nom = Ask-Text "Serveur $role à auditer (Entrée = ce serveur : $env:COMPUTERNAME)" ''
    if (Test-Locale $nom) {
      $script:Cibles.Add($env:COMPUTERNAME)
      return [pscustomobject]@{ Nom = $env:COMPUTERNAME; Locale = $true; Cred = $null }
    }
    $cred = $null
    if (-not (Ask-YesNo "Se connecter avec le compte actuel ($env:USERDOMAIN\$env:USERNAME) ?" $true)) {
      try { $cred = Get-Credential -Message "Identifiants pour $nom (ex. DOMAINE\admin)" } catch { }
      if (-not $cred) { Write-Host "  Aucun identifiant saisi." -ForegroundColor Yellow; continue }
    }
    Write-Host "  Test de la connexion à $nom (WinRM)..." -ForegroundColor Gray
    try {
      $p = @{ ComputerName = $nom; ScriptBlock = { $env:COMPUTERNAME }; ErrorAction = 'Stop' }
      if ($cred) { $p.Credential = $cred }
      $vrai = Invoke-Command @p
      Write-Host "  Connecté à $vrai." -ForegroundColor Green
      $script:Cibles.Add([string]$vrai)
      $script:CorrectionsLocales = $false
      return [pscustomobject]@{ Nom = [string]$vrai; Locale = $false; Cred = $cred; Saisi = $nom }
    } catch {
      Write-Host "  Connexion impossible : $($_.Exception.Message)" -ForegroundColor Red
      Write-Host "  Pistes : WinRM actif sur la cible (Enable-PSRemoting -Force), pare-feu TCP 5985 ouvert," -ForegroundColor Yellow
      Write-Host "  nom DNS plutôt qu'adresse IP (sinon TrustedHosts), compte administrateur de la cible." -ForegroundColor Yellow
      Write-Host "  Alternative : copier ce script sur le serveur et le lancer directement (Entrée à la question du serveur)." -ForegroundColor Yellow
      if (-not (Ask-YesNo "Réessayer ?" $true)) { throw "Cible $role injoignable" }
    }
  }
}
function Invoke-Cible($cible, [scriptblock]$bloc, [object[]]$arguments = @()) {
  if ($cible.Locale) { return (& $bloc @arguments) }
  $p = @{ ComputerName = $cible.Saisi; ScriptBlock = $bloc; ArgumentList = $arguments; ErrorAction = 'Stop' }
  if ($cible.Cred) { $p.Credential = $cible.Cred }
  Invoke-Command @p
}

# --- Cible SSH (ESXi, vCenter) : une connexion par hôte, commandes séparées par des marqueurs ---
function Test-Ssh {
  if (Get-Command ssh -ErrorAction SilentlyContinue) { return $true }
  Write-Host "  Client SSH introuvable : installer « Client OpenSSH » (Paramètres > Applications > Fonctionnalités facultatives)" -ForegroundColor Red
  Write-Host "  ou en administrateur : Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0" -ForegroundColor Yellow
  $false
}
function Invoke-SshLot($cible, $cmds) {
  # $cmds : [ordered]@{ id = 'commande shell' } -> [ordered]@{ id = 'sortie' } ; $null si la connexion échoue
  $seq = ($cmds.Keys | ForEach-Object { 'echo @@@' + $_ + '@@@; { ' + $cmds[$_] + '; } 2>&1' }) -join '; '
  $legacy = (-not $PSNativeCommandArgumentPassing) -or ($PSNativeCommandArgumentPassing -eq 'Legacy')
  if ($legacy) { $seq = $seq -replace '"', '\"' }
  Write-Host "  Connexion SSH à $cible (le mot de passe est demandé par ssh)..." -ForegroundColor Gray
  $enc = [Console]::OutputEncoding
  try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
  $raw = (ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 $cible $seq 2>&1 | Out-String)
  $code = $LASTEXITCODE
  try { [Console]::OutputEncoding = $enc } catch { }
  $blocs = [ordered]@{}; $cur = $null
  foreach ($ln in ($raw -split "`r?`n")) {
    if ($ln -match '^@@@(\w+)@@@\s*$') { $cur = $Matches[1]; $blocs[$cur] = New-Object System.Text.StringBuilder; continue }
    if ($cur) { [void]$blocs[$cur].AppendLine($ln) }
  }
  if ($blocs.Count -eq 0) { return [pscustomobject]@{ Ok = $false; Code = $code; Brut = $raw.Trim(); Sorties = $null } }
  $out = [ordered]@{}; foreach ($k in $blocs.Keys) { $out[$k] = (Repair-Text $blocs[$k].ToString()).TrimEnd() }
  [pscustomobject]@{ Ok = $true; Code = $code; Brut = ''; Sorties = $out }
}

# --- Contrôles ---
#   Statut : OK (sain), ATT (attention), CRIT (critique), INFO
function To-Table($objets, [string[]]$props, $max = 500) {
  $o = @($objets | Where-Object { $null -ne $_ })
  if (-not $o.Count) { return $null }
  if (-not $props) { $props = @($o[0].PSObject.Properties | ForEach-Object { $_.Name }) }
  $rows = New-Object System.Collections.Generic.List[object]
  foreach ($it in ($o | Select-Object -First $max)) {
    $rows.Add(@($props | ForEach-Object { $v = $it.$_; if ($v -is [datetime]) { $v.ToString('dd/MM/yyyy HH:mm') } elseif ($v -is [array]) { ($v -join ', ') } else { [string]$v } }))
  }
  [pscustomobject]@{ cols = $props; rows = $rows.ToArray(); total = $o.Count }
}
function Add-Check {
  param([string]$Rubrique, [string]$Titre, [ValidateSet('OK', 'ATT', 'CRIT', 'INFO')][string]$Statut, [string]$Resume = '',
        $Table = $null, [string]$Brut = '', [string]$Reco = '', $Cmds = @(), [string]$Cible = '')
  $col = @{ OK = 'Green'; ATT = 'Yellow'; CRIT = 'Red'; INFO = 'Gray' }[$Statut]
  $lib = @{ OK = '[ SAIN ]'; ATT = '[ATTENT]'; CRIT = '[CRITIQ]'; INFO = '[ INFO ]' }[$Statut]
  Write-Host ("  {0} {1}{2}" -f $lib, $Titre, $(if ($Resume) { ' — ' + $Resume } else { '' })) -ForegroundColor $col
  $acts = @($Cmds | Where-Object { $_ })
  $script:Checks.Add([ordered]@{
    c = $Rubrique; e = $Titre; s = $Statut; r = $Resume; t = $Cible
    tab = $Table; raw = $(if ($Brut) { (Repair-Text $Brut).Trim() } else { '' }); reco = $Reco; x = $acts
  })
}
function Cmd($libelle, $commande) { [ordered]@{ t = 'cmd'; l = $libelle; c = $commande; adm = $true } }
function CmdUser($libelle, $commande) { [ordered]@{ t = 'cmd'; l = $libelle; c = $commande; adm = $false } }
function Ouvrir($libelle, $uri) { [ordered]@{ t = 'open'; l = $libelle; u = $uri } }   # écran Windows (ms-settings:...) ouvert directement par le navigateur
function Lien($libelle, $chemin) { if ($chemin -and (Test-Path -LiteralPath $chemin)) { [ordered]@{ t = 'web'; l = $libelle; u = ([uri](Resolve-Path -LiteralPath $chemin).Path).AbsoluteUri } } }
function Test-EstAdmin { ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
function Cap([scriptblock]$sb) { try { ((& $sb 2>&1 | Out-String -Width 220).TrimEnd()) } catch { "[ERREUR] $($_.Exception.Message)" } }
function Add-Erreur($rubrique, $titre, $err, $cible = '') {
  Add-Check -Rubrique $rubrique -Titre $titre -Statut 'ATT' -Resume "Contrôle impossible : $err" -Cible $cible
}

# --- Rapport ---
function Get-DossierRapports {
  $d = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Rapports-Audit'
  try { New-Item -ItemType Directory -Path $d -Force -ErrorAction Stop | Out-Null } catch { $d = $env:TEMP }
  $d
}
function Save-Audit($nomFichier, $titre, $client, $rubriques, $prerequis) {
  $all = @($script:Checks.ToArray())
  $n = @{ OK = 0; ATT = 0; CRIT = 0; INFO = 0 }; foreach ($k in $all) { $n[$k.s]++ }
  $score = if (($n.OK + $n.ATT + $n.CRIT) -gt 0) { [math]::Floor($n.OK * 100 / ($n.OK + $n.ATT + $n.CRIT)) } else { 100 }
  $cibles = @($script:Cibles | Select-Object -Unique)
  # Corrections lançables d'un clic (bouton ▶) : seulement si les commandes concernent ce poste et que le lanceur
  # Console IT est installé pour ce compte. Les commandes sont enregistrées localement ; le lanceur n'exécute que celles-ci.
  $launch = ''
  $lanceur = Test-Path 'HKCU:\Software\Classes\consoleit\shell\open\command'
  $raison = if (-not $script:CorrectionsLocales) { 'les commandes concernent la cible auditée (serveur distant ou session SSH) : les exécuter sur la cible' } elseif (-not $lanceur) { "le lanceur Console IT n'est pas installé pour le compte $env:USERDOMAIN\$env:USERNAME qui a produit ce rapport (console, menu Lanceur, puis relancer le diagnostic)" } else { '' }
  if ($script:CorrectionsLocales -and $lanceur) {
    $rid = ($nomFichier -replace '\.html$', '') -replace '[^A-Za-z0-9_.-]', '_'
    $acts = New-Object System.Collections.Generic.List[object]; $num = 0
    foreach ($k in $all) { foreach ($x in @($k.x)) { if ($x -and $x.t -eq 'cmd') { $num++; $x.id = [string]$num; $acts.Add([ordered]@{ id = [string]$num; l = $x.l; c = $x.c; adm = [bool]$x.adm; titre = $k.e; rapport = $titre }) } } }
    if ($num) {
      try {
        $dA = Join-Path $env:LOCALAPPDATA 'ConsoleIT\actions'
        New-Item -ItemType Directory -Path $dA -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $dA "$rid.json"), ([ordered]@{ rapport = $titre; poste = $env:COMPUTERNAME; cree = (Get-Date).ToString('s'); actions = $acts.ToArray() } | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding $false))
        $launch = "consoleit:fix/$rid/"
      } catch { }
    }
  }
  $data = [ordered]@{
    type = 'audit'
    meta = [ordered]@{
      titre = $titre; client = $client; cibles = ($cibles -join ', ')
      par = "$env:USERDOMAIN\$env:USERNAME depuis $env:COMPUTERNAME"
      date = $script:Debut.ToString('dd/MM/yyyy HH:mm'); duree = ('{0:N0} s' -f ((Get-Date) - $script:Debut).TotalSeconds)
      id = ($nomFichier -replace '\.html$', ''); prereq = $prerequis; launch = $launch; launchInfo = $raison
    }
    score = [int]$score; counts = $n
    cats = @($rubriques.Keys | ForEach-Object { [ordered]@{ id = $_; nom = $rubriques[$_][0]; icon = $rubriques[$_][1] } })
    checks = $all
  }
  $path = Join-Path (Get-DossierRapports) $nomFichier
  Write-Report $path $(if ($client) { "$titre — $client" } else { "$titre — $($cibles -join ', ')" }) $data
  Write-Host ''
  Write-Host ('=' * 78) -ForegroundColor DarkCyan
  $verdict = if ($n.CRIT) { "$($n.CRIT) point(s) critique(s), $($n.ATT) point(s) d'attention" } elseif ($n.ATT) { "$($n.ATT) point(s) d'attention" } else { 'Aucun problème détecté' }
  Write-Host ("  {0} — score {1} %" -f $verdict, $score) -ForegroundColor $(if ($n.CRIT) { 'Red' } elseif ($n.ATT) { 'Yellow' } else { 'Green' })
  Write-Host "  Rapport : $path" -ForegroundColor Cyan
  Write-Host ('=' * 78) -ForegroundColor DarkCyan
  try { Invoke-Item $path } catch { Write-Host "  (ouvrir le rapport depuis un poste disposant d'un navigateur)" -ForegroundColor Gray }
}
