#!/bin/bash
# scripts/install.sh — instalador da Biblioteca CURA (macOS)
#
# bash 3.2-compativel (macOS ships 3.2 por padrao): sem associative array,
# sem mapfile/readarray, sem ${var,,}. Ver SPEC.md na raiz do repo.
#
# Uso:
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/joaotegoni/cura-biblioteca/main/scripts/install.sh)"
#   ./install.sh --uninstall
#
# Variaveis de ambiente:
#   CURA_BASE_URL   override da URL/dir base dos assets (teste local). Aceita
#                   caminho absoluto ("/path/to/release") ou "file:///path" ->
#                   copia local (cp) em vez de curl. Default: release "latest"
#                   do GitHub.
#
# Exit codes: 0 = ok; 1 = parcial (SketchUp nao encontrado); 2 = falha.
set -euo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
DEFAULT_BASE_URL="https://github.com/joaotegoni/cura-biblioteca/releases/latest/download"
BASE_URL="${CURA_BASE_URL:-$DEFAULT_BASE_URL}"
BASE_URL="${BASE_URL%/}"

APP_SUPPORT_DIR="$HOME/Library/Application Support"
CURA_STATE_DIR="$APP_SUPPORT_DIR/CURA-Biblioteca"
SNAPSHOT_PATH="$CURA_STATE_DIR/installed.json"
LOG_PATH="$CURA_STATE_DIR/install.log"
FONTS_DIR="$HOME/Library/Fonts"

UNINSTALL=0
if [ "${1:-}" = "--uninstall" ]; then
  UNINSTALL=1
fi

# ---------------------------------------------------------------------------
# Cores (identidade visual CURA — só quando stdout é tty; sem tty = plain)
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
  C_VERDE=$'\033[38;5;151m'
  C_BOLD=$'\033[1m'
  C_ERRO=$'\033[38;5;131m'
  C_RESET=$'\033[0m'
else
  C_VERDE=""
  C_BOLD=""
  C_ERRO=""
  C_RESET=""
fi
SEPARADOR="----------------------------------------"

# separador de campo pros registros TSV internos (manifest/snapshot parsing).
# NAO usa tab: bash trata tab como "IFS whitespace" e COLAPSA delimitadores
# consecutivos (perde campos vazios, ex. url:null). 0x1f (unit separator) e
# um caractere de controle que nunca aparece em texto normal e nao sofre
# esse colapso — testado e confirmado antes de usar.
US=$'\x1f'

# ---------------------------------------------------------------------------
# Temp dir + cleanup
# ---------------------------------------------------------------------------
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cura-biblioteca.XXXXXX")"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$CURA_STATE_DIR"

# ---------------------------------------------------------------------------
# Log + mensagens (voz CURA: lowercase, sem emoji; excecao = numeros, siglas
# e nomes de produto como SketchUp/GitHub)
# ---------------------------------------------------------------------------
log() {
  local ts
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  printf '[%s] %s\n' "$ts" "$1" >> "$LOG_PATH"
}

