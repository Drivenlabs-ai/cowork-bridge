<#
    Banc de test du moteur de synchronisation.
    ------------------------------------------
    Tourne sur Windows PowerShell 5.1 (cible réelle) et vérifie le COMPORTEMENT, pas la syntaxe.
    Deux dossiers locaux tiennent lieu de Drive et de dossier de travail : aucune dépendance à
    Google Drive pour ordinateur. Ce que ce banc ne couvre pas reste dans la checklist manuelle
    du CLAUDE.md (placeholders non hydratés, ERROR 1450, corbeille Google).

    Usage :  powershell -ExecutionPolicy Bypass -File tests\Run-Tests.ps1 -RclonePath <chemin>
    Sortie :  une ligne par cas, code de sortie 1 si un seul cas échoue.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RclonePath,
    [string]$Filter
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'Install-CoworkBridge.ps1') -LibraryOnly

if (-not (Test-Path -LiteralPath $RclonePath)) { throw "rclone introuvable : $RclonePath" }

# Le banc mesure la logique de synchronisation, pas la politique de reprise de rclone. Sans
# cette surcharge, chaque cas qui provoque une erreur attend les 30 s de --retries-sleep et le
# banc passe de quelques secondes à plusieurs minutes. Les autres drapeaux restent ceux du produit.
$script:RcloneCommonFlags = @('--checkers', '1', '--transfers', '4', '--local-no-preallocate', '--retries', '1')
$script:Rc = [pscustomobject]@{ Exe = $RclonePath }
$script:Failures = 0
$script:Ran = 0
$script:Root = Join-Path $env:TEMP ('cwb-tests-' + [guid]::NewGuid().ToString('N').Substring(0, 8))

# ---------------------------------------------------------------- infrastructure

# Un cas = un dossier Drive, un ou plusieurs dossiers de travail, un _bridge par poste.
function New-Case {
    # PowerShell ignore la casse des variables : nommer la liste $posts écraserait le paramètre
    # $Posts, typé [int], et la conversion échouerait sur tous les cas d'un coup.
    param([string]$Name, [int]$PostCount = 1)
    $case = Join-Path $script:Root $Name
    New-Item -ItemType Directory -Path (Join-Path $case 'drive') -Force | Out-Null
    Set-Marker (Join-Path $case 'drive')
    $posts = @()
    for ($i = 1; $i -le $PostCount; $i++) {
        $dest = Join-Path $case ('poste' + $i)
        $local = Join-Path $dest 'Dossier'
        $meta = Join-Path $dest $script:MetaDirName
        New-Item -ItemType Directory -Path $local -Force | Out-Null
        New-Item -ItemType Directory -Path $meta -Force | Out-Null
        New-FiltersFile (Join-Path $meta 'filters.txt') | Out-Null
        Set-Marker $local
        $posts += [pscustomobject]@{ Dest = $dest; Local = $local; Meta = $meta }
    }
    return [pscustomobject]@{ Path = $case; Drive = (Join-Path $case 'drive'); Posts = $posts }
}

