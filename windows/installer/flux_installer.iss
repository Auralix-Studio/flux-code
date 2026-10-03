; Script de Inno Setup para Flux
; Documentación oficial: https://jrsoftware.org/isinfo.php

#define MyAppName "Flux"
#ifndef MyAppVersion
  #error Build through scripts/build_installer.ps1 to supply the version
#endif
#define MyAppPublisher "Alexito"
#define MyAppExeName "flux.exe"
#define MyAppAssocName MyAppName + " File"
#define MyAppAssocExt ".m3u"
#define MyAppAssocKey StringChange(MyAppAssocName, " ", "") + MyAppAssocExt

[Setup]
; ID único de aplicación generado para Flux
AppId={D37F8A6B-9143-4C7E-B3DE-5E87D70A1172}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
AllowNoIcons=yes
; Icono para el instalador y desinstalador
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
; Carpeta de salida del instalador y nombre del archivo ejecutable
OutputDir=..\..\build\installer
OutputBaseFilename=Flux_Setup_v{#MyAppVersion}
; Compresión moderna de alto rendimiento
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
; Configuración de arquitectura x64
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; Permite al usuario elegir si instalar para el usuario actual o para todos
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog commandline
DisableProgramGroupPage=auto

[Languages]
Name: "spanish"; MessagesFile: "compiler:Languages\Spanish.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
; Opción para crear acceso directo en el escritorio (marcada por defecto, configurable)
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
; Archivos compilados en Release
Source: "..\..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs; Excludes: "*.pdb"

[Icons]
; Acceso directo en el Menú Inicio
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
; Acceso directo en el Escritorio (controlado por la tarea opcional)
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
; Opción para iniciar la aplicación al terminar la instalación
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent
