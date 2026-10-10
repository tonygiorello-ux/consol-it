# Console IT

Console web d'intervention. Elle lance, sur le poste où elle est ouverte, les scripts PowerShell suivants :

- **Poste de travail** : inventaire puis restauration lors d'une migration de poste ;
- **Administration** : audits en lecture seule (AD, DNS, DHCP, Veeam, Hyper-V, ESXi, vCenter).

Le site ne fait que servir les scripts. Inventaires, rapports et dossiers de migration restent sur le poste ou sur le support USB choisi.

Le cycle de travail : on modifie en local, on pousse sur GitHub, puis Cloudflare Pages reconstruit et publie le site. En parallèle, GitHub Actions lance les tests.

---

## Organisation du dépôt

```
sources/                     ← ce que l'on modifie
  catalogue.json             liste des actions de la console (titre, groupe, admin ou non, source…)
  audits/engine.ps1          moteur commun des audits (questions, connexion WinRM/SSH, rapport)
  audits/body_*.ps1          contrôles propres à chaque audit
  poste/*.ps1                Inventaire-Poste.ps1, Restaure-Poste.ps1
  ui/                        interface des rapports HTML (partagée par tous les scripts)
  lanceur/                   lanceur local (protocole consoleit:) et son installeur
site/                        ← publié par Cloudflare
  index.html, _headers, robots.txt   (versionnés)
  scripts/, lanceur/, manifest.json  (GÉNÉRÉS par le build, non versionnés)
outils/build.mjs             construit site/ à partir de sources/ (Node.js, sans dépendance)
tests/Lancer-Tests.ps1       encodage, syntaxe, audits exécutés sur données factices
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

### 3. Cloudflare Pages relié au dépôt

1. Ouvrir Cloudflare, puis **Workers & Pages**, **Create**, **Pages**, **Connect to Git**, et autoriser GitHub sur le dépôt `console-it`.
2. Réglages du build :

   | Réglage | Valeur |
   |---|---|
   | Production branch | `main` |
   | Framework preset | None |
   | Build command | `node outils/build.mjs` |
   | Build output directory | `site` |
   | Variable d'environnement | `NODE_VERSION` = `20` |

3. **Save and Deploy**. Chaque push sur `main` republie le site. Une autre branche donne un aperçu sur `<branche>.console-it.pages.dev`.
4. Domaine personnalisé (conseillé) : **Custom domains**, par exemple `outils.mondomaine.fr`.

### 4. Protéger la console (Cloudflare Zero Trust, Access)

1. Créer une application **Self-hosted** sur le domaine de la console **et** sur `console-it.pages.dev` et `*.console-it.pages.dev`.
   Règle *Allow* : les e-mails autorisés.
2. Créer une **seconde application** sur les mêmes domaines, limitée aux chemins `scripts/*`, `lanceur/*` et `manifest.json`.
   Règle *Bypass* : *Everyone*.
   Le lanceur télécharge ces fichiers hors du navigateur, donc sans la session Access. Ils ne contiennent aucun secret.
3. Activer l'authentification à deux facteurs sur les comptes Cloudflare et GitHub. Celui qui peut pousser sur `main` décide de ce que le lanceur exécute.

---

## Modifier ou ajouter un script

```
git pull
# … modifier les fichiers dans sources/ …
node outils/build.mjs                     # construit site/ (erreurs de catalogue signalées)
pwsh -File tests/Lancer-Tests.ps1         # ou : powershell -File tests\Lancer-Tests.ps1
git add -A
git commit -m "Audit DNS : contrôle des redirecteurs conditionnels"
git push                                  # Cloudflare republie en ~1 minute
```

- **Tester un script sur sa machine**, sans lanceur :
  `powershell -ExecutionPolicy Bypass -File site\scripts\Audit-DNS.ps1`
- **Tester la console en local** : lancer `npx wrangler pages dev site`, puis ouvrir http://localhost:8788. Le menu Lanceur donne alors la commande d'installation pour `localhost`. Le lanceur pointe ensuite vers le local. Réinstaller depuis la console en ligne pour revenir à la normale.
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
    - `groupe` : `poste`, `annuaire`, `sauvegarde`, `virtualisation` ou `outils` ;
    - `admin` : `true` demande l'élévation UAC ;
    - `assemblage` : `"audit"` pour un corps d'audit utilisant le moteur commun (voir `audits/body_*.ps1`). Si on l'omet, le script est publié tel quel.
- **Nouvel audit** : copier un `body_*.ps1` existant comme modèle. Il dispose de `Get-Cible`, `Invoke-Cible`, `Invoke-SshLot`, `Add-Check`, `To-Table`, `Cmd` et `Save-Audit` (voir `engine.ps1`). Ajouter ses données factices dans `tests/fixtures.ps1`.

Le build convertit chaque script en UTF-8 avec BOM et en CRLF. Il calcule aussi l'empreinte SHA-256 inscrite dans `manifest.json`. Le lanceur refuse un script dont l'empreinte ne correspond pas.

---

## Utilisation sur un poste

1. **Une fois par poste et par utilisateur** : menu **Lanceur**, copier la commande d'installation, puis la coller dans PowerShell, en mode normal et non administrateur.
2. **Lancer une action** : cliquer sur **▶ Lancer**. Le navigateur demande d'ouvrir « Console IT ». Une fenêtre sur le poste affiche l'action, le mode et l'empreinte, et il faut confirmer.
   - Pour les audits, Windows demande l'élévation (UAC).
   - L'inventaire et la restauration s'ouvrent dans la session de l'utilisateur, sans élévation : ils lisent et écrivent son profil.
3. **Fin d'intervention chez un client** : menu **Lanceur**, puis copier la commande de retrait.

Chaque fiche propose aussi **Copier la commande**. Elle lance le script sans le lanceur.

## Sécurité

- Le lien `consoleit:run/<id>` ne transporte qu'un identifiant. Une page web, y compris un autre site, ne peut faire passer ni commande ni paramètre.
- Seules les actions du `manifest.json` du site enregistré à l'installation peuvent être lancées. Ce site est en https, ou `localhost` pour les tests.
- L'empreinte SHA-256 est vérifiée, et chaque lancement demande une confirmation sur le poste.
- La confiance repose sur le dépôt GitHub et sur le compte Cloudflare : il faut protéger ces deux comptes (double authentification, dépôt privé, branche `main` protégée si l'on travaille à plusieurs).
- Une GPO qui impose `AllSigned` bloque `-ExecutionPolicy Bypass`. Il faudrait alors signer les scripts.