# Un passage de synchro sur un poste, comme l'agent le ferait.
function Invoke-Pass {
    param([object]$Case, [int]$Post = 1)
    $p = $Case.Posts[$Post - 1]
    return (Sync-Pair -Rclone $script:Rc -DrivePath $Case.Drive -LocalPath $p.Local `
                      -MetaDir $p.Meta -LocalName 'Dossier')
}

function Set-File {
    param([string]$Folder, [string]$Name, [string]$Content = 'contenu')
    $p = Join-Path $Folder $Name
    $dir = Split-Path -Parent $p
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($p, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

# Contenu d'un dossier, marqueur exclu, chemins relatifs en slash, trié : comparable à l'oeil.
function Get-Content-Set {
    param([string]$Folder)
    if (-not (Test-Path -LiteralPath $Folder)) { return '' }
    $items = Get-ChildItem -LiteralPath $Folder -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne $script:MarkerName } |
        ForEach-Object { $_.FullName.Substring($Folder.Length + 1).Replace('\', '/') }
    return (($items | Sort-Object) -join ' ')
}

function Assert-Equal {
    param([string]$Label, [string]$Expected, [string]$Actual)
    if ($Expected -eq $Actual) {
        Write-Host ("    ok   " + $Label) -ForegroundColor DarkGray
    } else {
        Write-Host ("    ECHEC " + $Label) -ForegroundColor Red
        Write-Host ("           attendu : '" + $Expected + "'") -ForegroundColor Red
        Write-Host ("           obtenu  : '" + $Actual + "'") -ForegroundColor Red
        $script:Failures++
    }
}

function Assert-Code {
    param([string]$Label, [int]$Expected, $Actual)
    # Une passe doit rendre UN entier. Si elle rend plusieurs objets, c'est qu'une instruction
    # écrit dans le pipeline sans être capturée : on nomme le coupable plutôt que de laisser
    # PowerShell se plaindre d'une conversion impossible.
    if ($Actual -is [array]) {
        Write-Host ("    ECHEC " + $Label + " : la passe a rendu " + $Actual.Count + " valeurs au lieu d'une") -ForegroundColor Red
        for ($i = 0; $i -lt $Actual.Count; $i++) {
            $v = $Actual[$i]
            $tn = 'null'; if ($null -ne $v) { $tn = $v.GetType().FullName }
            $txt = ''; if ($null -ne $v) { $txt = ($v | Out-String).Trim() }
            if ($txt.Length -gt 120) { $txt = $txt.Substring(0, 120) }
            Write-Host ("           [$i] ($tn) $txt") -ForegroundColor Red
        }
        $script:Failures++
        return
    }
    Assert-Equal $Label ([string]$Expected) ([string]$Actual)
}

function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    if ($Filter -and $Name -notlike "*$Filter*") { return }
    $script:Ran++
    Write-Host ("  " + $Name) -ForegroundColor Cyan
    try { & $Body } catch {
        Write-Host ("    ECHEC exception : " + $_.Exception.Message) -ForegroundColor Red
        # La pile dit QUELLE ligne a levé : sans elle, une conversion ratée en profondeur
        # ressemble à n'importe quelle autre et se cherche à l'aveugle.
        foreach ($l in ($_.ScriptStackTrace -split "`n")) { Write-Host ("           " + $l.Trim()) -ForegroundColor DarkRed }
        $script:Failures++
    }
}

# ---------------------------------------------------------------- les cas

Write-Host ""
Write-Host "Banc moteur de synchronisation" -ForegroundColor White

# Chaque brique doit rendre EXACTEMENT une valeur. Une instruction qui écrit dans le pipeline
# sans être capturée transforme un code de sortie en tableau, et la passe entière échoue sur
# une conversion. Ce cas isole la brique fautive au lieu de laisser deviner.
Test-Case 'fumee : chaque brique rend une seule valeur' {
    $c = New-Case 'fumee'
    Set-File $c.Drive 'a.md'
    $filters = Join-Path $c.Posts[0].Meta 'filters.txt'
    $probes = @(
        @{ Nom = 'Get-FolderListing'; Bloc = { Get-FolderListing -RcloneExe $script:Rc.Exe -Path $c.Drive -FiltersFile $filters } }
        @{ Nom = 'Invoke-RcloneRun';  Bloc = { Invoke-RcloneRun -RcloneExe $script:Rc.Exe -ArgLine ('lsf "{0}"' -f $c.Drive) -Label 'sonde' } }
        @{ Nom = 'New-PassFilterFile'; Bloc = { New-PassFilterFile -MetaDir $c.Posts[0].Meta -LocalName 'Dossier' -BaseFilters $filters -Protect @() } }
        @{ Nom = 'Write-PairIndex';   Bloc = { Write-PairIndex (Get-PairIndexPath $c.Posts[0].Meta 'sonde' 'local') @{ 'x.md' = '2026-01-01 00:00:00;1' } } }
        @{ Nom = 'Write-SyncStatus';  Bloc = { Write-SyncStatus -MetaDir $c.Posts[0].Meta -LocalName 'sonde' -Code 0 } }
        @{ Nom = 'Set-Marker';        Bloc = { Set-Marker $c.Drive } }
        @{ Nom = 'Get-SyncPlan';      Bloc = { Get-SyncPlan -IndexLocal @{} -IndexDrive @{} -Local @{} -Drive @{} } }
    )
    foreach ($p in $probes) {
        $out = @(& $p.Bloc)
        $attendu = 1
        if ($p.Nom -eq 'Write-PairIndex' -or $p.Nom -eq 'Write-SyncStatus' -or $p.Nom -eq 'Set-Marker') { $attendu = 0 }
        if ($out.Count -ne $attendu) {
            Write-Host ("    ECHEC " + $p.Nom + " rend " + $out.Count + " valeur(s), attendu " + $attendu) -ForegroundColor Red
            for ($i = 0; $i -lt $out.Count; $i++) {
                $v = $out[$i]
                $tn = 'null'; if ($null -ne $v) { $tn = $v.GetType().FullName }
                $txt = ''; if ($null -ne $v) { $txt = ($v | Out-String).Trim() }
                if ($txt.Length -gt 100) { $txt = $txt.Substring(0, 100) }
                Write-Host ("           [$i] ($tn) $txt") -ForegroundColor Red
            }
            $script:Failures++
        } else {
            Write-Host ("    ok   " + $p.Nom) -ForegroundColor DarkGray
        }
    }
}

