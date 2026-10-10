// Console IT — construction du site (Node.js 18+, sans dépendance)
//   node outils/build.mjs
// Lancé par Cloudflare Pages à chaque push (commande de build), et en local pour tester.
// Produit dans site/ : scripts/*.ps1, lanceur/*.ps1, manifest.json (fichiers générés, non versionnés).
//   - scripts d'audit  : moteur commun + interface du rapport + corps (sources/audits)
//   - scripts du poste : sources/poste, interface du rapport réinjectée depuis sources/ui
//   - tous les .ps1    : UTF-8 avec BOM + CRLF (indispensable pour Windows PowerShell 5.1)
//   - manifest.json    : catalogue + empreinte SHA-256 de chaque script (vérifiée par le lanceur)
import { readFileSync, writeFileSync, mkdirSync, rmSync, existsSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { execSync } from 'node:child_process';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const SRC = join(ROOT, 'sources'), SITE = join(ROOT, 'site');
const lire = (p) => readFileSync(join(SRC, p), 'utf8').replace(/^﻿/, '').replace(/\r\n/g, '\n').replace(/\n+$/, '');
const ecrirePs = (p, texte) => { mkdirSync(dirname(p), { recursive: true }); const buf = Buffer.concat([Buffer.from([0xef, 0xbb, 0xbf]), Buffer.from(texte.replace(/\r?\n/g, '\r\n'), 'utf8')]); writeFileSync(p, buf); return buf; };
const erreurs = [];
const verifier = (cond, msg) => { if (!cond) { erreurs.push(msg); } };

// ---- interface des rapports
const css = lire('ui/ui.css'), js = lire('ui/ui.js');
const auditCss = css + '\n' + lire('ui/audit.css');
const DISPATCH = "if (D.type === 'migration') { migration(); } else { inventaire(); }";
verifier(js.includes(DISPATCH), 'ui.js : ligne de répartition des rapports introuvable');
const auditJs = js.replace(DISPATCH, lire('ui/audit.js') + "\nif (D.type === 'audit') { audit(); } else if (D.type === 'migration') { migration(); } else { inventaire(); }");
for (const [n, t] of [['ui.css', auditCss], ['ui.js', auditJs]]) { verifier(!t.includes("\n'@"), `${n} contient la séquence \\n'@ qui fermerait la chaîne PowerShell`); }

const WRITE_REPORT = `function Write-Report($path, $title, $data) {
  $json = ($data | ConvertTo-Json -Depth 12 -Compress) -replace '</', '<\\/'
  $t = [System.Net.WebUtility]::HtmlEncode($title)
  $html = "<!doctype html>\`n<html lang=\`"fr\`"><head><meta charset=\`"utf-8\`"><meta name=\`"viewport\`" content=\`"width=device-width,initial-scale=1\`"><title>$t</title><style>\`n$($script:UiCss)\`n</style></head>\`n<body><div id=\`"app\`"></div>\`n<script type=\`"application/json\`" id=\`"data\`">$json</script>\`n<script>\`n$($script:UiJs)\`n</script></body></html>"
  [IO.File]::WriteAllText($path, $html, (New-Object System.Text.UTF8Encoding $true))
}`;

function assemblerAudit(e) {
  const corps = lire(e.source), moteur = lire('audits/engine.ps1');
  return `<#
  ${e.titre} — ${e.description}
  Script autonome et interactif : il demande le serveur à auditer et les identifiants, puis produit
  un rapport HTML dans le dossier « Rapports-Audit » du Bureau. LECTURE SEULE : aucune modification.
  Généré par outils/build.mjs depuis ${e.source} — modifier la source, pas ce fichier.

  Lancement (PowerShell en administrateur, dans le dossier du script) :
    Unblock-File .\\${e.fichier}
    powershell -NoProfile -ExecutionPolicy Bypass -File .\\${e.fichier}
#>
#Requires -Version 5.1
${moteur}

# --- Rapport HTML ---
${WRITE_REPORT}
$script:UiCss = @'
${auditCss}
'@
$script:UiJs = @'
${auditJs}
'@

try {
${corps}
} catch {
  Write-Host ''
  Write-Host "  ARRÊT : $($_.Exception.Message)" -ForegroundColor Red
} finally {
  if ($Host.Name -eq 'ConsoleHost') { Write-Host ''; [void](Read-Host '  Appuyer sur Entrée pour fermer') }
}
`;
}
function injecterUi(texte, nom) {
  for (const [marque, contenu] of [["$script:UiCss = @'\n", css], ["$script:UiJs = @'\n", js]]) {
    const a = texte.indexOf(marque);
    if (a < 0) { verifier(false, `${nom} : marqueur ${marque.trim()} introuvable`); continue; }
    const b = texte.indexOf("\n'@\n", a);
    texte = texte.slice(0, a) + marque + contenu + texte.slice(b);
  }
  return texte;
}
function dateGit(fichiers) {
  try { return execSync(`git log -1 --format=%cs -- ${fichiers.map((f) => JSON.stringify(f)).join(' ')}`, { cwd: ROOT, stdio: ['ignore', 'pipe', 'ignore'] }).toString().trim() || null; } catch { return null; }
}

// ---- génération
const cat = JSON.parse(lire('catalogue.json'));
rmSync(join(SITE, 'scripts'), { recursive: true, force: true });
rmSync(join(SITE, 'lanceur'), { recursive: true, force: true });
const ids = new Set();
const generes = new Map();
for (const e of cat.scripts) {
  verifier(/^[a-z0-9-]{1,40}$/.test(e.id || ''), `id invalide : ${e.id}`);
  verifier(!ids.has(e.id), `id en double : ${e.id}`); ids.add(e.id);
  verifier(/^[A-Za-z0-9_.-]+\.ps1$/.test(e.fichier || ''), `${e.id} : nom de fichier invalide`);
  verifier(existsSync(join(SRC, e.source || '')), `${e.id} : source absente (${e.source})`);
  if (!existsSync(join(SRC, e.source || ''))) { continue; }
  for (const a of e.arguments || []) { verifier(/^-[A-Za-z][A-Za-z0-9]{0,40}$/.test(a), `${e.id} : argument non autorisé « ${a} » (seulement des commutateurs comme -VerifierSeulement)`); }
  if (e.parent) { verifier(cat.scripts.some((x) => x.id === e.parent && !x.parent), `${e.id} : parent inconnu (${e.parent})`); }
  const deja = generes.get(e.fichier);
  if (deja) {
    verifier(deja.source === e.source, `${e.fichier} produit par deux sources différentes`);
    Object.assign(e, { sha256: deja.sha256, taille: deja.taille, modifie: deja.modifie }); delete e.source; delete e.assemblage; continue;
  }
  let texte;
  if (e.assemblage === 'audit') { texte = assemblerAudit(e); }
  else if (e.assemblage === 'poste') { texte = injecterUi(lire(e.source) + '\n', e.fichier); }
  else { texte = lire(e.source) + '\n'; }   // script simple : copié tel quel
  const buf = ecrirePs(join(SITE, 'scripts', e.fichier), texte);
  e.sha256 = createHash('sha256').update(buf).digest('hex').toUpperCase();
  e.taille = buf.length;
  const deps = [join('sources', e.source)].concat(e.assemblage === 'audit' ? ['sources/audits/engine.ps1', 'sources/ui'] : e.assemblage === 'poste' ? ['sources/ui/ui.css', 'sources/ui/ui.js'] : []);
  e.modifie = dateGit(deps) || new Date().toISOString().slice(0, 10);
  generes.set(e.fichier, { source: e.source, sha256: e.sha256, taille: e.taille, modifie: e.modifie });
  delete e.source; delete e.assemblage;
}
for (const f of ['lanceur.ps1', 'Installer-Lanceur.ps1']) {
  const buf = ecrirePs(join(SITE, 'lanceur', f), lire('lanceur/' + f) + '\n');
  if (f === 'lanceur.ps1') { cat.lanceur = { sha256: createHash('sha256').update(buf).digest('hex').toUpperCase() }; }   // mise à jour automatique des lanceurs installés
}

if (erreurs.length) { console.error('ÉCHEC de la construction :\n  - ' + erreurs.join('\n  - ')); process.exit(1); }
cat.genere = new Date().toISOString().slice(0, 16);
writeFileSync(join(SITE, 'manifest.json'), JSON.stringify(cat, null, 2) + '\n');
for (const e of cat.scripts) { console.log(`${e.id.padEnd(16)} ${e.fichier.padEnd(24)} ${String(Math.round(e.taille / 1024)).padStart(4)} Ko  ${e.sha256.slice(0, 16)}`); }
console.log(`OK : ${cat.scripts.length} scripts, manifeste écrit.`);
