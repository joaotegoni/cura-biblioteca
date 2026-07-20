; installer.iss — Biblioteca CURA (instalador Windows, Inno Setup 6)
;
; Bootstrapper fino: so embute scripts/install.ps1 como fallback offline.
; No pos-instalacao, tenta baixar a versao mais recente do install.ps1
; (BASE/install.ps1) e sobrescreve o embutido; se falhar, segue com o
; embutido mesmo. Executa o script (visivel) e traduz o exit code dele
; (0/1/2) pra mensagem final. O [UninstallRun] chama o mesmo script cacheado
; com -Uninstall -Force (funciona offline).
;
; AppId gerado 1x via `uuidgen` — nunca trocar depois do primeiro release
; publico (trocar quebra upgrade/uninstall de quem ja instalou).

#define MyAppName "Biblioteca CURA"
#define MyAppPublisher "cura"
#define MyAppURL "https://github.com/joaotegoni/cura-biblioteca"
#define MyAppExeName "install.ps1"

; CI pode sobrescrever via `iscc /DMyAppVersion=1.2.3 windows\installer.iss`
; (release.yml passa a versao da tag). Sem override, usa este default local.
#ifndef MyAppVersion
  #define MyAppVersion "1.0.0"
#endif

[Setup]
AppId={{5EB37A85-98B9-421B-B6DB-071C25498300}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}
DefaultDirName={localappdata}\CURA-Biblioteca
DisableDirPage=yes
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir=Output
OutputBaseFilename=BibliotecaCURA-Setup
SetupIconFile=cura.ico
UninstallDisplayIcon={uninstallexe}
WizardStyle=modern
WizardImageFile=wizard-large.bmp
WizardSmallImageFile=wizard-small.bmp

[Languages]
Name: "brazilianportuguese"; MessagesFile: "compiler:Languages\BrazilianPortuguese.isl"

; Voz CURA (E5): lowercase, sem emoji, marca "cura" sem chaves em frase corrida.
; AppName continua "Biblioteca CURA" (Adicionar/Remover Programas = contexto
; do sistema; capitalizacao natural ajuda o aluno a achar o programa).
[Messages]
brazilianportuguese.WelcomeLabel1=biblioteca cura
brazilianportuguese.WelcomeLabel2=este instalador baixa e instala a versão mais recente dos plugins e fontes do método cura.%n%nfeche o SketchUp antes de continuar.
brazilianportuguese.FinishedHeadingLabel=pronto
brazilianportuguese.FinishedLabel=biblioteca cura instalada. abra o SketchUp e confira o menu Extensões.

[Files]
Source: "..\scripts\install.ps1"; DestDir: "{app}"; Flags: ignoreversion

; Checkbox padrao do Inno na pagina final (desmarcado): abre o log no notepad.
; O texto do proprio resumo (FinishedLabel) e customizado em CurPageChanged
; conforme o exit code do install.ps1 (ver [Code] abaixo).
[Run]
Filename: "{sys}\notepad.exe"; Parameters: """{app}\install.log"""; Description: "abrir o log da instalação"; Flags: postinstall shellexec skipifdoesntexist unchecked

[UninstallRun]
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\install.ps1"" -Uninstall -Force"; Flags: waituntilterminated runhidden

; O ps1 -Uninstall so mexe no que esta no SNAPSHOT dele (plugins/fontes).
; Aqui o Inno limpa a PROPRIA pasta de cache (ps1 cacheado + log + snapshot
; residual), depois que o -Uninstall acima ja terminou de rodar.
[UninstallDelete]
Type: filesandordirs; Name: "{app}"

[Code]
const
  CuraLatestPs1Url = 'https://github.com/joaotegoni/cura-biblioteca/releases/latest/download/install.ps1';

var
  ResultCodeCura: Integer;
  LogPathCura: String;

{ Tenta baixar o install.ps1 mais novo de BASE por cima do embutido.
  Falhou (sem internet, 404, etc.) -> devolve False e o embutido (ja copiado
  pelo [Files]) continua valendo. Usa powershell -Command (mais simples e
  robusto aqui do que WinHttp COM direto em Pascal). }
function DownloadLatestInstallScript(DestPath: String): Boolean;
var
  ResCode: Integer;
  Q: String;
  Cmd: String;
begin
  Q := #39; { aspas simples: evita ter que escapar aspas duplas aninhadas }
  Cmd := '-NoProfile -Command "try { [Net.ServicePointManager]::SecurityProtocol = ' +
         '[Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri ' + Q + CuraLatestPs1Url + Q +
         ' -OutFile ' + Q + DestPath + Q + ' -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop } ' +
         'catch { exit 1 }"';
  Result := Exec('powershell.exe', Cmd, '', SW_HIDE, ewWaitUntilTerminated, ResCode);
  if Result then
    Result := (ResCode = 0);
end;

{ Roda o install.ps1 (cacheado em {app}) visivel - o aluno acompanha o
  progresso no console - e devolve o exit code real do script (0/1/2). }
function RunInstallScript(ScriptPath: String; var ResCode: Integer): Boolean;
var
  Cmd: String;
begin
  Cmd := '-NoProfile -ExecutionPolicy Bypass -File "' + ScriptPath + '"';
  Result := Exec('powershell.exe', Cmd, '', SW_SHOWNORMAL, ewWaitUntilTerminated, ResCode);
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  ScriptPath: String;
  RunOk: Boolean;
  NotepadResCode: Integer;
begin
  if CurStep = ssPostInstall then
  begin
    ScriptPath := ExpandConstant('{app}') + '\install.ps1';
    LogPathCura := ExpandConstant('{localappdata}') + '\CURA-Biblioteca\install.log';

    DownloadLatestInstallScript(ScriptPath);

    RunOk := RunInstallScript(ScriptPath, ResultCodeCura);
    if not RunOk then
      ResultCodeCura := 2;

    if ResultCodeCura = 2 then
    begin
      MsgBox('a instalação encontrou um erro. o log será aberto para mais detalhes.' + #13#10 + #13#10 + LogPathCura,
        mbError, MB_OK);
      Exec('notepad.exe', '"' + LogPathCura + '"', '', SW_SHOWNORMAL, ewNoWait, NotepadResCode);
    end;
  end;
end;

procedure CurPageChanged(CurPageID: Integer);
begin
  if CurPageID = wpFinished then
  begin
    if ResultCodeCura = 1 then
      WizardForm.FinishedLabel.Caption :=
        'SketchUp não encontrado neste computador. instalamos somente as fontes (quando disponíveis).' + #13#10 + #13#10 +
        'instale o SketchUp e execute este instalador novamente para concluir a instalação dos plugins.' + #13#10 + #13#10 +
        'log: ' + LogPathCura
    else if ResultCodeCura = 2 then
      WizardForm.FinishedLabel.Caption :=
        'a instalação encontrou um erro e pode estar incompleta.' + #13#10 + #13#10 +
        'consulte o log para detalhes; se precisar de ajuda, envie esse arquivo para o suporte.' + #13#10 + #13#10 +
        'log: ' + LogPathCura;
    { ResultCodeCura = 0: mantem o FinishedLabel padrao definido em [Messages] }
  end;
end;
