# Plugins propios

Cada archivo `.lua` de este directorio devuelve una especificación de
plugins de lazy.nvim y se carga automáticamente (`{ import = "plugins" }`
en `lua/config/lazy.lua`).

Sirve para tres cosas:

- **Añadir** un plugin que LazyVim no trae.
- **Configurar** uno que sí trae, repitiendo su nombre y añadiendo `opts`.
- **Quitar** uno, con `enabled = false`.

Ejemplo, en un archivo `lua/plugins/ejemplo.lua`:

```lua
return {
  -- añadir
  { "tpope/vim-fugitive" },

  -- configurar uno que ya viene con LazyVim
  { "folke/which-key.nvim", opts = { win = { border = "single" } } },

  -- quitar
  { "akinsho/bufferline.nvim", enabled = false },
}
```

Los *extras* de LazyVim (soporte por lenguaje: Python, Go, Docker...) se
activan con `:LazyExtras`, que escribe en `lazyvim.json` — versionado en
este repo, así que la selección viaja a todas las máquinas.

Este directorio empieza sin ningún plugin propio a propósito: el template
no debe imponer preferencias. `lua/config/lazy.lua` necesita que el
directorio exista, y este README basta para que exista.
