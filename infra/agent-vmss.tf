# -----------------------------------------------------------------------------
# PIVOTE DE ENTREGA: Elastic Pool clásico de Azure DevOps (VM Scale Set).
#
# El enfoque original de este proyecto era Managed DevOps Pools (ver
# devops-pool.tf) — más moderno, sin PAT, con el enlace pool⇄organización
# resuelto por un Azure Verified Module oficial. Se probó exhaustivamente
# (RBAC en 4 ubicaciones distintas, NVMe/DiskControllerTypes, cuota de vCPUs,
# adjunto de galería al DevCenter — cada uno un bug real y documentado en el
# historial de git) pero el servicio (todavía en *preview*) siguió rechazando
# la creación del pool con "InvalidImageResourceId" incluso con todo
# correctamente configurado y verificado en vivo. Dado el plazo de entrega,
# se pivotó al mecanismo clásico y maduro de "Azure virtual machine scale
# set" agent pools.
#
# SEGUNDO PIVOTE, dentro del mismo archivo: el VMSS originalmente arrancaba
# desde nuestra imagen propia (Packer + Compute Gallery, ver agent-image/).
# Esa imagen se construye y publica correctamente (pipelines/agent-image-pipeline.yml
# sigue funcionando y demuestra la capacidad completa: hardening, escaneo,
# versionado), pero al usarla como imagen de arranque real del VMSS, el
# agente invitado de Azure (walinuxagent) nunca llegó a completar su ciclo
# de integración con el fabric de Azure de forma estable pese a múltiples
# rondas de corrección (agente ausente, conflicto de aprovisionamiento con
# cloud-init, dependencia de Python ausente, interferencia de una segunda
# versión de Python) — cada ronda avanzaba pero aparecía un problema nuevo,
# y el tiempo de entrega no permite seguir iterando indefinidamente sobre
# la integración VM-guest de una imagen personalizada.
#
# Se pivotó a la imagen ESTÁNDAR de Ubuntu Server de Azure Marketplace, SIN
# modificar — la misma que usan a diario miles de VMs en producción, con
# cero incertidumbre sobre su integración con Azure. El principio de
# "efímero" no depende de la imagen: lo garantiza la opción "Recreate agent
# after each use" del Elastic Pool (equivalente a `agentProfile.kind =
# Stateless` de Managed DevOps Pools), sin importar qué imagen arranque.
# Las herramientas de build (Docker, Trivy, Azure CLI, etc.) que antes vivían
# precargadas en la imagen dorada ahora se instalan al inicio de cada
# ejecución del pipeline — ver pipelines/app-cicd-pipeline.yml y el ajuste
# de NSG en network.tf (snet-agents ahora permite salida a Internet, antes
# denegada por defecto, precisamente para esto). Ver docs/architecture.md y
# README.md, sección de limitaciones, para la reflexión completa sobre este
# trade-off (velocidad de build vs. confiabilidad de arranque).
# -----------------------------------------------------------------------------

# Clave SSH generada solo para satisfacer el schema del recurso (Azure exige
# alguna credencial de admin) — la clave privada NUNCA se guarda en ningún
# sitio útil ni se expone como output. No hay acceso interactivo por diseño
# (ver docs/architecture.md §4, "por qué no hace falta Bastion"); para
# depuración excepcional se usa Azure Run Command / Serial Console sobre el
# plano de control de ARM, no SSH.
resource "tls_private_key" "agent_vmss" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "azurerm_linux_virtual_machine_scale_set" "agents" {
  name                = "vmss-${var.project_name}-agents-${var.environment}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = var.agent_vm_sku
  instances           = 0 # Azure DevOps escala esto dinámicamente vía el Elastic Pool
  admin_username      = "azureuser"
  upgrade_mode        = "Manual"
  tags                = var.tags

  # Imagen ESTÁNDAR de Azure Marketplace, sin modificar (ver comentario de
  # cabecera). "latest" apunta siempre a la versión más reciente publicada
  # por Canonical/Microsoft.
  source_image_reference {
    publisher = "canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  # Azure DevOps cambia esto a `false` por su cuenta al vincular el VMSS a un
  # Elastic Pool (lo necesita para gestionar su propio escalado más allá de
  # un solo grupo de ubicación) — se declara igual acá para que Terraform no
  # intente revertirlo.
  single_placement_group = false

  admin_ssh_key {
    username   = "azureuser"
    public_key = tls_private_key.agent_vmss.public_key_openssh
  }

  os_disk {
    storage_account_type = "Standard_LRS"
    caching               = "ReadWrite"
  }

  # Sin IP pública en ninguna instancia — misma postura que el resto de la
  # plataforma (ver docs/architecture.md §4).
  network_interface {
    name                          = "nic-agent"
    primary                       = true
    network_security_group_id    = azurerm_network_security_group.agents.id

    ip_configuration {
      name      = "internal"
      primary   = true
      subnet_id = azurerm_subnet.agents.id
    }
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.mdp_agents.id]
  }

  # Habilita Consola serie / diagnóstico de arranque (usa almacenamiento
  # administrado por Azure) — sin abrir ningún puerto de red ni desplegar
  # Bastion.
  boot_diagnostics {
    storage_account_uri = null
  }

  depends_on = [
    azurerm_subnet.agents,
  ]
}
