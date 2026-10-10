/* ================================================================ RAPPORT D'AUDIT (scripts d'administration) */
function audit() {
  ST.CRIT = { l: 'Critique', c: 'bad' }; ST.ATT = { l: 'Attention', c: 'warn' }; ST.OK = { l: 'Sain', c: 'ok' }; ST.INFO = { l: 'Info', c: 'info' };
  var AO = { CRIT: 0, ATT: 1, INFO: 2, OK: 3 };
  var m = D.meta || {}, checks = arr(D.checks), cats = arr(D.cats), n = D.counts || {};
  checks.forEach(function (k, i) { k.i = i; if (!AO.hasOwnProperty(k.s)) { k.s = 'INFO'; } });
  var byId = {};
  cats.forEach(function (c) {
    c.items = checks.filter(function (k) { return k.c === c.id; }).sort(function (a, b) { return AO[a.s] - AO[b.s] || a.i - b.i; });
    c.n = { OK: 0, ATT: 0, CRIT: 0, INFO: 0 };
    c.items.forEach(function (k) { c.n[k.s]++; });
    c.state = c.n.CRIT ? 'bad' : (c.n.ATT ? 'warn' : 'ok');
    byId[c.id] = c;
  });
  var orphans = checks.filter(function (k) { return !byId[k.c]; });
  if (orphans.length) { var oc = { id: 'autres', nom: 'Autres contrôles', icon: '📋', items: orphans, n: { OK: 0, ATT: 0, CRIT: 0, INFO: 0 } }; orphans.forEach(function (k) { oc.n[k.s]++; }); oc.state = oc.n.CRIT ? 'bad' : (oc.n.ATT ? 'warn' : 'ok'); cats.push(oc); byId.autres = oc; }
  cats = cats.filter(function (c) { return c.items.length; });
  var crit = checks.filter(function (k) { return k.s === 'CRIT'; }), att = checks.filter(function (k) { return k.s === 'ATT'; });

  function tab(t) {
    if (!t || !t.cols) { return ''; }
    var cols = arr(t.cols), rows = arr(t.rows);
    if (rows.length && !Array.isArray(rows[0])) { rows = cols.length > 1 ? [rows] : rows.map(function (x) { return [x]; }); }
    if (!rows.length) { return ''; }
    var cell = function (r) { return cols.map(function (c, i) { return val(r[i]); }); };
    var first = rows.slice(0, 15), rest = rows.slice(15);
    var h = table(cols, first.map(cell), 'at');
    if (rest.length) { h += '<details class="more"><summary>▸ Afficher les ' + num(rest.length) + ' lignes suivantes</summary>' + table(cols, rest.map(cell), 'at') + '</details>'; }
    if (t.total > rows.length) { h += '<p class="note">Affichage limité à ' + num(rows.length) + ' lignes sur ' + num(t.total) + '.</p>'; }
    return '<div class="atab">' + h + '</div>';
  }
  function card(k, o) {
    o = o || {};
    var cn = byId[k.c] ? byId[k.c].nom : '';
    var t = (k.e + ' ' + (k.r || '') + ' ' + (k.reco || '') + ' ' + (k.t || '') + ' ' + cn).toLowerCase();
    return '<div class="item s-' + k.s + '"' + (o.id ? ' id="k' + k.i + '"' : '') + ' data-s="' + k.s + '" data-t="' + esc(t) + '">' +
      '<div class="ihead"><div class="el">' + (o.cat && cn ? '<span class="cat">' + esc(cn) + '</span>' : '') + esc(k.e) + (k.t ? ' <span class="tgt">' + esc(k.t) + '</span>' : '') + '</div>' + pill(k.s) + '</div>' +
      (k.r ? '<p class="ares">' + esc(k.r) + '</p>' : '') + tab(k.tab) +
      (k.raw ? '<details class="raw"><summary>▸ Sortie brute de la commande</summary><pre>' + esc(k.raw) + '</pre></details>' : '') +
      (k.reco ? '<div class="act"><b>' + (k.s === 'CRIT' || k.s === 'ATT' ? 'À faire :' : 'Remarque :') + '</b>' + esc(k.reco) + '</div>' : '') +
      actsHtml(k) + '</div>';
  }
  function list(items) {
    var c = { CRIT: 0, ATT: 0, OK: 0, INFO: 0 };
    items.forEach(function (k) { c[k.s]++; });
    var btn = function (f, l, x) { return '<button type="button" data-f="' + f + '"' + (f === 'all' ? ' class="on"' : '') + '>' + l + '<i>' + x + '</i></button>'; };
    var seg = btn('all', 'Tout', items.length) + (c.CRIT ? btn('CRIT', 'Critiques', c.CRIT) : '') + (c.ATT ? btn('ATT', 'Attention', c.ATT) : '') + (c.OK ? btn('OK', 'Sains', c.OK) : '') + (c.INFO ? btn('INFO', 'Info', c.INFO) : '');
    return '<div class="lst" data-f="all"><div class="toolbar"><div class="seg">' + seg + '</div><input class="search" type="search" data-lq placeholder="Rechercher dans cette rubrique…"></div>' +
      items.map(function (k) { return card(k, { id: true }); }).join('') + '<div class="empty">Aucun contrôle ne correspond.</div></div>';
  }
  function abar(x, total) {
    if (!total) { return '<div class="bar"></div>'; }
    var w = function (v) { return (v * 100 / total).toFixed(2) + '%'; };
    return '<div class="bar"><i class="b-ok" style="width:' + w(x.OK + x.INFO) + '"></i><i class="b-warn" style="width:' + w(x.ATT) + '"></i><i class="b-bad" style="width:' + w(x.CRIT) + '"></i></div>';
  }

  var views = {};
  // ---- Synthèse
  var hcls, htitle, htext;
  if (crit.length) { hcls = 'bad'; htitle = plural(crit.length, 'point critique', 'points critiques') + (att.length ? ' et ' + plural(att.length, 'point', 'points') + ' d’attention' : ''); htext = 'Les points critiques présentent un risque immédiat (panne, perte de données, sécurité). Chaque fiche indique la cause probable et, quand c’est possible, la commande de correction à copier.'; }
  else if (att.length) { hcls = 'warn'; htitle = plural(att.length, 'point', 'points') + ' d’attention'; htext = 'Aucun point critique. Les points d’attention sont des écarts aux bonnes pratiques ou des risques à moyen terme à planifier.'; }
  else { hcls = 'ok'; htitle = 'Aucun problème détecté'; htext = 'Tous les contrôles effectués sont au vert.'; }
  var ringC = D.score >= 90 ? 'var(--ok)' : (D.score >= 70 ? '#e3a33b' : 'var(--bad)');
  var tiles = cats.map(function (c) {
    var t = c.n.CRIT ? plural(c.n.CRIT, 'critique') + (c.n.ATT ? ' · ' + c.n.ATT + ' attention' : '') : (c.n.ATT ? c.n.ATT + ' attention' : 'Tout est sain ✓');
    return '<a class="tile ' + c.state + '" href="#' + c.id + '"><div class="tt"><span>' + c.icon + '</span>' + esc(c.nom) + '</div>' + abar(c.n, c.items.length) + '<div class="ts">' + t + ' · ' + plural(c.items.length, 'contrôle') + '</div></a>';
  }).join('');
  var prio = crit.concat(att).slice(0, 12).map(function (k) {
    return '<a class="prio" href="#k' + k.i + '">' + pill(k.s) + '<span><b>' + esc(k.e) + '</b>' + (k.r ? '<small>' + esc(k.r) + '</small>' : '') + '</span><em>' + esc(byId[k.c] ? byId[k.c].nom : '') + ' ›</em></a>';
  }).join('');
  views.synthese =
    '<div class="hero ' + hcls + '"><div class="ring" style="--p:' + D.score + ';--c:' + ringC + '"><span>' + D.score + ' %<small>sain</small></span></div>' +
    '<div><h1>' + esc(htitle) + '</h1><p>' + esc(htext) + '</p><div class="cta">' + (crit.length || att.length ? '<a class="btn primary" href="#traiter">Voir les points à traiter →</a>' : '') + '</div></div></div>' +
    '<div class="strip">' + (m.client ? '<span>Client : <b>' + esc(m.client) + '</b></span>' : '') + '<span>Cible : <b>' + esc(m.cibles || '—') + '</b></span><span>Audit du ' + esc(m.date) + ' · ' + esc(m.duree) + '</span><span>Par ' + esc(m.par) + '</span></div>' +
    '<div class="kpis">' +
    '<a class="kpi ' + (crit.length ? 'bad' : 'ok') + '" href="#traiter"><b>' + crit.length + '</b><span>points critiques</span></a>' +
    '<a class="kpi ' + (att.length ? 'warn' : 'ok') + '" href="#traiter"><b>' + att.length + '</b><span>points d’attention</span></a>' +
    '<a class="kpi ok" href="#' + (cats[0] ? cats[0].id : 'synthese') + '"><b>' + num(n.OK) + '</b><span>contrôles sains</span></a>' +
    '<a class="kpi acc" href="#' + (cats[0] ? cats[0].id : 'synthese') + '"><b>' + num(n.INFO) + '</b><span>informations relevées</span></a></div>' +
    (prio ? '<h2 class="sec">Points prioritaires</h2><div class="prios">' + prio + '</div>' + (crit.length + att.length > 12 ? '<p class="note"><a href="#traiter">Voir les ' + (crit.length + att.length) + ' points à traiter →</a></p>' : '') : '') +
    '<h2 class="sec">État par rubrique</h2><div class="tiles">' + tiles + '</div>';

  // ---- À traiter
  views.traiter = vh('Points à traiter', crit.length || att.length ? plural(crit.length, 'critique') + ', ' + plural(att.length, 'point') + ' d’attention. Commencer par les critiques.' : '', '❗', 'Points à traiter') +
    (crit.length || att.length ? cats.filter(function (c) { return c.n.CRIT || c.n.ATT; }).map(function (c) {
      return '<h2 class="sec"><span>' + c.icon + '</span>' + esc(c.nom) + '<a href="#' + c.id + '">Voir la rubrique →</a></h2>' +
        c.items.filter(function (k) { return k.s === 'CRIT' || k.s === 'ATT'; }).map(function (k) { return card(k); }).join('');
    }).join('') : '<div class="allgood"><span>✓</span>Aucun point à traiter : tous les contrôles sont sains.</div>');

  // ---- Rubriques
  cats.forEach(function (c) {
    var sub = [c.n.CRIT ? plural(c.n.CRIT, 'critique') : '', c.n.ATT ? c.n.ATT + ' attention' : '', c.n.OK ? plural(c.n.OK, 'contrôle sain', 'contrôles sains') : '', c.n.INFO ? plural(c.n.INFO, 'information') : ''].filter(Boolean).join(' · ');
    views[c.id] = vh(c.nom, sub, c.icon, c.nom) + list(c.items);
  });

  // ---- Aide
  views.aide = vh('Comment lire ce rapport', '', 'ℹ️', 'Aide') +
    panel('Les statuts', '<div class="legend">' + pill('CRIT') + '<span>Risque immédiat : panne, perte de données ou faille. À traiter en priorité.</span>' + pill('ATT') + '<span>Écart aux bonnes pratiques ou risque à moyen terme : à planifier.</span>' +
      pill('OK') + '<span>Contrôle passé avec succès.</span>' + pill('INFO') + '<span>Relevé pour information (inventaire, configuration), sans jugement.</span></div><p class="note">Le score est la part des contrôles sains parmi les contrôles évalués (les informations ne comptent pas).</p>') +
    panel('Chaque fiche', '<p>Le résumé donne le constat. Le tableau reprend les valeurs relevées ; « Sortie brute » affiche la sortie exacte de la commande, utile pour un diagnostic approfondi ou un ticket éditeur. Le cadre coloré indique l’action recommandée.</p>' +
      '<div class="legend"><span class="abtn">⌨️ Copier la commande <i>admin</i></span><span>Copie une commande de correction. Rien n’est appliqué par le script d’audit : relire la commande (« voir la commande »), l’adapter si besoin, puis la coller dans PowerShell administrateur sur le serveur concerné (ou dans la session SSH pour ESXi / vCenter).</span>' +
      '<span class="abtn">🌐 Ouvrir…</span><span>Ouvre une page de référence éditeur.</span></div>') +
    (m.prereq ? panel('Prérequis de ce script', '<p>' + esc(m.prereq) + '</p>') : '') +
    panel('Refaire l’audit', '<p>Après corrections, relancer le même script : un nouveau rapport daté est créé dans le dossier <b>Rapports-Audit</b> du Bureau. Comparer les scores pour mesurer les progrès.</p><p class="note">Identifiant de ce rapport : ' + esc(m.id) + '</p>');

  // ---- Menu
  var nav = [{ id: 'synthese', label: 'Synthèse', icon: '🏠' },
    { id: 'traiter', label: 'Points à traiter', icon: '❗', badge: crit.length + att.length || '✓', badgeCls: crit.length ? 'bad' : (att.length ? 'warn' : 'ok') },
    { grp: 'Rubriques' }];
  cats.forEach(function (c) { var p = c.n.CRIT + c.n.ATT; nav.push({ id: c.id, label: c.nom, dot: c.state, badge: p || '', badgeCls: c.n.CRIT ? 'bad' : 'warn' }); });
  nav.push({ grp: 'Rapport' }, { id: 'aide', label: 'Comment lire ce rapport', icon: 'ℹ️' });
  shell({ brand: m.titre || 'Audit', title: m.client || m.cibles || '', sub: (m.client ? m.cibles + ' · ' : '') + m.date, nav: nav, views: views, foot: '<small>Lecture seule : rien n\u2019a été modifié</small>' });
}
