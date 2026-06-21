# cowork-bridge

Outil Drivenlabs : pont **Google Drive → dossier local plat → Claude Cowork** sur Windows. Déployable chez les clients.

## Problème résolu

Le sandbox de Claude Cowork (VM Hyper-V, montage hôte→VM en **virtiofs / Plan 9**) attend du NTFS standard. Google Drive (et OneDrive/Dropbox/iCloud) expose ses fichiers via un filesystem virtuel / Cloud Files API → le montage échoue (`EINVAL`) ou la VM ne traverse pas la projection → **dossier vu vide dans Cowork**. Limite connue, non corrigée par Anthropic (issues `area:cowork` du repo `anthropics/claude-code`, ex. #25293, #29583, #33590). Contraintes Cowork aggravantes : dossier de travail **obligatoirement dans le home** (`C:\Users\<user>\`), et **raccourcis/jonctions rejetés** (résolus via `realpath()` puis re-bloqués).

Conséquence : seule issue stable = donner à Cowork un vrai dossier local plat dans le home, alimenté automatiquement depuis Drive.

## Architecture (Archi A : rclone sur le dossier Drive Desktop)

```
cloud <->[Google Drive Desktop, mode STREAM]<-> Mon Drive\X <->[rclone bisync, local<->local]<-> %USERPROFILE%\CoworkWork\X -> Cowork
```

- **Moteur = rclone** (licence MIT, **bundlé** dans l'installeur). `rclone bisync` entre DEUX chemins locaux (dossier monté par Drive Desktop ⇄ dossier de travail) — **aucun OAuth, aucun remote**. Choix vs FreeFileSync : FFS interdisait le bundling et l'usage pro de l'édition gratuite ; rclone est librement redistribuable.
- **Mode Stream, pas Miroir** : tout le Drive reste en placeholders ; seuls les dossiers pontés sont hydratés. Stockage local ≈ Σ(dossiers suivis).
- **Ciblage** : ajout **par l'explorateur** (`Select-DriveFolder`, OpenFileDialog détourné). Avant chaque ajout : **garde-fou disque** (`Test-DiskBudget` / `New-BrowsedSource`) — refuse si le dossier ne tient pas sur C: avec une marge (`$DiskMarginBytes` ≈ 5 Go). **Critique** : un disque plein empêche Windows de charger le profil → session vierge (incident Dylan).
- **Synchro de fond** : **agent résident unique** (`Set-SyncAgent` → `_bridge\sync-agent.ps1`, dossier Démarrage, sans droits) = `FileSystemWatcher` (push quasi instantané, récupéré par **`Wait-Event`** qui pompe la file — pas `-Action`+`Start-Sleep` qui ne déclenche pas en `-File`) **+** timer toutes les N min (pull). Relit `config.json` + `_bridge\interval` à chaque tour (délai à chaud, ajout/désync pris en compte sans redémarrer l'agent), écrit `_bridge\next-sync` (minuteur). Boucle mono-thread = mono-instance.
- **Sûreté des données** (flags rclone sourcés) : 1er run d'une paire = `bisync --resync --resync-mode path1` (Drive=Path1 fait foi, **union**, jamais d'effacement Drive). Garde-fous : `--check-access` + marqueur `.coworkbridge-ok` des deux côtés (abort si un côté vu vide/non monté), `--max-delete 25`, `--conflict-resolve none` (garde les 2 versions), `--backup-dir2` local daté (équivalent corbeille) + corbeille Drive native côté Drive, `--resilient --recover --max-lock 2m`. Désync (`Remove-TrackedFolder`) = `rclone copy` local→Drive (copie seule, gardé sur exit 0) puis corbeille du local.

⚠️ **Risque assumé d'Archi A** : on garde la couche Drive Desktop stream → le risque placeholder (hydratation, « placeholder vu comme supprimé ») persiste. `--check-access` couvre « dossier entier vide », pas le placeholder individuel → **test Windows bloquant**. Archi B (rclone direct API, sans Drive Desktop) éliminerait ce risque mais a été écartée (friction OAuth + coût vérification Google « restricted scope » : CASA $500–4 500/an, ou client_id par client).

## Fichiers

- `Run-CoworkBridge.bat` — lanceur (PowerShell `-STA -ExecutionPolicy Bypass`).
- `Install-CoworkBridge.ps1` — installeur + **centre de contrôle** WinForms (PS 5.1, pas de PS7). Moteur **rclone** (`Find-Rclone` → `rclone.exe` bundlé à côté du script). Install : choix des dossiers par l'explorateur + garde disque → `Apply-Config` (filtres, marqueurs, 1ʳᵉ synchro `bisync --resync`, agent). Si install existante → **panneau de gestion** : liste suivis, **Ajouter**, **Désynchroniser** (`Remove-TrackedFolder` : `rclone copy` local→Drive puis corbeille), **délai à chaud**, **minuteur**, Synchroniser, Ouvrir, MAJ, Désinstaller. `Apply-Config` factorisé. Génère l'agent via `Set-SyncAgent` (here-string `@"..."@` → `$` des variables de l'agent **backtické** ; seuls `$rcLit`/`$metaLit`/`$markLit` interpolés ; chemins échappés `''`). **⚠ UTF-8 AVEC BOM obligatoire** (PS 5.1 lit sans BOM en ANSI → accents cassés ; réajouter `printf '\xEF\xBB\xBF'`). Sécurité : `Assert-SafePath` (rejette CR/LF, `"`) sur tout chemin avant génération ; sinks `Start-Process` utilisent l'exe re-résolu, jamais un chemin de config ; `Test-UnderHome` rejoué avant toute création/suppression.
- `GUIDE.md` — guide client + checklist de déploiement Drivenlabs.
- `setup.iss` — script Inno Setup → installeur Windows pro (per-user, sans admin ; menu Démarrer, désinstalleur, lance la config au « Terminé »). Compilé sur Windows (CI ou machine Windows), pas sur Mac.
- `.github/workflows/build.yml` — CI : runner Windows compile l'installeur, signe si secrets présents, publie l'artefact (et une Release sur tag `v*`).
- `.gitignore` — ignore `Output/`, `*.exe`, `*.pfx`.

État runtime chez le client : `%USERPROFILE%\CoworkWork\_bridge\` (`config.json`, `sync-agent.ps1`, `filters.txt`, `interval`, `next-sync`, `bisync-state\` [listings rclone], `trash\<date>\` [backups], `rclone.log`, `bridge.log`). Marqueur `.coworkbridge-ok` dans chaque dossier suivi (local + Drive) pour `--check-access`.

## Build & distribution (pro)

- **Compilation** : sur Windows uniquement (`ISCC.exe setup.iss`), via la CI (runner `windows-latest`). Sortie : `Output\CoworkBridge-Setup.exe` (nom **stable**, sans version → URL latest permanente).
- **CI = build + release** (`.github/workflows/build.yml`) : à CHAQUE push sur `main`, version **par date** `YYYY.M.D.N` (N = nombre de commits du jour, auto), build de l'exe, `CHECKSUM` SHA256, puis **Release GitHub** (tag `vYYYY.M.D.N`) avec assets `CoworkBridge-Setup.exe` + `CHECKSUM` + `VERSION`. Plus de tag manuel, plus d'Azure. Versionné via `ISCC /DMyAppVersion /DMyAppVersionInfo`.
- **Mise à jour (pattern dentalsoft, appliqué à l'exe)** : l'app, au lancement (`Invoke-UpdateCheck` au début de `Start-Bridge`) **et** via le bouton « Vérifier les mises à jour », interroge `releases/latest` (repo public → API anonyme), compare la `VERSION` installée (lue dans `{app}\VERSION`, shippée par `setup.iss`) à la dernière release ; si plus récente → télécharge l'exe, **vérifie le SHA256** contre `CHECKSUM`, `Unblock-File`, le lance → Inno met à jour **en place** (AppId stable, config + données dans le profil conservées). Intégrité par **checksum**, pas par signature.
- **Signature de code : reportée** (jugée trop lourde pour l'instant). Conséquence assumée : l'exe non signé déclenche l'avertissement SmartScreen « éditeur inconnu » au 1er lancement. Voie moderne si on la veut un jour : **Azure Artifact Signing** (HSM cloud, ~9,99 $/mois, éligible UE, action `azure/trusted-signing-action@v2`, 6 secrets `AZURE_*`) — depuis juin 2023 plus de `.pfx`, signature cloud obligatoire. À rebrancher comme étape CI séparée le moment venu.
- **Moteur rclone bundlé** : la CI (étape `Bundle rclone`) télécharge `rclone-v<ver>-windows-amd64.zip` (version épinglée v1.74.3), **vérifie le SHA256 contre le `SHA256SUMS` officiel de rclone** (pas de hash en dur), extrait `rclone.exe` + la notice MIT (`rclone-LICENSE.txt`) ; `setup.iss` les embarque. Licence MIT → redistribution commerciale + bundling autorisés (seule obligation : joindre la notice). Bumper la version = changer `$ver` dans `build.yml`.
- **Icône** : `assets\app.ico` (lignes commentées dans `setup.iss`) — déposer le `.ico` Drivenlabs pour le branding, puis décommenter.

## Déploiement client (checklist interne)

Note : le repo est public, donc le `GUIDE.md` est grand public — cette checklist vit ici, pas dans le guide.

1. **Prérequis machine** : Google Drive pour ordinateur (mode **« Accéder en ligne aux fichiers »**, surtout pas « Dupliquer les fichiers »). **Seul prérequis** — le moteur rclone est bundlé dans l'installeur.
2. Donner au client l'`.exe` (Release GitHub). Non signé → avertissement SmartScreen « éditeur inconnu » au 1er lancement (et désormais aussi sur les auto-updates, `Unblock-File` retiré) — prévenir le client.
3. Installer → cocher les dossiers métier + Drive partagés pertinents → connecter `CoworkWork` dans Cowork.
4. **Valider** : ouvrir Cowork, vérifier que les fichiers sont **lisibles** (pas seulement listés — ouvrir un doc).
5. Noter l'empreinte stockage = somme des dossiers cochés.

Libellés Google Drive FR vérifiés (source officielle Google, juin 2026) : stream = « Accéder en ligne aux fichiers », miroir = « Dupliquer les fichiers », chemin « Paramètres → Préférences → Dossiers de Drive → Options de synchronisation de Mon Drive ». À reconfirmer sur la build installée chez le client (les libellés ont changé selon les versions).

Limites connues :
- Vaut pour Windows. Sur Mac le même mur existe (FileProvider) — rclone est cross-platform, mais l'installeur/PS (WinForms + agent FSW) est Windows-only (à porter si besoin).
- C'est un **contournement**, pas un correctif Anthropic. À retirer le jour où Cowork supportera nativement les dossiers cloud (issues `area:cowork` du repo `anthropics/claude-code`).
- Collision de noms de dossiers locaux : `Build-Pairs` trie de façon déterministe (stable dans tous les cas réalistes) ; un rename théorique ne survient que si deux dossiers de même type sanitizent vers le même nom (caractères illégaux) — quasi nul, non corrigé (réutiliser `LocalName` persisté fermerait le trou si besoin).

## Détails techniques vérifiés (rclone, audit 2026-06-21, sources rclone.org)

- **bisync par paire** (1 appel par dossier suivi), local↔local : `rclone bisync "<Drive>" "<Local>" --workdir <_bridge\bisync-state> --filters-file <_bridge\filters.txt> --check-access --check-filename .coworkbridge-ok --max-delete 25 --conflict-resolve none --backup-dir2 <_bridge\trash\<date>\<name>> --resilient --recover --max-lock 2m --log-file <_bridge\rclone.log> --log-level INFO`. 1er run : `+ --resync --resync-mode path1`.
- **Sûreté (vérifié doc)** : `--resync` est requis au 1er run et est une **union** (jamais de suppression côté Drive) ; `--conflict-resolve none` (défaut) garde les deux versions renommées `…conflict1/2` ; `--max-delete` en bisync = **pourcentage** (défaut 50%, on met 25) ; `--check-access` exige le marqueur des deux côtés AVANT le 1er resync (sinon il échoue) → on pose `.coworkbridge-ok` (exclu du sync via `filters.txt`) ; ne PAS utiliser `--inplace` ; codes 0=ok, ≠0 = erreur. bisync = « advanced command », jamais déclaré production-ready → ≥ v1.66 (on épingle v1.74.3).
- **Agent** : `Wait-Event -Timeout 5` (pompe la file FSW + tick périodique). `Register-ObjectEvent` SANS `-Action` (les events se mettent en file ; `-Action`+`Start-Sleep` ne déclenche pas en `-File`).
- Détection Drive : scan des racines de lecteurs + home, recherche d'un enfant `My Drive`/`Mon Drive` et `Shared drives`/`Drive partages`.

## État

Revue 1 (3 relecteurs : correction, sécurité, UX) et correctifs : 1er run en Miroir (anti-effacement Drive), suppressions corbeille + gate sur exit code, confinement réel du chemin (`GetFullPath`), `sources=@(...)` (cas mono-dossier), `LogfileFolder` revenu à la forme format-13 vérifiée, tâche planifiée `-User`, filtrage des lecteurs prêts, BOM UTF-8 + accents, wording client dé-jargonné, mise en avant « connecter CoworkWork, pas le dossier Drive ».

Revue 2 (post-packaging, CI + régression PS) et correctifs : **B1** la désélection supprimait par nom recalculé sans suffixe anti-collision → on persiste `LocalName` en config et on supprime par nom stocké ; **M1** la synchro finale de désélection était TwoWay (pouvait propager une suppression vers Drive) → remplacée par un batch **Update local→Drive** (copie seule, jamais de suppression) ciblé sur les dossiers retirés, gardé sur exit code ; CI durcie : moindre privilège (`contents: read` global, `write` au seul job release), garde anti-release-non-signée sur tag, actions épinglées par SHA, Inno pinné 6.7.1, PFX en `try/finally`, `VersionInfoVersion` numérique dédié. `setup.iss` : tous les points Inno vérifiés corrects. Note connue : l'`[UninstallRun]` fait `Stop-Process RealTimeSync` global (tue toutes les instances RTS, pas seulement la nôtre — pas de PID tracking ; acceptable car les clients ne lancent pas d'autre RTS).

**Incident client (2026-06-19)** : après redémarrage, session vierge (profil temporaire Windows) — cause probable **disque C: saturé** par la synchro dans `CoworkWork` (sous le profil). D'où la Phase A : **garde-fou disque** + doc recovery (supprimer `CoworkWork`, reboot). Bug FFS `<LogFolder>` confirmé corrigé en parallèle (install + 1ʳᵉ synchro `code 0` chez le client).

**Réécriture (rewrite control-center)** : boucle unifiée (intervalle live, `next-sync`, mono-instance), `Apply-Config` factorisé, garde disque (`Test-DiskBudget`), config par explorateur (plus de liste auto-détectée), panneau = centre de contrôle (liste suivis, ajouter, désync par dossier, délai applicable, minuteur), tâche planifiée abandonnée comme mécanisme.

**Revue sécurité (2026-06-19, sur `main`)** : risque dominant = chaîne d'auto-update (checksum ≠ authenticité, repo public). Correctifs livrés (v2026.6.19.3) : `Unblock-File` retiré (garde SmartScreen), assets par nom exact, exe re-résolu au lieu du chemin config, `Assert-SafePath` (CR/LF/`"`), `Test-UnderHome` + assainissement `LocalName` rejoués à la lecture, apostrophe XML. **Branch protection posée sur `main`** (PR obligatoire, pas de push direct admin). Restent ouverts : signature de code (différée), découplage release/push.

**Pivot rclone — Archi A (branche `feat/rclone-engine`)** : FreeFileSync → rclone bisync (voir Architecture + Détails). Motif : FFS s'installait à la main ET sa licence interdit le bundling + l'usage pro de l'édition gratuite ; rclone (MIT) est bundlable. Audit complet (sûreté bisync, licence, packaging, archi) fait le 2026-06-21.

⚠️ **Non exécuté sur Windows** (dev macOS ; structure vérifiée — accolades/parenthèses/here-strings équilibrées, BOM, `$Ffs` éliminé). **Test Windows BLOQUANT avant merge `main`** (Dylan), priorités :
1. 🔑 **placeholder Drive stream** : un fichier non hydraté est-il vu « présent » (pas « supprimé/modifié ») par bisync ? pas d'hydratation massive au scan ? (le risque non couvert par la doc rclone) ;
2. `bisync --resync` 1er run sûr (Drive fait foi, rien d'effacé côté Drive) ; `--check-access` déclenche bien l'abort si Drive non monté ;
3. agent : push quasi instantané via `Wait-Event` + FSW effectif en `-File` ? pull périodique + délai à chaud + minuteur ;
4. désync : `rclone copy` local→Drive OK puis corbeille, fichiers Drive intacts ;
5. CI : étape `Bundle rclone` (checksum SHA256SUMS) + Inno embarque `rclone.exe`.
Cible PS 5.1 (défaut Windows).