log_header() {
  {
    printf '\n===== biblioteca cura — instalador mac — %s =====\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  } >> "$LOG_PATH"
}

say() {
  printf '%s\n' "$1"
  log "$1"
}

err() {
  printf '%s%s%s\n' "$C_ERRO" "$1" "$C_RESET" >&2
  log "erro: $1"
}

banner() {
  printf '\n'
  printf '  %s%s{ cura }%s  biblioteca 9.0\n' "$C_BOLD" "$C_VERDE" "$C_RESET"
  printf '  %sinstalador mac%s\n' "$C_BOLD" "$C_RESET"
  printf '  %s\n\n' "$SEPARADOR"
}

# ---------------------------------------------------------------------------
# Helpers gerais
# ---------------------------------------------------------------------------
json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# imprime um array JSON de strings (uma por linha, indentado) a partir dos
# argumentos recebidos apos o indent. Zero argumentos -> nada impresso
# (array JSON vazio e valido mesmo com so espaco em branco entre [ e ]).
print_json_string_array() {
  local indent="$1"; shift
  local n=$#
  local i=0
  local item
  for item in "$@"; do
    i=$((i + 1))
    if [ "$i" -lt "$n" ]; then
      printf '%s"%s",\n' "$indent" "$(json_escape "$item")"
    else
      printf '%s"%s"\n' "$indent" "$(json_escape "$item")"
    fi
  done
}

is_local_base() {
  case "$1" in
    /*) return 0 ;;
    file://*) return 0 ;;
    *) return 1 ;;
  esac
}

local_base_path() {
  case "$1" in
    file://*) printf '%s' "${1#file://}" ;;
    *) printf '%s' "$1" ;;
  esac
}

# roda "$@" com timeout manual de $1 segundos (sem depender de `timeout`,
# que nao vem por padrao no macOS). Usado so pra checar se python3 responde
# sem travar (stub do CLT em Mac sem Xcode Command Line Tools pode abrir
# popup de instalacao em vez de rodar).
run_with_timeout() {
  local secs="$1"; shift
  "$@" &
  local pid=$!
  ( sleep "$secs"; kill -9 "$pid" 2>/dev/null ) &
  local watcher=$!
  local status=0
  wait "$pid" 2>/dev/null || status=$?
  kill -9 "$watcher" 2>/dev/null || true
  wait "$watcher" 2>/dev/null || true
  return "$status"
}

PYTHON3_BIN=""
detect_python3() {
  if command -v python3 >/dev/null 2>&1; then
    if run_with_timeout 5 python3 --version >/dev/null 2>&1; then
      PYTHON3_BIN="python3"
    fi
  fi
}

verify_sha256() {
  local file="$1" expected="$2" actual
  actual="$(shasum -a 256 "$file" | awk '{print $1}')"
  [ "$actual" = "$expected" ]
}

# fetch_asset <nome-relativo-a-BASE_URL> <destino>
# aborta o script (exit 2) em falha de rede/local — sem internet no meio da
# instalacao compromete o download inteiro, nao só este item.
fetch_asset() {
  local name="$1" dest="$2"
  if is_local_base "$BASE_URL"; then
    local src_dir src
    src_dir="$(local_base_path "$BASE_URL")"
    src="$src_dir/$name"
    if [ ! -e "$src" ]; then
      err "arquivo não encontrado em modo local: $src. log: $LOG_PATH."
      exit 2
    fi
    cp "$src" "$dest"
  else
    if ! curl -fsSL --retry 3 --connect-timeout 30 "$BASE_URL/$name" -o "$dest"; then
      err "falha ao baixar $name — sem internet ou GitHub inacessível. log: $LOG_PATH. verifique sua conexão e rode o instalador de novo."
      exit 2
    fi
  fi
}

# fetch_absolute_url <url-ou-path-absoluta> <destino>
# usado quando um plugin declara "url" propria no manifest (em vez de null).
fetch_absolute_url() {
  local url="$1" dest="$2"
  if is_local_base "$url"; then
    local src
    src="$(local_base_path "$url")"
    if [ ! -e "$src" ]; then
      err "arquivo não encontrado em modo local: $src. log: $LOG_PATH."
      exit 2
    fi
    cp "$src" "$dest"
  else
    if ! curl -fsSL --retry 3 --connect-timeout 30 "$url" -o "$dest"; then
      err "falha ao baixar $url — sem internet ou GitHub inacessível. log: $LOG_PATH. verifique sua conexão e rode o instalador de novo."
      exit 2
    fi
  fi
}

# só nomes exatos (sem "/" nem "..") — nunca glob solto, nunca fora de
# Plugins/Fonts/CURA-Biblioteca (regra de codigo obrigatoria do SPEC).
is_safe_leaf_name() {
  case "$1" in
    "" | */* | *..*) return 1 ;;
    *) return 0 ;;
  esac
}

