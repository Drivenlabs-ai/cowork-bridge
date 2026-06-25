# Cowork Bridge

**Make your Google Drive (and other cloud) folders readable by Claude Cowork on Windows.**

You point Claude Cowork at a Google Drive folder and it shows up **empty** — or the files are listed but **won't open**. Cowork Bridge fixes that: it keeps a real, always-current local copy of the Drive folders you choose, in a place Cowork can actually read, and syncs changes both ways in the background.

> Windows only · Free · Open-source · A workaround for a current Cowork limitation, **not** an official Anthropic fix.

---

## The problem

Claude Cowork runs its file tools inside an isolated virtual machine. That sandbox can only read **real files inside your Windows user folder** (`C:\Users\<you>\`).

Google Drive for desktop, in its default **Stream files** mode, doesn't keep real files on your disk. It shows *placeholders* and downloads the content on demand through a virtual filesystem. Cowork's sandbox can't see through that virtual filesystem, so one of two things happens:

- the Drive folder you connect looks **empty** inside Cowork, or
- the files are **listed but fail to open** — they're placeholders, not real bytes.

This isn't a misconfiguration on your end. It's a known limitation of how Cowork mounts folders (see the related Cowork issues on [`anthropics/claude-code`](https://github.com/anthropics/claude-code/issues?q=is%3Aissue+cowork+drive)). The same wall exists for OneDrive, Dropbox and iCloud, and shortcuts/symlinks don't get around it — Cowork rejects them.

The only stable fix today is to give Cowork a genuine local folder that stays in sync with Drive. That's what this tool does.

## What it does

```
   Google Drive (cloud)
        ⇅   Google Drive for desktop  (Stream files mode)
   G:\…\Your Folder                          ← lives in Drive's virtual filesystem; Cowork can't read it
        ⇅   Cowork Bridge  (two-way sync, runs in the background)
   C:\Users\<you>\CoworkWork\Your Folder     ← real local files; THIS is what you connect in Cowork
        →   Claude Cowork reads & writes here
```

You choose which Drive folders to bridge. For each one, the tool keeps a real copy under `C:\Users\<you>\CoworkWork` and syncs both sides automatically: your edits go back to Drive within seconds, and changes made elsewhere in Drive are pulled in on a schedule. In Cowork you connect the `CoworkWork` folder instead of the Drive folder.

Only the folders you pick are made local, so your disk holds just what you actually bridge — the rest of your Drive stays in the cloud.

## Quickstart

> The app's setup screens are currently in **French**. Each button below is given as it appears on screen, with the English meaning in parentheses. Labels can also vary slightly between versions.

### 1. Prerequisite — Google Drive for desktop in *Stream files* mode

Install [Google Drive for desktop](https://www.google.com/drive/download/) and sign in. Then open its settings (tray icon → gear → **Preferences**) and, under your Google Drive folder, choose **Stream files** (not *Mirror files*). This keeps the rest of your Drive in the cloud — only the folders you bridge get downloaded.

This is the only prerequisite. The sync engine is bundled inside the installer; there is nothing else to install.

### 2. Download

**[⬇ Download CoworkBridge-Setup.exe](https://github.com/Drivenlabs-ai/cowork-bridge/releases/latest/download/CoworkBridge-Setup.exe)** (latest release)

### 3. Install

Double-click the file. Because the installer isn't code-signed yet, Windows SmartScreen shows *"Windows protected your PC"* — click **More info → Run anyway**. The installer is per-user and needs no administrator rights. When it finishes, the setup window opens automatically.

### 4. Choose your folders

In the setup window, click **« Ajouter un dossier »** (*Add a folder*), browse to a Google Drive folder, and open it. Repeat for each folder you want available in Cowork. Add only what you actually work on — that's what takes up space on your PC. The tool **refuses** a folder that wouldn't fit on your disk with margin (a full system drive can stop Windows from loading your session, so this guard is deliberate).

Leave the **working folder** at its default, `C:\Users\<you>\CoworkWork` (it must stay inside your user folder). Click **« Installer »** (*Install*). The first copy from Drive starts.

### 5. Connect it in Cowork

In Claude Cowork, connect the **working folder** — `C:\Users\<you>\CoworkWork` — and **not** your Google Drive folder. Open a file to confirm Cowork can read it, not just list it.

That's it. From now on the sync runs on its own.

## How it works

- **Engine:** [rclone](https://rclone.org) (bundled, MIT-licensed), running `bisync` between two local paths — the folder Google Drive mounts on your PC and your working folder. No OAuth, no cloud account, no remote: it only ever touches local paths.
- **Background sync:** a small resident agent watches your working folder and pushes your edits to Drive within seconds, and pulls changes from Drive on a schedule (every few minutes, configurable).
- **Bundled, single installer:** rclone ships inside `CoworkBridge-Setup.exe`; you don't install or configure anything separately.

## Your files stay safe

The two-way sync is built to never lose data:

- The first sync of a folder treats **Drive as the source of truth** and merges — it never deletes anything on the Drive side.
- If the same file changed on both sides, **both versions are kept** (nothing is silently overwritten).
- Deletions are mirrored, but a **dated local backup** of anything removed is kept (an undo bin), and Drive keeps its own trash.
- A safety check **aborts the sync** if one side suddenly looks empty (e.g. Drive isn't mounted), instead of propagating a wipe.

## Keeping it updated

Once installed, Cowork Bridge updates itself. On launch — and from the **« Vérifier les mises à jour »** (*Check for updates*) button — it checks for a newer release, verifies its checksum, and updates in place, keeping your folders and settings. You never reinstall by hand.

## Managing your folders

Run Cowork Bridge again after setup and you get the control panel, where you can:

- **« Ajouter un dossier »** (*Add a folder*) or **« Désynchroniser le dossier sélectionné »** (*Unsync the selected folder*) — unsyncing first copies the folder back up to Drive, then frees the local copy (nothing is deleted from Drive).
- change how often changes are pulled from Drive,
- **« Synchroniser maintenant »** (*Sync now*), open the local folder, check for updates, or uninstall.

## Limitations & honesty

- **Windows only.** The same wall exists on macOS, but this installer (and the background agent) is Windows-only for now. rclone itself is cross-platform, so a Mac port is possible.
- **It's a workaround, not a fix.** It exists because Cowork can't currently read cloud folders directly. The day Cowork supports them natively, you won't need this anymore.
- **The installer isn't code-signed yet**, so you'll see the SmartScreen "unknown publisher" warning on install and on auto-updates.
- **The app interface is in French** today. The steps above map every button to its English meaning; a localized interface is on the list.

## Why this exists

This is a focused workaround for a real, widely-hit wall: knowledge workers keep their files in Google Drive, and Cowork — the place that's supposed to work *on* those files — can't see them. Rather than ask everyone to copy files around by hand, this tool automates the bridge and keeps it in sync. If it saves you the afternoon it would otherwise cost, it did its job.

## Built with

[rclone](https://rclone.org) (MIT License) for the sync engine, [Inno Setup](https://jrsoftware.org/isinfo.php) for the installer, and Windows PowerShell + WinForms for the app.

## License

Cowork Bridge bundles **rclone**, distributed under the [MIT License](https://github.com/rclone/rclone/blob/master/COPYING) (its notice ships with the installer). The license for Cowork Bridge's own code is being finalized — see this repository.
