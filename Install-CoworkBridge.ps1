<#
    Cowork Bridge - Installateur / centre de contrôle
    --------------------------------------------------
    Pont entre Google Drive (mode « Accéder en ligne aux fichiers ») et un dossier
    local plat lisible par Claude Cowork. Le sandbox de Cowork ne traverse pas le
    filesystem virtuel de Drive ; on lui donne donc de vrais octets dans
    %USERPROFILE%\CoworkWork (dans le home, contrainte Cowork).

    Moteur : rclone (bundlé, MIT) en mode bisync local <-> local, entre le dossier
    monté par Google Drive pour ordinateur et le dossier de travail. Aucun OAuth,
    aucun remote : ce sont deux chemins locaux.

    Synchro :
      - Agent résident (démarrage, _bridge\sync-agent.ps1) :
          * FileSystemWatcher sur les dossiers locaux -> push quasi instantané ;
          * timer toutes les N min -> pull régulier ;
          * mono-instance (boucle mono-thread), relit config + intervalle à chaud,
            écrit _bridge\next-sync pour le minuteur.
      - Resync (1er run d'une paire, récupération après abort critique, filtres
        modifiés) = rclone bisync --resync --resync-mode newer : union (jamais
        d'effacement Drive), la version la plus récente gagne — au 1er run le local
        est vide, donc Drive fait foi de fait.
      - Sûreté : --check-access (marqueur .coworkbridge-ok des deux côtés),
        --conflict-resolve none (garde les 2 versions),
        --backup-dir local daté (équivalent corbeille) + corbeille Drive native,
        --resilient --recover --max-lock 2m, rotation du journal rclone.log.
      - Observabilité : statut par paire dans _bridge\status\<nom>.json (agent +
        panneau) ; le panneau affiche l'état réel de la dernière synchro.

    Sécurité disque : avant d'ajouter un dossier, on vérifie qu'il tient sur C:
    avec une marge (sinon remplir le profil empêche Windows de l'ouvrir).

    Lancer via Run-CoworkBridge.bat (-STA -ExecutionPolicy Bypass). UTF-8 AVEC BOM.
#>

#requires -version 5.1
# -LibraryOnly : charge les fonctions sans ouvrir l'interface ni lancer la configuration.
# Seul le banc de test s'en sert (tests\Run-Tests.ps1) : il appelle les fonctions de synchro
# directement, sur deux dossiers locaux qui tiennent lieu de Drive et de dossier de travail.
param([switch]$LibraryOnly)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ----------------------------------------------------------------------------
# Constantes & etat
# ----------------------------------------------------------------------------
$script:AppName     = 'Cowork Bridge'
$script:HomeRoot    = $env:USERPROFILE
$script:DefaultDest = Join-Path $script:HomeRoot 'CoworkWork'
$script:MetaDirName = '_bridge'
$script:OldTaskName = 'CoworkBridge-Sync'        # ancien mécanisme : nettoyé seulement
$script:WatchdogTaskName = 'CoworkBridge-Watchdog'   # tâche per-user : relance l'agent (logon + horaire)
$script:MarkerName  = '.coworkbridge-ok'         # marqueur --check-access (anti côté vide)
$script:DefaultInterval = 30
$script:DiskMarginBytes = [long]5 * 1GB          # laisser au moins ça de libre sur C:
$script:LogFile     = $null
$script:Repo        = 'Drivenlabs-ai/cowork-bridge'

# Drapeaux rclone statiques : SOURCE UNIQUE, partagée mot pour mot entre l'installeur et
# l'agent résident (sérialisée dans sync-agent.ps1 à la génération). Tokens littéraux
# uniquement, aucune valeur par-run. Modifier ici = les deux suivent.
# --local-no-preallocate : la préallocation Windows de rclone arrondit la taille au secteur ; la
# projection Google Drive Desktop rapporte alors la taille préallouée (octets NULL en fin) -> abort
# « corrupted on transfer: sizes differ » (rclone #3207, flag officiel v1.55). --checkers 1 :
# énumération sérialisée pour ménager le pool noyau de la projection Cloud Files (ERROR 1450) ;
# --transfers reste à 4 (le débit de copie ne joue pas sur l'énumération).
$script:RcloneCommonFlags = @('--checkers', '1', '--transfers', '4', '--local-no-preallocate', '--retries-sleep', '30s')
# Descente seulement. --local-no-check-updated : un placeholder qui s'hydrate pendant la lecture
# change de stat apparent -> « can't copy - source file is being updated », non retryable. À la
# MONTÉE on ne le met pas : là, un fichier en cours d'écriture doit faire échouer sa copie plutôt
# que partir tronqué sur le Drive (même raison qu'à la désync, cf. Remove-TrackedFolder).
$script:RcloneDownFlags   = @('--local-no-check-updated')
# Rotation intégrée rclone (v1.71+) : borne rclone.log (journal uniquement — aucune limite
# sur les fichiers synchronisés). Sans elle, croissance infinie dans le profil (risque C: plein).
$script:RcloneLogFlags    = @('--log-level', 'INFO', '--log-file-max-size', '5M', '--log-file-max-backups', '2')

# Code de sortie SYNTHÉTIQUE « côté Drive non monté » : hors de la plage rclone (0-10, dont 9 =
# --error-on-no-transfer) pour éviter toute collision. N'est PAS un échec (ni succès) : neutre.
$script:CodeDriveMissing = 90
# Garde-fou de suppression : le seul sens où une perte serait irréversible est local -> Drive.
# Au-delà de ces deux seuils réunis, aucune suppression n'est propagée et la passe se contente
# d'aligner le local sur le Drive. Couvre le dossier local vidé (profil abîmé, mauvaise
# manipulation) sans gêner un retrait ordinaire de quelques fichiers.
$script:CodeDeleteGuard   = 91
$script:DeleteGuardMin    = 10     # en deçà de tant de fichiers, jamais de blocage
$script:DeleteGuardRatio  = 0.5    # et il faut aussi dépasser cette part de l'index
# Au-delà de tant d'échecs consécutifs, la paire n'est plus tentée que sur tick d'intervalle
# (pas sur événement du watcher) : une paire en erreur ne doit pas rescanner la projection en boucle.
$script:FailThrottle      = 3

# Filtres de synchro, en DEUX groupes source-unique :
#  - Volatile = éphémère qui casse la sync (verrous, temp, états FFS) : exclu partout, sync ET désync.
#  - Dir = artefacts dev (.git, node_modules...) : exclu de la SYNC seulement. À la désync on les REND
#    au Drive (ils n'existent que localement) avant de recycler le local, sinon on les perdrait.
$script:VolatileFilterLines = @(
    '- .coworkbridge-ok'   # marqueur de montage : posé des deux côtés, jamais synchronisé
    '- *.tmp'
    '- desktop.ini'
    '- thumbs.db'
    '- ~$*'
    '- .~lock.*'
    '- *.laccdb'
    '- .tmp.drivedownload/'
    '- .tmp.driveupload/'
    '- *.ffs_db*'
    '- *.ffs_lock'
    '- *.ffs_batch'
    '- *.ffs_real'
    '- *.ffs_tmp'
)
$script:DirFilterLines = @(
    '- __pycache__/'
    '- .git/'
    '- node_modules/'
    '- .venv/'
    '- venv/'
)

if (-not $LibraryOnly) {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    Add-Type -AssemblyName Microsoft.VisualBasic
    [System.Windows.Forms.Application]::EnableVisualStyles()
}

# ----------------------------------------------------------------------------
# Log + utilitaires
# ----------------------------------------------------------------------------
function Get-MetaDir([string]$dest) { Join-Path $dest $script:MetaDirName }

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = ('{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message)
    try {
        if ($script:LogFile) {
            $dir = Split-Path $script:LogFile -Parent
            if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            Add-Content -Path $script:LogFile -Value $line -Encoding UTF8
        }
    } catch {}
}

function Get-SyncResultText([int]$code) {
    switch ($code) {
        0       { 'Sync complete. Everything is up to date.' }
        90      { 'The Google Drive folder is not reachable. Check that Google Drive for desktop is running and signed in, then try again.' }
        91      { 'Many files had disappeared from the local folder at once. Nothing was deleted on Drive, and the local folder was restored from it. If you did mean to remove them, delete them on Drive.' }
        default { 'The sync ran into a problem. Try "Sync now" again. If it persists, open the local folder -> _bridge\rclone.log, or contact your Drivenlabs contact.' }
    }
}

# Agrège les codes d'une passe multi-paires par SÉVÉRITÉ, pas par valeur : les deux codes
# synthétiques valent 90 et 91, donc un tri numérique ferait passer « Drive non monté » devant
# une vraie erreur rclone. Ordre retenu : erreur rclone > garde-fou de suppression > Drive
# absent > succès.
function Merge-SyncCodes([int[]]$Codes) {
    $realErr = 0
    $missing = $false
    $guarded = $false
    foreach ($c in $Codes) {
        if ($c -eq 0) { continue }
        elseif ($c -eq $script:CodeDriveMissing) { $missing = $true }
        elseif ($c -eq $script:CodeDeleteGuard) { $guarded = $true }
        elseif ($c -gt $realErr) { $realErr = $c }
    }
    if ($realErr -ne 0) { return $realErr }
    if ($guarded) { return $script:CodeDeleteGuard }
    if ($missing) { return $script:CodeDriveMissing }
    return 0
}

function Remove-ToRecycleBin([string]$Path) {
    [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory(
        $Path,
        [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
        [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin)
}

# Confinement : un chemin (rechargé depuis config) doit rester sous le home.
function Test-UnderHome([string]$Path) {
    try {
        # NB : ne pas nommer la variable $home -> c'est la variable automatique PowerShell
        # ($HOME), et la collision faisait renvoyer False à tort (vérifié sur Windows).
        $full     = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
        $homeFull = [System.IO.Path]::GetFullPath($script:HomeRoot).TrimEnd('\')
        return $full.Equals($homeFull, [System.StringComparison]::OrdinalIgnoreCase) -or
               $full.StartsWith($homeFull + '\', [System.StringComparison]::OrdinalIgnoreCase)
    } catch { return $false }
}

# Rejette un chemin contenant un caractère interdit (CR/LF, guillemet) -> bloque
# toute injection dans les configs/scripts/commandes générés.
function Assert-SafePath([string]$Path) {
    if ($null -eq $Path) { return }
    if ($Path -match '[\r\n"]') { throw "Invalid path (forbidden character): $Path" }
}

# ----------------------------------------------------------------------------
# Espace disque (garde-fou : ne jamais remplir le profil -> session bloquée)
# ----------------------------------------------------------------------------
function Get-FolderSizeBytes([string]$Path) {
    try {
        $m = Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue |
             Measure-Object -Property Length -Sum
        if ($m -and $m.Sum) { return [long]$m.Sum }
    } catch {}
    return [long]0
}

function Get-FreeBytes([string]$Path) {
    try {
        $root = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($Path))
        return (New-Object System.IO.DriveInfo($root)).AvailableFreeSpace
    } catch { return [long]-1 }   # -1 = inconnu (distinct d'un vrai disque plein à 0)
}

function Format-Size([long]$b) {
    if ($b -ge 1GB) { return ('{0:N1} GB' -f ($b / 1GB)) }
    if ($b -ge 1MB) { return ('{0:N0} MB' -f ($b / 1MB)) }
    return ('{0:N0} KB' -f ($b / 1KB))
}

function Test-DiskBudget([long]$NeededBytes, [string]$Dest) {
    $free = Get-FreeBytes $Dest
    $ok = if ($free -lt 0) { $true } else { (($NeededBytes + $script:DiskMarginBytes) -le $free) }
    [pscustomobject]@{ Ok = $ok; Free = $free; Needed = $NeededBytes; Margin = $script:DiskMarginBytes }
}

# ----------------------------------------------------------------------------
# Mise a jour (releases publiques + checksum, fail-closed)
# ----------------------------------------------------------------------------
function Get-InstalledVersion {
    $f = Join-Path $PSScriptRoot 'VERSION'
    if (Test-Path $f) {
        try {
            $t = (Get-Content $f -Raw)
            if ($t) { $t = $t.Trim() }
            if ($t) { return [version]$t }
        } catch {}
    }
    return $null
}

function Get-LatestRelease {
    try {
        $h = @{ 'User-Agent' = 'CoworkBridge'; 'Accept' = 'application/vnd.github+json' }
        $r = Invoke-RestMethod -Uri "https://api.github.com/repos/$script:Repo/releases/latest" -Headers $h -TimeoutSec 6
        $tag = "$($r.tag_name)" -replace '^v', ''
        $ver = $null; try { $ver = [version]$tag } catch {}
        $exe = $r.assets | Where-Object { $_.name -eq 'CoworkBridge-Setup.exe' } | Select-Object -First 1
        $sum = $r.assets | Where-Object { $_.name -eq 'CHECKSUM' } | Select-Object -First 1
        if (-not $ver -or -not $exe) { return $null }
        return [pscustomobject]@{ Version = $ver; Tag = $tag; ExeUrl = $exe.browser_download_url; SumUrl = $sum.browser_download_url }
    } catch { return $null }
}

function Invoke-UpdateCheck {
    param([switch]$Interactive)
    $installed = Get-InstalledVersion
    if (-not $installed) {
        if ($Interactive) { Show-Info("Installed version unknown (this copy was not placed by the installer). Get the latest version from the releases page.") }
        return $false
    }
    $latest = Get-LatestRelease
    if (-not $latest) {
        if ($Interactive) { Show-Warn("Could not check for updates (no connection, or no version published).") }
        return $false
    }
    if ($latest.Version -le $installed) {
        if ($Interactive) { Show-Info("Cowork Bridge is up to date (version $installed).") }
        return $false
    }
    $m = "An update is available." + [Environment]::NewLine +
         "Installed: $installed   ->   Available: $($latest.Version)" + [Environment]::NewLine + [Environment]::NewLine +
         "Install it now? Your synced folders and settings are kept."
    if (-not (Confirm-YesNo $m)) { return $false }
    try {
        if (-not $latest.SumUrl) {
            Show-Warn("Update cancelled: no checksum published to verify the download (security).")
            return $false
        }
        $tmp = Join-Path $env:TEMP "CoworkBridge-Setup-$($latest.Tag).exe"
        Invoke-WebRequest -Uri $latest.ExeUrl -OutFile $tmp -UseBasicParsing -TimeoutSec 300
        $sumTxt   = (Invoke-WebRequest -Uri $latest.SumUrl -UseBasicParsing -TimeoutSec 60).Content
        $expected = (($sumTxt -split '\s+') | Where-Object { $_ } | Select-Object -First 1)
        if ($expected) { $expected = $expected.ToLower() }
        $actual   = (Get-FileHash $tmp -Algorithm SHA256).Hash.ToLower()
        if (-not $expected -or $expected -ne $actual) {
            Show-Warn("Update cancelled: the download does not match the expected checksum (security).")
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
            return $false
        }
        # On NE retire PAS le mark-of-the-web : tant que l'exe n'est pas signé, on laisse
        # SmartScreen évaluer le binaire téléchargé (dernier filet côté utilisateur).
        Start-Process -FilePath $tmp
        return $true
    } catch {
        Show-Warn("The update failed: $($_.Exception.Message)")
        return $false
    }
}

# ----------------------------------------------------------------------------
# Detection du montage Google Drive (point de depart du Parcourir + garde "pas de Drive")
# ----------------------------------------------------------------------------
function Get-DriveRoot {
    $bases = @()
    try {
        $bases += ([System.IO.DriveInfo]::GetDrives() |
            Where-Object { try { $_.IsReady } catch { $false } } |
            ForEach-Object { $_.RootDirectory.FullName })
    } catch {}
    $bases += $script:HomeRoot
    foreach ($base in ($bases | Select-Object -Unique)) {
        foreach ($n in @('My Drive', 'Mon Drive', 'Shared drives', 'Drive partagés', 'Drive partages', 'Disques partagés')) {
            $p = Join-Path $base $n
            if (Test-Path $p) { return $base }
        }
    }
    return $null
}

function Get-SourceType([string]$Path) {
    if ($Path -like '*\Shared drives\*' -or $Path -like '*\Drive partag*' -or $Path -like '*\Disques partag*') { return 'Shared' }
    return 'MyDrive'
}

# ----------------------------------------------------------------------------
# Localisation de rclone (bundlé à côté du script ; sinon PATH)
# ----------------------------------------------------------------------------
function Find-Rclone {
    $bundled = Join-Path $PSScriptRoot 'rclone.exe'
    if (Test-Path $bundled) { return [pscustomobject]@{ Exe = $bundled } }
    $cmd = Get-Command rclone.exe -ErrorAction SilentlyContinue
    if ($cmd) { return [pscustomobject]@{ Exe = $cmd.Source } }
    return $null
}

# ----------------------------------------------------------------------------
# Moteur rclone : filtres, marqueur, commande bisync
# ----------------------------------------------------------------------------
function New-FiltersFile([string]$Path) {
    # NE PAS exclure le marqueur .coworkbridge-ok : --check-access applique ces filtres
    # et doit pouvoir le trouver des deux côtés. Il se synchronise donc (inerte, identique
    # partout) — l'exclure faisait échouer --check-access systématiquement (vérifié sur Windows).
    # Exclure les fichiers d'état FreeFileSync : volatils (réécrits en continu) ils font
    # échouer rclone (« corrupted on transfer: sizes differ »). Indispensable pour migrer
    # une ancienne install FFS sans casser la synchro/désync (vu sur la machine de Dylan).
    # Fichiers verrous volatils (Office/LibreOffice/Access) : réécrits en permanence -> mêmes
    # « corrupted on transfer » que les fichiers d'état FFS. Les exclure évite cette churn côté sync.
    # Volatile + Dir concaténés -> contenu IDENTIQUE à avant (aucun resync spurieux au split).
    $lines = @($script:VolatileFilterLines) + @($script:DirFilterLines)
    $content = ($lines -join "`r`n")
    $enc = New-Object System.Text.UTF8Encoding($false)
    # Retourne $true si le contenu change (fichier absent ou différent) : l'appelant doit alors
    # purger les index (Reset-PairIndexes). Un fichier nouvellement exclu disparaît du relevé
    # local, et l'index le croirait supprimé à la main, donc à retirer du Drive.
    # Skip si identique : pas d'écriture, pas de churn.
    try { if ((Test-Path $Path) -and ([System.IO.File]::ReadAllText($Path) -eq $content)) { return $false } } catch {}
    # Écriture atomique : l'agent résident peut lire filters.txt en pleine passe (--filter-from).
    # Temp + Replace évite qu'il tombe sur un fichier tronqué ; repli sur écriture directe si besoin.
    try {
        $tmp = "$Path.new"
        [System.IO.File]::WriteAllText($tmp, $content, $enc)
        if (Test-Path $Path) { [System.IO.File]::Replace($tmp, $Path, $null) } else { [System.IO.File]::Move($tmp, $Path) }
    } catch {
        try { Remove-Item "$Path.new" -Force -ErrorAction SilentlyContinue } catch {}
        [System.IO.File]::WriteAllText($Path, $content, $enc)
    }
    return $true
}

# Filtre de DÉSYNC : volatile seulement (+ le marqueur). Les dossiers dev (.git, node_modules...)
# n'existent QUE localement -> on doit les rendre au Drive avant de recycler le local. Retourne le
# chemin du fichier écrit (dans le workdir, non hashé par bisync).
function New-DesyncFilterFile([string]$MetaDir) {
    $lines = @($script:VolatileFilterLines)
    $content = ($lines -join "`r`n")
    $path = Join-Path $MetaDir 'desync-filter.txt'
    [System.IO.File]::WriteAllText($path, $content, (New-Object System.Text.UTF8Encoding($false)))
    return $path
}

# Purge l'index de toutes les paires. À appeler dès que le contenu des filtres change : un
# fichier nouvellement exclu disparaît du relevé local, et l'index le croirait supprimé à la
# main, donc à retirer du Drive. Index absent = descente seule au passage suivant, puis index
# reconstruit : le mode dégradé aligne le local sur le Drive, il ne touche jamais au Drive.
function Reset-PairIndexes([string]$MetaDir) {
    $indexDir = Join-Path $MetaDir 'index'
    if (-not (Test-Path -LiteralPath $indexDir)) { return }
    Get-ChildItem -LiteralPath $indexDir -File -Filter '*.lst' -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

# L'ancien moteur tenait son état dans _bridge\bisync-state. Sa présence signale une install
# antérieure au moteur miroir. On la purge sans créer d'index : le premier passage est alors une
# descente seule. Sans ça, un dossier de travail resté sur l'état d'avant republierait sur le
# Drive tout ce qui y a été rangé depuis, ce qui est exactement le défaut qu'on corrige.
function Remove-LegacyBisyncState([string]$MetaDir) {
    $stateDir = Join-Path $MetaDir 'bisync-state'
    if (-not (Test-Path -LiteralPath $stateDir)) { return $false }
    Write-Log 'Ancien etat de synchro detecte : purge, la premiere passe sera une descente seule.'
    try { Remove-Item -LiteralPath $stateDir -Recurse -Force -ErrorAction SilentlyContinue } catch {}
    Reset-PairIndexes $MetaDir
    return $true
}

# Marqueur de montage : sa présence des deux côtés prouve que le dossier est bien monté et
# hydraté. S'il manque, la passe refuse d'agir — c'est le rempart contre un côté vu vide.
function Set-Marker([string]$Folder) {
    try {
        $f = Join-Path $Folder $script:MarkerName
        if (-not (Test-Path -LiteralPath $f)) {
            [System.IO.File]::WriteAllText($f, "Cowork Bridge - marqueur d'acces, ne pas supprimer.", (New-Object System.Text.UTF8Encoding($false)))
        }
    } catch {}
}

# ----------------------------------------------------------------------------
# Moteur : relevé, plan, deux passes rclone
# ----------------------------------------------------------------------------
# Le Drive est la référence, le dossier local est le plan de travail que Cowork lit et écrit.
# Une passe monte ce que le poste a produit, puis aligne le local sur le Drive. Rien n'est
# jamais fusionné, donc une suppression faite sur le Drive descend toujours, quoi qu'un autre
# poste ait fait du fichier. Les deux index (état local et état Drive au dernier passage
# réussi) servent uniquement à distinguer une création d'une suppression. Index absent ou
# illisible -> descente seule : le mode dégradé aligne, il ne republie jamais.

function Get-PairIndexPath([string]$MetaDir, [string]$LocalName, [string]$Side) {
    return (Join-Path (Join-Path $MetaDir 'index') ($LocalName + '.' + $Side + '.lst'))
}

# Lance rclone et rend ses lignes de sortie. Start-Process + redirection plutôt que l'appel
# direct : le panneau WinForms n'a pas de console, un « & rclone » y ferait clignoter une fenêtre.
function Invoke-RcloneCapture {
    param([string]$RcloneExe, [string]$ArgLine)
    $out = [System.IO.Path]::GetTempFileName()
    $err = [System.IO.Path]::GetTempFileName()
    try {
        $p = Start-Process -FilePath $RcloneExe -ArgumentList $ArgLine -WindowStyle Hidden `
                           -RedirectStandardOutput $out -RedirectStandardError $err -PassThru -Wait
        $lines = @()
        try { $lines = [System.IO.File]::ReadAllLines($out, [System.Text.Encoding]::UTF8) } catch {}
        return [pscustomobject]@{ Code = [int]$p.ExitCode; Lines = $lines }
    } finally {
        Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $err -Force -ErrorAction SilentlyContinue
    }
}

# « date;taille;chemin » -> table chemin -> empreinte « date;taille ». Le chemin arrive en
# dernier parce qu'il peut lui-même contenir des points-virgules : on coupe sur les deux premiers.
function ConvertTo-ListingTable([string[]]$Lines) {
    $t = @{}
    foreach ($l in $Lines) {
        if ([string]::IsNullOrEmpty($l)) { continue }
        $i1 = $l.IndexOf(';'); if ($i1 -lt 0) { continue }
        $i2 = $l.IndexOf(';', $i1 + 1); if ($i2 -lt 0) { continue }
        $path = $l.Substring($i2 + 1)
        if ([string]::IsNullOrEmpty($path)) { continue }
        $t[$path] = $l.Substring(0, $i2)
    }
    return $t
}

# Relevé d'un côté. $null si rclone n'a pas pu lister : l'appelant traite ça comme un côté
# indisponible et s'abstient, plutôt que de lire un dossier vide comme « tout a été supprimé ».
function Get-FolderListing {
    param([string]$RcloneExe, [string]$Path, [string]$FiltersFile)
    $argLine = @('lsf', ('"{0}"' -f $Path), '--recursive', '--files-only',
                 '--format', 'tsp', '--filter-from', ('"{0}"' -f $FiltersFile),
                 '--log-level', 'ERROR') -join ' '
    $r = Invoke-RcloneCapture -RcloneExe $RcloneExe -ArgLine $argLine
    if ($r.Code -ne 0) { return $null }
    return (ConvertTo-ListingTable $r.Lines)
}

function Read-PairIndex([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { return (ConvertTo-ListingTable ([System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8))) } catch { return $null }
}

function Write-PairIndex([string]$Path, [hashtable]$Table) {
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $lines = New-Object System.Collections.ArrayList
    foreach ($p in $Table.Keys) { [void]$lines.Add(($Table[$p] + ';' + $p)) }
    [System.IO.File]::WriteAllLines($Path, [string[]]$lines.ToArray(), (New-Object System.Text.UTF8Encoding($false)))
}

# Décide ce qui monte et ce qui se supprime sur le Drive. Les deux index sont comparés chacun
# à son propre côté : jamais une date locale contre une date Drive, dont les résolutions
# diffèrent. Toute situation ambiguë se résout en faveur du Drive, que la descente appliquera.
function Get-SyncPlan {
    param([hashtable]$IndexLocal, [hashtable]$IndexDrive, [hashtable]$Local, [hashtable]$Drive)
    $toUpload = New-Object System.Collections.ArrayList
    $toDelete = New-Object System.Collections.ArrayList
    foreach ($p in $Local.Keys) {
        if (-not $IndexLocal.ContainsKey($p)) {
            # Apparu en local depuis le dernier passage. Présent aussi sur le Drive : les deux
            # l'ont créé de leur côté, la descente tranche en faveur du Drive.
            if (-not $Drive.ContainsKey($p)) { [void]$toUpload.Add($p) }
            continue
        }
        # Connu et absent du Drive : quelqu'un l'y a supprimé. C'est ici que l'ancien moteur le
        # republiait. La descente l'efface du local, sa version part dans la sauvegarde datée.
        if (-not $Drive.ContainsKey($p)) { continue }
        if ($Local[$p] -eq $IndexLocal[$p]) { continue }
        # Modifié en local. Si le Drive a bougé lui aussi, il gagne (la descente écrase).
        if ($IndexDrive.ContainsKey($p) -and $Drive[$p] -eq $IndexDrive[$p]) { [void]$toUpload.Add($p) }
    }
    foreach ($p in $IndexLocal.Keys) {
        if ($Local.ContainsKey($p)) { continue }
        if (-not $Drive.ContainsKey($p)) { continue }
        # Supprimé en local et intact sur le Drive : la suppression se propage. Modifié sur le
        # Drive entre-temps : on n'y touche pas, la descente le rendra au local.
        if ($IndexDrive.ContainsKey($p) -and $Drive[$p] -eq $IndexDrive[$p]) { [void]$toDelete.Add($p) }
    }
    return [pscustomobject]@{ Upload = @($toUpload.ToArray()); Delete = @($toDelete.ToArray()) }
}

# Liste de chemins pour --files-from. Sans BOM : rclone lirait le marqueur comme partie du
# premier chemin. Un chemin par ligne, relatif à la racine, séparateurs en slash (sortie de lsf).
function Write-FilesFromList([string]$Path, [string[]]$Items) {
    [System.IO.File]::WriteAllLines($Path, [string[]]$Items, (New-Object System.Text.UTF8Encoding($false)))
    return $Path
}

function Invoke-RcloneRun {
    param([string]$RcloneExe, [string]$ArgLine, [string]$Label)
    $p = Start-Process -FilePath $RcloneExe -ArgumentList $ArgLine -WindowStyle Hidden -PassThru -Wait
    Write-Log "$Label -> code $($p.ExitCode)"
    return [int]$p.ExitCode
}

# ---- Statut de synchro par paire : _bridge\status\<name>.json ----
# Écrit par l'agent ET par Sync-Pair (panneau) — même forme JSON dans les deux (l'agent a sa
# copie autonome dans le here-string). Lu par le panneau (santé) et par le support à distance.
function Get-StatusField([object]$Obj, [string]$Name, $Default) {
    if ($Obj -and ($Obj.PSObject.Properties.Name -contains $Name) -and $null -ne $Obj.$Name) { return $Obj.$Name }
    return $Default
}

function Read-SyncStatus([string]$MetaDir, [string]$LocalName) {
    # -LiteralPath : LocalName peut contenir [ ] (légaux sous Windows, wildcards pour PowerShell)
    $f = Join-Path (Join-Path $MetaDir 'status') ($LocalName + '.json')
    if (-not (Test-Path -LiteralPath $f)) { return $null }
    try { return (Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

function Write-SyncStatus([string]$MetaDir, [string]$LocalName, [int]$Code) {
    # Mutex nommé : agent et panneau font tous deux un read-modify-write du MÊME fichier ; l'écriture
    # atomique (temp+Replace) évite un fichier tronqué mais pas une mise à jour perdue (un succès vert
    # réécrasé en rouge, une gate 24 h désarmée). Le lock sérialise le read+write. Best-effort (2 s).
    $mtx = New-Object System.Threading.Mutex($false, 'Local\CoworkBridge-Status')
    $held = $false
    try { $held = $mtx.WaitOne(2000) } catch [System.Threading.AbandonedMutexException] { $held = $true } catch { $held = $false }
    try {
        $dir = Join-Path $MetaDir 'status'
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $old = Read-SyncStatus -MetaDir $MetaDir -LocalName $LocalName
        $now = (Get-Date).ToString('o')
        # ConvertFrom-Json rend les dates ISO en [datetime] selon l'hôte (PS7 ; PS 5.1 les laisse
        # en chaîne) : re-normaliser en chaîne 'o' pour un JSON portable dans les deux cas.
        $lastSuccess = Get-StatusField $old 'lastSuccess' $null
        if ($lastSuccess -is [datetime]) { $lastSuccess = $lastSuccess.ToString('o') }
        # 'Drive absent' (sentinelle) = NEUTRE : ni succès ni échec -> failures inchangé (pas de
        # faux rouge au boot, pas de blocage du watcher). Succès -> 0 ; tout le reste -> +1, y
        # compris le garde-fou de suppression, qui doit se voir au panneau.
        $failures = [int](Get-StatusField $old 'failures' 0)
        if ($Code -eq 0) { $lastSuccess = $now; $failures = 0 }
        elseif ($Code -eq $script:CodeDriveMissing) { }
        else { $failures = $failures + 1 }
        $st = [pscustomobject]@{
            name = $LocalName; lastRun = $now; lastExit = $Code
            lastSuccess = $lastSuccess; failures = $failures
        }
        $out  = Join-Path $dir ($LocalName + '.json')
        $json = ConvertTo-Json -InputObject $st
        $enc  = New-Object System.Text.UTF8Encoding($false)
        try {
            $tmp = "$out.new"
            [System.IO.File]::WriteAllText($tmp, $json, $enc)
            if (Test-Path -LiteralPath $out) { [System.IO.File]::Replace($tmp, $out, $null) } else { [System.IO.File]::Move($tmp, $out) }
        } catch { [System.IO.File]::WriteAllText($out, $json, $enc) }
    } catch {} finally {
        if ($held) { try { $mtx.ReleaseMutex() } catch {} }
        $mtx.Dispose()
    }
}

function Format-Ago([datetime]$T) {
    $d = (Get-Date) - $T
    if ($d.TotalMinutes -lt 1) { return 'just now' }
    if ($d.TotalHours -lt 1)   { return ('{0} min ago' -f [int][math]::Floor($d.TotalMinutes)) }
    if ($d.TotalDays -lt 1)    { return ('{0} h ago' -f [int][math]::Floor($d.TotalHours)) }
    return ('{0} d ago' -f [int][math]::Floor($d.TotalDays))
}

# Agrège les statuts par paire pour le panneau : $null si aucune donnée (install neuve), sinon
# @{ Ok; Text }. États ORDONNÉS du plus au moins grave : agent arrêté (stale) > FAILING (erreur
# réelle, échecs consécutifs) > waiting-Drive (sentinelle) > retrying (1er échec, se répare) > OK.
# Le vert n'est réservé qu'aux paires réellement à 0 (pas d'un « OK » rassurant sur une paire qui
# vient d'échouer). $IntervalMin passé par l'appelant -> pas de relecture disque à chaque tick.
function Get-BridgeHealth([string]$MetaDir, [object[]]$Sources, [int]$IntervalMin = 30) {
    $worstFail = $null; $oldestOk = $null; $newestRun = $null; $missing = $false; $retrying = $false
    $guarded = $null
    foreach ($s in $Sources) {
        $st = Read-SyncStatus -MetaDir $MetaDir -LocalName (Resolve-LocalName $s)
        if (-not $st) { continue }
        $lr = Get-StatusField $st 'lastRun' $null
        if ($lr) { try { $t = [datetime]$lr; if (-not $newestRun -or $t -gt $newestRun) { $newestRun = $t } } catch {} }
        $code  = [int](Get-StatusField $st 'lastExit' 0)
        $fails = [int](Get-StatusField $st 'failures' 0)
        if ($code -eq 0) {
            $ls = Get-StatusField $st 'lastSuccess' $null
            if ($ls) { try { $t = [datetime]$ls; if (-not $oldestOk -or $t -lt $oldestOk) { $oldestOk = $t } } catch {} }
        } elseif ($code -eq $script:CodeDriveMissing) {
            $missing = $true
        } elseif ($code -eq $script:CodeDeleteGuard) {
            # Beaucoup de fichiers manquants d'un coup en local : rien n'a été supprimé sur le
            # Drive, et le dossier de travail a été rétabli depuis lui. À dire franchement,
            # l'utilisateur croirait sinon que son ménage n'a pas été pris en compte.
            $guarded = $st
        } elseif ($fails -ge 2) {
            if (-not $worstFail -or $fails -gt [int](Get-StatusField $worstFail 'failures' 0)) { $worstFail = $st }
        } else {
            $retrying = $true   # erreur réelle mais 1er échec : pas encore alarmant
        }
    }
    # Aucun run depuis longtemps = agent probablement arrêté (crash, raccourci/tâche supprimés) :
    # une santé verte serait périmée. Priorité maximale (plus rien ne se synchronise).
    if ($newestRun) {
        $mins = if ($IntervalMin -lt 1) { 1 } else { $IntervalMin }
        if (((Get-Date) - $newestRun).TotalMinutes -gt [math]::Max(3 * $mins, 90)) {
            # Kind='stale' : l'appelant suppresse ce verdict pendant une courte grâce au démarrage
            # (au boot l'agent vient d'être relancé mais n'a pas encore écrit de statut).
            return @{ Ok = $false; Kind = 'stale'; Text = ('no sync since {0} - the background agent may be stopped, close and reopen this app' -f (Format-Ago $newestRun)) }
        }
    }
    if ($worstFail) {
        $n = Get-StatusField $worstFail 'name' '?'
        $c = [int](Get-StatusField $worstFail 'failures' 0)
        $ls = Get-StatusField $worstFail 'lastSuccess' $null
        $since = 'never synced'
        if ($ls) { try { $since = 'last success ' + (Format-Ago ([datetime]$ls)) } catch {} }
        return @{ Ok = $false; Text = ('Sync FAILING: {0} ({1} tries, {2})' -f $n, $c, $since) }
    }
    if ($guarded) {
        $n = Get-StatusField $guarded 'name' '?'
        return @{ Ok = $false; Text = ('{0}: many files were missing locally - nothing was deleted on Drive, the folder was restored' -f $n) }
    }
    if ($missing)  { return @{ Ok = $false; Text = 'waiting for Google Drive to start' } }
    if ($retrying) { return @{ Ok = $false; Text = 'syncing (retrying)...' } }
    if ($oldestOk) { return @{ Ok = $true;  Text = ('last sync OK ({0})' -f (Format-Ago $oldestOk)) } }
    return $null
}

# Filtre de la descente. Sans fichier à protéger, c'est le filtre habituel. Sinon on préfixe
# une copie par les exclusions, plutôt que de cumuler --filter-from et --exclude-from dont
# l'ordre de priorité se discute. Chemin ancré à la racine du transfert, caractères de motif
# neutralisés : un nom contenant [ ] ou * ne doit pas se transformer en règle large.
function New-PassFilterFile {
    param([string]$MetaDir, [string]$LocalName, [string]$BaseFilters, [string[]]$Protect)
    if ($null -eq $Protect -or $Protect.Count -eq 0) { return $BaseFilters }
    $lines = New-Object System.Collections.ArrayList
    foreach ($p in $Protect) {
        [void]$lines.Add('- /' + ($p -replace '([\*\?\[\]\{\}])', '\$1'))
    }
    try { foreach ($l in [System.IO.File]::ReadAllLines($BaseFilters, [System.Text.Encoding]::UTF8)) { [void]$lines.Add($l) } } catch { return $BaseFilters }
    $path = Join-Path $MetaDir ($LocalName + '.pass-filter.txt')
    [System.IO.File]::WriteAllLines($path, [string[]]$lines.ToArray(), (New-Object System.Text.UTF8Encoding($false)))
    return $path
}

# Une passe de synchronisation sur une paire. Rend 0 (succès), 90 (Drive non monté),
# 91 (garde-fou de suppression), ou le code rclone de l'étape qui a échoué.
#
# Ordre : monter ce que ce poste a produit, propager ce qu'il a supprimé, puis aligner le
# dossier de travail sur le Drive. Le travail local part donc toujours avant que l'alignement
# ne l'écrase. Aucune étape ne fusionne les deux côtés : rien ne peut ressusciter une
# suppression, quel que soit ce qu'un autre poste a fait du fichier entre-temps.
# Un échec laisse l'index intact : la passe suivante reprend le même plan sur le même état.
# Même logique dans l'agent (Run-All) : toute modification ici se répercute là-bas.
function Sync-Pair {
    param([object]$Rclone, [string]$DrivePath, [string]$LocalPath, [string]$MetaDir, [string]$LocalName)
    Assert-SafePath $DrivePath; Assert-SafePath $LocalPath; Assert-SafePath $MetaDir

    # Marqueur côté Drive : preuve que Drive Desktop est monté et que le dossier est réellement
    # là. Sans ce garde, un Drive vu vide ferait vider le dossier de travail par l'alignement.
    if (-not (Test-Path -LiteralPath (Join-Path $DrivePath $script:MarkerName))) {
        Write-SyncStatus -MetaDir $MetaDir -LocalName $LocalName -Code $script:CodeDriveMissing
        return $script:CodeDriveMissing
    }
    if (-not (Test-Path -LiteralPath $LocalPath)) {
        New-Item -ItemType Directory -Path $LocalPath -Force | Out-Null
        Set-Marker $LocalPath
    }

    $filters = Join-Path $MetaDir 'filters.txt'
    $log     = Join-Path $MetaDir 'rclone.log'
    $backup  = Join-Path (Join-Path $MetaDir 'trash') ((Get-Date -Format 'yyyy-MM-dd') + '\' + $LocalName)
    $idxLocalPath = Get-PairIndexPath $MetaDir $LocalName 'local'
    $idxDrivePath = Get-PairIndexPath $MetaDir $LocalName 'drive'
    $q = { param($s) '"{0}"' -f $s }

    # Relevé des deux côtés. Un relevé qui échoue rend son côté inexploitable : on s'abstient,
    # plutôt que de lire une projection défaillante comme un dossier vidé.
    $local = Get-FolderListing -RcloneExe $Rclone.Exe -Path $LocalPath -FiltersFile $filters
    $drive = Get-FolderListing -RcloneExe $Rclone.Exe -Path $DrivePath -FiltersFile $filters
    if ($null -eq $local -or $null -eq $drive) {
        Write-Log "releve impossible sur '$LocalName'" 'WARN'
        Write-SyncStatus -MetaDir $MetaDir -LocalName $LocalName -Code 1
        return 1
    }

    $idxLocal = Read-PairIndex $idxLocalPath
    $idxDrive = Read-PairIndex $idxDrivePath
    $guarded = $false
    if ($null -eq $idxLocal -or $null -eq $idxDrive) {
        # Index absent : première passe, filtres modifiés, ou migration depuis l'ancien moteur.
        # Rien ne distingue alors une création locale d'une suppression distante, donc on ne
        # touche pas au Drive et on se contente d'aligner. L'index se reconstruit en fin de passe.
        $plan = [pscustomobject]@{ Upload = @(); Delete = @() }
        Write-Log "pas d'index pour '$LocalName' : descente seule"
    } else {
        $plan = Get-SyncPlan -IndexLocal $idxLocal -IndexDrive $idxDrive -Local $local -Drive $drive
        if ($plan.Delete.Count -gt $script:DeleteGuardMin -and
            $plan.Delete.Count -gt ($idxLocal.Count * $script:DeleteGuardRatio)) {
            Write-Log ("garde-fou de suppression sur '{0}' : {1} fichiers sur {2}, aucune suppression propagee" -f $LocalName, $plan.Delete.Count, $idxLocal.Count) 'WARN'
            $plan = [pscustomobject]@{ Upload = $plan.Upload; Delete = @() }
            $guarded = $true
        }
    }

    # Chaque étape fait ce qu'elle peut : une étape en échec n'annule pas les suivantes, elle
    # rend seulement le code final non nul, ce qui suffit à retenir l'index. Enchaîner ainsi
    # évite qu'un seul fichier verrouillé gèle la propagation des suppressions, ce qui est
    # exactement le blocage constaté chez le client.
    $upCode = 0; $delCode = 0; $downCode = 0
    $listFile = Join-Path $MetaDir ($LocalName + '.files-from.txt')

    # 1. Montée. --no-traverse : pour une poignée de fichiers, rclone vérifie chaque chemin au
    # lieu d'énumérer toute la destination, ce qui épargne un parcours de la projection Drive.
    $protect = @()
    if ($plan.Upload.Count -gt 0) {
        Write-FilesFromList $listFile $plan.Upload | Out-Null
        $argLine = (@('copy', (& $q $LocalPath), (& $q $DrivePath),
            '--files-from', (& $q $listFile), '--no-traverse') +
            $script:RcloneCommonFlags + @('--log-file', (& $q $log)) + $script:RcloneLogFlags) -join ' '
        $upCode = Invoke-RcloneRun -RcloneExe $Rclone.Exe -ArgLine $argLine -Label ("montee '{0}' ({1} fichiers)" -f $LocalName, $plan.Upload.Count)
        if ($upCode -ne 0) {
            # Ce qui n'a pas pu monter n'existe que dans le dossier de travail. L'alignement le
            # retirerait, alors que c'est peut-être le seul exemplaire : on le protège.
            $upDrive = Get-FolderListing -RcloneExe $Rclone.Exe -Path $DrivePath -FiltersFile $filters
            if ($null -eq $upDrive) { $protect = $plan.Upload }
            else { $protect = @($plan.Upload | Where-Object { -not $upDrive.ContainsKey($_) }) }
            if ($protect.Count -gt 0) { Write-Log ("montee incomplete sur '{0}' : {1} fichier(s) protege(s) de la descente" -f $LocalName, $protect.Count) 'WARN' }
        }
    }

    # 2. Suppressions sur le Drive. Drive Desktop route vers la corbeille Google (30 jours).
    if ($plan.Delete.Count -gt 0) {
        Write-FilesFromList $listFile $plan.Delete | Out-Null
        $argLine = (@('delete', (& $q $DrivePath),
            '--files-from', (& $q $listFile), '--no-traverse') +
            $script:RcloneCommonFlags + @('--log-file', (& $q $log)) + $script:RcloneLogFlags) -join ' '
        $delCode = Invoke-RcloneRun -RcloneExe $Rclone.Exe -ArgLine $argLine -Label ("suppressions Drive '{0}' ({1} fichiers)" -f $LocalName, $plan.Delete.Count)
    }

    # 3. Descente : le dossier de travail devient le reflet du Drive. Ce qui est écrasé ou retiré
    # part dans la sauvegarde datée, donc aucune de ces deux opérations n'est destructrice.
    $downFilters = New-PassFilterFile -MetaDir $MetaDir -LocalName $LocalName -BaseFilters $filters -Protect $protect
    $argLine = (@('sync', (& $q $DrivePath), (& $q $LocalPath),
        '--filter-from', (& $q $downFilters), '--backup-dir', (& $q $backup)) +
        $script:RcloneCommonFlags + $script:RcloneDownFlags + @('--log-file', (& $q $log)) + $script:RcloneLogFlags) -join ' '
    $downCode = Invoke-RcloneRun -RcloneExe $Rclone.Exe -ArgLine $argLine -Label ("descente '{0}'" -f $LocalName)
    Remove-Item -LiteralPath $listFile -Force -ErrorAction SilentlyContinue
    if ($downFilters -ne $filters) { Remove-Item -LiteralPath $downFilters -Force -ErrorAction SilentlyContinue }

    $code = 0
    foreach ($c in @($upCode, $delCode, $downCode)) { if ($c -ne 0 -and $code -eq 0) { $code = $c } }

    # 4. Index réécrit seulement si toutes les étapes sont passées. Sinon il continue de décrire
    # le dernier état sûr, et la passe suivante refait le même plan au lieu d'un demi-plan.
    if ($code -eq 0) {
        $afterLocal = Get-FolderListing -RcloneExe $Rclone.Exe -Path $LocalPath -FiltersFile $filters
        # Le Drive n'est relevé à nouveau que si cette passe l'a modifié : sinon le relevé d'entrée
        # fait foi, et on épargne une énumération de la projection.
        $afterDrive = $drive
        if ($plan.Upload.Count -gt 0 -or $plan.Delete.Count -gt 0) {
            $afterDrive = Get-FolderListing -RcloneExe $Rclone.Exe -Path $DrivePath -FiltersFile $filters
        }
        if ($null -ne $afterLocal -and $null -ne $afterDrive) {
            Write-PairIndex $idxLocalPath $afterLocal
            Write-PairIndex $idxDrivePath $afterDrive
        }
    }
    if ($guarded -and $code -eq 0) { $code = $script:CodeDeleteGuard }
    Write-SyncStatus -MetaDir $MetaDir -LocalName $LocalName -Code $code
    return $code
}

# ----------------------------------------------------------------------------
# Agent résident : watcher (push instantané) + timer (pull périodique)
# ----------------------------------------------------------------------------
function Set-IntervalFile([string]$MetaDir, [int]$IntervalMin) {
    [System.IO.File]::WriteAllText((Join-Path $MetaDir 'interval'), [string]$IntervalMin, (New-Object System.Text.UTF8Encoding($false)))
}

function Set-SyncAgent {
    param([string]$RcloneExe, [string]$MetaDir, [int]$IntervalMin)
    try {
        Assert-SafePath $RcloneExe; Assert-SafePath $MetaDir
        Set-IntervalFile -MetaDir $MetaDir -IntervalMin $IntervalMin
        $rcLit   = $RcloneExe.Replace("'", "''")
        $metaLit = $MetaDir.Replace("'", "''")
        $markLit = $script:MarkerName.Replace("'", "''")
        # Mêmes drapeaux statiques que l'installeur, sérialisés en littéraux PowerShell
        # ('flag', 'flag', ...) interpolés DANS le here-string (bare $, à la génération) — pas
        # d'escape backtick : ces tokens ne contiennent ni $ ni guillemet (constantes internes).
        $commonLit = ($script:RcloneCommonFlags | ForEach-Object { "'$_'" }) -join ', '
        $downLit   = ($script:RcloneDownFlags   | ForEach-Object { "'$_'" }) -join ', '
        $logLit    = ($script:RcloneLogFlags    | ForEach-Object { "'$_'" }) -join ', '
        # Constantes de tuning : SOURCE UNIQUE, interpolées en littéraux numériques dans l'agent
        # (bare $, à la génération) -> l'installeur et l'agent ne peuvent plus diverger sur ces seuils.
        $codeMissingLit = [int]$script:CodeDriveMissing
        $codeGuardLit   = [int]$script:CodeDeleteGuard
        $guardMinLit    = [int]$script:DeleteGuardMin
        $guardRatioLit  = [string]([double]$script:DeleteGuardRatio).ToString([System.Globalization.CultureInfo]::InvariantCulture)
        $throttleLit    = [int]$script:FailThrottle
        $agentPs = Join-Path $MetaDir 'sync-agent.ps1'
        $agent = @"
# Cowork Bridge - agent de synchro (genere automatiquement, ne pas editer)
Set-StrictMode -Version Latest
# Mono-instance : le chien de garde (tache planifiee) relance l'agent au logon + toutes les
# heures ; si un agent tourne deja, celui-ci sort immediatement. AbandonedMutex = le detenteur
# precedent est mort sans liberer -> la propriete nous revient (acquis). Toute autre exception :
# on demarre quand meme (--max-lock reste le garde-fou secondaire contre deux bisync concurrents).
`$script:mtx = New-Object System.Threading.Mutex(`$false, 'Local\CoworkBridge-SyncAgent')
`$got = `$false
try { `$got = `$script:mtx.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { `$got = `$true } catch { `$got = `$true }
if (-not `$got) { exit }
`$rclone = '$rcLit'
`$meta   = '$metaLit'
`$marker = '$markLit'

function Read-Pairs {
    `$cfg = Join-Path `$meta 'config.json'
    if (-not (Test-Path `$cfg)) { return @() }
    try { `$c = Get-Content `$cfg -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return @() }
    if (-not (`$c.PSObject.Properties.Name -contains 'sources') -or -not `$c.sources) { return @() }
    if (-not (`$c.PSObject.Properties.Name -contains 'dest') -or -not `$c.dest) { return @() }
    `$dest = `$c.dest
    `$out = @()
    foreach (`$s in @(`$c.sources)) {
        # tout garder sous StrictMode : une source malformee est ignoree, l'agent ne meurt pas
        if (-not (`$s.PSObject.Properties.Name -contains 'Path') -or -not `$s.Path) { continue }
        `$ln = `$null
        if ((`$s.PSObject.Properties.Name -contains 'LocalName') -and `$s.LocalName) { `$ln = [string]`$s.LocalName }
        elseif ((`$s.PSObject.Properties.Name -contains 'Name') -and `$s.Name) { `$ln = [string]`$s.Name }
        if (-not `$ln) { continue }
        `$ln = `$ln -replace '[\\/:*?"<>|]', '_'
        `$out += [pscustomobject]@{ Drive = `$s.Path; Local = (Join-Path `$dest `$ln); Name = `$ln }
    }
    return `$out
}

function Get-Interval {
    `$min = 30
    try { `$min = [int]((Get-Content (Join-Path `$meta 'interval') -Raw).Trim()) } catch {}
    if (`$min -lt 1) { `$min = 1 }
    return `$min
}

# ---- Statut par paire (meta\status\<name>.json) : meme forme JSON que Write-SyncStatus
# cote installeur. Lu par le panneau (sante) et le support a distance. ----
function Get-Field(`$o, [string]`$n, `$d) {
    if (`$o -and (`$o.PSObject.Properties.Name -contains `$n) -and `$null -ne `$o.`$n) { return `$o.`$n }
    return `$d
}

function Read-Status([string]`$name) {
    # -LiteralPath : le nom de paire peut contenir [ ] (legaux sous Windows, wildcards PowerShell)
    `$f = Join-Path (Join-Path `$meta 'status') (`$name + '.json')
    if (-not (Test-Path -LiteralPath `$f)) { return `$null }
    try { return (Get-Content -LiteralPath `$f -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return `$null }
}

function Write-Status([string]`$name, [int]`$code, [bool]`$markResync, [bool]`$markForce, [bool]`$deleteSignal) {
    # Mutex nomme : agent et panneau ecrivent le meme fichier ; serialise le read-modify-write
    # (l'ecriture atomique seule ne protege pas d'une mise a jour perdue). Best-effort (2 s).
    `$mtx = New-Object System.Threading.Mutex(`$false, 'Local\CoworkBridge-Status')
    `$held = `$false
    try { `$held = `$mtx.WaitOne(2000) } catch [System.Threading.AbandonedMutexException] { `$held = `$true } catch { `$held = `$false }
    try {
        `$dir = Join-Path `$meta 'status'
        if (-not (Test-Path -LiteralPath `$dir)) { New-Item -ItemType Directory -Path `$dir -Force | Out-Null }
        `$old = Read-Status `$name
        `$now = (Get-Date).ToString('o')
        # ConvertFrom-Json rend les dates ISO en [datetime] selon l'hote (PS7 ; PS 5.1 = chaine) : re-normaliser en 'o'
        `$lastSuccess = Get-Field `$old 'lastSuccess' `$null
        if (`$lastSuccess -is [datetime]) { `$lastSuccess = `$lastSuccess.ToString('o') }
        # sentinelle Drive absent = NEUTRE (ni succes ni echec) : failures inchange.
        `$failures = [int](Get-Field `$old 'failures' 0)
        if (`$code -eq 0) { `$lastSuccess = `$now; `$failures = 0 }
        elseif (`$code -eq $codeMissingLit) { }
        else { `$failures = `$failures + 1 }
        `$lastAuto = Get-Field `$old 'lastAutoResync' `$null
        if (`$lastAuto -is [datetime]) { `$lastAuto = `$lastAuto.ToString('o') }
        if (`$markResync) { `$lastAuto = `$now }
        `$deleteAborts = 0
        if (`$deleteSignal) { `$deleteAborts = 1 + [int](Get-Field `$old 'deleteAborts' 0) }
        `$lastForce = Get-Field `$old 'lastAutoForce' `$null
        if (`$lastForce -is [datetime]) { `$lastForce = `$lastForce.ToString('o') }
        if (`$markForce) { `$lastForce = `$now }
        `$st = [pscustomobject]@{
            name = `$name; lastRun = `$now; lastExit = `$code
            lastSuccess = `$lastSuccess; failures = `$failures; lastAutoResync = `$lastAuto
            deleteAborts = `$deleteAborts; lastAutoForce = `$lastForce
        }
        `$out  = Join-Path `$dir (`$name + '.json')
        `$json = ConvertTo-Json -InputObject `$st
        `$enc  = New-Object System.Text.UTF8Encoding(`$false)
        try {
            `$tmp = "`$out.new"
            [System.IO.File]::WriteAllText(`$tmp, `$json, `$enc)
            if (Test-Path -LiteralPath `$out) { [System.IO.File]::Replace(`$tmp, `$out, `$null) } else { [System.IO.File]::Move(`$tmp, `$out) }
        } catch { [System.IO.File]::WriteAllText(`$out, `$json, `$enc) }
    } catch {} finally {
        if (`$held) { try { `$mtx.ReleaseMutex() } catch {} }
        `$mtx.Dispose()
    }
}

# ---- Moteur : jumeau de Sync-Pair cote installeur. Toute modification la-bas se repercute ici.
# Le Drive est la reference, le dossier local est le plan de travail. Une passe monte ce que ce
# poste a produit, propage ce qu'il a supprime, puis aligne le local sur le Drive. Aucune fusion,
# donc aucune resurrection possible. Index absent -> descente seule.
function Invoke-RcloneCapture([string]`$argLine) {
    `$out = [System.IO.Path]::GetTempFileName()
    `$err = [System.IO.Path]::GetTempFileName()
    try {
        `$p = Start-Process -FilePath `$rclone -ArgumentList `$argLine -WindowStyle Hidden ``
                           -RedirectStandardOutput `$out -RedirectStandardError `$err -PassThru -Wait
        `$lines = @()
        try { `$lines = [System.IO.File]::ReadAllLines(`$out, [System.Text.Encoding]::UTF8) } catch {}
        return [pscustomobject]@{ Code = [int]`$p.ExitCode; Lines = `$lines }
    } finally {
        Remove-Item -LiteralPath `$out -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath `$err -Force -ErrorAction SilentlyContinue
    }
}

# « date;taille;chemin » -> table chemin -> « date;taille ». Le chemin vient en dernier car il
# peut contenir des points-virgules : on coupe sur les deux premiers seulement.
function ConvertTo-Table([string[]]`$lines) {
    `$t = @{}
    foreach (`$l in `$lines) {
        if ([string]::IsNullOrEmpty(`$l)) { continue }
        `$i1 = `$l.IndexOf(';'); if (`$i1 -lt 0) { continue }
        `$i2 = `$l.IndexOf(';', `$i1 + 1); if (`$i2 -lt 0) { continue }
        `$path = `$l.Substring(`$i2 + 1)
        if ([string]::IsNullOrEmpty(`$path)) { continue }
        `$t[`$path] = `$l.Substring(0, `$i2)
    }
    return `$t
}

# `$null si le releve echoue : le cote est inexploitable, on s'abstient plutot que de lire une
# projection defaillante comme un dossier vide.
function Get-Listing([string]`$path, [string]`$filters) {
    `$argLine = @('lsf', ('"{0}"' -f `$path), '--recursive', '--files-only',
                 '--format', 'tsp', '--filter-from', ('"{0}"' -f `$filters),
                 '--log-level', 'ERROR') -join ' '
    `$r = Invoke-RcloneCapture `$argLine
    if (`$r.Code -ne 0) { return `$null }
    return (ConvertTo-Table `$r.Lines)
}

function Read-Index([string]`$path) {
    if (-not (Test-Path -LiteralPath `$path)) { return `$null }
    try { return (ConvertTo-Table ([System.IO.File]::ReadAllLines(`$path, [System.Text.Encoding]::UTF8))) } catch { return `$null }
}

function Write-Index([string]`$path, [hashtable]`$table) {
    `$dir = Split-Path -Parent `$path
    if (-not (Test-Path -LiteralPath `$dir)) { New-Item -ItemType Directory -Path `$dir -Force | Out-Null }
    `$lines = New-Object System.Collections.ArrayList
    foreach (`$k in `$table.Keys) { [void]`$lines.Add((`$table[`$k] + ';' + `$k)) }
    [System.IO.File]::WriteAllLines(`$path, [string[]]`$lines.ToArray(), (New-Object System.Text.UTF8Encoding(`$false)))
}

# Chaque index est compare a son propre cote : jamais une date locale contre une date Drive,
# dont les resolutions different. Toute situation ambigue se resout en faveur du Drive.
function Get-Plan([hashtable]`$idxLocal, [hashtable]`$idxDrive, [hashtable]`$local, [hashtable]`$drive) {
    `$up = New-Object System.Collections.ArrayList
    `$del = New-Object System.Collections.ArrayList
    foreach (`$p in `$local.Keys) {
        if (-not `$idxLocal.ContainsKey(`$p)) {
            if (-not `$drive.ContainsKey(`$p)) { [void]`$up.Add(`$p) }
            continue
        }
        # Connu et absent du Drive : quelqu'un l'y a supprime. C'est ici que l'ancien moteur le
        # republiait. La descente l'efface du local, sa version part dans la sauvegarde datee.
        if (-not `$drive.ContainsKey(`$p)) { continue }
        if (`$local[`$p] -eq `$idxLocal[`$p]) { continue }
        if (`$idxDrive.ContainsKey(`$p) -and `$drive[`$p] -eq `$idxDrive[`$p]) { [void]`$up.Add(`$p) }
    }
    foreach (`$p in `$idxLocal.Keys) {
        if (`$local.ContainsKey(`$p)) { continue }
        if (-not `$drive.ContainsKey(`$p)) { continue }
        if (`$idxDrive.ContainsKey(`$p) -and `$drive[`$p] -eq `$idxDrive[`$p]) { [void]`$del.Add(`$p) }
    }
    return [pscustomobject]@{ Upload = @(`$up.ToArray()); Delete = @(`$del.ToArray()) }
}

# Sans BOM : rclone lirait le marqueur comme partie du premier chemin.
function Write-FilesFrom([string]`$path, [string[]]`$items) {
    [System.IO.File]::WriteAllLines(`$path, [string[]]`$items, (New-Object System.Text.UTF8Encoding(`$false)))
}

function Invoke-Rclone([string]`$argLine) {
    try {
        `$p = Start-Process -FilePath `$rclone -ArgumentList `$argLine -WindowStyle Hidden -Wait -PassThru
        return [int]`$p.ExitCode
    } catch { return -1 }
}

function Run-All {
    param([bool]`$Due)
    foreach (`$p in (Read-Pairs)) {
        # -LiteralPath sur tout chemin derive du nom de paire ([ ] legaux mais globbent en PowerShell)
        # Paire en echec repete : cadence intervalle seulement (pas de retry sur evenement du
        # watcher) -- sinon une synchro qui echoue en boucle rescanne la projection dos a dos.
        `$fails = [int](Get-Field (Read-Status `$p.Name) 'failures' 0)
        if (-not `$Due -and `$fails -ge $throttleLit) { continue }
        # Marqueur cote Drive : preuve que Drive Desktop est monte. Sans lui, le Drive serait vu
        # vide et l'alignement viderait le dossier de travail.
        if (-not (Test-Path -LiteralPath (Join-Path `$p.Drive `$marker))) { Write-Status `$p.Name $codeMissingLit; continue }
        if (-not (Test-Path -LiteralPath `$p.Local)) { Write-Status `$p.Name $codeMissingLit; continue }

        `$filters = Join-Path `$meta 'filters.txt'
        `$log     = Join-Path `$meta 'rclone.log'
        `$backup  = Join-Path (Join-Path `$meta 'trash') ((Get-Date -Format 'yyyy-MM-dd') + '\' + `$p.Name)
        `$idxL    = Join-Path (Join-Path `$meta 'index') (`$p.Name + '.local.lst')
        `$idxD    = Join-Path (Join-Path `$meta 'index') (`$p.Name + '.drive.lst')
        `$listFile = Join-Path `$meta (`$p.Name + '.files-from.txt')

        `$local = Get-Listing `$p.Local `$filters
        `$drive = Get-Listing `$p.Drive `$filters
        if (`$null -eq `$local -or `$null -eq `$drive) { Write-Status `$p.Name 1; continue }

        `$indexLocal = Read-Index `$idxL
        `$indexDrive = Read-Index `$idxD
        `$guarded = `$false
        if (`$null -eq `$indexLocal -or `$null -eq `$indexDrive) {
            `$plan = [pscustomobject]@{ Upload = @(); Delete = @() }
        } else {
            `$plan = Get-Plan `$indexLocal `$indexDrive `$local `$drive
            # Garde-fou : le seul sens ou une perte serait irreversible est local -> Drive.
            if (`$plan.Delete.Count -gt $guardMinLit -and `$plan.Delete.Count -gt (`$indexLocal.Count * $guardRatioLit)) {
                `$plan = [pscustomobject]@{ Upload = `$plan.Upload; Delete = @() }
                `$guarded = `$true
            }
        }

        # Chaque etape fait ce qu'elle peut : une etape en echec n'annule pas les suivantes,
        # elle rend seulement le code final non nul, ce qui suffit a retenir l'index. Sinon un
        # seul fichier verrouille gelerait la propagation des suppressions.
        `$upCode = 0; `$delCode = 0; `$downCode = 0
        `$protect = @()
        if (`$plan.Upload.Count -gt 0) {
            Write-FilesFrom `$listFile `$plan.Upload
            `$argLine = (@('copy', ('"{0}"' -f `$p.Local), ('"{0}"' -f `$p.Drive),
                '--files-from', ('"{0}"' -f `$listFile), '--no-traverse', $commonLit,
                '--log-file', ('"{0}"' -f `$log), $logLit)) -join ' '
            `$upCode = Invoke-Rclone `$argLine
            if (`$upCode -ne 0) {
                # Ce qui n'a pas pu monter n'existe que dans le dossier de travail : l'alignement
                # le retirerait alors que c'est peut-etre le seul exemplaire.
                `$upDrive = Get-Listing `$p.Drive `$filters
                if (`$null -eq `$upDrive) { `$protect = `$plan.Upload }
                else { `$protect = @(`$plan.Upload | Where-Object { -not `$upDrive.ContainsKey(`$_) }) }
            }
        }
        if (`$plan.Delete.Count -gt 0) {
            Write-FilesFrom `$listFile `$plan.Delete
            `$argLine = (@('delete', ('"{0}"' -f `$p.Drive),
                '--files-from', ('"{0}"' -f `$listFile), '--no-traverse', $commonLit,
                '--log-file', ('"{0}"' -f `$log), $logLit)) -join ' '
            `$delCode = Invoke-Rclone `$argLine
        }
        `$downFilters = `$filters
        if (`$protect.Count -gt 0) {
            `$lines = New-Object System.Collections.ArrayList
            foreach (`$x in `$protect) { [void]`$lines.Add('- /' + (`$x -replace '([\*\?\[\]\{\}])', '\`$1')) }
            try {
                foreach (`$l in [System.IO.File]::ReadAllLines(`$filters, [System.Text.Encoding]::UTF8)) { [void]`$lines.Add(`$l) }
                `$downFilters = Join-Path `$meta (`$p.Name + '.pass-filter.txt')
                [System.IO.File]::WriteAllLines(`$downFilters, [string[]]`$lines.ToArray(), (New-Object System.Text.UTF8Encoding(`$false)))
            } catch { `$downFilters = `$filters }
        }
        `$argLine = (@('sync', ('"{0}"' -f `$p.Drive), ('"{0}"' -f `$p.Local),
            '--filter-from', ('"{0}"' -f `$downFilters), '--backup-dir', ('"{0}"' -f `$backup),
            $commonLit, $downLit, '--log-file', ('"{0}"' -f `$log), $logLit)) -join ' '
        `$downCode = Invoke-Rclone `$argLine
        Remove-Item -LiteralPath `$listFile -Force -ErrorAction SilentlyContinue
        if (`$downFilters -ne `$filters) { Remove-Item -LiteralPath `$downFilters -Force -ErrorAction SilentlyContinue }
        `$code = 0
        foreach (`$c in @(`$upCode, `$delCode, `$downCode)) { if (`$c -ne 0 -and `$code -eq 0) { `$code = `$c } }

        # Index reecrit seulement si tout est passe : sinon il continue de decrire le dernier
        # etat sur, et la passe suivante refait le meme plan au lieu d'un demi-plan.
        if (`$code -eq 0) {
            `$afterLocal = Get-Listing `$p.Local `$filters
            `$afterDrive = `$drive
            if (`$plan.Upload.Count -gt 0 -or `$plan.Delete.Count -gt 0) { `$afterDrive = Get-Listing `$p.Drive `$filters }
            if (`$null -ne `$afterLocal -and `$null -ne `$afterDrive) {
                Write-Index `$idxL `$afterLocal
                Write-Index `$idxD `$afterDrive
            }
        }
        if (`$guarded -and `$code -eq 0) { `$code = $codeGuardLit }
        Write-Status `$p.Name `$code
    }
}


# Watcher : chaque modif locale émet un événement dans la file (récupéré par Wait-Event).
`$watchers = @()
foreach (`$p in (Read-Pairs)) {
    if (-not (Test-Path -LiteralPath `$p.Local)) { continue }
    try {
        `$w = New-Object System.IO.FileSystemWatcher `$p.Local
        `$w.IncludeSubdirectories = `$true
        `$w.EnableRaisingEvents = `$true
        foreach (`$ev in 'Changed','Created','Deleted','Renamed') {
            Register-ObjectEvent -InputObject `$w -EventName `$ev | Out-Null
        }
        `$watchers += `$w
    } catch {}
}

`$lastRun = (Get-Date).AddYears(-1)
while (`$true) {
    # Wait-Event pompe la file d'événements : push quasi instantané sur modif locale,
    # et le timeout de 5 s sert aussi de tick pour le pull périodique.
    `$ev = Wait-Event -Timeout 5
    `$dirty = `$false
    if (`$ev) { Get-Event | Remove-Event -ErrorAction SilentlyContinue; `$dirty = `$true }
    `$interval = Get-Interval
    `$due = ((Get-Date) - `$lastRun).TotalMinutes -ge `$interval
    if (`$dirty -or `$due) {
        Run-All `$due
        # Purge la file FSW : les fichiers deposes par le pull declenchaient sinon un second run
        # (assume : une modif utilisateur faite PENDANT la synchro part au tick suivant --
        # prefere a un double scan systematique de la projection)
        Get-Event -ErrorAction SilentlyContinue | Remove-Event -ErrorAction SilentlyContinue
        `$lastRun = Get-Date   # APRES Run-All : garantit un temps mort = intervalle, meme si la synchro est longue
        try { [System.IO.File]::WriteAllText((Join-Path `$meta 'next-sync'), `$lastRun.AddMinutes(`$interval).ToString('o')) } catch {}
    }
}
"@
        [System.IO.File]::WriteAllText($agentPs, $agent, (New-Object System.Text.UTF8Encoding($false)))
        $ps      = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $argLine = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $agentPs
        $lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'CoworkBridge-Sync.lnk'
        # Chien de garde : tâche planifiée per-user (sans admin) — logon + toutes les heures,
        # relance l'agent s'il ne tourne plus (l'agent est mono-instance via mutex). Un simple
        # raccourci Démarrage ne relançait pas un agent tué en cours de session. Repli .lnk si
        # la création de tâche est bloquée (GPO).
        $task = $false
        try {
            # Identité via WindowsIdentity : donne le principal correct sur AzureAD/MSA/domaine
            # (« AzureAD\user », « MACHINE\user »…), là où $env:USERDOMAIN\$env:USERNAME échoue à
            # résoudre le SID sur les comptes AzureAD. Durée de répétition FINIE (10 ans) plutôt que
            # [TimeSpan]::MaxValue, rejeté sur les hôtes plus anciens.
            $me = ([Security.Principal.WindowsIdentity]::GetCurrent()).Name
            $action  = New-ScheduledTaskAction -Execute $ps -Argument $argLine
            $trigLog = New-ScheduledTaskTrigger -AtLogOn -User $me
            $trigRep = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5) -RepetitionInterval (New-TimeSpan -Hours 1) -RepetitionDuration (New-TimeSpan -Days 3650)
            # ExecutionTimeLimit 0 = illimité : l'agent est résident, la limite par défaut (72 h) le tuerait
            $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero)
            Register-ScheduledTask -TaskName $script:WatchdogTaskName -Action $action -Trigger @($trigLog, $trigRep) -Settings $set -Force | Out-Null
            $task = $true
            if (Test-Path -LiteralPath $lnk) { Remove-Item -LiteralPath $lnk -Force -ErrorAction SilentlyContinue }
        } catch { Write-Log "Watchdog task not registered, falling back to Startup shortcut: $($_.Exception.Message)" 'WARN' }
        if (-not $task) {
            $wsh = New-Object -ComObject WScript.Shell
            $sc = $wsh.CreateShortcut($lnk)
            $sc.TargetPath  = $ps
            $sc.Arguments   = $argLine
            $sc.WindowStyle = 7
            $sc.Description  = 'Cowork Bridge - sync agent'
            $sc.Save()
        }
        try { Start-Process -FilePath $ps -ArgumentList $argLine -WindowStyle Hidden | Out-Null } catch {}
        return $true
    } catch {
        Write-Log "Sync agent not installed: $($_.Exception.Message)" 'WARN'
        return $false
    }
}

function Remove-SyncAgent {
    try { Unregister-ScheduledTask -TaskName $script:WatchdogTaskName -Confirm:$false -ErrorAction SilentlyContinue } catch {}
    $lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'CoworkBridge-Sync.lnk'
    if (Test-Path $lnk) { Remove-Item $lnk -Force }
    foreach ($pat in @('*sync-agent.ps1*', '*sync-loop.ps1*')) {
        try {
            Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
                Where-Object { $_.CommandLine -and $_.CommandLine -like $pat } |
                ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        } catch {}
    }
}

# Nettoyage des anciens mécanismes (FreeFileSync / tâche planifiée / ancien raccourci RTS)
function Remove-LegacyArtifacts {
    try { Unregister-ScheduledTask -TaskName $script:OldTaskName -Confirm:$false -ErrorAction SilentlyContinue } catch {}
    $oldRts = Join-Path ([Environment]::GetFolderPath('Startup')) 'CoworkBridge.lnk'
    if (Test-Path $oldRts) { Remove-Item $oldRts -Force -ErrorAction SilentlyContinue }
    try { Get-Process RealTimeSync -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue } catch {}
}

# ----------------------------------------------------------------------------
# Config (etat persistant) + paires
# ----------------------------------------------------------------------------
function Save-Config { param([object]$Config, [string]$Dest)
    $meta = Get-MetaDir $Dest
    if (-not (Test-Path $meta)) { New-Item -ItemType Directory -Path $meta -Force | Out-Null }
    $Config | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $meta 'config.json') -Encoding UTF8
}
function Load-Config { param([string]$Dest)
    $f = Join-Path (Get-MetaDir $Dest) 'config.json'
    if (Test-Path $f) { return (Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json) }
    return $null
}

function Build-Pairs { param([object[]]$Selected, [string]$Dest)
    $pairs = New-Object System.Collections.Generic.List[object]
    $used  = New-Object System.Collections.Generic.HashSet[string]
    foreach ($s in ($Selected | Sort-Object Type, Name)) {
        $persisted = $null
        if (($s.PSObject.Properties.Name -contains 'LocalName') -and $s.LocalName) { $persisted = [string]$s.LocalName }
        if ($persisted) {
            $localName = ($persisted -replace '[\\/:*?"<>|]', '_')
            [void]$used.Add($localName.ToLowerInvariant())
        } else {
            $prefix = if ($s.Type -eq 'Shared') { 'Partage - ' } else { '' }
            $base   = ($prefix + $s.Name) -replace '[\\/:*?"<>|]', '_'
            $localName = $base
            $n = 2
            while (-not $used.Add($localName.ToLowerInvariant())) { $localName = "$base ($n)"; $n++ }
        }
        $localPath = Join-Path $Dest $localName
        $pairs.Add([pscustomobject]@{ Source = $s; Drive = $s.Path; Local = $localPath; LocalName = $localName })
    }
    return $pairs
}

function Resolve-LocalName([object]$Source) {
    $raw = $null
    if (($Source.PSObject.Properties.Name -contains 'LocalName') -and $Source.LocalName) {
        $raw = [string]$Source.LocalName
    } else {
        $prefix = if ($Source.Type -eq 'Shared') { 'Partage - ' } else { '' }
        $raw = $prefix + [string]$Source.Name
    }
    return ($raw -replace '[\\/:*?"<>|]', '_')
}

function Get-SortedSources([object]$Config) {
    if ($Config -and ($Config.PSObject.Properties.Name -contains 'sources') -and $Config.sources) {
        return @($Config.sources) | Sort-Object Type, Name
    }
    return @()
}

# Garantit que dest/interval existent (config partielle ou éditée à la main) -> évite
# les exceptions StrictMode sur les accès .dest/.interval dans le panneau et les opérations.
function Normalize-Config([object]$Config) {
    if (-not $Config) { return $null }
    if (-not ($Config.PSObject.Properties.Name -contains 'dest') -or -not $Config.dest) {
        $Config | Add-Member -NotePropertyName dest -NotePropertyValue $script:DefaultDest -Force
    }
    if (-not ($Config.PSObject.Properties.Name -contains 'interval') -or -not $Config.interval) {
        $Config | Add-Member -NotePropertyName interval -NotePropertyValue $script:DefaultInterval -Force
    }
    return $Config
}

# ----------------------------------------------------------------------------
# Application d'une configuration (install initiale, ajout, désync : factorisé)
# ----------------------------------------------------------------------------
function Apply-Config {
    param(
        [object[]]$Selected, [string]$Dest, [int]$IntervalMin,
        [object]$Rclone, [scriptblock]$Status
    )
    $say = { param($m) if ($Status) { & $Status $m } }
    if (-not (Test-UnderHome $Dest)) { throw "Working folder is outside the user folder: $Dest" }
    & $say 'Preparing folders...'
    if (-not (Test-Path $Dest)) { New-Item -ItemType Directory -Path $Dest -Force | Out-Null }
    $meta = Get-MetaDir $Dest
    if (-not (Test-Path $meta)) { New-Item -ItemType Directory -Path $meta -Force | Out-Null }
    $script:LogFile = Join-Path $meta 'bridge.log'
    Write-Log "=== Apply: $($Selected.Count) folder(s) ==="

    $pairs = Build-Pairs -Selected $Selected -Dest $Dest
    foreach ($p in $pairs) {
        if (-not (Test-Path -LiteralPath $p.Local)) { New-Item -ItemType Directory -Path $p.Local -Force | Out-Null }
        Set-Marker $p.Local    # marqueur --check-access côté local
        Set-Marker $p.Drive    # et côté Drive (sa présence prouve que le dossier est monté)
        Write-Log "Pair: $($p.Drive)  <->  $($p.Local)"
    }

    & $say 'Generating configuration...'
    # Agent stoppé AVANT le swap des filtres et la première synchro : une passe en vol (lancée
    # avec l'ancien filters.txt) réécrirait ses index derrière Reset-PairIndexes, et le prochain
    # passage lirait un index qui ne correspond plus aux filtres en vigueur.
    # try/finally : l'agent est TOUJOURS réinstallé, même si une étape lève (sinon la machine
    # resterait sans synchro de fond ni watchdog jusqu'à réouverture manuelle).
    Remove-LegacyArtifacts
    Remove-SyncAgent
    $codes = @()
    $hasAgent = $false
    try {
        $null = Remove-LegacyBisyncState $meta
        if (New-FiltersFile (Join-Path $meta 'filters.txt')) { Reset-PairIndexes $meta }

        Save-Config -Dest $Dest -Config ([pscustomobject]@{
            version   = 2
            engine    = 'rclone'
            dest      = $Dest
            interval  = $IntervalMin
            sources   = @($pairs | ForEach-Object { @{ Type = $_.Source.Type; Name = $_.Source.Name; Path = $_.Source.Path; LocalName = $_.LocalName } })
            installed = (Get-Date -Format 's')
        })

        & $say 'First sync (may take a while for a large folder)...'
        # Sans index, chaque paire commence par une descente seule : le Drive peuple le dossier
        # de travail, et rien ne remonte tant qu'on ne sait pas ce qui vient d'où.
        foreach ($p in $pairs) {
            $codes += Sync-Pair -Rclone $Rclone -DrivePath $p.Drive -LocalPath $p.Local -MetaDir $meta -LocalName $p.LocalName
        }
    } finally {
        & $say 'Installation de la synchronisation automatique...'
        $hasAgent = Set-SyncAgent -RcloneExe $Rclone.Exe -MetaDir $meta -IntervalMin $IntervalMin
    }

    # Sévérité (pas max numérique) : « Drive absent » (90) ne masque pas une erreur rclone réelle.
    return [pscustomobject]@{ ExitCode = (Merge-SyncCodes $codes); Agent = $hasAgent }
}

# Désynchroniser un dossier : remonte son contenu vers Drive (copie seule, sans
# suppression), puis envoie la copie locale à la corbeille, puis régénère.
function Remove-TrackedFolder {
    param([object]$Config, [object]$Source, [object]$Rclone)
    $Config = Normalize-Config $Config
    if (-not (Test-UnderHome $Config.dest)) {
        Show-Warn("Working folder is outside your user folder - operation cancelled for safety.")
        return $false
    }
    $meta = Get-MetaDir $Config.dest
    $script:LogFile = Join-Path $meta 'bridge.log'
    $local = Join-Path $Config.dest (Resolve-LocalName $Source)

    # Valider les chemins AVANT de couper l'agent : un throw d'Assert-SafePath ici ne laisse
    # pas la machine sans agent (l'agent n'est stoppé qu'ensuite).
    Assert-SafePath $Source.Path
    if (Test-Path -LiteralPath $local) { Assert-SafePath $local }
    $remaining = @(Get-SortedSources $Config | Where-Object { $_.Path -ne $Source.Path })
    $agentHandled = $false

    # Agent stoppé pendant la désync (copie + recyclage) : sinon un tick scannerait un local à
    # moitié vidé et propagerait des suppressions. finally garantit qu'il repart toujours.
    Remove-SyncAgent
    try {
        if (Test-Path -LiteralPath $local) {
            $log = Join-Path $meta 'rclone.log'
            # Filtre de désync = volatile seulement : les dossiers dev (.git, node_modules...) qui
            # n'existaient que localement REPARTENT sur Drive (sinon ils finiraient à la corbeille).
            $filters = New-DesyncFilterFile $meta
            Assert-SafePath $filters
            # --filter-from (flag global rclone) et PAS --filters-file (propre à bisync). PAS de
            # --local-no-check-updated : sur ce chemin copie-puis-recyclage on VEUT l'abort si un
            # fichier est en cours d'écriture (sinon on pousserait un tronqué puis on supprime le bon).
            $argLine = @('copy', ('"{0}"' -f $local), ('"{0}"' -f $Source.Path),
                '--filter-from', ('"{0}"' -f $filters),
                '--checkers', '1', '--transfers', '4', '--local-no-preallocate',
                '--log-file', ('"{0}"' -f $log)) + $script:RcloneLogFlags
            $argLine = $argLine -join ' '
            $pushed = $false
            try {
                $p = Start-Process -FilePath $Rclone.Exe -ArgumentList $argLine -WindowStyle Hidden -PassThru -Wait
                $pushed = ([int]$p.ExitCode -eq 0)
                Write-Log "Unsync: copy local->Drive of '$($Source.Name)', code $($p.ExitCode)"
            } catch { Write-Log "Unsync: upload failed: $($_.Exception.Message)" 'WARN' }
            if (-not $pushed) {
                Show-Warn("The upload to Google Drive did not complete. For safety, the local copy is NOT deleted (no data lost).")
                return $false   # le finally relance l'agent
            }
            try { Remove-ToRecycleBin $local } catch { Write-Log "Unsync: recycle bin failed: $local ($($_.Exception.Message))" 'WARN' }
        }

        # État de la paire retirée : les deux index et le statut (-LiteralPath : [ ] possibles)
        $ln = Resolve-LocalName $Source
        foreach ($f in @((Get-PairIndexPath $meta $ln 'local'),
                         (Get-PairIndexPath $meta $ln 'drive'),
                         (Join-Path (Join-Path $meta 'status') ($ln + '.json')))) {
            if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
        }

        if ($remaining.Count -eq 0) {
            Remove-LegacyArtifacts   # 0 dossier restant : aucun agent voulu
            Save-Config -Dest $Config.dest -Config ([pscustomobject]@{
                version = 2; engine = 'rclone'; dest = $Config.dest; interval = [int]$Config.interval
                sources = @(); installed = (Get-Date -Format 's')
            })
            $agentHandled = $true
            return $true
        }
        $agentHandled = $true   # Apply-Config (ci-dessous) réinstalle l'agent dans son propre finally,
        Apply-Config -Selected $remaining -Dest $Config.dest -IntervalMin ([int]$Config.interval) -Rclone $Rclone -Status $null | Out-Null
        return $true
    } finally {
        # Sortie anticipée (échec remontée) ou exception : ne jamais laisser la machine sans agent.
        if (-not $agentHandled) { Set-SyncAgent -RcloneExe $Rclone.Exe -MetaDir $meta -IntervalMin ([int]$Config.interval) | Out-Null }
    }
}

# ----------------------------------------------------------------------------
# Migration d'une ancienne install FreeFileSync (config v1) vers le moteur rclone (v2).
# Déclenchée au lancement : sans elle, un client FFS qui s'auto-update hérite de RealTimeSync
# encore actif + des fichiers d'état .ffs_* volatils qui cassent rclone (cas réel : Dylan).
# ----------------------------------------------------------------------------
function Test-NeedsMigration([object]$Config) {
    if (-not $Config) { return $false }
    if (-not ($Config.PSObject.Properties.Name -contains 'engine')) { return $true }
    return ($Config.engine -ne 'rclone')
}

# Supprime les fichiers d'état FreeFileSync côté local (+ _bridge). Ne touche JAMAIS au Drive
# (les éventuels .ffs_db restés côté Drive sont simplement exclus par les filtres). RealTimeSync
# doit avoir été arrêté avant (Remove-LegacyArtifacts), sinon il les régénère.
function Remove-FfsArtifacts {
    param([string]$Dest, [object[]]$Sources)
    $meta = Get-MetaDir $Dest
    foreach ($pat in @('*.ffs_batch', '*.ffs_real', '*ffs_db*', '*.ffs_lock', '*.ffs_tmp')) {
        try { Get-ChildItem -Path $meta -Filter $pat -Force -ErrorAction SilentlyContinue |
                Where-Object { -not $_.PSIsContainer } | Remove-Item -Force -ErrorAction SilentlyContinue } catch {}
    }
    foreach ($s in $Sources) {
        $local = Join-Path $Dest (Resolve-LocalName $s)
        if (-not (Test-Path $local)) { continue }
        foreach ($pat in @('*ffs_db*', '*.ffs_lock', '*.ffs_tmp')) {
            try { Get-ChildItem -Path $local -Filter $pat -Recurse -Force -ErrorAction SilentlyContinue |
                    Where-Object { -not $_.PSIsContainer } | Remove-Item -Force -ErrorAction SilentlyContinue } catch {}
        }
    }
}

# Sources legacy -> sources v2, dédupliquées par Path (premier gagné -> tue le doublon FFS).
function Get-MigratedSources([object]$Config) {
    # Dédup par Path, DÉTERMINISTE : pour un même Path on garde la source dont le LocalName n'a PAS
    # de suffixe « (N) » (la copie primaire), sinon le plus court. Évite l'ordre instable de
    # Sort-Object Type,Name (qui orphelinait la primaire au profit de « ... (2) »).
    # Préférence : une source AVEC LocalName, puis le LocalName le plus COURT (un dup « X (2) » est
    # toujours plus long que sa primaire « X »). Pas de regex de suffixe : un dossier nommé
    # légitimement « ... (2024) » la trompait. Le 100000 sépare deux tiers (LocalName < MAX_PATH).
    $rank = {
        param($src)
        $ln = if (($src.PSObject.Properties.Name -contains 'LocalName') -and $src.LocalName) { [string]$src.LocalName } else { '' }
        $noLocal = if ($ln) { 0 } else { 1 }
        return ($noLocal * 100000 + $ln.Length)
    }
    $best = @{}
    foreach ($s in (Get-SortedSources $Config)) {
        if (-not ($s.PSObject.Properties.Name -contains 'Path') -or -not $s.Path) { continue }
        $key = ([string]$s.Path).ToLowerInvariant()
        if ((-not $best.ContainsKey($key)) -or ((& $rank $s) -lt (& $rank $best[$key]))) { $best[$key] = $s }
    }
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($s in ($best.Values | Sort-Object { [string]$_.Path })) {
        $type = if (($s.PSObject.Properties.Name -contains 'Type') -and $s.Type) { [string]$s.Type } else { Get-SourceType ([string]$s.Path) }
        $name = if (($s.PSObject.Properties.Name -contains 'Name') -and $s.Name) { [string]$s.Name } else { Split-Path ([string]$s.Path) -Leaf }
        $o = [pscustomobject]@{ Type = $type; Name = $name; Path = [string]$s.Path }
        if (($s.PSObject.Properties.Name -contains 'LocalName') -and $s.LocalName) {
            $o | Add-Member -NotePropertyName LocalName -NotePropertyValue ([string]$s.LocalName) -Force
        }
        $out.Add($o)
    }
    return $out.ToArray()
}

# Bascule complète FFS -> rclone : arrêt de l'ancien moteur, purge des fichiers d'état FFS,
# puis ré-application en rclone (baseline --resync, filtres FFS-exclus, agent). Idempotente :
# une fois la config en engine=rclone, Test-NeedsMigration renvoie $false.
function Invoke-LegacyMigration {
    param([object]$Config, [object]$Rclone, [scriptblock]$Status)
    $say = { param($m) if ($Status) { & $Status $m } }
    $Config = Normalize-Config $Config
    $dest = $Config.dest
    $meta = Get-MetaDir $dest
    if (-not (Test-Path $meta)) { New-Item -ItemType Directory -Path $meta -Force | Out-Null }
    $script:LogFile = Join-Path $meta 'bridge.log'
    Write-Log "=== Migration FreeFileSync -> rclone ==="

    if (-not (Test-UnderHome $dest)) {
        Show-Warn("Working folder is outside your user folder - migration cancelled for safety.")
        return $false
    }

    & $say 'Stopping the old sync engine...'
    Remove-LegacyArtifacts   # stoppe RealTimeSync + retire tâche/raccourci FFS
    Remove-SyncAgent

    $sources = @(Get-MigratedSources $Config)   # @() : garde un tableau même à 0/1 élément
    & $say 'Cleaning up old sync files...'
    Remove-FfsArtifacts -Dest $dest -Sources $sources

    if ($sources.Count -eq 0) {
        $null = New-FiltersFile (Join-Path $meta 'filters.txt')
        Save-Config -Dest $dest -Config ([pscustomobject]@{
            version = 2; engine = 'rclone'; dest = $dest; interval = [int]$Config.interval
            sources = @(); installed = (Get-Date -Format 's')
        })
        Write-Log "Migration: no usable source, empty v2 config written."
        return $true
    }

    & $say 'Switching to the new engine (may take a moment)...'
    # Apply-Config réécrit config.json en v2, pose marqueurs et filtres (FFS exclus), fait une
    # première passe (descente seule, faute d'index) et installe l'agent. Le local et le Drive
    # étaient déjà alignés par FFS, la descente n'a donc quasiment rien à faire.
    $res = Apply-Config -Selected $sources -Dest $dest -IntervalMin ([int]$Config.interval) -Rclone $Rclone -Status $Status
    Write-Log "Migration complete: $($sources.Count) folder(s) switched to rclone (first-sync code $($res.ExitCode))."
    # Un premier passage en échec laisse la paire sans index : le passage suivant refera une
    # descente seule, ce qui est le comportement sûr. L'agent résident reprend la main.
    if ([int]$res.ExitCode -ne 0) { Write-Log "Migration: first sync code $($res.ExitCode); the resident agent retries at the next pass." 'WARN' }
    return $true
}

# ----------------------------------------------------------------------------
# Sélecteur de dossier façon Explorateur (OpenFileDialog détourné, aucun fichier listé)
# ----------------------------------------------------------------------------
function Select-DriveFolder {
    param([string]$StartDir)
    $ofd = New-Object System.Windows.Forms.OpenFileDialog
    $ofd.Title           = 'Open the Google Drive folder to bridge, then click Open'
    $ofd.ValidateNames   = $false
    $ofd.CheckFileExists = $false
    $ofd.CheckPathExists = $true
    $ofd.Filter          = 'Dossier|*.cowork-bridge-none'
    $ofd.FileName        = 'Select this folder'
    if ($StartDir -and (Test-Path $StartDir)) { $ofd.InitialDirectory = $StartDir }
    if ($ofd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $dir = Split-Path -Path $ofd.FileName -Parent
        if ($dir -and (Test-Path $dir)) { return $dir }
    }
    return $null
}

function New-BrowsedSource {
    # $OnStatus (et pas $Status) : un callback de statut référence la variable $status (le Label) ;
    # PowerShell étant insensible à la casse, un param $Status le ferait résoudre sur CE scriptblock
    # (-> '<ScriptBlock>.Text' introuvable). Le nom distinct évite la collision.
    param([string]$Path, [long]$AlreadyUsedBytes, [string]$Dest, [scriptblock]$OnStatus)
    $say = { param($m) if ($OnStatus) { & $OnStatus $m } }
    & $say 'Calculating folder size...'
    $size = Get-FolderSizeBytes $Path
    $budget = Test-DiskBudget ($AlreadyUsedBytes + $size) $Dest
    if (-not $budget.Ok) {
        Show-Warn("Not enough disk space for this folder." + [Environment]::NewLine +
                  "This folder is approx $(Format-Size $size). Free disk space approx $(Format-Size $budget.Free)." + [Environment]::NewLine + [Environment]::NewLine +
                  "To avoid filling the disk (which can stop Windows from loading your session), choose a smaller folder, or free up space.")
        return $null
    }
    $leaf = Split-Path $Path -Leaf
    [pscustomobject]@{ Type = (Get-SourceType $Path); Name = $leaf; Path = $Path; SizeBytes = $size }
}

# ----------------------------------------------------------------------------
# GUI - choix des dossiers à la première installation (par l'explorateur)
# ----------------------------------------------------------------------------
function Show-SelectionDialog {
    param([string]$Dest, [int]$Interval, [string]$StartDir)

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "$script:AppName - Setup"
    $form.Size = New-Object System.Drawing.Size(620, 540)
    $form.StartPosition = 'CenterScreen'
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = "Choose the Google Drive folders to make available to Claude Cowork." + [Environment]::NewLine +
                "Click ""Add a folder"" and browse to the folder you want. Only the folders" + [Environment]::NewLine +
                "you add will take up space on this computer."
    $lbl.Location = New-Object System.Drawing.Point(15, 12)
    $lbl.Size = New-Object System.Drawing.Size(585, 56)
    $form.Controls.Add($lbl)

    $list = New-Object System.Windows.Forms.ListBox
    $list.Location = New-Object System.Drawing.Point(15, 74); $list.Size = New-Object System.Drawing.Size(575, 250)
    $list.IntegralHeight = $false; $list.HorizontalScrollbar = $true
    $form.Controls.Add($list)

    $script:selRows = New-Object System.Collections.Generic.List[object]
    $refresh = {
        $list.Items.Clear()
        foreach ($r in $script:selRows) {
            $tag = if ($r.Type -eq 'Shared') { '[Shared] ' } else { '[My Drive] ' }
            [void]$list.Items.Add($tag + $r.Name + '  —  ' + (Format-Size $r.SizeBytes))
        }
    }

    $btnAdd = New-Object System.Windows.Forms.Button
    $btnAdd.Text = 'Add a folder...'
    $btnAdd.Location = New-Object System.Drawing.Point(15, 330); $btnAdd.Size = New-Object System.Drawing.Size(200, 30)
    $form.Controls.Add($btnAdd)

    $btnRem = New-Object System.Windows.Forms.Button
    $btnRem.Text = 'Remove from list'
    $btnRem.Location = New-Object System.Drawing.Point(225, 330); $btnRem.Size = New-Object System.Drawing.Size(180, 30)
    $form.Controls.Add($btnRem)

    $lblDest = New-Object System.Windows.Forms.Label
    $lblDest.Text = 'Working folder (must stay inside your user folder):'
    $lblDest.Location = New-Object System.Drawing.Point(15, 372); $lblDest.Size = New-Object System.Drawing.Size(575, 18)
    $form.Controls.Add($lblDest)
    $txtDest = New-Object System.Windows.Forms.TextBox
    $txtDest.Text = $Dest
    $txtDest.Location = New-Object System.Drawing.Point(15, 392); $txtDest.Size = New-Object System.Drawing.Size(575, 24)
    $form.Controls.Add($txtDest)

    $lblInt = New-Object System.Windows.Forms.Label
    $lblInt.Text = 'Pull changes from Drive every (minutes):'
    $lblInt.Location = New-Object System.Drawing.Point(15, 424); $lblInt.Size = New-Object System.Drawing.Size(400, 22)
    $form.Controls.Add($lblInt)
    $numInt = New-Object System.Windows.Forms.NumericUpDown
    $numInt.Minimum = 1; $numInt.Maximum = 1440; $numInt.Value = $Interval
    $numInt.Location = New-Object System.Drawing.Point(420, 422); $numInt.Size = New-Object System.Drawing.Size(70, 24)
    $form.Controls.Add($numInt)

    $status = New-Object System.Windows.Forms.Label
    $status.Location = New-Object System.Drawing.Point(15, 452); $status.Size = New-Object System.Drawing.Size(575, 18)
    $status.ForeColor = [System.Drawing.Color]::DimGray
    $form.Controls.Add($status)
    $statusCb = { param($m) $status.Text = $m; $status.ForeColor = [System.Drawing.Color]::DimGray; $form.Refresh() }

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = 'Install'
    $btnOk.Location = New-Object System.Drawing.Point(410, 478); $btnOk.Size = New-Object System.Drawing.Size(95, 30)
    $form.Controls.Add($btnOk)
    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = 'Cancel'
    $btnCancel.Location = New-Object System.Drawing.Point(510, 478); $btnCancel.Size = New-Object System.Drawing.Size(80, 30)
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($btnCancel)
    $form.CancelButton = $btnCancel

    $script:DialogResult = $null

    $btnAdd.Add_Click({
        $used = [long]0
        foreach ($r in $script:selRows) { $used += [long]$r.SizeBytes }
        $p = Select-DriveFolder -StartDir $StartDir
        if (-not $p) { return }
        if ($script:selRows | Where-Object { $_.Path -eq $p }) { $statusCb.Invoke('This folder is already in the list.'); return }
        if (-not (Confirm-NoDuplicateLeaf -Sources $script:selRows -Path $p -Noun 'in the list')) { return }
        $src = New-BrowsedSource -Path $p -AlreadyUsedBytes ([long]$used) -Dest ($txtDest.Text.Trim()) -OnStatus $statusCb
        if ($src) { $script:selRows.Add($src); $refresh.Invoke(); $statusCb.Invoke('') }
    })
    $btnRem.Add_Click({
        $i = $list.SelectedIndex
        if ($i -ge 0 -and $i -lt $script:selRows.Count) { $script:selRows.RemoveAt($i); $refresh.Invoke() }
    })
    $btnOk.Add_Click({
        if ($script:selRows.Count -eq 0) { $statusCb.Invoke('Add at least one folder.'); $status.ForeColor = [System.Drawing.Color]::Firebrick; return }
        $d = $txtDest.Text.Trim()
        $ok = $false
        try {
            $dFull    = [System.IO.Path]::GetFullPath($d).TrimEnd('\')
            $homeFull = [System.IO.Path]::GetFullPath($script:HomeRoot).TrimEnd('\')
            $ok = $dFull.Equals($homeFull, [System.StringComparison]::OrdinalIgnoreCase) -or
                  $dFull.StartsWith($homeFull + '\', [System.StringComparison]::OrdinalIgnoreCase)
        } catch { $ok = $false }
        if (-not $ok) { $statusCb.Invoke("The folder must be inside: $script:HomeRoot"); $status.ForeColor = [System.Drawing.Color]::Firebrick; return }
        $script:DialogResult = [pscustomobject]@{
            Selected = @($script:selRows | ForEach-Object { [pscustomobject]@{ Type = $_.Type; Name = $_.Name; Path = $_.Path } })
            Dest     = ([System.IO.Path]::GetFullPath($d).TrimEnd('\'))
            Interval = [int]$numInt.Value
        }
        $form.Close()
    })

    [void]$form.ShowDialog()
    return $script:DialogResult
}

# ----------------------------------------------------------------------------
# GUI - panneau de gestion = centre de contrôle
# ----------------------------------------------------------------------------
function Show-ManageDialog {
    param([object]$Config, [object]$Rclone)

    $Config = Normalize-Config $Config
    $script:mgConfig = $Config
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "$script:AppName - Manage"
    $form.Size = New-Object System.Drawing.Size(560, 540)
    $form.StartPosition = 'CenterScreen'
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Location = New-Object System.Drawing.Point(20, 14); $lbl.Size = New-Object System.Drawing.Size(510, 58)
    $form.Controls.Add($lbl)

    $lblList = New-Object System.Windows.Forms.Label
    $lblList.Text = 'Folders synced by Cowork Bridge:'
    $lblList.Location = New-Object System.Drawing.Point(20, 76); $lblList.Size = New-Object System.Drawing.Size(510, 18)
    $form.Controls.Add($lblList)
    $list = New-Object System.Windows.Forms.ListBox
    $list.Location = New-Object System.Drawing.Point(20, 96); $list.Size = New-Object System.Drawing.Size(510, 110)
    $list.IntegralHeight = $false; $list.HorizontalScrollbar = $true
    $form.Controls.Add($list)

    $script:mgSources = @()
    $reload = {
        $reloaded = Load-Config -Dest $Config.dest
        if ($reloaded) { $script:mgConfig = Normalize-Config $reloaded }
        $script:mgSources = @(Get-SortedSources $script:mgConfig)
        $list.Items.Clear()
        foreach ($s in $script:mgSources) {
            $tag = if ($s.Type -eq 'Shared') { '[Shared] ' } else { '[My Drive] ' }
            [void]$list.Items.Add($tag + $s.Name)
        }
        $lbl.Text = "Cowork Bridge is running." + [Environment]::NewLine +
                    "Connect this in Cowork (and not the Google Drive folder):" + [Environment]::NewLine +
                    "$($script:mgConfig.dest)"
    }
    $reload.Invoke()

    $lblTimer = New-Object System.Windows.Forms.Label
    $lblTimer.Location = New-Object System.Drawing.Point(20, 212); $lblTimer.Size = New-Object System.Drawing.Size(510, 18)
    $lblTimer.ForeColor = [System.Drawing.Color]::DimGray
    $form.Controls.Add($lblTimer)

    $lblInt = New-Object System.Windows.Forms.Label
    $lblInt.Text = 'Sync from Drive every (min):'
    $lblInt.Location = New-Object System.Drawing.Point(20, 238); $lblInt.Size = New-Object System.Drawing.Size(270, 22)
    $form.Controls.Add($lblInt)
    $numInt = New-Object System.Windows.Forms.NumericUpDown
    $numInt.Minimum = 1; $numInt.Maximum = 1440; $numInt.Value = [int]$Config.interval
    $numInt.Location = New-Object System.Drawing.Point(295, 236); $numInt.Size = New-Object System.Drawing.Size(70, 24)
    $form.Controls.Add($numInt)
    $btnInt = New-Object System.Windows.Forms.Button
    $btnInt.Text = 'Apply'
    $btnInt.Location = New-Object System.Drawing.Point(375, 235); $btnInt.Size = New-Object System.Drawing.Size(155, 26)
    $form.Controls.Add($btnInt)

    $btnAdd = New-Object System.Windows.Forms.Button
    $btnAdd.Text = 'Add a folder'
    $btnAdd.Location = New-Object System.Drawing.Point(20, 272); $btnAdd.Size = New-Object System.Drawing.Size(245, 32)
    $form.Controls.Add($btnAdd)
    $btnDesync = New-Object System.Windows.Forms.Button
    $btnDesync.Text = 'Unsync the selected folder'
    $btnDesync.Location = New-Object System.Drawing.Point(285, 272); $btnDesync.Size = New-Object System.Drawing.Size(245, 32)
    $form.Controls.Add($btnDesync)

    $btnSync = New-Object System.Windows.Forms.Button
    $btnSync.Text = 'Sync now'
    $btnSync.Location = New-Object System.Drawing.Point(20, 310); $btnSync.Size = New-Object System.Drawing.Size(245, 32)
    $form.Controls.Add($btnSync)
    $btnOpen = New-Object System.Windows.Forms.Button
    $btnOpen.Text = 'Open the local folder'
    $btnOpen.Location = New-Object System.Drawing.Point(285, 310); $btnOpen.Size = New-Object System.Drawing.Size(245, 32)
    $form.Controls.Add($btnOpen)

    $btnUpdate = New-Object System.Windows.Forms.Button
    $btnUpdate.Text = 'Check for updates'
    $btnUpdate.Location = New-Object System.Drawing.Point(20, 348); $btnUpdate.Size = New-Object System.Drawing.Size(245, 32)
    $form.Controls.Add($btnUpdate)
    $btnUninstall = New-Object System.Windows.Forms.Button
    $btnUninstall.Text = 'Uninstall Cowork Bridge'
    $btnUninstall.Location = New-Object System.Drawing.Point(285, 348); $btnUninstall.Size = New-Object System.Drawing.Size(245, 32)
    $form.Controls.Add($btnUninstall)

    $status = New-Object System.Windows.Forms.Label
    $status.Location = New-Object System.Drawing.Point(20, 392); $status.Size = New-Object System.Drawing.Size(510, 56)
    $status.ForeColor = [System.Drawing.Color]::DimGray
    $form.Controls.Add($status)

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = 'Close'
    $btnClose.Location = New-Object System.Drawing.Point(440, 458); $btnClose.Size = New-Object System.Drawing.Size(90, 30)
    $btnClose.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.Controls.Add($btnClose)

    $nextFile = Join-Path (Get-MetaDir $Config.dest) 'next-sync'
    $script:mgTick = 0
    $script:mgHealth = $null
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 1000
    $timer.Add_Tick({
        $txt = 'Next sync: -'
        try {
            if (Test-Path $nextFile) {
                $next = [datetime]::Parse((Get-Content $nextFile -Raw).Trim())
                $rem = $next - (Get-Date)
                if ($rem.TotalSeconds -le 0) { $txt = 'Next sync: imminent' }
                else { $txt = 'Next sync in {0:mm\:ss}' -f $rem }
            }
        } catch {}
        # Santé réelle (status\<paire>.json écrits par l'agent). Recalcul ~1x/5 s seulement (les
        # valeurs changent en minutes) : sinon N parses JSON par seconde sur le thread UI. Le compte
        # à rebours, lui, reste à 1 s. Intervalle passé depuis mgConfig (pas de relecture disque).
        if (($script:mgTick % 5) -eq 0) {
            try { $script:mgHealth = Get-BridgeHealth -MetaDir (Get-MetaDir $script:mgConfig.dest) -Sources $script:mgSources -IntervalMin ([int]$script:mgConfig.interval) } catch {}
        }
        $script:mgTick++
        $health = $script:mgHealth
        # Grâce au démarrage (~15 s) : au boot, l'agent vient d'être relancé et n'a pas encore
        # écrit de statut -> ne pas alarmer avec « agent may be stopped » (verdict périmé, s'auto-corrige).
        if ($health -and $health.ContainsKey('Kind') -and $health.Kind -eq 'stale' -and $script:mgTick -le 15) { $health = $null }
        if ($health) {
            $lblTimer.Text = $txt + '   -   ' + $health.Text
            if ($health.Ok) { $lblTimer.ForeColor = [System.Drawing.Color]::DimGray }
            else            { $lblTimer.ForeColor = [System.Drawing.Color]::Firebrick }
        } else {
            $lblTimer.Text = $txt
            $lblTimer.ForeColor = [System.Drawing.Color]::DimGray
        }
    })
    $timer.Start()
    $form.Add_FormClosed({ $timer.Stop(); $timer.Dispose() })

    $busy = { param($m) $status.ForeColor = [System.Drawing.Color]::DimGray; $status.Text = $m; $form.Refresh() }

    $btnInt.Add_Click({
        $min = [int]$numInt.Value
        $meta = Get-MetaDir $script:mgConfig.dest
        Set-IntervalFile -MetaDir $meta -IntervalMin $min
        try { [System.IO.File]::WriteAllText((Join-Path $meta 'next-sync'), (Get-Date).AddMinutes($min).ToString('o'), (New-Object System.Text.UTF8Encoding($false))) } catch {}
        $cfg = $script:mgConfig; $cfg.interval = $min; Save-Config -Dest $cfg.dest -Config $cfg
        $busy.Invoke("Interval updated: every $min min.")
    })
    $btnAdd.Add_Click({
        $start = Get-DriveRoot
        $p = Select-DriveFolder -StartDir $start
        if (-not $p) { return }
        if ($script:mgSources | Where-Object { $_.Path -eq $p }) { $busy.Invoke('This folder is already tracked.'); return }
        if (-not (Confirm-NoDuplicateLeaf -Sources $script:mgSources -Path $p -Noun 'tracked')) { $busy.Invoke(''); return }
        $busy.Invoke('Calculating size...')
        $src = New-BrowsedSource -Path $p -AlreadyUsedBytes ([long]0) -Dest $script:mgConfig.dest -OnStatus $busy
        if (-not $src) { $busy.Invoke(''); return }
        $busy.Invoke('Adding and syncing...')
        $newSel = @($script:mgSources | ForEach-Object { [pscustomobject]@{ Type = $_.Type; Name = $_.Name; Path = $_.Path } }) + @([pscustomobject]@{ Type = $src.Type; Name = $src.Name; Path = $src.Path })
        try {
            $res = Apply-Config -Selected $newSel -Dest $script:mgConfig.dest -IntervalMin ([int]$script:mgConfig.interval) -Rclone $Rclone -Status $null
            $reload.Invoke()
            $busy.Invoke((Get-SyncResultText ([int]$res.ExitCode)))
        } catch { $busy.Invoke("Adding failed: $($_.Exception.Message)") }
    })
    $btnDesync.Add_Click({
        $i = $list.SelectedIndex
        if ($i -lt 0 -or $i -ge $script:mgSources.Count) { $busy.Invoke('Select a folder in the list first.'); return }
        $src = $script:mgSources[$i]
        $m = "Unsync $($src.Name)?" + [Environment]::NewLine + [Environment]::NewLine +
             "Its contents are first sent back to Google Drive, then the local copy goes" + [Environment]::NewLine +
             "to the Recycle Bin. Nothing is deleted on the Drive side."
        if (-not (Confirm-YesNo $m)) { return }
        $busy.Invoke('Uploading to Drive then freeing space...')
        try {
            if (Remove-TrackedFolder -Config $script:mgConfig -Source $src -Rclone $Rclone) {
                $reload.Invoke(); $busy.Invoke("$($src.Name) is no longer synced.")
            }
        } catch { $busy.Invoke("Unsync failed: $($_.Exception.Message)") }
    })
    $btnSync.Add_Click({
        $busy.Invoke('Syncing...')
        try {
            $codes = @()
            foreach ($s in $script:mgSources) {
                $local = Join-Path $script:mgConfig.dest (Resolve-LocalName $s)
                if (-not (Test-Path -LiteralPath $local)) { continue }
                # Même passe que l'agent : il n'y a plus de mode manuel à part, puisqu'il n'y a
                # plus d'état à débloquer. Sévérité : 90 ne masque pas une erreur rclone réelle.
                $codes += Sync-Pair -Rclone $Rclone -DrivePath $s.Path -LocalPath $local -MetaDir (Get-MetaDir $script:mgConfig.dest) -LocalName (Resolve-LocalName $s)
            }
            $busy.Invoke((Get-SyncResultText (Merge-SyncCodes $codes)))
        } catch { $busy.Invoke("Sync could not start: $($_.Exception.Message)") }
    })
    $btnOpen.Add_Click({ Start-Process explorer.exe -ArgumentList ('"{0}"' -f $script:mgConfig.dest) })
    $btnUpdate.Add_Click({ if (Invoke-UpdateCheck -Interactive) { $form.Close() } })
    $btnUninstall.Add_Click({ $form.Close(); Invoke-Uninstall -Config $script:mgConfig })

    [void]$form.ShowDialog()
}

# ----------------------------------------------------------------------------
# Flux principal
# ----------------------------------------------------------------------------
function Show-Info($msg)  { [void][System.Windows.Forms.MessageBox]::Show($msg, $script:AppName, 'OK', 'Information') }
function Show-Warn($msg)  { [void][System.Windows.Forms.MessageBox]::Show($msg, $script:AppName, 'OK', 'Warning') }
function Confirm-YesNo($msg) { return ([System.Windows.Forms.MessageBox]::Show($msg, $script:AppName, 'YesNo', 'Question') -eq 'Yes') }

# Garde anti-doublon « même nom + type, chemin différent » (typiquement un montage Drive
# qui a changé de lettre). Retourne $true si on peut ajouter : aucun homonyme, ou l'utilisateur
# confirme malgré le doublon probable. $false = abandon. $Noun adapte le message selon le flux.
function Confirm-NoDuplicateLeaf {
    param([object[]]$Sources, [string]$Path, [string]$Noun)
    $leaf = Split-Path $Path -Leaf
    $type = Get-SourceType $Path
    if ($Sources | Where-Object { $_.Name -eq $leaf -and $_.Type -eq $type }) {
        return (Confirm-YesNo("A folder named ""$leaf"" is already $Noun." + [Environment]::NewLine +
            "It may be the same one (the Google Drive path can change)." + [Environment]::NewLine +
            "Add it anyway?"))
    }
    return $true
}

function Start-Bridge {
    if (Invoke-UpdateCheck) { return }

    $rclone = Find-Rclone
    if (-not $rclone) {
        Show-Warn("The sync engine (rclone) could not be found next to the app." + [Environment]::NewLine +
                  "Reinstall Cowork Bridge from the official installer.")
        return
    }

    # Installation existante -> centre de contrôle
    $existing = Normalize-Config (Load-Config -Dest $script:DefaultDest)

    # Ancienne install FreeFileSync (config v1) -> bascule transparente vers rclone.
    if (Test-NeedsMigration $existing) {
        $mig = New-Object System.Windows.Forms.Form
        $mig.Text = "$script:AppName"; $mig.Size = New-Object System.Drawing.Size(480, 130)
        $mig.StartPosition = 'CenterScreen'; $mig.ControlBox = $false
        $mig.Font = New-Object System.Drawing.Font('Segoe UI', 9)
        $ml = New-Object System.Windows.Forms.Label
        $ml.Location = New-Object System.Drawing.Point(20, 30); $ml.Size = New-Object System.Drawing.Size(440, 60)
        $ml.Text = 'Updating the sync engine...'
        $mig.Controls.Add($ml); $mig.Show(); $mig.Refresh()
        $migCb = { param($m) $ml.Text = $m; $mig.Refresh() }
        try {
            Invoke-LegacyMigration -Config $existing -Rclone $rclone -Status $migCb
        } catch {
            Write-Log "ERREUR migration: $($_.Exception.Message)" 'ERROR'
            Show-Warn("The engine update ran into a problem:" + [Environment]::NewLine +
                      $($_.Exception.Message) + [Environment]::NewLine + [Environment]::NewLine +
                      "No data is lost. You can restart Cowork Bridge.")
        } finally {
            if ($mig.Visible) { $mig.Close() }
        }
        $existing = Normalize-Config (Load-Config -Dest $script:DefaultDest)
    }

    if ($existing -and @(Get-SortedSources $existing).Count -gt 0) {
        # Rafraîchit la config de synchro au lancement : un upgrade binaire ne relance pas Apply-Config,
        # donc filters.txt ET l'agent résident garderaient l'ancien jeu (anciennes exclusions, pas de
        # throttle --checkers). On régénère les deux ici pour qu'un client mis à jour en bénéficie.
        # Filtres modifiés -> baselines invalidées : bisync hash le filters-file et abort
        # « filters file has changed (must run --resync) » sinon ; le resync 'newer' repart proprement.
        # Agent stoppé AVANT le swap (un bisync en vol recréerait sa baseline derrière le reset).
        # try/finally : l'agent est TOUJOURS réinstallé, même si le swap/re-pose de marqueurs lève
        # (sinon on aurait tué l'agent sans le relancer -> plus de synchro de fond jusqu'à réouverture).
        if (Test-UnderHome $existing.dest) {
            $rm = Get-MetaDir $existing.dest
            Remove-SyncAgent
            try {
                $null = Remove-LegacyBisyncState $rm
                if (New-FiltersFile (Join-Path $rm 'filters.txt')) { Reset-PairIndexes $rm }
                # Re-pose les marqueurs --check-access (un client peut avoir supprimé ce fichier
                # « inconnu » via Drive web -> échec permanent sinon). Côté Drive : seulement si le
                # dossier a du contenu — un dossier vu vide peut être une projection défaillante,
                # y re-poser le marqueur désarmerait le garde anti-suppression massive.
                foreach ($s in @(Get-SortedSources $existing)) {
                    Set-Marker (Join-Path $existing.dest (Resolve-LocalName $s))
                    try {
                        if ((Test-Path -LiteralPath $s.Path) -and
                            @(Get-ChildItem -LiteralPath $s.Path -Force -ErrorAction SilentlyContinue | Select-Object -First 1).Count -gt 0) { Set-Marker $s.Path }
                    } catch {}
                }
            } catch {} finally {
                Set-SyncAgent -RcloneExe $rclone.Exe -MetaDir $rm -IntervalMin ([int]$existing.interval) | Out-Null
            }
        }
        Show-ManageDialog -Config $existing -Rclone $rclone
        return
    }

    # Première installation : choix des dossiers par l'explorateur
    $start = Get-DriveRoot
    if (-not $start) {
        $m = "No Google Drive folder detected on this computer." + [Environment]::NewLine + [Environment]::NewLine +
             "Check that Google Drive for desktop is running, signed in, and set to" + [Environment]::NewLine +
             """Stream files"" (Settings -> Preferences -> Google Drive folder)." + [Environment]::NewLine +
             "You can still continue and browse manually."
        Show-Warn $m
    }
    $choice = Show-SelectionDialog -Dest $script:DefaultDest -Interval $script:DefaultInterval -StartDir $start
    if (-not $choice) { return }

    $progress = New-Object System.Windows.Forms.Form
    $progress.Text = "$script:AppName"; $progress.Size = New-Object System.Drawing.Size(470, 130)
    $progress.StartPosition = 'CenterScreen'; $progress.ControlBox = $false
    $progress.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $pl = New-Object System.Windows.Forms.Label
    $pl.Location = New-Object System.Drawing.Point(20, 30); $pl.Size = New-Object System.Drawing.Size(420, 60); $pl.Text = 'Installing...'
    $progress.Controls.Add($pl); $progress.Show(); $progress.Refresh()
    $statusCb = { param($m) $pl.Text = $m; $progress.Refresh() }

    try {
        $res = Apply-Config -Selected $choice.Selected -Dest $choice.Dest -IntervalMin $choice.Interval -Rclone $rclone -Status $statusCb
        $progress.Close()
        $auto = if ($res.Agent) {
            "Syncing now runs on its own in the background:" + [Environment]::NewLine +
            "  - your changes go to Google Drive almost instantly;" + [Environment]::NewLine +
            "  - changes from Drive are pulled in every $($choice.Interval) min."
        } else {
            "Automatic sync could not be installed - see the guide (troubleshooting)."
        }
        $msg = "Setup complete." + [Environment]::NewLine + [Environment]::NewLine +
               "Last step, in Claude Cowork: connect the folder below -" + [Environment]::NewLine +
               "and not your Google Drive folder:" + [Environment]::NewLine + [Environment]::NewLine +
               "   $($choice.Dest)" + [Environment]::NewLine + [Environment]::NewLine +
               "If Cowork shows an empty folder, it almost always means the Google Drive" + [Environment]::NewLine +
               "folder was connected instead of this one." + [Environment]::NewLine + [Environment]::NewLine +
               $auto + [Environment]::NewLine + [Environment]::NewLine +
               (Get-SyncResultText ([int]$res.ExitCode))
        Show-Info $msg
    } catch {
        if ($progress.Visible) { $progress.Close() }
        Write-Log "ERREUR installation: $($_.Exception.Message)" 'ERROR'
        Show-Warn("Setup failed:" + [Environment]::NewLine + $($_.Exception.Message))
    }
}

function Invoke-Uninstall {
    param([object]$Config)
    $m = "Uninstall Cowork Bridge?" + [Environment]::NewLine + [Environment]::NewLine +
         "Automatic sync is removed. Your local folder is NOT deleted" + [Environment]::NewLine +
         "(you can delete it by hand to reclaim space). No file is lost."
    if (-not (Confirm-YesNo $m)) { return }
    $script:LogFile = Join-Path (Get-MetaDir $Config.dest) 'bridge.log'
    Remove-SyncAgent
    Remove-LegacyArtifacts
    Show-Info("Cowork Bridge is uninstalled (automatic sync removed)." + [Environment]::NewLine +
              "Your local folder is kept: $($Config.dest)")
}

# ----------------------------------------------------------------------------
if (-not $LibraryOnly) {
    try { Start-Bridge }
    catch { [void][System.Windows.Forms.MessageBox]::Show(("Unexpected error:" + [Environment]::NewLine + $($_.Exception.Message)), $script:AppName, 'OK', 'Error') }
}
