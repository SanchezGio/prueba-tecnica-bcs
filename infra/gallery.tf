# -----------------------------------------------------------------------------
# Azure Compute Gallery — almacena las versiones publicadas de la imagen del
# agente (construida con Packer, ver agent-image/packer/agent.pkr.hcl).
# Terraform solo crea el "contenedor" (gallery + image definition); las
# versiones de imagen las publica el pipeline de imagen (pipelines/agent-image-pipeline.yml).
# -----------------------------------------------------------------------------

resource "azurerm_shared_image_gallery" "main" {
  name                = "gal_${var.project_name}_${var.environment}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  description         = "Imágenes versionadas y escaneadas para los agentes efímeros de CI/CD."
  tags                = var.tags
}

resource "azurerm_shared_image" "agent" {
  name                = "img-agent-ubuntu2204"
  gallery_name        = azurerm_shared_image_gallery.main.name
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  os_type             = "Linux"
  hyper_v_generation  = "V2"
  tags                = var.tags

  # Requisito documentado de Managed DevOps Pools para tamaños de VM v6/v7
  # (ver agent_vm_sku, actualmente Standard_D2s_v7): la definición de imagen
  # debe declarar soporte NVMe (equivalente a `DiskControllerTypes="SCSI,NVMe"`
  # a nivel de ARM) o el pool rechaza la imagen con
  # SkuNotCompatibleWithImageDiskControllerType. Necesario pero NO suficiente
  # por sí solo — ver infra/devops-pool.tf para el resto de requisitos
  # (RBAC de la imagen/galería, adjunto de galería al DevCenter, permisos de
  # VNet) que también hacían falta y se fueron descubriendo uno a uno.
  disk_controller_type_nvme_enabled = true

  identifier {
    publisher = var.project_name
    offer     = "cicd-ephemeral-agent"
    sku       = "ubuntu-22-04-hardened"
  }
}

# El servicio de Managed DevOps Pools (Microsoft.DevOpsInfrastructure) usa un
# service principal de PRIMERA PARTE de Microsoft, llamado literalmente
# "DevOpsInfrastructure", para resolver y leer imágenes de un Azure Compute
# Gallery propio. Sin este rol, el pool falla al crearse con
# "InvalidImageResourceId" — un mensaje engañoso: el resourceId es correcto,
# lo que falta es permiso para que el servicio lo resuelva. No hay recurso
# nativo de Terraform para "buscar" este SPN (viviría en el proveedor
# `azuread`, que este proyecto no usa) — su Object ID se obtuvo una vez con:
#   az ad sp show --id $(az ad sp list --display-name DevOpsInfrastructure --query "[0].appId" -o tsv) --query id -o tsv
# y es específico de este tenant (Microsoft crea el SPN de un app de primera
# parte la primera vez que se usa en cada tenant) — si este código se
# despliega en un tenant distinto, hay que re-derivar el valor con ese mismo
# comando y actualizar la variable.
resource "azurerm_role_assignment" "devops_infrastructure_gallery_image_reader" {
  scope                = azurerm_shared_image.agent.id
  role_definition_name = "Compute Gallery Image Reader"
  principal_id         = var.devops_infrastructure_service_principal_object_id
}
