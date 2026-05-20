# Project 06 — Terraform IaaC: AWS 3-Tier Architecture with High Availability

## What This Project Does

This project provisions a complete, production-grade 3-tier web application infrastructure on AWS using Terraform — entirely from code. No resources are created manually in the AWS Console. Every component — the VPC, subnets, security groups, load balancers, EC2 auto scaling groups, and a Multi-AZ RDS database — is defined as Terraform HCL code and applied in a single run.

The architecture is split into three tiers following the principle of separation of concerns and least-privilege networking. The web tier faces the internet. The application tier is in private subnets with no public IP. The database tier is in isolated DB subnets that only the application tier can reach. This structure is the standard for any production AWS deployment.

The Terraform code is organised into **modules** — separate, reusable units for network, compute, and database. This reflects how real infrastructure teams structure Terraform codebases for maintainability and reuse.

## Architecture

```
Internet
    |
[Internet Gateway]
    |
[Public ALB]  ← accepts traffic from anywhere on port 80
    |
[Web Tier — EC2 in Public Subnets AZ-1 & AZ-2]
    Security Group: allows port 80 FROM Public ALB only
    |
[Internal ALB]  ← accepts traffic from Web Tier only
    |
[App Tier — EC2 in Private Subnets AZ-1 & AZ-2]
    Security Group: allows port 3000 FROM Internal ALB only
    No public IP — only reachable via the internal load balancer
    |
[RDS MySQL — DB Subnets AZ-1 & AZ-2]
    Multi-AZ: primary in AZ-1, automatic standby in AZ-2
    Read Replica: separate instance for read-heavy query scaling
    Security Group: allows port 3306 FROM App Tier ONLY
```

Each security group only allows traffic from the one tier directly above it. This means a compromised web server cannot directly access the database — it can only call the internal load balancer, which can only forward to the app tier.

---

## Project Structure

```
06-terraform-iaac/
├── main.tf                    # Root module — assembles all sub-modules
├── variables.tf               # Input variables — no hardcoded values
├── outputs.tf                 # Outputs — ALB DNS, DB endpoint etc.
├── terraform.tfvars.example   # Safe template — copy to terraform.tfvars locally
└── modules/
    ├── network/               # VPC, subnets, route tables, security groups, NAT
    ├── compute/               # ALBs, launch templates, auto scaling groups
    └── database/              # RDS subnet group, primary instance, read replica
```

Splitting into modules means each concern is isolated. The network module can be updated without touching the compute or database module, and each module can be reused in other projects.

---

## Terraform Configuration

### main.tf — Root Module

The root module is the entry point. It calls each sub-module and passes variables between them. Notice how the network module's outputs (like `vpc_id`) are passed directly into the compute and database modules — Terraform resolves these dependencies automatically.

```hcl
terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
  backend "s3" {
    # Remote state: Terraform stores its state file in S3 instead of locally.
    # This allows multiple team members to work on the same infrastructure
    # without state conflicts, and prevents state loss if a laptop dies.
    bucket = "your-terraform-state-bucket"
    key    = "prod/3tier/terraform.tfstate"
    region = "us-east-1"
  }
}

provider "aws" { region = var.aws_region }

module "network" {
  source             = "./modules/network"
  vpc_cidr           = var.vpc_cidr
  public_subnets     = var.public_subnets
  private_subnets    = var.private_subnets
  db_subnets         = var.db_subnets
  availability_zones = var.availability_zones
  project_name       = var.project_name
}

module "compute" {
  source             = "./modules/compute"
  vpc_id             = module.network.vpc_id       # output from network module
  public_subnet_ids  = module.network.public_subnet_ids
  private_subnet_ids = module.network.private_subnet_ids
  web_instance_type  = var.web_instance_type
  app_instance_type  = var.app_instance_type
  ami_id             = var.ami_id
  key_name           = var.key_name
  project_name       = var.project_name
  web_min_size       = var.web_min_size
  web_max_size       = var.web_max_size
  app_min_size       = var.app_min_size
  app_max_size       = var.app_max_size
}

module "database" {
  source            = "./modules/database"
  vpc_id            = module.network.vpc_id
  db_subnet_ids     = module.network.db_subnet_ids
  app_sg_id         = module.compute.app_sg_id     # DB only allows this SG
  db_name           = var.db_name
  db_username       = var.db_username
  db_password       = var.db_password              # sensitive variable — never logged
  db_instance_class = var.db_instance_class
  project_name      = var.project_name
}
```

