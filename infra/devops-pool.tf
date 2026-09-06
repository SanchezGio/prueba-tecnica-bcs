# -----------------------------------------------------------------------------
# ⚠️ APARCADO — no es el mecanismo de agente efímero en uso.
#
# Ver agent-vmss.tf para el mecanismo REAL actualmente en uso (VM Scale Set /
# Elastic Pool clásico). Este archivo se deja completo y funcional en su
# propio mérito — RBAC verificado en vivo en 4 ubicaciones distintas, imagen
# con NVMe, cuota de vCPUs correctamente dimensionada, adjunto de galería al
# DevCenter — como evidencia del proceso de troubleshooting y porque
# `create_agent_pool` sigue en `false` por defecto (no interfiere con nada).
# El servicio (Managed DevOps Pools, en *preview*) siguió rechazando la
# creación del pool con "InvalidImageResourceId" pese a que cada requisito
# documentado quedó verificado correcto — se pivotó por el plazo de entrega,
# no por falta de intentos. Ver docs/architecture.md y README.md para el
# detalle completo de la decisión.
#
# Managed DevOps Pool — el corazón del modelo de agente efímero.
#
# El DevCenter y el DevCenter Project se crean vía `azapi` (recursos estables,
# sin ambigüedad de schema). El pool en sí se crea con el Azure Verified
# Module oficial de Microsoft para Managed DevOps Pools
# (Azure/avm-res-devopsinfrastructure-pool/azurerm), que internamente resuelve
# tanto el recurso ARM (`Microsoft.DevOpsInfrastructure/pools`) como el enlace
# autenticado pool ⇄ organización de Azure DevOps — evita fijar a mano un
# `api_version`/schema de un servicio joven, que era el enfoque original de
# este archivo (ver historial de git) antes de encontrar el módulo oficial.
#
# APPLY EN DOS PASADAS (ver docs/DEPLOYMENT_GUIDE.md): el pool exige que la
# imagen del Compute Gallery (azurerm_shared_image.agent) ya tenga al menos
# una versión publicada, y esa versión la publica el pipeline de imagen
# (pipelines/agent-image-pipeline.yml), que a su vez necesita que el resto de
# la infraestructura (red, gallery, identidades) ya exista. Por eso el módulo
# está detrás de `var.create_agent_pool` (default `false`):
#   1) terraform apply                      (create_agent_pool = false)
#   2) ejecutar el pipeline de imagen una vez (publica la 1ª versión)
#   3) terraform apply -var create_agent_pool=true   (ahora sí crea el pool)
# -----------------------------------------------------------------------------

locals {
  devcenter_api_version = "2024-02-01"

  # El módulo pide el nombre "pelado" de la organización (sin el prefijo
  # https://dev.azure.com/), extraído de azure_devops_organization_url.
  devops_org_name = regex("[^/]+$", trimsuffix(var.azure_devops_organization_url, "/"))

  # "Off" = sin agentes en standby (costo mínimo, acepta cold start ~1-2 min).
  # "Manual" = mantiene `agent_pool_standby_count` agentes listos todo el día.
  # Ver docs/architecture.md §7.3 para el trade-off costo vs. disponibilidad.
  agent_resource_prediction_profile = var.agent_pool_standby_count > 0 ? "Manual" : "Off"
}

resource "azapi_resource" "devcenter" {
  type      = "Microsoft.DevCenter/devcenters@${local.devcenter_api_version}"
  name      = "dc-${local.name_prefix}"
  location  = azurerm_resource_group.main.location
  parent_id = azurerm_resource_group.main.id
  tags      = var.tags

  identity {
    type = "SystemAssigned"
  }
}

resource "azapi_resource" "devcenter_project" {
  type      = "Microsoft.DevCenter/projects@${local.devcenter_api_version}"
  name      = "proj-${local.name_prefix}"
  location  = azurerm_resource_group.main.location
  parent_id = azurerm_resource_group.main.id
  tags      = var.tags

  body = {
    properties = {
      devCenterId = azapi_resource.devcenter.id
    }
  }
}

# El modelo de DevCenter (sobre el que corre Managed DevOps Pools) exige
# adjuntar explícitamente cada Compute Gallery al recurso DevCenter antes de
# que sus imágenes sean usables por proyectos/pools asociados — esto es
# DISTINTO del rol "Compute Gallery Image Reader" que ya le dimos al service
# principal de primera parte "DevOpsInfrastructure" (gallery.tf). Aquí se usa
# la identidad PROPIA del DevCenter (system-assigned), siguiendo el ejemplo
# oficial de Microsoft para `Microsoft.DevCenter/devcenters/galleries`.
resource "azurerm_role_assignment" "devcenter_identity_gallery_reader" {
  scope                = azurerm_shared_image_gallery.main.id
  role_definition_name = "Reader"
  principal_id         = azapi_resource.devcenter.output.identity.principalId
}

