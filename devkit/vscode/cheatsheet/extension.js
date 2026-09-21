// devkit: abre la chuleta de comandos (cheatsheet.html, generado por
// gen-cheatsheet.sh) en un panel webview. Al arrancar, solo si ninguna
// pestaña abierta es un archivo -así reemplaza la marca de agua de fábrica
// (Show All Commands, Go to File, Open Chat) sin pisar una sesión con
// archivos ya abiertos, y Welcome o el walkthrough no cuentan como sesión
// en curso-. Si al recargar la ventana la pestaña "devkit: comandos"
// vuelve en blanco, se cierra y se reabre con el html, haya o no archivos
// abiertos. El comando "devkit: comandos" la reabre en cualquier momento;
// cerrarla no la vuelve a abrir sola hasta el próximo arranque del editor.
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
// pisar un cambio que el usuario haya hecho a mano en el mismo valor.
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

function esPestañaDeArchivo(tab) {
  return tab.input instanceof vscode.TabInputText
    || tab.input instanceof vscode.TabInputTextDiff
    || tab.input instanceof vscode.TabInputNotebook;
}

// Vuelve a traer al frente una pestaña de archivo. Cada tipo de entrada se
// reabre distinto: TabInputTextDiff no tiene uri -expone original y
// modified- y un notebook abierto con showTextDocument volvería como JSON
// crudo en una pestaña nueva. Un fallo aquí no debe tumbar activate(): la
// chuleta ya quedó reparada y lo único que se pierde es el orden de las
// pestañas, así que se traga el error en vez de rechazar la promesa.
async function revelarPestaña(tab, viewColumn) {
  const opciones = { viewColumn, preserveFocus: false, preview: false };
  try {
    if (tab.input instanceof vscode.TabInputText) {
      await vscode.window.showTextDocument(tab.input.uri, opciones);
    } else if (tab.input instanceof vscode.TabInputTextDiff) {
      await vscode.commands.executeCommand(
        'vscode.diff',
        tab.input.original,
        tab.input.modified,
        tab.label,
        opciones
      );
    } else if (tab.input instanceof vscode.TabInputNotebook) {
      const documento = await vscode.workspace.openNotebookDocument(tab.input.uri);
      await vscode.window.showNotebookDocument(documento, { viewColumn, preserveFocus: false });
    }
  } catch (error) {
    console.error(`devkit: no se pudo revelar ${tab.label}`, error);
  }
}

function esPestañaDeChuleta(tab) {
  return tab.input instanceof vscode.TabInputWebview
    && tab.input.viewType.endsWith(VIEW_TYPE);
}

async function activate(context) {
  await aplicarSettings();

  context.subscriptions.push(
    vscode.commands.registerCommand('devkit.cheatsheet.show', () => mostrarChuleta())
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
  // activo en ese grupo, se vuelve a revelar después para no taparlo. La
  // búsqueda del archivo se acota al grupo de la chuleta: isActive es por
  // grupo, y con el editor partido el primer archivo activo de
  // tabGroups.all suele estar en otro grupo, ya visible, donde revelarlo
  // roba el foco y deja tapado el archivo que la chuleta sí tapó.
  const restauradas = pestañas.filter(esPestañaDeChuleta);
  if (restauradas.length > 0) {
    const grupo = restauradas[0].group;
    const columna = grupo.viewColumn;
    const activa = grupo.tabs.find((t) => t.isActive && esPestañaDeArchivo(t));
    await vscode.window.tabGroups.close(restauradas);
    mostrarChuleta(columna, true);
    if (activa) {
      await revelarPestaña(activa, columna);
    }
    return;
  }

  if (hayArchivo) return;

  mostrarChuleta();
}

function deactivate() {}

module.exports = { activate, deactivate };
