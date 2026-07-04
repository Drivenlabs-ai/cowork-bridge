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
        --max-delete 25, --conflict-resolve none (garde les 2 versions),
        --backup-dir local daté (équivalent corbeille) + corbeille Drive native,
        --resilient --recover --max-lock 2m, rotation du journal rclone.log.
      - Observabilité : statut par paire dans _bridge\status\<nom>.json (agent +
        panneau) ; le panneau affiche l'état réel de la dernière synchro.

    Sécurité disque : avant d'ajouter un dossier, on vérifie qu'il tient sur C:
    avec une marge (sinon remplir le profil empêche Windows de l'ouvrir).

    Lancer via Run-CoworkBridge.bat (-STA -ExecutionPolicy Bypass). UTF-8 AVEC BOM.
#>

#requires -version 5.1
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

# Drapeaux bisync statiques (sûreté + perf + log) : SOURCE UNIQUE, partagée mot pour
# mot entre Get-BisyncArgLine (installeur) et l'agent résident (sérialisée dans sync-agent.ps1
# à la génération). Tokens littéraux uniquement, aucune valeur par-run. Modifier ici = les deux suivent.
$script:BisyncSafetyFlags   = @('--max-delete', '25', '--conflict-resolve', 'none')
# --local-no-preallocate : la préallocation Windows de rclone arrondit la taille au secteur ; la
# projection Google Drive Desktop rapporte alors la taille préallouée (octets NULL en fin) -> abort
# « corrupted on transfer: sizes differ » (rclone #3207, flag officiel v1.55). --local-no-check-updated :
# un placeholder qui s'hydrate pendant la lecture change de stat apparent -> « can't copy - source file
# is being updated », non retryable ; le run suivant + backup-dir couvrent le vrai fichier en cours
# d'écriture. --checkers 1 : énumération sérialisée pour ménager le pool noyau de la projection Cloud
# Files (ERROR 1450) ; --transfers reste à 4 (le débit de copie ne joue pas sur l'énumération).
# --retries-sleep : espace les retries internes bisync (défaut 0 = immédiat).
$script:BisyncPerfFlags     = @('--checkers', '1', '--transfers', '4', '--local-no-preallocate', '--local-no-check-updated', '--retries-sleep', '30s', '--resilient', '--recover', '--max-lock', '2m')
# Rotation intégrée rclone (v1.71+) : borne rclone.log (journal uniquement — aucune limite
# sur les fichiers synchronisés). Sans elle, croissance infinie dans le profil (risque C: plein).
$script:BisyncLogFlags      = @('--log-level', 'INFO', '--log-file-max-size', '5M', '--log-file-max-backups', '2')

# Code de sortie SYNTHÉTIQUE « côté Drive non monté » : hors de la plage rclone (0-10, dont 9 =
# --error-on-no-transfer) pour éviter toute collision. N'est PAS un échec (ni succès) : neutre.
$script:CodeDriveMissing = 90
# Seuils de tuning de la récupération : SOURCE UNIQUE, sérialisés dans l'agent (comme les flags).
# Modifier ici = installeur ET agent suivent. Éviter la dérive entre « Sync now » et le fond.
$script:RecoveryGateHours    = 24   # 1 auto-resync / 1 auto-force max par paire et par fenêtre
$script:RecoveryConsecutive  = 2    # nb d'échecs critiques consécutifs avant d'armer une récupération
$script:FailThrottle         = 3    # au-delà : la paire n'est plus tentée que sur tick d'intervalle

# Filtres de synchro, en DEUX groupes source-unique :
#  - Volatile = éphémère qui casse la sync (verrous, temp, états FFS) : exclu partout, sync ET désync.
#  - Dir = artefacts dev (.git, node_modules...) : exclu de la SYNC seulement. À la désync on les REND
#    au Drive (ils n'existent que localement) avant de recycler le local, sinon on les perdrait.
$script:VolatileFilterLines = @(
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

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic
[System.Windows.Forms.Application]::EnableVisualStyles()

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
        default { 'The sync ran into a problem. Try "Sync now" again. If it persists, open the local folder -> _bridge\rclone.log, or contact your Drivenlabs contact.' }
    }
}

