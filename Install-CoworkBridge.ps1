<#
    Cowork Bridge - Installateur / centre de contrôle
    --------------------------------------------------
    Pont entre Google Drive (mode « Accéder en ligne aux fichiers ») et un dossier
    local plat lisible par Claude Cowork. Le sandbox de Cowork ne traverse pas le
    filesystem virtuel de Drive ; on lui donne donc de vrais octets dans
    %USERPROFILE%\CoworkWork (dans le home, contrainte Cowork).

    Synchro :
      - RealTimeSync (démarrage) = push instantané des modifs locales.
      - Boucle résidente (démarrage, _bridge\sync-loop.ps1) = pull périodique :
        relit l'intervalle (_bridge\interval) à chaque tour, écrit l'heure de
        prochaine synchro (_bridge\next-sync) pour le minuteur, et ne lance pas
        FreeFileSync si une instance tourne déjà (verrou mono-instance).
      - 1er run d'une nouvelle install = Miroir Drive -> local (jamais d'effacement
        Drive). Suppressions = corbeille (récupérables).

    Sécurité disque : avant d'ajouter un dossier, on vérifie qu'il tient sur C:
    avec une marge (sinon remplir le profil empêche Windows de l'ouvrir).

    Moteur : FreeFileSync (à installer au préalable).
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
$script:TaskName    = 'CoworkBridge-Sync'        # ancien mécanisme : nettoyé seulement
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
        1       { 'Synchronisation terminée. Quelques fichiers ont été ignorés (verrouillés ou temporaires) — sans impact sur ton travail.' }
        default { 'La synchronisation a rencontré un problème. Relance « Synchroniser maintenant ». Si le problème persiste, contacte ton interlocuteur Drivenlabs.' }
    }
}

