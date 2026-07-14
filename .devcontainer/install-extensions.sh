#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────
#  Instalador de extensiones para Antigravity IDE (devcontainer).
#  Antigravity v0.0.1 IGNORA customizations.vscode.extensions (Problema 3),
#  así que las descargamos de Open VSX y registramos en extensions.json
#  (Problema 5). Maneja publisher con mayúsculas y VSIX platform-specific
#  (Problema 4) y permite pinear versiones por engine (Problema 6).
#  Idempotente: salta extensiones ya instaladas (Problema 7).
# ─────────────────────────────────────────────────────────────────────────
set -euo pipefail

EXTENSIONS_DIR="/home/devuser/.antigravity-ide-server/extensions"
EXTENSIONS_JSON="${EXTENSIONS_DIR}/extensions.json"
ARCH=$(uname -m)
PLATFORM="linux-x64"
[ "$ARCH" = "aarch64" ] && PLATFORM="linux-arm64"

mkdir -p "$EXTENSIONS_DIR"
[ -f "$EXTENSIONS_JSON" ] || echo "[]" > "$EXTENSIONS_JSON"

register_extension() {
  local extid="$1" version="$2" extdir="$3"
  python3 - "$extid" "$version" "$extdir" "$EXTENSIONS_JSON" <<'EOF'
import json, sys
extid, version, extdir, path = sys.argv[1:]
with open(path) as f:
    exts = json.load(f)
exts = [e for e in exts if e['identifier']['id'] != extid]
exts.append({
    'identifier': {'id': extid},
    'version': version,
    'location': {'$mid': 1, 'path': extdir, 'scheme': 'file'},
    'relativeLocation': extdir.split('/')[-1]
})
with open(path, 'w') as f:
    json.dump(exts, f)
EOF
}

# install_vsix <publisher> <name> [pinned-version]
install_vsix() {
  local publisher="$1" name="$2" pinned="${3:-}"
  local extid
  extid="$(echo "$publisher" | tr '[:upper:]' '[:lower:]').${name}"

  local version
  if [ -n "$pinned" ]; then
    version="$pinned"
  else
    version=$(curl -sf "https://open-vsx.org/api/${publisher}/${name}" \
      | python3 -c "import sys,json; print(json.load(sys.stdin)['version'])") || {
      echo "[ext] WARN: ${extid} not on Open VSX, skipping"
      return 0
    }
  fi

  local extdir="${EXTENSIONS_DIR}/${extid}-${version}"

  # Eliminar versiones anteriores del mismo extid
  for old in "${EXTENSIONS_DIR}/${extid}"-*/; do
    [ -d "$old" ] && [ "$old" != "${extdir}/" ] && rm -rf "$old"
  done

  if [ -d "$extdir" ]; then
    echo "[ext] ${extid}@${version} already installed"
    register_extension "$extid" "$version" "$extdir"
    return 0
  fi

  # 1º intenta URL platform-specific, 2º cae a la genérica (Problema 4)
  local download_url
  download_url=$(curl -sf "https://open-vsx.org/api/${publisher}/${name}/${PLATFORM}/${version}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('files',{}).get('download',''))" 2>/dev/null || true)

  if [ -z "$download_url" ]; then
    download_url="https://open-vsx.org/api/${publisher}/${name}/${version}/file/${publisher}.${name}-${version}.vsix"
  fi

  echo "[ext] Installing ${extid}@${version} (${PLATFORM})..."
  local tmp
  tmp=$(mktemp -d)
  trap "rm -rf '$tmp'" RETURN

  curl -sfL "$download_url" -o "$tmp/ext.vsix" || {
    echo "[ext] WARN: download failed for ${extid}, skipping"
    return 0
  }
  unzip -q "$tmp/ext.vsix" "extension/*" -d "$tmp/extracted" || {
    echo "[ext] WARN: unzip failed for ${extid}, skipping"
    return 0
  }
  mv "$tmp/extracted/extension" "$extdir"
  register_extension "$extid" "$version" "$extdir"
  echo "[ext] Installed ${extid}@${version}"
}

# ── Extensiones del proyecto (engine OK con Antigravity 1.107.0 → sin pin) ──
install_vsix ms-python  python                              # 2026.4.0  (generic)
install_vsix ms-toolsai jupyter                             # 2025.9.1  (generic)
install_vsix ms-toolsai vscode-jupyter-cell-tags            # 0.1.9     (generic)
install_vsix amazonwebservices aws-toolkit-vscode           # 4.7.0     (generic)
install_vsix Anthropic  claude-code                         # 2.1.186   (platform-specific linux-arm64)

echo "[ext] Done. Registered extensions:"
python3 -c "import json; print('  ' + '\n  '.join(e['identifier']['id']+'@'+e['version'] for e in json.load(open('$EXTENSIONS_JSON'))))" 2>/dev/null || true
