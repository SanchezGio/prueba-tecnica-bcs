# -----------------------------------------------------------------------------
# Identidades administradas — reemplazan cualquier secreto estático (PAT,
# usuario/contraseña de ACR, etc.). Ver docs/architecture.md §5.
# -----------------------------------------------------------------------------

resource "azurerm_user_assigned_identity" "mdp_agents" {
  name                = "id-mdp-agents-${var.environment}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = var.tags
}

resource "azurerm_user_assigned_identity" "aca_app" {
  name                = "id-aca-app-${var.environment}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = var.tags
}

# El agente necesita empujar imágenes al ACR (build) -> AcrPush.
resource "azurerm_role_assignment" "agents_acr_push" {
  scope                = azurerm_container_registry.main.id
  role_definition_name = "AcrPush"
  principal_id         = azurerm_user_assigned_identity.mdp_agents.principal_id
}

# El agente también necesita desplegar el Container App (az containerapp update),
# rol acotado al Container App concreto, no a todo el resource group.
resource "azurerm_role_assignment" "agents_aca_contributor" {
  scope                = azurerm_container_app.demo.id
  role_definition_name = "Container Apps Contributor"
  principal_id         = azurerm_user_assigned_identity.mdp_agents.principal_id
}

# El Container App solo necesita poder leer (pull) imágenes del ACR.
resource "azurerm_role_assignment" "aca_acr_pull" {
  scope                = azurerm_container_registry.main.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.aca_app.principal_id
}

resource "azurerm_role_assignment" "agents_kv_secrets_user" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.mdp_agents.principal_id
}
