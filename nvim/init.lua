-- Punto de entrada de Neovim.
--
-- Este archivo NO vive en ~/.config/nvim: vive en el repo de dotfiles, y
-- post-create.sh enlaza ~/.config/nvim aquí. Así la configuración se edita
-- como código versionado y no como un directorio suelto dentro de un volumen.

-- Antes de cargar nada: los plugins leen esto al configurar sus iconos, así
-- que llegar tarde significa iconos rotos a medias.
--
-- Los iconos de LazyVim son de Nerd Font. Si la terminal no la tiene
-- instalada se ven cuadraditos, y el template puede acabar en máquinas
-- ajenas, así que por defecto va apagado (decisión ASCII-safe, Problema 10).
-- Se enciende con NERD_FONT=true en .devcontainer/.env.
vim.g.have_nerd_font = os.getenv("NERD_FONT") == "true"

require("config.lazy")
