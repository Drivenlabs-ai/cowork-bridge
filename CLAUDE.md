# cowork-bridge

Outil Drivenlabs : pont **Google Drive → dossier local plat → Claude Cowork** sur Windows. Déployable chez les clients.

## Problème résolu

Le sandbox de Claude Cowork (VM Hyper-V, montage hôte→VM en **virtiofs / Plan 9**) attend du NTFS standard. Google Drive (et OneDrive/Dropbox/iCloud) expose ses fichiers via un filesystem virtuel / Cloud Files API → le montage échoue (`EINVAL`) ou la VM ne traverse pas la projection → **dossier vu vide dans Cowork**. Limite connue, non corrigée par Anthropic (issues `area:cowork` du repo `anthropics/claude-code`, ex. #25293, #29583, #33590). Contraintes Cowork aggravantes : dossier de travail **obligatoirement dans le home** (`C:\Users\<user>\`), et **raccourcis/jonctions rejetés** (résolus via `realpath()` puis re-bloqués).

Conséquence : seule issue stable = donner à Cowork un vrai dossier local plat dans le home, alimenté automatiquement depuis Drive.

## Architecture (décision verrouillée : moteur A)

```
cloud <->[Google Drive Desktop, mode STREAM]<-> Mon Drive\X <->[FreeFileSync]<-> %USERPROFILE%\CoworkWork\X -> Cowork
```

- **Mode Stream, pas Miroir** : tout le Drive reste en placeholders (≈0 octet) ; seuls les dossiers pontés sont hydratés. Le bridge ne fait donc pas exploser le stockage, il le réduit vs Miroir.
- **FreeFileSync** comme moteur : two-way + gestion de conflits + cross-platform (un seul outil pour un parc Win/Mac). Suppressions → corbeille.
- **Ciblage** : l'UI laisse cocher dossiers de *Mon Drive* + *Drive partagés*. Stockage local ≈ Σ(dossiers cochés).
- Synchro de fond : **RealTimeSync** (démarrage, push temps réel des modifs locales) + **tâche planifiée** (pull périodique du Drive, 30 min par défaut — les notifs de changement côté Drive virtuel ne sont pas fiables, d'où le polling).
- **Sûreté des données** (post-revue) : la 1ʳᵉ synchro d'une nouvelle install est en **Miroir Drive → local** (`Variant=Mirror`, ne touche jamais le côté Drive) ; la synchro courante seulement est `TwoWay`. Suppressions = `DeletionPolicy=RecycleBin`. La libération d'une copie locale (déselect) passe par la **corbeille** (`Microsoft.VisualBasic.FileIO`) et **uniquement si la dernière synchro a réussi** (exit ≤ 1). Garde anti-collision sur les noms de dossiers locaux.

Alternative évaluée et reportée en v2 : **rclone direct** (API Drive, sans Drive Desktop) → stockage ×1 exact, shared drives natifs, mais nécessite une app Google OAuth Drivenlabs (setup + vérification Google). Voir la conversation d'origine.

## Fichiers

- `Run-CoworkBridge.bat` — lanceur (PowerShell `-STA -ExecutionPolicy Bypass`).
- `Install-CoworkBridge.ps1` — installeur WinForms (PS 5.1, pas de ternaire/PS7). Détecte le montage Drive, sélection des dossiers, génère les configs FFS, installe l'autostart + tâche, première synchro. Mode gestion si install existante (synchro, modifier sélection, désinstaller). **⚠ Doit rester encodé UTF-8 AVEC BOM** : PS 5.1 lit un `.ps1` sans BOM en codepage ANSI et casse tous les accents des chaînes UI. Après toute réédition avec un outil qui retire le BOM, le réajouter (`printf '\xEF\xBB\xBF'` en tête). Identifiants de code en anglais, chaînes UI en français accentué.
- `GUIDE.md` — guide client + checklist de déploiement Drivenlabs.
- `setup.iss` — script Inno Setup → installeur Windows pro (per-user, sans admin ; menu Démarrer, désinstalleur, lance la config au « Terminé »). Compilé sur Windows (CI ou machine Windows), pas sur Mac.
- `.github/workflows/build.yml` — CI : runner Windows compile l'installeur, signe si secrets présents, publie l'artefact (et une Release sur tag `v*`).
- `.gitignore` — ignore `Output/`, `*.exe`, `*.pfx`.

État runtime chez le client : `%USERPROFILE%\CoworkWork\_bridge\` (`config.json`, `bridge.ffs_batch`, `bridge.ffs_real`, `bridge.log`).

## Build & distribution (pro)

- **Compilation** : sur Windows uniquement (`ISCC.exe setup.iss`). Le Mac ne compile pas d'`.exe` ; on passe par la CI (runner `windows-latest`) ou une machine Windows. Sortie : `Output\CoworkBridge-Setup-<version>.exe`.
- **CI** : push `main`/dispatch → artefact ; tag `v*` → Release GitHub avec l'exe. Versionné via `ISCC /DMyAppVersion=<tag>` (le `#ifndef` dans `setup.iss` laisse la CI primer).
- **Signature de code** : via **Azure Artifact Signing** (ex-Trusted Signing), action CI `azure/trusted-signing-action@v2` (SHA-épinglée), conditionnée à la présence des secrets `AZURE_*` (sinon build non signé, et un tag de release échoue volontairement). Depuis juin 2023 la clé doit être en HSM (plus de `.pfx` téléchargeable) → signature cloud obligatoire. Azure Artifact Signing : ~9,99 $/mois, éligible entreprises UE (Drivenlabs SAS OK), pas de token USB, réputation SmartScreen qui se construit avec les téléchargements (pas instantané). Alternatives plus chères : SSL.com eSigner, DigiCert KeyLocker.
  - **6 secrets GitHub à définir** (par Alex, dans Settings → Secrets, jamais via fichier) : `AZURE_TENANT_ID`, `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET`, `AZURE_ENDPOINT` (ex. `https://weu.codesigning.azure.net/`), `AZURE_CODE_SIGNING_NAME` (nom du compte), `AZURE_CERT_PROFILE_NAME`.
  - **Setup Azure (côté Alex)** : souscription pay-as-you-go → compte Artifact Signing (noter l'endpoint régional) → validation d'identité Drivenlabs SAS (docs business, quelques jours) → profil de certificat → App Registration + rôles (Identity Verifier sur l'utilisateur, Certificate Profile Signer sur l'app). Puis poser les 6 secrets → `git tag vX.Y.Z` → release signée.
- **Licence FreeFileSync** : ⚠ NON redistribué dans l'installeur (donationware propriétaire, droits de redistribution à vérifier). v1 = détection + guidage par le script. Décision à prendre après vérif licence : bundler le portable, ou télécharger l'installeur officiel FFS à l'install (`/VERYSILENT`), ou rester en prérequis guidé.
- **Icône** : `assets\app.ico` (lignes commentées dans `setup.iss`) — déposer le `.ico` Drivenlabs pour le branding, puis décommenter.

## Déploiement client (checklist interne)

Note : le repo est public, donc le `GUIDE.md` est grand public — cette checklist vit ici, pas dans le guide.

1. **Prérequis machine** : Google Drive pour ordinateur (mode **« Accéder en ligne aux fichiers »**, surtout pas « Dupliquer les fichiers ») + FreeFileSync. Les pré-installer évite la friction.
2. Donner au client l'`.exe` signé (Release GitHub une fois le cert posé ; d'ici là, l'artefact de build).
3. Installer → cocher les dossiers métier + Drive partagés pertinents → connecter `CoworkWork` dans Cowork.
4. **Valider** : ouvrir Cowork, vérifier que les fichiers sont **lisibles** (pas seulement listés — ouvrir un doc).
5. Noter l'empreinte stockage = somme des dossiers cochés.

Libellés Google Drive FR vérifiés (source officielle Google, juin 2026) : stream = « Accéder en ligne aux fichiers », miroir = « Dupliquer les fichiers », chemin « Paramètres → Préférences → Dossiers de Drive → Options de synchronisation de Mon Drive ». À reconfirmer sur la build installée chez le client (les libellés ont changé selon les versions).

Limites connues :
- Vaut pour Windows. Sur Mac le même mur existe (FileProvider) — le moteur FreeFileSync est cross-platform, mais l'installeur/PS est Windows-only (à porter si besoin).
- C'est un **contournement**, pas un correctif Anthropic. À retirer le jour où Cowork supportera nativement les dossiers cloud (issues `area:cowork` du repo `anthropics/claude-code`).
- Collision de noms de dossiers locaux : `Build-Pairs` trie de façon déterministe (stable dans tous les cas réalistes) ; un rename théorique ne survient que si deux dossiers de même type sanitizent vers le même nom (caractères illégaux) — quasi nul, non corrigé (réutiliser `LocalName` persisté fermerait le trou si besoin).

## Détails techniques vérifiés

- `.ffs_batch` : `XmlType="BATCH" XmlFormat="13"` (FFS convertit les anciens formats vers l'avant). `Synchronize/Variant` = `TwoWay` (courant) ou `Mirror` (1er run), `DeletionPolicy=RecycleBin`, `Batch/ProgressDialog Minimized+AutoClose`, `Errors Ignore="true"` (c'est CE flag qui rend la synchro non bloquante en tâche planifiée ; `ErrorDialog` reste à la valeur vérifiée `Show` pour ne pas risquer un enum invalide qui ferait rejeter tout le batch). `LogfileFolder MaxCount="0"` self-closing = forme **exacte** d'un vrai fichier format-13 (NE PAS mettre `Limit`, qui est le format 17). Lancement : `FreeFileSync.exe "x.ffs_batch"` (codes 0=ok / 1=warn / 2=err / 3=annulé).
- `.ffs_real` : `XmlType="REAL" XmlFormat="2"`, `Directories/Item`, `Delay`, `Commandline`. Lancé par `RealTimeSync.exe "x.ffs_real"`.
- Détection Drive : scan des racines de lecteurs + home, recherche d'un enfant `My Drive`/`Mon Drive` et `Shared drives`/`Drive partages`.

## État

Revue 1 (3 relecteurs : correction, sécurité, UX) et correctifs : 1er run en Miroir (anti-effacement Drive), suppressions corbeille + gate sur exit code, confinement réel du chemin (`GetFullPath`), `sources=@(...)` (cas mono-dossier), `LogfileFolder` revenu à la forme format-13 vérifiée, tâche planifiée `-User`, filtrage des lecteurs prêts, BOM UTF-8 + accents, wording client dé-jargonné, mise en avant « connecter CoworkWork, pas le dossier Drive ».

Revue 2 (post-packaging, CI + régression PS) et correctifs : **B1** la désélection supprimait par nom recalculé sans suffixe anti-collision → on persiste `LocalName` en config et on supprime par nom stocké ; **M1** la synchro finale de désélection était TwoWay (pouvait propager une suppression vers Drive) → remplacée par un batch **Update local→Drive** (copie seule, jamais de suppression) ciblé sur les dossiers retirés, gardé sur exit code ; CI durcie : moindre privilège (`contents: read` global, `write` au seul job release), garde anti-release-non-signée sur tag, actions épinglées par SHA, Inno pinné 6.7.1, PFX en `try/finally`, `VersionInfoVersion` numérique dédié. `setup.iss` : tous les points Inno vérifiés corrects. Note connue : l'`[UninstallRun]` fait `Stop-Process RealTimeSync` global (tue toutes les instances RTS, pas seulement la nôtre — pas de PID tracking ; acceptable car les clients ne lancent pas d'autre RTS).

⚠️ **v1 toujours non exécutée sur Windows** (développée sur macOS, pas de `pwsh` pour parser). À valider sur une vraie machine (Dylan) avant déploiement large, points à confirmer en priorité :
1. le `.ffs_batch` généré est accepté par le FreeFileSync installé (format 17) — sinon, basculer sur la reco structurelle : templater un `.ffs_batch` sauvegardé depuis le FFS réel plutôt que hand-author ;
2. enregistrement de la tâche planifiée + raccourci Démarrage ;
3. détection du montage Drive (noms `My Drive`/`Shared drives` localisés) ;
4. concurrence RealTimeSync ↔ tâche planifiée sur les mêmes paires (Delay RTS porté à 30 s, `MultipleInstances IgnoreNew` sur la tâche — à surveiller sur dossiers partagés).
Cible PS 5.1 (défaut Windows).
