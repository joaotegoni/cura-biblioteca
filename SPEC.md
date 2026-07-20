# SPEC — Instalador Biblioteca CURA 9.0 (caveman PT-BR, doc interno)

Instalador "eterno" 2 plataformas. Bootstrapper fino: conteúdo + lógica baixados em runtime de GitHub Releases. Rebuild de instalador ≈ nunca.

## Arquitetura

```
Aluno
 ├─ Windows: BibliotecaCURA-Setup.exe (Inno, per-user, sem admin)
 │    └─ baixa scripts/install.ps1 (latest) → executa
 └─ Mac: 1 linha Terminal: /bin/bash -c "$(curl -fsSL <RAW_SH_URL>)"
      └─ install.sh baixa manifest → executa

GitHub repo joaotegoni/cura-biblioteca (privado agora, público no ship)
 └─ Release "latest" assets:
    manifest.json, cura-ferramentas.rbz, fonts.zip, install.ps1, install.sh, BibliotecaCURA-Setup.exe
```

URLs canônicas:
- BASE = `https://github.com/joaotegoni/cura-biblioteca/releases/latest/download`
- RAW_SH_URL = `https://raw.githubusercontent.com/joaotegoni/cura-biblioteca/main/scripts/install.sh`
- Override p/ teste local: env `CURA_BASE_URL` (aceita `file:///...` ou dir local). Ambos scripts respeitam.

## manifest.json (schema 1)

```json
{
  "schema": 1,
  "biblioteca_version": "9.0.0",
  "min_sketchup": 2017,
  "plugins": [
    {
      "id": "cura-ferramentas",
      "name": "cura | ferramentas",
      "version": "0.8.0",
      "file": "cura-ferramentas.rbz",
      "url": null,
      "sha256": "e7c5013df3b822d11e32c0d34e2ce4a4b6df59a32fddedc4d358fbb41c1e7b4e",
      "roots": ["cura_ferramentas", "cura_ferramentas.rb"]
    }
  ],
  "fonts": null,
  "remove": [
    "TT_Lib2", "TT_Lib2.rb", "TT_Lib²", "tt_lib2.rb",
    "TT_CleanUp", "tt_cleanup", "tt_cleanup.rb",
    "TT_EdgeTools", "tt_edgetools", "tt_edgetools.rb"
  ]
}
```

Regras:
- `url: null` → download de `BASE/<file>`. URL absoluta → usa ela (futuro: endpoint autenticado assinatura — NÃO implementar auth agora, só suportar URL absoluta).
- `roots` = entradas raiz que o .rbz cria em Plugins/ → snapshot de desinstalação + limpeza de versão velha do próprio plugin antes de instalar.
- `fonts: null` → pula fontes SEM erro (fontes do João ainda não chegaram). Quando chegarem: `{"file":"fonts.zip","sha256":"...","families":["..."]}`.
- `remove` = SÓ match exato de nome (arquivo ou pasta) dentro de cada `Plugins/`. NUNCA glob/wildcard. Lista cresce via manifest quando João mandar RAR da 8.0.
- REGRA OPERACIONAL: renomeou um root de plugin, ou tirou um plugin do manifest? o nome ANTIGO entra na lista `remove` no MESMO release. A limpeza de upgrade só remove roots do plugin que vai ser reinstalado com sucesso (proteção contra download corrompido apagar cópia boa), então root antigo órfão só sai do disco via `remove`.
- sha256 SEMPRE verificado pós-download. Falhou → aborta item com msg clara, não instala corrompido.

## Fluxo de instalação (idêntico nas 2 plataformas)

1. Banner PT-BR ("Biblioteca CURA — instalador").
2. SketchUp aberto? (proc `SketchUp*`) → pede fechar e confirmar (Enter/retry). Não mata processo.
3. Baixa manifest (retry 3×, timeout 30s). Falha → msg "sem internet ou GitHub inacessível" + path do log, exit 2.
4. Detecta versões: glob dir `SketchUp 20*`; extrai ano; filtra `>= min_sketchup`. Cria subpasta `Plugins` se faltar (só quando dir da versão existe).
   - Win: `%APPDATA%\SketchUp\SketchUp 20XX\SketchUp\Plugins`
   - Mac: `~/Library/Application Support/SketchUp 20XX/SketchUp/Plugins`
