# ============================================================
# modules/compute/main.tf — Load Balancer + VM Scale Set
# ============================================================

# ── Public IP for Load Balancer ───────────────────────────────
# Static allocation means the IP does not change on reboot —
# important for DNS A-record stability.
resource "azurerm_public_ip" "lb" {
  name                = "pip-lb"
  resource_group_name = var.resource_group_name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"   # Standard SKU required for zone-redundant LB
  tags                = var.common_tags
}

# ── Load Balancer ─────────────────────────────────────────────
# Distributes inbound HTTP traffic across all healthy VMs in the scale set.
resource "azurerm_lb" "main" {
  name                = "lb-epicbook"
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = "Standard"

  frontend_ip_configuration {
    name                 = "lb-frontend"
    public_ip_address_id = azurerm_public_ip.lb.id
  }

  tags = var.common_tags
}

# ── Backend Address Pool ──────────────────────────────────────
# VMs in the scale set register themselves into this pool.
resource "azurerm_lb_backend_address_pool" "main" {
  loadbalancer_id = azurerm_lb.main.id
  name            = "lb-backend-pool"
}

# ── Health Probe ──────────────────────────────────────────────
# The LB probes each VM every 15 seconds on port 80.
# After 2 consecutive failures a VM is removed from rotation.
resource "azurerm_lb_probe" "http" {
  loadbalancer_id = azurerm_lb.main.id
  name            = "probe-http"
  protocol        = "Http"
  port            = 80
  request_path    = "/health"   # application must serve 200 OK at this path
  interval_in_seconds = 15
  number_of_probes    = 2
}

# ── Load Balancing Rule ───────────────────────────────────────
# Maps port 80 on the public IP to port 80 on each backend VM.
resource "azurerm_lb_rule" "http" {
  loadbalancer_id                = azurerm_lb.main.id
  name                           = "rule-http"
  protocol                       = "Tcp"
  frontend_port                  = 80
  backend_port                   = 80
  frontend_ip_configuration_name = "lb-frontend"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.main.id]
  probe_id                       = azurerm_lb_probe.http.id
}

# ── VM Scale Set ──────────────────────────────────────────────
# Scale set manages a fleet of identical VMs and can scale out/in
# automatically based on CPU metrics.
resource "azurerm_linux_virtual_machine_scale_set" "main" {
  name                = "vmss-epicbook"
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = var.vm_size
  instances           = var.vm_count
  admin_username      = var.admin_username

  # SSH key auth — password auth disabled for security
  admin_ssh_key {
    username   = var.admin_username
    public_key = file(var.ssh_public_key_path)
  }

  # Ubuntu 22.04 LTS — use latest patch to pick up security fixes automatically
  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"   # SSD-backed — required for production workloads
  }

  network_interface {
    name    = "nic-vmss"
    primary = true

    ip_configuration {
      name                                   = "ipconfig"
      primary                                = true
      subnet_id                              = var.public_subnet_id
      load_balancer_backend_address_pool_ids = [azurerm_lb_backend_address_pool.main.id]
    }
  }

  tags = var.common_tags
}

# ── Outputs ───────────────────────────────────────────────────
output "load_balancer_public_ip" {
  description = "Public IP address of the load balancer — use this to access the application."
  value       = azurerm_public_ip.lb.ip_address
}
