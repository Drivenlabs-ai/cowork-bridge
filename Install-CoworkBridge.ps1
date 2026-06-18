<#
    Cowork Bridge - Installateur
    -----------------------------
    Pont entre un dossier Google Drive (mode Stream) et un dossier local plat
    lisible par Claude Cowork.

    Pourquoi : le sandbox de Cowork (VM Hyper-V, montage virtiofs/Plan9) ne sait
    pas traverser le filesystem virtuel de Google Drive. Il faut donc lui donner
    de vrais octets sur un chemin NTFS classique, DANS le dossier home de
    l'utilisateur (contrainte Cowork : aucun dossier hors du home n'est accepte,
    et les raccourcis/jonctions sont resolus puis rejetes).

    Ce que fait l'installeur :
      1. detecte le montage Google Drive (Mon Drive + Drive partages)
      2. laisse choisir les dossiers a ponter (ciblage)
      3. cree %USERPROFILE%\CoworkWork et un sous-dossier par source
      4. genere une config FreeFileSync (.ffs_batch)
      5. installe la synchro de fond (RealTimeSync au demarrage + tache planifiee)
      6. lance une PREMIERE synchro en mode Miroir Drive -> local (jamais de
         suppression cote Drive au 1er run), puis bascule en deux-sens ensuite.

    Securite des donnees :
      - 1er run = Miroir Drive -> local : impossible d'effacer cote Drive.
      - synchro courante = deux-sens, suppressions vers la CORBEILLE (Windows
        + corbeille Drive) = recuperables.
      - liberation d'une copie locale = envoi a la corbeille, jamais en dur,
        et seulement apres une derniere synchro reussie.

    Moteur : FreeFileSync (a installer au prealable - cross-platform, deux-sens
    avec gestion de conflits).

    Lancer via Run-CoworkBridge.bat (gere ExecutionPolicy + mode STA).
    Le script doit etre encode en UTF-8 AVEC BOM (sinon PowerShell 5.1 casse les
    accents) ; Run-CoworkBridge.bat + le build s'en chargent.
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
$script:MetaDirName = '_bridge'                 # sous-dossier technique dans la destination
$script:TaskName    = 'CoworkBridge-Sync'
$script:DefaultInterval = 30                    # minutes (pull periodique)
$script:LogFile     = $null                     # defini lors de l'installation

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic
[System.Windows.Forms.Application]::EnableVisualStyles()

# ----------------------------------------------------------------------------
# Log
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

# Traduit le code de sortie FreeFileSync en phrase claire pour un non-technicien.
function Get-SyncResultText([int]$code) {
    switch ($code) {
        0       { 'Synchronisation terminée. Tout est à jour.' }
        1       { 'Synchronisation terminée. Quelques fichiers ont été ignorés (verrouillés ou temporaires) — sans impact sur ton travail.' }
        default { 'La synchronisation a rencontré un problème. Relance « Synchroniser maintenant ». Si le problème persiste, contacte ton interlocuteur Drivenlabs.' }
    }
}

