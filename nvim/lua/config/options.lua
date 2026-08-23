-- LazyVim carga este archivo automáticamente, después de sus propias
-- opciones. Aquí solo lo que cambia respecto a los valores de LazyVim.

local opt = vim.opt

-- El portapapeles del sistema desde dentro de un container no funciona por
-- la vía normal: no hay servidor X ni pbcopy. La salida es OSC 52, un
-- código de escape que la propia terminal interpreta y copia al
-- portapapeles del Mac. Requiere una terminal que lo soporte: Kitty,
-- WezTerm, Ghostty o Alacritty (ver CONFIGURACION-MANUAL.md).
opt.clipboard = "unnamedplus"
vim.g.clipboard = {
  name = "OSC 52",
  copy = {
    ["+"] = require("vim.ui.clipboard.osc52").copy("+"),
    ["*"] = require("vim.ui.clipboard.osc52").copy("*"),
  },
  paste = {
    -- Pegar por OSC 52 requiere que la terminal lo permita, y muchas lo
    -- desactivan por seguridad. Se usa el registro interno de Neovim, que
    -- funciona siempre dentro de la sesión.
    ["+"] = function()
      return vim.split(vim.fn.getreg('"'), "\n")
    end,
    ["*"] = function()
      return vim.split(vim.fn.getreg('"'), "\n")
    end,
  },
}

-- Números relativos: hace que 8k, 3j y demás sean inmediatos.
opt.relativenumber = true

-- El código de cliente no siempre respeta tus preferencias de formato; que
-- se vea lo que hay, no lo que te gustaría.
opt.list = true
