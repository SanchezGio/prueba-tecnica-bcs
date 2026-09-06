# -----------------------------------------------------------------------------
# Azure Container Registry — Premium (requisito para Private Endpoint +
# deshabilitar acceso público). Ver docs/architecture.md §7.3 sobre el costo.
# -----------------------------------------------------------------------------

resource "azurerm_container_registry" "main" {
  name                          = "acr${var.project_name}${var.environment}${local.unique_suffix}"
  location                      = azurerm_resource_group.main.location
  resource_group_name           = azurerm_resource_group.main.name
  sku                           = "Premium"
  admin_enabled                 = false # nunca credenciales admin estáticas
  public_network_access_enabled = false
  tags                          = var.tags
}

resource "azurerm_private_endpoint" "acr" {
  name                = "pe-acr-${var.environment}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  subnet_id           = azurerm_subnet.pe.id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-acr"
    private_connection_resource_id = azurerm_container_registry.main.id
    subresource_names              = ["registry"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [azurerm_private_dns_zone.acr.id]
  }
}

# Defender for Containers habilita el reescaneo continuo de imágenes en ACR
# (detección post-push, no solo en el momento del build). Se define a nivel de
# suscripción -> ver monitoring.tf.
