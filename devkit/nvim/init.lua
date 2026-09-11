--[[
  devkit: configuración base de Neovim.

  Derivada de kickstart.nvim (versión con vim.pack, Neovim 0.12), reducida:
    - Sin Mason. ruff y basedpyright vienen instalados en la imagen.
    - Sin treesitter por ahora: exige un compilador de C en la imagen.
    - Los plugins se instalan en la imagen; nvim-pack-lock.json fija versiones.
    - Ratón activo. El portapapeles del Mac se maneja desde Terminal.app
      (ver docs/ARCHITECTURE.md, sección 4.4).
    - Los agentes (Claude hoy, Codex después) viven en lua/devkit/agents.
    - Interfaz en ASCII: no se pide ningún glifo de Nerd Font. Ver la sección
      "Solo ASCII en la interfaz" y las pruebas en tests/.

  Atajos: <espacio> es la tecla líder. Pulsa <espacio> y espera: which-key
  muestra lo disponible.
--]]

vim.loader.enable()

vim.g.mapleader = ' '
vim.g.maplocalleader = ' '

-- Terminal.app pinta con Menlo, que no trae glifos de Nerd Font: pedir uno
-- dibuja un cuadro. Por eso todo va en ASCII. Ver docs/ARCHITECTURE.md 4.4.
vim.g.have_nerd_font = false

-- ---------------------------------------------------------------------------
-- Solo ASCII en la interfaz
--
-- El contenedor no dibuja: emite texto y Terminal.app lo pinta con la fuente
-- del Mac. Instalar una fuente aquí dentro no cambia nada, así que la única
-- salida es no pedir glifos que Menlo no tenga. `have_nerd_font = false` no
-- alcanza: cada plugin trae sus propios iconos por defecto y los usa igual.
--
-- Sí se permiten los caracteres de dibujo de cajas (U+2500–U+257F): Menlo los
-- trae completos y son los que dan los bordes y el árbol del explorador. Todo
-- lo demás —iconos de Nerd Font (área privada U+E000+ y U+F0000+), braille,
-- figuras geométricas, dingbats— se reemplaza por texto.
--
-- Las tablas de abajo se usan más adelante, en la configuración de cada
-- plugin. Se definen aquí juntas para que se lea de un vistazo qué se cambió.
-- ---------------------------------------------------------------------------

-- which-key fusiona en profundidad (`vim.tbl_deep_extend`), así que pasarle
-- `keys = {}` no borra nada: sus iconos por defecto sobreviven. Hay que dar un
-- texto por cada tecla que trae.
local teclas_ascii = {
  Up = 'Up ',
  Down = 'Down ',
  Left = 'Left ',
  Right = 'Right ',
  C = 'C-',
  M = 'M-',
  D = 'D-',
  S = 'S-',
  CR = 'CR ',
  NL = 'NL ',
  Esc = 'Esc ',
  BS = 'BS ',
  Space = 'Space ',
  Tab = 'Tab ',
  ScrollWheelDown = 'WheelDown ',
  ScrollWheelUp = 'WheelUp ',
}
for n = 1, 12 do
  teclas_ascii['F' .. n] = 'F' .. n .. ' '
end

-- Tipos del LSP (funciones, clases, variables...) con el nombre en texto en vez
-- de un icono. Se generan desde las listas del protocolo para no dejarse
-- ninguno: lo que no se sobrescriba conserva el glifo por defecto.
local tipos_ascii = {
  Control = 'control ',
  Collapsed = 'plegado ',
  Copilot = 'copilot ',
  Unknown = 'otro ',
}
for _, tabla in ipairs { vim.lsp.protocol.CompletionItemKind, vim.lsp.protocol.SymbolKind } do
  for nombre in pairs(tabla) do
    if type(nombre) == 'string' then tipos_ascii[nombre] = nombre:lower() .. ' ' end
  end
end

