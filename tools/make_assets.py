#!/usr/bin/env python3
"""tools/make_assets.py — gera os assets visuais do instalador Windows.

Uso:
    python3 tools/make_assets.py

Compoe o logotipo preto da cura (assets/cura-marca-preto.png, com fallback pro
master em ~/dev/cura-ferramentas) sobre o verde cura #AFBCAF solido (paleta E1
do DNA CURA, sem gradiente/sombra/canto redondo) e gera, em windows/:

    wizard-large.bmp  164x314  24-bit  (WizardImageFile do Inno)
    wizard-small.bmp   55x58   24-bit  (WizardSmallImageFile do Inno)
    cura.ico     16/32/48/256          (SetupIconFile do Inno)

Regenaravel: roda de novo sempre que o logotipo mudar. Os binarios gerados
entram no repo (nao sao baixados em runtime, ao contrario dos payloads de
plugin/fontes).

Stdlib + PIL apenas — sem dependencias externas alem do Pillow.
"""
from __future__ import annotations

from pathlib import Path

from PIL import Image

REPO_ROOT = Path(__file__).resolve().parent.parent
WINDOWS_DIR = REPO_ROOT / "windows"

# Paleta E1 (fechada) — verde cura e o fundo default de todo asset gerado aqui.
VERDE_CURA = (0xAF, 0xBC, 0xAF)

# Preferencia: copia local em assets/ (canonica pro repo); fallback pro master
# 512px em ~/dev/cura-ferramentas caso assets/ ainda nao tenha sido povoada.
MARK_SOURCE_CANDIDATES = [
    REPO_ROOT / "assets" / "cura-marca-preto.png",
    Path.home() / "dev/cura-ferramentas/src/cura_ferramentas/core/assets/cura-marca-preto-512.png",
]


def find_mark_source() -> Path:
    for candidate in MARK_SOURCE_CANDIDATES:
        if candidate.is_file():
            return candidate
    raise FileNotFoundError(
        "cura-marca-preto.png nao encontrado em nenhum dos caminhos esperados: "
        + ", ".join(str(c) for c in MARK_SOURCE_CANDIDATES)
    )


def load_tight_mark() -> Image.Image:
    """Abre o logotipo preto e corta pro bounding box real do canal alpha.

    O PNG master vem com bastante margem transparente ao redor da marca (e a
    marca e tinta preta pura - R=G=B=0 - entao o corte tem que ser feito no
    canal alpha isolado, nunca via Image.getbbox() direto na imagem RGBA, ou o
    resultado sai errado pra tinta preta sobre fundo transparente).
    """
    im = Image.open(find_mark_source()).convert("RGBA")
    alpha = im.split()[-1]
    bbox = alpha.getbbox()
    if bbox is None:
        raise ValueError("logotipo sem conteudo visivel (canal alpha vazio)")
    return im.crop(bbox)


def compose_on_solid(
    mark: Image.Image,
    canvas_size: tuple[int, int],
    mark_width: int,
    position: tuple[int, int] | None = None,
    bg: tuple[int, int, int] = VERDE_CURA,
) -> Image.Image:
    """Cola `mark` (RGBA, preta) redimensionada pra `mark_width` px de largura
    (mantendo proporcao) sobre um fundo solido `bg`, sem gradiente/sombra.

    `position` e o canto superior-esquerdo onde colar; None = centralizada.
    """
    canvas = Image.new("RGB", canvas_size, bg)
    scale = mark_width / mark.width
    mark_height = max(1, round(mark.height * scale))
    mark_resized = mark.resize((mark_width, mark_height), Image.LANCZOS)
    if position is None:
        x = (canvas_size[0] - mark_width) // 2
        y = (canvas_size[1] - mark_height) // 2
    else:
        x, y = position
    canvas.paste(mark_resized, (x, y), mark_resized)
    return canvas


def make_wizard_large(mark: Image.Image) -> Image.Image:
    """164x314 - marca ~120px de largura, centrada no terco superior."""
    size = (164, 314)
    mark_width = 120
    scale = mark_width / mark.width
    mark_height = max(1, round(mark.height * scale))
    x = (size[0] - mark_width) // 2
    y = max(0, round(size[1] / 6) - mark_height // 2)
    return compose_on_solid(mark, size, mark_width, position=(x, y))


def make_wizard_small(mark: Image.Image) -> Image.Image:
    """55x58 - marca preta sobre verde cura, ocupando a maior parte da largura."""
    size = (55, 58)
    mark_width = 44  # ~80% da largura, com pequena margem
    return compose_on_solid(mark, size, mark_width)


def make_icon_base(mark: Image.Image) -> Image.Image:
    """Canvas quadrado 256x256 - marca preta a ~70% da largura, cantos retos."""
    base = 256
    mark_width = round(base * 0.70)
    return compose_on_solid(mark, (base, base), mark_width)


def save_bmp_24bit(im: Image.Image, path: Path) -> None:
    im.convert("RGB").save(path, "BMP")


def main() -> int:
    WINDOWS_DIR.mkdir(parents=True, exist_ok=True)
    mark = load_tight_mark()

    wizard_large_path = WINDOWS_DIR / "wizard-large.bmp"
    save_bmp_24bit(make_wizard_large(mark), wizard_large_path)
    print(f"gerado: {wizard_large_path.relative_to(REPO_ROOT)} (164x314, 24-bit)")

    wizard_small_path = WINDOWS_DIR / "wizard-small.bmp"
    save_bmp_24bit(make_wizard_small(mark), wizard_small_path)
    print(f"gerado: {wizard_small_path.relative_to(REPO_ROOT)} (55x58, 24-bit)")

    icon_path = WINDOWS_DIR / "cura.ico"
    make_icon_base(mark).save(icon_path, sizes=[(16, 16), (32, 32), (48, 48), (256, 256)])
    print(f"gerado: {icon_path.relative_to(REPO_ROOT)} (16/32/48/256)")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
