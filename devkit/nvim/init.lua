--[[
  devkit: configuración base de Neovim.

  Derivada de kickstart.nvim (versión con vim.pack, Neovim 0.12), reducida:
    - Sin Mason. ruff y basedpyright vienen instalados en la imagen.
    - Sin treesitter por ahora: exige un compilador de C en la imagen.
    - Los plugins se instalan en la imagen; nvim-pack-lock.json fija versiones.
    - Ratón activo. El portapapeles del Mac se maneja desde Terminal.app
      (ver docs/ARCHITECTURE.md, sección 4.4).
    - Los agentes (Claude hoy, Codex después) viven en lua/devkit/agents.

  Atajos: <espacio> es la tecla líder. Pulsa <espacio> y espera: which-key
  muestra lo disponible.
--]]

vim.loader.enable()

vim.g.mapleader = ' '
vim.g.maplocalleader = ' '
vim.g.have_nerd_font = false

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
vim.o.updatetime = 250
vim.o.timeoutlen = 300
vim.o.splitright = true
vim.o.splitbelow = true
vim.o.list = true
vim.opt.listchars = { tab = '» ', trail = '·', nbsp = '␣' }
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

vim.diagnostic.config {
  update_in_insert = false,
  severity_sort = true,
  float = { border = 'rounded', source = 'if_many' },
  virtual_text = true,
}

vim.api.nvim_create_autocmd('TextYankPost', {
  desc = 'Resaltar lo copiado',
  group = vim.api.nvim_create_augroup('devkit-yank', { clear = true }),
  callback = function() vim.hl.on_yank() end,
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
  icons = { mappings = false, keys = {} },
  spec = {
    { '<leader>s', group = '[S]earch' },
    { '<leader>t', group = '[T]oggle' },
    { '<leader>h', group = 'Git [H]unk', mode = { 'n', 'v' } },
    { '<leader>a', group = '[A]gente', mode = { 'n', 'v' } },
  },
}

require('gitsigns').setup {
  signs = { add = { text = '+' }, change = { text = '~' }, delete = { text = '_' }, topdelete = { text = '‾' }, changedelete = { text = '~' } },
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
require('fidget').setup {}

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
require('blink.cmp').setup {
  keymap = { preset = 'default' },
  fuzzy = { implementation = 'lua' },
  sources = { default = { 'lsp', 'path', 'buffer' } },
  completion = { documentation = { auto_show = true, auto_show_delay_ms = 300 } },
}

-- ---------------------------------------------------------------------------
-- Agentes. Cada uno es un módulo en lua/devkit/agents/<nombre>.lua.
-- ---------------------------------------------------------------------------
require('devkit.agents').setup { 'claude' }
