// devkit: abre la chuleta de comandos (cheatsheet.html, generado por
// gen-cheatsheet.sh) en un panel webview, a pedido del comando "devkit:
// comandos". La chuleta ya no se abre sola al arrancar el editor: desde
// DEVKIT-143 el fondo del editor vacío (letterpress) la muestra como marca
// de agua -ver Dockerfile y gen-cheatsheet.sh-, así que la pestaña webview
// de DEVKIT-96/117 solo estorbaría.
const vscode = require('vscode');
const fs = require('fs');
const path = require('path');

const VIEW_TYPE = 'devkit.cheatsheet';
const TITULO = 'devkit: comandos';
const RUTA_SETTINGS = path.join(__dirname, 'settings.json');

function leerHtml() {
  return fs.readFileSync(path.join(__dirname, 'cheatsheet.html'), 'utf8');
}

// openvscode-server no lee ningún archivo como ajustes de usuario del
// navegador (DEVKIT-116): la única forma de dejarlos vigentes es escribirlos
// por la API de configuración. settings.json (copiado junto a esta extensión
// por el Dockerfile) es la única fuente; aquí no se declara ningún valor
// propio. Cada clave se aplica sola y se compara antes de escribir para no
// reescribir en cada arranque lo que ya está aplicado; no protege un
// cambio manual del usuario en esa misma clave, que vuelve al valor
// declarado aquí en el próximo arranque del editor.
async function aplicarSettings() {
  let declarados;
  try {
    declarados = JSON.parse(fs.readFileSync(RUTA_SETTINGS, 'utf8'));
  } catch (error) {
    console.error('devkit: no se pudo leer settings.json', error);
    return;
  }
  const config = vscode.workspace.getConfiguration();
  for (const [clave, valor] of Object.entries(declarados)) {
    if (JSON.stringify(config.inspect(clave)?.globalValue) === JSON.stringify(valor)) continue;
    try {
      await config.update(clave, valor, vscode.ConfigurationTarget.Global);
    } catch (error) {
      console.error(`devkit: no se pudo aplicar ${clave}`, error);
    }
  }
}

function mostrarChuleta(viewColumn = vscode.ViewColumn.One, preserveFocus = false) {
  const panel = vscode.window.createWebviewPanel(
    VIEW_TYPE,
    TITULO,
    { viewColumn, preserveFocus },
    { enableScripts: false }
  );
  panel.webview.html = leerHtml();
  return panel;
}

function activate(context) {
  // Sin await: aplicar settings.json nunca debe ser requisito para que el
  // comando ni el serializer de abajo queden registrados. aplicarSettings ya
  // atrapa sus propios errores (lectura del archivo y cada config.update),
  // así que no hay excepción que perder aquí.
  aplicarSettings();

  context.subscriptions.push(
    vscode.commands.registerCommand('devkit.cheatsheet.show', () => mostrarChuleta())
  );

  // Sin este registro, restaurar una pestaña abierta a mano con este
  // viewType (el usuario corrió "devkit: comandos" y no la cerró antes de
  // recargar la ventana) falla con "No serializer found for
  // 'devkit.cheatsheet'".
  context.subscriptions.push(
    vscode.window.registerWebviewPanelSerializer(VIEW_TYPE, {
      deserializeWebviewPanel: async (panel) => {
        panel.webview.html = leerHtml();
      },
    })
  );
}

function deactivate() {}

module.exports = { activate, deactivate };
