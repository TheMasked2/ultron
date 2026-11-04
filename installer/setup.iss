; Ultron installer (Inno Setup 6.3+). Build with installer\build.ps1.

#define AppName "Ultron"
#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif
#ifndef UvExe
  #error Pass /DUvExe=<path to uv.exe> (build.ps1 does this)
#endif

[Setup]
AppId={{D7E2A915-3C4B-4F6E-8A1D-5B9C0E7F2A63}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher=TheMasked2
DefaultDirName={localappdata}\Programs\{#AppName}
PrivilegesRequired=lowest
DisableProgramGroupPage=yes
OutputDir=Output
OutputBaseFilename=UltronSetup
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
UninstallDisplayName={#AppName}
CloseApplications=no

[Messages]
WelcomeLabel2=This installs [name/ver], open source game clipping with OBS.%n%nWhile you play, Ultron points OBS at your game and keeps the last minutes ready. Say "Ultron, clip that" (or use OBS's Save Replay hotkey) to save them. You can also start, stop and pause recording by voice.%n%nYou need OBS Studio (obsproject.com), a microphone and an internet connection: setup downloads Python and the speech models (a few hundred MB). Everything stays in the folder you pick next.
FinishedLabel=Ultron is installed. Start a game, then say "Ultron, clip that" whenever something happens.%n%nUntil the Ultron wake word ships, Ultron answers to "Hey Jarvis".

[Tasks]
Name: startup; Description: "Start with Windows (recommended)"
Name: obs; Description: "Set up OBS for me (WebSocket, replay buffer, scene, sources and audio tracks)"

[Files]
Source: "..\ultron\*.py"; DestDir: "{app}\ultron"; Flags: ignoreversion
Source: "..\pyproject.toml"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\uv.lock"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\setup.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\env.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\run.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\run.cmd"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\start-hidden.vbs"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\restart.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\models\wake\ultron.onnx"; DestDir: "{app}\models\wake"; Flags: ignoreversion
; Keep the user's settings on upgrade.
Source: "..\config.toml"; DestDir: "{app}"; Flags: onlyifdoesntexist uninsneveruninstall
Source: "obs-setup.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#UvExe}"; DestDir: "{app}\tools"; Flags: ignoreversion

[Icons]
Name: "{userstartup}\{#AppName}"; Filename: "{sys}\wscript.exe"; Parameters: """{app}\start-hidden.vbs"""; WorkingDir: "{app}"; Comment: "Game clipping with OBS"; Tasks: startup
Name: "{userprograms}\{#AppName}\Start {#AppName}"; Filename: "{sys}\wscript.exe"; Parameters: """{app}\start-hidden.vbs"""; WorkingDir: "{app}"
Name: "{userprograms}\{#AppName}\Restart {#AppName}"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\restart.ps1"""; WorkingDir: "{app}"; Flags: runminimized
Name: "{userprograms}\{#AppName}\Settings (config.toml)"; Filename: "{sys}\notepad.exe"; Parameters: """{app}\config.toml"""
Name: "{userprograms}\{#AppName}\Ultron log"; Filename: "{app}\ultron.log"
Name: "{userprograms}\{#AppName}\Repair (download models again)"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -NoExit -File ""{app}\setup.ps1"""; WorkingDir: "{app}"
Name: "{userprograms}\{#AppName}\Set up OBS again"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -NoExit -File ""{app}\obs-setup.ps1"" -CloseObs"; WorkingDir: "{app}"
Name: "{userprograms}\{#AppName}\Uninstall {#AppName}"; Filename: "{uninstallexe}"

[Run]
Filename: "{sys}\wscript.exe"; Parameters: """{app}\start-hidden.vbs"""; Description: "Start Ultron now"; Flags: postinstall nowait skipifsilent

[UninstallRun]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "{code:StopCommand}"; Flags: runhidden; RunOnceId: "StopUltron"

[UninstallDelete]
Type: filesandordirs; Name: "{app}\.venv"
Type: filesandordirs; Name: "{app}\.cache"
Type: filesandordirs; Name: "{app}\models"
Type: filesandordirs; Name: "{app}\cache"
Type: filesandordirs; Name: "{app}\ultron\__pycache__"
Type: files; Name: "{app}\ultron.log*"
Type: files; Name: "{app}\ultron.out"
Type: files; Name: "{app}\ultron.pid"

[Code]
#include "obs-pages.iss"

var
  ReplayPage: TInputQueryWizardPage;
  Progress: TOutputMarqueeProgressWizardPage;
  LogLines: TStringList;

function PowerShell: String;
begin
  Result := ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe');
end;

function StopCommand(Param: String): String;
begin
  { Ends Ultron (any process started from this folder). }
  Result := '-NoProfile -Command "Get-CimInstance Win32_Process | ' +
    'Where-Object { $_.ExecutablePath -like ''' + ExpandConstant('{app}') + '\*'' } | ' +
    'ForEach-Object { Stop-Process -Id $_.ProcessId -Force }"';
end;

procedure InitializeWizard;
begin
  LogLines := TStringList.Create;
  ReplayPage := CreateInputQueryPage(wpSelectTasks, 'Clip length',
    'How long should a clip be?',
    'A clip saves this many seconds from before you asked for it. Only used if OBS''s replay buffer isn''t set up yet; you can change it later in OBS: Settings > Output > Replay Buffer.');
  ReplayPage.Add('Seconds:', False);
  ReplayPage.Values[0] := '120';
  CreateObsPages(ReplayPage.ID);
  Progress := CreateOutputMarqueeProgressPage('Finishing setup', 'This can take a few minutes. Please keep this window open.');
end;

function ShouldSkipPage(PageID: Integer): Boolean;
begin
  Result := ((PageID = ReplayPage.ID) and not WizardIsTaskSelected('obs')) or ObsPagesSkip(PageID);
end;

procedure CurPageChanged(CurPageID: Integer);
begin
  ObsPagesActivate(CurPageID);
end;

function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := ObsPagesNext(CurPageID);
  if (CurPageID = ReplayPage.ID) and (StrToIntDef(ReplayPage.Values[0], 0) < 5) then
  begin
    MsgBox('Enter a number of seconds, for example 120.', mbError, MB_OK);
    Result := False;
  end;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  Code: Integer;
begin
  Result := ObsPagesTestStop;
  if Result <> '' then Exit;
  { Upgrading: stop the running Ultron so its files can be replaced. }
  Exec(PowerShell, StopCommand(''), '', SW_HIDE, ewWaitUntilTerminated, Code);
end;

procedure OnLog(const S: String; const Error, FirstLine: Boolean);
begin
  if Trim(S) <> '' then
  begin
    SaveStringToFile(ExpandConstant('{app}\install.log'), S + #13#10, True);
    LogLines.Add(S);
    if LogLines.Count > 15 then LogLines.Delete(0);
    Progress.SetText(Progress.Msg1Label.Caption, S);
  end;
  Progress.Animate;
end;

function LastLines: String;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to LogLines.Count - 1 do Result := Result + LogLines[I] + #13#10;
end;

function RunScript(Title, Script, Params: String): Integer;
begin
  LogLines.Clear;
  SaveStringToFile(ExpandConstant('{app}\install.log'), GetDateTimeString('yyyy-mm-dd hh:nn:ss', '-', ':') + ' ' + Script + ' ' + Params + #13#10, True);
  Progress.SetText(Title, '');
  Progress.Show;
  try
    if not ExecAndLogOutput(PowerShell, '-NoProfile -ExecutionPolicy Bypass -File "' + ExpandConstant('{app}\' + Script) + '" ' + Params,
      ExpandConstant('{app}'), SW_HIDE, ewWaitUntilTerminated, Result, @OnLog) then
      Result := -1;
  finally
    Progress.Hide;
  end;
end;

procedure SetUpUltron;
begin
  while RunScript('Downloading Python and the speech models...', 'setup.ps1', '') <> 0 do
    if SuppressibleMsgBox('Setup could not finish:' + #13#10#13#10 + LastLines + #13#10 +
      'Check your internet connection and click Retry. Cancel finishes without it; you can run "Repair" from the Start menu later.',
      mbError, MB_RETRYCANCEL, IDCANCEL) <> IDRETRY then Exit;
end;

function RunObsSetup(CloseObs: Boolean): Integer;
var
  Params: String;
begin
  Params := '-ReplaySeconds ' + ReplayPage.Values[0] + ObsPagesParams;
  if CloseObs then Params := Params + ' -CloseObs';
  Result := RunScript('Setting up OBS...', 'obs-setup.ps1', Params);
end;

procedure SetUpObs;
var
  Code: Integer;
  Again: Boolean;
begin
  Code := RunObsSetup(False);
  repeat
    Again := False;
    case Code of
      0: ;
      2: SuppressibleMsgBox('OBS Studio isn''t installed, so OBS was not set up.' + #13#10#13#10 +
           'Install OBS from obsproject.com, then run "Set up OBS again" from the Start menu.', mbInformation, MB_OK, IDOK);
      3: if SuppressibleMsgBox('OBS hasn''t been opened yet on this PC.' + #13#10#13#10 +
           'Open OBS once (you can cancel its setup wizard), close it again, then click Retry.',
           mbInformation, MB_RETRYCANCEL, IDCANCEL) = IDRETRY then
         begin Code := RunObsSetup(False); Again := True; end;
      4: if SuppressibleMsgBox('OBS has to close for a moment so its settings can be changed. It opens again by itself.' + #13#10#13#10 +
           'If you''re recording, stop first. Close OBS now?', mbConfirmation, MB_YESNO, IDNO) = IDYES then
         begin Code := RunObsSetup(True); Again := True; end;
    else
      if SuppressibleMsgBox('OBS could not be set up:' + #13#10#13#10 + LastLines + #13#10 +
           'Click Retry to try again, or Cancel to skip (you can run "Set up OBS again" from the Start menu later).',
           mbError, MB_RETRYCANCEL, IDCANCEL) = IDRETRY then
         begin Code := RunObsSetup(False); Again := True; end;
    end;
  until not Again;
end;

{ Ultron does what OBS Game Watcher did; two of them would both steer OBS. }
procedure OfferWatcherRemoval;
var
  Key, Uninstaller: String;
  Code: Integer;
begin
  Key := 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{6B0F3E52-8C1D-4E7A-9D2B-3F4A5C6D7E81}_is1';
  if not RegQueryStringValue(HKCU, Key, 'UninstallString', Uninstaller) then Exit;
  if SuppressibleMsgBox('OBS Game Watcher is installed. Ultron does the same job, and both running at once would fight over OBS.' + #13#10#13#10 +
    'Uninstall OBS Game Watcher now? (Recommended)', mbConfirmation, MB_YESNO, IDYES) = IDYES then
    Exec(RemoveQuotes(Uninstaller), '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART', '', SW_HIDE, ewWaitUntilTerminated, Code);
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep <> ssPostInstall then Exit;
  OfferWatcherRemoval;
  SetUpUltron;
  if WizardIsTaskSelected('obs') then SetUpObs;
end;
