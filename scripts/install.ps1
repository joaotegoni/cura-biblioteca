<#
.SYNOPSIS
    Instalador da Biblioteca CURA para SketchUp (Windows).
.DESCRIPTION
    Baixa manifest.json do GitHub Releases e instala os plugins (.rbz) e fontes
    em todas as versões do SketchUp encontradas no computador, sem precisar de
    privilégios de administrador (tudo per-user).
    Re-rodar o instalador conserta uma instalação (limpa e reinstala).
    Use -Uninstall para remover tudo que este instalador colocou no sistema.
.PARAMETER Uninstall
    Remove os itens registrados no snapshot desta instalação.
.PARAMETER Force
    Usado com -Uninstall para pular a confirmação (modo não-interativo,
    usado pelo desinstalador gerado pelo Inno Setup).
.PARAMETER BaseUrl
    Origem dos arquivos (manifest.json, .rbz, fonts.zip). Por padrão aponta
    para o release "latest" do GitHub. Aceita também um caminho local
    (pasta com os mesmos arquivos) para teste, ou a variável de ambiente
    CURA_BASE_URL (mesmo formato) quando -BaseUrl não for informado.
#>

#Requires -Version 5.0

[CmdletBinding()]
param(
    [switch]$Uninstall,
    [switch]$Force,
    # -Quiet: modo não-interativo usado pelo auto-update agendado. Sem prompts,
    # sem esperar o SketchUp fechar (adia se estiver aberto), no-op quando já
    # está na versão do manifest.
    [switch]$Quiet,
    [string]$BaseUrl = $(if ($env:CURA_BASE_URL) { $env:CURA_BASE_URL } else { "https://github.com/joaotegoni/cura-biblioteca/releases/latest/download" })
)

# URL FIXA da release oficial — usada só pelo registro do auto-update. Nunca
# usa $BaseUrl aqui: o updater tem que puxar sempre da release de verdade,
# mesmo que esta execução esteja com CURA_BASE_URL apontando pasta de teste.
$script:OfficialBaseUrl = "https://github.com/joaotegoni/cura-biblioteca/releases/latest/download"
$script:UpdaterTaskName = "CURA Biblioteca Updater"

# --- TLS 1.2 + encoding do console (tem que vir antes de qualquer output) ---
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
try {
    [Console]::OutputEncoding = [Text.Encoding]::UTF8
} catch {
    # console antigo pode recusar a troca de encoding; segue mesmo assim
}

$ErrorActionPreference = "Stop"

# --- Identidade visual CURA (paleta E1 fechada: verde cura = marca, terracota
# = erro terminal, mais nada). ANSI 256-color quando o host suporta VT; senão
# cai pro Write-Host -ForegroundColor clássico. Nunca depende de truecolor. ---
$script:AnsiOk = $false
try {
    if ($Host.UI.SupportsVirtualTerminal) { $script:AnsiOk = $true }
} catch {
    $script:AnsiOk = $false
}
$script:Esc = [char]27
$script:AnsiMarca = "$($script:Esc)[1m$($script:Esc)[38;5;151m"
$script:AnsiErro  = "$($script:Esc)[1m$($script:Esc)[38;5;131m"
$script:AnsiReset = "$($script:Esc)[0m"

# --- Paths fixos (cache/log/snapshot deste instalador) ---
$AppDataDir   = Join-Path $env:LOCALAPPDATA "CURA-Biblioteca"
$LogPath      = Join-Path $AppDataDir "install.log"
$SnapshotPath = Join-Path $AppDataDir "installed.json"

if (-not (Test-Path -LiteralPath $AppDataDir)) {
    New-Item -ItemType Directory -Path $AppDataDir -Force | Out-Null
}

# ============================================================================
# Funções auxiliares
# ============================================================================

function Write-CuraBanner {
    param([Parameter(Mandatory = $true)][string]$LogPath)
    $marca = "{ cura }  biblioteca 9.0"
    if ($script:AnsiOk) {
        Write-Host "  $($script:AnsiMarca)$marca$($script:AnsiReset)"
    } else {
        Write-Host "  $marca" -ForegroundColor DarkGreen
    }
    Write-Host "  instalador windows"
    try {
        Add-Content -LiteralPath $LogPath -Value "" -Encoding UTF8
        Add-Content -LiteralPath $LogPath -Value "===== $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $marca / instalador windows =====" -Encoding UTF8
    } catch {
        # log indisponível não trava o fluxo
    }
}

function Write-CuraLog {
    # Voz cura (E5): mensagem sempre em minúsculas, exceto números, siglas e
    # nomes de produto (SketchUp, Windows, GitHub). Sem emoji. Única cor fora
    # do default é o terracota de erro - aviso não ganha cor própria.
    param(
        [Parameter(Mandatory = $true)][string]$LogPath,
        [Parameter(Mandatory = $true, Position = 1)][string]$Message,
        [switch]$IsError
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] $Message"
    try {
        Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
    } catch {
        # se o log não puder ser escrito (disco cheio, permissão), não trava o fluxo
    }
    if ($IsError) {
        if ($script:AnsiOk) {
            Write-Host "$($script:AnsiErro)$Message$($script:AnsiReset)"
        } else {
            Write-Host $Message -ForegroundColor DarkRed
        }
    } else {
        Write-Host $Message
    }
}

