# -----------------------------------------------------------------------------
# Red privada: ningún recurso en esta VNet recibe IP pública (ver docs/architecture.md §4).
# -----------------------------------------------------------------------------

resource "azurerm_virtual_network" "main" {
  name                = "vnet-${local.name_prefix}"
  location            = azurerm_resource_group.main.location
  resource_group_name  = azurerm_resource_group.main.name
  address_space       = [var.address_space]
  tags                = var.tags
}

# --- Subred de agentes efímeros ---
# Sin delegación: el VM Scale Set (agent-vmss.tf, el mecanismo de agente
# efímero realmente en uso — ver ese archivo) no requiere ni acepta una
# subred delegada. La delegación a `Microsoft.DevOpsInfrastructure/pools`
# solo hacía falta para Managed DevOps Pools (devops-pool.tf, aparcado tras
# un bug no resuelto del servicio en preview) y se retiró porque una subred
# delegada bloquea el despliegue de cualquier otro tipo de recurso (como
# este VMSS) — si se retoma MDP en el futuro, esta delegación debe
# restaurarse primero.
resource "azurerm_subnet" "agents" {
  name                 = "snet-agents"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.subnet_agents_prefix]
}

# --- Subred de Private Endpoints ---
resource "azurerm_subnet" "pe" {
  name                              = "snet-pe"
  resource_group_name               = azurerm_resource_group.main.name
  virtual_network_name              = azurerm_virtual_network.main.name
  address_prefixes                  = [var.subnet_pe_prefix]
  private_endpoint_network_policies = "Disabled"
}

