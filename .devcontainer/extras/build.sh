#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────
#  Hook de BUILD del proyecto (opcional). Se ejecuta como root dentro de la
#  imagen, después de instalar las herramientas base y antes de crear el
#  usuario. Úsalo cuando los build args del Dockerfile no bastan: compilar
#  algo, añadir un repo apt, instalar un runtime que no está en la base...
#
#  El template lo deja vacío a propósito. Ejemplos:
#
#    # Node sin cambiar de imagen base
#    curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
#    apt-get install -y --no-install-recommends nodejs
#
#    # Terraform
#    curl -fsSL https://releases.hashicorp.com/terraform/1.9.8/terraform_1.9.8_linux_arm64.zip -o /tmp/tf.zip
#    unzip -q /tmp/tf.zip -d /usr/local/bin && rm /tmp/tf.zip
#
#  Recuerda limpiar cachés (rm -rf /var/lib/apt/lists/*) para no engordar la
#  imagen.
# ─────────────────────────────────────────────────────────────────────────
set -euo pipefail
echo "[build-extras] sin pasos extra definidos"
