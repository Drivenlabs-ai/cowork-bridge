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
      - 1er run d'une paire = rclone bisync --resync --resync-mode path1 (Drive fait
        foi, union, jamais d'effacement Drive).
      - Sûreté : --check-access (marqueur .coworkbridge-ok des deux côtés),
        --max-delete 25, --conflict-resolve none (garde les 2 versions),
        --backup-dir local daté (équivalent corbeille) + corbeille Drive native,
        --resilient --recover --max-lock 2m.

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
$script:MarkerName  = '.coworkbridge-ok'         # marqueur --check-access (anti côté vide)
$script:DefaultInterval = 30
$script:DiskMarginBytes = [long]5 * 1GB          # laisser au moins ça de libre sur C:
$script:LogFile     = $null
$script:Repo        = 'Drivenlabs-ai/cowork-bridge'

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
        0       { 'Synchronisation terminée. Tout est à jour.' }
        default { 'La synchronisation a rencontré un problème. Relance « Synchroniser maintenant ». Si ça persiste, ouvre le dossier local → _bridge\rclone.log, ou contacte ton interlocuteur Drivenlabs.' }
    }
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
    if ($Path -match '[\r\n"]') { throw "Chemin invalide (caractère interdit) : $Path" }
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
    if ($b -ge 1GB) { return ('{0:N1} Go' -f ($b / 1GB)) }
    if ($b -ge 1MB) { return ('{0:N0} Mo' -f ($b / 1MB)) }
    return ('{0:N0} Ko' -f ($b / 1KB))
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
        if ($Interactive) { Show-Info("Version installée inconnue (cette copie n'a pas été posée par l'installeur). Récupère la dernière version sur la page des releases.") }
        return $false
    }
    $latest = Get-LatestRelease
    if (-not $latest) {
        if ($Interactive) { Show-Warn("Impossible de vérifier les mises à jour (pas de connexion, ou aucune version publiée).") }
        return $false
    }
    if ($latest.Version -le $installed) {
        if ($Interactive) { Show-Info("Cowork Bridge est à jour (version $installed).") }
        return $false
    }
    $m = "Une mise à jour est disponible." + [Environment]::NewLine +
         "Installée : $installed   →   Disponible : $($latest.Version)" + [Environment]::NewLine + [Environment]::NewLine +
         "L'installer maintenant ? Tes dossiers suivis et tes réglages sont conservés."
    if (-not (Confirm-YesNo $m)) { return $false }
    try {
        if (-not $latest.SumUrl) {
            Show-Warn("Mise à jour annulée : aucun checksum publié pour vérifier le téléchargement (sécurité).")
            return $false
        }
        $tmp = Join-Path $env:TEMP "CoworkBridge-Setup-$($latest.Tag).exe"
        Invoke-WebRequest -Uri $latest.ExeUrl -OutFile $tmp -UseBasicParsing -TimeoutSec 300
        $sumTxt   = (Invoke-WebRequest -Uri $latest.SumUrl -UseBasicParsing -TimeoutSec 60).Content
        $expected = (($sumTxt -split '\s+') | Where-Object { $_ } | Select-Object -First 1)
        if ($expected) { $expected = $expected.ToLower() }
        $actual   = (Get-FileHash $tmp -Algorithm SHA256).Hash.ToLower()
        if (-not $expected -or $expected -ne $actual) {
            Show-Warn("Mise à jour annulée : le téléchargement ne correspond pas au checksum attendu (sécurité).")
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
            return $false
        }
        # On NE retire PAS le mark-of-the-web : tant que l'exe n'est pas signé, on laisse
        # SmartScreen évaluer le binaire téléchargé (dernier filet côté utilisateur).
        Start-Process -FilePath $tmp
        return $true
    } catch {
        Show-Warn("La mise à jour a échoué : $($_.Exception.Message)")
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
    $lines = @(
        '- *.tmp'
        '- desktop.ini'
        '- thumbs.db'
        '- .tmp.drivedownload/'
        '- .tmp.driveupload/'
        '- *.ffs_db'
        '- sync.ffs_db*'
        '- *.ffs_lock'
        '- *.ffs_batch'
        '- *.ffs_real'
    )
    [System.IO.File]::WriteAllText($Path, ($lines -join "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
}

# Marqueur d'accès (--check-access) : sa présence des deux côtés prouve que le dossier
# est bien monté/hydraté. S'il manque (Drive non monté, dossier vu vide), bisync abort.
function Set-Marker([string]$Folder) {
    try {
        $f = Join-Path $Folder $script:MarkerName
        if (-not (Test-Path $f)) {
            [System.IO.File]::WriteAllText($f, "Cowork Bridge - marqueur d'acces, ne pas supprimer.", (New-Object System.Text.UTF8Encoding($false)))
        }
    } catch {}
}

# Construit la ligne d'arguments rclone bisync pour une paire (chemins entre guillemets ;
# Assert-SafePath garantit qu'aucun chemin ne contient de guillemet -> pas d'évasion).
function Get-BisyncArgLine {
    param([string]$DrivePath, [string]$LocalPath, [string]$MetaDir, [string]$LocalName, [bool]$Resync)
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
        '--check-access', '--check-filename', $script:MarkerName,
        '--max-delete', '25',
        '--conflict-resolve', 'none',
        '--backup-dir2', (& $q $backup),
        '--resilient', '--recover', '--max-lock', '2m',
        '--log-file', (& $q $log), '--log-level', 'INFO'
    )
    if ($Resync) { $parts += @('--resync', '--resync-mode', 'path1') }
    return ($parts -join ' ')
}

# Lance une synchro bisync sur une paire. Retourne le code de sortie rclone (0 = ok).
function Invoke-Bisync {
    param([string]$RcloneExe, [string]$DrivePath, [string]$LocalPath, [string]$MetaDir, [string]$LocalName, [bool]$Resync)
    $argLine = Get-BisyncArgLine -DrivePath $DrivePath -LocalPath $LocalPath -MetaDir $MetaDir -LocalName $LocalName -Resync $Resync
    $p = Start-Process -FilePath $RcloneExe -ArgumentList $argLine -WindowStyle Hidden -PassThru -Wait
    Write-Log "bisync '$LocalName' (resync=$Resync) code $($p.ExitCode)"
    return [int]$p.ExitCode
}

# Synchronise une paire en gérant sa baseline : --resync si la paire n'a jamais été
# synchronisée (marqueur absent), sinon bisync normal. Marqueur posé après un run à 0.
# Indispensable : une paire neuve SANS --resync fait sortir bisync en erreur.
function Sync-Pair {
    param([object]$Rclone, [string]$DrivePath, [string]$LocalPath, [string]$MetaDir, [string]$LocalName, [bool]$ForceResync)
    $stateDir = Join-Path $MetaDir 'bisync-state'
    if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }
    $pairState = Join-Path $stateDir ($LocalName + '.synced')
    $resync = $ForceResync -or -not (Test-Path $pairState)
    $code = Invoke-Bisync -RcloneExe $Rclone.Exe -DrivePath $DrivePath -LocalPath $LocalPath -MetaDir $MetaDir -LocalName $LocalName -Resync $resync
    if ($code -eq 0) { New-Item -ItemType File -Path $pairState -Force | Out-Null }
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
        $agentPs = Join-Path $MetaDir 'sync-agent.ps1'
        $agent = @"
# Cowork Bridge - agent de synchro (genere automatiquement, ne pas editer)
Set-StrictMode -Version Latest
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

function Run-All {
    `$stateDir = Join-Path `$meta 'bisync-state'
    if (-not (Test-Path `$stateDir)) { New-Item -ItemType Directory -Path `$stateDir -Force | Out-Null }
    foreach (`$p in (Read-Pairs)) {
        if (-not (Test-Path `$p.Local)) { continue }
        `$filters   = Join-Path `$meta 'filters.txt'
        `$backup    = Join-Path (Join-Path `$meta 'trash') ((Get-Date -Format 'yyyy-MM-dd') + '\' + `$p.Name)
        `$log       = Join-Path `$meta 'rclone.log'
        `$pairState = Join-Path `$stateDir (`$p.Name + '.synced')
        `$argLine = @('bisync', ('"{0}"' -f `$p.Drive), ('"{0}"' -f `$p.Local),
            '--workdir', ('"{0}"' -f `$stateDir), '--filters-file', ('"{0}"' -f `$filters),
            '--check-access', '--check-filename', `$marker, '--max-delete', '25',
            '--conflict-resolve', 'none', '--backup-dir2', ('"{0}"' -f `$backup),
            '--resilient', '--recover', '--max-lock', '2m',
            '--log-file', ('"{0}"' -f `$log), '--log-level', 'INFO')
        if (-not (Test-Path `$pairState)) { `$argLine += @('--resync', '--resync-mode', 'path1') }
        `$argLine = `$argLine -join ' '
        try {
            `$proc = Start-Process -FilePath `$rclone -ArgumentList `$argLine -WindowStyle Hidden -Wait -PassThru
            if (`$proc.ExitCode -eq 0) { New-Item -ItemType File -Path `$pairState -Force | Out-Null }
        } catch {}
    }
}

