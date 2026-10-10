// Console IT — Worker placé devant le site statique : accès protégé par code PIN.
//
// - Navigateur : le PIN ouvre une session (cookie signé, HttpOnly, 8 h).
// - Lanceur et commandes PowerShell : ils ne passent pas par le navigateur ; la console leur fournit
//   un jeton signé valable 8 h (en-tête X-Console-Jeton), limité à manifest.json, scripts/ et lanceur/.
// - Secrets à définir dans Cloudflare (Worker > Settings > Variables and Secrets, type Secret) :
//     PIN           code d'accès (6 caractères minimum ; 8 chiffres ou plus conseillé)
//     CLE_SESSION   clé aléatoire longue servant à signer sessions et jetons (ne jamais la réutiliser ailleurs)
// - Essais de PIN limités par adresse IP (binding LIMITE_PIN, voir wrangler.jsonc) + délai après chaque échec.

const DUREE_S = 8 * 3600;
const COOKIE = 'consoleit_session';
const ENTETE_JETON = 'x-console-jeton';
const CHEMINS_LANCEUR = /^\/(manifest\.json|scripts\/[A-Za-z0-9_.-]+\.ps1|lanceur\/[A-Za-z0-9_.-]+\.ps1)$/;
const PUBLICS = new Set(['/robots.txt', '/favicon.ico']);
const enc = new TextEncoder();

const b64u = (buf) => btoa(String.fromCharCode(...new Uint8Array(buf))).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
const deb64u = (s) => Uint8Array.from(atob(s.replace(/-/g, '+').replace(/_/g, '/') + '==='.slice((s.length + 3) % 4)), (c) => c.charCodeAt(0));

