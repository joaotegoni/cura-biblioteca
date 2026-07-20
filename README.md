<p align="center"><img src="assets/cura-marca-tight.svg" width="140"></p>

# biblioteca cura

A biblioteca cura reúne os plugins e fontes do método cura para SketchUp. Este instalador baixa sempre a versão mais recente diretamente do GitHub — não é preciso reinstalar manualmente a cada atualização; basta rodar o instalador de novo quando quiser atualizar (ele conserta a instalação existente).

## instalação

### windows

1. Baixe o instalador mais recente (`BibliotecaCURA-Setup.exe`) na [página de releases](https://github.com/joaotegoni/cura-biblioteca/releases/latest).
2. Execute o arquivo baixado.
3. O Windows SmartScreen provavelmente vai avisar que o programa é de um editor desconhecido (o instalador ainda não tem assinatura de código). Clique em **Mais informações** e depois em **Executar assim mesmo**.
4. Siga o assistente. Não é preciso ser administrador — a instalação é só para o seu usuário.
5. Se o SketchUp estiver aberto, feche-o quando o instalador pedir.
6. Ao final, abra o SketchUp e confira o menu **Extensões** para ver o `cura | ferramentas` instalado.

### mac

Abra o Terminal e cole a linha abaixo:

```
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/joaotegoni/cura-biblioteca/main/scripts/install.sh)"
```

O script baixa o manifest mais recente e instala os plugins e fontes em todas as versões do SketchUp encontradas no seu Mac.

## desinstalar

**Windows:** abra Configurações > Aplicativos (ou o Painel de Controle > Programas) e desinstale "Biblioteca CURA" como qualquer outro programa.

**Mac:** cole a mesma linha do Terminal usada na instalação, acrescentando `-- --uninstall` no final:

```
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/joaotegoni/cura-biblioteca/main/scripts/install.sh)" -- --uninstall
```

Os dois modos listam exatamente o que vão remover antes de agir.

## manutenção

Para publicar uma nova versão do plugin ou das fontes:

1. Troque os arquivos em `payload/` (`cura-ferramentas.rbz` e, quando existir, `fonts.zip`).
2. Rode `python3 tools/make_manifest.py` para recalcular os hashes sha256 e atualizar `manifest.json`.
3. Faça o commit das mudanças.
4. Crie e envie uma tag: `git tag vX.Y.Z && git push --tags`.
5. O GitHub Actions (`.github/workflows/release.yml`) compila o instalador do Windows e publica tudo automaticamente em uma nova release.

Para mudar a identidade visual (ícone e imagens do assistente de instalação), edite o logotipo de origem em `assets/` e rode `python3 tools/make_assets.py`. Os binários gerados (`windows/wizard-large.bmp`, `windows/wizard-small.bmp`, `windows/cura.ico`) entram no repositório junto com o resto — não são baixados em tempo de instalação.

## roadmap

- **Assinatura de código** (Windows e Mac): os slots já existem no instalador e no script; falta só o certificado.
- **Fontes**: o manifest já tem o campo pronto (`fonts`); quando as fontes chegarem, basta adicionar `fonts.zip` ao payload e rodar `make_manifest.py`.
- **Plugin por assinatura**: o manifest já suporta uma `url` absoluta por item — trocar esse campo por um endpoint autenticado permite restringir o download a quem tem assinatura ativa, sem mudar o instalador.