is_allowed_removal_path() {
  local p="$1"
  case "$p" in
    "$APP_SUPPORT_DIR"/SketchUp\ */SketchUp/Plugins/*) return 0 ;;
    "$FONTS_DIR"/*) return 0 ;;
    "$CURA_STATE_DIR"/*) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Scripts auxiliares (python3 + awk) embutidos — gravados em $TMP_DIR em
# runtime. install.sh e um arquivo unico distribuido via curl|bash, entao os
# parsers viajam dentro dele em vez de arquivos separados no release.
# ---------------------------------------------------------------------------
PARSE_MANIFEST_PY="$TMP_DIR/parse_manifest.py"
PARSE_MANIFEST_AWK="$TMP_DIR/parse_manifest.awk"
PARSE_SNAPSHOT_AWK="$TMP_DIR/parse_snapshot.awk"
WRITE_SNAPSHOT_PY="$TMP_DIR/write_snapshot.py"
WRITE_SNAPSHOT_AWK="$TMP_DIR/write_snapshot.awk"

write_helper_scripts() {
  cat > "$PARSE_MANIFEST_PY" <<'PYEOF'
import json
import sys

US = "\x1f"


def emit(*fields):
    print(US.join("" if f is None else str(f) for f in fields))


def main():
    path = sys.argv[1]
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)

    emit("SCALAR", "schema", data.get("schema", ""))
    emit("SCALAR", "biblioteca_version", data.get("biblioteca_version", ""))
    emit("SCALAR", "min_sketchup", data.get("min_sketchup", ""))

    for plugin in data.get("plugins", []) or []:
        roots = plugin.get("roots", []) or []
        url = plugin.get("url")
        emit(
            "PLUGIN",
            plugin.get("id", ""),
            plugin.get("name", ""),
            plugin.get("version", ""),
            plugin.get("file", ""),
            url if url else "",
            plugin.get("sha256", ""),
            ",".join(roots),
        )

    fonts = data.get("fonts")
    if fonts:
        families = fonts.get("families", []) or []
        emit("FONTS", fonts.get("file", ""), fonts.get("sha256", ""), ",".join(families))

    for name in data.get("remove", []) or []:
        emit("REMOVE", name)


if __name__ == "__main__":
    main()
PYEOF

  # parser de fallback (sem python3) pro manifest.json do schema 1. NAO e
  # parser JSON generico: assume formatacao gerada por tools/make_manifest.py
  # (json.dumps indent=2 — 2 espacos por nivel, um elemento de array por
  # linha). Manifest e nosso, formato controlado; parser simples e aceitavel.
  cat > "$PARSE_MANIFEST_AWK" <<'AWKEOF'
BEGIN {
  state = "top"
  US = "\037"
}

function unesc(s) {
  gsub(/\\\\/, "\\", s)
  gsub(/\\"/, "\"", s)
  return s
}

function strval(line,    v) {
  v = line
  sub(/^[^:]*:[ \t]*"/, "", v)
  sub(/",?[ \t]*$/, "", v)
  return unesc(v)
}

function arrval(line,    v) {
  v = line
  sub(/^[ \t]*"/, "", v)
  sub(/",?[ \t]*$/, "", v)
  return unesc(v)
}

function rawval(line,    v) {
  v = line
  sub(/^[^:]*:[ \t]*/, "", v)
  sub(/,[ \t]*$/, "", v)
  gsub(/^[ \t]+|[ \t]+$/, "", v)
  return v
}

state == "top" && /^  "schema":/ { print "SCALAR" US "schema" US rawval($0); next }
state == "top" && /^  "biblioteca_version":/ { print "SCALAR" US "biblioteca_version" US strval($0); next }
state == "top" && /^  "min_sketchup":/ { print "SCALAR" US "min_sketchup" US rawval($0); next }

state == "top" && /^  "plugins": \[\]/ { next }
state == "top" && /^  "plugins": \[/ { state = "plugins_wait"; next }

state == "plugins_wait" && /^    \{/ {
  state = "plugin"
  p_id = ""; p_name = ""; p_version = ""; p_file = ""; p_url = ""; p_sha256 = ""; p_roots = ""
  next
}
state == "plugins_wait" && /^  \]/ { state = "top"; next }

state == "plugin" && /^      "id":/      { p_id = strval($0); next }
state == "plugin" && /^      "name":/    { p_name = strval($0); next }
state == "plugin" && /^      "version":/ { p_version = strval($0); next }
state == "plugin" && /^      "file":/    { p_file = strval($0); next }
state == "plugin" && /^      "url":/ {
  raw = rawval($0)
  p_url = (raw == "null") ? "" : strval($0)
  next
}
state == "plugin" && /^      "sha256":/  { p_sha256 = strval($0); next }
state == "plugin" && /^      "roots": \[\]/ { next }
state == "plugin" && /^      "roots": \[/ { state = "roots"; next }
state == "plugin" && /^    \}/ {
  print "PLUGIN" US p_id US p_name US p_version US p_file US p_url US p_sha256 US p_roots
  state = "plugins_wait"
  next
}

state == "roots" && /^      \]/ { state = "plugin"; next }
state == "roots" {
  v = arrval($0)
  p_roots = (p_roots == "") ? v : p_roots "," v
  next
}

