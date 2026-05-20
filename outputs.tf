# ============================================================
# outputs.tf — Values printed after  terraform apply  completes
# ============================================================
# Outputs serve two purposes:
#   1. Human-readable summary so the operator knows what was built.
#   2. Data sources for downstream modules or CI/CD pipelines.

output "resource_group_name" {
  description = "Name of the resource group — useful for az CLI commands after provisioning."
  value       = azurerm_resource_group.main.name
}

output "load_balancer_public_ip" {
  description = "Public IP of the Azure Load Balancer — the entry point for all HTTP/HTTPS traffic."
  value       = module.compute.load_balancer_public_ip
}

output "vnet_id" {
  description = "Resource ID of the Virtual Network — needed if peering with another VNet later."
  value       = module.network.vnet_id
}

output "public_subnet_id" {
  description = "Subnet ID of the public tier — useful for adding resources to the same subnet."
  value       = module.network.public_subnet_id
}

output "private_subnet_id" {
  description = "Subnet ID of the private tier — confirm database is NOT reachable from the internet."
  value       = module.network.private_subnet_id
}

output "mysql_fqdn" {
  description = "Fully-qualified domain name of the MySQL Flexible Server. Used by the app to connect."
  value       = module.database.mysql_fqdn
}

output "mysql_database_name" {
  description = "Name of the database created inside MySQL."
  value       = module.database.database_name
}
