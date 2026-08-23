-- Arranque de lazy.nvim y de LazyVim.
--
-- lazy.nvim se autoinstala en la primera ejecución, dentro de
-- stdpath("data") = ~/.local/share/nvim, que es un VOLUMEN. Por eso el
-- rebuild del container no vuelve a descargar los plugins: se instalan una
-- vez y sobreviven. Ese volumen NO se respalda a rclone, y es correcto:
-- se reconstruye entero desde este repo con un `nvim --headless`.

local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not (vim.uv or vim.loop).fs_stat(lazypath) then
  local salida = vim.fn.system({
    "git",
    "clone",
    "--filter=blob:none",
    "https://github.com/folke/lazy.nvim.git",
    "--branch=stable",
    lazypath,
  })
  if vim.v.shell_error ~= 0 then
    -- Fallar con un mensaje claro. Sin esto, Neovim arranca "bien" y luego
    -- va soltando errores incomprensibles porque no hay gestor de plugins.
    vim.api.nvim_echo({
      { "No pude clonar lazy.nvim. ¿Hay red en el container?\n", "ErrorMsg" },
      { salida, "WarningMsg" },
    }, true, {})
    vim.fn.getchar()
    os.exit(1)
  end
end
vim.opt.rtp:prepend(lazypath)

require("lazy").setup({
  spec = {
    { "LazyVim/LazyVim", import = "lazyvim.plugins" },
    -- Los plugins propios van en lua/plugins/, de este mismo repo.
    { import = "plugins" },
  },
  defaults = { lazy = false, version = false },
  install = { colorscheme = { "tokyonight", "habamax" } },
  -- Sin comprobación automática de actualizaciones: en un container que se
  -- recrea a menudo, es tráfico y ruido en cada arranque. `:Lazy update`
  -- cuando quieras, y el lazy-lock.json versionado manda.
  checker = { enabled = false },
  change_detection = { notify = false },
  performance = {
    rtp = {
      disabled_plugins = { "gzip", "tarPlugin", "tohtml", "tutor", "zipPlugin" },
    },
  },
})