function Remove-ToRecycleBin([string]$Path) {
    [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory(
        $Path,
        [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
        [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin)
}

# Confinement : un chemin (rechargé depuis config) doit rester sous le home.
# Re-vérifié à chaque opération destructive/création (pas seulement à l'install).
function Test-UnderHome([string]$Path) {
    try {
        $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
        $home = [System.IO.Path]::GetFullPath($script:HomeRoot).TrimEnd('\')
        return $full.Equals($home, [System.StringComparison]::OrdinalIgnoreCase) -or
               $full.StartsWith($home + '\', [System.StringComparison]::OrdinalIgnoreCase)
    } catch { return $false }
}

# Rejette un chemin contenant un caractère qui n'a rien à faire dans un chemin
# Windows (CR/LF, guillemet) -> bloque toute injection dans les configs/scripts générés.
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

# Vrai si $NeededBytes tient sur le disque de $Dest en gardant la marge.
function Test-DiskBudget([long]$NeededBytes, [string]$Dest) {
    $free = Get-FreeBytes $Dest
    # free < 0 = espace libre indéterminé -> ne pas bloquer (un échec transitoire
    # de lecture ne doit pas refuser tous les ajouts).
    $ok = if ($free -lt 0) { $true } else { (($NeededBytes + $script:DiskMarginBytes) -le $free) }
    [pscustomobject]@{
        Ok     = $ok
        Free   = $free
        Needed = $NeededBytes
        Margin = $script:DiskMarginBytes
    }
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

# Déduit le type (Mon Drive / Partagé) depuis le chemin.
function Get-SourceType([string]$Path) {
    if ($Path -like '*\Shared drives\*' -or $Path -like '*\Drive partag*' -or $Path -like '*\Disques partag*') { return 'Shared' }
    return 'MyDrive'
}

# ----------------------------------------------------------------------------
# Localisation de FreeFileSync
# ----------------------------------------------------------------------------
function Find-FreeFileSync {
    $bases = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA) | Where-Object { $_ }
    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($b in $bases) {
        $candidates.Add((Join-Path $b 'FreeFileSync'))
        $candidates.Add((Join-Path $b 'Programs\FreeFileSync'))
    }
    $candidates = $candidates | Where-Object { Test-Path $_ } | Select-Object -Unique
    foreach ($dir in $candidates) {
        $exe = Join-Path $dir 'FreeFileSync.exe'
        $rts = Join-Path $dir 'RealTimeSync.exe'
        if (Test-Path $exe) {
            $rtsPath = if (Test-Path $rts) { $rts } else { $null }
            return [pscustomobject]@{ Exe = $exe; Rts = $rtsPath; Dir = $dir }
        }
    }
    return $null
}

# ----------------------------------------------------------------------------
# Generation des configs FreeFileSync
# ----------------------------------------------------------------------------
function ConvertTo-XmlSafe([string]$s) {
    if ($null -eq $s) { return '' }
    $s = $s -replace '&', '&amp;'
    $s = $s -replace '<', '&lt;'
    $s = $s -replace '>', '&gt;'
    $s = $s -replace '"', '&quot;'
    $s = $s -replace "'", '&apos;'   # correct dans tout contexte XML (y compris attribut simple-quote)
    return $s
}

# $Variant : 'TwoWay' (courant) | 'Mirror' (1er run Drive->local) | 'Update' (copie seule).
# Élément log = <LogFolder/> à la racine (schéma FFS actuel vérifié, config.cpp) ;
# <Variant> migré par FFS depuis le format 13.
function New-FfsBatch {
    param(
        [object[]]$Pairs,
        [string]$OutPath,
        [ValidateSet('TwoWay','Mirror','Update')][string]$Variant = 'TwoWay'
    )
    foreach ($p in $Pairs) { Assert-SafePath $p.Left; Assert-SafePath $p.Right }
    $pairBlocks = foreach ($p in $Pairs) {
@"
        <Pair>
            <Left>$(ConvertTo-XmlSafe $p.Left)</Left>
            <Right>$(ConvertTo-XmlSafe $p.Right)</Right>
        </Pair>
"@
    }
    $pairsXml = ($pairBlocks -join "`r`n")
    $xml = @"
<?xml version="1.0" encoding="utf-8"?>
<FreeFileSync XmlType="BATCH" XmlFormat="13">
    <Compare>
        <Variant>TimeAndSize</Variant>
        <Symlinks>Exclude</Symlinks>
        <IgnoreTimeShift/>
    </Compare>
    <Synchronize>
        <Variant>$Variant</Variant>
        <DetectMovedFiles>false</DetectMovedFiles>
        <DeletionPolicy>RecycleBin</DeletionPolicy>
        <VersioningFolder Style="Replace"/>
    </Synchronize>
    <Filter>
        <Include>
            <Item>*</Item>
        </Include>
        <Exclude>
            <Item>\System Volume Information\</Item>
            <Item>\`$Recycle.Bin\</Item>
            <Item>*\desktop.ini</Item>
            <Item>*\thumbs.db</Item>
            <Item>*\.tmp.drivedownload\</Item>
            <Item>*\.tmp.driveupload\</Item>
            <Item>*.tmp</Item>
        </Exclude>
        <TimeSpan Type="None">0</TimeSpan>
        <SizeMin Unit="None">0</SizeMin>
        <SizeMax Unit="None">0</SizeMax>
    </Filter>
    <FolderPairs>
$pairsXml
    </FolderPairs>
    <Errors Ignore="true" Retry="2" Delay="5"/>
    <PostSyncCommand Condition="Completion"/>
    <LogFolder/>
    <Batch>
        <ProgressDialog Minimized="true" AutoClose="true"/>
        <ErrorDialog>Show</ErrorDialog>
        <PostSyncAction>None</PostSyncAction>
    </Batch>
</FreeFileSync>
"@
    [System.IO.File]::WriteAllText($OutPath, $xml, (New-Object System.Text.UTF8Encoding($false)))
}

function New-FfsReal {
    param([string[]]$WatchDirs, [string]$FfsExe, [string]$BatchPath, [string]$OutPath)
    Assert-SafePath $FfsExe; Assert-SafePath $BatchPath
    foreach ($d in $WatchDirs) { Assert-SafePath $d }
    $items = foreach ($d in $WatchDirs) { "    <Item>$(ConvertTo-XmlSafe $d)</Item>" }
    $itemsXml = ($items -join "`r`n")
    $cmd = ConvertTo-XmlSafe ('"{0}" "{1}"' -f $FfsExe, $BatchPath)
    $xml = @"
<?xml version="1.0" encoding="utf-8"?>
<FreeFileSync XmlType="REAL" XmlFormat="2">
  <Directories>
$itemsXml
  </Directories>
  <Delay>30</Delay>
  <Commandline>$cmd</Commandline>
</FreeFileSync>
"@
    [System.IO.File]::WriteAllText($OutPath, $xml, (New-Object System.Text.UTF8Encoding($false)))
}

# ----------------------------------------------------------------------------
# Autostart : RealTimeSync (push instantané) + boucle résidente (pull périodique)
# ----------------------------------------------------------------------------
function Set-StartupShortcut {
    param([string]$RtsExe, [string]$RealPath)
    if (-not $RtsExe) { return $false }
    $lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'CoworkBridge.lnk'
    $wsh = New-Object -ComObject WScript.Shell
    $sc = $wsh.CreateShortcut($lnk)
    $sc.TargetPath = $RtsExe
    $sc.Arguments  = '"{0}"' -f $RealPath
    $sc.WindowStyle = 7
    $sc.Description = 'Cowork Bridge - synchro temps reel'
    $sc.Save()
    return $true
}

function Remove-StartupShortcut {
    $lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'CoworkBridge.lnk'
    if (Test-Path $lnk) { Remove-Item $lnk -Force }
}

function Set-IntervalFile([string]$MetaDir, [int]$IntervalMin) {
    [System.IO.File]::WriteAllText((Join-Path $MetaDir 'interval'), [string]$IntervalMin, (New-Object System.Text.UTF8Encoding($false)))
}

# Boucle résidente : relit l'intervalle à chaud, écrit l'heure de prochaine synchro,
# verrou mono-instance (ne double pas avec RealTimeSync). Sans droits (dossier Démarrage).
function Set-SyncLoop {
    param([string]$FfsExe, [string]$BatchPath, [string]$MetaDir, [int]$IntervalMin)
    try {
        # un CR/LF dans un de ces chemins romprait le littéral PS et injecterait du code
        Assert-SafePath $FfsExe; Assert-SafePath $BatchPath; Assert-SafePath $MetaDir
        Set-IntervalFile -MetaDir $MetaDir -IntervalMin $IntervalMin
        $ffsLit  = $FfsExe.Replace("'", "''")
        $batLit  = $BatchPath.Replace("'", "''")
        $metaLit = $MetaDir.Replace("'", "''")
        $loopPs  = Join-Path $MetaDir 'sync-loop.ps1'
        $loopScript = @"
# Cowork Bridge - boucle de synchro periodique (genere automatiquement, ne pas editer)
`$ffs   = '$ffsLit'
`$batch = '$batLit'
`$meta  = '$metaLit'
while (`$true) {
    if (-not (Get-Process FreeFileSync -ErrorAction SilentlyContinue)) {
        try { Start-Process -FilePath `$ffs -ArgumentList ('"{0}"' -f `$batch) -WindowStyle Minimized -Wait } catch {}
    }
    `$min = 30
    try { `$min = [int]((Get-Content (Join-Path `$meta 'interval') -Raw).Trim()) } catch {}
    if (`$min -lt 1) { `$min = 1 }
    try { [System.IO.File]::WriteAllText((Join-Path `$meta 'next-sync'), (Get-Date).AddMinutes(`$min).ToString('o')) } catch {}
    Start-Sleep -Seconds (`$min * 60)
}
"@
        [System.IO.File]::WriteAllText($loopPs, $loopScript, (New-Object System.Text.UTF8Encoding($false)))
        $ps      = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $argLine = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $loopPs
        $lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'CoworkBridge-Sync.lnk'
        $wsh = New-Object -ComObject WScript.Shell
        $sc = $wsh.CreateShortcut($lnk)
        $sc.TargetPath = $ps
        $sc.Arguments  = $argLine
        $sc.WindowStyle = 7
        $sc.Description = 'Cowork Bridge - synchro periodique'
        $sc.Save()
        try { Start-Process -FilePath $ps -ArgumentList $argLine -WindowStyle Hidden | Out-Null } catch {}
        return $true
    } catch {
        Write-Log "Boucle de synchro non installee: $($_.Exception.Message)" 'WARN'
        return $false
    }
}

function Remove-SyncLoop {
    $lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'CoworkBridge-Sync.lnk'
    if (Test-Path $lnk) { Remove-Item $lnk -Force }
    try {
        Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine -like '*sync-loop.ps1*' } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    } catch {}
}

function Unregister-SyncTask {
    Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false -ErrorAction SilentlyContinue
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

# Tri déterministe (Type, Name) -> noms locaux stables ; garde anti-collision.
function Build-Pairs { param([object[]]$Selected, [string]$Dest)
    $pairs = New-Object System.Collections.Generic.List[object]
    $used  = New-Object System.Collections.Generic.HashSet[string]
    foreach ($s in ($Selected | Sort-Object Type, Name)) {
        $persisted = $null
        if (($s.PSObject.Properties.Name -contains 'LocalName') -and $s.LocalName) { $persisted = [string]$s.LocalName }
        if ($persisted) {
            # honorer le nom local déjà sur disque (n'invente pas un nouveau dossier),
            # mais toujours assaini (anti-traversal si la config a été altérée)
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
        $pairs.Add([pscustomobject]@{ Source = $s; Left = $s.Path; Right = $localPath; LocalName = $localName })
    }
    return $pairs
}

# Nom local d'une source enregistrée (LocalName persisté, sinon recalcul).
# Toujours assaini : sans séparateur ni caractère réservé -> ne peut pas remonter
# hors du dossier de travail, même si la config a été altérée.
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
    # StrictMode : ne jamais accéder à .sources sans vérifier qu'elle existe
    # (un config.json antérieur à cette version peut ne pas la porter).
    if ($Config -and ($Config.PSObject.Properties.Name -contains 'sources') -and $Config.sources) {
        return @($Config.sources) | Sort-Object Type, Name
    }
    return @()
}

# ----------------------------------------------------------------------------
# Application d'une configuration (install initiale, ajout, désync : factorisé)
# ----------------------------------------------------------------------------
function Apply-Config {
    param(
        [object[]]$Selected, [string]$Dest, [int]$IntervalMin,
        [object]$Ffs, [bool]$FirstRun, [scriptblock]$Status
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
    $watch = New-Object System.Collections.Generic.List[string]
    foreach ($p in $pairs) {
        if (-not (Test-Path $p.Right)) { New-Item -ItemType Directory -Path $p.Right -Force | Out-Null }
        $watch.Add($p.Right)
        Write-Log "Paire: $($p.Left)  <->  $($p.Right)"
    }
    $pairArray = $pairs | ForEach-Object { [pscustomobject]@{ Left = $_.Left; Right = $_.Right } }

    & $say 'Génération de la configuration...'
    $batchPath = Join-Path $meta 'bridge.ffs_batch'
    $realPath  = Join-Path $meta 'bridge.ffs_real'
    New-FfsBatch -Pairs $pairArray -OutPath $batchPath -Variant 'TwoWay'
    New-FfsReal  -WatchDirs $watch.ToArray() -FfsExe $Ffs.Exe -BatchPath $batchPath -OutPath $realPath

    & $say 'Installation de la synchronisation automatique...'
    $hasRts = Set-StartupShortcut -RtsExe $Ffs.Rts -RealPath $realPath
    Unregister-SyncTask                 # nettoie un éventuel ancien mécanisme
    Remove-SyncLoop                     # repart propre
    $hasLoop = Set-SyncLoop -FfsExe $Ffs.Exe -BatchPath $batchPath -MetaDir $meta -IntervalMin $IntervalMin

    Save-Config -Dest $Dest -Config ([pscustomobject]@{
        version   = 1
        dest      = $Dest
        interval  = $IntervalMin
        ffsExe    = $Ffs.Exe
        ffsRts    = $Ffs.Rts
        batch     = $batchPath
        real      = $realPath
        sources   = @($pairs | ForEach-Object { @{ Type = $_.Source.Type; Name = $_.Source.Name; Path = $_.Source.Path; LocalName = $_.LocalName } })
        installed = (Get-Date -Format 's')
    })

    & $say 'Première synchronisation (peut prendre un moment sur un gros dossier)...'
    if ($FirstRun) {
        $firstPath = Join-Path $meta 'bridge-firstrun.ffs_batch'
        New-FfsBatch -Pairs $pairArray -OutPath $firstPath -Variant 'Mirror'
        Write-Log 'Premiere synchro (Miroir Drive -> local)'
        $proc = Start-Process -FilePath $Ffs.Exe -ArgumentList ('"{0}"' -f $firstPath) -PassThru -Wait
    } else {
        Write-Log 'Synchro (deux-sens)'
        $proc = Start-Process -FilePath $Ffs.Exe -ArgumentList ('"{0}"' -f $batchPath) -PassThru -Wait
    }
    Write-Log "Synchro terminee, code $($proc.ExitCode)"
    if ($hasRts) {
        try { Start-Process -FilePath $Ffs.Rts -ArgumentList ('"{0}"' -f $realPath) -WindowStyle Minimized | Out-Null } catch {}
    }
    return [pscustomobject]@{ ExitCode = $proc.ExitCode; Rts = $hasRts; Loop = $hasLoop; Batch = $batchPath }
}

# Désynchroniser un dossier : remonte son contenu vers Drive (copie seule, sans
# suppression), puis envoie la copie locale à la corbeille, puis régénère.
function Remove-TrackedFolder {
    param([object]$Config, [object]$Source, [object]$Ffs)
    if (-not (Test-UnderHome $Config.dest)) {
        Show-Warn("Dossier de travail hors de ton dossier utilisateur — opération annulée par sécurité.")
        return $false
    }
    $meta = Get-MetaDir $Config.dest
    $script:LogFile = Join-Path $meta 'bridge.log'
    $local = Join-Path $Config.dest (Resolve-LocalName $Source)

    if (Test-Path $local) {
        $pushBatch = Join-Path $meta 'bridge-release.ffs_batch'
        New-FfsBatch -Pairs @([pscustomobject]@{ Left = $local; Right = $Source.Path }) -OutPath $pushBatch -Variant 'Update'
        $pushed = $false
        try {
            # exe re-résolu (Find-FreeFileSync), jamais le chemin stocké en config
            $p = Start-Process -FilePath $Ffs.Exe -ArgumentList ('"{0}"' -f $pushBatch) -PassThru -Wait
            $pushed = ([int]$p.ExitCode -le 1)
            Write-Log "Désync : remontée Update local->Drive de '$($Source.Name)', code $($p.ExitCode)"
        } catch { Write-Log "Désync : remontée échouée: $($_.Exception.Message)" 'WARN' }
        if (-not $pushed) {
            Show-Warn("La remontée vers Google Drive n'a pas abouti. Par sécurité, la copie locale n'est PAS supprimée (aucune perte).")
            return $false
        }
        try { Remove-ToRecycleBin $local } catch { Write-Log "Désync : corbeille échouée: $local ($($_.Exception.Message))" 'WARN' }
    }

    $remaining = @(Get-SortedSources $Config | Where-Object { $_.Path -ne $Source.Path })
    if ($remaining.Count -eq 0) {
        # plus aucun dossier suivi : on retire la synchro de fond, on garde la config vide
        Remove-StartupShortcut; Remove-SyncLoop; Unregister-SyncTask
        try { Get-Process RealTimeSync -ErrorAction SilentlyContinue | Stop-Process -Force } catch {}
        Save-Config -Dest $Config.dest -Config ([pscustomobject]@{
            version = 1; dest = $Config.dest; interval = [int]$Config.interval
            ffsExe = $Config.ffsExe; ffsRts = $Config.ffsRts
            batch = $Config.batch; real = $Config.real; sources = @(); installed = (Get-Date -Format 's')
        })
        return $true
    }
    Apply-Config -Selected $remaining -Dest $Config.dest -IntervalMin ([int]$Config.interval) -Ffs $Ffs -FirstRun $false -Status $null | Out-Null
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

# Construit l'objet source d'un chemin parcouru (avec taille + contrôle disque).
# Renvoie l'objet, ou $null si annulé / refusé pour cause d'espace.
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
        $used = ($script:selRows | Measure-Object -Property SizeBytes -Sum).Sum
        if (-not $used) { $used = [long]0 }
        $p = Select-DriveFolder -StartDir $StartDir
        if (-not $p) { return }
        if ($script:selRows | Where-Object { $_.Path -eq $p }) { $statusCb.Invoke('Ce dossier est déjà dans la liste.'); return }
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
    param([object]$Config, [object]$Ffs)

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
        $script:mgConfig = Load-Config -Dest $Config.dest
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

    # ligne minuteur
    $lblTimer = New-Object System.Windows.Forms.Label
    $lblTimer.Location = New-Object System.Drawing.Point(20, 212); $lblTimer.Size = New-Object System.Drawing.Size(510, 18)
    $lblTimer.ForeColor = [System.Drawing.Color]::DimGray
    $form.Controls.Add($lblTimer)

    # délai + appliquer
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

    # boutons actions (2 colonnes)
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

    # minuteur live (lit _bridge\next-sync)
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
        # les dossiers déjà suivis sont déjà sur le disque -> l'espace libre les reflète déjà ;
        # on ne vérifie que le nouveau dossier.
        $busy.Invoke('Calcul de la taille...')
        $src = New-BrowsedSource -Path $p -AlreadyUsedBytes ([long]0) -Dest $script:mgConfig.dest -Status $busy
        if (-not $src) { $busy.Invoke(''); return }
        $busy.Invoke('Ajout et synchronisation...')
        $newSel = @($script:mgSources | ForEach-Object { [pscustomobject]@{ Type = $_.Type; Name = $_.Name; Path = $_.Path } }) + @([pscustomobject]@{ Type = $src.Type; Name = $src.Name; Path = $src.Path })
        try {
            $res = Apply-Config -Selected $newSel -Dest $script:mgConfig.dest -IntervalMin ([int]$script:mgConfig.interval) -Ffs $Ffs -FirstRun $false -Status $null
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
            if (Remove-TrackedFolder -Config $script:mgConfig -Source $src -Ffs $Ffs) {
                $reload.Invoke(); $busy.Invoke("« $($src.Name) » n'est plus synchronisé.")
            }
        } catch { $busy.Invoke("La désynchronisation a échoué : $($_.Exception.Message)") }
    })
    $btnSync.Add_Click({
        $busy.Invoke('Synchronisation en cours...')
        try {
            # exe re-résolu + batch canonique (jamais les chemins stockés en config)
            $batch = Join-Path (Get-MetaDir $script:mgConfig.dest) 'bridge.ffs_batch'
            $p = Start-Process -FilePath $Ffs.Exe -ArgumentList ('"{0}"' -f $batch) -PassThru -Wait
            $busy.Invoke((Get-SyncResultText ([int]$p.ExitCode)))
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

function Start-Bridge {
    if (Invoke-UpdateCheck) { return }

    $ffs = Find-FreeFileSync
    if (-not $ffs) {
        $m = "Cowork Bridge a besoin d'un logiciel gratuit, FreeFileSync, pour copier tes fichiers." + [Environment]::NewLine +
             "Il n'est pas encore installé sur cet ordinateur." + [Environment]::NewLine + [Environment]::NewLine +
             "Ouvrir la page de téléchargement maintenant ?" + [Environment]::NewLine +
             "Installe FreeFileSync, puis rouvre Cowork Bridge."
        if (Confirm-YesNo $m) { Start-Process 'https://freefilesync.org/download.php' }
        return
    }

    # Installation existante -> centre de contrôle (gère tout en place)
    $existing = Load-Config -Dest $script:DefaultDest
    if ($existing -and @(Get-SortedSources $existing).Count -gt 0) {
        Show-ManageDialog -Config $existing -Ffs $ffs
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
        $res = Apply-Config -Selected $choice.Selected -Dest $choice.Dest -IntervalMin $choice.Interval -Ffs $ffs -FirstRun $true -Status $statusCb
        $progress.Close()
        $auto = if ($res.Rts -and $res.Loop) {
            "La synchronisation tourne maintenant toute seule en arrière-plan :" + [Environment]::NewLine +
            "  - tes modifications partent vers Google Drive en temps réel ;" + [Environment]::NewLine +
            "  - les changements venant de Drive sont récupérés toutes les $($choice.Interval) min."
        } else {
            "Tes modifications partent vers Google Drive en temps réel." + [Environment]::NewLine +
            "Le rafraîchissement périodique n'a pas pu être installé — voir le guide (dépannage)."
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
    Unregister-SyncTask
    Remove-StartupShortcut
    Remove-SyncLoop
    try { Get-Process RealTimeSync -ErrorAction SilentlyContinue | Stop-Process -Force } catch {}
    Show-Info("Cowork Bridge est désinstallé (synchronisation automatique retirée)." + [Environment]::NewLine +
              "Ton dossier local est conservé : $($Config.dest)")
}

# ----------------------------------------------------------------------------
try { Start-Bridge }
catch { [void][System.Windows.Forms.MessageBox]::Show(("Erreur inattendue :" + [Environment]::NewLine + $($_.Exception.Message)), $script:AppName, 'OK', 'Error') }
