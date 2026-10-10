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