-- ---------------------------------------------------------------------------
-- Opciones (kickstart)
-- ---------------------------------------------------------------------------
vim.o.number = true
vim.o.mouse = 'a'
vim.o.showmode = false
vim.o.breakindent = true
vim.o.undofile = true
vim.o.ignorecase = true
vim.o.smartcase = true
vim.o.signcolumn = 'yes'
vim.o.timeoutlen = 300
vim.o.splitright = true
vim.o.splitbelow = true
vim.o.list = true
-- kickstart marca el espacio duro con '␣' (U+2423, bloque Control Pictures),
-- que Menlo no trae: sale un cuadro dentro del texto del archivo.
vim.opt.listchars = { tab = '> ', trail = '-', nbsp = '+' }
vim.o.inccommand = 'split'
vim.o.cursorline = true
vim.o.scrolloff = 10
vim.o.confirm = true
vim.o.termguicolors = true
vim.o.expandtab = true
vim.o.shiftwidth = 4
vim.o.tabstop = 4

-- Sin proveedor de portapapeles en el contenedor: los registros son internos.
-- No se fija 'unnamedplus' para evitar el error "clipboard: No provider".

vim.keymap.set('n', '<Esc>', '<cmd>nohlsearch<CR>')
vim.keymap.set('t', '<Esc><Esc>', '<C-\\><C-n>', { desc = 'Salir del modo terminal' })
vim.keymap.set('n', '<C-h>', '<C-w><C-h>', { desc = 'Ventana izquierda' })
vim.keymap.set('n', '<C-l>', '<C-w><C-l>', { desc = 'Ventana derecha' })
vim.keymap.set('n', '<C-j>', '<C-w><C-j>', { desc = 'Ventana inferior' })
vim.keymap.set('n', '<C-k>', '<C-w><C-k>', { desc = 'Ventana superior' })

-- El borde 'rounded' usa dibujo de cajas, que Menlo sí trae. Los dos valores
-- que hay que fijar son el prefijo del texto virtual, que por defecto es '■'
-- (U+25A0), y las letras del margen, que si no salen de la inicial de cada
-- severidad: se escriben aquí para que no dependan de un default de Neovim.
vim.diagnostic.config {
  update_in_insert = false,
  severity_sort = true,
  float = { border = 'rounded', source = 'if_many' },
  signs = {
    text = {
      [vim.diagnostic.severity.ERROR] = 'E',
      [vim.diagnostic.severity.WARN] = 'W',
      [vim.diagnostic.severity.INFO] = 'I',
      [vim.diagnostic.severity.HINT] = 'H',
    },
  },
  virtual_text = { prefix = '*', spacing = 2, source = 'if_many' },
}

vim.api.nvim_create_autocmd('TextYankPost', {
  desc = 'Resaltar lo copiado',
  group = vim.api.nvim_create_augroup('devkit-yank', { clear = true }),
  callback = function() vim.hl.on_yank() end,
})

-- ---------------------------------------------------------------------------
-- Recarga de archivos que cambian en disco
--
-- Un agente edita los archivos directo en disco mientras siguen abiertos en un
-- buffer. 'autoread' ya viene activo, pero Neovim solo compara la marca de
-- tiempo del archivo cuando algo dispara la comprobación, y dentro de tmux en
-- Terminal.app casi ningún evento de foco llega: el buffer se queda mostrando
-- la versión vieja mientras el agente trabaja.
--
-- 'updatetime' sube de los 250 ms de kickstart a 1000 ms porque aquí ya no es
-- solo el retardo de gitsigns y del resaltado del LSP: es también cada cuánto
-- se consulta el disco. Un segundo se percibe igual de inmediato y evita
-- cuatro comprobaciones por segundo en un contenedor con el volumen montado
-- desde el Mac, donde un stat() cuesta bastante más que en disco local.
--
-- CursorHold dispara una sola vez tras cada pulsación, no cada 'updatetime'.
-- Por sí solo deja fuera el caso más común: el humano mirando el panel sin
-- tocar el teclado. El timer repite la comprobación en ese silencio.
-- ---------------------------------------------------------------------------
vim.o.autoread = true
vim.o.updatetime = 1000

-- checktime falla en la línea de comandos: ese es el único caso que se salta.
-- No se filtra por 'buftype'. `checktime` sin argumentos revisa todos los
-- buffers, así que mirar el terminal de Claude o el panel de un plugin no
-- impide releer el archivo abierto al lado, que es justo lo que hace falta
-- mientras el agente escribe. Los buffers sin archivo detrás no tienen nada
-- que releer y resolverlos no cuesta nada.
local function comprobar_cambios_en_disco()
  if vim.fn.mode() == 'c' then return end
  vim.cmd 'checktime'
end