5. Zero versão achada → aviso: "SketchUp não encontrado — instalando só as fontes; instale o SketchUp e rode este instalador de novo." Segue p/ fontes, exit 1.
6. Por versão: limpeza — remove itens da lista `remove` + `roots` de instalação anterior (upgrade limpo). Loga cada remoção.
7. Download payloads em dir temp (mktemp) → sha256 → unzip .rbz (rbz = zip) DENTRO de cada `Plugins/` (overwrite). Download 1×, instala N×.
8. Fontes (se manifest tiver): unzip fonts.zip; instala .ttf/.otf/.ttc per-user:
   - Mac: copia p/ `~/Library/Fonts/`
   - Win: copia p/ `%LOCALAPPDATA%\Microsoft\Windows\Fonts\` (criar dir) + registra valor em `HKCU\Software\Microsoft\Windows NT\CurrentVersion\Fonts`: nome = "<basename> (TrueType)", dado = path completo. Sem admin.
9. Snapshot JSON (p/ desinstalar): lista exata do que instalou (por versão SketchUp: paths dos roots; fontes: paths; versão biblioteca; data ISO).
   - Mac: `~/Library/Application Support/CURA-Biblioteca/installed.json`
   - Win: `%LOCALAPPDATA%\CURA-Biblioteca\installed.json`
10. Log completo (tudo que fez, timestamps): mesmo dir, `install.log` (append, header com data). Aluno manda esse arquivo pro suporte.
11. Resumo final PT-BR: "✅ Instalado: 1 plugin (cura | ferramentas v0.8.0) em N versões do SketchUp (2021, 2025); X fontes. Log: <path>". Instrui abrir SketchUp > Extensões pra conferir.

Idempotente: re-rodar = conserto (limpa + reinstala). Exit codes: 0 ok, 1 parcial (sem SketchUp), 2 falha.

## Desinstalação — "explicando cada um"

Modo `--uninstall` (sh) / `-Uninstall` (ps1): lê snapshot → imprime lista item a item (plugin X na versão Y, fonte Z) → confirma → remove SÓ o que está no snapshot → remove snapshot → resumo. Sem snapshot → msg "nada instalado por este instalador". Windows: exe Inno registra "Biblioteca CURA" em Adicionar/Remover; desinstalador chama o ps1 cacheado com -Uninstall (funciona offline → cachear install.ps1 em `%LOCALAPPDATA%\CURA-Biblioteca\` na instalação).

## Arquivos a produzir

### Efetor A (Mac + manifest)
- `scripts/install.sh` — bash **3.2-compatível** (macOS ships 3.2: SEM assoc array, SEM mapfile, SEM ${var,,}). `set -euo pipefail`. `mktemp -d` + `trap cleanup EXIT`. Paths SEMPRE quoted (espaços). curl `-fsSL --retry 3 --connect-timeout 30`. sha256: `shasum -a 256`. unzip: `unzip -oq`. Suporta `--uninstall` e `CURA_BASE_URL` (se começa com `/` ou `file://`, copia local em vez de curl). Confirmações: `read -r` de `/dev/tty` (script vem de pipe! stdin ocupado — OBRIGATÓRIO /dev/tty p/ prompts).
- `manifest.json` — como schema acima, sha256 real do payload/cura-ferramentas.rbz (já calculado: e7c5013d…).
- `tools/make_manifest.py` — python3 stdlib puro (pathlib, hashlib, json): recalcula sha256 de payload/* e reescreve campos no manifest.json. Uso: CI e manutenção. `check=True` se usar subprocess (não deve precisar).

### Efetor B (Windows + CI + docs)
- `scripts/install.ps1` — **PowerShell 5.1** (Win10 default; nada de sintaxe pwsh7). Início: `[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12`. Download: `Invoke-WebRequest -UseBasicParsing`. Hash: `Get-FileHash -Algorithm SHA256`. **Expand-Archive exige extensão .zip** → copiar .rbz p/ temp como .zip antes. Param: `[switch]$Uninstall`, `$BaseUrl` (default BASE; aceita path local p/ teste). Saída console PT-BR SEM acento quebrado: console 5.1 usa codepage legada → `[Console]::OutputEncoding = [Text.Encoding]::UTF8` no início e salvar .ps1 **UTF-8 com BOM** (5.1 lê BOM; sem BOM = mojibake).
- `windows/installer.iss` — Inno Setup 6. `PrivilegesRequired=lowest`, `Languages: BrazilianPortuguese` (compiler:Languages\BrazilianPortuguese.isl), AppId GUID fixo (gerar 1× e cravar), AppName "Biblioteca CURA", DefaultDirName `{localappdata}\CURA-Biblioteca` (só cache/log — plugins vão pro %APPDATA% do SketchUp via ps1). Embute SÓ `scripts/install.ps1` como fallback ([Files]). [Code]: no install, tenta baixar install.ps1 mais novo de BASE (ITD não — usar `WinHttp.WinHttpRequest.5.1` COM em Pascal ou simplesmente rodar powershell que baixa); falhou download → usa o embutido (offline-tolerante na lógica, payload sempre exige internet). Executa `powershell.exe -NoProfile -ExecutionPolicy Bypass -File <cached>\install.ps1` visível (aluno vê progresso), captura exit code → mensagem final. [UninstallRun]: `powershell ... -File <cached>\install.ps1 -Uninstall -Confirm:$false` + Inno remove cache/log. Wizard mínimo: welcome → progress → finished (texto resumo + checkbox "ver log").
- `windows/cura.ico` — gerar via python3+PIL de `~/dev/cura-ferramentas/src/cura_ferramentas/core/assets/` (buscar cura-marca-*-512.png; se não achar, `find ~/dev/cura-ferramentas -name "*512*.png"`). Tamanhos 16/32/48/256 no .ico. PIL disponível no python3 local.
- `.github/workflows/release.yml` — trigger `push: tags: ['v*']`. Job 1 (ubuntu): roda `tools/make_manifest.py` (garante sha256 atual), sobe artifacts. Job 2 (windows-latest): `choco install innosetup -y`, `iscc windows\installer.iss`, exe → artifact. Job 3: `softprops/action-gh-release@v2` anexa: exe, payload/cura-ferramentas.rbz, payload/fonts.zip (se existir), manifest.json, scripts/install.sh, scripts/install.ps1. `fail_on_unmatched_files: false` (fonts.zip pode não existir ainda).
- `README.md` — PT-BR normal (aluno lê): seção aluno (Windows: baixar exe, SmartScreen "Saiba mais > Executar assim mesmo" enquanto sem assinatura; Mac: colar 1 linha no Terminal), seção manutenção (trocar payload → `python3 tools/make_manifest.py` → commit → `git tag vX.Y.Z && git push --tags` → CI publica), seção futuro (assinatura de código Win/Mac = slots prontos; plugin por assinatura = trocar `url` no manifest p/ endpoint autenticado).

## Identidade visual CURA (obrigatória em TUDO user-facing)

Fonte: DNA CURA (`dna-cura/visual.md`, espinha E1–E7). Assets já copiados em `assets/` do repo (cura-marca-tight.svg, cura-marca-branco-tight.svg, cura-marca-preto.png, cura-marca-branco.png). Masters 512px: `~/dev/cura-ferramentas/src/cura_ferramentas/core/assets/cura-marca-{preto,branco,verde}-512.png`.

**Paleta (E1 — fechada, sem gradiente/tom fora dela):**
- branco `#FFFFFF` · preto `#000000` · verde cura `#AFBCAF` (default)
- terracota `#B34E31` — SÓ pra mensagens de erro no terminal (única secundária usada; 1 por peça)

**Voz/copy (E5):** TUDO lowercase (títulos, resumos, prompts) — exceto números, siglas e nomes de produto (SketchUp, Windows, GitHub). **Sem emoji** (nem ✅ — trocar resumo final por texto puro "ok /"). Sem exclamação em série. Brand mark grafado `{ cura }` (com chaves, espaços internos) SÓ como marca no banner/imagem; em frase corrida = **cura** sem chaves.

**Terminal (install.sh + install.ps1) — banner obrigatório no início:**
```
  { cura }  biblioteca 9.0
  instalador mac            ← ou "instalador windows"
```
- sh: ANSI 256-color quando stdout é tty (`[ -t 1 ]`): marca em verde cura ≈ `\033[38;5;151m`, texto bold `\033[1m`, erro em terracota ≈ `\033[38;5;131m`, reset `\033[0m`. Sem tty → plain ASCII sem escapes.
- ps1: se `$Host.UI.SupportsVirtualTerminal` → mesmos códigos ANSI via `$([char]27)`; senão fallback `Write-Host -ForegroundColor` (marca DarkGreen, erro DarkRed, resto default). Nunca depender de truecolor.
- Resumo final sem emoji, lowercase: `ok / instalado: cura | ferramentas v0.8.0 em 2 versões do SketchUp (2021, 2025). log: <path>`.
- E7 no espírito: separadores = linha reta `─` ou `-`, sem caixas ASCII rebuscadas.

**Inno wizard (efetor B):**
- `windows/wizard-large.bmp` 164×314 24-bit: fundo verde cura `#AFBCAF` chapado (E7: plano sólido, borda dura, sem gradiente/sombra), marca preta (cura-marca-preto.png, alpha compositado sobre o verde) centrada no terço superior, largura ~120px. Sem texto extra (Guarujá não licenciada pra embed; marca SVG/PNG já tem texto em path).
- `windows/wizard-small.bmp` 55×58 24-bit: marca preta sobre verde cura.
- `windows/cura.ico` (16/32/48/256): quadrado chapado verde cura + marca preta centrada (~70% da largura). Cantos retos (E7).
- Gerar via `tools/make_assets.py` (python3+PIL, stdlib+PIL only) — regenerável, entra no repo.
- `installer.iss`: `WizardStyle=modern`, `WizardImageFile`/`WizardSmallImageFile`/`SetupIconFile` apontando pros assets. [Messages] em PT-BR lowercase voz CURA: WelcomeLabel1 `biblioteca cura`; WelcomeLabel2 `este instalador baixa e instala a versão mais recente dos plugins e fontes do método cura.%n%nfeche o SketchUp antes de continuar.`; FinishedHeadingLabel `pronto`; FinishedLabel `biblioteca cura instalada. abra o SketchUp e confira o menu Extensões.`
- AppName mantém `Biblioteca CURA` (Adicionar/Remover do Windows = contexto do sistema, capitalização natural ajuda aluno achar).

**README.md:** topo com `<p align="center"><img src="assets/cura-marca-tight.svg" width="140"></p>`, título `# biblioteca cura`, headings lowercase. Prosa normal (aluno lê), sem emoji.

## Regras de código (obrigatórias, dos arquivos de memória)

- Shell: `set -euo pipefail`; mktemp+trap; nunca path sem quote; testar com `bash -n`.
- Python: pathlib, sem `strftime` com locale, stdlib only.
- PS: 5.1-safe, TLS12, BOM UTF-8.
- Destrutivo (remoção): SÓ nomes exatos do manifest/snapshot. Nunca rm -rf de glob solto. Nunca tocar em nada fora de Plugins/, Fonts e dirs CURA-Biblioteca.
- Msgs de erro: sempre com path do log e próximo passo pro aluno.
- Sem feature além deste spec (YAGNI). Sem auth, sem telemetria, sem auto-update de exe.
