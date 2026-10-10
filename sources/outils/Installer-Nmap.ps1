<#
  Installer nmap (scanner réseau avancé, optionnel)
  ATTENTION : ce script MODIFIE le poste (installation de nmap et du pilote Npcap).
  Essaie winget, sinon télécharge l'installeur officiel sur nmap.org. Un antivirus d'entreprise peut le bloquer.
  La cartographie réseau de la console fonctionne sans nmap.
#>
$ErrorActionPreference = 'Continue'
Write-Host '=== Installation de nmap ===' -ForegroundColor Cyan
Write-Host 'Ce script installe nmap et Npcap sur ce poste.' -ForegroundColor Yellow
if ((Read-Host 'Continuer ? (o/N)') -notmatch '^[oOyY]') { Write-Host 'Annulé.'; return }
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
$installe = $false
if (Get-Command winget -ErrorAction SilentlyContinue) {
  Write-Host 'Tentative via winget...' -ForegroundColor Yellow
  try {
    winget install -e --id Insecure.Nmap --silent --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -eq 0) { $installe = $true; Write-Host 'nmap installé via winget.' -ForegroundColor Green }
  } catch { Write-Warning ('winget : ' + $_.Exception.Message) }
}
if (-not $installe) {
  try {
    $tmp = Join-Path $env:TEMP 'nmap-setup.exe'
    Write-Host 'Recherche de la dernière version sur nmap.org...' -ForegroundColor Yellow
    $href = $null
    try { $page = Invoke-WebRequest 'https://nmap.org/download.html' -UseBasicParsing; $href = ($page.Links | Where-Object { $_.href -match 'nmap-[\d.]+-setup\.exe$' } | Select-Object -First 1).href } catch { }
    if (-not $href) { $href = 'https://nmap.org/dist/nmap-7.95-setup.exe' }
    if ($href -notmatch '^https?://') { $href = 'https://nmap.org' + $href }
    Write-Host "Téléchargement : $href" -ForegroundColor Yellow
    Invoke-WebRequest $href -OutFile $tmp -UseBasicParsing
    $sig = Get-AuthenticodeSignature $tmp
    if ($sig.Status -ne 'Valid') { Write-Warning "Signature de l'installeur non valide ($($sig.Status)) : installation annulée."; Remove-Item $tmp -Force; return }
    Write-Host "Installeur signé par : $($sig.SignerCertificate.Subject)" -ForegroundColor Gray
    Write-Host 'Installation silencieuse (Npcap inclus)...' -ForegroundColor Yellow
    Start-Process $tmp -ArgumentList '/S' -Wait
  } catch { Write-Warning ('Échec du téléchargement ou de l''installation : ' + $_.Exception.Message) }
}
Write-Host ''
$exe = @("${env:ProgramFiles(x86)}\Nmap\nmap.exe", "$env:ProgramFiles\Nmap\nmap.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if ($exe) { Write-Host "OK : nmap installé ($exe)" -ForegroundColor Green }
else { Write-Warning 'nmap.exe introuvable après installation : un antivirus l''a très probablement bloqué ou supprimé (fréquent en entreprise). La cartographie native fonctionne sans nmap.' }
Write-Host 'Tu peux fermer cette fenêtre.' -ForegroundColor DarkGray
