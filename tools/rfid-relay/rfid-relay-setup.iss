; QB Engineer RFID Relay — Inno Setup Script
; Produces: rfid-relay-setup.exe
;
; Prerequisites:
;   1. dotnet publish the pcsc-relay project first (see build-installer.ps1)
;   2. Inno Setup 6+ installed (https://jrsoftware.org/isinfo.php)
;      or run via CI with `iscc rfid-relay-setup.iss`

#define AppName      "QB Engineer RFID Relay"
#define AppVersion   "1.0.0"
#define ServiceName  "QbEngineerRfidRelay"
#define ExeName      "pcsc-relay.exe"
#define PublishDir   "publish\win-x64"

[Setup]
AppId={{A3F7B2C1-8D4E-4F6A-9B0C-1E2D3C4A5B6F}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher=QB Engineer
DefaultDirName={commonpf64}\QB Engineer\RfidRelay
DefaultGroupName=QB Engineer
OutputDir=dist
OutputBaseFilename=rfid-relay-setup
Compression=lzma2/ultra64
SolidCompression=yes
PrivilegesRequired=admin
PrivilegesRequiredOverridesAllowed=dialog
; Silent install support: rfid-relay-setup.exe /VERYSILENT /SUPPRESSMSGBOXES
AllowNoIcons=yes
UninstallDisplayName={#AppName}
CloseApplications=yes

; Require Windows 10 or later (Smart Card service API)
MinVersion=10.0

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
; Main executable (published self-contained single file)
Source: "{#PublishDir}\{#ExeName}"; DestDir: "{app}"; Flags: ignoreversion

[Run]
; Enable Smart Card service (dependency) — non-fatal if already correct
Filename: "sc.exe"; Parameters: "config SCardSvr start= demand"; \
  Flags: runhidden; StatusMsg: "Configuring Smart Card service..."; \
  Check: not ServiceExists('{#ServiceName}')

; Install the Windows Service
Filename: "sc.exe"; Parameters: "create ""{#ServiceName}"" \
  binPath= """"""{app}\{#ExeName}"""" --port 9876 --debounce 500"" \
  DisplayName= ""{#AppName}"" \
  start= auto \
  description= ""Bridges USB NFC/RFID smart card readers to QB Engineer via WebSocket."""; \
  Flags: runhidden; StatusMsg: "Installing service..."

; Configure auto-restart on failure (reset after 1 day; restart after 5s, 10s, 30s)
Filename: "sc.exe"; Parameters: "failure ""{#ServiceName}"" reset= 86400 actions= restart/5000/restart/10000/restart/30000"; \
  Flags: runhidden; StatusMsg: "Configuring auto-restart..."

; Start the service immediately
Filename: "sc.exe"; Parameters: "start ""{#ServiceName}"""; \
  Flags: runhidden; StatusMsg: "Starting service..."

[UninstallRun]
; Stop and remove service on uninstall
Filename: "sc.exe"; Parameters: "stop ""{#ServiceName}""";  Flags: runhidden; RunOnceId: "StopService"
Filename: "sc.exe"; Parameters: "delete ""{#ServiceName}"""; Flags: runhidden; RunOnceId: "DeleteService"

[Code]
{ Returns true if a Windows Service with the given name already exists }
function ServiceExists(ServiceName: string): Boolean;
var
  ResultCode: Integer;
begin
  Exec('sc.exe', 'query "' + ServiceName + '"', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Result := (ResultCode = 0);
end;

{ On upgrade: stop existing service before overwriting the exe }
procedure CurStepChanged(CurStep: TSetupStep);
var
  ResultCode: Integer;
begin
  if CurStep = ssInstall then
  begin
    if ServiceExists('{#ServiceName}') then
    begin
      Exec('sc.exe', 'stop "{#ServiceName}"', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
      Sleep(2000);
      Exec('sc.exe', 'delete "{#ServiceName}"', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
      Sleep(1000);
    end;
  end;
end;