state == "top" && /^  "fonts": null/ { next }
state == "top" && /^  "fonts": \{/ {
  state = "fonts"
  f_file = ""; f_sha256 = ""; f_families = ""
  next
}
state == "fonts" && /^    "file":/    { f_file = strval($0); next }
state == "fonts" && /^    "sha256":/  { f_sha256 = strval($0); next }
state == "fonts" && /^    "families": \[\]/ { next }
state == "fonts" && /^    "families": \[/ { state = "families"; next }
state == "fonts" && /^  \}/ {
  print "FONTS" US f_file US f_sha256 US f_families
  state = "top"
  next
}
state == "families" && /^    \]/ { state = "fonts"; next }
state == "families" {
  v = arrval($0)
  f_families = (f_families == "") ? v : f_families "," v
  next
}

state == "top" && /^  "remove": \[\]/ { next }
state == "top" && /^  "remove": \[/ { state = "remove"; next }
state == "remove" && /^  \]/ { state = "top"; next }
state == "remove" {
  print "REMOVE" US arrval($0)
  next
}
AWKEOF

  cat > "$PARSE_SNAPSHOT_AWK" <<'AWKEOF2'
BEGIN { state = "top"; US = "\037" }
function arrval(line,    v) {
  v = line
  sub(/^[ \t]*"/, "", v)
  sub(/",?[ \t]*$/, "", v)
  gsub(/\\\\/, "\\", v)
  gsub(/\\"/, "\"", v)
  return v
}
function strval(line,    v) {
  v = line
  sub(/^[^:]*:[ \t]*"/, "", v)
  sub(/",?[ \t]*$/, "", v)
  gsub(/\\\\/, "\\", v)
  gsub(/\\"/, "\"", v)
  return v
}
state == "top" && /^  "biblioteca_version":/ { print "SCALAR" US "biblioteca_version" US strval($0); next }
state == "top" && /^  "installed_at":/ { print "SCALAR" US "installed_at" US strval($0); next }
state == "top" && /^  "item_labels": \[\]/ { next }
state == "top" && /^  "item_labels": \[/ { state = "labels"; next }
state == "labels" && /^  \]/ { state = "top"; next }
state == "labels" { print "LABEL" US arrval($0); next }
state == "top" && /^  "item_paths": \[\]/ { next }
state == "top" && /^  "item_paths": \[/ { state = "paths"; next }
state == "paths" && /^  \]/ { state = "top"; next }
state == "paths" { print "PATH" US arrval($0); next }
AWKEOF2

  cat > "$WRITE_SNAPSHOT_PY" <<'PYEOF2'
import json
import sys

US = "\x1f"


def main():
    tsv_path, out_path = sys.argv[1], sys.argv[2]
    biblioteca_version = ""
    installed_at = ""
    labels = []
    paths = []
    pending_label = None
    with open(tsv_path, "r", encoding="utf-8") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line:
                continue
            parts = line.split(US)
            rtype = parts[0]
            if rtype == "SCALAR":
                key, val = parts[1], parts[2]
                if key == "biblioteca_version":
                    biblioteca_version = val
                elif key == "installed_at":
                    installed_at = val
            elif rtype == "LABEL":
                pending_label = parts[1]
            elif rtype == "PATH":
                labels.append(pending_label)
                paths.append(parts[1])
                pending_label = None

    data = {
        "biblioteca_version": biblioteca_version,
        "installed_at": installed_at,
        "item_labels": labels,
        "item_paths": paths,
    }
    with open(out_path, "w", encoding="utf-8") as fh:
        fh.write(json.dumps(data, indent=2, ensure_ascii=False) + "\n")


if __name__ == "__main__":
    main()
PYEOF2

  cat > "$WRITE_SNAPSHOT_AWK" <<'AWKEOF3'
BEGIN {
  FS = "\037"
  n = 0
  biblioteca_version = ""
  installed_at = ""
  pending_label = ""
}
function jesc(s) {
  gsub(/\\/, "\\\\", s)
  gsub(/"/, "\\\"", s)
  return s
}
$1 == "SCALAR" && $2 == "biblioteca_version" { biblioteca_version = $3 }
$1 == "SCALAR" && $2 == "installed_at" { installed_at = $3 }
$1 == "LABEL" { pending_label = $2 }
$1 == "PATH" {
  n++
  labels[n] = pending_label
  paths[n] = $2
}
END {
  printf "{\n"
  printf "  \"biblioteca_version\": \"%s\",\n", jesc(biblioteca_version)
  printf "  \"installed_at\": \"%s\",\n", jesc(installed_at)
  printf "  \"item_labels\": [\n"
  for (i = 1; i <= n; i++) {
    comma = (i < n) ? "," : ""
    printf "    \"%s\"%s\n", jesc(labels[i]), comma
  }
  printf "  ],\n"
  printf "  \"item_paths\": [\n"
  for (i = 1; i <= n; i++) {
    comma = (i < n) ? "," : ""
    printf "    \"%s\"%s\n", jesc(paths[i]), comma
  }
  printf "  ]\n"
  printf "}\n"
}
AWKEOF3
}

# ---------------------------------------------------------------------------
# Estado global do manifest (arrays paralelos — bash 3.2 nao tem assoc array)
# ---------------------------------------------------------------------------
MIN_SKETCHUP=""
BIBLIOTECA_VERSION=""
PLUGIN_IDS=(); PLUGIN_NAMES=(); PLUGIN_VERSIONS=(); PLUGIN_FILES=()
PLUGIN_URLS=(); PLUGIN_SHA256S=(); PLUGIN_ROOTS_CSV=()
FONTS_FILE=""; FONTS_SHA256=""
REMOVE_NAMES=()
ALL_PLUGIN_ROOTS=()

parse_manifest() {
  local manifest_path="$1"
  local tsv="$TMP_DIR/manifest.tsv"

  if [ -n "$PYTHON3_BIN" ]; then
    if ! "$PYTHON3_BIN" "$PARSE_MANIFEST_PY" "$manifest_path" > "$tsv" 2>"$TMP_DIR/parse_manifest.err"; then
      err "manifest.json inválido ou não foi possível interpretá-lo. log: $LOG_PATH."
      log "detalhe (python3): $(cat "$TMP_DIR/parse_manifest.err" 2>/dev/null)"
      exit 2
    fi
  else
    awk -f "$PARSE_MANIFEST_AWK" "$manifest_path" > "$tsv"
  fi

  while IFS="$US" read -r rtype f1 f2 f3 f4 f5 f6 f7; do
    case "$rtype" in
      SCALAR)
        case "$f1" in
          min_sketchup) MIN_SKETCHUP="$f2" ;;
          biblioteca_version) BIBLIOTECA_VERSION="$f2" ;;
        esac
        ;;
      PLUGIN)
        PLUGIN_IDS+=("$f1")
        PLUGIN_NAMES+=("$f2")
        PLUGIN_VERSIONS+=("$f3")
        PLUGIN_FILES+=("$f4")
        PLUGIN_URLS+=("$f5")
        PLUGIN_SHA256S+=("$f6")
        PLUGIN_ROOTS_CSV+=("$f7")
        ;;
      FONTS)
        FONTS_FILE="$f1"
        FONTS_SHA256="$f2"
        ;;
      REMOVE)
        REMOVE_NAMES+=("$f1")
        ;;
    esac
  done < "$tsv"

  # uniao de todos os roots (usada na limpeza pre-instalacao/upgrade)
  local i csv old_ifs name
  for i in "${!PLUGIN_ROOTS_CSV[@]}"; do
    csv="${PLUGIN_ROOTS_CSV[$i]}"
    old_ifs="$IFS"
    IFS=','
    for name in $csv; do
      ALL_PLUGIN_ROOTS+=("$name")
    done
    IFS="$old_ifs"
  done
}

