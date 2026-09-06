variable "devops_infrastructure_service_principal_object_id" {
  description = <<-EOT
    Object ID (por tenant) del service principal de primera parte de
    Microsoft "DevOpsInfrastructure" — ver comentario en infra/gallery.tf
    sobre por qué se necesita y cómo re-derivarlo en un tenant distinto:
      az ad sp show --id $(az ad sp list --display-name DevOpsInfrastructure --query "[0].appId" -o tsv) --query id -o tsv
  EOT
  type        = string
  default     = "9810f39b-e8aa-4702-bd29-faf4955ff1cb"
}

variable "subscription_id" {
  description = <<-EOT
    ID de la suscripción Azure de destino. Requerido explícitamente por el
    proveedor azurerm >= 4.0. Déjalo como null para intentar inferirlo de la
    sesión activa de `az` (funciona en Azure Cloud Shell si tienes una única
    suscripción o ya hiciste `az account set --subscription <id>`).
  EOT
  type        = string
  default     = null
}

variable "location" {
  description = "Región Azure de despliegue."
  type        = string
  default     = "eastus"
}

variable "environment" {
  description = "Sufijo de entorno (dev, test, prod) usado en nombres de recursos."
  type        = string
  default     = "dev"
}

variable "project_name" {
  description = "Nombre corto del proyecto, usado como prefijo de nombres de recursos."
  type        = string
  default     = "cicd"
}

variable "address_space" {
  description = "Rango CIDR de la VNet principal."
  type        = string
  default     = "10.60.0.0/16"
}

variable "subnet_agents_prefix" {
  description = "Subred delegada a Microsoft.DevOpsInfrastructure/pools (agentes efímeros)."
  type        = string
  default     = "10.60.1.0/24"
}

variable "subnet_pe_prefix" {
  description = "Subred de Private Endpoints (ACR, Key Vault, Storage)."
  type        = string
  default     = "10.60.2.0/24"
}

variable "subnet_aca_prefix" {
  description = "Subred del Azure Container Apps Environment (interno)."
  type        = string
  default     = "10.60.4.0/23"
}

variable "subnet_build_prefix" {
  description = "Subred temporal usada solo para construir la imagen del agente (Packer)."
  type        = string
  default     = "10.60.3.0/24"
}

variable "azure_devops_organization_url" {
  description = "URL de la organización de Azure DevOps, p. ej. https://dev.azure.com/mi-org"
  type        = string
}

variable "azure_devops_project_name" {
  description = "Nombre del proyecto de Azure DevOps donde se registrará el Managed DevOps Pool."
  type        = string
}

variable "agent_vm_sku" {
  description = <<-EOT
    SKU de VM usado por el Managed DevOps Pool para builds estándar.
    Historial de diagnóstico en esta suscripción de prueba (ver también
    agent_pool_max_agents):
    - Standard_D4as_v5: 'SkuNotAvailable' (Capacity Restrictions).
    - Standard_DC4as_v5 (cómputo confidencial): 'IncompatibleConfidentialVM'.
    - Standard_D4s_v7: pasaba todas las validaciones de imagen/red una vez
      resuelto el permiso de VNet (ver infra/devops-pool.tf), pero
      'InsufficientCoreQuota' — la suscripción tiene un tope de solo 4
      vCPUs TOTALES en la región (`az vm list-usage --location <region>`),
      independiente de qué SKU se elija. maximum_concurrency=4 × 4 vCPUs
      pedía 16, muy por encima del tope.
    - Standard_D2s_v7 (2 vCPU): candidato actual, dimensionado para caber
      dentro del tope de 4 vCPUs junto con agent_pool_max_agents=1.
  EOT
  type        = string
  default     = "Standard_D2s_v7"
}

variable "agent_pool_max_agents" {
  description = <<-EOT
    Número máximo de agentes concurrentes que el pool puede provisionar.
    Acotado a 1 en esta suscripción de prueba por el tope de 4 vCPUs
    TOTALES en la región (ver agent_vm_sku) — con Standard_D2s_v7 (2 vCPU),
    1 agente concurrente usa 2 de las 4 vCPUs disponibles, dejando margen.
    En una suscripción con cuota normal, subir esto a 3-4 es razonable.
  EOT
  type        = number
  default     = 1
}

variable "create_agent_pool" {
  description = <<-EOT
    Poner en true SOLO en el segundo `terraform apply`, después de haber
    publicado al menos una versión de la imagen del agente en el Compute
    Gallery (ejecutando pipelines/agent-image-pipeline.yml). El pool falla al
    crearse si la imagen referenciada no tiene ninguna versión todavía. Ver
    docs/DEPLOYMENT_GUIDE.md.
  EOT
  type        = bool
  default     = false
}

variable "agent_pool_standby_count" {
  description = <<-EOT
    Cantidad de agentes en 'standby' (pre-aprovisionados, listos para tomar un job
    inmediatamente). 0 = costo mínimo, acepta latencia de arranque en frío (~1-2 min).
    Ver docs/architecture.md sección 7.3 (trade-off costo vs. disponibilidad).
  EOT
  type        = number
  default     = 0
}

variable "bootstrap_image" {
  description = <<-EOT
    Imagen pública usada SOLO para poder crear el Container App la primera
    vez (todavía no existe una imagen real en nuestro ACR en el primer
    `terraform apply`). El pipeline de CI/CD la reemplaza con
    `az containerapp update` una vez que construye y publica la imagen real;
    `lifecycle.ignore_changes` en container-apps.tf evita que Terraform la
    revierta en applies posteriores.
  EOT
  type        = string
  default     = "mcr.microsoft.com/k8se/quickstart:latest"
}

variable "log_analytics_daily_quota_gb" {
  description = "Tope diario de ingesta en Log Analytics, para control de costo."
  type        = number
  default     = 2
}

variable "tags" {
  description = "Tags comunes aplicados a todos los recursos."
  type        = map(string)
  # Clave "proposito" SIN tilde deliberadamente: con tilde ("propósito") se
  # observó "drift" perpetuo en cada `terraform plan` (Terraform proponía
  # re-aplicar la misma tag una y otra vez, incluso justo después de un
  # apply exitoso) — causa más probable: normalización Unicode distinta
  # entre cómo se guarda el carácter acentuado localmente (NFC/NFD) y cómo
  # lo devuelve la API de Azure Resource Manager al refrescar el estado,
  # produciendo una diferencia real a nivel de bytes pese a verse idéntico.
  # Se evita la clase completa de riesgo restringiendo las claves de tags a
  # ASCII.
  default = {
    proyecto   = "agentes-efimeros-cicd"
    proposito  = "prueba-tecnica-lider-ciberseguridad"
    gestion    = "terraform"
  }
}
