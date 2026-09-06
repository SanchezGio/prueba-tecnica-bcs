output "resource_group_name" {
  value = azurerm_resource_group.main.name
}

output "container_registry_login_server" {
  value = azurerm_container_registry.main.login_server
}

output "container_app_fqdn_internal" {
  description = "FQDN interno del Container App (solo alcanzable dentro de la VNet)."
  value       = azurerm_container_app.demo.latest_revision_fqdn
}

output "key_vault_uri" {
  value = azurerm_key_vault.main.vault_uri
}

output "shared_image_gallery_id" {
  value = azurerm_shared_image.agent.id
}

output "log_analytics_workspace_id" {
  value = azurerm_log_analytics_workspace.main.id
}

output "managed_devops_pool_id" {
  description = "ID del Managed DevOps Pool. Solo tiene valor una vez aplicado con create_agent_pool = true (ver docs/DEPLOYMENT_GUIDE.md)."
  value       = var.create_agent_pool ? module.managed_devops_pool[0].resource_id : null
}

output "managed_devops_pool_name" {
  value = "mdp-${var.project_name}-agents-${var.environment}"
}

# ---------------------------------------------------------------------------
# Valores a usar en el variable group "cicd-ephemeral-agents-image" del
# pipeline de imagen (pipelines/agent-image-pipeline.yml). Ver docs/DEPLOYMENT_GUIDE.md Fase 5.
# ---------------------------------------------------------------------------

output "image_build_subnet_id" {
  description = "Valor de la variable BUILD_SUBNET_ID."
  value       = azurerm_subnet.build.id
}

output "azure_subscription_id" {
  description = "Valor de la variable AZURE_SUBSCRIPTION_ID."
  value       = data.azurerm_client_config.current.subscription_id
}

output "compute_gallery_name" {
  description = "Valor de la variable GALLERY_NAME."
  value       = azurerm_shared_image_gallery.main.name
}
