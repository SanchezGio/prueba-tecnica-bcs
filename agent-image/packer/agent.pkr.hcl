# -----------------------------------------------------------------------------
# Plantilla Packer — equivalente de un Dockerfile para la imagen de VM del
# agente efímero (Managed DevOps Pool usa VMs, no contenedores, por lo que el
# artefacto natural para "definición de la imagen del agente" es esta
# plantilla Packer en vez de un Dockerfile). Ver docs/architecture.md §3.3.
#
# Produce una imagen versionada publicada directamente en el Azure Compute
# Gallery (infra/gallery.tf), la misma que referencia el Managed DevOps Pool
# en infra/devops-pool.tf.
# -----------------------------------------------------------------------------

packer {
  required_plugins {
    azure = {
      version = ">= 2.0.0"
      source  = "github.com/hashicorp/azure"
    }
  }
}

variable "subscription_id" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "gallery_name" {
  type    = string
  default = "gal_cicd_dev"
}

variable "image_definition_name" {
  type    = string
  default = "img-agent-ubuntu2204"
}

variable "location" {
  type    = string
  default = "eastus"
}

variable "virtual_network_name" {
  description = "Nombre (no resource ID) de la VNet donde vive la subred temporal de build."
  type        = string
}

variable "virtual_network_subnet_name" {
  description = "Nombre (no resource ID) de la subred temporal (aislada) usada solo durante el build de la imagen, no la subred de producción de los agentes."
  type        = string
}

variable "virtual_network_resource_group_name" {
  description = "Resource group donde vive esa VNet."
  type        = string
}

variable "build_vm_size" {
  description = <<-EOT
    SKU de la VM TEMPORAL de build (no es el SKU de los agentes en
    producción, ese se define en infra/variables.tf:agent_vm_sku). Tanto
    Standard_D2as_v5 como Standard_B2ms fallaron por 'SkuNotAvailable'
    (Capacity Restrictions) en esta suscripción/región — `az vm list-skus`
    mostró que solo la generación v7 de la serie D está disponible sin
    restricciones aquí, de ahí este default. Si esta también falla, vuelve a
    correr `az vm list-skus --location <region> --resource-type
    virtualMachines -o table` para ver qué SKUs sí acepta tu suscripción.
  EOT
  type        = string
  default     = "Standard_D2s_v7"
}

