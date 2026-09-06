# -----------------------------------------------------------------------------
# Azure Container Apps — destino de despliegue del microservicio de prueba
# (FastAPI, ver app/). Entorno "interno": sin IP pública / ingress público.
# -----------------------------------------------------------------------------

resource "azurerm_container_app_environment" "main" {
  name                           = "cae-${local.name_prefix}"
  location                       = azurerm_resource_group.main.location
  resource_group_name            = azurerm_resource_group.main.name
  log_analytics_workspace_id     = azurerm_log_analytics_workspace.main.id
  infrastructure_subnet_id       = azurerm_subnet.aca.id
  internal_load_balancer_enabled = true # sin IP pública / VIP interna únicamente
  tags                           = var.tags
}

# -----------------------------------------------------------------------------
# DNS del dominio interno del Container Apps Environment.
#
# Comportamiento de Azure (confirmado en vivo, no documentado con suficiente
# claridad): cuando el entorno usa una VNet PROPIA (`infrastructure_subnet_id`,
# como aquí) en vez de dejar que Azure administre su propia VNet, el servicio
# NO crea automáticamente la Private DNS Zone del dominio interno
# (`<default_domain>`, algo como
# "internal.<env>.<region>.azurecontainerapps.io") ni su registro A — a
# diferencia del caso "VNet administrada por Azure", donde sí lo hace. Sin
# esto, cualquier recurso dentro de la VNet (incluidos los agentes efímeros
# del VMSS) nunca resuelve el FQDN interno de la Container App, sin importar
# cuánto se reintente (fallo determinístico, no transitorio — confirmado con
# `getent hosts` fallando 5/5 veces en el pipeline).
#
# Solución oficial de Microsoft para este escenario ("BYO VNet" + entorno
# interno): crear la zona privada del dominio por defecto del entorno, un
# registro A wildcard apuntando a la IP estática interna del entorno, y
# vincular esa zona a la misma VNet — mismo patrón ya usado para ACR/Key
# Vault/Storage más arriba en network.tf, aplicado aquí al propio Container
# Apps Environment.
resource "azurerm_private_dns_zone" "aca_internal" {
  name                = azurerm_container_app_environment.main.default_domain
  resource_group_name = azurerm_resource_group.main.name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "aca_internal" {
  name                  = "link-aca-internal"
  resource_group_name  = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.aca_internal.name
  virtual_network_id    = azurerm_virtual_network.main.id
}

resource "azurerm_private_dns_a_record" "aca_internal_wildcard" {
  name                = "*"
  zone_name           = azurerm_private_dns_zone.aca_internal.name
  resource_group_name = azurerm_resource_group.main.name
  ttl                 = 300
  records             = [azurerm_container_app_environment.main.static_ip_address]
}

resource "azurerm_container_app" "demo" {
  name                         = "aca-fastapi-demo"
  container_app_environment_id = azurerm_container_app_environment.main.id
  resource_group_name          = azurerm_resource_group.main.name
  revision_mode                = "Single"
  tags                         = var.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.aca_app.id]
  }

  registry {
    server   = azurerm_container_registry.main.login_server
    identity = azurerm_user_assigned_identity.aca_app.id
  }

  template {
    min_replicas = 0 # escala a cero — costo casi nulo en reposo
    max_replicas = 2

    container {
      name = "fastapi-demo"
      # Placeholder de arranque: la primera versión REAL de la imagen (en
      # nuestro ACR) todavía no existe en el primer `terraform apply` — la
      # publica el pipeline de CI/CD (pipelines/app-cicd-pipeline.yml). Se usa
      # una imagen pública mínima de Microsoft solo para poder crear el
      # recurso; el `lifecycle.ignore_changes` de abajo evita que Terraform la
      # "restaure" y pise el despliegue real del pipeline en `applies`
      # posteriores — a partir de ahí, la imagen la gobierna el pipeline, no
      # Terraform (ver README, "Terraform gestiona plano de control...").
      image  = var.bootstrap_image
      cpu    = 0.25
      memory = "0.5Gi"
    }
  }

  lifecycle {
    ignore_changes = [template[0].container[0].image]
  }

  ingress {
    external_enabled = false # sin endpoint público — solo alcanzable dentro de la VNet
    target_port      = 8000
    transport        = "auto"

    traffic_weight {
      percentage      = 100
      latest_revision = true
    }
  }
}