# ---------------------------------------------------------------------------
# Snapshot (installed.json) — escrita e leitura
# ---------------------------------------------------------------------------
ITEM_LABELS=(); ITEM_PATHS=()

write_snapshot() {
  local tsv="$TMP_DIR/snapshot_in.tsv"
  {
    printf 'SCALAR%sbiblioteca_version%s%s\n' "$US" "$US" "$BIBLIOTECA_VERSION"
    printf 'SCALAR%sinstalled_at%s%s\n' "$US" "$US" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    if [ "${#ITEM_LABELS[@]}" -gt 0 ]; then
      local idx
      for idx in "${!ITEM_LABELS[@]}"; do
        printf 'LABEL%s%s\n' "$US" "${ITEM_LABELS[$idx]}"
        printf 'PATH%s%s\n' "$US" "${ITEM_PATHS[$idx]}"
      done
    fi
  } > "$tsv"

  if [ -n "$PYTHON3_BIN" ]; then
    "$PYTHON3_BIN" "$WRITE_SNAPSHOT_PY" "$tsv" "$SNAPSHOT_PATH"
  else
    awk -f "$WRITE_SNAPSHOT_AWK" "$tsv" > "$SNAPSHOT_PATH"
  fi
}

SNAP_ITEM_LABELS=(); SNAP_ITEM_PATHS=()
SNAP_BIBLIOTECA_VERSION=""

