; Burrow installer (Inno Setup 6). Built by build.bat.
[Setup]
AppId={{B2F6C9A4-5D1E-4C7B-9A3E-0B7D1E2F4A10}
AppName=Burrow
AppVersion=1.0.0
AppPublisher=Burrow
DefaultDirName={autopf}\Burrow
DefaultGroupName=Burrow
UninstallDisplayIcon={app}\Burrow.exe
OutputDir=installer
OutputBaseFilename=Burrow-Setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesInstallIn64BitMode=x64compatible
; Asks "Install for all users / only for me" at the start of setup
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"; GroupDescription: "Shortcuts:"; Flags: unchecked

[Files]
Source: "dist\Burrow.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "wstunnel.exe"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist

[Icons]
Name: "{autoprograms}\Burrow"; Filename: "{app}\Burrow.exe"
Name: "{autodesktop}\Burrow"; Filename: "{app}\Burrow.exe"; Tasks: desktopicon

[Run]
; shellexec lets Windows show the admin prompt Burrow.exe requires
Filename: "{app}\Burrow.exe"; Description: "Launch Burrow"; Flags: nowait postinstall skipifsilent shellexec