function Resolve-CuraLocalPath {
    # Se $BaseUrl aponta pra pasta local (teste), devolve o path resolvido.
    # Devolve $null se for uma URL remota de verdade.
    param([Parameter(Mandatory = $true)][string]$BaseUrl)
    $path = $BaseUrl
    if ($path -like "file://*") {
        $path = $path -replace '^file://', ''
    }
    if ($path -match '^https?://') {
        return $null
    }
    if (Test-Path -LiteralPath $path) {
        return $path
    }
    return $null
}

function Get-CuraRemoteFile {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$OutFile,
        [Parameter(Mandatory = $true)][string]$LogPath,
        [int]$Retries = 3,
        [int]$TimeoutSec = 30
    )
    $attempt = 0
    $lastMessage = ""
    while ($attempt -lt $Retries) {
        $attempt++
        try {
            Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -TimeoutSec $TimeoutSec
            return $true
        } catch {
            $lastMessage = $_.Exception.Message
            Write-CuraLog -LogPath $LogPath -Message "aviso: tentativa $attempt de $Retries falhou para $Url : $lastMessage"
            if ($attempt -lt $Retries) {
                Start-Sleep -Seconds 2
            }
        }
    }
    Write-CuraLog -LogPath $LogPath -Message "erro / falha definitiva ao baixar $Url : $lastMessage" -IsError
    return $false
}

function Get-CuraAsset {
    # Copia de pasta local (modo teste) ou baixa de $BaseUrl/$FileName (modo normal).
    param(
        [Parameter(Mandatory = $true)][string]$BaseUrl,
        [Parameter(Mandatory = $true)][string]$FileName,
        [Parameter(Mandatory = $true)][string]$OutFile,
        [Parameter(Mandatory = $true)][string]$LogPath
    )
    $localBase = Resolve-CuraLocalPath -BaseUrl $BaseUrl
    if ($null -ne $localBase) {
        $sourcePath = Join-Path $localBase $FileName
        if (-not (Test-Path -LiteralPath $sourcePath)) {
            Write-CuraLog -LogPath $LogPath -Message "erro / arquivo local não encontrado: $sourcePath" -IsError
            return $false
        }
        Copy-Item -LiteralPath $sourcePath -Destination $OutFile -Force
        Write-CuraLog -LogPath $LogPath -Message "copiado localmente (modo teste): $sourcePath"
        return $true
    }
    $url = "$BaseUrl/$FileName"
    return Get-CuraRemoteFile -Url $url -OutFile $OutFile -LogPath $LogPath
}

function Get-CuraPluginPayload {
    # Baixa o payload de um plugin. Contrato do manifest (SPEC.md): url null
    # -> BASE/<file> (via Get-CuraAsset); url absoluta -> usa ela direto
    # (aceita também path local/file://, modo teste, espelhando
    # Resolve-CuraLocalPath). O Mac já respeita isso; aqui equipara.
    param(
        [Parameter(Mandatory = $true)]$Plugin,
        [Parameter(Mandatory = $true)][string]$BaseUrl,
        [Parameter(Mandatory = $true)][string]$OutFile,
        [Parameter(Mandatory = $true)][string]$LogPath
    )
    if ($Plugin.url) {
        $localPath = Resolve-CuraLocalPath -BaseUrl $Plugin.url
        if ($null -ne $localPath) {
            if (-not (Test-Path -LiteralPath $localPath -PathType Leaf)) {
                Write-CuraLog -LogPath $LogPath -Message "erro / arquivo local não encontrado: $localPath" -IsError
                return $false
            }
            Copy-Item -LiteralPath $localPath -Destination $OutFile -Force
            Write-CuraLog -LogPath $LogPath -Message "copiado localmente (modo teste, url própria): $localPath"
            return $true
        }
        return Get-CuraRemoteFile -Url $Plugin.url -OutFile $OutFile -LogPath $LogPath
    }
    return Get-CuraAsset -BaseUrl $BaseUrl -FileName $Plugin.file -OutFile $OutFile -LogPath $LogPath
}

function Get-CuraSketchUpVersions {
    # Detecta instalações do SketchUp em %APPDATA%\SketchUp\SketchUp 20XX e
    # devolve só as que atendem $MinVersion. Nunca lança erro se a pasta raiz
    # não existir (SketchUp não instalado ainda).
    param([Parameter(Mandatory = $true)][int]$MinVersion)
    $result = @()
    $root = Join-Path $env:APPDATA "SketchUp"
    try {
        $dirs = Get-ChildItem -Path $root -Directory -Filter "SketchUp 20*" -ErrorAction Stop
    } catch {
        return $result
    }
    foreach ($dir in $dirs) {
        if ($dir.Name -match '20\d\d') {
            $year = [int]$Matches[0]
            if ($year -ge $MinVersion) {
                $pluginsPath = Join-Path $dir.FullName "SketchUp\Plugins"
                $result += [PSCustomObject]@{
                    Year        = $year
                    VersionDir  = $dir.FullName
                    PluginsPath = $pluginsPath
                }
            }
        }
    }
    return $result
}

