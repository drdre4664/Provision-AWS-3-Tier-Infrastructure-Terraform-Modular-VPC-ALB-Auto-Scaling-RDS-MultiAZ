# ============================================================
# variables.tf — All input variables for the root module
# ============================================================
# Centralising variables here means every configurable value
# is visible in one place.  Descriptions are mandatory so that
# "terraform plan" output is self-documenting.

# ── Azure identity ────────────────────────────────────────────
variable "subscription_id" {
  description = "Azure Subscription ID. Supply via TF_VAR_subscription_id env var — never hardcode."
  type        = string
}

# ── Resource placement ────────────────────────────────────────
variable "resource_group_name" {
  description = "Name of the Azure Resource Group that will contain all resources."
  type        = string
  default     = "rg-epicbook-prod"
}

variable "location" {
  description = "Azure region for all resources. Keeping a single region reduces latency and egress costs."
  type        = string
  default     = "uksouth"
}

# ── Tagging strategy ──────────────────────────────────────────
# Tags enable cost attribution and make resources searchable in the portal.
variable "common_tags" {
  description = "Tags applied to every resource for cost tracking and ownership."
  type        = map(string)
  default = {
    project     = "epicbook"
    environment = "prod"
    managed_by  = "terraform"
  }
}

# ── Networking ────────────────────────────────────────────────
variable "vnet_address_space" {
  description = "CIDR block for the Virtual Network. /16 gives room for multiple subnets."
  type        = list(string)
  default     = ["10.0.0.0/16"]
}

variable "public_subnet_cidr" {
  description = "CIDR for the public subnet that hosts the load balancer and web tier."
  type        = string
  default     = "10.0.1.0/24"
}

variable "private_subnet_cidr" {
  description = "CIDR for the private subnet that hosts the database — no direct internet access."
  type        = string
  default     = "10.0.2.0/24"
}

# ── Compute ───────────────────────────────────────────────────
variable "vm_size" {
  description = "Azure VM SKU. Standard_B2s is sufficient for a dev/demo workload."
  type        = string
  default     = "Standard_B2s"
}

variable "vm_count" {
  description = "Number of VMs in the scale set. Set to 2 for minimal HA (one per availability zone)."
  type        = number
  default     = 2
}

variable "vm_admin_username" {
  description = "OS-level admin username for the VMs. No default — must be supplied explicitly."
  type        = string
  # No default intentionally: forces the operator to make a deliberate choice.
}

variable "ssh_public_key_path" {
  description = "Path to the local SSH public key file. The private key never leaves your machine."
  type        = string
  default     = "~/.ssh/id_rsa.pub"
}

# ── Database ──────────────────────────────────────────────────
variable "db_admin_username" {
  description = "Admin login for Azure MySQL Flexible Server. Supply via TF_VAR_db_admin_username."
  type        = string
  sensitive   = true   # marks value as sensitive so it is redacted in plan output
}

variable "db_admin_password" {
  description = "Admin password for MySQL. Supply via TF_VAR_db_admin_password — never commit to source control."
  type        = string
  sensitive   = true
}

variable "db_name" {
  description = "Name of the initial database to create inside MySQL."
  type        = string
  default     = "epicbook_db"
}

variable "db_sku" {
  description = "MySQL Flexible Server SKU. Burstable B-series is cost-effective for non-production workloads."
  type        = string
  default     = "B_Standard_B1ms"
}
