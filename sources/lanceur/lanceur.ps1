<#
  Console IT — lanceur local (appelé par le navigateur via les liens consoleit:run/<action>)

  Sécurité :
    - n'exécute QUE les actions déclarées dans manifest.json du site configuré à l'installation ;
      aucun paramètre ni aucune commande ne peut être passé par le lien ;
    - vérifie l'empreinte SHA-256 du script téléchargé contre le manifeste ;
    - demande toujours confirmation sur le poste (nom de l'action, mode d'exécution, source, empreinte),
      puis Windows demande l'élévation (UAC) pour les actions « administrateur ».
  Rien n'est envoyé au site : les rapports et le dossier de migration restent sur le poste.
  Durée de vie limitée (8 h par défaut) : passé ce délai, le lanceur se retire du poste.
#>
param([string]$Url)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
$Titre = 'Console IT'
$Dir = Join-Path $env:LOCALAPPDATA 'ConsoleIT'

function Show-Box($texte, $boutons = 'OK', $icone = 'Information') {
  $owner = New-Object System.Windows.Forms.Form -Property @{ TopMost = $true; ShowInTaskbar = $false; WindowState = 'Minimized' }
  try { [System.Windows.Forms.MessageBox]::Show($owner, $texte, $Titre, [System.Windows.Forms.MessageBoxButtons]::$boutons, [System.Windows.Forms.MessageBoxIcon]::$icone) }
  finally { $owner.Dispose() }
}
function Stop-Erreur($m) { [void](Show-Box $m 'OK' 'Error'); exit 1 }

