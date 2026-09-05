#ifndef AppVersion
  #define AppVersion "0.2.0"
#endif
[Setup]
AppId={{67B6BDB0-F52B-4F15-BDDE-6B2728EED154}
AppName=Remodex
AppVersion={#AppVersion}
VersionInfoVersion=0.5.0.0
AppPublisher=Remodex
DefaultDirName={localappdata}\Programs\Remodex
DefaultGroupName=Remodex
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.22000
OutputDir=..\build\windows
OutputBaseFilename=Remodex-{#AppVersion}-windows-x64-setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayIcon={app}\Remodex.exe
CloseApplications=yes
RestartApplications=no
AppMutex=Local\Remodex.Desktop
SetupLogging=no

[Languages]
Name: "chinesesimp"; MessagesFile: "ChineseSimplified.isl"

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; Flags: unchecked
Name: "startup"; Description: "登录 Windows 时启动 Remodex"

[Files]
Source: "..\build\windows\app\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Remodex"; Filename: "{app}\Remodex.exe"
Name: "{group}\卸载 Remodex"; Filename: "{uninstallexe}"
Name: "{userdesktop}\Remodex"; Filename: "{app}\Remodex.exe"; Tasks: desktopicon

[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "Remodex"; ValueData: """{app}\Remodex.exe"""; Flags: uninsdeletevalue; Tasks: startup

[Run]
Filename: "{app}\Remodex.exe"; Description: "启动 Remodex"; Flags: nowait postinstall skipifsilent

[Code]
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usPostUninstall then
    if not UninstallSilent then
      if MsgBox('是否同时删除 Remodex 的本机配置与配对凭据？不会删除 Codex、Git 或项目文件。离线卸载不会撤销服务器上的设备，请在后台单独撤销。', mbConfirmation, MB_YESNO) = IDYES then
        DelTree(ExpandConstant('{localappdata}\Remodex'), True, True, True);
end;
