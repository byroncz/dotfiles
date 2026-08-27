# Configuración de agentes compartida

Lo que hay aquí se **enlaza** dentro de `.claude/` del repo de trabajo, no se
copia. Editar una skill desde el repo de trabajo y editarla desde aquí son la
misma operación sobre el mismo archivo, que es justo lo que se busca: no hay
copia que se quede atrás.

```
claude/skills/<nombre>/SKILL.md   ──enlace──>   <repo>/.claude/skills/<nombre>
```

El enlazado lo hace `provision/post-create.sh` con GNU Stow en cada arranque.

## Lo compartido y lo local conviven

`.claude/skills/` del repo de trabajo acaba mezclando dos cosas, y es
deliberado:

```
.claude/skills/
├── <nombre>            -> enlace a este repo        (compartida)
└── openspec-propose/   directorio real del proyecto (local)
```

Una skill que solo tiene sentido en un proyecto se crea ahí directamente y no
se enlaza. Lo que genere `openspec init` tampoco se toca.

## Añadir una skill compartida

Crea `claude/skills/<nombre>/SKILL.md`, commitea, y reabre el container. No
hay que registrarla en ningún sitio: se enlaza todo lo que cuelgue de aquí.

## Por qué no va bajo `.claude/` de este repo

Porque `.claude/` es el directorio de configuración de ESTE repositorio como
proyecto. Si el origen viviera ahí, enlazar desde un repo de trabajo crearía
un ciclo y no habría forma de distinguir qué es de este proyecto y qué se
comparte con los demás.
