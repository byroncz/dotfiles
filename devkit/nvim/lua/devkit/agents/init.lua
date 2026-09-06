--[[
  Hueco de agente.

  Cada agente es un módulo lua/devkit/agents/<nombre>.lua que expone:
    M.setup()          -- configura el plugin del agente
    M.keymaps          -- lista { modo, tecla, acción, descripción }

  Los atajos viven bajo <leader>a y son los mismos para todos los agentes:
    <leader>ac  abrir o cerrar el agente
    <leader>as  enviar la selección (modo visual) o el buffer
    <leader>aa  aceptar el diff propuesto
    <leader>ad  rechazar el diff propuesto

  Para añadir Codex: crear codex.lua con la misma interfaz y pasarlo en la
  lista de setup() desde init.lua.
--]]
local M = {}

function M.setup(names)
  for _, name in ipairs(names) do
    local ok, agent = pcall(require, 'devkit.agents.' .. name)
    if not ok then
      vim.notify('devkit: agente no encontrado: ' .. name, vim.log.levels.WARN)
    else
      agent.setup()
      for _, km in ipairs(agent.keymaps or {}) do
        vim.keymap.set(km[1], km[2], km[3], { desc = km[4] })
      end
    end
  end
end

return M