read_snapshot() {
  local tsv="$TMP_DIR/snapshot_out.tsv"
  if [ -n "$PYTHON3_BIN" ]; then
    "$PYTHON3_BIN" - "$SNAPSHOT_PATH" > "$tsv" <<'PYEOF3'
import json
import sys

US = "\x1f"

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    d = json.load(fh)

print("SCALAR" + US + "biblioteca_version" + US + str(d.get("biblioteca_version", "")))
for label in d.get("item_labels", []) or []:
    print("LABEL" + US + str(label))
for path in d.get("item_paths", []) or []:
    print("PATH" + US + str(path))
PYEOF3
  else
    awk -f "$PARSE_SNAPSHOT_AWK" "$SNAPSHOT_PATH" > "$tsv"
  fi

  while IFS="$US" read -r rtype f1 f2; do
    case "$rtype" in
      SCALAR)
        [ "$f1" = "biblioteca_version" ] && SNAP_BIBLIOTECA_VERSION="$f2"
        ;;
      LABEL) SNAP_ITEM_LABELS+=("$f1") ;;
      PATH) SNAP_ITEM_PATHS+=("$f1") ;;
    esac
  done < "$tsv"
}

# ---------------------------------------------------------------------------
# Fluxo: aguarda SketchUp fechar (nao mata processo)
# ---------------------------------------------------------------------------
wait_sketchup_closed() {
  while pgrep -x "SketchUp" >/dev/null 2>&1; do
    printf '\nSketchUp está aberto. feche-o completamente antes de continuar.\n'
    printf 'pressione enter para verificar de novo (ou ctrl+c para cancelar): '
    # le como condicao de if (nao dispara set -e em falha). checar so
    # "[ -r /dev/tty ]" nao basta: o device pode existir e passar no teste
    # de permissao mas nao ter terminal de controle (ex. execucao headless)
    # e a redirecao falhar mesmo assim — só a tentativa real de leitura
    # revela isso. 2>/dev/null antes do "<" suprime o erro cru do bash.
    if read -r _ 2>/dev/null < /dev/tty; then
      :
    else
      log "aviso: /dev/tty indisponível — seguindo sem confirmar fechamento do SketchUp"
      break
    fi
  done
}

# ---------------------------------------------------------------------------
# Limpeza de um Plugins/ (lista remove + roots de instalacao anterior)
# ---------------------------------------------------------------------------
cleanup_plugins_dir() {
  local plugins_dir="$1"
  local name target

  if [ "${#REMOVE_NAMES[@]}" -gt 0 ]; then
    for name in "${REMOVE_NAMES[@]}"; do
      is_safe_leaf_name "$name" || continue
      target="$plugins_dir/$name"
      if [ -e "$target" ]; then
        rm -rf -- "$target"
        log "removido (lista remove): $target"
      fi
    done
  fi

  if [ "${#ALL_PLUGIN_ROOTS[@]}" -gt 0 ]; then
    for name in "${ALL_PLUGIN_ROOTS[@]}"; do
      is_safe_leaf_name "$name" || continue
      target="$plugins_dir/$name"
      if [ -e "$target" ]; then
        rm -rf -- "$target"
        log "removido (upgrade limpo): $target"
      fi
    done
  fi
}

