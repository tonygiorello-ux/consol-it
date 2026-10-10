<#
  Tests de la Console IT (PowerShell 7 ou Windows PowerShell 5.1) — à lancer après « node outils/build.mjs ».
    pwsh -File tests/Lancer-Tests.ps1
  1. Chaque script généré : UTF-8 avec BOM, CRLF, syntaxe PowerShell valide.
  2. Chaque audit : exécuté de bout en bout sur des données factices (tests/fixtures*.ps1),
     sans serveur réel ; le rapport HTML doit être produit et ses données JSON lisibles.
  3. Chaque diagnostic poste : exécuté avec des commandes Windows simulées (tests/stubs_windows.ps1).
  Code de sortie 1 si un test échoue (utilisé par GitHub Actions).
#>
$ErrorActionPreference = 'Stop'
$Racine = Split-Path $PSScriptRoot -Parent
$Site = Join-Path $Racine 'site'
$Echecs = New-Object System.Collections.Generic.List[string]
function OK($m) { Write-Host "  OK    $m" -ForegroundColor Green }
function KO($m) { Write-Host "  ÉCHEC $m" -ForegroundColor Red; $Echecs.Add($m) }

Write-Host '1. Encodage et syntaxe' -ForegroundColor Cyan
$fichiers = @(Get-ChildItem (Join-Path $Site 'scripts'), (Join-Path $Site 'lanceur') -Filter *.ps1 -ErrorAction SilentlyContinue)
if (-not $fichiers.Count) { KO 'aucun script dans site/ : lancer d''abord node outils/build.mjs' }
foreach ($f in $fichiers) {
  $b = [IO.File]::ReadAllBytes($f.FullName)
  if ($b.Length -lt 3 -or $b[0] -ne 0xEF -or $b[1] -ne 0xBB -or $b[2] -ne 0xBF) { KO "$($f.Name) : pas de BOM UTF-8"; continue }
  $t = [Text.Encoding]::UTF8.GetString($b)
  if (($t -split "`n" | Where-Object { $_ -notmatch "`r$" } | Select-Object -SkipLast 1).Count) { KO "$($f.Name) : fins de ligne LF (CRLF attendu)" }
  $tok = $null; $err = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tok, [ref]$err)
  if ($err.Count) { KO "$($f.Name) : $($err.Count) erreur(s) de syntaxe — L$($err[0].Extent.StartLineNumber) $($err[0].Message)" } else { OK $f.Name }
}

Write-Host '2. Audits sur données factices' -ForegroundColor Cyan
$out = Join-Path ([IO.Path]::GetTempPath()) 'console-it-tests'
Remove-Item $out -Recurse -Force -ErrorAction SilentlyContinue
$tmp = Join-Path ([IO.Path]::GetTempPath()) 'console-it-run'
New-Item -ItemType Directory $tmp -Force | Out-Null
$exe = (Get-Process -Id $PID).Path
$marque = "`r`n'@`r`n`r`ntry {`r`n"
foreach ($k in 'AD', 'DNS', 'DHCP', 'Veeam', 'HyperV', 'ESXi', 'vCenter') {
  $src = Join-Path $Site "scripts/Audit-$k.ps1"
  if (-not (Test-Path $src)) { KO "Audit-$k.ps1 absent"; continue }
  $t = [IO.File]::ReadAllText($src, [Text.Encoding]::UTF8)
  $i = $t.LastIndexOf($marque)
  if ($i -lt 0) { KO "Audit-$k : point d'injection des données factices introuvable"; continue }
  $fx = Join-Path $PSScriptRoot $(if ($k -in 'ESXi', 'vCenter') { 'fixtures_ssh.ps1' } else { 'fixtures.ps1' })
  $t = $t.Substring(0, $i) + "`r`n'@`r`n`$script:TYPE='$k'; . '$fx'`r`ntry {`r`n" + $t.Substring($i + $marque.Length)
  $t = $t.Replace("if (`$Host.Name -eq 'ConsoleHost')", 'if ($false)')
  $test = Join-Path $tmp "Audit-$k.ps1"
  [IO.File]::WriteAllText($test, $t, (New-Object Text.UTF8Encoding $true))
  $avant = @(Get-ChildItem $out -Filter "Audit-$k*.html" -ErrorAction SilentlyContinue).Count
  $sortie = & $exe -NoProfile -NonInteractive -File $test 2>&1 | Out-String
  $html = Get-ChildItem $out -Filter "Audit-$k*.html" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1
  if ($sortie -match 'ARRÊT :|Exception|Erreur de collecte' -or -not $html -or @(Get-ChildItem $out -Filter "Audit-$k*.html").Count -le $avant) {
    KO "Audit-$k : exécution en erreur"; Write-Host ($sortie -split "`n" | Select-Object -Last 15 | Out-String) -ForegroundColor DarkGray; continue
  }
  $h = [IO.File]::ReadAllText($html.FullName, [Text.Encoding]::UTF8)
  if ($h -notmatch '(?s)<script type="application/json" id="data">(.*?)</script>') { KO "Audit-$k : données absentes du rapport"; continue }
  try { $d = $Matches[1] | ConvertFrom-Json } catch { KO "Audit-$k : JSON du rapport illisible"; continue }
  $n = @($d.checks).Count
  if ($d.type -ne 'audit' -or $n -lt 5) { KO "Audit-$k : rapport incomplet ($n contrôles)"; continue }
  OK ("Audit-{0,-8} {1,3} contrôles · score {2} % · {3} critique(s), {4} attention" -f $k, $n, $d.score, $d.counts.CRIT, $d.counts.ATT)
}

