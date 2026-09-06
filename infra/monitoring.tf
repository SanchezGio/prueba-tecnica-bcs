# -----------------------------------------------------------------------------
# Observabilidad y detección — Log Analytics + Defender for Cloud.
# Los hallazgos de escaneo (Trivy/Bandit/pip-audit/Checkov) se publican como
# artefactos del pipeline (auditables en Azure DevOps); esto complementa con
# detección continua a nivel de plataforma (no solo en el momento del build).
# -----------------------------------------------------------------------------

resource "azurerm_log_analytics_workspace" "main" {
  name                = "law-${local.name_prefix}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  daily_quota_gb      = var.log_analytics_daily_quota_gb # control de costo
  tags                = var.tags
}

resource "azurerm_application_insights" "main" {
  name                = "appi-${local.name_prefix}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  workspace_id        = azurerm_log_analytics_workspace.main.id
  application_type    = "web"
  tags                = var.tags
}

# Defender for Cloud es un recurso a nivel de suscripción. Se modela aquí de
# forma explícita para dejar constancia de la decisión, pero su aplicación
# real puede requerir permisos a nivel de suscripción que un despliegue de
# solo-este-resource-group no siempre tiene — se documenta como paso manual
# adicional en el README si el `apply` de estos dos recursos falla por permisos.

resource "azurerm_security_center_subscription_pricing" "containers" {
  tier          = "Standard"
  resource_type = "Containers"
}

resource "azurerm_security_center_subscription_pricing" "servers" {
  tier          = "Standard"
  resource_type = "VirtualMachines"
  # "P2" (Defender for Servers Plan 2: evaluación de vulnerabilidades + EDR,
  # no solo el básico Plan 1) quedó asignado por Azure al activar Defender
  # sobre la suscripción. Se fija explícitamente para que coincida con el
  # estado real — sin este valor, Terraform detecta "drift" (subplan no
  # declarado) y fuerza un reemplazo completo del recurso, lo que apagaría y
  # volvería a encender Defender for Servers sin que sea una decisión
  # deliberada de este cambio.
  subplan = "P2"
}
