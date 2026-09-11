--[[
  Inventario: qué glifos fuera de ASCII pide la configuración de Neovim.

  Recorre la configuración ya fusionada de cada plugin —la del plugin más la
  nuestra encima— y lista cada cadena con al menos un carácter fuera de ASCII,
  con sus puntos de código. Es la contraparte de solo-ascii.lua: aquella prueba
  mira lo que se dibujó, esta mira lo que se pediría dibujar, incluidas las
  piezas que no se pueden capturar sin interfaz (el menú de which-key es modal)
  o que solo aparecen en casos puntuales (un archivo sin seguir en git).

  Falla, con código de salida 1, si aparece un glifo que no esté en la lista
  permitida: ASCII y el bloque de dibujo de cajas (U+2500–U+257F), que Menlo
  trae completo y del que salen los bordes y el árbol del explorador.

  Uso, desde la raíz del repo:
    nvim --headless -c 'luafile devkit/nvim/tests/inventario-glifos.lua'
--]]

local hallazgos = {}
local prohibidos = 0

local function codepoints(s)
  local cps = {}
  for _, c in ipairs(vim.fn.str2list(s)) do
    cps[#cps + 1] = string.format('U+%04X', c)
  end
  return table.concat(cps, ' ')
end

-- Dibujo de cajas: el único bloque fuera de ASCII que esta configuración usa a
-- propósito. Todo lo demás cuenta como hallazgo.
local function permitido(s)
  for _, c in ipairs(vim.fn.str2list(s)) do
    if c > 127 and not (c >= 0x2500 and c <= 0x257F) then return false end
  end
  return true
end

local vistos = {}
local function recorrer(prefijo, valor, profundidad)
  if profundidad > 10 then return end
  local t = type(valor)
  if t == 'string' then
    if valor:find '[\128-\255]' then
      local ok = permitido(valor)
      if not ok then prohibidos = prohibidos + 1 end
      hallazgos[#hallazgos + 1] = string.format(
        '%-8s %-58s %-12s %s',
        ok and '[cajas]' or '[FUERA]',
        prefijo,
        '"' .. valor .. '"',
        codepoints(valor)
      )
    end
  elseif t == 'table' then
    if vistos[valor] then return end
    vistos[valor] = true
    local claves = {}
    for k in pairs(valor) do claves[#claves + 1] = k end
    table.sort(claves, function(a, b) return tostring(a) < tostring(b) end)
    for _, k in ipairs(claves) do
      recorrer(prefijo .. '.' .. tostring(k), valor[k], profundidad + 1)
    end
  end
end

local function bloque(nombre, obtener)
  local ok, valor = pcall(obtener)
  if not ok then
    hallazgos[#hallazgos + 1] = string.format('%-8s %-58s %s', '[ERROR]', nombre, tostring(valor))
    prohibidos = prohibidos + 1
    return
  end
  local antes = #hallazgos
  recorrer(nombre, valor, 0)
  if #hallazgos == antes then
    hallazgos[#hallazgos + 1] = string.format('%-8s %-58s', '[ok]', nombre)
  end
end

bloque('snacks.picker', function() return require('snacks.picker.config').get() end)
bloque('which-key', function() return require('which-key.config').options end)
-- blink.cmp expone su configuración por __index, así que pairs() no la
-- recorre: hay que nombrar cada sección.
bloque('blink.cmp', function()
  local cfg = require 'blink.cmp.config'
  local copia = {}
  for _, k in ipairs { 'keymap', 'completion', 'fuzzy', 'sources', 'signature', 'snippets', 'appearance', 'cmdline', 'term' } do
    copia[k] = cfg[k]
  end
  return copia
end)
bloque('fidget', function() return require('fidget').options end)
bloque('telescope', function() return require('telescope.config').values end)
bloque('gitsigns.signs', function() return require('gitsigns.config').config.signs end)
bloque('vim.diagnostic', function() return vim.diagnostic.config() end)
bloque('listchars', function() return vim.opt.listchars:get() end)
bloque('fillchars', function() return vim.opt.fillchars:get() end)

print(table.concat(hallazgos, '\n'))
if prohibidos > 0 then
  print(string.format('\nFALLA: %d glifo(s) fuera de ASCII y del dibujo de cajas.', prohibidos))
  vim.cmd 'cquit'
end
print '\nOK: solo ASCII y dibujo de cajas.'
vim.cmd 'qa!'