# Agrège les codes d'une passe multi-paires par SÉVÉRITÉ (pas par max numérique : 90 « Drive
# absent » ne doit pas masquer un abort réel 1/7). Une vraie erreur domine ; 90 seul sinon ; 0.
function Merge-SyncCodes([int[]]$Codes) {
    $realErr = 0
    $missing = $false
    foreach ($c in $Codes) {
        if ($c -eq 0) { continue }
        elseif ($c -eq $script:CodeDriveMissing) { $missing = $true }
        elseif ($c -gt $realErr) { $realErr = $c }
    }
    if ($realErr -ne 0) { return $realErr }
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
    # Retourne $true si le contenu change (fichier absent ou différent) : bisync hash le
    # filters-file (<filters>.md5) et abort « filters file has changed (must run --resync) »
    # à chaque run sinon -> l'appelant doit alors invalider les baselines (Reset-PairBaselines).
    # Skip si identique : pas d'écriture, pas de churn.
    try { if ((Test-Path $Path) -and ([System.IO.File]::ReadAllText($Path) -eq $content)) { return $false } } catch {}
    # Écriture atomique : l'agent résident peut lire filters.txt en plein bisync (--filters-file).
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
    $lines = @($script:VolatileFilterLines) + @("- $script:MarkerName")
    $content = ($lines -join "`r`n")
    $path = Join-Path $MetaDir 'desync-filter.txt'
    [System.IO.File]::WriteAllText($path, $content, (New-Object System.Text.UTF8Encoding($false)))
    return $path
}

# Invalide la baseline de toutes les paires : bisync exige un --resync quand le contenu du
# filters-file a changé. Baseline absente -> le prochain passage (agent ou Sync now) fait
# --resync --resync-mode newer (union, la version la plus récente gagne, rien de supprimé),
# ce qui réécrit aussi le .md5 du filters-file. Purge aussi les jetons de récupération.
function Reset-PairBaselines([string]$MetaDir) {
    $stateDir = Join-Path $MetaDir 'bisync-state'
    if (-not (Test-Path -LiteralPath $stateDir)) { return }
    Get-ChildItem -LiteralPath $stateDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like '*.synced' -or $_.Name -like '*.resync-pending' -or $_.Name -like '*.force-pending' } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

# Marqueur d'accès (--check-access) : sa présence des deux côtés prouve que le dossier
# est bien monté/hydraté. S'il manque (Drive non monté, dossier vu vide), bisync abort.
function Set-Marker([string]$Folder) {
    try {
        $f = Join-Path $Folder $script:MarkerName
        if (-not (Test-Path -LiteralPath $f)) {
            [System.IO.File]::WriteAllText($f, "Cowork Bridge - marqueur d'acces, ne pas supprimer.", (New-Object System.Text.UTF8Encoding($false)))
        }
    } catch {}
}