# Watcher : chaque modif locale émet un événement dans la file (récupéré par Wait-Event).
`$watchers = @()
foreach (`$p in (Read-Pairs)) {
    if (-not (Test-Path `$p.Local)) { continue }
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
        Run-All
        `$lastRun = Get-Date   # APRES Run-All : garantit un temps mort = intervalle, même si la synchro est longue
        try { [System.IO.File]::WriteAllText((Join-Path `$meta 'next-sync'), `$lastRun.AddMinutes(`$interval).ToString('o')) } catch {}
    }
}
"@
        [System.IO.File]::WriteAllText($agentPs, $agent, (New-Object System.Text.UTF8Encoding($false)))
        $ps      = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $argLine = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $agentPs
        $lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'CoworkBridge-Sync.lnk'
        $wsh = New-Object -ComObject WScript.Shell
        $sc = $wsh.CreateShortcut($lnk)
        $sc.TargetPath  = $ps
        $sc.Arguments   = $argLine
        $sc.WindowStyle = 7
        $sc.Description  = 'Cowork Bridge - agent de synchro'
        $sc.Save()
        try { Start-Process -FilePath $ps -ArgumentList $argLine -WindowStyle Hidden | Out-Null } catch {}
        return $true
    } catch {
        Write-Log "Agent de synchro non installe: $($_.Exception.Message)" 'WARN'
        return $false
    }
}

function Remove-SyncAgent {
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
    if (-not (Test-UnderHome $Dest)) { throw "Dossier de travail hors du dossier utilisateur : $Dest" }
    & $say 'Préparation des dossiers...'
    if (-not (Test-Path $Dest)) { New-Item -ItemType Directory -Path $Dest -Force | Out-Null }
    $meta = Get-MetaDir $Dest
    if (-not (Test-Path $meta)) { New-Item -ItemType Directory -Path $meta -Force | Out-Null }
    $script:LogFile = Join-Path $meta 'bridge.log'
    Write-Log "=== Application : $($Selected.Count) dossier(s), FirstRun=$FirstRun ==="

    $pairs = Build-Pairs -Selected $Selected -Dest $Dest
    foreach ($p in $pairs) {
        if (-not (Test-Path $p.Local)) { New-Item -ItemType Directory -Path $p.Local -Force | Out-Null }
        Set-Marker $p.Local    # marqueur --check-access côté local
        Set-Marker $p.Drive    # et côté Drive (sa présence prouve que le dossier est monté)
        Write-Log "Paire: $($p.Drive)  <->  $($p.Local)"
    }

    & $say 'Génération de la configuration...'
    New-FiltersFile (Join-Path $meta 'filters.txt')

    Save-Config -Dest $Dest -Config ([pscustomobject]@{
        version   = 2
        engine    = 'rclone'
        dest      = $Dest
        interval  = $IntervalMin
        sources   = @($pairs | ForEach-Object { @{ Type = $_.Source.Type; Name = $_.Source.Name; Path = $_.Source.Path; LocalName = $_.LocalName } })
        installed = (Get-Date -Format 's')
    })

    & $say 'Première synchronisation (peut prendre un moment sur un gros dossier)...'
    # Baseline gérée PAR PAIRE par Sync-Pair (un dossier ajouté plus tard a besoin de
    # SON propre --resync, sinon bisync sort en erreur).
    $worst = 0
    foreach ($p in $pairs) {
        $code = Sync-Pair -Rclone $Rclone -DrivePath $p.Drive -LocalPath $p.Local -MetaDir $meta -LocalName $p.LocalName -ForceResync $FirstRun
        if ($code -gt $worst) { $worst = $code }
    }

    & $say 'Installation de la synchronisation automatique...'
    Remove-LegacyArtifacts
    Remove-SyncAgent
    $hasAgent = Set-SyncAgent -RcloneExe $Rclone.Exe -MetaDir $meta -IntervalMin $IntervalMin

    return [pscustomobject]@{ ExitCode = $worst; Agent = $hasAgent }
}

# Désynchroniser un dossier : remonte son contenu vers Drive (copie seule, sans
# suppression), puis envoie la copie locale à la corbeille, puis régénère.
function Remove-TrackedFolder {
    param([object]$Config, [object]$Source, [object]$Rclone)
    $Config = Normalize-Config $Config
    if (-not (Test-UnderHome $Config.dest)) {
        Show-Warn("Dossier de travail hors de ton dossier utilisateur — opération annulée par sécurité.")
        return $false
    }
    $meta = Get-MetaDir $Config.dest
    $script:LogFile = Join-Path $meta 'bridge.log'
    $local = Join-Path $Config.dest (Resolve-LocalName $Source)

    if (Test-Path $local) {
        Assert-SafePath $local; Assert-SafePath $Source.Path
        # remontée copie-seule local -> Drive (jamais de suppression côté Drive)
        $log = Join-Path $meta 'rclone.log'
        $filters = Join-Path $meta 'filters.txt'
        if (-not (Test-Path $filters)) { New-FiltersFile $filters }
        Assert-SafePath $filters
        $argLine = @('copy', ('"{0}"' -f $local), ('"{0}"' -f $Source.Path),
            '--filters-file', ('"{0}"' -f $filters),
            '--log-file', ('"{0}"' -f $log), '--log-level', 'INFO') -join ' '
        $pushed = $false
        try {
            $p = Start-Process -FilePath $Rclone.Exe -ArgumentList $argLine -WindowStyle Hidden -PassThru -Wait
            $pushed = ([int]$p.ExitCode -eq 0)
            Write-Log "Désync : remontée copy local->Drive de '$($Source.Name)', code $($p.ExitCode)"
        } catch { Write-Log "Désync : remontée échouée: $($_.Exception.Message)" 'WARN' }
        if (-not $pushed) {
            Show-Warn("La remontée vers Google Drive n'a pas abouti. Par sécurité, la copie locale n'est PAS supprimée (aucune perte).")
            return $false
        }
        try { Remove-ToRecycleBin $local } catch { Write-Log "Désync : corbeille échouée: $local ($($_.Exception.Message))" 'WARN' }
    }

    $remaining = @(Get-SortedSources $Config | Where-Object { $_.Path -ne $Source.Path })
    if ($remaining.Count -eq 0) {
        Remove-SyncAgent; Remove-LegacyArtifacts
        Save-Config -Dest $Config.dest -Config ([pscustomobject]@{
            version = 2; engine = 'rclone'; dest = $Config.dest; interval = [int]$Config.interval
            sources = @(); installed = (Get-Date -Format 's')
        })
        return $true
    }
    Apply-Config -Selected $remaining -Dest $Config.dest -IntervalMin ([int]$Config.interval) -Rclone $Rclone -FirstRun $false -Status $null | Out-Null
    return $true
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
    foreach ($pat in @('*.ffs_batch', '*.ffs_real', '*.ffs_db', 'sync.ffs_db*', '*.ffs_lock')) {
        try { Get-ChildItem -Path $meta -Filter $pat -Force -ErrorAction SilentlyContinue |
                Where-Object { -not $_.PSIsContainer } | Remove-Item -Force -ErrorAction SilentlyContinue } catch {}
    }
    foreach ($s in $Sources) {
        $local = Join-Path $Dest (Resolve-LocalName $s)
        if (-not (Test-Path $local)) { continue }
        foreach ($pat in @('*.ffs_db', 'sync.ffs_db*', '*.ffs_lock')) {
            try { Get-ChildItem -Path $local -Filter $pat -Recurse -Force -ErrorAction SilentlyContinue |
                    Where-Object { -not $_.PSIsContainer } | Remove-Item -Force -ErrorAction SilentlyContinue } catch {}
        }
    }
}

# Sources legacy -> sources v2, dédupliquées par Path (premier gagné -> tue le doublon FFS).
function Get-MigratedSources([object]$Config) {
    $seen = New-Object System.Collections.Generic.HashSet[string]
    $out  = New-Object System.Collections.Generic.List[object]
    foreach ($s in (Get-SortedSources $Config)) {
        if (-not ($s.PSObject.Properties.Name -contains 'Path') -or -not $s.Path) { continue }
        if (-not $seen.Add(([string]$s.Path).ToLowerInvariant())) { continue }
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
        Show-Warn("Dossier de travail hors de ton dossier utilisateur — migration annulée par sécurité.")
        return $false
    }

    & $say 'Arrêt de l''ancien moteur de synchronisation...'
    Remove-LegacyArtifacts   # stoppe RealTimeSync + retire tâche/raccourci FFS
    Remove-SyncAgent

    $sources = @(Get-MigratedSources $Config)   # @() : garde un tableau même à 0/1 élément
    & $say 'Nettoyage des anciens fichiers de synchronisation...'
    Remove-FfsArtifacts -Dest $dest -Sources $sources

    if ($sources.Count -eq 0) {
        New-FiltersFile (Join-Path $meta 'filters.txt')
        Save-Config -Dest $dest -Config ([pscustomobject]@{
            version = 2; engine = 'rclone'; dest = $dest; interval = [int]$Config.interval
            sources = @(); installed = (Get-Date -Format 's')
        })
        Write-Log "Migration : aucune source exploitable, config v2 vide ecrite."
        return $true
    }

    & $say 'Bascule vers le nouveau moteur (peut prendre un moment)...'
    # Apply-Config réécrit config.json en v2, pose markers + filtres (FFS exclus), baseline
    # --resync (local et Drive déjà alignés par FFS -> union quasi nulle), installe l'agent.
    Apply-Config -Selected $sources -Dest $dest -IntervalMin ([int]$Config.interval) -Rclone $Rclone -FirstRun $true -Status $Status | Out-Null
    Write-Log "Migration terminee : $($sources.Count) dossier(s) bascule(s) en rclone."
    return $true
}

# ----------------------------------------------------------------------------
# Sélecteur de dossier façon Explorateur (OpenFileDialog détourné, aucun fichier listé)
# ----------------------------------------------------------------------------
function Select-DriveFolder {
    param([string]$StartDir)
    $ofd = New-Object System.Windows.Forms.OpenFileDialog
    $ofd.Title           = 'Ouvre le dossier Google Drive à suivre, puis clique « Ouvrir »'
    $ofd.ValidateNames   = $false
    $ofd.CheckFileExists = $false
    $ofd.CheckPathExists = $true
    $ofd.Filter          = 'Dossier|*.cowork-bridge-none'
    $ofd.FileName        = 'Sélectionner ce dossier'
    if ($StartDir -and (Test-Path $StartDir)) { $ofd.InitialDirectory = $StartDir }
    if ($ofd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $dir = Split-Path -Path $ofd.FileName -Parent
        if ($dir -and (Test-Path $dir)) { return $dir }
    }
    return $null
}

function New-BrowsedSource {
    param([string]$Path, [long]$AlreadyUsedBytes, [string]$Dest, [scriptblock]$Status)
    $say = { param($m) if ($Status) { & $Status $m } }
    & $say 'Calcul de la taille du dossier...'
    $size = Get-FolderSizeBytes $Path
    $budget = Test-DiskBudget ($AlreadyUsedBytes + $size) $Dest
    if (-not $budget.Ok) {
        Show-Warn("Pas assez d'espace sur le disque pour ce dossier." + [Environment]::NewLine +
                  "Ce dossier ≈ $(Format-Size $size). Libre sur le disque ≈ $(Format-Size $budget.Free)." + [Environment]::NewLine + [Environment]::NewLine +
                  "Pour éviter de saturer le disque (et bloquer l'ouverture de session Windows), choisis un dossier plus petit, ou libère de la place.")
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
    $form.Text = "$script:AppName - Installation"
    $form.Size = New-Object System.Drawing.Size(620, 540)
    $form.StartPosition = 'CenterScreen'
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = "Choisis les dossiers Google Drive à rendre accessibles à Claude Cowork." + [Environment]::NewLine +
                "Clique « Ajouter un dossier » et navigue jusqu'au dossier voulu. Seuls les" + [Environment]::NewLine +
                "dossiers ajoutés occuperont de l'espace sur cet ordinateur."
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
            $tag = if ($r.Type -eq 'Shared') { '[Partagé] ' } else { '[Mon Drive] ' }
            [void]$list.Items.Add($tag + $r.Name + '  —  ' + (Format-Size $r.SizeBytes))
        }
    }

    $btnAdd = New-Object System.Windows.Forms.Button
    $btnAdd.Text = 'Ajouter un dossier…'
    $btnAdd.Location = New-Object System.Drawing.Point(15, 330); $btnAdd.Size = New-Object System.Drawing.Size(200, 30)
    $form.Controls.Add($btnAdd)

    $btnRem = New-Object System.Windows.Forms.Button
    $btnRem.Text = 'Retirer de la liste'
    $btnRem.Location = New-Object System.Drawing.Point(225, 330); $btnRem.Size = New-Object System.Drawing.Size(180, 30)
    $form.Controls.Add($btnRem)

    $lblDest = New-Object System.Windows.Forms.Label
    $lblDest.Text = 'Dossier de travail (doit rester dans ton dossier utilisateur) :'
    $lblDest.Location = New-Object System.Drawing.Point(15, 372); $lblDest.Size = New-Object System.Drawing.Size(575, 18)
    $form.Controls.Add($lblDest)
    $txtDest = New-Object System.Windows.Forms.TextBox
    $txtDest.Text = $Dest
    $txtDest.Location = New-Object System.Drawing.Point(15, 392); $txtDest.Size = New-Object System.Drawing.Size(575, 24)
    $form.Controls.Add($txtDest)

    $lblInt = New-Object System.Windows.Forms.Label
    $lblInt.Text = 'Récupérer les changements venant de Drive toutes les (minutes) :'
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
    $btnOk.Text = 'Installer'
    $btnOk.Location = New-Object System.Drawing.Point(410, 478); $btnOk.Size = New-Object System.Drawing.Size(95, 30)
    $form.Controls.Add($btnOk)
    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = 'Annuler'
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
        if ($script:selRows | Where-Object { $_.Path -eq $p }) { $statusCb.Invoke('Ce dossier est déjà dans la liste.'); return }
        if (-not (Confirm-NoDuplicateLeaf -Sources $script:selRows -Path $p -Noun 'dans la liste')) { return }
        $src = New-BrowsedSource -Path $p -AlreadyUsedBytes ([long]$used) -Dest ($txtDest.Text.Trim()) -Status $statusCb
        if ($src) { $script:selRows.Add($src); $refresh.Invoke(); $statusCb.Invoke('') }
    })
    $btnRem.Add_Click({
        $i = $list.SelectedIndex
        if ($i -ge 0 -and $i -lt $script:selRows.Count) { $script:selRows.RemoveAt($i); $refresh.Invoke() }
    })
    $btnOk.Add_Click({
        if ($script:selRows.Count -eq 0) { $statusCb.Invoke('Ajoute au moins un dossier.'); $status.ForeColor = [System.Drawing.Color]::Firebrick; return }
        $d = $txtDest.Text.Trim()
        $ok = $false
        try {
            $dFull    = [System.IO.Path]::GetFullPath($d).TrimEnd('\')
            $homeFull = [System.IO.Path]::GetFullPath($script:HomeRoot).TrimEnd('\')
            $ok = $dFull.Equals($homeFull, [System.StringComparison]::OrdinalIgnoreCase) -or
                  $dFull.StartsWith($homeFull + '\', [System.StringComparison]::OrdinalIgnoreCase)
        } catch { $ok = $false }
        if (-not $ok) { $statusCb.Invoke("Le dossier doit être dans : $script:HomeRoot"); $status.ForeColor = [System.Drawing.Color]::Firebrick; return }
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
    $form.Text = "$script:AppName - Gestion"
    $form.Size = New-Object System.Drawing.Size(560, 540)
    $form.StartPosition = 'CenterScreen'
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Location = New-Object System.Drawing.Point(20, 14); $lbl.Size = New-Object System.Drawing.Size(510, 58)
    $form.Controls.Add($lbl)

    $lblList = New-Object System.Windows.Forms.Label
    $lblList.Text = 'Dossiers synchronisés par Cowork Bridge :'
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
            $tag = if ($s.Type -eq 'Shared') { '[Partagé] ' } else { '[Mon Drive] ' }
            [void]$list.Items.Add($tag + $s.Name)
        }
        $lbl.Text = "Cowork Bridge est actif." + [Environment]::NewLine +
                    "À connecter dans Cowork (et surtout pas le dossier Google Drive) :" + [Environment]::NewLine +
                    "$($script:mgConfig.dest)"
    }
    $reload.Invoke()

    $lblTimer = New-Object System.Windows.Forms.Label
    $lblTimer.Location = New-Object System.Drawing.Point(20, 212); $lblTimer.Size = New-Object System.Drawing.Size(510, 18)
    $lblTimer.ForeColor = [System.Drawing.Color]::DimGray
    $form.Controls.Add($lblTimer)

    $lblInt = New-Object System.Windows.Forms.Label
    $lblInt.Text = 'Synchroniser depuis Drive toutes les (min) :'
    $lblInt.Location = New-Object System.Drawing.Point(20, 238); $lblInt.Size = New-Object System.Drawing.Size(270, 22)
    $form.Controls.Add($lblInt)
    $numInt = New-Object System.Windows.Forms.NumericUpDown
    $numInt.Minimum = 1; $numInt.Maximum = 1440; $numInt.Value = [int]$Config.interval
    $numInt.Location = New-Object System.Drawing.Point(295, 236); $numInt.Size = New-Object System.Drawing.Size(70, 24)
    $form.Controls.Add($numInt)
    $btnInt = New-Object System.Windows.Forms.Button
    $btnInt.Text = 'Appliquer'
    $btnInt.Location = New-Object System.Drawing.Point(375, 235); $btnInt.Size = New-Object System.Drawing.Size(155, 26)
    $form.Controls.Add($btnInt)

    $btnAdd = New-Object System.Windows.Forms.Button
    $btnAdd.Text = 'Ajouter un dossier'
    $btnAdd.Location = New-Object System.Drawing.Point(20, 272); $btnAdd.Size = New-Object System.Drawing.Size(245, 32)
    $form.Controls.Add($btnAdd)
    $btnDesync = New-Object System.Windows.Forms.Button
    $btnDesync.Text = 'Désynchroniser le dossier sélectionné'
    $btnDesync.Location = New-Object System.Drawing.Point(285, 272); $btnDesync.Size = New-Object System.Drawing.Size(245, 32)
    $form.Controls.Add($btnDesync)

    $btnSync = New-Object System.Windows.Forms.Button
    $btnSync.Text = 'Synchroniser maintenant'
    $btnSync.Location = New-Object System.Drawing.Point(20, 310); $btnSync.Size = New-Object System.Drawing.Size(245, 32)
    $form.Controls.Add($btnSync)
    $btnOpen = New-Object System.Windows.Forms.Button
    $btnOpen.Text = 'Ouvrir le dossier local'
    $btnOpen.Location = New-Object System.Drawing.Point(285, 310); $btnOpen.Size = New-Object System.Drawing.Size(245, 32)
    $form.Controls.Add($btnOpen)

    $btnUpdate = New-Object System.Windows.Forms.Button
    $btnUpdate.Text = 'Vérifier les mises à jour'
    $btnUpdate.Location = New-Object System.Drawing.Point(20, 348); $btnUpdate.Size = New-Object System.Drawing.Size(245, 32)
    $form.Controls.Add($btnUpdate)
    $btnUninstall = New-Object System.Windows.Forms.Button
    $btnUninstall.Text = 'Désinstaller Cowork Bridge'
    $btnUninstall.Location = New-Object System.Drawing.Point(285, 348); $btnUninstall.Size = New-Object System.Drawing.Size(245, 32)
    $form.Controls.Add($btnUninstall)

    $status = New-Object System.Windows.Forms.Label
    $status.Location = New-Object System.Drawing.Point(20, 392); $status.Size = New-Object System.Drawing.Size(510, 56)
    $status.ForeColor = [System.Drawing.Color]::DimGray
    $form.Controls.Add($status)

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = 'Fermer'
    $btnClose.Location = New-Object System.Drawing.Point(440, 458); $btnClose.Size = New-Object System.Drawing.Size(90, 30)
    $btnClose.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.Controls.Add($btnClose)

    $nextFile = Join-Path (Get-MetaDir $Config.dest) 'next-sync'
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 1000
    $timer.Add_Tick({
        $txt = 'Prochaine synchronisation : —'
        try {
            if (Test-Path $nextFile) {
                $next = [datetime]::Parse((Get-Content $nextFile -Raw).Trim())
                $rem = $next - (Get-Date)
                if ($rem.TotalSeconds -le 0) { $txt = 'Prochaine synchronisation : imminente' }
                else { $txt = 'Prochaine synchronisation dans {0:mm\:ss}' -f $rem }
            }
        } catch {}
        $lblTimer.Text = $txt
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
        $busy.Invoke("Délai mis à jour : toutes les $min min.")
    })
    $btnAdd.Add_Click({
        $start = Get-DriveRoot
        $p = Select-DriveFolder -StartDir $start
        if (-not $p) { return }
        if ($script:mgSources | Where-Object { $_.Path -eq $p }) { $busy.Invoke('Ce dossier est déjà suivi.'); return }
        if (-not (Confirm-NoDuplicateLeaf -Sources $script:mgSources -Path $p -Noun 'suivi')) { $busy.Invoke(''); return }
        $busy.Invoke('Calcul de la taille...')
        $src = New-BrowsedSource -Path $p -AlreadyUsedBytes ([long]0) -Dest $script:mgConfig.dest -Status $busy
        if (-not $src) { $busy.Invoke(''); return }
        $busy.Invoke('Ajout et synchronisation...')
        $newSel = @($script:mgSources | ForEach-Object { [pscustomobject]@{ Type = $_.Type; Name = $_.Name; Path = $_.Path } }) + @([pscustomobject]@{ Type = $src.Type; Name = $src.Name; Path = $src.Path })
        try {
            $res = Apply-Config -Selected $newSel -Dest $script:mgConfig.dest -IntervalMin ([int]$script:mgConfig.interval) -Rclone $Rclone -FirstRun $false -Status $null
            $reload.Invoke()
            $busy.Invoke((Get-SyncResultText ([int]$res.ExitCode)))
        } catch { $busy.Invoke("L'ajout a échoué : $($_.Exception.Message)") }
    })
    $btnDesync.Add_Click({
        $i = $list.SelectedIndex
        if ($i -lt 0 -or $i -ge $script:mgSources.Count) { $busy.Invoke('Sélectionne d''abord un dossier dans la liste.'); return }
        $src = $script:mgSources[$i]
        $m = "Désynchroniser « $($src.Name) » ?" + [Environment]::NewLine + [Environment]::NewLine +
             "Son contenu est d'abord renvoyé vers Google Drive, puis la copie locale part" + [Environment]::NewLine +
             "à la corbeille. Rien n'est supprimé côté Drive."
        if (-not (Confirm-YesNo $m)) { return }
        $busy.Invoke('Remontée vers Drive puis libération...')
        try {
            if (Remove-TrackedFolder -Config $script:mgConfig -Source $src -Rclone $Rclone) {
                $reload.Invoke(); $busy.Invoke("« $($src.Name) » n'est plus synchronisé.")
            }
        } catch { $busy.Invoke("La désynchronisation a échoué : $($_.Exception.Message)") }
    })
    $btnSync.Add_Click({
        $busy.Invoke('Synchronisation en cours...')
        try {
            $worst = 0
            foreach ($s in $script:mgSources) {
                $local = Join-Path $script:mgConfig.dest (Resolve-LocalName $s)
                if (-not (Test-Path $local)) { continue }
                $code = Sync-Pair -Rclone $Rclone -DrivePath $s.Path -LocalPath $local -MetaDir (Get-MetaDir $script:mgConfig.dest) -LocalName (Resolve-LocalName $s) -ForceResync $false
                if ($code -gt $worst) { $worst = $code }
            }
            $busy.Invoke((Get-SyncResultText $worst))
        } catch { $busy.Invoke("La synchronisation n'a pas pu démarrer : $($_.Exception.Message)") }
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
        return (Confirm-YesNo("Un dossier nommé « $leaf » est déjà $Noun." + [Environment]::NewLine +
            "C'est peut-être le même (le chemin Google Drive a pu changer)." + [Environment]::NewLine +
            "L'ajouter quand même ?"))
    }
    return $true
}

function Start-Bridge {
    if (Invoke-UpdateCheck) { return }

    $rclone = Find-Rclone
    if (-not $rclone) {
        Show-Warn("Le moteur de synchronisation (rclone) est introuvable à côté de l'application." + [Environment]::NewLine +
                  "Réinstalle Cowork Bridge depuis l'installeur officiel.")
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
        $ml.Text = 'Mise à jour du moteur de synchronisation...'
        $mig.Controls.Add($ml); $mig.Show(); $mig.Refresh()
        $migCb = { param($m) $ml.Text = $m; $mig.Refresh() }
        try {
            Invoke-LegacyMigration -Config $existing -Rclone $rclone -Status $migCb
        } catch {
            Write-Log "ERREUR migration: $($_.Exception.Message)" 'ERROR'
            Show-Warn("La mise à jour du moteur a rencontré un problème :" + [Environment]::NewLine +
                      $($_.Exception.Message) + [Environment]::NewLine + [Environment]::NewLine +
                      "Aucune donnée n'est perdue. Tu peux relancer Cowork Bridge.")
        } finally {
            if ($mig.Visible) { $mig.Close() }
        }
        $existing = Normalize-Config (Load-Config -Dest $script:DefaultDest)
    }

    if ($existing -and @(Get-SortedSources $existing).Count -gt 0) {
        Show-ManageDialog -Config $existing -Rclone $rclone
        return
    }

    # Première installation : choix des dossiers par l'explorateur
    $start = Get-DriveRoot
    if (-not $start) {
        $m = "Aucun dossier Google Drive détecté sur cet ordinateur." + [Environment]::NewLine + [Environment]::NewLine +
             "Vérifie que Google Drive pour ordinateur est lancé, connecté à ton compte, et réglé sur" + [Environment]::NewLine +
             "« Accéder en ligne aux fichiers » (Paramètres → Préférences → Dossiers de Drive)." + [Environment]::NewLine +
             "Tu peux quand même continuer et parcourir manuellement."
        Show-Warn $m
    }
    $choice = Show-SelectionDialog -Dest $script:DefaultDest -Interval $script:DefaultInterval -StartDir $start
    if (-not $choice) { return }

    $progress = New-Object System.Windows.Forms.Form
    $progress.Text = "$script:AppName"; $progress.Size = New-Object System.Drawing.Size(470, 130)
    $progress.StartPosition = 'CenterScreen'; $progress.ControlBox = $false
    $progress.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $pl = New-Object System.Windows.Forms.Label
    $pl.Location = New-Object System.Drawing.Point(20, 30); $pl.Size = New-Object System.Drawing.Size(420, 60); $pl.Text = 'Installation...'
    $progress.Controls.Add($pl); $progress.Show(); $progress.Refresh()
    $statusCb = { param($m) $pl.Text = $m; $progress.Refresh() }

    try {
        $res = Apply-Config -Selected $choice.Selected -Dest $choice.Dest -IntervalMin $choice.Interval -Rclone $rclone -FirstRun $true -Status $statusCb
        $progress.Close()
        $auto = if ($res.Agent) {
            "La synchronisation tourne maintenant toute seule en arrière-plan :" + [Environment]::NewLine +
            "  - tes modifications partent vers Google Drive quasi instantanément ;" + [Environment]::NewLine +
            "  - les changements venant de Drive sont récupérés toutes les $($choice.Interval) min."
        } else {
            "La synchronisation automatique n'a pas pu être installée — voir le guide (dépannage)."
        }
        $msg = "Installation terminée." + [Environment]::NewLine + [Environment]::NewLine +
               "Dernière étape, dans Claude Cowork : connecte le dossier ci-dessous —" + [Environment]::NewLine +
               "et surtout pas ton dossier Google Drive :" + [Environment]::NewLine + [Environment]::NewLine +
               "   $($choice.Dest)" + [Environment]::NewLine + [Environment]::NewLine +
               "Si Cowork affiche un dossier vide, c'est presque toujours qu'on a connecté" + [Environment]::NewLine +
               "le dossier Google Drive au lieu de celui-ci." + [Environment]::NewLine + [Environment]::NewLine +
               $auto + [Environment]::NewLine + [Environment]::NewLine +
               (Get-SyncResultText ([int]$res.ExitCode))
        Show-Info $msg
    } catch {
        if ($progress.Visible) { $progress.Close() }
        Write-Log "ERREUR installation: $($_.Exception.Message)" 'ERROR'
        Show-Warn("L'installation a échoué :" + [Environment]::NewLine + $($_.Exception.Message))
    }
}

function Invoke-Uninstall {
    param([object]$Config)
    $m = "Désinstaller Cowork Bridge ?" + [Environment]::NewLine + [Environment]::NewLine +
         "La synchronisation automatique est retirée. Ton dossier local n'est PAS supprimé" + [Environment]::NewLine +
         "(tu pourras l'effacer à la main pour récupérer l'espace). Aucun fichier n'est perdu."
    if (-not (Confirm-YesNo $m)) { return }
    $script:LogFile = Join-Path (Get-MetaDir $Config.dest) 'bridge.log'
    Remove-SyncAgent
    Remove-LegacyArtifacts
    Show-Info("Cowork Bridge est désinstallé (synchronisation automatique retirée)." + [Environment]::NewLine +
              "Ton dossier local est conservé : $($Config.dest)")
}

# ----------------------------------------------------------------------------
try { Start-Bridge }
catch { [void][System.Windows.Forms.MessageBox]::Show(("Erreur inattendue :" + [Environment]::NewLine + $($_.Exception.Message)), $script:AppName, 'OK', 'Error') }