source "azure-arm" "agent" {
  subscription_id    = var.subscription_id
  use_azure_cli_auth = true # sin credenciales estáticas en el pipeline de imagen

  # Reutiliza el resource group principal (rg-cicd-dev) para los recursos
  # TEMPORALES de build (VM, disco, NIC — destruidos al terminar) en vez de
  # dejar que Packer cree uno nuevo a nivel de suscripción. La Service
  # Connection (svc-conn-azure-rm-oidc) solo tiene Contributor sobre este
  # resource group (least privilege, ver docs/DEPLOYMENT_GUIDE.md Fase 4.3) —
  # crear un RG nuevo requeriría permisos a nivel de suscripción que
  # deliberadamente no le dimos. La región se infiere de este mismo resource
  # group (no hace falta declarar `location` junto con `build_resource_group_name`).
  build_resource_group_name = var.resource_group_name

  # Publica directamente como nueva versión en el Compute Gallery.
  shared_image_gallery_destination {
    subscription        = var.subscription_id
    resource_group       = var.resource_group_name
    gallery_name         = var.gallery_name
    image_name           = var.image_definition_name
    # Año.MesDía.HoraMinSeg — Azure resuelve "latest" comparando versiones
    # como major.minor.patch, así que el intento anterior ("1.0.{{timestamp}}")
    # quedó SIEMPRE por debajo de la versión previa "2026.09.06" (major 1 < 2026)
    # y "latest" nunca avanzó pese a publicarse versiones nuevas. Este formato
    # mantiene el mismo "major" (año) que el esquema original y usa
    # mes+día como minor (siempre creciente) y hora+min+seg como patch
    # (único incluso con varios builds el mismo día).
    image_version = "{{isotime \"2006.0102.150405\"}}"
    replication_regions   = [var.location]
  }

  # Imagen ESTÁNDAR de Ubuntu Server (no "minimal"): la variante minimal no
  # trae cloud-init y walinuxagent integrados/pre-configurados para Azure —
  # tras varias vueltas descubriendo una pieza faltante a la vez (walinuxagent
  # ausente, conflicto de aprovisionamiento con cloud-init, dependencia de
  # 'requests' ausente, más una que apareció después) quedó claro que el
  # problema de fondo era la elección de imagen base, no una lista finita de
  # parches. La imagen estándar viene probada por Canonical/Microsoft
  # exactamente para este escenario (VM de Azure con cloud-init + waagent
  # coexistiendo), eliminando esa categoría completa de riesgo de una vez.
  os_type         = "Linux"
  image_publisher = "canonical"
  image_offer     = "0001-com-ubuntu-server-jammy"
  image_sku       = "22_04-lts-gen2"

  # El build corre en una subred aislada (snet-image-build), separada de la
  # subred de producción de los agentes — no es la misma red donde luego
  # operan los agentes reales. El builder azure-arm pide VNet/subred/resource
  # group como nombres separados, no como un resource ID de subred.
  virtual_network_name                = var.virtual_network_name
  virtual_network_subnet_name         = var.virtual_network_subnet_name
  virtual_network_resource_group_name = var.virtual_network_resource_group_name

  # IP pública EFÍMERA solo para que Packer (que corre en un agente
  # Microsoft-hosted, fuera de la VNet) pueda conectarse por SSH a esta VM
  # temporal de build. Trade-off deliberado y acotado: existe solo mientras
  # dura un build (minutos), el NSG de snet-image-build permite entrante
  # únicamente TCP/22 (ver infra/network.tf), y se destruye junto con el
  # resto de la VM al terminar. NO aplica a los agentes de producción
  # (snet-agents), que nunca tienen — ni necesitan — IP pública.
  private_virtual_network_with_public_ip = true

  vm_size = var.build_vm_size

  azure_tags = {
    proyecto = "agentes-efimeros-cicd"
    origen   = "packer"
  }
}

build {
  sources = ["source.azure-arm.agent"]

  # Rutas relativas al directorio de trabajo desde donde se invoca `packer
  # build` (la raíz del repo, ver pipelines/agent-image-pipeline.yml) — Packer
  # resuelve `script` relativo al cwd del proceso, NO relativo a este .pkr.hcl.
  provisioner "shell" {
    execute_command = "sudo -E -S bash '{{ .Path }}'"
    script          = "agent-image/scripts/provision-agent.sh"
  }

  provisioner "shell" {
    execute_command = "sudo -E -S bash '{{ .Path }}'"
    script          = "agent-image/scripts/cis-hardening.sh"
  }

  # Escaneo de vulnerabilidades de la imagen ANTES de publicarla — mecanismo
  # activo y auditable (no solo declarativo), el reporte se sube como
  # artefacto del pipeline de imagen (pipelines/agent-image-pipeline.yml).
  provisioner "shell" {
    inline = [
      "trivy fs --severity HIGH,CRITICAL --exit-code 0 --format json --output /tmp/trivy-agent-image-report.json / || true"
    ]
  }

  provisioner "file" {
    source      = "/tmp/trivy-agent-image-report.json"
    destination = "trivy-agent-image-report.json"
    direction   = "download"
  }

  # Limpieza final: sin claves SSH de build, sin históricos de bash, sin cloud-init
  # residual con datos de la ejecución del build — la imagen publicada debe
  # quedar "en blanco" para que cada VM que arranque desde ella parta idéntica.
  provisioner "shell" {
    execute_command = "sudo -E -S bash '{{ .Path }}'"
    inline = [
      "rm -rf /var/lib/cloud/instances/*",
      "cloud-init clean --logs",
      "rm -f /root/.bash_history /home/*/.bash_history",
      "rm -rf /tmp/*",
      # Cada VM que arranque desde esta imagen debe generar su propio
      # machine-id (systemd lo regenera solo si el archivo queda vacío) —
      # dejarlo con el valor de la VM de build podría causar colisiones o
      # comportamientos raros de red/DHCP entre instancias efímeras.
      "truncate -s 0 /etc/machine-id",
      "rm -f /var/lib/dbus/machine-id",
      "waagent -deprovision+user -force"
    ]
  }
}
