#!/usr/bin/env bash
# Instala únicamente las herramientas estrictamente necesarias para
# build/test/scan del componente de prueba. Nada de credenciales embebidas:
# toda autenticación en tiempo de ejecución se resuelve vía identidad
# administrada (ver docs/architecture.md §5).
#
# Corre sobre la imagen ESTÁNDAR de Ubuntu Server 22.04 (no "minimal" — ver
# agent.pkr.hcl y el historial de git de este archivo): esa imagen ya trae
# cloud-init y walinuxagent integrados y pre-configurados para Azure, así
# que este script solo instala herramientas de build/CI, no infraestructura
# de arranque de la VM.
set -euxo pipefail

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get -y upgrade

# SOLUCIÓN DEFINITIVA a la categoría de errores de cloud-init que veníamos
# arrastrando (fallaba en una etapa distinta cada vez: datasource, luego
# Config Stage, con "ModuleNotFoundError" variando): la causa real no era la
# imagen, era que ESTE MISMO SCRIPT instalaba `python3.11` junto al Python
# del SISTEMA (3.10, el que usa cloud-init vía su shebang /usr/bin/python3).
# En Ubuntu, instalar una versión adicional de Python puede alterar qué
# intérprete queda resuelto como "python3" por defecto — exactamente el tipo
# de interferencia que rompe cloud-init de forma impredecible según qué
# módulo intente cargar en cada etapa. La solución no es perseguir cada
# módulo faltante: es NO TOCAR el Python del sistema en absoluto. Bandit y
# pip-audit corren perfectamente con el Python 3.10 que ya trae la imagen,
# dentro de un entorno virtual aislado (ver más abajo) — no hay ninguna
# razón real para necesitar 3.11 en este agente.
apt-get install -y --no-install-recommends \
  ca-certificates \
  curl \
  gnupg \
  git=1:2.34.* \
  python3 \
  python3-venv \
  python3-pip \
  unzip \
  jq \
  auditd \
  unattended-upgrades \
  liblttng-ust1 \
  libkrb5-3 \
  zlib1g \
  libssl3 \
  libicu70

# liblttng-ust1/libkrb5-3/zlib1g/libssl3/libicu70: prerrequisitos
# DOCUMENTADOS por Microsoft para el binario del agente de Azure Pipelines en
# Linux (self-hosted, incluido el que instala automáticamente la extensión
# de un Elastic Pool de VM Scale Set) — sin estas librerías, el agente ni
# siquiera arranca. Se instalan acá, proactivamente, en vez de esperar a que
# la extensión falle en una VM real para enterarnos. A diferencia del resto
# de este archivo, esto NO depende de si la imagen base es minimal o
# estándar — es un requisito del agente de Azure Pipelines en sí.
# Referencia: https://learn.microsoft.com/azure/devops/pipelines/agents/linux-agent

# --- Azure CLI (usada por el pipeline para az acr login --identity, az containerapp update, etc.) ---
curl -sL https://aka.ms/InstallAzureCLIDeb | bash

# --- Docker (rootless donde sea posible) para construir la imagen del microservicio ---
curl -fsSL https://get.docker.com | sh
usermod -aG docker azureuser || true
systemctl enable docker

# --- Trivy (escaneo de imágenes de contenedor y del propio filesystem de la imagen del agente) ---
# Instalado vía el repositorio APT oficial en vez del instalador
# "curl | sh" de un solo comando: evita depender de la API de GitHub (sujeta
# a rate-limiting) y de la lógica interna de ese script, además de integrarse
# con el resto de este provisioning ya basado en apt.
curl -fsSL https://aquasecurity.github.io/trivy-repo/deb/public.key | gpg --dearmor -o /usr/share/keyrings/trivy.gpg
echo "deb [signed-by=/usr/share/keyrings/trivy.gpg] https://aquasecurity.github.io/trivy-repo/deb generic main" \
  | tee /etc/apt/sources.list.d/trivy.list
apt-get update
apt-get install -y trivy

# --- Herramientas de análisis para el componente Python (Bandit SAST, pip-audit SCA) ---
# En un entorno virtual dedicado, NUNCA en el Python del sistema (ver
# comentario arriba) — así, sin importar qué instalemos acá, el `python3`
# que usa cloud-init (y cualquier otra cosa del sistema) queda intacto.
python3 -m venv /opt/agent-tools-venv
/opt/agent-tools-venv/bin/pip install --no-cache-dir --upgrade pip
/opt/agent-tools-venv/bin/pip install --no-cache-dir bandit pip-audit
ln -sf /opt/agent-tools-venv/bin/bandit /usr/local/bin/bandit
ln -sf /opt/agent-tools-venv/bin/pip-audit /usr/local/bin/pip-audit

# --- gitleaks (secretos) ---
GITLEAKS_VERSION="8.18.4"
curl -sSL "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz" \
  -o /tmp/gitleaks.tar.gz
tar -xzf /tmp/gitleaks.tar.gz -C /usr/local/bin gitleaks
rm -f /tmp/gitleaks.tar.gz

# --- Actualizaciones automáticas de la propia imagen base (no de la VM en ejecución,
#     que es efímera; esto reduce la deriva entre una reconstrucción de imagen y la siguiente) ---
dpkg-reconfigure -f noninteractive unattended-upgrades

echo "Provisioning de la imagen del agente completado."