# Construit la ligne d'arguments rclone bisync pour une paire (chemins entre guillemets ;
# Assert-SafePath garantit qu'aucun chemin ne contient de guillemet -> pas d'évasion).
function Get-BisyncArgLine {
    param([string]$DrivePath, [string]$LocalPath, [string]$MetaDir, [string]$LocalName, [bool]$Resync, [bool]$Force)
    Assert-SafePath $DrivePath; Assert-SafePath $LocalPath; Assert-SafePath $MetaDir
    $workdir = Join-Path $MetaDir 'bisync-state'
    $filters = Join-Path $MetaDir 'filters.txt'
    $backup  = Join-Path (Join-Path $MetaDir 'trash') ((Get-Date -Format 'yyyy-MM-dd') + '\' + $LocalName)
    $log     = Join-Path $MetaDir 'rclone.log'
    $q = { param($s) '"{0}"' -f $s }
    $parts = @(
        'bisync', (& $q $DrivePath), (& $q $LocalPath),
        '--workdir', (& $q $workdir),
        '--filters-file', (& $q $filters),
        '--check-access', '--check-filename', $script:MarkerName
    ) + $script:BisyncSafetyFlags + @(
        '--backup-dir2', (& $q $backup)
    ) + $script:BisyncPerfFlags + @(   # concurrence basse (rclone.org : baisser --checkers sur backend lent) ; valeur à valider sur Windows
        '--log-file', (& $q $log)
    ) + $script:BisyncLogFlags
    # 'newer' : resync en union (jamais de suppression), la version la plus récente gagne.
    # Premier run d'une paire : le local vient d'être créé (vide) -> équivalent « Drive fait foi » ;
    # récupération (filtres changés, abort critique) : préserve l'édition locale la plus récente.
    if ($Resync) { $parts += @('--resync', '--resync-mode', 'newer') }
    # --force = assumer un run dont les suppressions dépassent --max-delete (réorganisation
    # Cowork réelle, confirmée par 2 signaux consécutifs). No-op s'il n'y a pas d'excès.
    elseif ($Force) { $parts += '--force' }
    return ($parts -join ' ')
}

# Lance une synchro bisync sur une paire. Retourne le code de sortie rclone (0 = ok).
function Invoke-Bisync {
    param([string]$RcloneExe, [string]$DrivePath, [string]$LocalPath, [string]$MetaDir, [string]$LocalName, [bool]$Resync, [bool]$Force)
    $argLine = Get-BisyncArgLine -DrivePath $DrivePath -LocalPath $LocalPath -MetaDir $MetaDir -LocalName $LocalName -Resync $Resync -Force $Force
    $p = Start-Process -FilePath $RcloneExe -ArgumentList $argLine -WindowStyle Hidden -PassThru -Wait
    Write-Log "bisync '$LocalName' (resync=$Resync force=$Force) code $($p.ExitCode)"
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

function Write-SyncStatus([string]$MetaDir, [string]$LocalName, [int]$Code, [bool]$MarkAutoResync = $false, [bool]$MarkAutoForce = $false, [bool]$DeleteSignal = $false) {
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
        # faux rouge au boot, pas de blocage FSW). Succès -> 0 ; vraie erreur -> +1.
        $failures = [int](Get-StatusField $old 'failures' 0)
        if ($Code -eq 0) { $lastSuccess = $now; $failures = 0 }
        elseif ($Code -eq $script:CodeDriveMissing) { }
        else { $failures = $failures + 1 }
        $lastAuto = Get-StatusField $old 'lastAutoResync' $null
        if ($lastAuto -is [datetime]) { $lastAuto = $lastAuto.ToString('o') }
        if ($MarkAutoResync) { $lastAuto = $now }
        # deleteAborts = signaux « too many deletes » consécutifs (remis à 0 dès qu'un run n'en émet pas)
        $deleteAborts = 0
        if ($DeleteSignal) { $deleteAborts = 1 + [int](Get-StatusField $old 'deleteAborts' 0) }
        $lastForce = Get-StatusField $old 'lastAutoForce' $null
        if ($lastForce -is [datetime]) { $lastForce = $lastForce.ToString('o') }
        if ($MarkAutoForce) { $lastForce = $now }
        $st = [pscustomobject]@{
            name = $LocalName; lastRun = $now; lastExit = $Code
            lastSuccess = $lastSuccess; failures = $failures; lastAutoResync = $lastAuto
            deleteAborts = $deleteAborts; lastAutoForce = $lastForce
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

# Longueur actuelle de rclone.log (offset à capturer AVANT un run) : 0 si absent.
function Get-LogOffset([string]$MetaDir) {
    try {
        $log = Join-Path $MetaDir 'rclone.log'
        if (Test-Path -LiteralPath $log) { return (Get-Item -LiteralPath $log).Length }
    } catch {}
    return [long]0
}

# Détecte l'abort « too many deletes » (garde --max-delete) du run qui vient de s'achever : il sort
# en exit 1 (jamais 7, vérifié source rclone) -> indétectable par le code seul. On ne scanne QUE les
# octets ajoutés par CE run (de $FromOffset à la fin), donc strictement par paire (log partagé) et
# insensible à la rotation (si le fichier a rétréci, on repart de 0). Le motif texte reste fragile
# (dépend du libellé rclone) -> à confirmer sur Windows. Faux positif bénin : --force sans excès = no-op.
function Test-MaxDeleteSignal([string]$MetaDir, [long]$FromOffset) {
    try {
        $log = Join-Path $MetaDir 'rclone.log'
        if (-not (Test-Path -LiteralPath $log)) { return $false }
        $fs = [System.IO.File]::Open($log, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $start = $FromOffset
            if ($start -gt $fs.Length -or $start -lt 0) { $start = 0 }   # rotation -> nouveau fichier
            # Région démesurée = rotation en plein run puis re-croissance (l'offset ne veut plus rien
            # dire) : borne au dernier Mo. L'abort « too many deletes » est émis en fin de run -> la
            # queue le capture, et la mémoire reste bornée.
            $cap = [long]1MB
            if (($fs.Length - $start) -gt $cap) { $start = $fs.Length - $cap }
            $len = [int]($fs.Length - $start)
            if ($len -le 0) { return $false }
            [void]$fs.Seek($start, [System.IO.SeekOrigin]::Begin)
            $buf = New-Object byte[] $len
            $read = 0
            while ($read -lt $len) {
                $n = $fs.Read($buf, $read, $len - $read)
                if ($n -le 0) { break }
                $read += $n
            }
        } finally { $fs.Close() }
        $txt = [System.Text.Encoding]::UTF8.GetString($buf, 0, $read)
        return ($txt -match 'too many deletes')
    } catch {}
    return $false
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
        } elseif ($fails -ge $script:RecoveryConsecutive) {
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
    if ($missing)  { return @{ Ok = $false; Text = 'waiting for Google Drive to start' } }
    if ($retrying) { return @{ Ok = $false; Text = 'syncing (retrying)...' } }
    if ($oldestOk) { return @{ Ok = $true;  Text = ('last sync OK ({0})' -f (Format-Ago $oldestOk)) } }
    return $null
}

# Synchronise une paire en gérant sa baseline : --resync si la paire n'a jamais été
# synchronisée (marqueur absent) ou si un jeton de récupération est posé, sinon bisync
# normal. Marqueur posé après un run à 0. Une paire neuve SANS --resync sort en erreur.
# Récupération : exit 7 = abort critique bisync (« Must run --resync to recover ») -> jeton
# one-shot .resync-pending, au plus 1 fois par 24 h (pas de tempête de resyncs). Le jeton est
# consommé que le resync réussisse ou non. Exit 1 + signal « too many deletes » -> jeton
# one-shot .force-pending (mêmes gardes). Même logique dans l'agent (Run-All).
function Sync-Pair {
    param([object]$Rclone, [string]$DrivePath, [string]$LocalPath, [string]$MetaDir, [string]$LocalName, [bool]$ForceResync, [bool]$Manual)
    $stateDir = Join-Path $MetaDir 'bisync-state'
    if (-not (Test-Path -LiteralPath $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }
    # Côté Drive absent (Drive Desktop pas monté / démarré) : pas de run -> pas d'exit 7 transitoire
    # ni de jeton injustifié. Code sentinelle « Drive absent » (neutre, message ciblé au panneau).
    if (-not (Test-Path -LiteralPath $DrivePath)) {
        Write-SyncStatus -MetaDir $MetaDir -LocalName $LocalName -Code $script:CodeDriveMissing -MarkAutoResync $false
        return $script:CodeDriveMissing
    }
    # -LiteralPath sur tout chemin dérivé de LocalName : [ ] y sont légaux mais globbent en PowerShell
    $pairState  = Join-Path $stateDir ($LocalName + '.synced')
    $pending    = Join-Path $stateDir ($LocalName + '.resync-pending')
    $forceTok   = Join-Path $stateDir ($LocalName + '.force-pending')
    $offset = Get-LogOffset $MetaDir

    # « Sync now » manuel = override humain : escalade INLINE sans passer par les jetons ni les
    # gates 24 h/consécutif (le clic EST la confirmation). Un run ; si abort critique -> resync ;
    # si too-many-deletes -> force ; on rend le code final tout de suite, débloque un état coincé.
    if ($Manual) {
        $resync = $ForceResync -or -not (Test-Path -LiteralPath $pairState)
        $code = Invoke-Bisync -RcloneExe $Rclone.Exe -DrivePath $DrivePath -LocalPath $LocalPath -MetaDir $MetaDir -LocalName $LocalName -Resync $resync -Force $false
        if ($code -eq 7 -and -not $resync) {
            $code = Invoke-Bisync -RcloneExe $Rclone.Exe -DrivePath $DrivePath -LocalPath $LocalPath -MetaDir $MetaDir -LocalName $LocalName -Resync $true -Force $false
        } elseif ($code -eq 1 -and (Test-MaxDeleteSignal -MetaDir $MetaDir -FromOffset $offset)) {
            $code = Invoke-Bisync -RcloneExe $Rclone.Exe -DrivePath $DrivePath -LocalPath $LocalPath -MetaDir $MetaDir -LocalName $LocalName -Resync $false -Force $true
        }
        if ($code -eq 0) {
            New-Item -ItemType File -Path $pairState -Force | Out-Null
            # État résolu : d'éventuels jetons armés par l'agent sont moot -> évite un double run.
            Remove-Item -LiteralPath $pending -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $forceTok -Force -ErrorAction SilentlyContinue
        }
        Write-SyncStatus -MetaDir $MetaDir -LocalName $LocalName -Code $code
        return $code
    }

    # Chemin automatique (Apply-Config, agent) : jetons + gates anti-tempête.
    $hadPending = Test-Path -LiteralPath $pending
    $hadForce   = Test-Path -LiteralPath $forceTok
    $resync  = $ForceResync -or $hadPending -or -not (Test-Path -LiteralPath $pairState)
    $useForce = ($hadForce -and -not $resync)
    $code = Invoke-Bisync -RcloneExe $Rclone.Exe -DrivePath $DrivePath -LocalPath $LocalPath -MetaDir $MetaDir -LocalName $LocalName -Resync $resync -Force $useForce
    if ($hadPending) { Remove-Item -LiteralPath $pending -Force -ErrorAction SilentlyContinue }
    # Jeton force conservé si un resync a pris le pas (il n'a PAS été appliqué) -> il servira au run suivant.
    if ($useForce)   { Remove-Item -LiteralPath $forceTok -Force -ErrorAction SilentlyContinue }
    $mark = $false; $markForce = $false; $delSig = $false
    if ($code -eq 0) {
        New-Item -ItemType File -Path $pairState -Force | Out-Null
    } elseif ($code -eq 7 -and -not $hadPending -and (Test-Path -LiteralPath $pairState)) {
        # Armer au Ne exit 7 CONSÉCUTIF seulement : une collision de verrou ponctuelle
        # (Sync now + agent sur la même paire, --max-lock) ne déclenche pas de resync injustifié.
        $prev  = Read-SyncStatus -MetaDir $MetaDir -LocalName $LocalName
        $again = ([int](Get-StatusField $prev 'lastExit' 0) -eq 7)
        $last  = Get-StatusField $prev 'lastAutoResync' $null
        $ok24  = $true
        if ($last) { try { $ok24 = ((Get-Date) - [datetime]$last).TotalHours -ge $script:RecoveryGateHours } catch {} }
        if ($again -and $ok24) { New-Item -ItemType File -Path $pending -Force | Out-Null; $mark = $true }
    } elseif ($code -eq 1 -and -not $useForce) {
        # « too many deletes » (réorganisation Cowork : déplacement = suppression + création).
        # Armé au Ne signal consécutif (un glitch de projection fluctue, une réorganisation
        # persiste) ; suppressions récupérables : corbeille Drive + backup-dir2 local. 1x/fenêtre.
        $delSig = Test-MaxDeleteSignal -MetaDir $MetaDir -FromOffset $offset
        if ($delSig) {
            $prev  = Read-SyncStatus -MetaDir $MetaDir -LocalName $LocalName
            $lastF = Get-StatusField $prev 'lastAutoForce' $null
            $okF   = $true
            if ($lastF) { try { $okF = ((Get-Date) - [datetime]$lastF).TotalHours -ge $script:RecoveryGateHours } catch {} }
            if (([int](Get-StatusField $prev 'deleteAborts' 0) -ge ($script:RecoveryConsecutive - 1)) -and $okF) {
                New-Item -ItemType File -Path $forceTok -Force | Out-Null; $markForce = $true
            }
        }
    }
    Write-SyncStatus -MetaDir $MetaDir -LocalName $LocalName -Code $code -MarkAutoResync $mark -MarkAutoForce $markForce -DeleteSignal $delSig
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
        # Mêmes drapeaux statiques que Get-BisyncArgLine, sérialisés en littéraux PowerShell
        # ('flag', 'flag', ...) interpolés DANS le here-string (bare $, à la génération) — pas
        # d'escape backtick : ces tokens ne contiennent ni $ ni guillemet (constantes internes).
        $safetyLit = ($script:BisyncSafetyFlags | ForEach-Object { "'$_'" }) -join ', '
        $perfLit   = ($script:BisyncPerfFlags   | ForEach-Object { "'$_'" }) -join ', '
        $logLit    = ($script:BisyncLogFlags    | ForEach-Object { "'$_'" }) -join ', '
        # Constantes de tuning : SOURCE UNIQUE, interpolées en littéraux numériques dans l'agent
        # (bare $, à la génération) -> l'installeur et l'agent ne peuvent plus diverger sur ces seuils.
        $codeMissingLit = [int]$script:CodeDriveMissing
        $gateHoursLit   = [int]$script:RecoveryGateHours
        $consecLit      = [int]$script:RecoveryConsecutive
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

# Longueur de rclone.log (offset a capturer AVANT un run) : 0 si absent.
function Get-LogOffset {
    try {
        `$log = Join-Path `$meta 'rclone.log'
        if (Test-Path -LiteralPath `$log) { return (Get-Item -LiteralPath `$log).Length }
    } catch {}
    return [long]0
}

# Abort « too many deletes » (garde --max-delete) : sort en exit 1 -> indetectable par le code
# seul. On scanne UNIQUEMENT les octets ajoutes par CE run (de `$fromOffset a la fin) : strictement
# par paire malgre le log partage, insensible a la rotation (fichier retreci -> depuis 0). Motif
# texte fragile (libelle rclone) -> a confirmer sur Windows. Faux positif benin : --force = no-op.
function Test-MaxDelete([long]`$fromOffset) {
    try {
        `$log = Join-Path `$meta 'rclone.log'
        if (-not (Test-Path -LiteralPath `$log)) { return `$false }
        `$fs = [System.IO.File]::Open(`$log, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            `$start = `$fromOffset
            if (`$start -gt `$fs.Length -or `$start -lt 0) { `$start = 0 }
            # region demesuree = rotation en plein run puis re-croissance : borne au dernier Mo
            # (l'abort est emis en fin de run -> la queue le capture ; memoire bornee)
            `$cap = [long]1MB
            if ((`$fs.Length - `$start) -gt `$cap) { `$start = `$fs.Length - `$cap }
            `$len = [int](`$fs.Length - `$start)
            if (`$len -le 0) { return `$false }
            [void]`$fs.Seek(`$start, [System.IO.SeekOrigin]::Begin)
            `$buf = New-Object byte[] `$len
            `$read = 0
            while (`$read -lt `$len) {
                `$n = `$fs.Read(`$buf, `$read, `$len - `$read)
                if (`$n -le 0) { break }
                `$read += `$n
            }
        } finally { `$fs.Close() }
        `$txt = [System.Text.Encoding]::UTF8.GetString(`$buf, 0, `$read)
        return (`$txt -match 'too many deletes')
    } catch {}
    return `$false
}

function Run-All {
    param([bool]`$Due)
    `$stateDir = Join-Path `$meta 'bisync-state'
    if (-not (Test-Path -LiteralPath `$stateDir)) { New-Item -ItemType Directory -Path `$stateDir -Force | Out-Null }
    foreach (`$p in (Read-Pairs)) {
        # -LiteralPath sur tout chemin derive du nom de paire ([ ] legaux mais globbent en PowerShell)
        # Paire en echec repete : cadence intervalle seulement (pas de retry sur evenement FSW) --
        # sinon une synchro qui echoue en boucle rescanne la projection dos a dos (pression 1450)
        `$fails = [int](Get-Field (Read-Status `$p.Name) 'failures' 0)
        if (-not `$Due -and `$fails -ge $throttleLit) { continue }
        # Un cote absent (Drive pas encore monte au boot, dossier local supprime) : pas de run ->
        # pas d'exit 7 transitoire ni de jeton injustifie ; sentinelle Drive absent (neutre au panneau)
        if (-not (Test-Path -LiteralPath `$p.Local) -or -not (Test-Path -LiteralPath `$p.Drive)) { Write-Status `$p.Name $codeMissingLit `$false `$false `$false; continue }
        `$filters    = Join-Path `$meta 'filters.txt'
        `$backup     = Join-Path (Join-Path `$meta 'trash') ((Get-Date -Format 'yyyy-MM-dd') + '\' + `$p.Name)
        `$log        = Join-Path `$meta 'rclone.log'
        `$pairState  = Join-Path `$stateDir (`$p.Name + '.synced')
        `$pending    = Join-Path `$stateDir (`$p.Name + '.resync-pending')
        `$forceTok   = Join-Path `$stateDir (`$p.Name + '.force-pending')
        `$hadPending = Test-Path -LiteralPath `$pending
        `$hadForce   = Test-Path -LiteralPath `$forceTok
        `$argLine = @('bisync', ('"{0}"' -f `$p.Drive), ('"{0}"' -f `$p.Local),
            '--workdir', ('"{0}"' -f `$stateDir), '--filters-file', ('"{0}"' -f `$filters),
            '--check-access', '--check-filename', `$marker, $safetyLit,
            '--backup-dir2', ('"{0}"' -f `$backup), $perfLit,
            '--log-file', ('"{0}"' -f `$log), $logLit)
        # 'newer' : union, la version la plus recente gagne (premier run : local vide -> Drive fait foi)
        `$doResync = (`$hadPending -or -not (Test-Path -LiteralPath `$pairState))
        `$useForce = (`$hadForce -and -not `$doResync)
        if (`$doResync) { `$argLine += @('--resync', '--resync-mode', 'newer') }
        elseif (`$useForce) { `$argLine += '--force' }
        `$argLine = `$argLine -join ' '
        `$offset = Get-LogOffset
        `$code = -1
        try {
            `$proc = Start-Process -FilePath `$rclone -ArgumentList `$argLine -WindowStyle Hidden -Wait -PassThru
            `$code = [int]`$proc.ExitCode
        } catch {}
        # jetons one-shot, consommes seulement si rclone a pu demarrer (code -1 = Start-Process a echoue).
        # Le jeton force est GARDE si un resync a pris le pas (--force pas applique) -> servira au run suivant.
        if (`$hadPending -and `$code -ne -1) { Remove-Item -LiteralPath `$pending -Force -ErrorAction SilentlyContinue }
        if (`$useForce -and `$code -ne -1)   { Remove-Item -LiteralPath `$forceTok -Force -ErrorAction SilentlyContinue }
        `$markResync = `$false; `$markForce = `$false; `$delSig = `$false
        if (`$code -eq 0) {
            New-Item -ItemType File -Path `$pairState -Force | Out-Null
        } elseif (`$code -eq 7 -and -not `$hadPending -and (Test-Path -LiteralPath `$pairState)) {
            # exit 7 = abort critique bisync (Must run --resync to recover) -> resync de recuperation,
            # arme au Ne exit 7 CONSECUTIF (une collision de verrou ponctuelle ne declenche rien),
            # au plus 1 fois par fenetre (pas de tempete de resyncs)
            `$prev  = Read-Status `$p.Name
            `$again = ([int](Get-Field `$prev 'lastExit' 0) -eq 7)
            `$last  = Get-Field `$prev 'lastAutoResync' `$null
            `$ok24  = `$true
            if (`$last) { try { `$ok24 = ((Get-Date) - [datetime]`$last).TotalHours -ge $gateHoursLit } catch {} }
            if (`$again -and `$ok24) {
                New-Item -ItemType File -Path `$pending -Force | Out-Null
                `$markResync = `$true
            }
        } elseif (`$code -eq 1 -and -not `$useForce) {
            # too many deletes (reorganisation Cowork : deplacement = suppression + creation).
            # Arme au Ne signal consecutif (un glitch de projection fluctue, une reorganisation
            # persiste) ; suppressions recuperables (corbeille Drive + backup-dir2). 1x/fenetre.
            `$delSig = Test-MaxDelete `$offset
            if (`$delSig) {
                `$prev  = Read-Status `$p.Name
                `$lastF = Get-Field `$prev 'lastAutoForce' `$null
                `$okF   = `$true
                if (`$lastF) { try { `$okF = ((Get-Date) - [datetime]`$lastF).TotalHours -ge $gateHoursLit } catch {} }
                if (([int](Get-Field `$prev 'deleteAborts' 0) -ge ($consecLit - 1)) -and `$okF) {
                    New-Item -ItemType File -Path `$forceTok -Force | Out-Null
                    `$markForce = `$true
                }
            }
        }
        Write-Status `$p.Name `$code `$markResync `$markForce `$delSig
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
        [object]$Rclone, [bool]$FirstRun, [scriptblock]$Status
    )
    $say = { param($m) if ($Status) { & $Status $m } }
    if (-not (Test-UnderHome $Dest)) { throw "Working folder is outside the user folder: $Dest" }
    & $say 'Preparing folders...'
    if (-not (Test-Path $Dest)) { New-Item -ItemType Directory -Path $Dest -Force | Out-Null }
    $meta = Get-MetaDir $Dest
    if (-not (Test-Path $meta)) { New-Item -ItemType Directory -Path $meta -Force | Out-Null }
    $script:LogFile = Join-Path $meta 'bridge.log'
    Write-Log "=== Apply: $($Selected.Count) folder(s), FirstRun=$FirstRun ==="

    $pairs = Build-Pairs -Selected $Selected -Dest $Dest
    foreach ($p in $pairs) {
        if (-not (Test-Path -LiteralPath $p.Local)) { New-Item -ItemType Directory -Path $p.Local -Force | Out-Null }
        Set-Marker $p.Local    # marqueur --check-access côté local
        Set-Marker $p.Drive    # et côté Drive (sa présence prouve que le dossier est monté)
        Write-Log "Pair: $($p.Drive)  <->  $($p.Local)"
    }

    & $say 'Generating configuration...'
    # Agent stoppé AVANT le swap des filtres et la première synchro : un bisync en vol (lancé
    # avec l'ancien filters.txt) recréerait sa baseline derrière Reset-PairBaselines et son
    # --resync réécrirait le .md5 global, contournant le garde « filters file has changed ».
    # try/finally : l'agent est TOUJOURS réinstallé, même si une étape lève (sinon la machine
    # resterait sans synchro de fond ni watchdog jusqu'à réouverture manuelle).
    Remove-LegacyArtifacts
    Remove-SyncAgent
    $codes = @()
    $hasAgent = $false
    try {
        if (New-FiltersFile (Join-Path $meta 'filters.txt')) { Reset-PairBaselines $meta }

        Save-Config -Dest $Dest -Config ([pscustomobject]@{
            version   = 2
            engine    = 'rclone'
            dest      = $Dest
            interval  = $IntervalMin
            sources   = @($pairs | ForEach-Object { @{ Type = $_.Source.Type; Name = $_.Source.Name; Path = $_.Source.Path; LocalName = $_.LocalName } })
            installed = (Get-Date -Format 's')
        })

        & $say 'First sync (may take a while for a large folder)...'
        # Baseline gérée PAR PAIRE par Sync-Pair (un dossier ajouté plus tard a besoin de
        # SON propre --resync, sinon bisync sort en erreur).
        foreach ($p in $pairs) {
            $codes += Sync-Pair -Rclone $Rclone -DrivePath $p.Drive -LocalPath $p.Local -MetaDir $meta -LocalName $p.LocalName -ForceResync $FirstRun -Manual $false
        }
    } finally {
        & $say 'Installation de la synchronisation automatique...'
        $hasAgent = Set-SyncAgent -RcloneExe $Rclone.Exe -MetaDir $meta -IntervalMin $IntervalMin
    }

    # Sévérité (pas max numérique) : « Drive absent » (90) ne masque pas un abort réel 1/7.
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
                '--log-file', ('"{0}"' -f $log)) + $script:BisyncLogFlags
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

        # État de la paire retirée : baseline, jetons de récupération, statut (-LiteralPath : [ ] possibles)
        $ln = Resolve-LocalName $Source
        foreach ($f in @((Join-Path (Join-Path $meta 'bisync-state') ($ln + '.synced')),
                         (Join-Path (Join-Path $meta 'bisync-state') ($ln + '.resync-pending')),
                         (Join-Path (Join-Path $meta 'bisync-state') ($ln + '.force-pending')),
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
        Apply-Config -Selected $remaining -Dest $Config.dest -IntervalMin ([int]$Config.interval) -Rclone $Rclone -FirstRun $false -Status $null | Out-Null
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
    # Apply-Config réécrit config.json en v2, pose markers + filtres (FFS exclus), baseline
    # --resync 'newer' (local et Drive déjà alignés par FFS -> union quasi nulle, et une
    # édition locale plus récente que FFS n'avait pas poussée est préservée), installe l'agent.
    $res = Apply-Config -Selected $sources -Dest $dest -IntervalMin ([int]$Config.interval) -Rclone $Rclone -FirstRun $true -Status $Status
    Write-Log "Migration complete: $($sources.Count) folder(s) switched to rclone (first-sync code $($res.ExitCode))."
    if ([int]$res.ExitCode -ne 0) { Write-Log "Migration: first sync code $($res.ExitCode); the resident agent will retry resync until a baseline is set." 'WARN' }
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
            $res = Apply-Config -Selected $newSel -Dest $script:mgConfig.dest -IntervalMin ([int]$script:mgConfig.interval) -Rclone $Rclone -FirstRun $false -Status $null
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
                # -Manual : le clic humain débloque une paire coincée (escalade resync/force inline,
                # sans attendre les gates 24 h/consécutif). Sévérité : 90 ne masque pas un abort réel.
                $codes += Sync-Pair -Rclone $Rclone -DrivePath $s.Path -LocalPath $local -MetaDir (Get-MetaDir $script:mgConfig.dest) -LocalName (Resolve-LocalName $s) -ForceResync $false -Manual $true
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
                if (New-FiltersFile (Join-Path $rm 'filters.txt')) { Reset-PairBaselines $rm }
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
        $res = Apply-Config -Selected $choice.Selected -Dest $choice.Dest -IntervalMin $choice.Interval -Rclone $rclone -FirstRun $true -Status $statusCb
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
try { Start-Bridge }
catch { [void][System.Windows.Forms.MessageBox]::Show(("Unexpected error:" + [Environment]::NewLine + $($_.Exception.Message)), $script:AppName, 'OK', 'Error') }
