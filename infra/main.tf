locals {
  name_prefix = "${var.project_name}-${var.environment}"
  # Sufijo corto y determinístico para recursos que exigen nombre globalmente único
  # (ACR, Key Vault, Storage). random_id se guarda en el state; en un despliegue real
  # esto vive en el backend remoto, no en este repo.
  unique_suffix = random_id.suffix.hex
}

resource "random_id" "suffix" {
  byte_length = 3
}

resource "azurerm_resource_group" "main" {
  name     = "rg-${local.name_prefix}"
  location = var.location
  tags     = var.tags
}