function Test-CuraSafeLeafName {
    # Espelha is_safe_leaf_name do install.sh (SPEC.md linha ~133): rejeita
    # nome vazio e qualquer nome contendo separador de path ("\" ou "/") ou
    # "..". Guarda anti path-traversal aplicada a todo nome vindo do
    # manifest/snapshot antes de virar alvo de remoção.
    param([string]$Name)
    if ([string]::IsNullOrEmpty($Name)) { return $false }
    if ($Name -match '[\\/]' -or $Name -match '\.\.') { return $false }
    return $true
}

function Remove-CuraExact {
    # Remove SÓ por nome exato (arquivo ou pasta) dentro de $ParentDir.
    # Nunca usa wildcard/glob - literal match apenas. Nome que falhar a
    # guarda anti path-traversal é rejeitado (log de aviso + skip) antes de
    # qualquer Join-Path.
    param(
        [Parameter(Mandatory = $true)][string]$ParentDir,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$LogPath
    )
    if (-not (Test-CuraSafeLeafName -Name $Name)) {
        Write-CuraLog -LogPath $LogPath -Message "aviso: nome de remoção rejeitado (path-traversal?): '$Name' - ignorado."
        return
    }
    $target = Join-Path $ParentDir $Name
    if (Test-Path -LiteralPath $target) {
        try {
            Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop
            Write-CuraLog -LogPath $LogPath -Message "removido: $target"
        } catch {
            Write-CuraLog -LogPath $LogPath -Message "aviso: falha ao remover $target : $($_.Exception.Message)"
        }
    }
}

function Get-CuraOldSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$SnapshotPath
    )
    if (Test-Path -LiteralPath $SnapshotPath) {
        try {
            $raw = Get-Content -LiteralPath $SnapshotPath -Raw -Encoding UTF8
            return ($raw | ConvertFrom-Json)
        } catch {
            return $null
        }
    }
    return $null
}

function Wait-CuraSketchUpClosed {
    # Verifica (e, se interativo, aguarda) que o SketchUp não está aberto.
    # -Quiet: adia (exit 0), sem alarde, igual ao check inicial. Interativo:
    # pede pra fechar e espera enter, com opção de cancelar. Chamada tanto no
    # início do fluxo quanto de novo logo antes da 1ª remoção/Expand-Archive
    # (o download dos payloads pode levar minutos e o SketchUp pode ter sido
    # aberto nesse meio tempo).
    param(
        [Parameter(Mandatory = $true)][string]$LogPath,
        [switch]$Quiet
    )
    if ($Quiet) {
        if (Get-Process -Name "SketchUp*" -ErrorAction SilentlyContinue) {
            Write-CuraLog -LogPath $LogPath -Message "quiet: SketchUp aberto, adiando update."
            exit 0
        }
    } else {
        while ($true) {
            $procs = Get-Process -Name "SketchUp*" -ErrorAction SilentlyContinue
            if (-not $procs) { break }
            Write-Host "o SketchUp está aberto. feche o programa e pressione enter para continuar (ou digite 'sair' para cancelar)."
            $resp = Read-Host
            if ($resp -match '^(sair|exit|q)$') {
                Write-CuraLog -LogPath $LogPath -Message "aviso: instalação cancelada pelo usuário (SketchUp aberto)."
                exit 2
            }
        }
    }
}

function Test-CuraUpToDate {
    # Decide se dá pra pular a instalação inteira (no-op). Só quando NADA mudou:
    # mesma biblioteca_version no snapshot, toda versão do SketchUp detectada já
    # está no snapshot com seus arquivos no lugar, e todas as fontes no lugar.
    # Se surgiu um SketchUp novo (não presente no snapshot), NÃO é no-op — tem
    # que instalar os plugins nele.
    param(
        [Parameter(Mandatory = $true)]$Manifest,
        $OldSnapshot,
        $DetectedVersions
    )
    if ($null -eq $OldSnapshot) { return $false }
    if ($OldSnapshot.biblioteca_version -ne $Manifest.biblioteca_version) { return $false }

    foreach ($ver in $DetectedVersions) {
        $snapVer = $null
        foreach ($sv in $OldSnapshot.sketchup_versions) {
            if ($sv.year -eq $ver.Year) { $snapVer = $sv; break }
        }
        if ($null -eq $snapVer) { return $false }   # SketchUp novo -> precisa instalar

        # Autoritativo contra o MANIFEST atual, não contra o que o snapshot
        # registrou: todo root de todo plugin do manifest precisa existir de
        # verdade no Plugins/ desta versão. Corrige o caso de uma rodada
        # anterior ter falhado em instalar um plugin (sha256/download) - se o
        # snapshot só tivesse os plugins que ela registrou, o no-op passaria
        # mesmo faltando plugin em disco.
        foreach ($plugin in $Manifest.plugins) {
            foreach ($r in $plugin.roots) {
                if (-not (Test-Path -LiteralPath (Join-Path $ver.PluginsPath $r))) { return $false }
            }
        }
    }

    foreach ($f in $OldSnapshot.fonts) {
        if (-not (Test-Path -LiteralPath $f.file)) { return $false }
    }
    return $true
}