Write-Host '3. Diagnostics poste (commandes Windows simulées)' -ForegroundColor Cyan
$stubs = Join-Path $PSScriptRoot 'stubs_windows.ps1'
$reponses = @{ 'Diagnostic-LenteurReseau' = @('n'); 'Cartographie-Reseau' = @('127.0.0.0/30') }
$diags = @((Get-Content (Join-Path $Racine 'site/manifest.json') -Raw | ConvertFrom-Json).scripts | Where-Object { $_.groupe -eq 'diagnostic' -and $_.fichier -notmatch 'Installer-' })
foreach ($e in $diags) {
  $k = [IO.Path]::GetFileNameWithoutExtension($e.fichier)
  $t = [IO.File]::ReadAllText((Join-Path $Site "scripts/$($e.fichier)"), [Text.Encoding]::UTF8)
  $i = $t.LastIndexOf($marque)
  if ($i -lt 0) { KO "$k : point d'injection introuvable"; continue }
  $rep = (@($reponses[$k]) | Where-Object { $_ } | ForEach-Object { "`$script:Reponses.Enqueue('$_'); " }) -join ''
  $t = $t.Substring(0, $i) + "`r`n'@`r`n. '$stubs'; $rep`r`ntry {`r`n" + $t.Substring($i + $marque.Length)
  $t = $t.Replace("if (`$Host.Name -eq 'ConsoleHost')", 'if ($false)')
  $test = Join-Path $tmp $e.fichier
  [IO.File]::WriteAllText($test, $t, (New-Object Text.UTF8Encoding $true))
  $avant = @(Get-ChildItem $out -Filter '*.html' -ErrorAction SilentlyContinue).Name
  $sortie = & $exe -NoProfile -NonInteractive -File $test 2>&1 | Out-String
  $nouv = @(Get-ChildItem $out -Filter '*.html' -ErrorAction SilentlyContinue | Where-Object { $avant -notcontains $_.Name -and $_.Name -notmatch '^(GPO|Veille-|Batterie)' })
  if ($sortie -match 'ARRÊT :' -or -not $nouv.Count) { KO "$k : exécution en erreur"; Write-Host ($sortie -split "`n" | Select-Object -Last 12 | Out-String) -ForegroundColor DarkGray; continue }
  $h = [IO.File]::ReadAllText($nouv[0].FullName, [Text.Encoding]::UTF8)
  if ($h -notmatch '(?s)<script type="application/json" id="data">(.*?)</script>') { KO "$k : données absentes du rapport"; continue }
  try { $d = $Matches[1] | ConvertFrom-Json } catch { KO "$k : JSON du rapport illisible"; continue }
  $n = @($d.checks).Count
  if ($n -lt 3) { KO "$k : rapport incomplet ($n contrôles)"; continue }
  OK ("{0,-30} {1,3} contrôles · score {2} % · {3} critique(s), {4} attention" -f $k, $n, $d.score, $d.counts.CRIT, $d.counts.ATT)
}

Write-Host ''
if ($Echecs.Count) { Write-Host "$($Echecs.Count) échec(s)." -ForegroundColor Red; exit 1 }
Write-Host 'Tous les tests sont passés.' -ForegroundColor Green
