<#
  Console IT — installation du lanceur local (par utilisateur, sans droits administrateur)

  Enregistre le protocole consoleit: pour l'utilisateur courant (HKCU) : un clic sur « Lancer » dans la console
  web ouvre le lanceur, qui télécharge le script déclaré dans le manifeste, vérifie son empreinte, demande
  confirmation puis l'exécute (avec élévation UAC pour les actions d'administration).

  Usage (commande fournie par la console, PowerShell normal) :
    & ([scriptblock]::Create(...)) -Base 'https://outils.exemple.fr'
    ... -Desinstaller
#>
param(
  [string]$Base,
  [switch]$Desinstaller
)
$ErrorActionPreference = 'Stop'
$Proto = 'consoleit'
$Dir = Join-Path $env:LOCALAPPDATA 'ConsoleIT'
$Cle = "HKCU:\Software\Classes\$Proto"

if ($Desinstaller) {
  Remove-Item -LiteralPath $Cle -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $Dir -Recurse -Force -ErrorAction SilentlyContinue
  Write-Host 'Lanceur Console IT retiré de ce poste (protocole et fichiers).' -ForegroundColor Green
  return
}
$Base = ([string]$Base).TrimEnd('/')
if ($Base -notmatch '^(https://[a-zA-Z0-9.-]+(:\d+)?|http://(localhost|127\.0\.0\.1)(:\d+)?)(/[A-Za-z0-9._~/-]*)?$') { throw "Adresse de la console invalide (https://, ou http://localhost pour un test local) : '$Base'" }

[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
$wc = New-Object System.Net.WebClient
$bytes = $wc.DownloadData("$Base/lanceur/lanceur.ps1?t=$([DateTime]::UtcNow.Ticks)")
New-Item -ItemType Directory -Path $Dir -Force | Out-Null
$lanceur = Join-Path $Dir 'lanceur.ps1'
[IO.File]::WriteAllBytes($lanceur, $bytes)
[IO.File]::WriteAllText((Join-Path $Dir 'config.json'), (@{ base = $Base; installe = (Get-Date).ToString('s') } | ConvertTo-Json), (New-Object Text.UTF8Encoding $false))

$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
New-Item -Path $Cle -Force | Out-Null
Set-ItemProperty -Path $Cle -Name '(default)' -Value 'URL:Console IT'
Set-ItemProperty -Path $Cle -Name 'URL Protocol' -Value ''
New-Item -Path "$Cle\shell\open\command" -Force | Out-Null
Set-ItemProperty -Path "$Cle\shell\open\command" -Name '(default)' -Value ('"{0}" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{1}" "%1"' -f $ps, $lanceur)

Write-Host ''
Write-Host "Lanceur Console IT installé pour $env:USERNAME sur $env:COMPUTERNAME." -ForegroundColor Green
Write-Host "  Console : $Base"
Write-Host '  Au premier clic sur « Lancer », le navigateur demande d''ouvrir « Console IT » : accepter (et cocher « toujours autoriser » si proposé).' -ForegroundColor Gray
Write-Host '  Pour le retirer : même commande avec -Desinstaller (bouton « Retirer le lanceur » de la console).' -ForegroundColor Gray