Test-Case 'suppression simple : le Drive supprime, le local suit et ne rejoue pas' {
    $c = New-Case 'suppr-simple'
    'a', 'b', 'c', 'd' | ForEach-Object { Set-File $c.Drive "$_.md" }
    Assert-Code 'premier passage' 0 (Invoke-Pass $c)
    Assert-Equal 'local aligné' 'a.md b.md c.md d.md' (Get-Content-Set $c.Posts[0].Local)

    Remove-Item -LiteralPath (Join-Path $c.Drive 'b.md') -Force
    Assert-Code 'passage après suppression' 0 (Invoke-Pass $c)
    Assert-Equal 'b.md a disparu du local' 'a.md c.md d.md' (Get-Content-Set $c.Posts[0].Local)

    Assert-Code 'passage suivant' 0 (Invoke-Pass $c)
    Assert-Equal 'b.md ne revient pas sur le Drive' 'a.md c.md d.md' (Get-Content-Set $c.Drive)
}

Test-Case 'retrait d un dossier volumineux : passe au premier passage' {
    $c = New-Case 'suppr-volumineux'
    1..8 | ForEach-Object { Set-File $c.Drive "client/f$_.md" }
    1..2 | ForEach-Object { Set-File $c.Drive "reste/g$_.md" }
    Assert-Code 'premier passage' 0 (Invoke-Pass $c)

    # 8 fichiers sur 10 : bien au-delà des 25 % qui gelaient un run entier avec l ancien moteur
    Remove-Item -LiteralPath (Join-Path $c.Drive 'client') -Recurse -Force
    Assert-Code 'passage après retrait' 0 (Invoke-Pass $c)
    Assert-Equal 'le dossier client a disparu du local' 'reste/g1.md reste/g2.md' (Get-Content-Set $c.Posts[0].Local)
}

Test-Case 'fichier local illisible : la suppression passe quand meme (le blocage client)' {
    $c = New-Case 'fichier-illisible'
    'a', 'b', 'c' | ForEach-Object { Set-File $c.Drive "$_.md" }
    Assert-Code 'premier passage' 0 (Invoke-Pass $c)

    # Verrou exclusif : ni lecture ni écriture par un tiers, ce que produit un document ouvert.
    # Le verrou Windows n'existe pas sur les autres systèmes, où le droit de lecture le remplace :
    # les deux rendent le fichier incopiable, qui est la seule chose que ce cas vérifie.
    $bloque = Join-Path $c.Posts[0].Local 'bloque.md'
    Set-File $c.Posts[0].Local 'bloque.md' 'verrouille'
    $stream = [System.IO.File]::Open($bloque, 'Open', 'ReadWrite', 'None')
    if (-not $script:OnWindows) { & chmod 000 $bloque }
    try {
        Remove-Item -LiteralPath (Join-Path $c.Drive 'b.md') -Force
        Invoke-Pass $c | Out-Null
        # Le fichier verrouillé ne doit bloquer ni la suppression, ni l'alignement.
        Assert-Equal 'b.md ne remonte pas sur le Drive' 'a.md c.md' (Get-Content-Set $c.Drive)
        Assert-Equal 'la suppression descend malgré le verrou' 'a.md bloque.md c.md' (Get-Content-Set $c.Posts[0].Local)
        Invoke-Pass $c | Out-Null
        Assert-Equal 'toujours pas au passage suivant' 'a.md c.md' (Get-Content-Set $c.Drive)
        Assert-Equal 'et le fichier verrouillé est toujours là' 'a.md bloque.md c.md' (Get-Content-Set $c.Posts[0].Local)
    } finally {
        $stream.Close()
        if (-not $script:OnWindows) { & chmod 644 $bloque }
    }

    # Verrou levé : le fichier rejoint le Drive au passage suivant, rien n'a été perdu.
    Assert-Code 'passage après déverrouillage' 0 (Invoke-Pass $c)
    Assert-Equal 'bloque.md est monté' 'a.md bloque.md c.md' (Get-Content-Set $c.Drive)
}

