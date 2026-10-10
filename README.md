# Console IT

Console web d'intervention. Elle lance, sur le poste où elle est ouverte, les scripts PowerShell suivants :

- **Poste de travail** : inventaire puis restauration lors d'une migration de poste ;
- **Diagnostics** : diagnostics du poste en lecture seule (lenteurs PC / Office / réseau, veille, matériel, fiche garantie, crashs, imprimantes, cartographie réseau, domaine et GPO, sécurité, inventaire des logiciels), plus l'installation optionnelle de nmap ;
- **Administration** : audits en lecture seule (AD, DNS, DHCP, Veeam, Hyper-V, ESXi, vCenter).

Le site ne fait que servir les scripts. Inventaires, rapports et dossiers de migration restent sur le poste ou sur le support USB choisi.

Le cycle de travail : on modifie en local, on pousse sur GitHub, puis Cloudflare (Workers Builds) reconstruit et publie le site. En parallèle, GitHub Actions lance les tests.

---

## Organisation du dépôt

```
sources/                     ← ce que l'on modifie
  catalogue.json             liste des actions de la console (titre, groupe, admin ou non, source…)
  audits/engine.ps1          moteur commun des audits (questions, connexion WinRM/SSH, rapport)
  audits/body_*.ps1          contrôles propres à chaque audit
  diagnostics/body_*.ps1     contrôles de chaque diagnostic poste (même moteur et même rapport que les audits)
  outils/                    scripts publiés tels quels (ex. Installer-Nmap.ps1)
  poste/*.ps1                Inventaire-Poste.ps1, Restaure-Poste.ps1
  ui/                        interface des rapports HTML (partagée par tous les scripts)
  lanceur/                   lanceur local (protocole consoleit:) et son installeur
site/                        ← publié par Cloudflare
  index.html, _headers, robots.txt   (versionnés)
  scripts/, lanceur/, manifest.json  (GÉNÉRÉS par le build, non versionnés)
worker/index.js              accès par code PIN (session navigateur + jeton du lanceur)
outils/build.mjs             construit site/ à partir de sources/ (Node.js, sans dépendance)
wrangler.jsonc               déploiement Cloudflare : build automatique puis publication de site/
tests/Lancer-Tests.ps1       encodage, syntaxe, audits sur données factices, diagnostics avec commandes Windows simulées (tests/stubs_windows.ps1)
.github/workflows/           tests automatiques à chaque push
```

Ne jamais modifier `site/scripts` : ces fichiers sont recréés à chaque build. Un script d'audit publié est l'assemblage du moteur, de l'interface et du corps de l'audit.

---

## Mise en place (une seule fois)

### 1. Poste de travail

