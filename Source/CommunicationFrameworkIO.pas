{ ****************************************************************************** }
{ * single tunnel IO framework(incl auth service)                              * }
{ * written by QQ 600585@qq.com                                                * }
{ * https://github.com/PassByYou888/CoreCipher                                 * }
{ * https://github.com/PassByYou888/ZServer4D                                  * }
{ * https://github.com/PassByYou888/zExpression                                * }
{ ****************************************************************************** }
(*
  update history
*)

unit CommunicationFrameworkIO;

interface

{$I zDefine.inc}


uses CoreClasses, ListEngine, UnicodeMixedLib,
  DataFrameEngine, MemoryStream64, CommunicationFramework, TextDataEngine,
  DoStatusIO, PascalStrings, CoreCipher;

type
  TCommunicationFramework_UserAuthService = class;

  TPeerClientUserDefineForIO = class(TPeerClientUserDefine)
  public
    UserFlag, UserID: SystemString;
    UserPath        : SystemString;
    UserConfigFile  : TSectionTextData;
    UserAuthService : TCommunicationFramework_UserAuthService;
    UserDBIntf      : THashVariantList;
    LoginSuccessed  : Boolean;

    constructor Create(AOwner: TPeerIO); override;
    destructor Destroy; override;

    function MakeFilePath(fn: SystemString): SystemString;
    function GetUserID: SystemString;
  end;

  TCommunicationFramework_UserAuthService = class(TCoreClassObject)
  protected
    FRootPath          : SystemString;
    FUserDB            : TSectionTextData;
    FCanRegisterNewUser: Boolean;
    FCanSaveUserInfo   : Boolean;
    FLoginUserList     : THashVariantList;
  protected
    procedure Command_UserLogin(Sender: TPeerIO; InData, OutData: TDataFrameEngine); virtual;
    procedure Command_RegisterUser(Sender: TPeerIO; InData, OutData: TDataFrameEngine); virtual;
  public
    Communication: TCommunicationFramework;

    constructor Create(ACommunication: TCommunicationFramework);
    destructor Destroy; override;

    procedure SwitchServiceAsMaxPerformance;
    procedure SwitchServiceAsMaxSafe;
    procedure SwitchServiceAsDefaultPerformance;

    procedure Progress; virtual;

    procedure RegisterCommand; virtual;
    procedure UnRegisterCommand; virtual;

    function MakeUserFlag: SystemString;
    function GetUserDefineClient(cli: TPeerIO): TPeerClientUserDefineForIO;

    property CanRegisterNewUser: Boolean read FCanRegisterNewUser write FCanRegisterNewUser;
    property RootPath: SystemString read FRootPath;
    property CanSaveUserInfo: Boolean read FCanSaveUserInfo write FCanSaveUserInfo;
    property LoginUserList: THashVariantList read FLoginUserList;
  end;

  TCommunicationFramework_UserAuthClient = class(TCoreClassObject)
  public
    Client: TCommunicationFrameworkClient;

    constructor Create(ACommunication: TCommunicationFrameworkClient);
    destructor Destroy; override;

    procedure SwitchServiceAsMaxPerformance;
    procedure SwitchServiceAsMaxSafe;
    procedure SwitchServiceAsDefaultPerformance;

    procedure Progress; virtual;

    procedure RegisterCommand; virtual;
    procedure UnRegisterCommand; virtual;

    function UserLogin(UserID, Passwd: SystemString): Boolean;
    function RegisterUser(UserID, Passwd: SystemString): Boolean;
  end;

implementation

uses SysUtils;

constructor TPeerClientUserDefineForIO.Create(AOwner: TPeerIO);
begin
  inherited Create(AOwner);
  UserFlag := '';
  UserID := '';
  UserPath := '';
  UserConfigFile := TSectionTextData.Create;
  UserAuthService := nil;
  UserDBIntf := nil;
  LoginSuccessed := False;
end;

destructor TPeerClientUserDefineForIO.Destroy;
begin
  if LoginSuccessed then
    begin
      LockObject(UserAuthService.FLoginUserList);
      try
          UserAuthService.FLoginUserList.Delete(UserID);
      except
      end;
      UnLockObject(UserAuthService.FLoginUserList);
    end;

  try
      DisposeObject(UserConfigFile);
  except
  end;

  inherited Destroy;
end;

function TPeerClientUserDefineForIO.MakeFilePath(fn: SystemString): SystemString;
begin
  Result := umlCombineFileName(UserPath, fn);
end;

function TPeerClientUserDefineForIO.GetUserID: SystemString;
begin
  Result := UserConfigFile.GetDefaultValue('UserInfo', 'UserID', '');
end;

procedure TCommunicationFramework_UserAuthService.Command_UserLogin(Sender: TPeerIO; InData, OutData: TDataFrameEngine);
var
  UserID, UserPasswd: SystemString;
  UserDefineIO      : TPeerClientUserDefineForIO;
begin
  UserID := InData.Reader.ReadString;
  UserPasswd := InData.Reader.ReadString;

  if not FUserDB.Exists(UserID) then
    begin
      OutData.WriteBool(False);
      OutData.WriteString(Format('user name Invalid:%s', [UserID]));
      Exit;
    end;

  LockObject(FLoginUserList);
  if FLoginUserList.Exists(UserID) then
    begin
      OutData.WriteBool(False);
      OutData.WriteString(Format('user already online:%s', [UserID]));
      Exit;
    end;
  UnLockObject(FLoginUserList);

  if not ComparePassword(TCipherStyle.csDES64, UserPasswd, SystemString(FUserDB.GetDefaultValue(UserID, 'password', ''))) then
    begin
      OutData.WriteBool(False);
      OutData.WriteString(Format('password error', []));
      Exit;
    end;

  UserDefineIO := GetUserDefineClient(Sender);

  UserDefineIO.UserDBIntf := FUserDB.VariantList[UserID];
  UserDefineIO.UserFlag := UserDefineIO.UserDBIntf['UserFlag'];
  UserDefineIO.UserID := UserID;
  UserDefineIO.UserPath := umlCombinePath(FRootPath, UserDefineIO.UserFlag);
  UserDefineIO.UserAuthService := Self;
  UserDefineIO.LoginSuccessed := True;

  if umlFileExists(UserDefineIO.MakeFilePath('User.Config')) then
      UserDefineIO.UserConfigFile.LoadFromFile(UserDefineIO.MakeFilePath('User.Config'));
  UserDefineIO.UserConfigFile.Hit['UserInfo', 'UserID'] := UserID;

  LockObject(FLoginUserList);
  FLoginUserList[UserID] := Now;
  UnLockObject(FLoginUserList);

  OutData.WriteBool(True);
  OutData.WriteString(Format('success Login:%s', [UserID]));
  OutData.WriteString(UserDefineIO.UserFlag);
end;

procedure TCommunicationFramework_UserAuthService.Command_RegisterUser(Sender: TPeerIO; InData, OutData: TDataFrameEngine);
var
  UserID, UserPasswd: SystemString;
  UserDefineIO      : TPeerClientUserDefineForIO;
begin
  if not FCanRegisterNewUser then
    begin
      OutData.WriteBool(False);
      OutData.WriteString(Format('disable user register in server', []));
      Exit;
    end;
  UserID := InData.Reader.ReadString;
  UserPasswd := InData.Reader.ReadString;

  if umlExistsLimitChar(UserID, '[]:'#13#10#9#8#0) then
    begin
      OutData.WriteBool(False);
      OutData.WriteString(Format('user name Illegal:%s', [UserID]));
      Exit;
    end;

  if FUserDB.Exists(UserID) then
    begin
      OutData.WriteBool(False);
      OutData.WriteString(Format('user already registed:%s', [UserID]));
      Exit;
    end;

  LockObject(FLoginUserList);
  if FLoginUserList.Exists(UserID) then
    begin
      OutData.WriteBool(False);
      OutData.WriteString(Format('user already online:%s', [UserID]));
      Exit;
    end;
  UnLockObject(FLoginUserList);

  UserDefineIO := GetUserDefineClient(Sender);
  UserDefineIO.UserFlag := MakeUserFlag;
  UserDefineIO.UserID := UserID;
  UserDefineIO.UserPath := umlCombinePath(FRootPath, UserDefineIO.UserFlag);
  umlCreateDirectory(UserDefineIO.UserPath);
  UserDefineIO.UserDBIntf := FUserDB.VariantList[UserID];
  UserDefineIO.UserDBIntf['UserFlag'] := UserDefineIO.UserFlag;
  UserDefineIO.UserDBIntf['password'] := GeneratePassword(TCipherStyle.csDES64, UserPasswd).Text;
  UserDefineIO.UserAuthService := Self;
  UserDefineIO.LoginSuccessed := True;

  if umlFileExists(UserDefineIO.MakeFilePath('User.Config')) then
      UserDefineIO.UserConfigFile.LoadFromFile(UserDefineIO.MakeFilePath('User.Config'));
  UserDefineIO.UserConfigFile.Hit['UserInfo', 'UserID'] := UserID;

  OutData.WriteBool(True);
  OutData.WriteString(Format('success registed:%s', [UserID]));
  OutData.WriteString(UserDefineIO.UserFlag);

  if FCanSaveUserInfo then
      FUserDB.SaveToFile(umlCombineFileName(FRootPath, 'UserDB'));

  LockObject(FLoginUserList);
  FLoginUserList[UserID] := Now;
  UnLockObject(FLoginUserList);
end;

constructor TCommunicationFramework_UserAuthService.Create(ACommunication: TCommunicationFramework);
begin
  inherited Create;
  Communication := ACommunication;
  FRootPath := umlCurrentPath;
  FUserDB := TSectionTextData.Create;
  FCanRegisterNewUser := True;
  FCanSaveUserInfo := False;
  FLoginUserList := THashVariantList.Create;

  if umlFileExists(umlCombineFileName(FRootPath, 'UserDB')) then
      FUserDB.LoadFromFile(umlCombineFileName(FRootPath, 'UserDB'));

  SwitchServiceAsDefaultPerformance;
end;

destructor TCommunicationFramework_UserAuthService.Destroy;
begin
  if FCanSaveUserInfo then
      FUserDB.SaveToFile(umlCombineFileName(FRootPath, 'UserDB'));
  DisposeObject(FLoginUserList);
  DisposeObject(FUserDB);
  inherited Destroy;
end;

procedure TCommunicationFramework_UserAuthService.SwitchServiceAsMaxPerformance;
begin
  Communication.SwitchMaxPerformance;
end;

procedure TCommunicationFramework_UserAuthService.SwitchServiceAsMaxSafe;
begin
  Communication.SwitchMaxSafe;
end;

procedure TCommunicationFramework_UserAuthService.SwitchServiceAsDefaultPerformance;
begin
  Communication.SwitchDefaultPerformance;
end;

procedure TCommunicationFramework_UserAuthService.Progress;
begin
  Communication.ProgressBackground;
end;

procedure TCommunicationFramework_UserAuthService.RegisterCommand;
begin
  Communication.PeerClientUserDefineClass := TPeerClientUserDefineForIO;

  {$IFDEF FPC}
  Communication.RegisterStream('UserLogin').OnExecute := @Command_UserLogin;
  Communication.RegisterStream('RegisterUser').OnExecute := @Command_RegisterUser;
  {$ELSE}
  Communication.RegisterStream('UserLogin').OnExecute := Command_UserLogin;
  Communication.RegisterStream('RegisterUser').OnExecute := Command_RegisterUser;
  {$ENDIF}
end;

procedure TCommunicationFramework_UserAuthService.UnRegisterCommand;
begin
  Communication.DeleteRegistedCMD('UserLogin');
  Communication.DeleteRegistedCMD('RegisterUser');
  Communication.PeerClientUserDefineClass := TPeerClientUserDefine;
end;

function TCommunicationFramework_UserAuthService.MakeUserFlag: SystemString;
var
  d: Double;
  p: PInt64;
begin
  repeat
    TCoreClassThread.Sleep(1);
    d := Now;
    p := @d;
    Result := IntToHex(p^, 16);
  until not umlDirectoryExists(umlCombinePath(FRootPath, Result));
end;

function TCommunicationFramework_UserAuthService.GetUserDefineClient(cli: TPeerIO): TPeerClientUserDefineForIO;
begin
  Result := cli.UserDefine as TPeerClientUserDefineForIO;
end;

constructor TCommunicationFramework_UserAuthClient.Create(ACommunication: TCommunicationFrameworkClient);
begin
  inherited Create;
  Client := ACommunication;
  SwitchServiceAsMaxSafe;
end;

destructor TCommunicationFramework_UserAuthClient.Destroy;
begin
  inherited Destroy;
end;

procedure TCommunicationFramework_UserAuthClient.SwitchServiceAsMaxPerformance;
begin
  Client.SwitchMaxPerformance;
end;

procedure TCommunicationFramework_UserAuthClient.SwitchServiceAsMaxSafe;
begin
  Client.SwitchMaxSafe;
end;

procedure TCommunicationFramework_UserAuthClient.SwitchServiceAsDefaultPerformance;
begin
  Client.SwitchDefaultPerformance;
end;

procedure TCommunicationFramework_UserAuthClient.Progress;
begin
  Client.ProgressBackground;
end;

procedure TCommunicationFramework_UserAuthClient.RegisterCommand;
begin
end;

procedure TCommunicationFramework_UserAuthClient.UnRegisterCommand;
begin
end;

function TCommunicationFramework_UserAuthClient.UserLogin(UserID, Passwd: SystemString): Boolean;
var
  sendDE, resDE: TDataFrameEngine;
begin
  Result := False;
  sendDE := TDataFrameEngine.Create;
  resDE := TDataFrameEngine.Create;

  sendDE.WriteString(UserID);
  sendDE.WriteString(Passwd);
  Client.WaitSendStreamCmd('UserLogin', sendDE, resDE, 10000);

  if resDE.Count > 0 then
    begin
      Result := resDE.ReadBool(0);
      DoStatus(resDE.ReadString(1));
    end;

  DisposeObject(sendDE);
  DisposeObject(resDE);
end;

function TCommunicationFramework_UserAuthClient.RegisterUser(UserID, Passwd: SystemString): Boolean;
var
  sendDE, resDE: TDataFrameEngine;
begin
  Result := False;
  sendDE := TDataFrameEngine.Create;
  resDE := TDataFrameEngine.Create;

  sendDE.WriteString(UserID);
  sendDE.WriteString(Passwd);
  Client.WaitSendStreamCmd('RegisterUser', sendDE, resDE, 10000);

  if resDE.Count > 0 then
    begin
      Result := resDE.ReadBool(0);
      DoStatus(resDE.ReadString(1));
    end;

  DisposeObject(sendDE);
  DisposeObject(resDE);
end;

end.
