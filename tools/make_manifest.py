#!/usr/bin/env python3
"""tools/make_manifest.py — recalcula sha256 de payload/* e reescreve manifest.json.

Uso:
    python3 tools/make_manifest.py

Roda a partir de qualquer diretorio (resolve a raiz do repo pelo proprio
caminho deste arquivo). Le o manifest.json existente na raiz, recalcula o
sha256 de cada payload declarado (plugins[].file e, se presente, fonts.file)
contra o arquivo correspondente em payload/, e regrava manifest.json com os
hashes atualizados. Nao inventa nem remove campos — so atualiza "sha256" dos
itens ja descritos no manifest, preservando todo o resto (schema,
biblioteca_version, min_sketchup, ids, roots, remove[], fonts: null etc).

Usado em CI (.github/workflows/release.yml, job de release) e manutencao
manual: trocar o payload -> rodar este script -> commit -> tag.

Stdlib puro (pathlib, hashlib, json) — sem dependencias externas.
"""
from __future__ import annotations

import hashlib
import json
import sys
import zipfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
MANIFEST_PATH = REPO_ROOT / "manifest.json"
PAYLOAD_DIR = REPO_ROOT / "payload"

# leitura em blocos p/ nao carregar arquivos grandes inteiros na memoria
_CHUNK_SIZE = 1024 * 1024


def sha256_of(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(_CHUNK_SIZE), b""):
            digest.update(chunk)
    return digest.hexdigest()


def update_entry(entry: dict, *, label: str) -> tuple[str, str, str] | None:
    """Recalcula sha256 de um item (plugin ou fonts) que tenha campo 'file'.

    Retorna (label, hash_antigo, hash_novo) p/ log, ou None se nao houver
    'file' declarado (entrada incompleta — ignorada, nao e erro fatal aqui;
    quem valida o schema completo e o instalador no momento do uso).
    """
    file_name = entry.get("file")
    if not file_name:
        return None

    payload_path = PAYLOAD_DIR / file_name
    if not payload_path.is_file():
        print(f"ERRO: payload nao encontrado p/ {label}: {payload_path}", file=sys.stderr)
        raise SystemExit(1)

    old_hash = entry.get("sha256")
    new_hash = sha256_of(payload_path)
    entry["sha256"] = new_hash
    return (label, old_hash, new_hash)


def validate_roots(entry: dict, payload_path: Path, *, label: str) -> None:
    """Confere que 'roots' do manifest bate com as entradas de topo reais
    dentro do .rbz/.zip (primeiro segmento de cada nome, deduplicado).

    'roots' é o que cleanup/uninstall usam pra achar o que remover no disco
    (SPEC.md: "roots = entradas raiz que o .rbz cria em Plugins/"); nada mais
    no pipeline confere isso contra o conteudo real do zip. Divergiu -> erro
    fatal (SystemExit 1), mesmo criterio de payload ausente acima — melhor
    quebrar o CI do que deixar 'roots' desatualizado ir pra producao calado.
    """
    declared = set(entry.get("roots") or [])
    with zipfile.ZipFile(payload_path) as zf:
        actual = {name.split("/", 1)[0] for name in zf.namelist() if name.split("/", 1)[0]}
    if declared != actual:
        print(f"ERRO: 'roots' de {label} não bate com o conteúdo do zip.", file=sys.stderr)
        print(f"  roots do manifest: {sorted(declared)}", file=sys.stderr)
        print(f"  entradas de topo no zip: {sorted(actual)}", file=sys.stderr)
        raise SystemExit(1)


def main() -> int:
    if not MANIFEST_PATH.is_file():
        print(f"ERRO: manifest nao encontrado em {MANIFEST_PATH}", file=sys.stderr)
        return 1

    manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))

    changes: list[tuple[str, str, str]] = []

    for plugin in manifest.get("plugins", []) or []:
        label = f"plugin {plugin.get('id', '?')} ({plugin.get('file', '?')})"
        result = update_entry(plugin, label=label)
        if result:
            changes.append(result)
            validate_roots(plugin, PAYLOAD_DIR / plugin["file"], label=label)

    fonts = manifest.get("fonts")
    if fonts is not None:
        result = update_entry(fonts, label=f"fonts ({fonts.get('file', '?')})")
        if result:
            changes.append(result)

    MANIFEST_PATH.write_text(
        json.dumps(manifest, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )

    if not changes:
        print("Nenhum item com payload p/ hashear (plugins vazio e fonts null).")
    for label, old_hash, new_hash in changes:
        mark = "sem mudanca" if old_hash == new_hash else "ALTERADO"
        print(f"{label}: sha256={new_hash} ({mark})")

    print(f"manifest.json atualizado: {MANIFEST_PATH}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