try {
  $cfg = Get-Content -LiteralPath (Join-Path $Dir 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  $fin = $null
  try { $fin = [datetime]::ParseExact([string]$cfg.expire, 'yyyyMMddHHmm', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]'AssumeUniversal,AdjustToUniversal') } catch { }
  if (-not $fin -or [DateTime]::UtcNow -ge $fin) {
    Remove-Item -LiteralPath 'HKCU:\Software\Classes\consoleit' -Recurse -Force -ErrorAction SilentlyContinue
    try { Unregister-ScheduledTask -TaskName 'ConsoleIT-Expiration' -Confirm:$false -ErrorAction SilentlyContinue } catch { }
    Remove-Item -LiteralPath $Dir -Recurse -Force -ErrorAction SilentlyContinue
    Stop-Erreur "Le lanceur Console IT a expiré sur ce poste$(if ($fin) { ' (fin de validité : ' + $fin.ToLocalTime().ToString('dd/MM/yyyy HH:mm') + ')' }). Il vient d'être retiré.`n`nPour continuer : console, menu Lanceur, réinstaller."
  }
  $base = ([string]$cfg.base).TrimEnd('/')
  if ($base -notmatch '^(https://[a-zA-Z0-9.-]+(:\d+)?|http://(localhost|127\.0\.0\.1)(:\d+)?)(/[A-Za-z0-9._~/-]*)?$') { Stop-Erreur "Configuration invalide : $base. Réinstaller le lanceur depuis la console." }

  # --- Correction proposée par un rapport (bouton ▶) : consoleit:fix/<rapport>/<n>
  # La commande n'est PAS dans le lien : elle est lue dans le fichier d'actions écrit sur ce poste par le script
  # qui a produit le rapport (%LOCALAPPDATA%\ConsoleIT\actions). Une page web ne peut donc rien faire exécuter d'autre.
  $dA = Join-Path $Dir 'actions'
  Get-ChildItem -LiteralPath $dA -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt (Get-Date).AddHours(-8) } | Remove-Item -Force -ErrorAction SilentlyContinue
  if ([string]$Url -match '^[A-Za-z][A-Za-z0-9+.-]*:(//)?fix/([A-Za-z0-9_.-]{1,160})/(\d{1,4})/?$') {
    $rid = $Matches[2]; $num = $Matches[3]
    $fa = Join-Path $dA "$rid.json"
    if (-not (Test-Path -LiteralPath $fa)) { Stop-Erreur "Correction introuvable sur ce poste.`n`nLe rapport a été produit sur un autre poste ou par un autre compte, ou ses corrections ont expiré (8 h). Utiliser « voir / copier la commande » sous le bouton." }
    $doc = Get-Content -LiteralPath $fa -Raw -Encoding UTF8 | ConvertFrom-Json
    $act = @($doc.actions | Where-Object { [string]$_.id -eq $num }) | Select-Object -First 1
    if (-not $act -or -not [string]$act.c) { Stop-Erreur "Correction n° $num absente du rapport $rid." }
    $c = [string]$act.c
    $aff = if ($c.Length -gt 700) { $c.Substring(0, 700) + ' …' } else { $c }
    $mode = if ($act.adm) { 'PowerShell ADMINISTRATEUR (Windows va demander l''élévation)' } else { "PowerShell dans la session de $env:USERNAME" }
    $msg = "Appliquer « $($act.l) » sur $env:COMPUTERNAME ?`n`nRapport : $($doc.rapport) ($($doc.cree))`nContrôle : $($act.titre)`nExécution : $mode`n`nCommande :`n$aff"
    if ((Show-Box $msg 'YesNo' 'Question') -ne [System.Windows.Forms.DialogResult]::Yes) { exit 0 }
    $esc = { param($t) ([string]$t) -replace "'", "''" }
    $corps = "`$Host.UI.RawUI.WindowTitle = 'Console IT - correction'`r`nWrite-Host '$(& $esc $act.l)' -ForegroundColor Cyan`r`nWrite-Host ''`r`n$c`r`nWrite-Host ''`r`nWrite-Host 'Terminé. Relancer le diagnostic pour vérifier.' -ForegroundColor Green`r`n"
    $fs = Join-Path $dA ("run_{0}_{1}.ps1" -f $rid, $num)
    [IO.File]::WriteAllText($fs, $corps, (New-Object Text.UTF8Encoding $true))
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arg = '-NoProfile -ExecutionPolicy Bypass -NoExit -File "{0}"' -f $fs
    try {
      if ($act.adm) { Start-Process -FilePath $ps -ArgumentList $arg -Verb RunAs } else { Start-Process -FilePath $ps -ArgumentList $arg }
    } catch { if ($_.Exception.Message -match 'annul|cancel') { exit 0 }; throw }
    exit 0
  }

  # consoleit:run/audit-ad  |  consoleit://run/audit-ad/  ->  audit-ad
  $id = ([string]$Url -replace '^[A-Za-z][A-Za-z0-9+.-]*:(//)?', '' -replace '^run/', '' -replace '[?#].*$', '').Trim('/').ToLowerInvariant()
  if ($id -notmatch '^[a-z0-9-]{1,40}$') { Stop-Erreur "Lien non reconnu : $Url" }

  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072   # TLS 1.2
  $wc = New-Object System.Net.WebClient
  $wc.Headers['Cache-Control'] = 'no-cache'
  if ([string]$cfg.jeton -match '^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$') { $wc.Headers['X-Console-Jeton'] = [string]$cfg.jeton }
  $man = [Text.Encoding]::UTF8.GetString($wc.DownloadData("$base/manifest.json?t=$([DateTime]::UtcNow.Ticks)")).TrimStart([char]0xFEFF) | ConvertFrom-Json
  # Mise à jour automatique du lanceur : si le site publie une autre version, on la télécharge, on vérifie
  # son empreinte (manifeste) puis on relance la même action avec la nouvelle version.
  $hash = { param($b) [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($b)).Replace('-', '') }
  $attendu = [string]$man.lanceur.sha256
  if ($attendu -match '^[0-9A-Fa-f]{64}$' -and (& $hash ([IO.File]::ReadAllBytes($PSCommandPath))) -ne $attendu.ToUpperInvariant()) {
    $neuf = $wc.DownloadData("$base/lanceur/lanceur.ps1?v=$($attendu.Substring(0, 12))")
    if ((& $hash $neuf) -ne $attendu.ToUpperInvariant()) { Stop-Erreur 'Mise à jour du lanceur refusée : empreinte différente de celle du manifeste.' }
    [IO.File]::WriteAllBytes($PSCommandPath, $neuf)
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Start-Process -FilePath $ps -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" "consoleit:run/{1}"' -f $PSCommandPath, $id) -WindowStyle Hidden
    exit 0
  }

  $e = @($man.scripts | Where-Object { $_.id -eq $id }) | Select-Object -First 1
  if (-not $e) { Stop-Erreur "Action inconnue sur $base : $id" }
  if ([string]$e.fichier -notmatch '^[A-Za-z0-9_.-]+\.ps1$' -or [string]$e.sha256 -notmatch '^[0-9A-Fa-f]{64}$') { Stop-Erreur "Entrée de manifeste invalide pour $id." }

  $bytes = $wc.DownloadData("$base/scripts/$($e.fichier)?v=$($e.sha256.Substring(0, 12))")
  $sha = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($bytes)).Replace('-', '')
  if ($sha -ne ([string]$e.sha256).ToUpperInvariant()) { Stop-Erreur "Empreinte du script $($e.fichier) différente de celle du manifeste : exécution refusée.`n`nAttendue : $($e.sha256)`nReçue :    $sha" }

  # versions déjà approuvées sur ce poste
  $apPath = Join-Path $Dir 'approuves.json'
  $ap = @{}
  if (Test-Path -LiteralPath $apPath) { try { (Get-Content -LiteralPath $apPath -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $ap[$_.Name] = [string]$_.Value } } catch { } }
  $nouveau = $ap[$id] -ne $sha

  $mode = if ($e.admin) { 'PowerShell ADMINISTRATEUR (Windows va demander l''élévation)' } else { "PowerShell dans la session de $env:USERDOMAIN\$env:USERNAME (sans élévation)" }
  $msg = "Lancer « $($e.titre) » sur $env:COMPUTERNAME ?`n`nExécution : $mode`nSource : $base/scripts/$($e.fichier)`nEmpreinte SHA-256 : $($sha.Substring(0, 16))…"
  $extra = @($e.arguments | Where-Object { $_ })
  foreach ($x in $extra) { if ([string]$x -notmatch '^-[A-Za-z][A-Za-z0-9]{0,40}$') { Stop-Erreur "Argument non autorisé dans le manifeste pour $id : $x" } }
  if ($extra.Count) { $msg += "`nOptions : $($extra -join ' ')" }
  if ($nouveau) { $msg += "`n`nPremière exécution de cette version sur ce poste." }
  $msg += "`n`nLanceur valable jusqu'à $($fin.ToLocalTime().ToString('HH:mm')) le $($fin.ToLocalTime().ToString('dd/MM'))."
  if ((Show-Box $msg 'YesNo' 'Question') -ne [System.Windows.Forms.DialogResult]::Yes) { exit 0 }
  $ap[$id] = $sha
  try { [IO.File]::WriteAllText($apPath, ($ap | ConvertTo-Json), (New-Object Text.UTF8Encoding $false)) } catch { }

  $sd = Join-Path $Dir 'scripts'
  New-Item -ItemType Directory -Path $sd -Force | Out-Null
  $f = Join-Path $sd $e.fichier
  [IO.File]::WriteAllBytes($f, $bytes)
  $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $arg = '-NoProfile -ExecutionPolicy Bypass -NoExit -File "{0}"' -f $f
  if ($extra.Count) { $arg += ' ' + ($extra -join ' ') }
  try {
    if ($e.admin) { Start-Process -FilePath $ps -ArgumentList $arg -Verb RunAs -WorkingDirectory $sd }
    else { Start-Process -FilePath $ps -ArgumentList $arg -WorkingDirectory $sd }
  } catch {
    if ($_.Exception.Message -match 'annul|cancel') { exit 0 }   # élévation refusée par l'utilisateur
    throw
  }
} catch {
  if ($_.Exception.Message -match '\(401\)') { Stop-Erreur "Accès refusé par la console (jeton absent ou expiré).`n`nRéinstaller le lanceur : console, menu Lanceur, commande d'installation." }
  Stop-Erreur "Le lancement a échoué : $($_.Exception.Message)"
}