# Suppression vers la corbeille (recuperable), jamais en dur.
function Remove-ToRecycleBin([string]$Path) {
    [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory(
        $Path,
        [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
        [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin)
}

# ----------------------------------------------------------------------------
# Detection du montage Google Drive
# ----------------------------------------------------------------------------
# Renvoie une liste d'objets : @{ Type='MyDrive'|'Shared'; Name; Path }
function Get-DriveSources {
    $results = New-Object System.Collections.Generic.List[object]

    # bases candidates : lecteurs PRETS (evite de bloquer sur un lecteur reseau
    # deconnecte) + le home (cas miroir sur C:).
    $bases = @()
    try {
        $bases += ([System.IO.DriveInfo]::GetDrives() |
            Where-Object { try { $_.IsReady } catch { $false } } |
            ForEach-Object { $_.RootDirectory.FullName })
    } catch {}
    $bases += $script:HomeRoot
    $bases = $bases | Select-Object -Unique

    $myDriveNames = @('My Drive', 'Mon Drive')
    $sharedNames  = @('Shared drives', 'Drive partages', 'Drives partages', 'Disques partages')

    foreach ($base in $bases) {
        if (-not (Test-Path $base)) { continue }

        foreach ($md in $myDriveNames) {
            $p = Join-Path $base $md
            if (Test-Path $p) {
                try {
                    Get-ChildItem -LiteralPath $p -Directory -ErrorAction Stop | ForEach-Object {
                        $results.Add([pscustomobject]@{ Type = 'MyDrive'; Name = $_.Name; Path = $_.FullName })
                    }
                } catch { Write-Log "Lecture impossible: $p ($($_.Exception.Message))" 'WARN' }
            }
        }

        foreach ($sd in $sharedNames) {
            $p = Join-Path $base $sd
            if (Test-Path $p) {
                try {
                    Get-ChildItem -LiteralPath $p -Directory -ErrorAction Stop | ForEach-Object {
                        $results.Add([pscustomobject]@{ Type = 'Shared'; Name = $_.Name; Path = $_.FullName })
                    }
                } catch { Write-Log "Lecture impossible: $p ($($_.Exception.Message))" 'WARN' }
            }
        }
    }
    return $results
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
    return $s
}

# $Pairs : liste d'objets @{ Left; Right }  (Left = source Drive, Right = local)
# $Variant : 'TwoWay' (synchro courante) ou 'Mirror' (1er run Drive -> local, sans
#            jamais toucher au cote Drive). Schema verifie contre un vrai .ffs_batch
#            format 13 ; FFS convertit vers l'avant a l'ouverture.
function New-FfsBatch {
    param(
        [object[]]$Pairs,
        [string]$OutPath,
        [ValidateSet('TwoWay','Mirror','Update')][string]$Variant = 'TwoWay'
    )

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
    <Batch>
        <ProgressDialog Minimized="true" AutoClose="true"/>
        <ErrorDialog>Show</ErrorDialog>
        <PostSyncAction>None</PostSyncAction>
        <LogfileFolder MaxCount="0"/>
    </Batch>
</FreeFileSync>
"@
    [System.IO.File]::WriteAllText($OutPath, $xml, (New-Object System.Text.UTF8Encoding($false)))
}

function New-FfsReal {
    param([string[]]$WatchDirs, [string]$FfsExe, [string]$BatchPath, [string]$OutPath)
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
# Autostart : raccourci RealTimeSync dans le dossier Demarrage + tache planifiee
# ----------------------------------------------------------------------------
function Set-StartupShortcut {
    param([string]$RtsExe, [string]$RealPath)
    if (-not $RtsExe) { return $false }
    $startup = [Environment]::GetFolderPath('Startup')
    $lnk = Join-Path $startup 'CoworkBridge.lnk'
    $wsh = New-Object -ComObject WScript.Shell
    $sc = $wsh.CreateShortcut($lnk)
    $sc.TargetPath = $RtsExe
    $sc.Arguments  = '"{0}"' -f $RealPath
    $sc.WindowStyle = 7   # minimise
    $sc.Description = 'Cowork Bridge - synchro temps reel'
    $sc.Save()
    return $true
}

function Remove-StartupShortcut {
    $lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'CoworkBridge.lnk'
    if (Test-Path $lnk) { Remove-Item $lnk -Force }
}

function Register-SyncTask {
    param([string]$FfsExe, [string]$BatchPath, [int]$IntervalMin)
    try {
        Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false -ErrorAction SilentlyContinue
        $action  = New-ScheduledTaskAction -Execute $FfsExe -Argument ('"{0}"' -f $BatchPath)
        $trigger = New-ScheduledTaskTrigger -AtLogOn
        $repeat  = New-ScheduledTaskTrigger -Once -At (Get-Date) `
                    -RepetitionInterval (New-TimeSpan -Minutes $IntervalMin)
        $trigger.Repetition = $repeat.Repetition
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
                    -DontStopIfGoingOnBatteries -StartWhenAvailable `
                    -MultipleInstances IgnoreNew
        Register-ScheduledTask -TaskName $script:TaskName -Action $action -Trigger $trigger `
            -Settings $settings -Description 'Cowork Bridge - synchro periodique Drive -> local' `
            -User $env:USERNAME -RunLevel Limited | Out-Null
        return $true
    } catch {
        Write-Log "Tache planifiee non creee: $($_.Exception.Message)" 'WARN'
        return $false
    }
}

function Unregister-SyncTask {
    Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false -ErrorAction SilentlyContinue
}

# ----------------------------------------------------------------------------
# Config (etat persistant)
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

# Construit la liste des paires + dossiers locaux, avec garde anti-collision de noms.
# Tri déterministe (Type, Name) : l'attribution des noms locaux (et des éventuels
# suffixes anti-collision) reste stable d'un run à l'autre quel que soit l'ordre
# d'entrée — indispensable pour que l'ajout d'un dossier ne renomme pas les existants.
function Build-Pairs { param([object[]]$Selected, [string]$Dest)
    $pairs = New-Object System.Collections.Generic.List[object]
    $used  = New-Object System.Collections.Generic.HashSet[string]
    foreach ($s in ($Selected | Sort-Object Type, Name)) {
        $prefix = if ($s.Type -eq 'Shared') { 'Partage - ' } else { '' }
        $base   = ($prefix + $s.Name) -replace '[\\/:*?"<>|]', '_'
        $localName = $base
        $n = 2
        while (-not $used.Add($localName.ToLowerInvariant())) { $localName = "$base ($n)"; $n++ }
        $localPath = Join-Path $Dest $localName
        $pairs.Add([pscustomobject]@{ Source = $s; Left = $s.Path; Right = $localPath; LocalName = $localName })
    }
    return $pairs
}

# ----------------------------------------------------------------------------
# Application d'une installation
# ----------------------------------------------------------------------------
function Invoke-Install {
    param(
        [object[]]$Selected,    # objets sources (Type/Name/Path)
        [string]$Dest,
        [int]$IntervalMin,
        [object]$Ffs,
        [bool]$FirstRun,        # vrai = nouvelle install (1er run en Miroir)
        [scriptblock]$Status
    )
    & $Status 'Préparation des dossiers...'
    if (-not (Test-Path $Dest)) { New-Item -ItemType Directory -Path $Dest -Force | Out-Null }
    $meta = Get-MetaDir $Dest
    if (-not (Test-Path $meta)) { New-Item -ItemType Directory -Path $meta -Force | Out-Null }
    $script:LogFile = Join-Path $meta 'bridge.log'
    Write-Log "=== Installation : $($Selected.Count) dossier(s), FirstRun=$FirstRun ==="

    $pairs = Build-Pairs -Selected $Selected -Dest $Dest
    $watch = New-Object System.Collections.Generic.List[string]
    foreach ($p in $pairs) {
        if (-not (Test-Path $p.Right)) { New-Item -ItemType Directory -Path $p.Right -Force | Out-Null }
        $watch.Add($p.Right)
        Write-Log "Paire: $($p.Left)  <->  $($p.Right)"
    }
    $pairArray = $pairs | ForEach-Object { [pscustomobject]@{ Left = $_.Left; Right = $_.Right } }

    & $Status 'Génération de la configuration...'
    $batchPath = Join-Path $meta 'bridge.ffs_batch'
    $realPath  = Join-Path $meta 'bridge.ffs_real'
    New-FfsBatch -Pairs $pairArray -OutPath $batchPath -Variant 'TwoWay'
    New-FfsReal  -WatchDirs $watch.ToArray() -FfsExe $Ffs.Exe -BatchPath $batchPath -OutPath $realPath

    & $Status 'Installation de la synchronisation automatique...'
    $hasRts  = Set-StartupShortcut -RtsExe $Ffs.Rts -RealPath $realPath
    $hasTask = Register-SyncTask -FfsExe $Ffs.Exe -BatchPath $batchPath -IntervalMin $IntervalMin

    Save-Config -Dest $Dest -Config ([pscustomobject]@{
        version   = 1
        dest      = $Dest
        interval  = $IntervalMin
        ffsExe    = $Ffs.Exe
        ffsRts    = $Ffs.Rts
        batch     = $batchPath
        real      = $realPath
        # LocalName persiste le nom de dossier local REEL (préfixe + sanitization +
        # suffixe anti-collision) pour que la libération d'espace supprime le bon
        # dossier sans le recalculer. @(...) force un tableau JSON ; au reload via
        # ConvertFrom-Json, toujours réaccéder en @($Config.sources).
        sources   = @($pairs | ForEach-Object { @{ Type = $_.Source.Type; Name = $_.Source.Name; Path = $_.Source.Path; LocalName = $_.LocalName } })
        installed = (Get-Date -Format 's')
    })

    # Premiere synchro : en Miroir Drive -> local sur une nouvelle install
    # (impossible d'effacer cote Drive) ; sinon synchro deux-sens normale.
    & $Status 'Première synchronisation (peut prendre un moment sur un gros dossier)...'
    if ($FirstRun) {
        $firstPath = Join-Path $meta 'bridge-firstrun.ffs_batch'
        New-FfsBatch -Pairs $pairArray -OutPath $firstPath -Variant 'Mirror'
        Write-Log 'Premiere synchro (Miroir Drive -> local)'
        $proc = Start-Process -FilePath $Ffs.Exe -ArgumentList ('"{0}"' -f $firstPath) -PassThru -Wait
    } else {
        Write-Log 'Synchro (deux-sens)'
        $proc = Start-Process -FilePath $Ffs.Exe -ArgumentList ('"{0}"' -f $batchPath) -PassThru -Wait
    }
    Write-Log "Premiere synchro terminee, code $($proc.ExitCode)"

    # demarre RealTimeSync immediatement (sans attendre le prochain logon)
    if ($hasRts) {
        try { Start-Process -FilePath $Ffs.Rts -ArgumentList ('"{0}"' -f $realPath) -WindowStyle Minimized | Out-Null } catch {}
    }

    return [pscustomobject]@{ ExitCode = $proc.ExitCode; Rts = $hasRts; Task = $hasTask; Batch = $batchPath; Local = $watch.ToArray() }
}

# ----------------------------------------------------------------------------
# GUI - selection des dossiers (install ou modification)
# ----------------------------------------------------------------------------
function Show-SelectionDialog {
    param(
        [object[]]$Sources, [object[]]$PreChecked, [string]$Dest, [int]$Interval,
        [string]$Title = 'Installation', [string]$OkLabel = 'Installer'
    )

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "$script:AppName - $Title"
    $form.Size = New-Object System.Drawing.Size(620, 620)
    $form.StartPosition = 'CenterScreen'
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = "Cet outil rend tes dossiers Google Drive accessibles à Claude Cowork." + [Environment]::NewLine +
                "Coche ceux à rendre accessibles. Seuls les dossiers cochés occuperont" + [Environment]::NewLine +
                "de l'espace sur cet ordinateur (tout reste aussi dans Drive)."
    $lbl.Location = New-Object System.Drawing.Point(15, 12)
    $lbl.Size = New-Object System.Drawing.Size(585, 56)
    $form.Controls.Add($lbl)

    $clb = New-Object System.Windows.Forms.CheckedListBox
    $clb.Location = New-Object System.Drawing.Point(15, 74)
    $clb.Size = New-Object System.Drawing.Size(575, 320)
    $clb.CheckOnClick = $true
    $clb.IntegralHeight = $false

    $preset = @{}
    if ($PreChecked) { foreach ($p in $PreChecked) { $preset[$p.Path] = $true } }

    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($s in ($Sources | Sort-Object Type, Name)) {
        $tag = if ($s.Type -eq 'Shared') { '[Partagé] ' } else { '[Mon Drive] ' }
        $idx = $clb.Items.Add(($tag + $s.Name))
        $rows.Add($s)
        if ($preset.ContainsKey($s.Path)) { $clb.SetItemChecked($idx, $true) }
    }
    $form.Controls.Add($clb)

    # destination
    $lblDest = New-Object System.Windows.Forms.Label
    $lblDest.Text = 'Dossier de travail (doit rester dans ton dossier utilisateur) :'
    $lblDest.Location = New-Object System.Drawing.Point(15, 404)
    $lblDest.Size = New-Object System.Drawing.Size(575, 20)
    $form.Controls.Add($lblDest)

    $txtDest = New-Object System.Windows.Forms.TextBox
    $txtDest.Text = $Dest
    $txtDest.Location = New-Object System.Drawing.Point(15, 426)
    $txtDest.Size = New-Object System.Drawing.Size(575, 24)
    $form.Controls.Add($txtDest)

    # intervalle
    $lblInt = New-Object System.Windows.Forms.Label
    $lblInt.Text = 'Récupérer les changements venant de Drive toutes les (minutes) :'
    $lblInt.Location = New-Object System.Drawing.Point(15, 460)
    $lblInt.Size = New-Object System.Drawing.Size(400, 22)
    $form.Controls.Add($lblInt)

    $numInt = New-Object System.Windows.Forms.NumericUpDown
    $numInt.Minimum = 1; $numInt.Maximum = 1440; $numInt.Value = $Interval
    $numInt.Location = New-Object System.Drawing.Point(420, 458)
    $numInt.Size = New-Object System.Drawing.Size(70, 24)
    $form.Controls.Add($numInt)

    $status = New-Object System.Windows.Forms.Label
    $status.Location = New-Object System.Drawing.Point(15, 494)
    $status.Size = New-Object System.Drawing.Size(575, 40)
    $status.ForeColor = [System.Drawing.Color]::DimGray
    $form.Controls.Add($status)

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = $OkLabel
    $btnOk.Location = New-Object System.Drawing.Point(410, 542)
    $btnOk.Size = New-Object System.Drawing.Size(95, 30)
    $form.Controls.Add($btnOk)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = 'Annuler'
    $btnCancel.Location = New-Object System.Drawing.Point(510, 542)
    $btnCancel.Size = New-Object System.Drawing.Size(80, 30)
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($btnCancel)
    $form.CancelButton = $btnCancel

    $script:DialogResult = $null

    $btnOk.Add_Click({
        $checked = @()
        for ($i = 0; $i -lt $clb.Items.Count; $i++) {
            if ($clb.GetItemChecked($i)) { $checked += $rows[$i] }
        }
        if ($checked.Count -eq 0) { $status.Text = 'Coche au moins un dossier.'; $status.ForeColor = [System.Drawing.Color]::Firebrick; return }

        # confinement reel du chemin dans le home (et pas un simple prefixe de chaine)
        $d = $txtDest.Text.Trim()
        $ok = $false
        try {
            $dFull    = [System.IO.Path]::GetFullPath($d).TrimEnd('\')
            $homeFull = [System.IO.Path]::GetFullPath($script:HomeRoot).TrimEnd('\')
            $ok = $dFull.Equals($homeFull, [System.StringComparison]::OrdinalIgnoreCase) -or
                  $dFull.StartsWith($homeFull + '\', [System.StringComparison]::OrdinalIgnoreCase)
        } catch { $ok = $false }
        if (-not $ok) {
            $status.Text = "Le dossier doit être dans : $script:HomeRoot (contrainte Cowork)."
            $status.ForeColor = [System.Drawing.Color]::Firebrick; return
        }
        $script:DialogResult = [pscustomobject]@{
            Selected = $checked
            Dest     = ([System.IO.Path]::GetFullPath($d).TrimEnd('\'))
            Interval = [int]$numInt.Value
        }
        $form.Close()
    })

    [void]$form.ShowDialog()
    return $script:DialogResult
}

# ----------------------------------------------------------------------------
# GUI - panneau de gestion (install existante)
# ----------------------------------------------------------------------------
function Show-ManageDialog {
    param([object]$Config)

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "$script:AppName - Gestion"
    $form.Size = New-Object System.Drawing.Size(540, 420)
    $form.StartPosition = 'CenterScreen'
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

    $lbl = New-Object System.Windows.Forms.Label
    $count = @($Config.sources).Count
    $lbl.Text = "Cowork Bridge est actif." + [Environment]::NewLine +
                "Dossier de travail : $($Config.dest)" + [Environment]::NewLine +
                "Dossiers suivis : $count" + [Environment]::NewLine + [Environment]::NewLine +
                "À connecter dans Cowork (et surtout pas le dossier Google Drive) :" + [Environment]::NewLine +
                "$($Config.dest)"
    $lbl.Location = New-Object System.Drawing.Point(20, 18)
    $lbl.Size = New-Object System.Drawing.Size(490, 110)
    $form.Controls.Add($lbl)

    $btnAdd = New-Object System.Windows.Forms.Button
    $btnAdd.Text = 'Ajouter un dossier'
    $btnAdd.Location = New-Object System.Drawing.Point(20, 138); $btnAdd.Size = New-Object System.Drawing.Size(230, 34)
    $form.Controls.Add($btnAdd)

    $btnSync = New-Object System.Windows.Forms.Button
    $btnSync.Text = 'Synchroniser maintenant'
    $btnSync.Location = New-Object System.Drawing.Point(270, 138); $btnSync.Size = New-Object System.Drawing.Size(230, 34)
    $form.Controls.Add($btnSync)

    $btnEdit = New-Object System.Windows.Forms.Button
    $btnEdit.Text = 'Modifier la sélection'
    $btnEdit.Location = New-Object System.Drawing.Point(20, 180); $btnEdit.Size = New-Object System.Drawing.Size(230, 34)
    $form.Controls.Add($btnEdit)

    $btnOpen = New-Object System.Windows.Forms.Button
    $btnOpen.Text = 'Ouvrir le dossier local'
    $btnOpen.Location = New-Object System.Drawing.Point(270, 180); $btnOpen.Size = New-Object System.Drawing.Size(230, 34)
    $form.Controls.Add($btnOpen)

    $btnUninstall = New-Object System.Windows.Forms.Button
    $btnUninstall.Text = 'Désinstaller Cowork Bridge'
    $btnUninstall.Location = New-Object System.Drawing.Point(20, 222); $btnUninstall.Size = New-Object System.Drawing.Size(230, 34)
    $form.Controls.Add($btnUninstall)

    $status = New-Object System.Windows.Forms.Label
    $status.Location = New-Object System.Drawing.Point(20, 268); $status.Size = New-Object System.Drawing.Size(490, 50)
    $status.ForeColor = [System.Drawing.Color]::DimGray
    $form.Controls.Add($status)

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = 'Fermer'
    $btnClose.Location = New-Object System.Drawing.Point(420, 330); $btnClose.Size = New-Object System.Drawing.Size(90, 30)
    $btnClose.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.Controls.Add($btnClose)

    $script:ManageAction = $null

    $btnSync.Add_Click({
        $status.Text = 'Synchronisation en cours...'; $status.ForeColor = [System.Drawing.Color]::DimGray; $form.Refresh()
        try {
            $p = Start-Process -FilePath $Config.ffsExe -ArgumentList ('"{0}"' -f $Config.batch) -PassThru -Wait
            $status.Text = (Get-SyncResultText ([int]$p.ExitCode))
        } catch { $status.Text = "La synchronisation n'a pas pu démarrer : $($_.Exception.Message)" }
    })
    $btnOpen.Add_Click({ Start-Process explorer.exe -ArgumentList ('"{0}"' -f $Config.dest) })
    $btnAdd.Add_Click({ $script:ManageAction = 'add'; $form.Close() })
    $btnEdit.Add_Click({ $script:ManageAction = 'edit'; $form.Close() })
    $btnUninstall.Add_Click({ $script:ManageAction = 'uninstall'; $form.Close() })

    [void]$form.ShowDialog()
    return $script:ManageAction
}

# ----------------------------------------------------------------------------
# Flux principal
# ----------------------------------------------------------------------------
function Show-Info($msg)  { [void][System.Windows.Forms.MessageBox]::Show($msg, $script:AppName, 'OK', 'Information') }
function Show-Warn($msg)  { [void][System.Windows.Forms.MessageBox]::Show($msg, $script:AppName, 'OK', 'Warning') }
function Confirm-YesNo($msg) { return ([System.Windows.Forms.MessageBox]::Show($msg, $script:AppName, 'YesNo', 'Question') -eq 'Yes') }

function Start-Bridge {
    # 1. FreeFileSync present ?
    $ffs = Find-FreeFileSync
    if (-not $ffs) {
        $m = "Cowork Bridge a besoin d'un logiciel gratuit, FreeFileSync, pour copier tes fichiers." + [Environment]::NewLine +
             "Il n'est pas encore installé sur cet ordinateur." + [Environment]::NewLine + [Environment]::NewLine +
             "Ouvrir la page de téléchargement maintenant ?" + [Environment]::NewLine +
             "Installe FreeFileSync, puis rouvre Cowork Bridge."
        if (Confirm-YesNo $m) { Start-Process 'https://freefilesync.org/download.php' }
        return
    }

    # 2. installation existante ?
    $existing = Load-Config -Dest $script:DefaultDest
    $mode = 'install'
    if ($existing) {
        $action = Show-ManageDialog -Config $existing
        switch ($action) {
            'uninstall' { Invoke-Uninstall -Config $existing; return }
            'add'       { $mode = 'add' }    # ajouter un/des dossier(s) aux dossiers suivis
            'edit'      { $mode = 'edit' }   # revoir toute la selection
            default     { return }
        }
    }

    # 3. detection des sources Drive
    $sources = Get-DriveSources
    if (-not $sources -or $sources.Count -eq 0) {
        $m = "Aucun dossier Google Drive détecté sur cet ordinateur." + [Environment]::NewLine + [Environment]::NewLine +
             "Vérifie que Google Drive pour ordinateur est lancé, que tu y es connecté à ton" + [Environment]::NewLine +
             "compte, et qu'il est réglé sur « Accéder en ligne aux fichiers » (Paramètres →" + [Environment]::NewLine +
             "Préférences → Dossiers de Drive → Options de synchronisation de Mon Drive)." + [Environment]::NewLine + [Environment]::NewLine +
             "Relance ensuite Cowork Bridge."
        Show-Warn $m
        return
    }

    # 4. selection (selon le mode)
    if ($mode -eq 'add') {
        # n'afficher que les dossiers PAS ENCORE suivis ; on ajoute sans rien retirer.
        $trackedPaths = @($existing.sources | ForEach-Object { $_.Path })
        $untracked = @($sources | Where-Object { $trackedPaths -notcontains $_.Path })
        if ($untracked.Count -eq 0) {
            Show-Info("Tous les dossiers Google Drive détectés sont déjà suivis." + [Environment]::NewLine +
                      "Pour en suivre un nouveau, crée-le d'abord dans Google Drive, puis reviens ici.")
            return
        }
        $choice = Show-SelectionDialog -Sources $untracked -PreChecked $null -Dest $existing.dest -Interval ([int]$existing.interval) -Title 'Ajouter un dossier' -OkLabel 'Ajouter'
        if (-not $choice) { return }
        # union avec les dossiers déjà suivis ; dossier de travail inchangé, aucun retrait.
        $choice.Selected = @($existing.sources) + @($choice.Selected)
        $choice.Dest = $existing.dest
    }
    elseif ($mode -eq 'edit') {
        $choice = Show-SelectionDialog -Sources $sources -PreChecked $existing.sources -Dest $existing.dest -Interval ([int]$existing.interval) -Title 'Modifier la sélection' -OkLabel 'Enregistrer'
        if (-not $choice) { return }
    }
    else {
        $choice = Show-SelectionDialog -Sources $sources -PreChecked $null -Dest $script:DefaultDest -Interval $script:DefaultInterval -Title 'Installation' -OkLabel 'Installer'
        if (-not $choice) { return }
    }

    # 5. nettoyage des dossiers retires (modification de selection)
    if ($existing) {
        $newPaths = @($choice.Selected | ForEach-Object { $_.Path })
        # @() requis : ConvertFrom-Json renvoie un scalaire pour un sources mono-element.
        $removed = @($existing.sources | Where-Object { $newPaths -notcontains $_.Path })
        if ($removed.Count -gt 0) {
            $m = "Tu as retiré $($removed.Count) dossier(s) de la sélection." + [Environment]::NewLine + [Environment]::NewLine +
                 "Leur contenu va d'abord être renvoyé vers Google Drive, puis la copie locale" + [Environment]::NewLine +
                 "sera envoyée à la corbeille pour libérer de l'espace. Aucun fichier n'est perdu :" + [Environment]::NewLine +
                 "rien n'est supprimé côté Drive, et la suppression locale est récupérable." + [Environment]::NewLine + [Environment]::NewLine +
                 "Renvoyer vers Drive puis libérer l'espace ?"
            if (Confirm-YesNo $m) {
                $script:LogFile = Join-Path (Get-MetaDir $existing.dest) 'bridge.log'

                # Nom de dossier local RÉEL : persisté en config (LocalName) ; recalcul
                # de repli pour une config antérieure qui ne le porterait pas.
                $removedInfo = foreach ($r in $removed) {
                    $hasLn = ($r.PSObject.Properties.Name -contains 'LocalName') -and $r.LocalName
                    $ln = if ($hasLn) { $r.LocalName }
                          else {
                              $prefix = if ($r.Type -eq 'Shared') { 'Partage - ' } else { '' }
                              ($prefix + $r.Name) -replace '[\\/:*?"<>|]', '_'
                          }
                    [pscustomobject]@{ Local = (Join-Path $existing.dest $ln); Drive = $r.Path }
                }

                # Sauvegarde AVANT suppression : Update local -> Drive (copie seulement,
                # ne supprime jamais rien). On ne relance PAS le batch TwoWay global,
                # qui pourrait propager une suppression locale vers Drive.
                $pushPairs = @($removedInfo | Where-Object { Test-Path $_.Local } |
                               ForEach-Object { [pscustomobject]@{ Left = $_.Local; Right = $_.Drive } })
                $pushed = $true
                if ($pushPairs.Count -gt 0) {
                    $pushBatch = Join-Path (Get-MetaDir $existing.dest) 'bridge-release.ffs_batch'
                    New-FfsBatch -Pairs $pushPairs -OutPath $pushBatch -Variant 'Update'
                    try {
                        $p = Start-Process -FilePath $existing.ffsExe -ArgumentList ('"{0}"' -f $pushBatch) -PassThru -Wait
                        $pushed = ([int]$p.ExitCode -le 1)   # 0 = ok, 1 = avertissements
                        Write-Log "Sauvegarde avant liberation (Update local -> Drive), code $($p.ExitCode)"
                    } catch { $pushed = $false; Write-Log "Sauvegarde avant liberation echouee: $($_.Exception.Message)" 'WARN' }
                }

                if (-not $pushed) {
                    Show-Warn("La sauvegarde vers Google Drive n'a pas abouti." + [Environment]::NewLine +
                              "Par sécurité, les copies locales NE sont PAS supprimées (aucune perte).")
                } else {
                    foreach ($ri in $removedInfo) {
                        if (Test-Path $ri.Local) {
                            try { Remove-ToRecycleBin $ri.Local } catch { Write-Log "Liberation locale echouee (corbeille): $($ri.Local) ($($_.Exception.Message))" 'WARN' }
                        }
                    }
                }
            }
        }
    }

    # 6. application
    $progress = New-Object System.Windows.Forms.Form
    $progress.Text = "$script:AppName"; $progress.Size = New-Object System.Drawing.Size(470, 130)
    $progress.StartPosition = 'CenterScreen'; $progress.ControlBox = $false
    $progress.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $pl = New-Object System.Windows.Forms.Label
    $pl.Location = New-Object System.Drawing.Point(20, 30); $pl.Size = New-Object System.Drawing.Size(420, 60)
    $pl.Text = 'Installation...'
    $progress.Controls.Add($pl)
    $progress.Show(); $progress.Refresh()
    $statusCb = { param($m) $pl.Text = $m; $progress.Refresh() }

    try {
        $res = Invoke-Install -Selected $choice.Selected -Dest $choice.Dest -IntervalMin $choice.Interval `
                              -Ffs $ffs -FirstRun (-not $existing) -Status $statusCb
        $progress.Close()

        $auto = if ($res.Rts -and $res.Task) {
            "La synchronisation tourne maintenant toute seule en arrière-plan :" + [Environment]::NewLine +
            "  - tes modifications sont renvoyées vers Google Drive en temps réel ;" + [Environment]::NewLine +
            "  - les changements venant de Drive sont récupérés dans ton dossier de travail toutes les $($choice.Interval) min."
        } else {
            "La synchronisation automatique n'a pas pu être entièrement configurée." + [Environment]::NewLine +
            "Reporte-toi au guide (dépannage, « Synchro en temps réel absente »)."
        }

        $msg = "Installation terminée." + [Environment]::NewLine + [Environment]::NewLine +
               "Dernière étape, dans Claude Cowork : connecte le dossier ci-dessous —" + [Environment]::NewLine +
               "et surtout pas ton dossier Google Drive :" + [Environment]::NewLine + [Environment]::NewLine +
               "   $($choice.Dest)" + [Environment]::NewLine + [Environment]::NewLine +
               "Si Cowork affiche un dossier vide, c'est presque toujours qu'on a connecté" + [Environment]::NewLine +
               "le dossier Google Drive au lieu de celui-ci." + [Environment]::NewLine + [Environment]::NewLine +
               $auto + [Environment]::NewLine + [Environment]::NewLine +
               "Espace utilisé sur le PC ≈ la taille des dossiers cochés (tout reste aussi dans Drive)." + [Environment]::NewLine + [Environment]::NewLine +
               (Get-SyncResultText ([int]$res.ExitCode))
        Show-Info $msg
    } catch {
        if ($progress.Visible) { $progress.Close() }
        Write-Log "ERREUR installation: $($_.Exception.Message)" 'ERROR'
        Show-Warn("L'installation a échoué :" + [Environment]::NewLine + $($_.Exception.Message) + [Environment]::NewLine + [Environment]::NewLine +
                  "Le détail est dans le journal (bouton « Ouvrir le dossier local », sous-dossier _bridge).")
    }
}

function Invoke-Uninstall {
    param([object]$Config)
    $m = "Désinstaller Cowork Bridge ?" + [Environment]::NewLine + [Environment]::NewLine +
         "Une dernière synchro est lancée, puis la synchronisation automatique est retirée." + [Environment]::NewLine +
         "Ton dossier local n'est PAS supprimé (tu pourras l'effacer à la main plus tard si" + [Environment]::NewLine +
         "tu veux récupérer l'espace). Aucun fichier n'est perdu."
    if (-not (Confirm-YesNo $m)) { return }
    $script:LogFile = Join-Path (Get-MetaDir $Config.dest) 'bridge.log'
    try {
        $p = Start-Process -FilePath $Config.ffsExe -ArgumentList ('"{0}"' -f $Config.batch) -PassThru -Wait
        Write-Log "Synchro avant desinstallation, code $($p.ExitCode)"
    } catch { Write-Log "Synchro avant desinstallation echouee: $($_.Exception.Message)" 'WARN' }
    Unregister-SyncTask
    Remove-StartupShortcut
    try { Get-Process RealTimeSync -ErrorAction SilentlyContinue | Stop-Process -Force } catch {}
    Show-Info("Cowork Bridge est désinstallé (synchronisation automatique retirée)." + [Environment]::NewLine +
              "Ton dossier local est conservé : $($Config.dest)")
}

# ----------------------------------------------------------------------------
try { Start-Bridge }
catch { [void][System.Windows.Forms.MessageBox]::Show(("Erreur inattendue :" + [Environment]::NewLine + $($_.Exception.Message)), $script:AppName, 'OK', 'Error') }
