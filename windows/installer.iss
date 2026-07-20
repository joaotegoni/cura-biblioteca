; installer.iss — Biblioteca CURA (instalador Windows, Inno Setup 6)
;
; Bootstrapper fino: so embute scripts/install.ps1 como fallback offline.
; No pos-instalacao, tenta baixar a versao mais recente do install.ps1 pra um
; arquivo separado (BASE/install.ps1) e SO promove por cima do embutido se o
; download deu certo e o arquivo parece valido (tamanho minimo); se falhar,
; segue com o embutido mesmo. Executa o script (visivel) e traduz o exit code
; dele (0/1/2) pra mensagem final. No uninstall, CurUninstallStepChanged roda
; o mesmo script cacheado com -Uninstall -Force (funciona offline), guarda o
; exit code e salva uma copia do log fora de {app} antes do [UninstallDelete].
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

; [UninstallRun] foi removido: o Inno nao expoe o exit code de uma entrada
; dessa secao pro [Code], entao rodar o script direto por Exec() dentro de
; CurUninstallStepChanged(usUninstall) e a unica forma de capturar o
; resultado real do -Uninstall (ver [Code] abaixo). O ps1 -Uninstall so mexe
; no que esta no SNAPSHOT dele (plugins/fontes); aqui o Inno limpa a PROPRIA
; pasta de cache (ps1 cacheado + log + snapshot residual) depois.
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

{ Roda o install.ps1 cacheado na pasta do app, visivel - o aluno acompanha
  o progresso no console - e devolve o exit code real do script (0/1/2). }
function RunInstallScript(ScriptPath: String; var ResCode: Integer): Boolean;
var
  Cmd: String;
begin
  Cmd := '-NoProfile -ExecutionPolicy Bypass -File "' + ScriptPath + '"';
  Result := Exec('powershell.exe', Cmd, '', SW_SHOWNORMAL, ewWaitUntilTerminated, ResCode);
end;

{ Roda o install.ps1 -Uninstall -Force, oculto (mesmo comportamento da antiga
  secao UninstallRun) - devolve o exit code real do script. Nota: linha de
  comentario NUNCA pode comecar com "[" - o compilador le como tag de secao
  mesmo dentro de Code. }
function RunUninstallScript(ScriptPath: String; var ResCode: Integer): Boolean;
var
  Cmd: String;
begin
  Cmd := '-NoProfile -ExecutionPolicy Bypass -File "' + ScriptPath + '" -Uninstall -Force';
  Result := Exec('powershell.exe', Cmd, '', SW_HIDE, ewWaitUntilTerminated, ResCode);
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  ScriptPath: String;
  DownloadPath: String;
  RunOk: Boolean;
  NotepadResCode: Integer;
  DownloadOk: Boolean;
  DownloadSize: Longint;
  DownloadContent: AnsiString;
  DownloadComplete: Boolean;
begin
  if CurStep = ssPostInstall then
  begin
    ScriptPath := ExpandConstant('{app}') + '\install.ps1';
    DownloadPath := ScriptPath + '.download';
    LogPathCura := ExpandConstant('{localappdata}') + '\CURA-Biblioteca\install.log';

    { Baixa pra um arquivo separado - nunca escreve por cima do embutido
      direto. So promove (sobrescreve o embutido) se a funcao retornou True,
      o arquivo existe, tem tamanho plausivel (> 1000 bytes, cinto extra) E
      termina com o marcador "cura-eof" (ultima linha do install.ps1) - um
      limiar de bytes sozinho nao pega truncamento no MEIO do arquivo, so no
      fim; o marcador pega qualquer truncamento em qualquer ponto porque so
      aparece na ultima linha do script. Senao apaga o .download e segue com
      o embutido que o [Files] ja copiou. }
    DownloadOk := DownloadLatestInstallScript(DownloadPath);
    DownloadSize := 0;
    DownloadComplete := False;
    if DownloadOk and FileExists(DownloadPath) and FileSize(DownloadPath, DownloadSize) and (DownloadSize > 1000) then
    begin
      if LoadStringFromFile(DownloadPath, DownloadContent) then
        DownloadComplete := (Pos('cura-eof', String(DownloadContent)) > 0);
    end;
    if DownloadComplete then
      FileCopy(DownloadPath, ScriptPath, False);
    if FileExists(DownloadPath) then
      DeleteFile(DownloadPath);

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

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  ScriptPath: String;
  LogSrc: String;
  LogDst: String;
  RunOk: Boolean;
  ResCode: Integer;
begin
  { usUninstall ocorre depois do prompt de confirmacao mas ANTES de qualquer
    arquivo ser removido (inclusive antes do [UninstallDelete]) - da pra
    rodar o script e salvar uma copia do log fora da pasta do app com
    seguranca. }
  if CurUninstallStep = usUninstall then
  begin
    ScriptPath := ExpandConstant('{app}') + '\install.ps1';
    LogSrc := ExpandConstant('{localappdata}') + '\CURA-Biblioteca\install.log';
    LogDst := ExpandConstant('{%TEMP}') + '\cura-uninstall.log';

    RunOk := RunUninstallScript(ScriptPath, ResCode);
    if not RunOk then
      ResCode := 2;

    { copia o log pra fora da pasta do app antes do [UninstallDelete] apagar
      tudo - evidencia sobrevive mesmo se a desinstalacao falhar. }
    if FileExists(LogSrc) then
      FileCopy(LogSrc, LogDst, False);

    { UninstallSilent (/SILENT ou /VERYSILENT): nao mostra o MsgBox - senao
      um uninstall silencioso trava pra sempre num dialogo que ninguem ve. }
    if (ResCode <> 0) and (not UninstallSilent) then
      MsgBox('a desinstalação encontrou um problema (código ' + IntToStr(ResCode) + ').' + #13#10 + #13#10 +
        'log salvo em: ' + LogDst, mbError, MB_OK);
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