function Register-CuraUpdater {
    # Registra a tarefa agendada per-user (sem admin) que roda o auto-update:
    # no logon + diária de reserva. A ação baixa SEMPRE o install.ps1 mais
    # recente da release oficial e roda -Quiet. Falha aqui é aviso, nunca erro
    # fatal — a instalação principal já terminou com sucesso quando chegamos aqui.
    param(
        [Parameter(Mandatory = $true)][string]$TaskName,
        [Parameter(Mandatory = $true)][string]$OfficialBaseUrl,
        [Parameter(Mandatory = $true)][string]$LogPath
    )
    try {
        # comando interno: TLS 1.2, baixa o install.ps1 latest pro TEMP e roda
        # -Quiet. Empacotado com -EncodedCommand (base64 UTF-16LE) pra não
        # depender de escaping de aspas na linha de comando da tarefa agendada.
        # Roda o baixado como PROCESSO FILHO (não `&` direto): install.ps1
        # termina com `exit`, que mataria este wrapper inteiro antes de
        # conseguir copiar o script pro cache depois. Rodando como filho, o
        # exit code vem por $LASTEXITCODE sem derrubar o wrapper. Se rodou
        # até um dos exit codes esperados do próprio script (0/1/2 - ou seja,
        # não foi um crash/parse error), copia o baixado por cima do cache em
        # {localappdata}\CURA-Biblioteca\install.ps1 (se o dir existir), pra
        # que o uninstall do Inno (que roda essa cópia congelada) também
        # receba fixes futuros.
        $inner = @"
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
`$u='$OfficialBaseUrl/install.ps1'
`$o=Join-Path `$env:TEMP 'cura-updater.ps1'
try { Invoke-WebRequest -Uri `$u -OutFile `$o -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop } catch { exit 0 }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `$o -Quiet
`$code = `$LASTEXITCODE
if (`$code -eq 0 -or `$code -eq 1 -or `$code -eq 2) {
    `$cache = Join-Path `$env:LOCALAPPDATA 'CURA-Biblioteca'
    if (Test-Path -LiteralPath `$cache) {
        Copy-Item -LiteralPath `$o -Destination (Join-Path `$cache 'install.ps1') -Force -ErrorAction SilentlyContinue
    }
}
exit `$code
"@
        $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($inner))
        $psArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand $enc"

        if (Get-Command Register-ScheduledTask -ErrorAction SilentlyContinue) {
            $action    = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $psArgs
            $trigLogon = New-ScheduledTaskTrigger -AtLogOn
            $trigDaily = New-ScheduledTaskTrigger -Daily -At "12:00"
            # roda como o usuário atual, privilégio limitado (sem admin), só quando logado.
            $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
            $settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopOnIdleEnd -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
            Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger @($trigLogon, $trigDaily) `
                -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
            Write-CuraLog -LogPath $LogPath -Message "auto-update registrado (logon + diária)"
        } else {
            # fallback Win7/PS3 sem o módulo ScheduledTasks: schtasks.exe (só logon).
            $tr = "powershell.exe $psArgs"
            & schtasks.exe /Create /TN $TaskName /TR $tr /SC ONLOGON /F 2>$null | Out-Null
            Write-CuraLog -LogPath $LogPath -Message "auto-update registrado via schtasks (logon)"
        }
    } catch {
        Write-CuraLog -LogPath $LogPath -Message "aviso: não foi possível registrar o auto-update: $($_.Exception.Message)"
    }
}

function Unregister-CuraUpdater {
    param(
        [Parameter(Mandatory = $true)][string]$TaskName,
        [Parameter(Mandatory = $true)][string]$LogPath
    )
    try {
        if (Get-Command Unregister-ScheduledTask -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
        }
        & schtasks.exe /Delete /TN $TaskName /F 2>$null | Out-Null
        Write-CuraLog -LogPath $LogPath -Message "auto-update desregistrado"
    } catch {
        # tarefa pode nem existir — ignorar
    }
}

