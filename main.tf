# ============================================================
# main.tf — Root module: wires together network, compute, database
# ============================================================
# Terraform reads all .tf files in a directory together.
# Keeping each logical group in its own module keeps this file
# short and each module independently testable.

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.90"   # pin minor version to avoid surprise breaking changes
    }
  }

  # Remote state keeps the .tfstate file out of this repo and allows
  # the whole team to share a single source of truth for infrastructure.
  backend "azurerm" {
    resource_group_name  = "rg-tfstate"
    storage_account_name = "<your-storage-account>"   # replace before first run
    container_name       = "tfstate"
    key                  = "hands-on/terraform.tfstate"
  }
}

provider "azurerm" {
  features {}
  # Credentials come from the environment — never hardcode them here.
  # Run: az login  OR  set ARM_CLIENT_ID / ARM_CLIENT_SECRET env vars.
  subscription_id = var.subscription_id
}

# ── Resource Group ────────────────────────────────────────────
# Everything lives in one resource group so we can tear it all
# down with a single  terraform destroy  without hunting for orphans.
resource "azurerm_resource_group" "main" {
  name     = var.resource_group_name
  location = var.location

  tags = var.common_tags
}

# ── Networking module ─────────────────────────────────────────
# Provisions VNet, public/private subnets, NSGs, and the NAT gateway.
# Outputs (vnet_id, subnet_ids, etc.) are consumed by the compute module.
module "network" {
  source = "./modules/network"

  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  vnet_address_space  = var.vnet_address_space
  public_subnet_cidr  = var.public_subnet_cidr
  private_subnet_cidr = var.private_subnet_cidr
  common_tags         = var.common_tags
}

# ── Compute module ────────────────────────────────────────────
# Provisions the VM Scale Set, Load Balancer, and managed disks.
# Depends on network outputs for subnet placement.
module "compute" {
  source = "./modules/compute"

  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  public_subnet_id    = module.network.public_subnet_id
  vm_size             = var.vm_size
  vm_count            = var.vm_count
  admin_username      = var.vm_admin_username   # value supplied via tfvars — no default
  ssh_public_key_path = var.ssh_public_key_path
  common_tags         = var.common_tags
}

# ── Database module ───────────────────────────────────────────
# Provisions Azure Database for MySQL Flexible Server.
# Placed on the private subnet — no public internet exposure.
module "database" {
  source = "./modules/database"

  resource_group_name  = azurerm_resource_group.main.name
  location             = azurerm_resource_group.main.location
  private_subnet_id    = module.network.private_subnet_id
  db_admin_username    = var.db_admin_username   # supplied via env var TF_VAR_db_admin_username
  db_admin_password    = var.db_admin_password   # supplied via env var TF_VAR_db_admin_password
  db_name              = var.db_name
  db_sku               = var.db_sku
  common_tags          = var.common_tags
}
