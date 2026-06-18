; ============================================================================
;  Cowork Bridge - script d'installation Inno Setup
;  Produit un installeur Windows pro (assistant standard, menu Démarrer,
;  désinstalleur dans "Ajouter/supprimer des programmes"), per-user (sans admin).
;
;  Compilé sur Windows (runner CI GitHub Actions ou machine Windows) :
;     ISCC.exe setup.iss
;  -> sortie : Output\CoworkBridge-Setup-<version>.exe
;
;  NOTE LICENCE : cet installeur NE redistribue PAS FreeFileSync (donationware
;  propriétaire ; droits de redistribution à vérifier). Il installe nos fichiers
;  et la logique de pont ; le script détecte FreeFileSync et guide l'utilisateur
;  s'il manque. Le bundling/téléchargement-à-l'install de FFS sera ajouté une
;  fois la licence vérifiée (voir CLAUDE.md).
; ============================================================================

#define MyAppName "Drivenlabs Cowork Bridge"
#define MyAppShortName "Cowork Bridge"
; MyAppVersion peut être injecté par la CI via ISCC /DMyAppVersion=x.y.z ;
; sinon valeur par défaut pour une compilation locale.
#ifndef MyAppVersion
  #define MyAppVersion "1.0.0"
#endif
#define MyAppPublisher "Drivenlabs"
#define MyAppURL "https://drivenlabs.fr"

[Setup]
AppId={{561E3A3F-18D0-4973-A720-DE3AF610FF3C}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
VersionInfoVersion={#MyAppVersion}
VersionInfoCompany={#MyAppPublisher}
VersionInfoDescription={#MyAppName} Setup

; per-user : pas d'UAC, installe dans %LocalAppData%\Programs (cohérent avec un
; outil qui travaille dans le home de l'utilisateur).
PrivilegesRequired=lowest
DefaultDirName={autopf}\{#MyAppShortName}
DefaultGroupName={#MyAppShortName}
DisableProgramGroupPage=yes
DisableDirPage=yes

OutputDir=Output
OutputBaseFilename=CoworkBridge-Setup-{#MyAppVersion}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesInstallIn64BitMode=x64compatible

; Icône d'app (à fournir dans assets\app.ico pour un rendu brandé). Décommenter
; quand le .ico Drivenlabs est en place ; sinon Inno utilise l'icône par défaut.
;SetupIconFile=assets\app.ico
;UninstallDisplayIcon={app}\app.ico

[Languages]
Name: "french"; MessagesFile: "compiler:Languages\French.isl"

[Files]
Source: "Install-CoworkBridge.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "Run-CoworkBridge.bat";     DestDir: "{app}"; Flags: ignoreversion
Source: "GUIDE.md";                 DestDir: "{app}"; Flags: ignoreversion isreadme
; Source: "assets\app.ico";         DestDir: "{app}"; Flags: ignoreversion

[Icons]
; Lancement sans console qui flashe : powershell en fenêtre cachée, l'UI WinForms s'affiche.
Name: "{group}\Configurer {#MyAppShortName}"; \
    Filename: "powershell.exe"; \
    Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File ""{app}\Install-CoworkBridge.ps1"""; \
    WorkingDir: "{app}"; \
    Comment: "Ouvrir l'installeur / le panneau de gestion de Cowork Bridge"
Name: "{group}\Guide {#MyAppShortName}"; Filename: "{app}\GUIDE.md"
Name: "{group}\Désinstaller {#MyAppShortName}"; Filename: "{uninstallexe}"

[Run]
; Proposer de lancer la configuration à la fin de l'installation.
Filename: "powershell.exe"; \
    Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File ""{app}\Install-CoworkBridge.ps1"""; \
    WorkingDir: "{app}"; \
    Description: "Configurer {#MyAppShortName} maintenant"; \
    Flags: postinstall nowait skipifsilent

[UninstallRun]
; Désinstaller le programme retire aussi la synchro de fond (tâche planifiée +
; raccourci de démarrage + RealTimeSync). Les données locales (CoworkWork) sont
; volontairement CONSERVÉES — on ne supprime jamais les fichiers de l'utilisateur.
Filename: "powershell.exe"; \
    Parameters: "-NoProfile -ExecutionPolicy Bypass -Command ""Unregister-ScheduledTask -TaskName 'CoworkBridge-Sync' -Confirm:$false -ErrorAction SilentlyContinue; Remove-Item (Join-Path ([Environment]::GetFolderPath('Startup')) 'CoworkBridge.lnk') -Force -ErrorAction SilentlyContinue; Get-Process RealTimeSync -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue"""; \
    Flags: runhidden; RunOnceId: "RemoveCoworkBridgeSync"