# ---------------------------------------------------------------------------
# Instalacao
# ---------------------------------------------------------------------------
do_install() {
  log_header
  banner
  wait_sketchup_closed

  detect_python3
  write_helper_scripts

  local manifest_path="$TMP_DIR/manifest.json"
  fetch_asset "manifest.json" "$manifest_path"
  parse_manifest "$manifest_path"

  local VERSION_YEARS=() VERSION_DIRS=()
  local d base year plugins_dir
  for d in "$APP_SUPPORT_DIR"/"SketchUp 20"*; do
    [ -e "$d" ] || continue
    [ -d "$d" ] || continue
    base="$(basename "$d")"
    year="${base#SketchUp }"
    year="${year%% *}"
    case "$year" in
      '' | *[!0-9]*) continue ;;
    esac
    if [ "$year" -ge "$MIN_SKETCHUP" ]; then
      plugins_dir="$d/SketchUp/Plugins"
      mkdir -p "$plugins_dir"
      VERSION_YEARS+=("$year")
      VERSION_DIRS+=("$plugins_dir")
    fi
  done

  local HAD_ERROR=0

  if [ "${#VERSION_YEARS[@]}" -eq 0 ]; then
    say "SketchUp não encontrado — instalando só as fontes. instale o SketchUp e rode este instalador de novo."
  else
    # download + verificacao de cada plugin (1x, independente de quantas
    # versoes do SketchUp existam)
    mkdir -p "$TMP_DIR/payload"
    local PLUGIN_OK=()
    local i file url sha_expected dest
    for i in "${!PLUGIN_IDS[@]}"; do
      file="${PLUGIN_FILES[$i]}"
      url="${PLUGIN_URLS[$i]}"
      sha_expected="${PLUGIN_SHA256S[$i]}"
      dest="$TMP_DIR/payload/$file"

      if [ -n "$url" ]; then
        fetch_absolute_url "$url" "$dest"
      else
        fetch_asset "$file" "$dest"
      fi

      if verify_sha256 "$dest" "$sha_expected"; then
        PLUGIN_OK+=("1")
      else
        err "arquivo $file corrompido no download (sha256 não confere) — ${PLUGIN_NAMES[$i]} não instalado. log: $LOG_PATH. tente rodar o instalador de novo mais tarde."
        PLUGIN_OK+=("0")
        HAD_ERROR=1
      fi
    done

    # por versao: limpeza (upgrade limpo) + instala os plugins baixados com sucesso
    local vi year_v plugins_dir_v pi root_name root_path
    for vi in "${!VERSION_YEARS[@]}"; do
      year_v="${VERSION_YEARS[$vi]}"
      plugins_dir_v="${VERSION_DIRS[$vi]}"
      cleanup_plugins_dir "$plugins_dir_v"

      for pi in "${!PLUGIN_IDS[@]}"; do
        if [ "${PLUGIN_OK[$pi]}" = "1" ]; then
          unzip -oq "$TMP_DIR/payload/${PLUGIN_FILES[$pi]}" -d "$plugins_dir_v"
          log "instalado: ${PLUGIN_NAMES[$pi]} v${PLUGIN_VERSIONS[$pi]} em SketchUp $year_v"

          local old_ifs="$IFS"
          IFS=','
          for root_name in ${PLUGIN_ROOTS_CSV[$pi]}; do
            root_path="$plugins_dir_v/$root_name"
            if [ -e "$root_path" ]; then
              ITEM_LABELS+=("plugin ${PLUGIN_NAMES[$pi]} v${PLUGIN_VERSIONS[$pi]} (SketchUp $year_v)")
              ITEM_PATHS+=("$root_path")
            fi
          done
          IFS="$old_ifs"
        fi
      done
    done
  fi

  # fontes (independe de ter achado SketchUp — instala sempre que o manifest tiver)
  local FONTS_INSTALLED_COUNT=0
  if [ -n "$FONTS_FILE" ]; then
    local fonts_dest="$TMP_DIR/payload/$FONTS_FILE"
    mkdir -p "$TMP_DIR/payload"
    fetch_asset "$FONTS_FILE" "$fonts_dest"
    if verify_sha256 "$fonts_dest" "$FONTS_SHA256"; then
      mkdir -p "$FONTS_DIR"
      local extract_dir="$TMP_DIR/fonts_extracted"
      mkdir -p "$extract_dir"
      unzip -oq "$fonts_dest" -d "$extract_dir"
      local fontfile fontbase
      while IFS= read -r fontfile; do
        fontbase="$(basename "$fontfile")"
        cp "$fontfile" "$FONTS_DIR/$fontbase"
        FONTS_INSTALLED_COUNT=$((FONTS_INSTALLED_COUNT + 1))
        ITEM_LABELS+=("fonte $fontbase")
        ITEM_PATHS+=("$FONTS_DIR/$fontbase")
        log "fonte instalada: $FONTS_DIR/$fontbase"
      done < <(find "$extract_dir" -type f \( -iname '*.ttf' -o -iname '*.otf' -o -iname '*.ttc' \))
    else
      err "arquivo $FONTS_FILE corrompido no download (sha256 não confere) — fontes não instaladas. log: $LOG_PATH. tente rodar o instalador de novo mais tarde."
      HAD_ERROR=1
    fi
  else
    log "fontes: manifest sem fontes (fonts: null), etapa pulada."
  fi

  write_snapshot

  # resumo final
  printf '\n%s\n' "$SEPARADOR"
  if [ "${#VERSION_YEARS[@]}" -eq 0 ]; then
    if [ "$FONTS_INSTALLED_COUNT" -gt 0 ]; then
      say "fontes instaladas: $FONTS_INSTALLED_COUNT. log: $LOG_PATH."
    else
      say "log: $LOG_PATH."
    fi
    exit 1
  fi

  local ok_plugins_desc="" first=1 piece
  for i in "${!PLUGIN_IDS[@]}"; do
    if [ "${PLUGIN_OK[$i]}" = "1" ]; then
      piece="${PLUGIN_NAMES[$i]} v${PLUGIN_VERSIONS[$i]}"
      if [ "$first" = "1" ]; then
        ok_plugins_desc="$piece"
        first=0
      else
        ok_plugins_desc="$ok_plugins_desc, $piece"
      fi
    fi
  done

  local versions_desc="" y
  for y in "${VERSION_YEARS[@]}"; do
    if [ -z "$versions_desc" ]; then
      versions_desc="$y"
    else
      versions_desc="$versions_desc, $y"
    fi
  done

  local ver_word="versões"
  [ "${#VERSION_YEARS[@]}" = "1" ] && ver_word="versão"

  local fonts_suffix=""
  if [ "$FONTS_INSTALLED_COUNT" -gt 0 ]; then
    fonts_suffix="; $FONTS_INSTALLED_COUNT fontes"
  fi

  local msg
  if [ -z "$ok_plugins_desc" ]; then
    msg="nenhum plugin instalado (falha de integridade) em ${#VERSION_YEARS[@]} ${ver_word} do SketchUp (${versions_desc})${fonts_suffix}. log: $LOG_PATH."
  else
    msg="instalado: ${ok_plugins_desc} em ${#VERSION_YEARS[@]} ${ver_word} do SketchUp (${versions_desc})${fonts_suffix}. log: $LOG_PATH. abra o SketchUp e confira o menu Extensões."
  fi

  if [ "$HAD_ERROR" = "1" ]; then
    say "$msg"
    log "resumo: instalação parcial (havia item com falha de integridade)"
    exit 2
  fi

  printf '%sok /%s %s\n' "$C_BOLD" "$C_RESET" "$msg"
  log "resumo: ok / $msg"
  exit 0
}