### modules/network/main.tf — VPC and Security Groups

```hcl
# The VPC is the private network container for all our resources
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags = { Name = "${var.project_name}-vpc" }
}

# Internet Gateway: the door between our VPC and the public internet
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.project_name}-igw" }
}

# Public subnets: where web tier EC2 instances live — have routes to the internet
resource "aws_subnet" "public" {
  count                   = length(var.public_subnets)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnets[count.index]
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = true
  tags = { Name = "${var.project_name}-public-${count.index + 1}" }
}

# Private subnets: where app tier EC2 instances live — no direct internet route
resource "aws_subnet" "private" {
  count             = length(var.private_subnets)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnets[count.index]
  availability_zone = var.availability_zones[count.index]
  tags = { Name = "${var.project_name}-private-${count.index + 1}" }
}

# DB subnets: the most isolated tier — only accepts traffic on port 3306 from app SG
resource "aws_subnet" "db" {
  count             = length(var.db_subnets)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.db_subnets[count.index]
  availability_zone = var.availability_zones[count.index]
  tags = { Name = "${var.project_name}-db-${count.index + 1}" }
}

# NAT Gateway: lets private subnet instances (app tier) reach the internet
# for package downloads etc., without being reachable from the internet themselves
resource "aws_eip" "nat" { domain = "vpc" }

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
  tags          = { Name = "${var.project_name}-nat" }
}

# Security Groups: the firewall rules for each tier
# Each tier ONLY accepts traffic from its direct upstream source

resource "aws_security_group" "alb" {
  # Public ALB: accepts HTTP from the entire internet
  name   = "${var.project_name}-alb-sg"
  vpc_id = aws_vpc.main.id
  ingress { from_port = 80; to_port = 80; protocol = "tcp"; cidr_blocks = ["0.0.0.0/0"] }
  egress  { from_port = 0;  to_port = 0;  protocol = "-1"; cidr_blocks = ["0.0.0.0/0"] }
}

resource "aws_security_group" "web" {
  # Web Tier: ONLY accepts traffic from the public ALB security group
  name   = "${var.project_name}-web-sg"
  vpc_id = aws_vpc.main.id
  ingress { from_port = 80; to_port = 80; protocol = "tcp"; security_groups = [aws_security_group.alb.id] }
  egress  { from_port = 0;  to_port = 0;  protocol = "-1"; cidr_blocks = ["0.0.0.0/0"] }
}

resource "aws_security_group" "internal_alb" {
  # Internal ALB: ONLY accepts traffic from the web tier
  name   = "${var.project_name}-internal-alb-sg"
  vpc_id = aws_vpc.main.id
  ingress { from_port = 80; to_port = 80; protocol = "tcp"; security_groups = [aws_security_group.web.id] }
  egress  { from_port = 0;  to_port = 0;  protocol = "-1"; cidr_blocks = ["0.0.0.0/0"] }
}

resource "aws_security_group" "app" {
  # App Tier: ONLY accepts traffic from the internal ALB
  name   = "${var.project_name}-app-sg"
  vpc_id = aws_vpc.main.id
  ingress { from_port = 3000; to_port = 3000; protocol = "tcp"; security_groups = [aws_security_group.internal_alb.id] }
  egress  { from_port = 0;    to_port = 0;    protocol = "-1"; cidr_blocks = ["0.0.0.0/0"] }
}

resource "aws_security_group" "db" {
  # Database Tier: ONLY accepts MySQL traffic from the app tier security group
  name   = "${var.project_name}-db-sg"
  vpc_id = aws_vpc.main.id
  ingress { from_port = 3306; to_port = 3306; protocol = "tcp"; security_groups = [aws_security_group.app.id] }
  # No egress rule needed — RDS initiates no outbound connections
}
```

### modules/database/main.tf — RDS Multi-AZ

