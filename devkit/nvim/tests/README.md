# Pruebas de la configuración de Neovim

Dos scripts, los dos se corren con `nvim --headless` desde la raíz del repo.
Entre los dos cubren la misma regla desde los dos lados: la interfaz no puede
pedir un glifo que Terminal.app no sepa dibujar con la fuente del Mac.

El porqué de la regla está en `docs/ARCHITECTURE.md`, sección 4.4.

## `inventario-glifos.lua`

Lee la configuración ya fusionada de cada plugin (la del plugin más la nuestra
encima) y lista cada cadena con algún carácter fuera de ASCII. Falla con código
de salida 1 si encuentra uno que no sea dibujo de cajas (U+2500–U+257F), que es
lo único fuera de ASCII que esta configuración usa a propósito.

```bash
nvim --headless -c 'luafile devkit/nvim/tests/inventario-glifos.lua'
```

Cubre las piezas que no se pueden capturar de otro modo: el menú de `<espacio>`
(which-key es modal y sin interfaz conectada Neovim no repinta mientras espera
una tecla) y los iconos que solo salen en casos puntuales, como la marca de un
archivo sin seguir en git.

## `solo-ascii.lua`

Abre el explorador de archivos y, aparte, un buffer con diagnósticos y el menú
de autocompletado abierto, y vuelca la pantalla de cada uno a un archivo: no el
buffer, porque snacks dibuja los iconos de archivo como texto virtual y esos no
están en el texto del buffer.

```bash
SALIDA=/tmp/pantalla.txt nvim --headless -c 'luafile devkit/nvim/tests/solo-ascii.lua'
grep -P '[^\x00-\x7F─-╿‘-”…→←▶▼]' /tmp/pantalla.txt
```

El `grep` no debe encontrar nada; devuelve 1 cuando la prueba pasa. Lo que deja
pasar es ASCII más lo que Menlo sí trae: dibujo de cajas, comillas
tipográficas, puntos suspensivos y flechas.

## Lo que ninguna de las dos prueba

Que Menlo tenga de verdad cada carácter permitido. Eso se confirma mirando:
abrir Neovim en Terminal.app y revisar que no queden cuadros en el explorador,
en `<espacio>`, en el autocompletado y en un archivo con errores de LSP.
