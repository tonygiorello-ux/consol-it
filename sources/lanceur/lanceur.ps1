<#
  Console IT — lanceur local (appelé par le navigateur via les liens consoleit:run/<action>)

  Sécurité :
    - n'exécute QUE les actions déclarées dans manifest.json du site configuré à l'installation ;
      aucun paramètre ni aucune commande ne peut être passé par le lien ;
    - vérifie l'empreinte SHA-256 du script téléchargé contre le manifeste ;
    - demande toujours confirmation sur le poste (nom de l'action, mode d'exécution, source, empreinte),
      puis Windows demande l'élévation (UAC) pour les actions « administrateur ».
  Rien n'est envoyé au site : les rapports et le dossier de migration restent sur le poste.
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
  $base = ([string]$cfg.base).TrimEnd('/')
  if ($base -notmatch '^(https://[a-zA-Z0-9.-]+(:\d+)?|http://(localhost|127\.0\.0\.1)(:\d+)?)(/[A-Za-z0-9._~/-]*)?$') { Stop-Erreur "Configuration invalide : $base. Réinstaller le lanceur depuis la console." }

  # consoleit:run/audit-ad  |  consoleit://run/audit-ad/  ->  audit-ad
  $id = ([string]$Url -replace '^[A-Za-z][A-Za-z0-9+.-]*:(//)?', '' -replace '^run/', '' -replace '[?#].*$', '').Trim('/').ToLowerInvariant()
  if ($id -notmatch '^[a-z0-9-]{1,40}$') { Stop-Erreur "Lien non reconnu : $Url" }

  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072   # TLS 1.2
  $wc = New-Object System.Net.WebClient
  $wc.Headers['Cache-Control'] = 'no-cache'
  $man = [Text.Encoding]::UTF8.GetString($wc.DownloadData("$base/manifest.json?t=$([DateTime]::UtcNow.Ticks)")).TrimStart([char]0xFEFF) | ConvertFrom-Json
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
  if ($nouveau) { $msg += "`n`nPremière exécution de cette version sur ce poste." }
  if ((Show-Box $msg 'YesNo' 'Question') -ne [System.Windows.Forms.DialogResult]::Yes) { exit 0 }
  $ap[$id] = $sha
  try { [IO.File]::WriteAllText($apPath, ($ap | ConvertTo-Json), (New-Object Text.UTF8Encoding $false)) } catch { }

  $sd = Join-Path $Dir 'scripts'
  New-Item -ItemType Directory -Path $sd -Force | Out-Null
  $f = Join-Path $sd $e.fichier
  [IO.File]::WriteAllBytes($f, $bytes)
  $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $arg = '-NoProfile -ExecutionPolicy Bypass -NoExit -File "{0}"' -f $f
  try {
    if ($e.admin) { Start-Process -FilePath $ps -ArgumentList $arg -Verb RunAs -WorkingDirectory $sd }
    else { Start-Process -FilePath $ps -ArgumentList $arg -WorkingDirectory $sd }
  } catch {
    if ($_.Exception.Message -match 'annul|cancel') { exit 0 }   # élévation refusée par l'utilisateur
    throw
  }
} catch {
  Stop-Erreur "Le lancement a échoué : $($_.Exception.Message)"
}