```hcl
resource "aws_db_subnet_group" "main" {
  # A DB subnet group tells RDS which subnets it can place instances in.
  # Using subnets in two AZs is required for Multi-AZ deployments.
  name       = "${var.project_name}-db-subnet-group"
  subnet_ids = var.db_subnet_ids
}

resource "aws_db_instance" "primary" {
  identifier             = "${var.project_name}-db-primary"
  engine                 = "mysql"
  engine_version         = "8.0"
  instance_class         = var.db_instance_class
  db_name                = var.db_name
  username               = var.db_username  # from sensitive variable — never hardcoded
  password               = var.db_password  # from sensitive variable — never logged
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [var.db_sg_id]
  multi_az               = true   # RDS creates a synchronous standby in the second AZ.
                                  # If the primary fails, AWS fails over automatically.
  storage_type           = "gp3"
  allocated_storage      = 20
  skip_final_snapshot    = false  # always take a final snapshot before destroy
  final_snapshot_identifier = "${var.project_name}-final-snapshot"
  backup_retention_period   = 7   # 7 days of automated backups
}

resource "aws_db_instance" "replica" {
  # Read replica: a separate, asynchronously replicated instance.
  # Offload read-heavy queries here to reduce load on the primary.
  identifier          = "${var.project_name}-db-replica"
  replicate_source_db = aws_db_instance.primary.identifier
  instance_class      = var.db_instance_class
  skip_final_snapshot = true
}
```

### variables.tf

```hcl
variable "aws_region"         { default = "us-east-1" }
variable "project_name"       { default = "3tier-ha" }
variable "vpc_cidr"           { default = "10.0.0.0/16" }
variable "public_subnets"     { default = ["10.0.1.0/24", "10.0.2.0/24"] }
variable "private_subnets"    { default = ["10.0.3.0/24", "10.0.4.0/24"] }
variable "db_subnets"         { default = ["10.0.5.0/24", "10.0.6.0/24"] }
variable "availability_zones" { default = ["us-east-1a", "us-east-1b"] }
variable "ami_id"             { default = "ami-0c02fb55956c7d316" }
variable "key_name"           { description = "Name of your EC2 key pair" }
variable "web_instance_type"  { default = "t3.micro" }
variable "app_instance_type"  { default = "t3.micro" }
variable "db_instance_class"  { default = "db.t3.micro" }
variable "db_name"            { description = "Database name" }
variable "db_username"        { description = "Database admin username" }
variable "db_password"        { description = "Database admin password"; sensitive = true }
variable "web_min_size"       { default = 2 }
variable "web_max_size"       { default = 4 }
variable "app_min_size"       { default = 2 }
variable "app_max_size"       { default = 4 }
```

---

## Step-by-Step Deployment

### Step 1 — Set up your variables file

**Why:** Terraform requires values for variables that have no defaults (like `key_name`, `db_password`). The `terraform.tfvars` file is the local source for these values. It is listed in `.gitignore` and is never committed to source control.

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your own values
```

### Step 2 — Initialise Terraform

**Why:** `terraform init` downloads the AWS provider plugin and configures the S3 remote backend. This must be run once before any other Terraform command.

```bash
terraform init
```

### Step 3 — Preview the execution plan

**Why:** `terraform plan` shows exactly what Terraform will create, modify, or destroy — without actually doing anything. Always review this output before applying. It is your safety check.

```bash
terraform plan
```

### Step 4 — Apply the infrastructure

**Why:** `terraform apply` executes the plan. Terraform creates all resources in the correct dependency order — it knows the VPC must exist before subnets, subnets before instances, etc.

```bash
terraform apply
```

### Step 5 — Retrieve and verify outputs

**Why:** After apply completes, you can retrieve the DNS name of the public ALB and the RDS endpoint from Terraform outputs.

```bash
terraform output public_alb_dns
terraform output db_endpoint

# Verify the load balancer health checks are passing
curl -I http://$(terraform output -raw public_alb_dns)/health
# Expected: HTTP/1.1 200 OK
```

### Step 6 — Destroy when done

```bash
terraform destroy
# Terraform tears down every resource it created, in reverse dependency order
```

---

## What I Learned

- **Modular Terraform** is the production standard. Each module (network, compute, database) can be developed, tested, and reused independently.
- **Remote S3 state** enables team collaboration. Without it, two people running Terraform simultaneously would corrupt the state file.
- **Multi-AZ RDS** provides automatic failover — if the primary database fails, AWS promotes the standby in under two minutes with no manual intervention.
- **Security Groups as sources** (instead of CIDR blocks) is the correct pattern for inter-tier rules. It is more secure and more maintainable: if an IP changes, the rule still works because it references the SG, not the IP.
- **`sensitive = true`** on password variables prevents Terraform from ever printing their values in plan or apply output — a critical safeguard.

---

**Tools Used:** Terraform · AWS VPC · EC2 · Application Load Balancer · Auto Scaling · RDS MySQL · S3 · IAM