# --- Subred del Azure Container Apps Environment (interno, sin ingress público) ---
resource "azurerm_subnet" "aca" {
  name                 = "snet-aca"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.subnet_aca_prefix]

  delegation {
    name = "container-apps-delegation"
    service_delegation {
      name    = "Microsoft.App/environments"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

# --- Subred temporal de build de la imagen del agente (Packer) ---
# Deliberadamente separada de snet-agents: el build de la imagen necesita
# salir a Internet (apt, curl a GitHub/aka.ms) mientras que la producción
# (snet-agents) deniega ese egress por defecto (ver NSG más abajo). Solo se
# usa mientras corre pipelines/agent-image-pipeline.yml; no aloja nada de
# forma permanente. Ver docs/architecture.md — este es el trade-off explícito
# "qué sale a Internet y por qué", acotado a un proceso de build controlado y
# disparado por pipeline, no a los agentes que ejecutan código de terceros.
resource "azurerm_subnet" "build" {
  name                 = "snet-image-build"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.subnet_build_prefix]
}

resource "azurerm_network_security_group" "build" {
  name                = "nsg-image-build-${var.environment}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = var.tags

  # EXCEPCIÓN DELIBERADA Y ACOTADA: el pipeline de imagen corre en un agente
  # Microsoft-hosted (fuera de la VNet, ver pipelines/agent-image-pipeline.yml)
  # y Packer necesita conectarse por SSH a la VM temporal de build — sin ruta
  # de red privada posible desde un agente hosted, la única opción es una IP
  # pública efímera + este puerto abierto. Acotado a: (a) esta subred aislada,
  # que no aloja nada permanente; (b) solo puerto 22; (c) la VM y su IP
  # pública se destruyen al terminar el build (minutos de exposición, no
  # meses). Los agentes de producción (snet-agents) NUNCA tienen esta regla
  # ni IP pública — ver docs/architecture.md §4.
  security_rule {
    name                       = "AllowSSHInboundForPackerBuild"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "DenyAllInbound"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
  # Outbound: sin restricción explícita (usa el default "Allow" de Azure para
  # VNet/Internet) — únicamente mientras dura el build de una imagen, nunca
  # para ejecutar el código de terceros que sí corren los agentes de producción.
}

resource "azurerm_subnet_network_security_group_association" "build" {
  subnet_id                 = azurerm_subnet.build.id
  network_security_group_id = azurerm_network_security_group.build.id
}

resource "azurerm_subnet_nat_gateway_association" "build" {
  subnet_id      = azurerm_subnet.build.id
  nat_gateway_id = azurerm_nat_gateway.main.id
}

# -----------------------------------------------------------------------------
# NSGs — deny-by-default en inbound; egress acotado a los service tags necesarios.
# -----------------------------------------------------------------------------

resource "azurerm_network_security_group" "agents" {
  name                = "nsg-agents-${var.environment}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = var.tags

  security_rule {
    name                       = "DenyAllInbound"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "AllowAzureDevOpsOutbound"
    priority                   = 100
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "*"
    destination_address_prefix = "AzureDevOps"
  }

  security_rule {
    name                       = "AllowAzureADOutbound"
    priority                   = 110
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "*"
    destination_address_prefix = "AzureActiveDirectory"
  }

  security_rule {
    name                       = "AllowAzureMonitorOutbound"
    priority                   = 120
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "*"
    destination_address_prefix = "AzureMonitor"
  }

  security_rule {
    name                       = "AllowVNetOutbound"
    priority                   = 130
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "VirtualNetwork"
  }

  # El agente instala sus propias herramientas de build (Docker, Trivy, Azure
  # CLI, gitleaks) al inicio de cada ejecución en vez de traerlas precargadas
  # en una imagen dorada (ver agent-vmss.tf y pipelines/app-cicd-pipeline.yml
  # — pivote de entrega tras problemas de integración VM-guest con una
  # imagen personalizada). Eso exige salida real a Internet, no solo a los
  # *service tags* de Azure. Se acota a HTTPS (443) más HTTP (80, ver más
  # abajo) únicamente — sigue sin haber NADA expuesto de entrada, y el resto
  # de puertos de salida arbitrarios sigue denegado por la regla de abajo. En
  # un despliegue real de mayor madurez, esto se reemplazaría por un feed
  # privado de Azure Artifacts (con upstream a los registries públicos) o un
  # Azure Firewall con filtrado por FQDN, para no depender de "todo
  # HTTP(S)" sino de una lista explícita de destinos — ver docs/architecture.md
  # y README.md.
  security_rule {
    name                       = "AllowHTTPSOutboundInternet"
    priority                   = 135
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "*"
    destination_address_prefix = "Internet"
  }

  # El mirror regional de apt (azure.archive.ubuntu.com, usado por defecto en
  # las imágenes Ubuntu de Azure) sirve los paquetes solo por HTTP, sin
  # listener HTTPS — comprobado en vivo (la conexión a 443 sencillamente
  # cuelga hasta timeout). Esto no es una brecha de integridad: apt valida
  # cada paquete contra las firmas GPG del repositorio (Release/Release.gpg),
  # independientemente del transporte, así que instalar por HTTP plano es el
  # comportamiento estándar y aceptado del ecosistema apt/Debian — no algo
  # exclusivo de este pipeline. Sin esta regla, ningún job puede instalar
  # nada vía apt en la imagen de Marketplace sin modificar.
  security_rule {
    name                       = "AllowHTTPOutboundInternetAptMirror"
    priority                   = 136
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "*"
    destination_address_prefix = "Internet"
  }

  security_rule {
    name                       = "DenyInternetOutboundDefault"
    priority                   = 4000
    direction                  = "Outbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "Internet"
  }
}

resource "azurerm_subnet_network_security_group_association" "agents" {
  subnet_id                 = azurerm_subnet.agents.id
  network_security_group_id = azurerm_network_security_group.agents.id
}

resource "azurerm_network_security_group" "aca" {
  name                = "nsg-aca-${var.environment}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = var.tags

  security_rule {
    name                       = "DenyAllInboundFromInternet"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "aca" {
  subnet_id                 = azurerm_subnet.aca.id
  network_security_group_id = azurerm_network_security_group.aca.id
}

# -----------------------------------------------------------------------------
# NAT Gateway — salida controlada y con IP predecible/auditable (reemplaza el
# outbound por defecto de Azure, no expone nada de entrada).
# -----------------------------------------------------------------------------

resource "azurerm_public_ip" "natgw" {
  name                = "pip-natgw-${var.environment}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_nat_gateway" "main" {
  name                    = "natgw-${local.name_prefix}"
  location                = azurerm_resource_group.main.location
  resource_group_name     = azurerm_resource_group.main.name
  sku_name                = "Standard"
  idle_timeout_in_minutes = 10
  tags                    = var.tags
}

resource "azurerm_nat_gateway_public_ip_association" "main" {
  nat_gateway_id       = azurerm_nat_gateway.main.id
  public_ip_address_id = azurerm_public_ip.natgw.id
}

resource "azurerm_subnet_nat_gateway_association" "agents" {
  subnet_id      = azurerm_subnet.agents.id
  nat_gateway_id = azurerm_nat_gateway.main.id
}

resource "azurerm_subnet_nat_gateway_association" "aca" {
  subnet_id      = azurerm_subnet.aca.id
  nat_gateway_id = azurerm_nat_gateway.main.id
}

# -----------------------------------------------------------------------------
# Private DNS Zones para los Private Endpoints (ACR, Key Vault, Storage).
# -----------------------------------------------------------------------------

resource "azurerm_private_dns_zone" "acr" {
  name                = "privatelink.azurecr.io"
  resource_group_name = azurerm_resource_group.main.name
  tags                = var.tags
}

resource "azurerm_private_dns_zone" "keyvault" {
  name                = "privatelink.vaultcore.azure.net"
  resource_group_name = azurerm_resource_group.main.name
  tags                = var.tags
}

resource "azurerm_private_dns_zone" "blob" {
  name                = "privatelink.blob.core.windows.net"
  resource_group_name = azurerm_resource_group.main.name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "acr" {
  name                  = "link-acr"
  resource_group_name  = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.acr.name
  virtual_network_id    = azurerm_virtual_network.main.id
}

resource "azurerm_private_dns_zone_virtual_network_link" "keyvault" {
  name                  = "link-kv"
  resource_group_name  = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.keyvault.name
  virtual_network_id    = azurerm_virtual_network.main.id
}

resource "azurerm_private_dns_zone_virtual_network_link" "blob" {
  name                  = "link-blob"
  resource_group_name  = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.blob.name
  virtual_network_id    = azurerm_virtual_network.main.id
}
