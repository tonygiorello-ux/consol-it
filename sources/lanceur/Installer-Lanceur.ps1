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
  [string]$Jeton,                                 # jeton de téléchargement fourni par la console (accès protégé par PIN)
  [ValidateRange(1, 72)][int]$DureeHeures = 8,   # durée de vie du lanceur sur le poste
  [switch]$Desinstaller
)
$ErrorActionPreference = 'Stop'
$Proto = 'consoleit'
$Dir = Join-Path $env:LOCALAPPDATA 'ConsoleIT'
$Cle = "HKCU:\Software\Classes\$Proto"

$Tache = 'ConsoleIT-Expiration'
if ($Desinstaller) {
  Remove-Item -LiteralPath $Cle -Recurse -Force -ErrorAction SilentlyContinue
  try { Unregister-ScheduledTask -TaskName $Tache -Confirm:$false -ErrorAction SilentlyContinue } catch { }
  Remove-Item -LiteralPath $Dir -Recurse -Force -ErrorAction SilentlyContinue
  Write-Host 'Lanceur Console IT retiré de ce poste (protocole et fichiers).' -ForegroundColor Green
  return
}
$Base = ([string]$Base).TrimEnd('/')
if ($Base -notmatch '^(https://[a-zA-Z0-9.-]+(:\d+)?|http://(localhost|127\.0\.0\.1)(:\d+)?)(/[A-Za-z0-9._~/-]*)?$') { throw "Adresse de la console invalide (https://, ou http://localhost pour un test local) : '$Base'" }

[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
$wc = New-Object System.Net.WebClient
if ($Jeton) {
  if ($Jeton -notmatch '^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$') { throw 'Jeton invalide : recopier la commande depuis la console.' }
  $wc.Headers['X-Console-Jeton'] = $Jeton
}
$bytes = $wc.DownloadData("$Base/lanceur/lanceur.ps1?t=$([DateTime]::UtcNow.Ticks)")
New-Item -ItemType Directory -Path $Dir -Force | Out-Null
$lanceur = Join-Path $Dir 'lanceur.ps1'
[IO.File]::WriteAllBytes($lanceur, $bytes)
$fin = [DateTime]::UtcNow.AddHours($DureeHeures)
[IO.File]::WriteAllText((Join-Path $Dir 'config.json'), (@{ base = $Base; jeton = $Jeton; installe = [DateTime]::UtcNow.ToString('yyyyMMddHHmm'); expire = $fin.ToString('yyyyMMddHHmm') } | ConvertTo-Json), (New-Object Text.UTF8Encoding $false))

$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
New-Item -Path $Cle -Force | Out-Null
Set-ItemProperty -Path $Cle -Name '(default)' -Value 'URL:Console IT'
Set-ItemProperty -Path $Cle -Name 'URL Protocol' -Value ''
New-Item -Path "$Cle\shell\open\command" -Force | Out-Null
Set-ItemProperty -Path "$Cle\shell\open\command" -Name '(default)' -Value ('"{0}" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{1}" "%1"' -f $ps, $lanceur)

# Retrait automatique à l'expiration (tâche planifiée de l'utilisateur, sans droits administrateur).
# Si le poste est éteint à l'heure prévue, la tâche s'exécute au démarrage suivant ; le lanceur vérifie aussi la date à chaque clic.
$nettoyage = "Remove-Item -LiteralPath 'HKCU:\Software\Classes\$Proto' -Recurse -Force -ErrorAction SilentlyContinue; " +
             "Remove-Item -LiteralPath '$($Dir -replace "'", "''")' -Recurse -Force -ErrorAction SilentlyContinue; " +
             "Unregister-ScheduledTask -TaskName '$Tache' -Confirm:`$false -ErrorAction SilentlyContinue"
$tacheOk = $false
try {
  $act = New-ScheduledTaskAction -Execute $ps -Argument ('-NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($nettoyage)))
  $trg = New-ScheduledTaskTrigger -Once -At $fin.ToLocalTime()
  $set = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
  $pri = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
  Register-ScheduledTask -TaskName $Tache -Action $act -Trigger $trg -Settings $set -Principal $pri -Description 'Retire le lanceur Console IT à la fin de sa durée de vie.' -Force -ErrorAction Stop | Out-Null
  $tacheOk = $true
} catch { }

Write-Host ''
Write-Host "Lanceur Console IT installé pour $env:USERNAME sur $env:COMPUTERNAME." -ForegroundColor Green
Write-Host "  Console : $Base"
Write-Host ("  Valable {0} h, jusqu'au {1:dd/MM/yyyy à HH:mm} : il se retire ensuite de lui-même{2}." -f $DureeHeures, $fin.ToLocalTime(), $(if ($tacheOk) { '' } else { ' (au prochain clic : la tâche de retrait automatique n''a pas pu être créée)' })) -ForegroundColor Yellow
Write-Host '  Au premier clic sur « Lancer », le navigateur demande d''ouvrir « Console IT » : accepter (et cocher « toujours autoriser » si proposé).' -ForegroundColor Gray
Write-Host '  Pour le retirer : même commande avec -Desinstaller (bouton « Retirer le lanceur » de la console).' -ForegroundColor Gray