function Invoke-CuraUninstall {
    param(
        [Parameter(Mandatory = $true)][string]$SnapshotPath,
        [Parameter(Mandatory = $true)][string]$LogPath,
        [switch]$Force
    )
    if (-not (Test-Path -LiteralPath $SnapshotPath)) {
        Write-Host "nada instalado por este instalador (nenhum snapshot encontrado)."
        exit 0
    }

    # Reaproveita Get-CuraOldSnapshot (já protegido com try/catch) em vez de
    # ler/parsear cru aqui - snapshot corrompido não pode virar exceção não
    # tratada no meio do -Uninstall.
    $snap = Get-CuraOldSnapshot -SnapshotPath $SnapshotPath
    if ($null -eq $snap) {
        Write-CuraLog -LogPath $LogPath -Message "aviso: snapshot ilegível ou corrompido ($SnapshotPath) - nada a desinstalar."
        Write-Host "não foi possível ler o registro desta instalação (arquivo corrompido)."
        Write-Host "log: $LogPath"
        exit 0
    }

    Write-Host "itens que serão removidos:"
    foreach ($ver in $snap.sketchup_versions) {
        foreach ($p in $ver.plugins) {
            Write-Host "  - plugin $($p.name) v$($p.version) (SketchUp $($ver.year))"
        }
    }
    foreach ($f in $snap.fonts) {
        Write-Host "  - fonte: $($f.file)"
    }

    if (-not $Force) {
        $resp = Read-Host "confirma a remoção? (s/n)"
        if ($resp -notmatch '^[sSyY]') {
            Write-Host "cancelado pelo usuário. nada foi removido."
            exit 0
        }
    }

    # Whitelist de prefixo no PARENTDIR: Remove-CuraExact já valida o Name
    # (path-traversal), mas o plugins_path em si vem cru do snapshot - se
    # estiver corrompido/adulterado apontando pra fora da árvore do
    # SketchUp, nada deveria ser removido lá. Mesma ideia da whitelist de
    # fontes logo abaixo.
    $sketchUpRootUninstall = [System.IO.Path]::GetFullPath((Join-Path $env:APPDATA "SketchUp"))
    foreach ($ver in $snap.sketchup_versions) {
        $pluginsPathSafe = $false
        try {
            $resolvedPluginsPath = [System.IO.Path]::GetFullPath($ver.plugins_path)
            $pluginsPathSafe = $resolvedPluginsPath.StartsWith($sketchUpRootUninstall, [StringComparison]::OrdinalIgnoreCase)
        } catch {
            $pluginsPathSafe = $false
        }
        if (-not $pluginsPathSafe) {
            Write-CuraLog -LogPath $LogPath -Message "aviso: plugins_path fora do diretório esperado, ignorado: $($ver.plugins_path)"
            continue
        }
        foreach ($p in $ver.plugins) {
            foreach ($r in $p.roots) {
                Remove-CuraExact -ParentDir $ver.plugins_path -Name $r -LogPath $LogPath
            }
        }
    }
    # Whitelist de prefixo (espelha is_allowed_removal_path do install.sh):
    # só remove o arquivo de fonte do snapshot se ele está DENTRO do dir de
    # fontes per-user esperado - nunca confia cegamente no path gravado.
    $winFontsDirUninstall = Join-Path $env:LOCALAPPDATA "Microsoft\Windows\Fonts"
    foreach ($f in $snap.fonts) {
        $fontInsideExpectedDir = $false
        try {
            $resolvedFont     = [System.IO.Path]::GetFullPath($f.file)
            $resolvedFontsDir = [System.IO.Path]::GetFullPath($winFontsDirUninstall)
            $fontInsideExpectedDir = $resolvedFont.StartsWith($resolvedFontsDir, [StringComparison]::OrdinalIgnoreCase)
        } catch {
            $fontInsideExpectedDir = $false
        }
        if (-not $fontInsideExpectedDir) {
            Write-CuraLog -LogPath $LogPath -Message "aviso: caminho de fonte fora do diretório esperado, ignorado: $($f.file)"
            continue
        }
        if (Test-Path -LiteralPath $f.file) {
            Remove-Item -LiteralPath $f.file -Force -ErrorAction SilentlyContinue
            Write-CuraLog -LogPath $LogPath -Message "fonte removida: $($f.file)"
        }
        Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts" -Name $f.reg_name -ErrorAction SilentlyContinue
    }

    Unregister-CuraUpdater -TaskName $script:UpdaterTaskName -LogPath $LogPath

    Remove-Item -LiteralPath $SnapshotPath -Force -ErrorAction SilentlyContinue
    Write-CuraLog -LogPath $LogPath -Message "desinstalação concluída. snapshot removido."
    Write-Host ""
    Write-Host "biblioteca cura removida deste computador."
    Write-Host "log: $LogPath"
    exit 0
}

# ============================================================================
# Fluxo principal
# ============================================================================

Write-CuraBanner -LogPath $LogPath

# --- Lock de concorrência: mutex nomeado per-user. Evita dois processos
# mexendo ao mesmo tempo em Plugins/ e installed.json - ex.: a Tarefa
# Agendada dispara no logon/12h bem na hora em que o aluno roda o
# Setup.exe de novo. WaitOne(0) não espera: se já tem dono, desiste na hora
# em vez de travar (o próximo gatilho do updater tenta de novo sozinho).
# Vale pro fluxo de instalação E pro -Uninstall - por isso é adquirido antes
# do "if ($Uninstall)". Liberado no finally lá embaixo.
$script:CuraMutex = New-Object System.Threading.Mutex($false, 'Local\CuraBibliotecaInstaller')
$script:CuraMutexOwned = $false
try {
    $script:CuraMutexOwned = $script:CuraMutex.WaitOne(0)
} catch [System.Threading.AbandonedMutexException] {
    # dono anterior encerrou sem liberar (crash) - ainda assim conseguimos o lock
    $script:CuraMutexOwned = $true
}
if (-not $script:CuraMutexOwned) {
    Write-CuraLog -LogPath $LogPath -Message "aviso: outra operação da biblioteca cura já está em andamento - encerrando."
    if (-not $Quiet) {
        Write-Host "outra operação da biblioteca cura já está em andamento. tente novamente em alguns instantes."
    }
    $script:CuraMutex.Dispose()
    exit 0
}

