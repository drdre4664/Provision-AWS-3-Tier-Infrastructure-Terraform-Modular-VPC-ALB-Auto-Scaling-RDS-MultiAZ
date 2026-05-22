# Azure 3-Tier Infrastructure with Terraform (VNet, Load Balancer, VMs, MySQL Flexible Server)

> **Part 1 of 2 — Terraform Progression** · This repo demonstrates **single-cloud Azure depth** (VM Scale Sets, remote state in Azure Storage, NSG chaining, MySQL Flexible Server with VNet integration). For the multi-cloud, modular evolution of this architecture that runs the same design on both AWS and Azure, see [Terraform-MultiCloud-IaC-Modules-AWS-Azure-3-Tier](https://github.com/drdre4664/Terraform-MultiCloud-IaC-Modules-AWS-Azure-3-Tier).

## What This Project Does

This project provisions a complete, production-grade 3-tier web application infrastructure on Microsoft Azure using Terraform — entirely from code. No resources are created manually in the Azure Portal. Every component — the Resource Group, Virtual Network, subnets, Network Security Groups, Load Balancer, Virtual Machine Scale Set, and the MySQL Flexible Server — is defined as Terraform HCL and applied in a single run.

The architecture follows the principle of separation of concerns and least-privilege networking. The web tier sits behind a public Load Balancer. The data tier lives on a delegated private subnet that only the web tier can reach. The whole stack is grouped under one Resource Group so a single `terraform destroy` tears everything down with no orphaned resources.

The Terraform code is organised into three reusable modules — `network`, `compute`, and `database`. This reflects how real infrastructure teams structure Terraform codebases for maintainability and reuse.

## Architecture

```
                        Internet
                           │
                           ▼
                  [Public IP — Standard SKU]
                           │
                           ▼
                  [Azure Load Balancer]            <-- Standard SKU, /health probe every 15s
                           │
                           ▼
        [VM Scale Set — Ubuntu 22.04 LTS]
        Public Subnet · NSG allows port 80 from Internet
        Auto-registers into LB backend pool
                           │
                           ▼
        [Azure MySQL Flexible Server 8.0]
        Private Subnet · delegated to Microsoft.DBforMySQL/flexibleServers
        Private DNS zone linked to VNet — no public endpoint
```

| Tier      | Azure Resource                       | Subnet         |
| --------- | ------------------------------------ | -------------- |
| Edge      | Public IP + Standard Load Balancer   | n/a            |
| Web       | Linux VM Scale Set (Ubuntu 22.04)    | Public subnet  |
| Database  | MySQL Flexible Server 8.0            | Private subnet |

The web NSG only allows HTTP from the internet. The MySQL Flexible Server has no public endpoint at all — the VM Scale Set reaches it through the VNet via a private DNS zone, so traffic never touches the public internet.

## Project Structure

```
.
├── main.tf                       # Root module — wires network, compute, database together
├── variables.tf                  # Input variables — no hardcoded values
├── outputs.tf                    # Outputs — LB public IP, DB FQDN
├── terraform.tfvars.example      # Safe template — copy to terraform.tfvars locally
└── modules/
    ├── network/                  # VNet, public/private subnets, NSGs, NAT, DNS delegation
    ├── compute/                  # Public IP, Load Balancer, VMSS, health probe
    └── database/                 # Private DNS zone, VNet link, MySQL Flexible Server
```

Each module owns one concern. The network module can be evolved without touching compute or database, and each module can be reused in other projects.

## Terraform Configuration

### `main.tf` — Root module

The root module declares the provider, the remote state backend, and a single Resource Group that contains the entire deployment. It then calls each sub-module and passes outputs between them — Terraform resolves the dependency order automatically.

```hcl
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.90"
    }
  }

  # Remote state lives in Azure Storage so the whole team
  # shares a single source of truth and locks the state file
  # during apply.
  backend "azurerm" {
    resource_group_name  = "rg-tfstate"
    storage_account_name = "<your-storage-account>"
    container_name       = "tfstate"
    key                  = "hands-on/terraform.tfstate"
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

resource "azurerm_resource_group" "main" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.common_tags
}

module "network" {
  source              = "./modules/network"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  vnet_address_space  = var.vnet_address_space
  public_subnet_cidr  = var.public_subnet_cidr
  private_subnet_cidr = var.private_subnet_cidr
  common_tags         = var.common_tags
}

module "compute" {
  source              = "./modules/compute"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  public_subnet_id    = module.network.public_subnet_id
  vm_size             = var.vm_size
  vm_count            = var.vm_count
  admin_username      = var.vm_admin_username
  ssh_public_key_path = var.ssh_public_key_path
  common_tags         = var.common_tags
}

module "database" {
  source              = "./modules/database"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  private_subnet_id   = module.network.private_subnet_id
  vnet_id             = module.network.vnet_id
  db_admin_username   = var.db_admin_username   # sensitive — from env var
  db_admin_password   = var.db_admin_password   # sensitive — from env var
  db_sku              = var.db_sku
  common_tags         = var.common_tags
}
```

### `modules/network/main.tf` — VNet, subnets, NSGs, subnet delegation

The network module is the foundation. Two subnets are carved out of one VNet. The private subnet is **delegated** to MySQL Flexible Server, which is what unlocks VNet integration.

```hcl
resource "azurerm_virtual_network" "main" {
  name                = "vnet-${var.resource_group_name}"
  resource_group_name = var.resource_group_name
  location            = var.location
  address_space       = var.vnet_address_space
  tags                = var.common_tags
}

# Public subnet — hosts the Load Balancer frontend and the VMSS instances
resource "azurerm_subnet" "public" {
  name                 = "snet-public"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.public_subnet_cidr]
  service_endpoints    = ["Microsoft.Storage"]
}

# Private subnet — hosts MySQL Flexible Server.
# Subnet delegation is REQUIRED for Flexible Server VNet integration.
resource "azurerm_subnet" "private" {
  name                 = "snet-private"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.private_subnet_cidr]
  service_endpoints    = ["Microsoft.Sql"]

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

# NSG for the web tier — explicit allow-list, default deny
resource "azurerm_network_security_group" "web" {
  name                = "nsg-web"
  resource_group_name = var.resource_group_name
  location            = var.location

  security_rule {
    name                       = "allow-http-in"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }
}
```

### `modules/compute/main.tf` — Public Load Balancer + VM Scale Set

A Standard-SKU Load Balancer fronts a Linux VM Scale Set. The LB's health probe hits `/health` on every VM every 15 seconds; two consecutive failures remove a VM from rotation.

```hcl
resource "azurerm_public_ip" "lb" {
  name                = "pip-lb"
  resource_group_name = var.resource_group_name
  location            = var.location
  allocation_method   = "Static"   # IP must not change on reboot — DNS A-record stability
  sku                 = "Standard" # Standard SKU is mandatory for zone-redundant LB
  tags                = var.common_tags
}

resource "azurerm_lb" "main" {
  name                = "lb-epicbook"
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = "Standard"

  frontend_ip_configuration {
    name                 = "lb-frontend"
    public_ip_address_id = azurerm_public_ip.lb.id
  }
}

resource "azurerm_lb_backend_address_pool" "main" {
  loadbalancer_id = azurerm_lb.main.id
  name            = "lb-backend-pool"
}

resource "azurerm_lb_probe" "http" {
  loadbalancer_id     = azurerm_lb.main.id
  name                = "probe-http"
  protocol            = "Http"
  port                = 80
  request_path        = "/health"   # the app must return 200 OK at this path
  interval_in_seconds = 15
  number_of_probes    = 2
}

resource "azurerm_linux_virtual_machine_scale_set" "main" {
  name                = "vmss-web"
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = var.vm_size
  instances           = var.vm_count

  admin_username                  = var.admin_username
  disable_password_authentication = true   # SSH keys only — no passwords on the boundary

  admin_ssh_key {
    username   = var.admin_username
    public_key = file(var.ssh_public_key_path)
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"     # auto-pick latest patch for security fixes
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
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
}
```

### `modules/database/main.tf` — MySQL Flexible Server with VNet integration

MySQL Flexible Server with VNet integration needs a **private DNS zone** linked to the VNet so VMs can resolve the server FQDN to its private IP. Without that link, the VMs cannot find the database.

```hcl
resource "azurerm_private_dns_zone" "mysql" {
  name                = "epicbook.mysql.database.azure.com"
  resource_group_name = var.resource_group_name
}

resource "azurerm_private_dns_zone_virtual_network_link" "mysql" {
  name                  = "mysql-vnet-link"
  private_dns_zone_name = azurerm_private_dns_zone.mysql.name
  resource_group_name   = var.resource_group_name
  virtual_network_id    = var.vnet_id
}

resource "azurerm_mysql_flexible_server" "main" {
  name                   = "mysql-epicbook"
  resource_group_name    = var.resource_group_name
  location               = var.location
  administrator_login    = var.db_admin_username   # supplied via TF_VAR_ env var
  administrator_password = var.db_admin_password   # supplied via TF_VAR_ env var
  sku_name               = var.db_sku
  version                = "8.0.21"

  delegated_subnet_id = var.private_subnet_id
  private_dns_zone_id = azurerm_private_dns_zone.mysql.id

  backup_retention_days        = 7
  geo_redundant_backup_enabled = false

  maintenance_window {
    day_of_week  = 0   # Sunday
    start_hour   = 2   # 2am
    start_minute = 0
  }

  depends_on = [azurerm_private_dns_zone_virtual_network_link.mysql]
}
```

## Step-by-Step Deployment

### Step 1 — Bootstrap the remote state backend
Terraform needs a place to store its state file before it can run. Create the Resource Group, Storage Account, and Container that the `backend "azurerm"` block in `main.tf` points to. This is a one-time setup per environment.

```bash
az group create --name rg-tfstate --location uksouth
az storage account create --name <your-storage-account> --resource-group rg-tfstate --sku Standard_LRS
az storage container create --name tfstate --account-name <your-storage-account>
```

### Step 2 — Authenticate to Azure
Terraform reads Azure credentials from the environment. The simplest path is `az login`; for CI use a Service Principal via `ARM_CLIENT_ID` / `ARM_CLIENT_SECRET` / `ARM_TENANT_ID`.

```bash
az login
az account set --subscription "<your-subscription-id>"
```

### Step 3 — Provide sensitive variables via environment
Secrets never go in `terraform.tfvars`. Export them as `TF_VAR_*` env vars so they live only in the shell session.

```bash
export TF_VAR_subscription_id="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
export TF_VAR_db_admin_username="<your-db-admin-user>"
export TF_VAR_db_admin_password="<your-strong-password>"
```

### Step 4 — Set up your tfvars file
Copy the template and fill in the non-sensitive values (region, sizing, tags, SSH key path).

```bash
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars
```

### Step 5 — Initialise Terraform
`terraform init` downloads the `azurerm` provider and configures the remote state backend. Run this once before any other Terraform command.

```bash
terraform init
```

### Step 6 — Preview the execution plan
Always read the plan before applying. It shows exactly what will be created, modified, or destroyed — no surprises.

```bash
terraform plan
```

### Step 7 — Apply the infrastructure
Terraform creates resources in dependency order — the VNet before the subnets, the DNS zone before MySQL, etc.

```bash
terraform apply
```

### Step 8 — Retrieve and verify outputs

```bash
terraform output load_balancer_public_ip
terraform output mysql_fqdn

# Confirm the LB is serving traffic
curl -I http://$(terraform output -raw load_balancer_public_ip)/health
# Expected: HTTP/1.1 200 OK
```

### Step 9 — Destroy when done
Tear down everything in reverse dependency order. Always destroy after testing — VMSS, MySQL Flexible Server, and the Standard LB are the most expensive resources here.

```bash
terraform destroy
```

## What I Learned

**Modular Terraform is the production standard.** Each module (network, compute, database) can be developed, tested, and reused independently. The root `main.tf` reads like a blueprint — three module calls — and the implementation details stay inside each module.

**Remote state in Azure Storage enables team collaboration and locking.** Without it, two people running Terraform at the same time would corrupt the state file. The Storage Account's blob lease provides the locking mechanism for free.

**Subnet delegation is non-obvious but mandatory.** MySQL Flexible Server with VNet integration only works if the private subnet is delegated to `Microsoft.DBforMySQL/flexibleServers`. Forgetting this turns into a confusing apply-time error.

**Private DNS zone + VNet link is what makes the database reachable.** Even with VNet integration, VMs cannot resolve the MySQL FQDN without a private DNS zone linked to the VNet. The `depends_on` between the server and the link makes the ordering explicit.

**`sensitive = true` on password variables prevents Terraform from ever printing their values** in plan or apply output. Passing them via `TF_VAR_*` env vars instead of `tfvars` keeps them out of any committed file.

**One Resource Group for one environment makes `terraform destroy` reliable.** Every resource in this project lives under one Resource Group, so destroy never leaves orphans.

## Tools Used

Terraform · Azure VNet · Subnet Delegation · NSG · Public IP · Standard Load Balancer · Linux VM Scale Set · MySQL Flexible Server · Private DNS Zone · Azure Storage (remote state) · Azure CLI
