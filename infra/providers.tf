terraform {
  required_version = ">= 1.8.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    azapi = {
      source  = "azure/azapi"
      version = "~> 2.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    modtm = {
      source  = "azure/modtm"
      version = "~> 0.3"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  # Backend remoto — el estado de Terraform vive en Azure Storage, no en el
  # disco (efímero, no confiable entre sesiones) de Azure Cloud Shell. Ver
  # docs/DEPLOYMENT_GUIDE.md Fase 2 sobre por qué esto es obligatorio, no
  # opcional, después de perder un estado local a mitad de despliegue.
  backend "azurerm" {
    resource_group_name  = "rg-tfstate"
    storage_account_name = "sttfstate448825877"
    container_name       = "tfstate"
    key                  = "cicd-ephemeral-agents.tfstate"
  }
}

provider "azurerm" {
  # Requerido explícitamente desde azurerm 4.x. Si se deja null, el proveedor
  # intenta inferirlo de la sesión activa de `az` (Cloud Shell ya tiene una);
  # si Terraform se queja pidiéndolo, exporta ARM_SUBSCRIPTION_ID antes de
  # `terraform init`/`plan`/`apply`, o defínelo en terraform.tfvars.
  subscription_id = var.subscription_id

  # azurerm 4.x solo auto-registra un subconjunto "core" de Resource Providers
  # por defecto. Este proyecto usa varios que no están en ese subconjunto
  # (Microsoft.DevCenter, Microsoft.DevOpsInfrastructure, Microsoft.App, etc.)
  # — "all" replica el comportamiento (más simple, requiere permisos para
  # registrar RPs a nivel de suscripción) que tenía la versión 3.x del proveedor.
  resource_provider_registrations = "all"

  features {
    key_vault {
      purge_soft_delete_on_destroy    = true
      recover_soft_deleted_key_vaults = true
    }
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}

provider "azapi" {}

# Requerido por el módulo Azure Verified Module de Managed DevOps Pools
# (infra/devops-pool.tf) para su telemetría opcional — deshabilitada
# explícitamente vía `enable_telemetry = false` en ese módulo.
provider "modtm" {}
