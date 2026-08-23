-- Plugins propios, encima de lo que ya trae LazyVim. Ver README.md.
--
-- Este archivo debe EXISTIR aunque esté vacío: `{ import = "plugins" }` en
-- lua/config/lazy.lua falla con "No specs found for module plugins" si el
-- directorio no contiene ningún .lua. Un README no cuenta.
--
-- Empieza vacío a propósito: el template no impone preferencias de editor.
--
--   return {
--     { "tpope/vim-fugitive" },                                   -- añadir
--     { "folke/which-key.nvim", opts = { win = { border = "single" } } },
--     { "akinsho/bufferline.nvim", enabled = false },             -- quitar
--   }

return {}
