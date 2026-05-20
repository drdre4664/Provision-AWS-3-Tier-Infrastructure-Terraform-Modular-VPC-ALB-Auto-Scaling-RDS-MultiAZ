# ============================================================
# modules/network/main.tf — VNet, subnets, NSGs, NAT Gateway
# ============================================================

# ── Virtual Network ───────────────────────────────────────────
# One VNet scopes the entire network address space for this environment.
# All subnets are carved out of this block so IP ranges never overlap.
resource "azurerm_virtual_network" "main" {
  name                = "vnet-${var.resource_group_name}"
  resource_group_name = var.resource_group_name
  location            = var.location
  address_space       = var.vnet_address_space
  tags                = var.common_tags
}

# ── Public Subnet ─────────────────────────────────────────────
# Hosts the Load Balancer and web-tier VMs.
# Service endpoints for Storage allow VMs to reach blob storage without
# traversing the public internet.
resource "azurerm_subnet" "public" {
  name                 = "snet-public"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.public_subnet_cidr]

  service_endpoints = ["Microsoft.Storage"]
}

# ── Private Subnet ────────────────────────────────────────────
# Hosts the MySQL database — no direct internet route.
# Microsoft.Sql service endpoint lets the DB service authorise
# traffic from this subnet without a public IP.
resource "azurerm_subnet" "private" {
  name                 = "snet-private"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.private_subnet_cidr]

  service_endpoints = ["Microsoft.Sql"]

  delegation {
    name = "mysql-delegation"
    service_delegation {
      name = "Microsoft.DBforMySQL/flexibleServers"
      actions = [
        "Microsoft.Network/virtualNetworks/subnets/join/action",
      ]
    }
  }
}

# ── Network Security Group — Public tier ─────────────────────
# Explicit allow-list: only HTTP, HTTPS, and SSH are open.
# All other inbound traffic is denied by the default "DenyAllInBound" rule.
resource "azurerm_network_security_group" "public" {
  name                = "nsg-public"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.common_tags

  security_rule {
    name                       = "allow-http"
    priority                   = 100   # lower number = higher priority
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "allow-https"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "allow-ssh"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"    # restrict to your IP in production
    destination_address_prefix = "*"
  }
}

# ── NSG Association ───────────────────────────────────────────
resource "azurerm_subnet_network_security_group_association" "public" {
  subnet_id                 = azurerm_subnet.public.id
  network_security_group_id = azurerm_network_security_group.public.id
}

# ── Outputs ───────────────────────────────────────────────────
# Expose IDs so the root module and compute module can reference them.
output "vnet_id" {
  value = azurerm_virtual_network.main.id
}

output "public_subnet_id" {
  value = azurerm_subnet.public.id
}

output "private_subnet_id" {
  value = azurerm_subnet.private.id
}