async function cle(env) {
  return crypto.subtle.importKey('raw', enc.encode(env.CLE_SESSION), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign', 'verify']);
}
async function signer(env, donnees) {
  const p = b64u(enc.encode(JSON.stringify(donnees)));
  const s = await crypto.subtle.sign('HMAC', await cle(env), enc.encode(p));
  return p + '.' + b64u(s);
}
async function verifier(env, jeton, type) {
  if (!jeton || jeton.length > 600 || !/^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/.test(jeton)) { return null; }
  const [p, s] = jeton.split('.');
  let ok = false;
  try { ok = await crypto.subtle.verify('HMAC', await cle(env), deb64u(s), enc.encode(p)); } catch { return null; }
  if (!ok) { return null; }
  let d; try { d = JSON.parse(new TextDecoder().decode(deb64u(p))); } catch { return null; }
  if (d.t !== type || typeof d.exp !== 'number' || d.exp < Date.now() / 1000) { return null; }
  return d;
}
async function pinCorrect(env, saisi) {
  // comparaison à temps constant (HMAC des deux valeurs, puis comparaison octet par octet)
  const k = await cle(env);
  const a = new Uint8Array(await crypto.subtle.sign('HMAC', k, enc.encode('pin:' + saisi)));
  const b = new Uint8Array(await crypto.subtle.sign('HMAC', k, enc.encode('pin:' + env.PIN)));
  let diff = 0; for (let i = 0; i < a.length; i++) { diff |= a[i] ^ b[i]; }
  return diff === 0;
}
function lireCookie(req) {
  const m = (req.headers.get('cookie') || '').match(new RegExp('(?:^|;\\s*)' + COOKIE + '=([^;]+)'));
  return m ? m[1] : null;
}
const SECU = {
  'X-Content-Type-Options': 'nosniff', 'X-Frame-Options': 'DENY', 'Referrer-Policy': 'no-referrer', 'X-Robots-Tag': 'noindex, nofollow',
  'Content-Security-Policy': "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'",
  'Cache-Control': 'no-store',
};
function reponse(corps, statut = 200, entetes = {}) {
  return new Response(corps, { status: statut, headers: { 'Content-Type': 'text/html; charset=utf-8', ...SECU, ...entetes } });
}
const attendre = (ms) => new Promise((r) => setTimeout(r, ms));

function pageConnexion(message = '', bloque = false) {
  return `<!doctype html><html lang="fr"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex,nofollow"><title>Console IT</title>
<style>
:root{--bg:#eef1f5;--panel:#fff;--ink:#142030;--mute:#5a6779;--line:#dbe1e9;--accent:#1c5ea8;--bad:#b42318;--badbg:#fde6e3;--side:#0d2238;--f:"Segoe UI Variable Text","Segoe UI",system-ui,-apple-system,Roboto,sans-serif}
@media (prefers-color-scheme:dark){:root{--bg:#0b1117;--panel:#131c27;--ink:#e3eaf2;--mute:#96a3b3;--line:#233041;--accent:#7eb0ee;--bad:#ff8b80;--badbg:#391613;--side:#08131f;color-scheme:dark}}
*{box-sizing:border-box}html,body{margin:0;height:100%}
body{background:var(--bg);color:var(--ink);font:15px/1.5 var(--f);display:grid;place-items:center;padding:16px}
.b{width:100%;max-width:360px;background:var(--panel);border:1px solid var(--line);border-radius:16px;overflow:hidden}
.h{background:var(--side);color:#fff;padding:20px 24px}.h b{font-size:18px;display:block}.h span{font-size:12.5px;color:#c6d4e5}
form{padding:22px 24px 24px;display:flex;flex-direction:column;gap:14px}
label{font-weight:600;font-size:14px}
input{font:600 22px/1 ui-monospace,"Cascadia Mono",Consolas,monospace;letter-spacing:.35em;text-align:center;padding:12px;border:1px solid var(--line);border-radius:10px;background:var(--bg);color:var(--ink);width:100%}
input:focus{outline:2px solid var(--accent);outline-offset:1px}
button{font:600 15px/1 var(--f);padding:12px;border:0;border-radius:10px;background:var(--accent);color:#fff;cursor:pointer}
@media (prefers-color-scheme:dark){button{color:#0b1117}}
.e{background:var(--badbg);color:var(--bad);border-radius:8px;padding:10px 12px;font-size:13.5px}
p{margin:0;color:var(--mute);font-size:12.5px}
</style></head><body><div class="b"><div class="h"><b>Console IT</b><span>Accès réservé</span></div>
<form method="post" action="/login" autocomplete="off">
${message ? `<div class="e">${message}</div>` : ''}
<label for="pin">Code PIN</label>
<input id="pin" name="pin" type="password" inputmode="numeric" autocomplete="one-time-code" maxlength="64" required autofocus ${bloque ? 'disabled' : ''}>
<button type="submit" ${bloque ? 'disabled' : ''}>Entrer</button>
<p>Session valable 8 heures sur ce navigateur.</p>
</form></div></body></html>`;
}

export default {
  async fetch(req, env) {
    const url = new URL(req.url);
    const chemin = url.pathname;

    if (!env.PIN || !env.CLE_SESSION || String(env.PIN).length < 6 || String(env.CLE_SESSION).length < 32) {
      return reponse('<p style="font-family:system-ui;padding:24px">Console IT : secrets <b>PIN</b> (6 caractères minimum) et <b>CLE_SESSION</b> (32 caractères minimum) à définir dans Cloudflare, Worker &gt; Settings &gt; Variables and Secrets.</p>', 503);
    }
    if (PUBLICS.has(chemin)) { return env.ASSETS.fetch(req); }

    // --- connexion
    if (chemin === '/login') {
      if (req.method === 'GET') { return reponse(pageConnexion()); }
      if (req.method !== 'POST') { return reponse('', 405); }
      const ip = req.headers.get('cf-connecting-ip') || 'inconnue';
      if (env.LIMITE_PIN) {
        const { success } = await env.LIMITE_PIN.limit({ key: 'pin:' + ip });
        if (!success) { return reponse(pageConnexion('Trop d’essais depuis cette adresse. Réessayer dans une minute.', false), 429); }
      }
      let pin = '';
      try { pin = String((await req.formData()).get('pin') || '').trim().slice(0, 64); } catch { }
      if (!pin || !(await pinCorrect(env, pin))) {
        await attendre(1200);   // ralentit les essais en série
        return reponse(pageConnexion('Code PIN incorrect.'), 401);
      }
      const session = await signer(env, { t: 'session', exp: Math.floor(Date.now() / 1000) + DUREE_S });
      return new Response(null, { status: 303, headers: { Location: '/', 'Set-Cookie': `${COOKIE}=${session}; Path=/; Max-Age=${DUREE_S}; HttpOnly; Secure; SameSite=Lax`, ...SECU } });
    }
    if (chemin === '/logout') {
      return new Response(null, { status: 303, headers: { Location: '/login', 'Set-Cookie': `${COOKIE}=; Path=/; Max-Age=0; HttpOnly; Secure; SameSite=Lax`, ...SECU } });
    }

    const session = await verifier(env, lireCookie(req), 'session');

    // --- jeton pour le lanceur et les commandes PowerShell (demandé par la console)
    if (chemin === '/api/jeton') {
      if (!session) { return new Response('{"erreur":"session"}', { status: 401, headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' } }); }
      const exp = Math.floor(Date.now() / 1000) + DUREE_S;
      const jeton = await signer(env, { t: 'dl', exp });
      return new Response(JSON.stringify({ jeton, exp, sessionExp: session.exp }), { headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' } });
    }

    if (session) { return env.ASSETS.fetch(req); }

    // --- lanceur : uniquement les fichiers à exécuter, avec un jeton valide
    if (CHEMINS_LANCEUR.test(chemin) && (req.method === 'GET' || req.method === 'HEAD')) {
      if (await verifier(env, req.headers.get(ENTETE_JETON), 'dl')) { return env.ASSETS.fetch(req); }
      return new Response('Jeton absent ou expiré : réinstaller le lanceur depuis la console.\n', { status: 401, headers: { 'Content-Type': 'text/plain; charset=utf-8', 'Cache-Control': 'no-store' } });
    }

    // --- sinon : page de connexion
    const page = req.method === 'GET' && (req.headers.get('accept') || '').includes('text/html');
    return page ? new Response(null, { status: 303, headers: { Location: '/login', ...SECU } }) : new Response('Authentification requise\n', { status: 401, headers: { 'Content-Type': 'text/plain; charset=utf-8', 'Cache-Control': 'no-store' } });
  },
};