- Installer [Git](https://git-scm.com/download/win), [Node.js LTS](https://nodejs.org) et, conseillé, [PowerShell 7](https://aka.ms/powershell) :
  `winget install Git.Git OpenJS.NodeJS.LTS Microsoft.PowerShell`
- Éditeur conseillé : VS Code, avec l'extension PowerShell.

### 2. GitHub

1. Créer un dépôt **privé** vide sur GitHub, par exemple `console-it`, sans README ni licence.
2. Dans le dossier du projet :
   ```
   git remote add origin https://github.com/<compte>/console-it.git
   git push -u origin main
   ```

### 3. Cloudflare relié au dépôt (Workers)

Le fichier `wrangler.jsonc` décrit le déploiement. Le site statique est le dossier `site`, et la commande `node outils/build.mjs` s'exécute automatiquement avant chaque déploiement.

1. Ouvrir Cloudflare, puis **Workers & Pages**, **Create**, **Import a repository**, et choisir `consol-it`.
   Si le dépôt n'apparaît pas : sur GitHub, aller dans Settings, Applications, Cloudflare Workers and Pages, Configure, puis ajouter le dépôt.
2. Réglages :

   | Réglage | Valeur |
   |---|---|
   | Nom du Worker | `consol-it` (doit correspondre à `name` dans `wrangler.jsonc`) |
   | Build command | *(vide)* : le build est déclenché par `wrangler.jsonc` |
   | Deploy command | `npx wrangler deploy` |
   | Branche de production | `main` |

3. Chaque push sur `main` republie le site sur `https://consol-it.<compte>.workers.dev`. Le journal se trouve dans l'onglet **Deployments** du Worker, puis **View build**.
4. Domaine personnalisé (conseillé) : dans le Worker, **Settings**, **Domains & Routes**, **Add**, puis **Custom domain**.

### 4. Code PIN (accès à la console)

Le Worker `worker/index.js` est placé devant le site. Sans session valide, toute page redirige vers l'écran du code PIN.

**Dans Cloudflare**, ouvrir le Worker `consol-it`, puis **Settings**, **Variables and Secrets**, **Add**. Créer deux variables de type **Secret** :

| Nom | Valeur |
|---|---|
| `PIN` | le code d'accès : 6 caractères minimum, **8 chiffres ou plus conseillé** |
| `CLE_SESSION` | une chaîne aléatoire d'au moins 32 caractères, par exemple le résultat de `-join ((48..57)+(65..90)+(97..122) \| Get-Random -Count 48 \| % {[char]$_})` |

Sans ces deux secrets, le site affiche un message de configuration au lieu de la console. Changer `CLE_SESSION` déconnecte toutes les sessions et invalide les lanceurs installés. Changer `PIN` ne touche pas aux sessions déjà ouvertes.

**Fonctionnement :**
- **Navigateur :** la session est liée à la page ouverte. C'est un cookie signé `HttpOnly` / `Secure` / `SameSite=Strict`, valable 3 minutes et prolongé chaque minute par la console. Il est effacé dès qu'on quitte la page : onglet fermé, autre site, navigateur fermé ou rechargement. Le PIN est alors redemandé. La durée maximale d'une session est de 8 h. Le lien « Se déconnecter » se trouve dans la barre latérale.
- **Essais limités :** 5 essais par minute et par adresse IP, avec un délai après chaque erreur.
- **Lanceur et commandes copiées :** la console leur ajoute un **jeton signé valable 8 h**, envoyé dans l'en-tête `X-Console-Jeton`. Ce jeton n'ouvre que `manifest.json`, `scripts/` et `lanceur/`, jamais la console. Il expire en même temps que le lanceur.
- **Test local :** copier `.dev.vars.exemple` en `.dev.vars` (fichier non versionné), puis lancer `npx wrangler dev`.

**Pour aller plus loin :** pour exiger une identité (e-mail ou compte Microsoft) en plus du PIN, ajouter Cloudflare Access sur le domaine. Le PIN reste alors une seconde barrière.

---

## Modifier ou ajouter un script

```
git pull
# … modifier les fichiers dans sources/ …
node outils/build.mjs                     # construit site/ (erreurs de catalogue signalées)
pwsh -File tests/Lancer-Tests.ps1         # ou : powershell -File tests\Lancer-Tests.ps1
git add -A
git commit -m "Audit DNS : contrôle des redirecteurs conditionnels"
git push                                  # Cloudflare republie en 1 à 2 minutes
```

- **Tester un script sur sa machine**, sans lanceur :
  `powershell -ExecutionPolicy Bypass -File site\scripts\Audit-DNS.ps1`
- **Tester la console en local** : lancer `npx wrangler dev` (build compris), puis ouvrir http://localhost:8787. Le menu Lanceur donne alors la commande d'installation pour `localhost`. Le lanceur pointe ensuite vers le local. Réinstaller depuis la console en ligne pour revenir à la normale.
- **Ajouter un nouveau script** :
  - Placer le `.ps1` dans `sources/`, par exemple `sources/outils/Nettoyage-Profil.ps1`.
  - Ajouter une entrée dans `sources/catalogue.json` :
    ```json
    { "id": "nettoyage-profil", "groupe": "outils", "titre": "Nettoyage du profil",
      "fichier": "Nettoyage-Profil.ps1", "source": "outils/Nettoyage-Profil.ps1",
      "admin": false, "cible": "Poste, session de l'utilisateur",
      "description": "…", "questions": ["…"], "prerequis": "…" }
    ```
  - Valeurs possibles :
    - `groupe` : `poste`, `diagnostic` (avec `categorie`, ex. « Performance et lenteurs »), `annuaire`, `sauvegarde`, `virtualisation` ou `outils` ;
    - `admin` : `true` demande l'élévation UAC ;
    - `parent` + `libelle` + `arguments` (ex. `["-VerifierSeulement"]`) : variante d'une action, affichée comme bouton supplémentaire sur la fiche du parent. Seuls des commutateurs sont acceptés, jamais de valeurs ;
    - `assemblage` : `"audit"` pour un corps d'audit utilisant le moteur commun (voir `audits/body_*.ps1`). Si on l'omet, le script est publié tel quel.
- **Nouvel audit** : copier un `body_*.ps1` existant comme modèle. Il dispose de `Get-Cible`, `Invoke-Cible`, `Invoke-SshLot`, `Add-Check`, `To-Table`, `Cmd` et `Save-Audit` (voir `engine.ps1`). Ajouter ses données factices dans `tests/fixtures.ps1`.

Le build convertit chaque script en UTF-8 avec BOM et en CRLF. Il calcule aussi l'empreinte SHA-256 inscrite dans `manifest.json`. Le lanceur refuse un script dont l'empreinte ne correspond pas.

---

## Utilisation sur un poste

1. **Une fois par poste et par utilisateur** : menu **Lanceur**, copier la commande d'installation, puis la coller dans PowerShell, en mode normal et non administrateur.
2. **Lancer une action** : cliquer sur **▶ Lancer**. Le navigateur demande d'ouvrir « Console IT ». Une fenêtre sur le poste affiche l'action, le mode et l'empreinte, et il faut confirmer.
   - Pour les audits, Windows demande l'élévation (UAC).
   - L'inventaire et la restauration s'ouvrent dans la session de l'utilisateur, sans élévation : ils lisent et écrivent son profil.
3. Le lanceur est **valable 8 heures**. Il se retire ensuite seul : une tâche planifiée de l'utilisateur s'en charge, et il vérifie aussi sa date à chaque clic. Réinstaller le prolonge de 8 h. Pour le retirer plus tôt : menu **Lanceur**, puis copier la commande de retrait.
4. **Restauration** : deux boutons sur la même fiche, **Restaurer et contrôler** (`-Restaurer`) ou **Vérifier seulement** (`-VerifierSeulement` : ne modifie rien, régénère le rapport). Lancé sans l'une de ces options, le script demande le mode avant de commencer.
5. **Mise à jour du lanceur** : le manifeste publie l'empreinte du lanceur. Un lanceur installé dont l'empreinte diffère télécharge la nouvelle version, la vérifie, puis relance l'action. Pas besoin de le réinstaller après une modification de `sources/lanceur/lanceur.ps1`. En revanche, une modification de l'installeur demande une réinstallation.

Chaque fiche propose aussi **Copier la commande**. Elle lance le script sans le lanceur.

## Sécurité

- Le lien `consoleit:run/<id>` ne transporte qu'un identifiant. Une page web, y compris un autre site, ne peut faire passer ni commande ni paramètre.
- Seules les actions du `manifest.json` du site enregistré à l'installation peuvent être lancées. Ce site est en https, ou `localhost` pour les tests.
- L'empreinte SHA-256 est vérifiée, et chaque lancement demande une confirmation sur le poste.
- La confiance repose sur le dépôt GitHub et sur le compte Cloudflare : il faut protéger ces deux comptes (double authentification, dépôt privé, branche `main` protégée si l'on travaille à plusieurs).
- Une GPO qui impose `AllSigned` bloque `-ExecutionPolicy Bypass`. Il faudrait alors signer les scripts.
