// devkit (DEVKIT-229): en la terminal integrada de openvscode-server, un
// hipervínculo OSC 8 (DEVKIT-156) no se puede abrir -el navegador no sabe
// resolver el esquema openvscode-server://, ver la investigación de la card
// en Notion-. `devkit-run.sh` lo sabe (TERM_PROGRAM=vscode) e imprime "#N"
// en texto plano en vez del enlace; este TerminalLinkProvider lo intercepta
// y abre el PR en el webview de GitHub Pull Requests con `vscode.open`, que
// entra por _workbench.open sin openExternal y no dispara pestaña ni diálogo
// (a diferencia de env.openExternal/asExternalUri, ver Notas de la card).
const vscode = require('vscode');

const RE_CLAVE = /[A-Z]+-\d+/;
const RE_NUMERO_PR = /#(\d+)/g;
const RE_URL_PR = /https:\/\/github\.com\/([^/\s]+)\/([^/\s]+)\/pull\/(\d+)/g;

// git@github.com:owner/repo.git o https://github.com/owner/repo(.git) -las
// dos formas que puede traer un remoto `origin` real.
function ownerRepoDeRemoto(url) {
  if (!url) return null;
  const m = url.match(/github\.com[:/]([^/]+)\/([^/]+?)(?:\.git)?$/);
  return m ? { owner: m[1], repo: m[2] } : null;
}

// owner/repo del remoto `origin` del workspace, por la API de git de VS Code
// (extensión integrada `vscode.git`), no por `gh repo view`: esto corre en el
// editor, no en una shell con `gh` a mano.
function ownerRepoDelWorkspace() {
  const git = vscode.extensions.getExtension('vscode.git');
  const api = git && git.isActive ? git.exports.getAPI(1) : null;
  const repo = api && api.repositories[0];
  if (!repo) return null;
  const origin = repo.state.remotes.find((r) => r.name === 'origin');
  return ownerRepoDeRemoto(origin && (origin.fetchUrl || origin.pushUrl));
}

async function abrirPR(owner, repo, numero) {
  const uri = `${vscode.env.uriScheme}://GitHub.vscode-pull-request-github/open-pull-request-webview?uri=https://github.com/${owner}/${repo}/pull/${numero}`;
  await vscode.commands.executeCommand('vscode.open', vscode.Uri.parse(uri));
}

function activate(context) {
  context.subscriptions.push(
    vscode.window.registerTerminalLinkProvider({
      provideTerminalLinks(ctx) {
        const linea = ctx.line;
        const links = [];
        let m;

        RE_URL_PR.lastIndex = 0;
        while ((m = RE_URL_PR.exec(linea))) {
          links.push({
            startIndex: m.index,
            length: m[0].length,
            tooltip: 'devkit: abrir el PR en el IDE',
            owner: m[1],
            repo: m[2],
            numero: m[3],
          });
        }

        // "#N" solo cuenta como PR en una línea que también trae una Clave
        // ([A-Z]+-\d+, DEVKIT-12): sin esa condición, cualquier "#" de la
        // terminal (un comentario de shell, un hashtag) se confundiría con
        // un número de PR.
        if (RE_CLAVE.test(linea)) {
          RE_NUMERO_PR.lastIndex = 0;
          while ((m = RE_NUMERO_PR.exec(linea))) {
            links.push({
              startIndex: m.index,
              length: m[0].length,
              tooltip: 'devkit: abrir el PR en el IDE',
              numero: m[1],
            });
          }
        }

        return links;
      },
      handleTerminalLink(link) {
        let owner = link.owner;
        let repo = link.repo;
        if (!owner || !repo) {
          const remoto = ownerRepoDelWorkspace();
          if (!remoto) {
            vscode.window.showErrorMessage(
              'devkit: no encuentro el remoto origin del workspace para abrir el PR.'
            );
            return;
          }
          owner = remoto.owner;
          repo = remoto.repo;
        }
        return abrirPR(owner, repo, link.numero);
      },
    })
  );
}

function deactivate() {}

module.exports = { activate, deactivate };
