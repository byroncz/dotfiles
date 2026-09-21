// devkit: abre la chuleta de comandos (cheatsheet.html, generado por
// gen-cheatsheet.sh) en un panel webview. Al arrancar, solo si ninguna
// pestaña abierta es un archivo -así reemplaza la marca de agua de fábrica
// (Show All Commands, Go to File, Open Chat) sin pisar una sesión con
// archivos ya abiertos, y Welcome o el walkthrough no cuentan como sesión
// en curso-. El comando "devkit: comandos" la reabre en cualquier momento;
// cerrarla no la vuelve a abrir sola hasta el próximo arranque del editor.
const vscode = require('vscode');
const fs = require('fs');
const path = require('path');

const VIEW_TYPE = 'devkit.cheatsheet';
const TITULO = 'devkit: comandos';

function leerHtml() {
  return fs.readFileSync(path.join(__dirname, 'cheatsheet.html'), 'utf8');
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

function esPestañaDeArchivo(tab) {
  return tab.input instanceof vscode.TabInputText
    || tab.input instanceof vscode.TabInputTextDiff
    || tab.input instanceof vscode.TabInputNotebook;
}

function esPestañaDeChuleta(tab) {
  return tab.input instanceof vscode.TabInputWebview
    && tab.input.viewType.endsWith(VIEW_TYPE);
}

async function activate(context) {
  context.subscriptions.push(
    vscode.commands.registerCommand('devkit.cheatsheet.show', mostrarChuleta)
  );

  // Sin este registro, restaurar una pestaña con este viewType falla con
  // "No serializer found for 'devkit.cheatsheet'". La reparación de abajo
  // cierra y reabre la pestaña restaurada apenas termina activate(), así
  // que pisa cualquier restauración que este serializer llegue a hacer: se
  // mantiene solo para evitar ese error, no para cubrir otros clientes.
  context.subscriptions.push(
    vscode.window.registerWebviewPanelSerializer(VIEW_TYPE, {
      deserializeWebviewPanel: async (panel) => {
        panel.webview.html = leerHtml();
      },
    })
  );

  const pestañas = vscode.window.tabGroups.all.flatMap((grupo) => grupo.tabs);
  const hayArchivo = pestañas.some(esPestañaDeArchivo);

  // openvscode-server no invoca el serializer de arriba al recargar la
  // ventana: la pestaña "devkit: comandos" vuelve en la lista de pestañas
  // pero sin contenido. Se repara siempre, haya o no un archivo abierto -si
  // no se repara cuando hay un archivo abierto, un reload normal (chuleta
  // abierta, se abre un archivo, Reload Window) la deja en blanco para
  // siempre-. Se cierran todas las coincidencias (pudo quedar restaurada en
  // más de un grupo) y se reabre en la misma columna; si había un archivo
  // activo en ese grupo, se vuelve a revelar después para no taparlo.
  const restauradas = pestañas.filter(esPestañaDeChuleta);
  if (restauradas.length > 0) {
    const columna = restauradas[0].group.viewColumn;
    const activa = pestañas.find((t) => t.isActive && esPestañaDeArchivo(t));
    await vscode.window.tabGroups.close(restauradas);
    mostrarChuleta(columna, true);
    if (activa) {
      await vscode.window.showTextDocument(activa.input.uri, {
        viewColumn: activa.group.viewColumn,
        preserveFocus: false,
        preview: false,
      });
    }
    return;
  }

  if (hayArchivo) return;

  mostrarChuleta();
}

function deactivate() {}

module.exports = { activate, deactivate };