resource "azapi_resource" "devcenter_gallery_attachment" {
  type = "Microsoft.DevCenter/devcenters/galleries@${local.devcenter_api_version}"
  # Este nombre (a diferencia de la mayoría de recursos Azure) no admite
  # guiones — solo alfanuméricos, "_" y ".".
  name      = "gal_${var.project_name}_${var.environment}_attachment"
  parent_id = azapi_resource.devcenter.id

  body = {
    properties = {
      galleryResourceId = azurerm_shared_image_gallery.main.id
    }
  }

  depends_on = [azurerm_role_assignment.devcenter_identity_gallery_reader]
}

# El service principal "DevOpsInfrastructure" (ver gallery.tf) también
# necesita poder LEER la VNet y unir VMs a la subred delegada — sin esto el
# pool falla al crearse con "UnauthorizedAccessToVirtualNetwork". Este
# permiso resultó ser la causa real detrás del persistente
# "InvalidImageResourceId" que veíamos antes (un mensaje que no reflejaba el
# problema de fondo) — solo se hizo visible al descartar primero cualquier
# problema relacionado con la imagen.
resource "azurerm_role_assignment" "devops_infrastructure_vnet_reader" {
  scope                = azurerm_virtual_network.main.id
  role_definition_name = "Reader"
  principal_id         = var.devops_infrastructure_service_principal_object_id
}

resource "azurerm_role_assignment" "devops_infrastructure_vnet_network_contributor" {
  scope                = azurerm_virtual_network.main.id
  role_definition_name = "Network Contributor"
  principal_id         = var.devops_infrastructure_service_principal_object_id
}

module "managed_devops_pool" {
  count = var.create_agent_pool ? 1 : 0

  source  = "Azure/avm-res-devopsinfrastructure-pool/azurerm"
  version = "~> 0.3"

  name                = "mdp-${var.project_name}-agents-${var.environment}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = var.tags

  # Opt-out explícito de la telemetría opcional de los Azure Verified Modules.
  enable_telemetry = false

  dev_center_project_resource_id = azapi_resource.devcenter_project.id
  subnet_id                      = azurerm_subnet.agents.id

  # Sin PAT: el módulo resuelve el enlace pool ⇄ organización de Azure DevOps
  # usando la identidad con la que corre `terraform apply` (necesita ser al
  # menos administradora del proyecto de Azure DevOps) — ver docs/DEPLOYMENT_GUIDE.md.
  organization_profile = {
    organizations = [{
      name        = local.devops_org_name
      projects    = [var.azure_devops_project_name]
      parallelism = var.agent_pool_max_agents
    }]
    permission_profile = {
      kind = "CreatorOnly"
    }
  }

  maximum_concurrency = var.agent_pool_max_agents

  # 'Stateless' (default del módulo) = el agente se destruye automáticamente
  # tras cada job — ver docs/architecture.md §3.2.
  agent_profile_kind                        = "Stateless"
  agent_profile_resource_prediction_profile = local.agent_resource_prediction_profile
  agent_profile_resource_predictions_manual = {
    time_zone = "UTC"
    days_data = [{ "00:00:00" = var.agent_pool_standby_count }]
  }

  fabric_profile_sku_name              = var.agent_vm_sku
  fabric_profile_os_profile_logon_type = "Service" # sin sesión interactiva -> sin necesidad de Bastion
  # `aliases`: nombre corto por el que la definición del pool referencia
  # esta imagen.
  fabric_profile_images = [{
    resource_id = azurerm_shared_image.agent.id
    buffer      = "*"
    aliases     = ["ubuntu2204"]
  }]

  managed_identities = {
    user_assigned_resource_ids = [azurerm_user_assigned_identity.mdp_agents.id]
  }

  depends_on = [
    azurerm_subnet.agents,
    azurerm_shared_image.agent,
    azurerm_user_assigned_identity.mdp_agents,
    azurerm_role_assignment.devops_infrastructure_gallery_image_reader,
    azurerm_role_assignment.devops_infrastructure_vnet_reader,
    azurerm_role_assignment.devops_infrastructure_vnet_network_contributor,
    azapi_resource.devcenter_gallery_attachment,
  ]
}
