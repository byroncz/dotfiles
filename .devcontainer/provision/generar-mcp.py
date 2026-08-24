#!/usr/bin/env python3
"""Genera las configuraciones de MCP desde el origen único.

    mcp/servers.json  ->  <workspace>/.mcp.json   (Claude Code, JSON)
                      ->  ~/.codex/config.toml    (Codex, TOML)

Ambos declaran los MISMOS servidores con los MISMOS comandos, porque salen de
la misma estructura en memoria. Es la única forma de que no divergan.

Solo stdlib, y solo `json`: python3-minimal no trae `tomllib` y aquí hay que
ESCRIBIR TOML, no leerlo, así que se emite a mano. El TOML que hace falta son
tablas de tres claves; una dependencia para eso no se paga.

Nunca aborta el arranque: ante cualquier problema avisa y devuelve 0. Un
devcontainer que no arranca por una config de MCP es peor que uno sin MCP.
"""

import json
import os
import sys
from pathlib import Path

MARCA = "generado por .devcontainer/provision/generar-mcp.py"


def log(msg):
    print(f"[mcp] {msg}")


def servidores_activos(origen):
    """Los servidores habilitados, con sus secretos resueltos desde el entorno.

    Un servidor con `env_desde` cuya variable no esté definida se queda FUERA.
    Escribirlo con la credencial vacía lo dejaría fallando en silencio en cada
    arranque del agente, que es mucho más difícil de diagnosticar que su
    ausencia.
    """
    activos = {}
    for nombre, cfg in origen.get("servers", {}).items():
        if not cfg.get("enabled", False):
            log(f"{nombre}: desactivado en servers.json, no se genera")
            continue

        env, falta = {}, []
        for var in cfg.get("env_desde", []):
            valor = os.environ.get(var)
            if valor:
                env[var] = valor
            else:
                falta.append(var)
        if falta:
            log(f"{nombre}: omitido, falta {', '.join(falta)} en el entorno")
            continue

        activos[nombre] = {
            "command": cfg["command"],
            "args": list(cfg.get("args", [])),
            "env": env,
        }
    return activos


def escribir_si_es_nuestro(destino, contenido, etiqueta):
    """Escribe solo si el archivo no existe o lo generamos nosotros.

    Un archivo escrito a mano no se pisa: se avisa y se deja como está. La
    marca en la primera línea es lo que distingue un caso del otro.
    """
    destino = Path(destino)
    if destino.exists():
        try:
            previo = destino.read_text(encoding="utf-8")
        except OSError as e:
            log(f"AVISO: no pude leer {destino} ({e}); lo dejo como está")
            return
        if MARCA not in previo:
            log(f"AVISO: {destino} no lo generamos nosotros; lo dejo como está")
            return
        if previo == contenido:
            log(f"{etiqueta}: sin cambios")
            return
    try:
        destino.parent.mkdir(parents=True, exist_ok=True)
        destino.write_text(contenido, encoding="utf-8")
    except OSError as e:
        log(f"AVISO: no pude escribir {destino} ({e})")
        return
    log(f"{etiqueta} -> {destino}")


def render_claude(activos):
    """.mcp.json de Claude Code.

    La marca va en una clave `_generado`: JSON no admite comentarios, y sin
    marca no hay forma de distinguir este archivo de uno escrito a mano.
    """
    doc = {
        "_generado": MARCA + " — no editar, edita .devcontainer/mcp/servers.json",
        "mcpServers": {
            n: {"command": c["command"], "args": c["args"], "env": c["env"]}
            for n, c in activos.items()
        },
    }
    return json.dumps(doc, indent=2, ensure_ascii=False) + "\n"


def toml_str(valor):
    """Cadena TOML básica. json.dumps escapa igual que TOML para \\ y \"."""
    return json.dumps(str(valor), ensure_ascii=False)


def toml_clave(nombre):
    """Clave TOML: desnuda si puede, entrecomillada si no.

    TOML admite [A-Za-z0-9_-] desnudo, así que `basic-memory` va tal cual;
    cualquier otra cosa (un punto, un espacio) tiene que ir entre comillas o
    el archivo no parsea.
    """
    if nombre and all(c.isalnum() or c in "_-" for c in nombre):
        return nombre
    return toml_str(nombre)


def render_codex(activos):
    """~/.codex/config.toml. Codex espera tablas [mcp_servers.<nombre>]."""
    lineas = [
        f"# {MARCA}",
        "# No editar: edita .devcontainer/mcp/servers.json y reabre el container.",
    ]
    for nombre, cfg in activos.items():
        lineas.append("")
        lineas.append(f"[mcp_servers.{toml_clave(nombre)}]")
        lineas.append(f"command = {toml_str(cfg['command'])}")
        lineas.append("args = [" + ", ".join(toml_str(a) for a in cfg["args"]) + "]")
        if cfg["env"]:
            pares = ", ".join(
                f"{toml_clave(k)} = {toml_str(v)}" for k, v in cfg["env"].items()
            )
            lineas.append("env = { " + pares + " }")
    return "\n".join(lineas) + "\n"


def main():
    aqui = Path(__file__).resolve().parent
    origen_path = aqui.parent / "mcp" / "servers.json"
    workspace = Path(os.environ.get("WORKSPACE_DIR", "/workspace"))
    home = Path(os.environ.get("HOME", str(Path.home())))

    if not origen_path.is_file():
        log(f"AVISO: no encuentro {origen_path}; no genero nada")
        return 0
    try:
        origen = json.loads(origen_path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as e:
        log(f"AVISO: {origen_path} no es JSON válido ({e}); no genero nada")
        return 0

    activos = servidores_activos(origen)
    if not activos:
        log("ningún servidor habilitado; no genero nada")
        return 0

    escribir_si_es_nuestro(workspace / ".mcp.json", render_claude(activos), "Claude")
    escribir_si_es_nuestro(home / ".codex" / "config.toml", render_codex(activos), "Codex")
    log("servidores: " + ", ".join(sorted(activos)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
