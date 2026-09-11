--[[
  Prueba: lo que Neovim manda a la terminal no lleva glifos fuera de ASCII.

  Abre el explorador de archivos sobre el directorio actual y, aparte, un
  buffer con diagnósticos y el menú de autocompletado abierto. De cada uno
  vuelca la pantalla —lo que el contenedor le manda a Terminal.app— a un
  archivo, para correrle encima el grep que busca lo que Menlo no tiene.

  Se vuelca la pantalla y no el buffer a propósito: snacks dibuja los iconos de
  archivo como texto virtual (extmarks), así que no están en el texto del
  buffer. La pantalla es la única copia fiel de lo que el humano ve.

  El menú de <espacio> (which-key) no entra aquí: es modal, se queda leyendo
  teclas, y sin interfaz conectada Neovim no repinta mientras espera. Sus
  iconos los cubre inventario-glifos.lua, que los lee de la configuración ya
  fusionada.

  Los diagnósticos se publican a mano con vim.diagnostic.set en vez de esperar
  a basedpyright: lo que se prueba es cómo se dibujan el signo del margen y el
  prefijo del texto virtual, y eso no depende de quién los haya reportado.

  Uso, desde la raíz del repo:
    SALIDA=/tmp/pantalla.txt nvim --headless -c 'luafile devkit/nvim/tests/solo-ascii.lua'
    grep -P '[^\x00-\x7F─-╿‘-”…→←▶▼]' /tmp/pantalla.txt

  El grep no debe encontrar nada. Lo que deja pasar es ASCII más lo que Menlo
  sí trae y esta configuración usa a propósito: dibujo de cajas para bordes y
  árbol, comillas tipográficas, puntos suspensivos y flechas.
--]]

local salida = os.getenv 'SALIDA' or '/tmp/devkit-solo-ascii.txt'

-- Una pantalla más grande entra más árbol en el volcado.
vim.o.columns = 120
vim.o.lines = 40

local archivo = assert(io.open(salida, 'w'))

local function esperar(condicion, ms)
  return vim.wait(ms or 10000, condicion, 50)
end

-- El repintado ocurre en el siguiente ciclo del bucle de eventos: sin la pausa
-- el volcado puede agarrar la pantalla a medio dibujar.
local function capturar(titulo)
  vim.wait(500)
  vim.cmd 'redraw!'
  archivo:write('=== ' .. titulo .. ' ===\n')
  for fila = 1, vim.o.lines do
    local linea = {}
    for col = 1, vim.o.columns do
      linea[#linea + 1] = vim.fn.screenstring(fila, col)
    end
    archivo:write((table.concat(linea):gsub('%s+$', '')), '\n')
  end
  archivo:write '\n'
  archivo:flush()
  io.stderr:write('capturado: ' .. titulo .. '\n')
end

-- ---------------------------------------------------------------------------
-- 1. Explorador de archivos
--
-- En headless el explorador lista el árbol dos veces: su refresco corre otra
-- vez mientras vim.wait hace girar el bucle de eventos. Es un efecto de correr
-- sin interfaz, no de esta configuración; se reproduce igual con el init.lua
-- anterior. Para lo que prueba este volcado da lo mismo.
-- ---------------------------------------------------------------------------
Snacks.explorer { cwd = vim.uv.cwd() }

local picker
esperar(function()
  picker = Snacks.picker.get({ source = 'explorer' })[1]
  return picker ~= nil and picker.list ~= nil and #picker.list.items > 0
end)

if not picker then
  io.stderr:write 'El explorador no abrió\n'
  vim.cmd 'cquit'
end

-- Expandir una carpeta ejercita el icono de carpeta abierta, que es distinto
-- del de carpeta cerrada. Se salta la raíz, que ya viene abierta: volver a
-- confirmarla la duplicaría en la lista.
local carpeta
for indice, elemento in ipairs(picker.list.items) do
  if elemento.dir and not elemento.open then
    carpeta = elemento
    picker.list:move(indice, true)
    picker:action 'confirm'
    break
  end
end
if carpeta then esperar(function() return carpeta.open == true end) end

capturar 'explorador'
picker:close()
esperar(function() return #Snacks.picker.get { source = 'explorer' } == 0 end, 2000)

-- ---------------------------------------------------------------------------
-- 2. Autocompletado (blink.cmp) y diagnósticos
--
-- La fuente 'buffer' basta para llenar el menú sin levantar un servidor: la
-- columna de tipos es la misma venga de donde venga el candidato.
-- ---------------------------------------------------------------------------
local buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
  'def procesar_ventas(df):',
  '    return df',
  '',
  'proc',
})
-- 'text' y no 'python' a propósito: así no arranca ningún servidor de LSP y la
-- prueba no depende de que basedpyright levante.
vim.bo[buf].filetype = 'text'
vim.api.nvim_set_current_buf(buf)

local ns = vim.api.nvim_create_namespace 'devkit-prueba-ascii'
vim.diagnostic.set(ns, buf, {
  { lnum = 0, col = 0, severity = vim.diagnostic.severity.ERROR, message = 'error de ejemplo', source = 'prueba' },
  { lnum = 1, col = 4, severity = vim.diagnostic.severity.WARN, message = 'aviso de ejemplo', source = 'prueba' },
  { lnum = 2, col = 0, severity = vim.diagnostic.severity.INFO, message = 'nota de ejemplo', source = 'prueba' },
  { lnum = 3, col = 0, severity = vim.diagnostic.severity.HINT, message = 'pista de ejemplo', source = 'prueba' },
})

vim.api.nvim_win_set_cursor(0, { 4, 4 })
vim.cmd 'startinsert!'
require('blink.cmp').show()
esperar(function() return require('blink.cmp').is_menu_visible() end, 5000)
capturar 'autocompletado y diagnosticos'
vim.cmd 'stopinsert'

archivo:close()
vim.cmd 'qa!'