try {
    if ($Uninstall) {
        Invoke-CuraUninstall -SnapshotPath $SnapshotPath -LogPath $LogPath -Force:$Force
    }

    # --- 2. SketchUp aberto? ---
    # Quiet (auto-update): não trocar arquivo embaixo do programa rodando. Se
    # estiver aberto, adia pro próximo gatilho (exit 0, sem alarde).
    # Interativo: pede pra fechar (não mata o processo).
    Wait-CuraSketchUpClosed -LogPath $LogPath -Quiet:$Quiet

    $TempDir = Join-Path $env:TEMP ("cura-biblioteca-" + [System.IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Path $TempDir -Force | Out-Null

    try {
        # --- 3. Baixa manifest.json ---
        $manifestPath = Join-Path $TempDir "manifest.json"
        $ok = Get-CuraAsset -BaseUrl $BaseUrl -FileName "manifest.json" -OutFile $manifestPath -LogPath $LogPath
        if (-not $ok) {
            Write-CuraLog -LogPath $LogPath -Message "erro / não foi possível baixar manifest.json. sem internet ou GitHub inacessível." -IsError
            Write-Host ""
            Write-Host "log completo em: $LogPath"
            exit 2
        }
        $manifestRaw = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8
        $manifest = $manifestRaw | ConvertFrom-Json

        $oldSnapshot = Get-CuraOldSnapshot -SnapshotPath $SnapshotPath
        $hadErrors = $false

        # --- 4/5. Detecta versões do SketchUp ---
        # @() força array mesmo quando exatamente 1 versão é detectada (o
        # PowerShell 5.1 "desembrulha" coleção de 1 elemento no retorno de
        # função, o que quebraria .Count mais abaixo).
        $versions = @(Get-CuraSketchUpVersions -MinVersion $manifest.min_sketchup)
        $noSketchUpFound = ($versions.Count -eq 0)

        # --- No-op: nada mudou desde a última instalação? pula tudo. Mantém o
        # auto-update diário/logon barato e não fica re-extraindo plugin à toa
        # (re-churn de arquivo reindexaria o SketchUp sem motivo). ---
        if (Test-CuraUpToDate -Manifest $manifest -OldSnapshot $oldSnapshot -DetectedVersions $versions) {
            Write-CuraLog -LogPath $LogPath -Message "no-op: biblioteca já na versão $($manifest.biblioteca_version)."
            # self-cura: garante que a tarefa agendada existe/está com a
            # definição mais recente mesmo quando não há nada pra
            # (re)instalar - interativo OU -Quiet (idempotente via
            # Register-ScheduledTask -Force). Sem isso, o wrapper do updater
            # nunca se atualiza sozinho: a tarefa roda sempre -Quiet, então
            # só o ramo -not $Quiet nunca bastava.
            Register-CuraUpdater -TaskName $script:UpdaterTaskName -OfficialBaseUrl $script:OfficialBaseUrl -LogPath $LogPath
            if (-not $Quiet) {
                Write-Host ""
                Write-Host "biblioteca já está atualizada (v$($manifest.biblioteca_version)). nada a fazer."
                Write-Host "log: $LogPath"
            }
            exit 0
        }

        $snapshotVersions = @()

        if ($noSketchUpFound) {
            Write-CuraLog -LogPath $LogPath -Message "aviso: nenhuma instalação do SketchUp (>= $($manifest.min_sketchup)) foi encontrada. instalando somente as fontes; instale o SketchUp e rode este instalador de novo para os plugins."
        } else {
            # --- 7a. Baixa e verifica cada payload de plugin uma única vez ---
            $verifiedPlugins = @()
            foreach ($plugin in $manifest.plugins) {
                $destFile = Join-Path $TempDir $plugin.file
                $ok = Get-CuraPluginPayload -Plugin $plugin -BaseUrl $BaseUrl -OutFile $destFile -LogPath $LogPath
                if (-not $ok) {
                    Write-CuraLog -LogPath $LogPath -Message "erro / falha ao baixar $($plugin.name) ($($plugin.file)). este item não será instalado." -IsError
                    $hadErrors = $true
                    continue
                }
                $hash = (Get-FileHash -LiteralPath $destFile -Algorithm SHA256).Hash
                if ($hash.ToLower() -ne $plugin.sha256.ToLower()) {
                    Write-CuraLog -LogPath $LogPath -Message "erro / sha256 não confere para $($plugin.file) (esperado $($plugin.sha256), obtido $hash). download corrompido, item não será instalado." -IsError
                    $hadErrors = $true
                    continue
                }
                # Expand-Archive só aceita .zip - copia o .rbz pra .zip antes
                $zipPath = Join-Path $TempDir ([System.IO.Path]::GetFileNameWithoutExtension($plugin.file) + ".zip")
                Copy-Item -LiteralPath $destFile -Destination $zipPath -Force
                $verifiedPlugins += [PSCustomObject]@{ Plugin = $plugin; ZipPath = $zipPath }
                Write-CuraLog -LogPath $LogPath -Message "payload verificado: $($plugin.name) v$($plugin.version) (sha256 ok)"
            }

            # --- 6. Re-checa SketchUp antes da 1ª remoção/Expand-Archive: o
            # download+verificação acima pode ter levado minutos, e o
            # processo pode ter sido aberto nesse meio tempo. ---
            Wait-CuraSketchUpClosed -LogPath $LogPath -Quiet:$Quiet

            # --- 6/7b. Por versão: limpeza (remove list + roots antigos/atuais) e instalação ---
            foreach ($ver in $versions) {
                if (-not (Test-Path -LiteralPath $ver.PluginsPath)) {
                    New-Item -ItemType Directory -Path $ver.PluginsPath -Force | Out-Null
                }

                # Lista `remove` (plugins mortos) é incondicional - independe
                # de $verifiedPlugins.
                foreach ($name in $manifest.remove) {
                    Remove-CuraExact -ParentDir $ver.PluginsPath -Name $name -LogPath $LogPath
                }

                $installedPluginsForVersion = @()
                foreach ($vp in $verifiedPlugins) {
                    # Só limpa os roots (snapshot antigo + manifest atual)
                    # DESTE plugin, e só porque ele passou na verificação de
                    # sha256 - imediatamente antes do Expand-Archive dele.
                    # Plugin que falhou a verificação nunca chega aqui (não
                    # está em $verifiedPlugins) e mantém a cópia antiga
                    # intacta no disco.
                    $pluginRootsToClean = @()
                    if (($null -ne $oldSnapshot) -and ($null -ne $oldSnapshot.sketchup_versions)) {
                        foreach ($oldVer in $oldSnapshot.sketchup_versions) {
                            if ($oldVer.year -eq $ver.Year) {
                                foreach ($p in $oldVer.plugins) {
                                    if ($p.id -eq $vp.Plugin.id) {
                                        foreach ($r in $p.roots) { $pluginRootsToClean += $r }
                                    }
                                }
                            }
                        }
                    }
                    foreach ($r in $vp.Plugin.roots) { $pluginRootsToClean += $r }
                    $pluginRootsToClean = $pluginRootsToClean | Select-Object -Unique
                    foreach ($name in $pluginRootsToClean) {
                        Remove-CuraExact -ParentDir $ver.PluginsPath -Name $name -LogPath $LogPath
                    }

                    try {
                        Expand-Archive -LiteralPath $vp.ZipPath -DestinationPath $ver.PluginsPath -Force
                        Write-CuraLog -LogPath $LogPath -Message "instalado $($vp.Plugin.name) v$($vp.Plugin.version) em SketchUp $($ver.Year)"
                        $installedPluginsForVersion += [PSCustomObject]@{
                            id      = $vp.Plugin.id
                            name    = $vp.Plugin.name
                            version = $vp.Plugin.version
                            roots   = $vp.Plugin.roots
                        }
                    } catch {
                        Write-CuraLog -LogPath $LogPath -Message "erro / falha ao extrair $($vp.Plugin.name) em SketchUp $($ver.Year): $($_.Exception.Message)" -IsError
                        $hadErrors = $true
                    }
                }

                $snapshotVersions += [PSCustomObject]@{
                    year         = $ver.Year
                    plugins_path = $ver.PluginsPath
                    plugins      = $installedPluginsForVersion
                }
            }
        }

        # --- 8. Fontes (independe de ter SketchUp encontrado ou não) ---
        $installedFonts = @()
        if ($null -ne $manifest.fonts) {
            $fontsZipDest = Join-Path $TempDir $manifest.fonts.file
            $ok = Get-CuraAsset -BaseUrl $BaseUrl -FileName $manifest.fonts.file -OutFile $fontsZipDest -LogPath $LogPath
            if (-not $ok) {
                Write-CuraLog -LogPath $LogPath -Message "erro / falha ao baixar fontes ($($manifest.fonts.file)). fontes não serão instaladas." -IsError
                $hadErrors = $true
            } else {
                $fontsHash = (Get-FileHash -LiteralPath $fontsZipDest -Algorithm SHA256).Hash
                if ($fontsHash.ToLower() -ne $manifest.fonts.sha256.ToLower()) {
                    Write-CuraLog -LogPath $LogPath -Message "erro / sha256 não confere para $($manifest.fonts.file). fontes não serão instaladas." -IsError
                    $hadErrors = $true
                } else {
                    $fontsZipRenamed = Join-Path $TempDir "fonts-payload.zip"
                    Copy-Item -LiteralPath $fontsZipDest -Destination $fontsZipRenamed -Force
                    $fontsExtractDir = Join-Path $TempDir "fonts-extract"
                    New-Item -ItemType Directory -Path $fontsExtractDir -Force | Out-Null
                    Expand-Archive -LiteralPath $fontsZipRenamed -DestinationPath $fontsExtractDir -Force

                    $winFontsDir = Join-Path $env:LOCALAPPDATA "Microsoft\Windows\Fonts"
                    New-Item -ItemType Directory -Path $winFontsDir -Force | Out-Null

                    $fontFiles = Get-ChildItem -Path $fontsExtractDir -Recurse -File | Where-Object {
                        $_.Extension -match '^\.(ttf|otf|ttc)$'
                    }
                    foreach ($f in $fontFiles) {
                        $destFontPath = Join-Path $winFontsDir $f.Name
                        Copy-Item -LiteralPath $f.FullName -Destination $destFontPath -Force
                        $regName = "$([System.IO.Path]::GetFileNameWithoutExtension($f.Name)) (TrueType)"
                        New-ItemProperty -Path "HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts" -Name $regName -Value $destFontPath -PropertyType String -Force | Out-Null
                        Write-CuraLog -LogPath $LogPath -Message "fonte instalada: $($f.Name)"
                        $installedFonts += [PSCustomObject]@{ file = $destFontPath; reg_name = $regName }
                    }
                }
            }
        } else {
            Write-CuraLog -LogPath $LogPath -Message "manifest ainda sem fontes definidas - etapa pulada."
        }

        # --- 9. Snapshot (para desinstalação futura) ---
        # Se algum item falhou (sha256/download/extração), grava a
        # biblioteca_version ANTIGA em vez da nova - senão a próxima rodada
        # do updater vê a version nova já batendo no snapshot e cai no no-op
        # (Test-CuraUpToDate), nunca mais retentando o item que faltou. Os
        # itens que instalaram com sucesso já ficam registrados normalmente
        # em $snapshotVersions/$installedFonts.
        $snapshotBibliotecaVersion = $manifest.biblioteca_version
        if ($hadErrors) {
            if ($null -ne $oldSnapshot) {
                $snapshotBibliotecaVersion = $oldSnapshot.biblioteca_version
            } else {
                $snapshotBibliotecaVersion = ""
            }
        }
        $snapshot = [PSCustomObject]@{
            biblioteca_version = $snapshotBibliotecaVersion
            installed_at       = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssK")
            sketchup_versions  = $snapshotVersions
            fonts              = $installedFonts
        }
        # Escrita atômica: grava num .tmp e só substitui o snapshot real com
        # Move-Item -Force por cima - evita installed.json meio escrito se o
        # processo for interrompido no meio do Set-Content (queda de energia,
        # kill da tarefa por timeout, etc).
        $snapshotTmpPath = "$SnapshotPath.tmp"
        $snapshot | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $snapshotTmpPath -Encoding UTF8
        Move-Item -LiteralPath $snapshotTmpPath -Destination $SnapshotPath -Force

        # --- 10. Auto-update: (re)registra a tarefa agendada sempre que uma
        # rodada chega até aqui - interativa OU -Quiet. Register-ScheduledTask
        # -Force é idempotente e atualiza a DEFINIÇÃO da tarefa (a instância
        # que está rodando agora, se for essa mesma tarefa, segue até o fim
        # normalmente); assim uma mudança futura no wrapper do updater
        # (Register-CuraUpdater) se propaga sozinha pro parque instalado, sem
        # depender de reinstalação manual.
        Register-CuraUpdater -TaskName $script:UpdaterTaskName -OfficialBaseUrl $script:OfficialBaseUrl -LogPath $LogPath

        # --- 11. Resumo final (voz cura: minúsculo, sem emoji, tag "ok /" só no
        # sucesso limpo - mesmo criterio do install.sh: 1 = só "sem SketchUp",
        # 2 = qualquer falha de integridade/download, mesmo com SketchUp achado) ---
        Write-Host ""
        if ($noSketchUpFound) {
            if ($installedFonts.Count -gt 0) {
                Write-Host "SketchUp não encontrado neste computador. $($installedFonts.Count) fontes instaladas."
            } else {
                Write-Host "SketchUp não encontrado neste computador."
            }
            Write-Host "instale o SketchUp e rode este instalador novamente para concluir a instalação dos plugins."
            Write-Host "log: $LogPath"
            exit 1
        }

        $pluginSummaryParts = @()
        foreach ($plugin in $manifest.plugins) {
            $pluginSummaryParts += "$($plugin.name) v$($plugin.version)"
        }
        $pluginSummary = $pluginSummaryParts -join ", "
        $versionsList = ($versions | ForEach-Object { $_.Year }) -join ", "
        $msg = "instalado: $pluginSummary em $($versions.Count) versões do SketchUp ($versionsList); $($installedFonts.Count) fontes."

        if ($hadErrors) {
            Write-Host $msg
            Write-Host "algum item teve falha de integridade (download corrompido) - veja o log para detalhes."
            Write-Host "log: $LogPath"
            exit 2
        }

        Write-Host "ok / $msg"
        Write-Host "abra o SketchUp > extensões pra conferir."
        Write-Host "log: $LogPath"
        exit 0
    } finally {
        if (Test-Path -LiteralPath $TempDir) {
            Remove-Item -LiteralPath $TempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
} catch {
    Write-CuraLog -LogPath $LogPath -Message "erro / erro inesperado: $($_.Exception.Message)" -IsError
    Write-Host ""
    Write-Host "log completo em: $LogPath"
    exit 2
} finally {
    if ($script:CuraMutexOwned) {
        $script:CuraMutex.ReleaseMutex()
    }
    $script:CuraMutex.Dispose()
}
# cura-eof