vim.api.nvim_create_autocmd({ 'CursorHold', 'CursorHoldI', 'FocusGained', 'BufEnter', 'TermLeave' }, {
  desc = 'Releer el archivo si cambió en disco',
  group = vim.api.nvim_create_augroup('devkit-checktime', { clear = true }),
  callback = comprobar_cambios_en_disco,
})

local temporizador_checktime = vim.uv.new_timer()
temporizador_checktime:start(
  vim.o.updatetime,
  vim.o.updatetime,
  function() vim.schedule(comprobar_cambios_en_disco) end
)

vim.api.nvim_create_autocmd('VimLeavePre', {
  desc = 'Detener el timer de checktime al salir',
  group = vim.api.nvim_create_augroup('devkit-checktime-cierre', { clear = true }),
  callback = function()
    if not temporizador_checktime:is_closing() then temporizador_checktime:close() end
  end,
})

-- ---------------------------------------------------------------------------
-- Plugins (vim.pack, integrado en Neovim 0.12)
-- ---------------------------------------------------------------------------
local function gh(repo) return 'https://github.com/' .. repo end

vim.pack.add {
  gh 'folke/tokyonight.nvim',
  gh 'folke/which-key.nvim',
  gh 'lewis6991/gitsigns.nvim',
  gh 'nvim-lua/plenary.nvim',
  gh 'nvim-telescope/telescope.nvim',
  gh 'nvim-telescope/telescope-ui-select.nvim',
  gh 'neovim/nvim-lspconfig',
  { src = gh 'saghen/blink.cmp', version = vim.version.range '1.*' },
  gh 'stevearc/conform.nvim',
  gh 'j-hui/fidget.nvim',
  gh 'folke/snacks.nvim',
  gh 'coder/claudecode.nvim',
}

vim.cmd.colorscheme 'tokyonight-night'

require('which-key').setup {
  delay = 0,
  icons = {
    mappings = false,
    breadcrumb = '>', -- por defecto '»'
    separator = '->', -- por defecto '➜' (U+279C), fuera de Menlo
    ellipsis = '...', -- por defecto '…'
    keys = teclas_ascii,
  },
  spec = {
    { '<leader>s', group = '[S]earch' },
    { '<leader>t', group = '[T]oggle' },
    { '<leader>h', group = 'Git [H]unk', mode = { 'n', 'v' } },
    { '<leader>a', group = '[A]gente', mode = { 'n', 'v' } },
  },
}

-- ---------------------------------------------------------------------------
-- Explorador de archivos: snacks.explorer, con <espacio>e
--
-- snacks.nvim ya venía instalado porque claudecode.nvim lo usa de proveedor de
-- terminal, así que el explorador no añade ningún plugin y nvim-pack-lock.json
-- no cambia. Es "un picker disfrazado": por eso se configura bajo
-- picker.sources.explorer y no bajo explorer.
--
-- De serie ya trae lo que hace falta trabajando con un agente. `watch = true`
-- levanta un vim.uv.fs_event por cada directorio abierto y otro sobre .git, así
-- que crear, borrar o renombrar archivos desde fuera del editor refresca el
-- árbol solo, y `git_status = true` repinta la marca del archivo en cuanto
-- cambia el índice. Lo que sigue es solo lo que se aparta del valor por defecto.
--
-- `.git` no se lista por defecto (los ocultos están apagados), pero `H` los
-- enciende y ahí sí aparecería: `exclude` lo deja fuera en los dos casos.
--
-- Un clic abre el archivo bajo el ratón; sobre un directorio solo mueve el
-- cursor. Expandir y plegar queda en el doble clic a propósito: si un clic
-- alternara el directorio, el segundo clic de un doble clic lo volvería a
-- cerrar. La lista sincroniza su elemento actual en CursorMoved, que no ha
-- corrido todavía cuando se procesa el mapeo, así que hay que resolver la fila
-- del ratón a mano, igual que hace snacks en su propio manejador.
local function abrir_con_clic(picker)
  local lista = picker.list
  local raton = vim.fn.getmousepos()
  if raton.winid ~= lista.win.win or raton.line < 1 then return end
  local primera = vim.api.nvim_win_call(raton.winid, function() return vim.fn.line 'w0' end)
  local indice = lista:row2idx(raton.line - primera + 1)
  local elemento = lista:get(indice)
  if not elemento then return end
  lista:move(indice, true)
  if not elemento.dir then picker:action 'confirm' end
