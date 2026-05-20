# ============================================================
# modules/database/main.tf — Azure MySQL Flexible Server
# ============================================================

# ── Private DNS Zone ──────────────────────────────────────────
# MySQL Flexible Server with VNet integration requires a private DNS zone
# so VMs can resolve the server FQDN to its private IP address.
resource "azurerm_private_dns_zone" "mysql" {
  name                = "epicbook.mysql.database.azure.com"
  resource_group_name = var.resource_group_name
  tags                = var.common_tags
}

# ── DNS Zone — VNet Link ──────────────────────────────────────
# Links the private DNS zone to the VNet so all VMs in the VNet
# can resolve the MySQL hostname without going over the public internet.
resource "azurerm_private_dns_zone_virtual_network_link" "mysql" {
  name                  = "mysql-vnet-link"
  private_dns_zone_name = azurerm_private_dns_zone.mysql.name
  resource_group_name   = var.resource_group_name
  virtual_network_id    = var.virtual_network_id
  registration_enabled  = false   # false = only forward lookup, not auto-registration
}

# ── MySQL Flexible Server ─────────────────────────────────────
# Flexible Server provides more control over maintenance windows and
# backup retention than the older Single Server tier.
resource "azurerm_mysql_flexible_server" "main" {
  name                   = "mysql-epicbook-${random_id.suffix.hex}"  # globally unique name
  resource_group_name    = var.resource_group_name
  location               = var.location
  administrator_login    = var.db_admin_username   # supplied via TF_VAR_ env var
  administrator_password = var.db_admin_password   # supplied via TF_VAR_ env var
  sku_name               = var.db_sku
  version                = "8.0.21"

  # VNet integration — server gets a private IP, no public endpoint
  delegated_subnet_id    = var.private_subnet_id
  private_dns_zone_id    = azurerm_private_dns_zone.mysql.id

  backup_retention_days        = 7      # 7-day rolling backup window
  geo_redundant_backup_enabled = false  # set true in production multi-region deployments

  maintenance_window {
    day_of_week  = 0   # Sunday — minimise impact on weekday traffic
    start_hour   = 2   # 2am
    start_minute = 0
  }

  tags = var.common_tags

  depends_on = [azurerm_private_dns_zone_virtual_network_link.mysql]
}

# ── Database ──────────────────────────────────────────────────
# Creates the initial empty database inside the server.
resource "azurerm_mysql_flexible_database" "main" {
  name                = var.db_name
  resource_group_name = var.resource_group_name
  server_name         = azurerm_mysql_flexible_server.main.name
  charset             = "utf8mb4"     # full Unicode support including emoji
  collation           = "utf8mb4_unicode_ci"
}

# ── Random suffix ─────────────────────────────────────────────
# MySQL server names must be globally unique across all Azure customers.
# A short random suffix prevents naming collisions on re-deploy.
resource "random_id" "suffix" {
  byte_length = 4
}

# ── Outputs ───────────────────────────────────────────────────
output "mysql_fqdn" {
  description = "FQDN for the MySQL server — use as DB_HOST in your application config."
  value       = azurerm_mysql_flexible_server.main.fqdn
}

output "database_name" {
  description = "Name of the database created inside MySQL."
  value       = azurerm_mysql_flexible_database.main.name
}
