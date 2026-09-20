// devkit: abre la chuleta de comandos (cheatsheet.html, generado por
// gen-cheatsheet.sh) en un panel webview. Al arrancar, solo si no hay ningún
// editor abierto -así reemplaza la marca de agua de fábrica (Show All
// Commands, Go to File, Open Chat) sin pisar una sesión con archivos ya
// abiertos-. El comando "devkit: comandos" la reabre en cualquier momento;
// cerrarla no la vuelve a abrir sola hasta el próximo arranque del editor.
const vscode = require('vscode');
const fs = require('fs');
const path = require('path');

function leerHtml() {
  return fs.readFileSync(path.join(__dirname, 'cheatsheet.html'), 'utf8');
}

function mostrarChuleta() {
  const panel = vscode.window.createWebviewPanel(
    'devkit.cheatsheet',
    'devkit: comandos',
    vscode.ViewColumn.One,
    { enableScripts: false }
  );
  panel.webview.html = leerHtml();
  return panel;
}

function activate(context) {
  context.subscriptions.push(
    vscode.commands.registerCommand('devkit.cheatsheet.show', mostrarChuleta)
  );

  // Sin esto, recargar la ventana (la forma normal de volver en
  // openvscode-server) restaura la pestaña "devkit: comandos" y el workbench
  // falla con "No serializer found for 'devkit.cheatsheet'", dejándola en
  // blanco.
  context.subscriptions.push(
    vscode.window.registerWebviewPanelSerializer('devkit.cheatsheet', {
      deserializeWebviewPanel: async (panel) => {
        panel.webview.html = leerHtml();
      },
    })
  );

  const hayEditorAbierto = vscode.window.tabGroups.all.some((grupo) => grupo.tabs.length > 0);
  if (!hayEditorAbierto) {
    mostrarChuleta();
  }
}

function deactivate() {}

module.exports = { activate, deactivate };