end

-- Los iconos del explorador salen de snacks.picker, no de snacks.explorer: el
-- explorador es un picker. Sin mini.icons ni nvim-web-devicons instalados,
-- `Snacks.util.icon` cae en estos valores, que de fábrica son Nerd Font.
-- `files.enabled = false` quitaría también la marca de carpeta, así que se deja
-- encendido con un hueco para los archivos y '-' / '+' para las carpetas.
-- El árbol (`icons.tree`) se queda con su dibujo de cajas: Menlo lo trae.
require('snacks').setup {
  explorer = { replace_netrw = true },
  picker = {
    prompt = '> ',
    icons = {
      files = { enabled = true, file = '  ', dir = '- ', dir_open = '+ ' },
      keymaps = { nowait = '! ' },
      undo = { saved = '* ' },
      ui = {
        live = 'vivo ',
        hidden = 'h',
        ignored = 'i',
        follow = 'f',
        selected = '* ',
        unselected = '  ',
      },
      git = {
        enabled = true,
        commit = 'c ',
        staged = 'S',
        added = 'A',
        deleted = 'D',
        ignored = 'I',
        modified = 'M',
        renamed = 'R',
        unmerged = 'U',
        untracked = '?',
      },
      diagnostics = { Error = 'E ', Warn = 'W ', Hint = 'H ', Info = 'I ' },
      lsp = { unavailable = '', enabled = 'on ', disabled = 'off ', attached = 'lsp ' },
      kinds = tipos_ascii,
    },
    sources = {
      -- Los pickers de GitHub traen el logo de GitHub (U+E709) en el título.
      -- Esta configuración no les pone atajo, pero se limpian igual por si
      -- alguien llama a Snacks.picker.gh_pr() a mano.
      gh_actions = { title = 'Actions' },
      gh_diff = { title = 'Pull Request Diff' },
      gh_issue = { title = 'Issues' },
      gh_labels = { title = 'Labels' },
      gh_pr = { title = 'Pull Requests' },
      gh_reactions = { title = 'Reactions' },
      explorer = {
        exclude = { '.git' },
        actions = { devkit_abrir_con_clic = abrir_con_clic },
        win = { list = { keys = { ['<LeftMouse>'] = 'devkit_abrir_con_clic' } } },
      },
    },
  },
}

vim.keymap.set('n', '<leader>e', function() Snacks.explorer() end, { desc = '[E]xplorador de archivos' })

-- 'topdelete' venía con '‾' (U+203E). El resto ya era ASCII; la marca de
-- archivo sin seguir usa dibujo de cajas, que se queda como está.
require('gitsigns').setup {
  signs = { add = { text = '+' }, change = { text = '~' }, delete = { text = '_' }, topdelete = { text = '-' }, changedelete = { text = '~' } },
  on_attach = function(bufnr)
    local gs = require 'gitsigns'
    local map = function(mode, l, r, desc) vim.keymap.set(mode, l, r, { buffer = bufnr, desc = desc }) end
    map('n', ']c', function() gs.nav_hunk 'next' end, 'Siguiente cambio')
    map('n', '[c', function() gs.nav_hunk 'prev' end, 'Cambio anterior')
    map('n', '<leader>hp', gs.preview_hunk, 'Previsualizar cambio')
    map('n', '<leader>hb', function() gs.blame_line { full = true } end, 'Blame de la línea')
    map('n', '<leader>hd', gs.diffthis, 'Diff contra el índice')
  end,
}

-- Telescope: buscar archivos, texto y símbolos.
require('telescope').setup {
  extensions = { ['ui-select'] = { require('telescope.themes').get_dropdown() } },
}
pcall(require('telescope').load_extension, 'ui-select')
local builtin = require 'telescope.builtin'
vim.keymap.set('n', '<leader>sf', builtin.find_files, { desc = '[S]earch [F]iles' })
vim.keymap.set('n', '<leader>sg', builtin.live_grep, { desc = '[S]earch by [G]rep' })
vim.keymap.set('n', '<leader>sh', builtin.help_tags, { desc = '[S]earch [H]elp' })
vim.keymap.set('n', '<leader>sk', builtin.keymaps, { desc = '[S]earch [K]eymaps' })
vim.keymap.set('n', '<leader>sd', builtin.diagnostics, { desc = '[S]earch [D]iagnostics' })
vim.keymap.set('n', '<leader>sr', builtin.resume, { desc = '[S]earch [R]esume' })
vim.keymap.set('n', '<leader><leader>', builtin.buffers, { desc = 'Buffers abiertos' })
vim.keymap.set('n', '<leader>/', builtin.current_buffer_fuzzy_find, { desc = 'Buscar en el buffer' })

