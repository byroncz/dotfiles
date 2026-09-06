-- Claude Code vía coder/claudecode.nvim: implementa el mismo protocolo que la
-- extensión oficial de VS Code. Claude descubre a Neovim por un archivo en
-- $CLAUDE_CONFIG_DIR/ide/.
local M = {}

function M.setup()
  require('claudecode').setup {
    terminal = {
      split_side = 'right',
      split_width_percentage = 0.40,
      provider = 'snacks',
    },
    diff_opts = { auto_close_on_accept = true, vertical_split = true },
  }
end

M.keymaps = {
  { 'n', '<leader>ac', '<cmd>ClaudeCode<cr>', 'Claude: abrir o cerrar' },
  { 'n', '<leader>af', '<cmd>ClaudeCodeFocus<cr>', 'Claude: enfocar' },
  { 'v', '<leader>as', '<cmd>ClaudeCodeSend<cr>', 'Claude: enviar selección' },
  { 'n', '<leader>as', '<cmd>ClaudeCodeAdd %<cr>', 'Claude: añadir el archivo actual' },
  { 'n', '<leader>aa', '<cmd>ClaudeCodeDiffAccept<cr>', 'Claude: aceptar diff' },
  { 'n', '<leader>ad', '<cmd>ClaudeCodeDiffDeny<cr>', 'Claude: rechazar diff' },
}

return M