# ---------------------------------------------------------------------------
# Desinstalacao — "explicando cada um"
# ---------------------------------------------------------------------------
do_uninstall() {
  log_header
  banner

  if [ ! -f "$SNAPSHOT_PATH" ]; then
    say "nada instalado por este instalador (nenhum registro encontrado em $SNAPSHOT_PATH)."
    exit 0
  fi

  detect_python3
  write_helper_scripts
  read_snapshot

  if [ "${#SNAP_ITEM_PATHS[@]}" -eq 0 ]; then
    say "nada instalado por este instalador (registro vazio em $SNAPSHOT_PATH)."
    rm -f "$SNAPSHOT_PATH"
    exit 0
  fi

  say "a biblioteca cura vai remover os seguintes itens:"
  local i
  for i in "${!SNAP_ITEM_PATHS[@]}"; do
    printf -- '- %s: %s\n' "${SNAP_ITEM_LABELS[$i]:-item}" "${SNAP_ITEM_PATHS[$i]}"
  done

  printf 'confirma a remoção? (s/n): '
  local resp=""
  # ver nota em wait_sketchup_closed: "[ -r /dev/tty ]" sozinho nao basta,
  # a tentativa real de leitura e que revela terminal indisponivel.
  if ! read -r resp 2>/dev/null < /dev/tty; then
    err "não foi possível confirmar (terminal indisponível). desinstalação cancelada por segurança. log: $LOG_PATH."
    exit 2
  fi

  case "$resp" in
    s | S | sim | Sim | SIM) ;;
    *)
      say "cancelado. nada foi removido."
      exit 0
      ;;
  esac

  local path
  for path in "${SNAP_ITEM_PATHS[@]}"; do
    if is_allowed_removal_path "$path"; then
      if [ -e "$path" ]; then
        rm -rf -- "$path"
        log "removido (uninstall): $path"
      fi
    else
      log "aviso: caminho fora do escopo permitido, ignorado na desinstalação: $path"
    fi
  done

  rm -f "$SNAPSHOT_PATH"
  printf '%sok /%s biblioteca cura desinstalada. log: %s\n' "$C_BOLD" "$C_RESET" "$LOG_PATH"
  log "resumo: ok / biblioteca cura desinstalada"
  exit 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
if [ "$UNINSTALL" = "1" ]; then
  do_uninstall
else
  do_install
fi
