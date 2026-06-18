# Cowork Bridge — guide

Rend tes dossiers Google Drive accessibles à Claude Cowork, sur Windows.

## Le problème que ça règle

Claude Cowork travaille dans un environnement isolé qui sait lire les vrais dossiers de ton PC, mais **pas** les dossiers cloud (Google Drive, OneDrive, Dropbox, iCloud) : ceux-là ne sont pas réellement présents sur le disque tant qu'on ne les ouvre pas. Résultat : un dossier Google Drive connecté dans Cowork **apparaît vide**. Les raccourcis ne contournent pas le problème (Cowork les rejette).

La seule solution fiable : donner à Cowork une **vraie copie locale**, remplie automatiquement depuis Drive. C'est le rôle de Cowork Bridge.

En clair : tes fichiers vivent dans le cloud Google. Google Drive les pose sur ton PC, Cowork Bridge en fait une copie dans un dossier de travail, et Claude Cowork lit cette copie.

```
Cloud Google  →  Google Drive (sur ton PC)  →  dossier de travail  →  Claude Cowork
```

## Prérequis (une fois)

1. **Google Drive pour ordinateur** installé, connecté à ton compte, et réglé sur **« Accéder en ligne aux fichiers »** (Paramètres → Préférences → Dossiers de Drive → Options de synchronisation de Mon Drive). Ce mode laisse le reste de ton Drive dans le cloud (≈ aucun espace pris sur le PC) ; seuls les dossiers que tu choisis sont réellement téléchargés.
2. **FreeFileSync** installé : https://freefilesync.org/download.php (gratuit). C'est le moteur qui copie les fichiers.

## Installation

1. Lance **CoworkBridge-Setup.exe** et suis l'assistant (tu peux cocher « Créer une icône sur le bureau »).
2. À la fin, l'écran de configuration s'ouvre. Coche les dossiers Drive (Mon Drive et/ou Drive partagés) à **rendre accessibles à Claude Cowork**. Ne coche que ce sur quoi tu travailles — c'est ce qui occupera de l'espace sur le PC.
3. Laisse le **dossier de travail** par défaut (`C:\Users\<toi>\CoworkWork`) — il doit rester dans ton dossier utilisateur.
4. Clique **Installer**. La première copie depuis Drive se lance.
5. Dans **Claude Cowork**, connecte le **dossier de travail** : `C:\Users\<toi>\CoworkWork` — **et surtout pas** ton dossier Google Drive.

C'est fini. Tes fichiers apparaissent dans Cowork.

## Au quotidien

Rien à faire, la synchronisation tourne en arrière-plan :

- **Tes modifications dans Cowork** → renvoyées vers Google Drive **en temps réel** (un petit programme nommé RealTimeSync tourne en fond, visible en bas à droite dans la zone de notification).
- **Les changements venant de Drive** (toi sur un autre appareil, un collègue sur un Drive partagé) → récupérés dans ton dossier de travail **toutes les 30 min** par défaut (réglable).
- Les suppressions passent par la **corbeille** (Windows + corbeille Drive), jamais en dur → toujours récupérables.

**Sûreté des données** : la toute première copie ne fait que **descendre** tes fichiers de Drive vers le PC — elle ne peut rien supprimer côté Drive. La synchronisation ne devient bidirectionnelle qu'ensuite. Et si tu retires un dossier, sa copie locale n'est libérée qu'**après avoir été renvoyée vers Drive avec succès**, et part à la corbeille.

Pour forcer une synchronisation immédiate : ouvre **Cowork Bridge** (icône du bureau, ou menu Démarrer → **Configurer Cowork Bridge**) → **Synchroniser maintenant**.

## Mises à jour

Cowork Bridge se met à jour tout seul : au lancement, s'il existe une version plus récente, il te propose de l'installer (tes dossiers suivis et réglages sont conservés). Tu peux aussi cliquer **« Vérifier les mises à jour »** dans la fenêtre de gestion.

## Ajouter ou retirer un dossier

Ouvre **Cowork Bridge** (icône du bureau, ou menu Démarrer → **Configurer Cowork Bridge**) :

- **Ajouter un dossier** → bouton **« Ajouter un dossier »** → coche le(s) nouveau(x) dossier(s) → **Ajouter**. Le dossier est copié depuis Drive et apparaît dans ton dossier de travail. **Rien à retoucher dans Cowork.**
- **Pas besoin pour un sous-dossier** : tout ce qui est créé **à l'intérieur** d'un dossier déjà suivi se synchronise tout seul. Tu ne reviens ici que pour un nouveau dossier de **premier niveau**.
- **Retirer un dossier** → bouton **« Modifier la sélection »** → décoche. Son contenu est d'abord **renvoyé vers Google Drive**, puis la copie locale part à la **corbeille** pour libérer de l'espace. Si le renvoi échoue, rien n'est supprimé.

## Gérer l'espace disque

Cowork Bridge **réduit** ton espace utilisé si tu étais en mode « Dupliquer les fichiers » (qui télécharge tout le Drive). En mode « Accéder en ligne aux fichiers » + sélection ciblée, le PC ne contient que les dossiers suivis.

- **Espace occupé ≈ taille des dossiers cochés.** Jamais tout le Drive.
- Le dossier de travail (`CoworkWork`) n'est qu'une **copie de travail** : tout y est aussi dans Drive (et dans le cloud).

## Dépannage

| Symptôme | Cause / solution |
|---|---|
| « Aucun dossier Google Drive détecté » | Google Drive pour ordinateur n'est pas lancé, pas connecté à ton compte, ou pas en mode « Accéder en ligne aux fichiers ». Corrige, puis rouvre Cowork Bridge. |
| « FreeFileSync n'est pas détecté » | Installe FreeFileSync (lien ci-dessus), puis rouvre Cowork Bridge. |
| Cowork affiche un dossier vide | Tu as connecté le dossier Google Drive au lieu du **dossier de travail** (`CoworkWork`). Connecte `CoworkWork`. |
| Synchro en temps réel absente | Rouvre Cowork Bridge et relance l'installation (elle reconfigure la synchronisation). |
| Un conflit de fichier | FreeFileSync garde les deux versions et le signale. Bouton **« Ouvrir le dossier local »** → sous-dossier `_bridge` pour le détail. |

Journal et configuration : bouton **« Ouvrir le dossier local »** → sous-dossier `_bridge` (pas besoin de taper un chemin).

## Désinstaller

Au choix :
- Dans **Cowork Bridge** → **« Désinstaller Cowork Bridge »**, ou
- Windows → Paramètres → Applications → Cowork Bridge → Désinstaller.

La synchronisation de fond est retirée. Ton dossier de travail est **conservé** (tes fichiers restent, et ils sont aussi dans Drive) — supprime-le à la main si tu veux récupérer l'espace.
