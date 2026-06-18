# Cowork Bridge — guide

Pont entre **Google Drive** et **Claude Cowork** sur Windows.

## Le problème qu'il règle

Le sandbox de Claude Cowork tourne dans une VM isolée et monte tes dossiers via virtiofs/Plan 9. Ces montages attendent un vrai système de fichiers NTFS — or Google Drive (comme OneDrive, Dropbox, iCloud) présente ses fichiers à travers un filesystem virtuel. Résultat : **un dossier Google Drive connecté dans Cowork apparaît vide** (la VM ne traverse pas la projection Drive). C'est une limite connue, non corrigée à ce jour, et les raccourcis/jonctions sont rejetés par Cowork (il résout le lien et applique le même blocage).

La seule solution stable : donner à Cowork un **dossier local plat**, dans ton dossier utilisateur, rempli automatiquement depuis Drive. C'est ce que fait ce bridge.

```
Cloud  <->[Google Drive]<->  Mon Drive\Projet  <->[FreeFileSync]<->  CoworkWork\Projet  ->  Cowork lit ici
```

---

## Prérequis (une fois)

1. **Google Drive pour ordinateur** installé et connecté, configuré en mode **« Stream »** (Préférences → Google Drive → *Diffuser les fichiers*). Le mode Stream garde le reste de ton Drive en placeholders (≈ 0 octet) ; seuls les dossiers pontés seront téléchargés.
2. **FreeFileSync** installé : https://freefilesync.org/download.php (gratuit). C'est le moteur de synchro.

---

## Installation

1. Double-clique **`Run-CoworkBridge.bat`**.
2. Coche les dossiers Drive (Mon Drive et/ou Drive partagés) à rendre accessibles dans Cowork. **Ne coche que ce sur quoi tu travailles** — c'est ce qui occupera de l'espace en local.
3. Laisse le dossier de travail par défaut (`C:\Users\<toi>\CoworkWork`) — il doit rester dans ton dossier utilisateur (contrainte Cowork).
4. Clique **Installer**. La première synchro se lance.
5. Dans **Claude Cowork**, connecte le dossier : **`C:\Users\<toi>\CoworkWork`**.

C'est fini. Tes fichiers Drive apparaissent maintenant dans Cowork.

---

## Au quotidien

Rien à faire, la synchro tourne en arrière-plan :

- **Tes modifications dans Cowork** → poussées vers Drive **en temps réel** (RealTimeSync, dans la zone de notification).
- **Les modifications côté Drive** (toi ailleurs, un collègue sur un Drive partagé) → ramenées en local **toutes les 30 min** par défaut (réglable).
- Les suppressions passent par la **corbeille** (Windows + corbeille Drive), jamais en dur → toujours récupérables.

**Sûreté des données** : la toute première synchro ne fait que **descendre** tes fichiers de Drive vers le local — elle ne peut rien supprimer côté Drive. Ensuite seulement la synchro devient bidirectionnelle. Et si jamais tu retires un dossier, sa copie locale n'est libérée qu'**après une dernière synchro réussie**, et part à la corbeille.

Pour forcer une synchro immédiate : relance `Run-CoworkBridge.bat` → **Synchroniser maintenant**.

---

## Gérer le stockage

Le bridge **réduit** ton stockage si tu étais en mode Miroir (qui télécharge tout le Drive). En mode Stream + sélection ciblée, le local ne contient que les dossiers pontés.

- **Ajouter / retirer des dossiers** : relance `Run-CoworkBridge.bat` → **Modifier la sélection**. Décocher un dossier lance une dernière synchro et, **si elle réussit**, envoie sa copie locale à la **corbeille** (récupérable). Si la synchro échoue, rien n'est supprimé.
- **Espace occupé ≈ taille des dossiers cochés.** Jamais tout le Drive.
- Le dossier `CoworkWork` n'est qu'un **cache de travail** : tout y est aussi dans Drive (et le cloud). Tu peux en vider un sous-dossier après une dernière synchro pour récupérer de la place.

---

## Dépannage

| Symptôme | Cause / solution |
|---|---|
| « Aucun dossier Google Drive détecté » | Google Drive pour ordinateur n'est pas lancé/connecté, ou pas en mode Stream. Lance-le, vérifie qu'il est connecté, relance le `.bat`. |
| « FreeFileSync n'est pas détecté » | Installe FreeFileSync (lien ci-dessus) puis relance le `.bat`. |
| Cowork voit toujours un dossier vide | Vérifie que tu as connecté `CoworkWork` (et **pas** le dossier Drive) dans Cowork. |
| Synchro temps réel absente | RealTimeSync n'était pas trouvé à l'install. Lance-le à la main : `RealTimeSync.exe "C:\Users\<toi>\CoworkWork\_bridge\bridge.ffs_real"`, ou re-lance l'install. |
| Un conflit de fichier | FreeFileSync garde les deux versions et le signale. Ouvre `CoworkWork\_bridge\` (journaux) pour voir le détail. |

Journal et configs : `C:\Users\<toi>\CoworkWork\_bridge\` (`bridge.log`, `bridge.ffs_batch`, `bridge.ffs_real`, `config.json`).

---

## Désinstaller

`Run-CoworkBridge.bat` → **Désinstaller le bridge**. Une dernière synchro est lancée, la synchro de fond est retirée (tâche planifiée + démarrage). Le dossier local est conservé — supprime-le à la main si tu veux récupérer l'espace.

---

## Déploiement Drivenlabs (checklist interne)

Pour standardiser chez un client :

1. **Pré-requis machine** : Google Drive pour ordinateur (mode **Stream**, surtout pas Miroir) + FreeFileSync. Les pré-installer évite la friction à l'install.
2. Copier le dossier `cowork-bridge\` chez le client (ou le packager en .zip).
3. Lancer `Run-CoworkBridge.bat`, sélectionner les dossiers métier + Drive partagés pertinents.
4. **Valider** : ouvrir Cowork, connecter `CoworkWork`, vérifier que les fichiers sont lisibles (pas seulement listés — ouvrir un doc).
5. Noter l'empreinte stockage = somme des dossiers cochés.

Limites connues à communiquer :
- Vaut pour Windows. Sur Mac le même mur existe (FileProvider) — adapter le moteur (rsync/FreeFileSync, qui est cross-platform).
- C'est un **contournement**, pas un correctif Anthropic. À retirer le jour où Cowork supportera nativement les dossiers cloud (suivre les issues `area:cowork` du repo `anthropics/claude-code`).
- v1 testée en conditions réelles à valider sur une machine Windows avant déploiement large.
