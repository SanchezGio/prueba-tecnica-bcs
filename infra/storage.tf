# -----------------------------------------------------------------------------
# Storage Account — usada para diagnósticos/artefactos de build que requieran
# persistencia fuera del agente efímero (p. ej. reportes SARIF de escaneo).
# -----------------------------------------------------------------------------

resource "azurerm_storage_account" "artifacts" {
  name                            = "st${var.project_name}${var.environment}${local.unique_suffix}"
  location                        = azurerm_resource_group.main.location
  resource_group_name             = azurerm_resource_group.main.name
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  public_network_access_enabled   = false
  allow_nested_items_to_be_public = false
  tags                            = var.tags
}

# NOTA: el contenedor de blobs ("scan-reports") se crea deliberadamente por
# fuera de Terraform. `azurerm_storage_container` es una operación de PLANO DE
# DATOS (Blob REST API), distinta de crear la propia Storage Account (que es
# una operación de plano de control vía ARM). Con
# `public_network_access_enabled = false`, la única ruta de red hacia el plano
# de datos es el Private Endpoint dentro de esta VNet — y quien ejecuta
# `terraform apply` (Azure Cloud Shell) NO está dentro de la VNet, así que
# Terraform no puede crear el contenedor (403 esperado). Se crea de forma
# idempotente desde dentro de la red, en el propio agente efímero, la primera
# vez que un pipeline lo necesita:
#   az storage container create --account-name <storage> --name scan-reports \
#     --auth-mode login   # usa la identidad administrada del agente (id-mdp-agents)
# Este es el mismo patrón que se aplicaría a cualquier otro recurso de plano de
# datos detrás de un Private Endpoint (p. ej. secretos de Key Vault, si los
# hubiera) — Terraform gestiona el control-plane, los pipelines gestionan el
# data-plane, porque son los únicos con ruta de red hasta él.

resource "azurerm_private_endpoint" "storage" {
  name                = "pe-storage-${var.environment}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  subnet_id           = azurerm_subnet.pe.id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-storage"
    private_connection_resource_id = azurerm_storage_account.artifacts.id
    subresource_names              = ["blob"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [azurerm_private_dns_zone.blob.id]
  }
}

resource "azurerm_role_assignment" "agents_storage_blob_contributor" {
  scope                = azurerm_storage_account.artifacts.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.mdp_agents.principal_id
}