Test-Case 'multi-postes, fichier intact ailleurs : la suppression descend partout' {
    $c = New-Case 'multi-intact' 2
    'a', 'b' | ForEach-Object { Set-File $c.Drive "$_.md" }
    Invoke-Pass $c 1 | Out-Null
    Invoke-Pass $c 2 | Out-Null

    Remove-Item -LiteralPath (Join-Path $c.Drive 'b.md') -Force
    Invoke-Pass $c 1 | Out-Null
    Assert-Equal 'poste 1 a perdu b.md' 'a.md' (Get-Content-Set $c.Posts[0].Local)
    Invoke-Pass $c 2 | Out-Null
    Assert-Equal 'poste 2 aussi' 'a.md' (Get-Content-Set $c.Posts[1].Local)
    Assert-Equal 'et b.md reste supprimé du Drive' 'a.md' (Get-Content-Set $c.Drive)
}

Test-Case 'multi-postes, fichier modifie ailleurs : la suppression gagne (ancien M1)' {
    $c = New-Case 'multi-modifie' 2
    'a', 'b' | ForEach-Object { Set-File $c.Drive "$_.md" }
    Invoke-Pass $c 1 | Out-Null
    Invoke-Pass $c 2 | Out-Null

    # Le poste 2 modifie b.md ; le poste 1 le supprime sur le Drive avant que 2 n ait resynchronisé
    Set-File $c.Posts[1].Local 'b.md' 'version du poste 2'
    Remove-Item -LiteralPath (Join-Path $c.Drive 'b.md') -Force
    Invoke-Pass $c 2 | Out-Null

    Assert-Equal 'b.md ne remonte pas sur le Drive' 'a.md' (Get-Content-Set $c.Drive)
    Assert-Equal 'et disparaît du poste 2' 'a.md' (Get-Content-Set $c.Posts[1].Local)
    $trash = Join-Path $c.Posts[1].Meta 'trash'
    $saved = (Get-ChildItem -LiteralPath $trash -Recurse -File -Filter 'b.md' -ErrorAction SilentlyContinue | Measure-Object).Count
    Assert-Equal 'la version du poste 2 est en sauvegarde' '1' ([string]$saved)
}

Test-Case 'creation locale : ce que Cowork ecrit remonte sur le Drive' {
    $c = New-Case 'creation-locale'
    Set-File $c.Drive 'a.md'
    Invoke-Pass $c | Out-Null

    Set-File $c.Posts[0].Local 'skills/nouveau.md' 'produit par Cowork'
    Assert-Code 'passage' 0 (Invoke-Pass $c)
    Assert-Equal 'le fichier est sur le Drive' 'a.md skills/nouveau.md' (Get-Content-Set $c.Drive)
    Assert-Equal 'et toujours en local' 'a.md skills/nouveau.md' (Get-Content-Set $c.Posts[0].Local)
}

Test-Case 'modification locale : elle remonte sans etre ecrasee' {
    $c = New-Case 'modif-locale'
    Set-File $c.Drive 'a.md' 'version initiale'
    Invoke-Pass $c | Out-Null

    Set-File $c.Posts[0].Local 'a.md' 'version modifiee en local'
    Assert-Code 'passage' 0 (Invoke-Pass $c)
    $onDrive = [System.IO.File]::ReadAllText((Join-Path $c.Drive 'a.md'))
    Assert-Equal 'le Drive porte la version locale' 'version modifiee en local' $onDrive
}