-- ---------------------------------------------------------------------------
-- LSP: basedpyright (tipos) y ruff (lint). Ambos en PATH, sin Mason.
-- ---------------------------------------------------------------------------
-- fidget gira un spinner mientras el LSP trabaja. El patrón por defecto,
-- 'dots', son caracteres braille (U+28xx) y el icono de terminado un '✔':
-- ninguno de los dos está en Menlo. 'line' es el mismo spinner en '-\|/'.
require('fidget').setup {
  progress = {
    display = { progress_icon = { pattern = 'line', period = 1 }, done_icon = 'ok' },
  },
  notification = {
    configs = {
      default = vim.tbl_extend('force', require('fidget.notification').default_config, { icon = '>>' }),
    },
  },
}

vim.api.nvim_create_autocmd('LspAttach', {
  group = vim.api.nvim_create_augroup('devkit-lsp-attach', { clear = true }),
  callback = function(event)
    local map = function(keys, func, desc, mode)
      vim.keymap.set(mode or 'n', keys, func, { buffer = event.buf, desc = 'LSP: ' .. desc })
    end
    map('grn', vim.lsp.buf.rename, '[R]e[n]ame')
    map('gra', vim.lsp.buf.code_action, 'Code [A]ction', { 'n', 'x' })
    map('grd', builtin.lsp_definitions, '[D]efinition')
    map('grr', builtin.lsp_references, '[R]eferences')
    map('gO', builtin.lsp_document_symbols, 'Símbolos del documento')
    local client = vim.lsp.get_client_by_id(event.data.client_id)
    if client and client:supports_method('textDocument/inlayHint', event.buf) then
      map('<leader>th', function()
        vim.lsp.inlay_hint.enable(not vim.lsp.inlay_hint.is_enabled { bufnr = event.buf })
      end, '[T]oggle inlay [H]ints')
    end
  end,
})

vim.lsp.config('basedpyright', {
  settings = { basedpyright = { analysis = { typeCheckingMode = 'standard' } } },
})
vim.lsp.config('ruff', {
  on_attach = function(client) client.server_capabilities.hoverProvider = false end,
})
vim.lsp.enable { 'basedpyright', 'ruff' }

-- Formato al guardar con ruff.
require('conform').setup {
  notify_on_error = false,
  format_on_save = { timeout_ms = 1000, lsp_format = 'fallback' },
  formatters_by_ft = { python = { 'ruff_organize_imports', 'ruff_format' }, lua = {} },
}
vim.keymap.set('n', '<leader>f', function() require('conform').format { async = true } end, { desc = '[F]ormatear buffer' })

-- Autocompletado. Implementación de búsqueda en Lua: sin binarios externos.
--
-- La primera columna del menú es 'kind_icon' de fábrica: un glifo de Nerd Font
-- por tipo. Se cambia por 'kind', que es el mismo dato en texto ('Function',
-- 'Variable'...), y se manda al final para que el nombre quede a la izquierda.
-- 'kind_icons' se sobrescribe igual: la columna ya no se dibuja, pero así no
-- quedan glifos esperando a que alguien la vuelva a encender.
require('blink.cmp').setup {
  keymap = { preset = 'default' },
  fuzzy = { implementation = 'lua' },
  sources = { default = { 'lsp', 'path', 'buffer' } },
  appearance = { kind_icons = tipos_ascii },
  completion = {
    documentation = { auto_show = true, auto_show_delay_ms = 300 },
    menu = { draw = { columns = { { 'label', 'label_description', gap = 1 }, { 'kind' } } } },
  },
}

-- ---------------------------------------------------------------------------
-- Agentes. Cada uno es un módulo en lua/devkit/agents/<nombre>.lua.
-- ---------------------------------------------------------------------------
require('devkit.agents').setup { 'claude' }