Test-Case 'suppression locale : elle se propage au Drive' {
    $c = New-Case 'suppr-locale'
    'a', 'b', 'c' | ForEach-Object { Set-File $c.Drive "$_.md" }
    Invoke-Pass $c | Out-Null

    Remove-Item -LiteralPath (Join-Path $c.Posts[0].Local 'b.md') -Force
    Assert-Code 'passage' 0 (Invoke-Pass $c)
    Assert-Equal 'b.md a quitté le Drive' 'a.md c.md' (Get-Content-Set $c.Drive)
    Assert-Equal 'et ne redescend pas' 'a.md c.md' (Get-Content-Set $c.Posts[0].Local)
}

Test-Case 'renommage local : le Drive suit, sans doublon' {
    $c = New-Case 'renommage'
    Set-File $c.Drive 'ancien.md' 'texte'
    Invoke-Pass $c | Out-Null

    Move-Item -LiteralPath (Join-Path $c.Posts[0].Local 'ancien.md') -Destination (Join-Path $c.Posts[0].Local 'nouveau.md')
    Assert-Code 'passage' 0 (Invoke-Pass $c)
    Assert-Equal 'le Drive porte le nouveau nom seul' 'nouveau.md' (Get-Content-Set $c.Drive)
}

Test-Case 'garde-fou : un local vide ne vide pas le Drive' {
    $c = New-Case 'garde-fou'
    1..20 | ForEach-Object { Set-File $c.Drive "f$_.md" }
    Invoke-Pass $c | Out-Null

    # Dossier local vidé par accident (profil abimé, disque, mauvaise manipulation)
    Get-ChildItem -LiteralPath $c.Posts[0].Local -File -Force |
        Where-Object { $_.Name -ne $script:MarkerName } | Remove-Item -Force
    $code = Invoke-Pass $c
    Assert-Code 'code garde-fou' 91 $code
    Assert-Equal 'le Drive est intact' (($(1..20 | ForEach-Object { "f$_.md" }) | Sort-Object) -join ' ') (Get-Content-Set $c.Drive)
    Assert-Equal 'et le local a été restauré' (($(1..20 | ForEach-Object { "f$_.md" }) | Sort-Object) -join ' ') (Get-Content-Set $c.Posts[0].Local)
}

Test-Case 'Drive non monte : aucune action, code neutre' {
    $c = New-Case 'drive-absent'
    Set-File $c.Drive 'a.md'
    Invoke-Pass $c | Out-Null
    Remove-Item -LiteralPath $c.Drive -Recurse -Force

    Assert-Code 'sentinelle Drive absent' 90 (Invoke-Pass $c)
    Assert-Equal 'le local est intact' 'a.md' (Get-Content-Set $c.Posts[0].Local)
}

Test-Case 'migration depuis bisync : le premier passage ne remonte rien' {
    $c = New-Case 'migration'
    Set-File $c.Drive 'garde.md'
    # État hérité : le local porte des fichiers que le Drive n a plus (ce que le client a rangé),
    # plus un dossier d état bisync. Aucun index : le passage doit être une descente seule.
    Set-File $c.Posts[0].Local 'garde.md'
    Set-File $c.Posts[0].Local 'range-sur-le-drive.md' 'supprimé côté Drive il y a trois semaines'
    New-Item -ItemType Directory -Path (Join-Path $c.Posts[0].Meta 'bisync-state') -Force | Out-Null
    Set-File (Join-Path $c.Posts[0].Meta 'bisync-state') 'Dossier.synced' ''

    Assert-Code 'passage de migration' 0 (Invoke-Pass $c)
    Assert-Equal 'rien n a remonté sur le Drive' 'garde.md' (Get-Content-Set $c.Drive)
    Assert-Equal 'le local est aligné' 'garde.md' (Get-Content-Set $c.Posts[0].Local)
    $trash = Join-Path $c.Posts[0].Meta 'trash'
    $saved = (Get-ChildItem -LiteralPath $trash -Recurse -File -Filter 'range-sur-le-drive.md' -ErrorAction SilentlyContinue | Measure-Object).Count
    Assert-Equal 'l orphelin local est en sauvegarde' '1' ([string]$saved)
}

# ---------------------------------------------------------------- verdict

Write-Host ""
if ($script:Failures -eq 0) {
    Write-Host ("$script:Ran cas, tout passe.") -ForegroundColor Green
} else {
    Write-Host ("$script:Ran cas, $script:Failures assertion(s) en échec.") -ForegroundColor Red
}
try { Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue } catch {}
if ($script:Failures -gt 0) { exit 1 }
exit 0
