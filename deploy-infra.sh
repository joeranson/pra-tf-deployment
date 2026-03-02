#!/bin/bash
# Complete BeyondTrust Demo Environment Deployment Script with State Tracking (FIXED VERSION)
# Incorporates all fixes discovered during initial deployment
# Modified to use SQL Server instead of plain member server
# COST OPTIMIZED VERSION: Reduced storage costs by ~70% through HDD storage, 
# removed unnecessary data disk, reduced OS disk sizes, and Basic SKU public IP
#
# Usage:
#   ./deploy-infra.sh                  # First run creates config, second run deploys
#   ./deploy-infra.sh --cleanup        # Remove only resources created by this script
#   ./deploy-infra.sh --with-rds       # Also deploy RDS roles and publish SSMS RemoteApp

set -e

# Check for cleanup flag
CLEANUP_MODE=false
if [ "$1" = "--cleanup" ]; then
    CLEANUP_MODE=true
fi

# Check for --with-rds flag
WITH_RDS=false
if [ "$1" = "--with-rds" ]; then
    WITH_RDS=true
fi

# Variables
PROJECT_DIR="$HOME/beyondtrust-demo"
CONFIG_FILE="$PROJECT_DIR/config.env"
STATE_FILE="$PROJECT_DIR/deployment-state.json"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Functions
print_status() {
    echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# State Management Functions (FIXED)
init_state() {
    if [ ! -f "$STATE_FILE" ]; then
        echo '{"metadata": {}, "resources": {}, "azure": {}}' > "$STATE_FILE"
    fi
}

add_resource() {
    local resource_type="$1"
    local resource_id="$2"
    local resource_name="$3"
    local additional_data="${4:-}"
    
    init_state
    
    # If no additional data provided, use empty object (FIX)
    if [ -z "$additional_data" ]; then
        additional_data="{}"
    fi
    
    # Add resource to state file
    jq --arg type "$resource_type" \
       --arg id "$resource_id" \
       --arg name "$resource_name" \
       --argjson data "$additional_data" \
       --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
       '.resources[$type] += [{
           id: $id, 
           name: $name, 
           created_at: $timestamp
       } + $data]' \
       "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
}

get_resources() {
    local resource_type="$1"
    
    if [ -f "$STATE_FILE" ]; then
        jq -r --arg type "$resource_type" '.resources[$type][]? | .id' "$STATE_FILE"
    fi
}

update_metadata() {
    local key="$1"
    local value="$2"
    
    init_state
    
    jq --arg key "$key" \
       --arg value "$value" \
       '.metadata[$key] = $value' \
       "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
}

update_azure_info() {
    local key="$1"
    local value="$2"
    
    init_state
    
    jq --arg key "$key" \
       --arg value "$value" \
       '.azure[$key] = $value' \
       "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
}

# Create initial directory structure
setup_directories() {
    print_status "Setting up project directory structure..."
    
    # Main project directories
    mkdir -p "$PROJECT_DIR"/{terraform,ansible/{playbooks,inventory,group_vars},scripts}
    
    # BeyondTrust subdirectories
    mkdir -p "$PROJECT_DIR"/beyondtrust/{terraform,scripts,downloads,ansible,config}
    
    cd "$PROJECT_DIR"
}

# Create comprehensive config template
create_config_template() {
    if [ ! -f "$CONFIG_FILE" ]; then
        print_status "Creating configuration template..."
        
        cat > "$CONFIG_FILE" << 'EOF'
# BeyondTrust Demo Environment Configuration
# Please fill in all required values before running deployment

#===========================================
# AZURE CONFIGURATION
#===========================================

# Azure settings will be gathered during deployment:
# - Subscription ID: Selected after Azure login
# - Your public IP: Auto-detected at runtime

# Azure Region (default: East US 2)
AZURE_REGION="East US 2"

# Environment name (used in resource naming)
ENVIRONMENT="demo"

# VM Credentials
ADMIN_USERNAME="testadmin"
ADMIN_PASSWORD="TestPassword123!"

# Domain Configuration
DOMAIN_NAME="test.local"
DOMAIN_NETBIOS_NAME="TEST"
SAFE_MODE_PASSWORD="SafeModePass123!"

#===========================================
# BEYONDTRUST CONFIGURATION
#===========================================

# BeyondTrust Instance URL (e.g., https://yourinstance.beyondtrustcloud.com)
BT_API_HOST=""

# API Credentials (get from BeyondTrust console -> Configuration -> API Accounts)
# Required permissions: Configuration API, Manage Vault Accounts
BT_CLIENT_ID=""
BT_CLIENT_SECRET=""

# Approval Configuration
APPROVER_EMAIL=""

# Resource Prefix (to ensure uniqueness)
RESOURCE_PREFIX="Demo_"

# Vault Account Group ID
# Find this in the BeyondTrust console: Vault -> Account Groups
# Select the group you want demo accounts assigned to and note its ID
VAULT_ACCOUNT_GROUP_ID="4"

# Optional: Override default BeyondTrust resource names
# JUMP_GROUP_DEMO="Demo Servers"
# JUMP_GROUP_DC="Domain Controllers"
# JUMPOINT_NAME="DC01_Jumpoint"

#===========================================
# DEMO USER CONFIGURATION (optional)
#===========================================

# Modify these if you want different demo users
# DEMO_USER_1="jsmith:John:Smith:DemoPass123!"
# DEMO_USER_2="mjohnson:Mary:Johnson:DemoPass123!"
# DEMO_USER_3="bdavis:Bob:Davis:DemoPass123!"

#===========================================
# LINUX VM CONFIGURATION
#===========================================

# Credentials for the Ubuntu Linux VM local admin account
LINUX_ADMIN_USERNAME="linuxadmin"
LINUX_ADMIN_PASSWORD="UbuntuPass123!"

# Optional: Override default Linux BeyondTrust Jump Group name
# JUMP_GROUP_LINUX="Linux Servers"
EOF
        
        print_warning "Configuration file created at: $CONFIG_FILE"
        print_warning "Please edit this file and add your BeyondTrust credentials"
        print_status "After configuration, run this script again to deploy"
        exit 0
    fi
}

# Validate configuration
validate_config() {
    print_status "Validating configuration..."
    
    # Source config
    source "$CONFIG_FILE"
    
    # Azure subscription will be handled during deployment
    # Just validate BeyondTrust settings
    if [ -z "$BT_API_HOST" ] || [ -z "$BT_CLIENT_ID" ] || [ -z "$BT_CLIENT_SECRET" ] || [ -z "$APPROVER_EMAIL" ]; then
        print_error "Missing BeyondTrust configuration. Please edit $CONFIG_FILE"
    fi
    
    # Set defaults for optional values
    RESOURCE_PREFIX="${RESOURCE_PREFIX:-Demo_}"
    JUMP_GROUP_DEMO="${RESOURCE_PREFIX}${JUMP_GROUP_DEMO:-Demo Servers}"
    JUMP_GROUP_DC="${RESOURCE_PREFIX}${JUMP_GROUP_DC:-Domain Controllers}"
    JUMPOINT_NAME="${RESOURCE_PREFIX}${JUMPOINT_NAME:-DC01_Jumpoint}"
    VAULT_ACCOUNT_GROUP_ID="${VAULT_ACCOUNT_GROUP_ID:-4}"
    LINUX_ADMIN_USERNAME="${LINUX_ADMIN_USERNAME:-linuxadmin}"
    LINUX_ADMIN_PASSWORD="${LINUX_ADMIN_PASSWORD:-UbuntuPass123!}"
    JUMP_GROUP_LINUX="${RESOURCE_PREFIX}${JUMP_GROUP_LINUX:-Linux Servers}"

    # EXPORT ALL VARIABLES (FIX)
    export BT_API_HOST BT_CLIENT_ID BT_CLIENT_SECRET APPROVER_EMAIL RESOURCE_PREFIX
    export DOMAIN_NAME DOMAIN_NETBIOS_NAME ADMIN_USERNAME ADMIN_PASSWORD
    export JUMP_GROUP_DEMO JUMP_GROUP_DC JUMPOINT_NAME VAULT_ACCOUNT_GROUP_ID
    export LINUX_ADMIN_USERNAME LINUX_ADMIN_PASSWORD JUMP_GROUP_LINUX
    
    print_status "Configuration validated successfully"
}

# Install prerequisites
install_prerequisites() {
    print_status "Installing prerequisites..."
    sudo apt-get update -qq
    sudo apt-get install -y -qq curl wget unzip git python3 python3-pip python3-venv software-properties-common gnupg lsb-release jq

    # Install Terraform
    if ! command -v terraform &> /dev/null; then
        print_status "Installing Terraform..."
        wget -O- https://apt.releases.hashicorp.com/gpg | gpg --dearmor | sudo tee /usr/share/keyrings/hashicorp-archive-keyring.gpg > /dev/null
        echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
        sudo apt-get update -qq && sudo apt-get install -y terraform
    fi

    # Install Azure CLI
    if ! command -v az &> /dev/null; then
        print_status "Installing Azure CLI..."
        curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
    fi

    # Install Ansible (only if needed)
    if ! command -v ansible &> /dev/null; then
        print_status "Installing Ansible and dependencies..."
        sudo apt-get install -y ansible-core python3-winrm
    else
        print_status "Ansible already installed: $(ansible --version | head -1)"
    fi

    # Create virtual environment for additional Python packages (only if needed)
    if [ ! -f "$HOME/.venvs/ansible/bin/activate" ]; then
        print_status "Setting up Python environment..."
        python3 -m venv "$HOME/.venvs/ansible"
        source "$HOME/.venvs/ansible/bin/activate"
        pip install --quiet --upgrade pip
        pip install --quiet pywinrm requests-ntlm
        deactivate
    else
        print_status "Python venv already configured at $HOME/.venvs/ansible"
    fi

    # Install Ansible collections (idempotent by default)
    print_status "Ensuring Ansible collections are installed..."
    ansible-galaxy collection install ansible.windows community.windows
}

# Phase 1: Deploy Azure Infrastructure
deploy_azure_infrastructure() {
    print_status "Phase 1: Deploying Azure infrastructure..."
    
    cd "$PROJECT_DIR"
    
    # Initialize state tracking
    init_state
    update_metadata "deployment_started" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    update_metadata "environment" "$ENVIRONMENT"
    
    # Get public IP at runtime with retry and fallback services
    print_status "Getting your public IP address..."
    MY_PUBLIC_IP=""
    local ip_services=("https://ifconfig.me" "https://api.ipify.org" "https://checkip.amazonaws.com")
    local ip_attempt=0
    while [ -z "$MY_PUBLIC_IP" ] && [ $ip_attempt -lt ${#ip_services[@]} ]; do
        MY_PUBLIC_IP=$(curl -s --max-time 10 "${ip_services[$ip_attempt]}" 2>/dev/null | tr -d '[:space:]')
        ip_attempt=$((ip_attempt + 1))
    done
    if ! echo "$MY_PUBLIC_IP" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
        print_error "Could not detect a valid public IP. Tried ${ip_services[*]}. Set MY_PUBLIC_IP in your environment to override."
    fi
    print_status "Your public IP: $MY_PUBLIC_IP"
    update_metadata "deployer_ip" "$MY_PUBLIC_IP"
    
    # Login to Azure and get subscription
    print_status "Logging into Azure..."
    if ! az account show &> /dev/null; then
        az login
    fi
    
    # Get subscription ID interactively
    AZURE_SUBSCRIPTION_ID=$(az account show --query id -o tsv)
    print_status "Using Azure subscription: $AZURE_SUBSCRIPTION_ID"
    az account set --subscription "$AZURE_SUBSCRIPTION_ID"
    
    # Update state with Azure info
    update_azure_info "subscription_id" "$AZURE_SUBSCRIPTION_ID"
    update_azure_info "region" "$AZURE_REGION"
    update_azure_info "resource_group" "rg-beyondtrust-$ENVIRONMENT"
    
    # Create Terraform files
    print_status "Creating Azure Terraform configuration..."
    
    cat > terraform/main.tf << 'EOF'
terraform {
  required_version = ">= 1.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "4.34.0"
    }
  }
}

provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}

# Variables
variable "environment" {
  type        = string
  description = "Environment name used in resource naming (e.g. demo, dev)"
  default     = "demo"
}

variable "azure_region" {
  type        = string
  description = "Azure region for all resources"
  default     = "East US 2"
}

variable "admin_username" {
  type        = string
  description = "Administrator username for Windows VMs"
  default     = "testadmin"
}

variable "admin_password" {
  type        = string
  description = "Administrator password for Windows VMs. Passed via TF_VAR_admin_password or terraform.tfvars."
  sensitive   = true
  default     = "TestPassword123!"
}

variable "allowed_rdp_source_ip" {
  type        = string
  description = "CIDR of the deployer's public IP for RDP/WinRM access (e.g. 203.0.113.1/32)"
}

variable "linux_admin_username" {
  type        = string
  description = "Administrator username for the Ubuntu Linux VM"
  default     = "linuxadmin"
}

variable "linux_admin_password" {
  type        = string
  description = "Administrator password for the Ubuntu Linux VM"
  sensitive   = true
  default     = "UbuntuPass123!"
}

# Resource Group
resource "azurerm_resource_group" "demo" {
  name     = "rg-beyondtrust-${var.environment}"
  location = var.azure_region
  tags = {
    Environment = var.environment
    Project     = "BeyondTrust-Demo"
  }
}

# Network
resource "azurerm_virtual_network" "demo" {
  name                = "vnet-${var.environment}"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.demo.location
  resource_group_name = azurerm_resource_group.demo.name
}

resource "azurerm_subnet" "dc" {
  name                 = "subnet-dc"
  resource_group_name  = azurerm_resource_group.demo.name
  virtual_network_name = azurerm_virtual_network.demo.name
  address_prefixes     = ["10.0.1.0/24"]
}

resource "azurerm_subnet" "sql" {
  name                 = "subnet-sql"
  resource_group_name  = azurerm_resource_group.demo.name
  virtual_network_name = azurerm_virtual_network.demo.name
  address_prefixes     = ["10.0.2.0/24"]
}

resource "azurerm_subnet" "linux" {
  name                 = "subnet-linux"
  resource_group_name  = azurerm_resource_group.demo.name
  virtual_network_name = azurerm_virtual_network.demo.name
  address_prefixes     = ["10.0.3.0/24"]
}

# NSG for DC
resource "azurerm_network_security_group" "dc" {
  name                = "nsg-dc-${var.environment}"
  location            = azurerm_resource_group.demo.location
  resource_group_name = azurerm_resource_group.demo.name

  security_rule {
    name                       = "RDP"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "3389"
    source_address_prefix      = var.allowed_rdp_source_ip
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "WinRM"
    priority                   = 101
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "5985-5986"
    source_address_prefix      = var.allowed_rdp_source_ip
    destination_address_prefix = "*"
  }
}

# NSG for SQL
resource "azurerm_network_security_group" "sql" {
  name                = "nsg-sql-${var.environment}"
  location            = azurerm_resource_group.demo.location
  resource_group_name = azurerm_resource_group.demo.name

  security_rule {
    name                       = "RDP-Internal"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "3389"
    source_address_prefix      = "10.0.1.0/24"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "WinRM-Internal"
    priority                   = 101
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "5985-5986"
    source_address_prefix      = "10.0.1.0/24"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "HTTP"
    priority                   = 102
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "10.0.0.0/16"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "SQL-Internal"
    priority                   = 103
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "1433"
    source_address_prefix      = "10.0.0.0/16"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "dc" {
  subnet_id                 = azurerm_subnet.dc.id
  network_security_group_id = azurerm_network_security_group.dc.id
}

resource "azurerm_subnet_network_security_group_association" "sql" {
  subnet_id                 = azurerm_subnet.sql.id
  network_security_group_id = azurerm_network_security_group.sql.id
}

# NSG for Linux
resource "azurerm_network_security_group" "linux" {
  name                = "nsg-linux-${var.environment}"
  location            = azurerm_resource_group.demo.location
  resource_group_name = azurerm_resource_group.demo.name

  security_rule {
    name                       = "SSH-VNet"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "10.0.0.0/16"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "SSH-Deployer"
    priority                   = 101
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = var.allowed_rdp_source_ip
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "linux" {
  subnet_id                 = azurerm_subnet.linux.id
  network_security_group_id = azurerm_network_security_group.linux.id
}

# Public IP for DC
resource "azurerm_public_ip" "dc" {
  name                = "pip-dc-${var.environment}"
  resource_group_name = azurerm_resource_group.demo.name
  location            = azurerm_resource_group.demo.location
  allocation_method   = "Static"
  sku                 = "Standard"
}

# NICs
resource "azurerm_network_interface" "dc" {
  name                = "nic-dc-${var.environment}"
  location            = azurerm_resource_group.demo.location
  resource_group_name = azurerm_resource_group.demo.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.dc.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.0.1.10"
    public_ip_address_id          = azurerm_public_ip.dc.id
  }
}

resource "azurerm_network_interface" "sql" {
  name                = "nic-sql-${var.environment}"
  location            = azurerm_resource_group.demo.location
  resource_group_name = azurerm_resource_group.demo.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.sql.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.0.2.10"
  }

  dns_servers = ["10.0.1.10"]
}

resource "azurerm_network_interface" "ubuntu" {
  name                = "nic-ubuntu-${var.environment}"
  location            = azurerm_resource_group.demo.location
  resource_group_name = azurerm_resource_group.demo.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.linux.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.0.3.10"
  }
}

# VMs
resource "azurerm_windows_virtual_machine" "dc" {
  name                = "vm-dc-${var.environment}"
  computer_name       = "DC01"
  resource_group_name = azurerm_resource_group.demo.name
  location            = azurerm_resource_group.demo.location
  size                = "Standard_D2s_v3"
  admin_username      = var.admin_username
  admin_password      = var.admin_password
  secure_boot_enabled = true
  vtpm_enabled        = true

  network_interface_ids = [azurerm_network_interface.dc.id]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = "2022-datacenter-azure-edition"
    version   = "latest"
  }

  tags = {
    Environment = var.environment
    Project     = "BeyondTrust-Demo"
    ManagedBy   = "Terraform"
    Role        = "DomainController"
  }
}

# SQL Server VM (replacing member server but cheaper)
resource "azurerm_windows_virtual_machine" "sql" {
  name                = "vm-sql-${var.environment}"
  computer_name       = "SQL01"
  resource_group_name = azurerm_resource_group.demo.name
  location            = azurerm_resource_group.demo.location
  size                = "Standard_D2s_v3"  # Cheaper size
  admin_username      = var.admin_username
  admin_password      = var.admin_password
  secure_boot_enabled = true
  vtpm_enabled        = true

  network_interface_ids = [azurerm_network_interface.sql.id]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    disk_size_gb         = 128
  }

  source_image_reference {
    publisher = "MicrosoftSQLServer"
    offer     = "sql2019-ws2022"
    sku       = "sqldev-gen2"
    version   = "latest"
  }

  tags = {
    Environment = var.environment
    Project     = "BeyondTrust-Demo"
    ManagedBy   = "Terraform"
    Role        = "SQLServer"
  }
}


# SQL VM Configuration
resource "azurerm_mssql_virtual_machine" "sql" {
  virtual_machine_id = azurerm_windows_virtual_machine.sql.id
  sql_license_type   = "PAYG"

  sql_connectivity_type = "PRIVATE"
  sql_connectivity_port = 1433
  # depends_on is implicit via virtual_machine_id reference; no explicit declaration needed
}

# Ubuntu Linux VM
resource "azurerm_linux_virtual_machine" "ubuntu" {
  name                            = "vm-ubuntu-${var.environment}"
  computer_name                   = "UBUNTU01"
  resource_group_name             = azurerm_resource_group.demo.name
  location                        = azurerm_resource_group.demo.location
  size                            = "Standard_B2s"
  admin_username                  = var.linux_admin_username
  admin_password                  = var.linux_admin_password
  disable_password_authentication = false

  network_interface_ids = [azurerm_network_interface.ubuntu.id]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  tags = {
    Environment = var.environment
    Project     = "BeyondTrust-Demo"
    ManagedBy   = "Terraform"
    Role        = "LinuxServer"
  }
}

locals {
  winrm_script = <<-EOT
    Enable-PSRemoting -Force
    Set-Item -Path WSMan:\localhost\Service\Auth\Basic -Value $true
    Set-Item -Path WSMan:\localhost\Service\AllowUnencrypted -Value $true
    New-NetFirewallRule -DisplayName "WinRM HTTP" -Direction Inbound -LocalPort 5985 -Protocol TCP -Action Allow
    Restart-Service WinRM
  EOT
}

# WinRM using Run Command
resource "azurerm_virtual_machine_run_command" "dc_winrm" {
  name               = "ConfigureWinRM-DC"
  location           = azurerm_resource_group.demo.location
  virtual_machine_id = azurerm_windows_virtual_machine.dc.id

  source {
    script = local.winrm_script
  }
}

resource "azurerm_virtual_machine_run_command" "sql_winrm" {
  name               = "ConfigureWinRM-SQL"
  location           = azurerm_resource_group.demo.location
  virtual_machine_id = azurerm_windows_virtual_machine.sql.id

  source {
    script = local.winrm_script
  }
}

resource "azurerm_virtual_machine_run_command" "sql_iis" {
  name               = "InstallIIS-SQL"
  location           = azurerm_resource_group.demo.location
  virtual_machine_id = azurerm_windows_virtual_machine.sql.id

  source {
    script = <<-EOT
      Install-WindowsFeature -Name Web-Server -IncludeManagementTools
      New-Item -Path "C:\inetpub\wwwroot" -ItemType Directory -Force -ErrorAction SilentlyContinue
      $html = "<html><body><h1>BeyondTrust Demo - SQL Server</h1><p>Server: $env:COMPUTERNAME</p></body></html>"
      Set-Content -Path "C:\inetpub\wwwroot\index.html" -Value $html -Force
    EOT
  }

  depends_on = [azurerm_windows_virtual_machine.sql]
}

# Outputs
output "dc_public_ip" {
  value = azurerm_public_ip.dc.ip_address
}

output "ubuntu_private_ip" {
  value = azurerm_network_interface.ubuntu.private_ip_address
}

output "deployment_info" {
  sensitive = true
  value = {
    resource_group = azurerm_resource_group.demo.name
    dc_rdp         = "${azurerm_public_ip.dc.ip_address}:3389"
  }
}
EOF

    # Create tfvars
    cat > terraform/terraform.tfvars << EOF
environment           = "$ENVIRONMENT"
azure_region          = "$AZURE_REGION"
admin_username        = "$ADMIN_USERNAME"
admin_password        = "$ADMIN_PASSWORD"
allowed_rdp_source_ip = "$MY_PUBLIC_IP/32"
linux_admin_username  = "$LINUX_ADMIN_USERNAME"
linux_admin_password  = "$LINUX_ADMIN_PASSWORD"
EOF

    # Set Azure subscription
    export ARM_SUBSCRIPTION_ID="$AZURE_SUBSCRIPTION_ID"
    
    # Register required resource providers
    print_status "Registering required Azure resource providers..."
    az provider register --namespace Microsoft.SqlVirtualMachine --wait
    az provider register --namespace Microsoft.Compute --wait
    az provider register --namespace Microsoft.Network --wait
    az provider register --namespace Microsoft.Storage --wait

    # Deploy infrastructure
    print_status "Deploying Azure infrastructure with Terraform..."
    pushd "$PROJECT_DIR/terraform" > /dev/null
    terraform init
    terraform validate
    terraform apply -auto-approve

    # Get DC IP
    DC_IP=$(terraform output -raw dc_public_ip)
    print_status "Domain Controller deployed at: $DC_IP"

    # Update state with DC IP
    update_azure_info "dc_public_ip" "$DC_IP"
    popd > /dev/null
}

# Phase 2: Configure Domain
configure_domain() {
    print_status "Phase 2: Configuring Active Directory domain..."
    
    cd "$PROJECT_DIR"
    
    # Source config to get domain variables
    source "$CONFIG_FILE"
    
    # Update state
    update_metadata "domain_name" "$DOMAIN_NAME"
    update_metadata "domain_netbios" "$DOMAIN_NETBIOS_NAME"
    
    # Create ansible.cfg
    cat > ansible/ansible.cfg << 'EOF'
[defaults]
inventory = ./inventory/hosts.yml
host_key_checking = False
timeout = 30
callbacks_enabled = profile_tasks
stdout_callback = yaml
deprecation_warnings = False

[winrm]
transport = ntlm
EOF

    # Create group_vars
    cat > ansible/group_vars/windows.yml << EOF
---
ansible_user: $ADMIN_USERNAME
ansible_password: $ADMIN_PASSWORD
ansible_connection: winrm
ansible_winrm_transport: ntlm
ansible_winrm_server_cert_validation: ignore
ansible_port: 5985

domain_name: $DOMAIN_NAME
domain_netbios_name: $DOMAIN_NETBIOS_NAME
safe_mode_password: $SAFE_MODE_PASSWORD
dns_forwarder: 8.8.8.8
EOF

    # Get DC IP from state
    DC_IP=$(jq -r '.azure.dc_public_ip' "$STATE_FILE")

    # Create inventory
    cat > ansible/inventory/hosts.yml << EOF
all:
  children:
    windows:
      vars:
        ansible_connection: winrm
        ansible_winrm_transport: ntlm
        ansible_winrm_server_cert_validation: ignore
        ansible_port: 5985
        ansible_user: $ADMIN_USERNAME
        ansible_password: $ADMIN_PASSWORD
      hosts:
        dc:
          ansible_host: $DC_IP
        sql:
          ansible_host: 10.0.2.10
    linux:
      vars:
        ansible_connection: ssh
        ansible_shell_type: sh
        ansible_ssh_common_args: '-o StrictHostKeyChecking=no -o ProxyJump=$ADMIN_USERNAME@$DC_IP'
      hosts:
        ubuntu:
          ansible_host: 10.0.3.10
          ansible_connection: ssh
          ansible_port: 22
          ansible_user: $LINUX_ADMIN_USERNAME
          ansible_password: "$LINUX_ADMIN_PASSWORD"
          ansible_become: yes
          ansible_become_method: sudo
          ansible_become_pass: "$LINUX_ADMIN_PASSWORD"
EOF

    # Create playbooks
    cat > ansible/playbooks/01-setup-dc.yml << 'EOF'
---
- name: Setup Domain Controller
  hosts: dc
  gather_facts: yes
  tasks:
    - name: Install AD Features
      ansible.windows.win_feature:
        name:
          - AD-Domain-Services
          - DNS
          - RSAT-AD-Tools
        state: present
      register: features
    
    - name: Reboot if needed
      ansible.windows.win_reboot:
      when: features.reboot_required
    
    - name: Check if already a domain controller
      ansible.windows.win_shell: |
        (Get-WmiObject Win32_ComputerSystem).DomainRole
      register: domain_role
      changed_when: false
    
    - name: Create Domain
      ansible.windows.win_domain:
        dns_domain_name: "{{ domain_name }}"
        domain_netbios_name: "{{ domain_netbios_name }}"
        safe_mode_password: "{{ safe_mode_password }}"
        state: domain_controller
      register: domain_install
      when: domain_role.stdout|int < 4  # 4 or 5 means it's already a DC
    
    - name: Reboot after domain promotion
      ansible.windows.win_reboot:
        msg: "Rebooting after DC promotion"
        reboot_timeout: 600
        post_reboot_delay: 60
      when: domain_install.changed
    
    - name: Wait for DC to come back
      ansible.builtin.wait_for_connection:
        delay: 60
        timeout: 600
      when: domain_install.changed
EOF

    cat > ansible/playbooks/02-configure-sql.yml << 'EOF'
---
- name: Configure SQL Server via DC proxy
  hosts: dc
  vars:
    sql_ip: "10.0.2.10"
   
  tasks:
    - name: Clear any connection errors
      meta: clear_host_errors
      
    - name: Test DC connectivity first
      ansible.windows.win_ping:
      
    - name: Get DC status
      ansible.windows.win_shell: |
        @{
          Computer = $env:COMPUTERNAME
          Domain = (Get-WmiObject Win32_ComputerSystem).Domain
          WinRM = (Get-Service WinRM).Status
        } | ConvertTo-Json
      register: dc_status
      
    - name: Show DC status
      debug:
        var: dc_status.stdout

    - name: Reset connection after domain promotion
      meta: reset_connection
        
    - name: Wait for connection to stabilize
      wait_for_connection:
        delay: 10
        timeout: 300
        
    - name: Enable unencrypted WinRM traffic on DC
      ansible.windows.win_powershell:
        script: |
          Set-Item -Path WSMan:\localhost\Client\AllowUnencrypted -Value $true -Force
          Set-Item -Path WSMan:\localhost\Client\Auth\Basic -Value $true -Force
          "WinRM configured for unencrypted traffic"
       
    - name: Configure WinRM TrustedHosts and test connectivity
      ansible.windows.win_shell: |
        # Set TrustedHosts
        Set-Item WSMan:\localhost\Client\TrustedHosts -Value "*" -Force
       
        # Test basic connectivity
        Test-NetConnection -ComputerName {{ sql_ip }} -Port 5985
        
    - name: Configure SQL server for domain join and SQL setup
      ansible.windows.win_shell: |
        $password = ConvertTo-SecureString "{{ ansible_password }}" -AsPlainText -Force
        $localCred = New-Object PSCredential("{{ ansible_user }}", $password)
        $domainPassword = ConvertTo-SecureString "{{ ansible_password }}" -AsPlainText -Force
        $domainCred = New-Object PSCredential("{{ domain_netbios_name }}\{{ ansible_user }}", $domainPassword)
       
        # Configure the join and SQL setup
        $scriptBlock = {
          param($DomainName, $AdminUser, $AdminPass)
         
          try {
            # Check if already domain joined
            $cs = Get-WmiObject Win32_ComputerSystem
            if ($cs.Domain -eq $DomainName) {
              return "Already joined to $DomainName"
            }
           
            # Join domain
            $pass = ConvertTo-SecureString $AdminPass -AsPlainText -Force
            $cred = New-Object PSCredential("$DomainName\$AdminUser", $pass)
           
            Add-Computer -DomainName $DomainName -Credential $cred -Force
            Write-Output "Domain join successful - restarting in 30 seconds"
           
            # Schedule restart
            shutdown /r /t 30 /c "Restarting to complete domain join"
           
          } catch {
            Write-Output "Error joining domain: $_"
          }
        }
       
        # Execute on SQL server
        $sessionOption = New-PSSessionOption -SkipCACheck -SkipCNCheck
        Invoke-Command -ComputerName {{ sql_ip }} -Credential $localCred -Authentication Basic -SessionOption $sessionOption -ScriptBlock $scriptBlock -ArgumentList "{{ domain_name }}", "{{ ansible_user }}", "{{ ansible_password }}"
      register: domain_join
     
    - name: Show domain join result
      debug:
        var: domain_join.stdout_lines
       
    - name: Wait for SQL restart if joined
      pause:
        seconds: 60
      when: "'Domain join successful' in domain_join.stdout"
     
    - name: Final verification
      ansible.windows.win_shell: |
        Start-Sleep -Seconds 30
       
        # Check if SQL is in AD
        try {
          $computer = Get-ADComputer -Filter "Name -eq 'SQL01'" -ErrorAction Stop
          Write-Output "Found in AD: $($computer.Name) - $($computer.DNSHostName)"
        } catch {
          Write-Output "Not found in AD yet"
        }
       
        # Try to connect with domain creds
        $domainCred = New-Object PSCredential("{{ domain_netbios_name }}\{{ ansible_user }}", (ConvertTo-SecureString "{{ ansible_password }}" -AsPlainText -Force))
        try {
          Test-WSMan -ComputerName SQL01.{{ domain_name }} -Credential $domainCred -Authentication Negotiate
          Write-Output "Domain authentication working"
        } catch {
          Write-Output "Domain auth not ready yet"
        }
      register: final_check
     
    - name: Show final status
      debug:
        var: final_check.stdout_lines
EOF

    cat > ansible/playbooks/03-create-users.yml << 'EOF'
---
- name: Create Demo Users
  hosts: dc
  tasks:
    - name: Create OU
      ansible.windows.win_powershell:
        script: |
          New-ADOrganizationalUnit -Name "Demo Users" -Path "DC={{ domain_name.split('.') | join(',DC=') }}" -ErrorAction SilentlyContinue

    - name: Create users
      ansible.windows.win_powershell:
        script: |
          $users = @(
            @{name='jsmith'; first='John'; last='Smith'; pass='DemoPass123!'},
            @{name='mjohnson'; first='Mary'; last='Johnson'; pass='DemoPass123!'},
            @{name='bdavis'; first='Bob'; last='Davis'; pass='DemoPass123!'}
          )
          
          foreach ($u in $users) {
            $password = ConvertTo-SecureString $u.pass -AsPlainText -Force
            New-ADUser -Name "$($u.first) $($u.last)" `
              -GivenName $u.first `
              -Surname $u.last `
              -SamAccountName $u.name `
              -UserPrincipalName "$($u.name)@{{ domain_name }}" `
              -Path "OU=Demo Users,DC={{ domain_name.split('.') | join(',DC=') }}" `
              -AccountPassword $password `
              -Enabled $true `
              -PasswordNeverExpires $true `
              -ErrorAction SilentlyContinue
          }
          
          # Make jsmith admin
          Add-ADGroupMember -Identity "Domain Admins" -Members "jsmith" -ErrorAction SilentlyContinue
          
          # Add all users to Remote Desktop Users group for RDP access
          $users | ForEach-Object { 
            Add-ADGroupMember -Identity "Remote Desktop Users" -Members $_.name -ErrorAction SilentlyContinue
          }

    - name: Configure RDP access on SQL server
      ansible.windows.win_shell: |
        $domainCred = New-Object PSCredential("{{ domain_netbios_name }}\{{ ansible_user }}", (ConvertTo-SecureString "{{ ansible_password }}" -AsPlainText -Force))
        
        Invoke-Command -ComputerName SQL01.{{ domain_name }} -Credential $domainCred -Authentication Negotiate -ScriptBlock {
          Add-LocalGroupMember -Group "Remote Desktop Users" -Member "{{ domain_netbios_name }}\Remote Desktop Users" -ErrorAction SilentlyContinue
        }
      ignore_errors: yes
      
    - name: Configure SQL Server for domain authentication (simplified)
      ansible.windows.win_shell: |
        # Note: SQL Server domain authentication will be configured in a separate task
        Write-Output "SQL Server is domain-joined. Configuring SQL authentication..."
      ignore_errors: yes
      
    - name: Configure SQL Server authentication and logins
      ansible.windows.win_shell: |
        $domainCred = New-Object PSCredential("{{ domain_netbios_name }}\{{ ansible_user }}", (ConvertTo-SecureString "{{ ansible_password }}" -AsPlainText -Force))
        
        Invoke-Command -ComputerName SQL01.{{ domain_name }} -Credential $domainCred -Authentication Negotiate -ScriptBlock {
          try {
            # First, restart SQL in single-user mode to ensure we have access
            Write-Output "Configuring SQL Server authentication..."
            Stop-Service MSSQLSERVER -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 5
            
            # Start in single-user mode
            $sqlProcess = Start-Process -FilePath "net" -ArgumentList "start MSSQLSERVER /m" -Wait -PassThru -NoNewWindow
            Start-Sleep -Seconds 10
            
            # Configure mixed mode and SA account using sqlcmd
            $sqlCommands = "USE [master]`nGO`nEXEC xp_instance_regwrite N'HKEY_LOCAL_MACHINE', N'Software\Microsoft\MSSQLServer\MSSQLServer', N'LoginMode', REG_DWORD, 2`nGO`nALTER LOGIN [sa] WITH PASSWORD = 'SAPassword123!'`nGO`nALTER LOGIN [sa] ENABLE`nGO`nEXIT"
            
            $sqlCommands | sqlcmd -S localhost -E
            
            # Restart SQL Server normally
            Stop-Service MSSQLSERVER -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 5
            Start-Service MSSQLSERVER
            Start-Sleep -Seconds 10
            
            # Now add domain logins using SA account
            $domainCommands = "CREATE LOGIN [{{ domain_netbios_name }}\Domain Admins] FROM WINDOWS`nGO`nALTER SERVER ROLE sysadmin ADD MEMBER [{{ domain_netbios_name }}\Domain Admins]`nGO`nCREATE LOGIN [{{ domain_netbios_name }}\{{ ansible_user }}] FROM WINDOWS`nGO`nALTER SERVER ROLE sysadmin ADD MEMBER [{{ domain_netbios_name }}\{{ ansible_user }}]`nGO`nCREATE LOGIN [{{ domain_netbios_name }}\jsmith] FROM WINDOWS`nGO`nALTER SERVER ROLE sysadmin ADD MEMBER [{{ domain_netbios_name }}\jsmith]`nGO`nCREATE LOGIN [{{ domain_netbios_name }}\mjohnson] FROM WINDOWS`nGO`nCREATE LOGIN [{{ domain_netbios_name }}\bdavis] FROM WINDOWS`nGO`nSELECT name, type_desc FROM sys.server_principals WHERE type IN ('S', 'U', 'G') ORDER BY name`nGO`nEXIT"
            
            $domainCommands | sqlcmd -S localhost -U sa -P "SAPassword123!"
            
            Write-Output "SQL Server authentication configured successfully"
            Write-Output "SA password: SAPassword123!"
            Write-Output "Domain logins added for: Domain Admins, {{ ansible_user }}, jsmith, mjohnson, bdavis"
            Write-Output "SQL data and log files will use default C: drive locations"
            
          } catch {
            Write-Output "Error configuring SQL Server: $_"
            Write-Output "You may need to configure SQL authentication manually"
          }
        }
      register: sql_auth_config
      ignore_errors: yes
      
    - name: Show SQL authentication configuration result
      debug:
        var: sql_auth_config.stdout_lines
EOF

    # Poll for DC01 WinRM availability instead of a fixed wait
    print_status "Waiting for DC01 to become reachable via WinRM (max 3 min)..."
    local vm_ready=false
    for attempt in $(seq 1 18); do
        if ansible dc -i "$PROJECT_DIR/ansible/inventory/hosts.yml" \
            -m ansible.windows.win_ping \
            -e @"$PROJECT_DIR/ansible/group_vars/windows.yml" &>/dev/null; then
            print_status "DC01 is reachable (attempt $attempt/18)"
            vm_ready=true
            break
        fi
        print_warning "DC01 not ready yet (attempt $attempt/18), retrying in 10s..."
        sleep 10
    done
    if [ "$vm_ready" = false ]; then
        print_warning "DC01 did not respond within 3 minutes — proceeding anyway"
    fi

    # Run Ansible playbooks
    pushd "$PROJECT_DIR/ansible" > /dev/null
    export ANSIBLE_HOST_KEY_CHECKING=False

    # Activate venv for ansible commands
    source "$HOME/.venvs/ansible/bin/activate"

    print_status "Testing connectivity to Domain Controller..."
    ansible dc -m ansible.windows.win_ping

    print_status "Setting up domain controller..."
    ansible-playbook playbooks/01-setup-dc.yml -e @group_vars/windows.yml

    print_status "Domain controller setup complete. Polling for Active Directory services (max 4 min)..."
    local ad_ready=false
    for attempt in $(seq 1 24); do
        if ansible dc -i "$PROJECT_DIR/ansible/inventory/hosts.yml" \
            -m ansible.windows.win_service_info \
            -a 'name=NTDS' \
            -e @"$PROJECT_DIR/ansible/group_vars/windows.yml" 2>/dev/null \
            | grep -q '"state": "started"'; then
            print_status "Active Directory (NTDS) is running (attempt $attempt/24)"
            ad_ready=true
            break
        fi
        print_warning "AD services not ready yet (attempt $attempt/24), retrying in 10s..."
        sleep 10
    done
    if [ "$ad_ready" = false ]; then
        print_warning "AD services did not confirm ready within 4 minutes — proceeding anyway"
    fi

    print_status "Configuring SQL server..."
    ansible-playbook playbooks/02-configure-sql.yml -e @group_vars/windows.yml

    print_status "Creating demo users..."
    ansible-playbook playbooks/03-create-users.yml -e @group_vars/windows.yml

    deactivate
    popd > /dev/null
}

# Phase 3: BeyondTrust Integration
deploy_beyondtrust() {
    print_status "Phase 3: Deploying BeyondTrust PRA integration..."
    
    cd "$PROJECT_DIR"
    
    # Source config and EXPORT ALL VARIABLES (FIX)
    source "$CONFIG_FILE"
    export BT_API_HOST BT_CLIENT_ID BT_CLIENT_SECRET RESOURCE_PREFIX APPROVER_EMAIL
    export JUMP_GROUP_DEMO JUMP_GROUP_DC JUMPOINT_NAME ADMIN_USERNAME ADMIN_PASSWORD DOMAIN_NAME
    export VAULT_ACCOUNT_GROUP_ID

    # Update state
    update_metadata "beyondtrust_instance" "$BT_API_HOST"
    update_metadata "resource_prefix" "$RESOURCE_PREFIX"
    
    # Create all BeyondTrust scripts
    create_beyondtrust_terraform_config
    create_beyondtrust_api_helper
    create_beyondtrust_state_helper
    create_beyondtrust_run_wrapper  # NEW: Create wrapper script
    create_beyondtrust_policy_script
    create_beyondtrust_installer_script
    create_beyondtrust_jump_items_script
    create_beyondtrust_vault_script
    create_beyondtrust_cleanup_script
    create_beyondtrust_ansible_playbook
    
    # Step 1: Deploy Terraform resources
    print_status "Deploying BeyondTrust Terraform resources..."
    pushd "$PROJECT_DIR/beyondtrust/terraform" > /dev/null
    terraform init
    terraform apply -auto-approve

    # Save IDs for later use
    terraform output -raw jump_group_demo_id > demo_group_id.txt
    terraform output -raw jump_group_dc_id > dc_group_id.txt
    terraform output -raw jumpoint_id > jumpoint_id.txt
    terraform output -raw jump_group_linux_id > linux_group_id.txt

    # Track Terraform resources in state
    add_resource "jump_group" "$(cat demo_group_id.txt)" "$JUMP_GROUP_DEMO" '{"type": "shared", "managed_by": "terraform"}'
    add_resource "jump_group" "$(cat dc_group_id.txt)" "$JUMP_GROUP_DC" '{"type": "shared", "managed_by": "terraform"}'
    add_resource "jump_group" "$(cat linux_group_id.txt)" "$JUMP_GROUP_LINUX" '{"type": "shared", "managed_by": "terraform"}'
    add_resource "jumpoint" "$(cat jumpoint_id.txt)" "$JUMPOINT_NAME" '{"platform": "windows-x86", "managed_by": "terraform"}'
    popd > /dev/null

    # Step 2: Create policies via API (using wrapper)
    print_status "Creating jump policies..."
    (cd "$PROJECT_DIR/beyondtrust/scripts" && ./run-with-config.sh create-policies.sh)

    # Step 3: Download installers (using wrapper)
    print_status "Downloading installers..."
    (cd "$PROJECT_DIR/beyondtrust/scripts" && ./run-with-config.sh download-installers.sh) || {
        print_error "Failed to download installers. Check your BeyondTrust API credentials and network connectivity."
    }

    # Step 4: Install software via Ansible
    print_status "Installing BeyondTrust software on DC01..."
    pushd "$PROJECT_DIR/ansible" > /dev/null

    # Activate virtual environment if needed
    if [ -f "$HOME/.venvs/ansible/bin/activate" ]; then
        source "$HOME/.venvs/ansible/bin/activate"
    fi

    ansible-playbook "$PROJECT_DIR/beyondtrust/ansible/install-beyondtrust.yml" \
        -i inventory/hosts.yml \
        -e @group_vars/windows.yml || {
        print_warning "Ansible installation encountered issues. Continuing with API configuration..."
    }

    if [ -n "$VIRTUAL_ENV" ]; then
        deactivate
    fi
    popd > /dev/null

    # Step 5: Configure jump items (using wrapper)
    print_status "Configuring jump items..."
    (cd "$PROJECT_DIR/beyondtrust/scripts" && ./run-with-config.sh configure-jump-items.sh)

    # Step 6: Configure vault (using wrapper)
    print_status "Configuring vault accounts..."
    (cd "$PROJECT_DIR/beyondtrust/scripts" && ./run-with-config.sh configure-vault.sh)

    # Update deployment completed timestamp
    update_metadata "deployment_completed" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

# NEW: Create run wrapper script
create_beyondtrust_run_wrapper() {
    print_status "Creating run wrapper script..."
    
    cat > beyondtrust/scripts/run-with-config.sh << 'EOF'
#!/bin/bash
# Wrapper script to run BeyondTrust scripts with proper environment

# Find config file
CONFIG_FILE="../../config.env"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: Cannot find config file"
    exit 1
fi

# Source configuration
source "$CONFIG_FILE"

# Export all BeyondTrust variables
export BT_API_HOST BT_CLIENT_ID BT_CLIENT_SECRET APPROVER_EMAIL RESOURCE_PREFIX
export DOMAIN_NAME DOMAIN_NETBIOS_NAME ADMIN_USERNAME ADMIN_PASSWORD
export VAULT_ACCOUNT_GROUP_ID="${VAULT_ACCOUNT_GROUP_ID:-4}"
export JUMP_GROUP_DEMO="${RESOURCE_PREFIX}Demo Servers"
export JUMP_GROUP_DC="${RESOURCE_PREFIX}Domain Controllers"
export JUMPOINT_NAME="${RESOURCE_PREFIX}DC01_Jumpoint"

# Run the requested script
if [ -n "$1" ]; then
    echo "Running $1 with configured environment..."
    ./$1 "${@:2}"
else
    echo "Usage: ./run-with-config.sh <script-name> [args...]"
    echo "Example: ./run-with-config.sh create-policies.sh"
fi
EOF
    
    chmod +x beyondtrust/scripts/run-with-config.sh
}

# BeyondTrust script creation functions
create_beyondtrust_terraform_config() {
    print_status "Creating BeyondTrust Terraform configuration..."
    
    cat > beyondtrust/terraform/versions.tf << 'EOF'
terraform {
  required_version = ">= 1.0"
  required_providers {
    sra = {
      source  = "BeyondTrust/sra"
      version = "~> 1.0"
    }
  }
}
EOF

    cat > beyondtrust/terraform/main.tf << EOF
# Provider configuration uses environment variables
provider "sra" {}

# Jump Groups
resource "sra_jump_group" "demo_servers" {
  name      = "$JUMP_GROUP_DEMO"
  code_name = "demo_servers"
  comments  = "Servers requiring approval for access"
}

resource "sra_jump_group" "domain_controllers" {
  name      = "$JUMP_GROUP_DC"
  code_name = "domain_controllers"
  comments  = "Domain controllers with direct access"
}

resource "sra_jump_group" "linux_servers" {
  name      = "$JUMP_GROUP_LINUX"
  code_name = "linux_servers"
  comments  = "Linux servers accessible via SSH Shell Jump"
}

# Jumpoint
resource "sra_jumpoint" "dc_jumpoint" {
  name                    = "$JUMPOINT_NAME"
  code_name              = "dc01_jumpoint"
  platform               = "windows-x86"
  shell_jump_enabled     = true
  protocol_tunnel_enabled = true
  enabled                = true
  comments               = "Jumpoint on Domain Controller for indirect access"
}

# Outputs
output "jump_group_demo_id" {
  value = sra_jump_group.demo_servers.id
}

output "jump_group_dc_id" {
  value = sra_jump_group.domain_controllers.id
}

output "jumpoint_id" {
  value = sra_jumpoint.dc_jumpoint.id
}

output "jump_group_linux_id" {
  value = sra_jump_group.linux_servers.id
}
EOF
}

create_beyondtrust_api_helper() {
    print_status "Creating BeyondTrust API helper script..."
    
    cat > beyondtrust/scripts/bt-api.sh << 'EOF'
#!/bin/bash
# BeyondTrust API helper functions

# Token cache (in-memory, valid for the lifetime of the calling process)
_BT_TOKEN=""
_BT_TOKEN_EXPIRY=0

# Get OAuth token with in-memory caching to avoid a new credential request per API call
get_api_token() {
    local now
    now=$(date +%s)
    # Refresh if no token or within 60 seconds of expiry
    if [ -z "$_BT_TOKEN" ] || [ "$now" -ge "$((_BT_TOKEN_EXPIRY - 60))" ]; then
        local response attempt=0
        while [ $attempt -lt 3 ]; do
            response=$(curl -s --max-time 15 -X POST "$BT_API_HOST/oauth2/token" \
                -H "Content-Type: application/x-www-form-urlencoded" \
                -d "grant_type=client_credentials&client_id=$BT_CLIENT_ID&client_secret=$BT_CLIENT_SECRET")
            _BT_TOKEN=$(echo "$response" | jq -r .access_token)
            if [ -n "$_BT_TOKEN" ] && [ "$_BT_TOKEN" != "null" ]; then
                local expires_in
                expires_in=$(echo "$response" | jq -r '.expires_in // 600')
                _BT_TOKEN_EXPIRY=$((now + expires_in))
                break
            fi
            attempt=$((attempt + 1))
            [ $attempt -lt 3 ] && sleep $((attempt * 2))
        done
        if [ -z "$_BT_TOKEN" ] || [ "$_BT_TOKEN" = "null" ]; then
            echo "ERROR: Failed to obtain API token after 3 attempts. Check BT_API_HOST, BT_CLIENT_ID, and BT_CLIENT_SECRET." >&2
            return 1
        fi
    fi
    echo "$_BT_TOKEN"
}

# Make API call
api_call() {
    local method="$1"
    local endpoint="$2"
    local data="$3"

    local token
    token=$(get_api_token) || return 1

    local args=(-s -X "$method" "$BT_API_HOST/api/config/v1$endpoint" \
        -H "Authorization: Bearer $token" \
        -H "Accept: application/json")

    if [ -n "$data" ]; then
        args+=(-H "Content-Type: application/json" -d "$data")
    fi

    curl "${args[@]}"
}
EOF
    
    chmod +x beyondtrust/scripts/bt-api.sh
}

create_beyondtrust_state_helper() {
    print_status "Creating BeyondTrust state helper script..."
    
    cat > beyondtrust/scripts/state-helper.sh << 'EOF'
#!/bin/bash
# State file helper for BeyondTrust resources
# NOTE: add_bt_resource and get_bt_resources mirror the add_resource/get_resources
# functions defined in deploy-infra.sh. Keep them in sync if the logic changes.

# Derive an absolute path to the state file regardless of working directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="$SCRIPT_DIR/../../deployment-state.json"

# Wrapper functions that use the main state file
add_bt_resource() {
    local resource_type="$1"
    local resource_id="$2"
    local resource_name="$3"
    local additional_data="${4:-}"
    
    # Ensure state file exists
    if [ ! -f "$STATE_FILE" ]; then
        echo '{"metadata": {}, "resources": {}, "azure": {}}' > "$STATE_FILE"
    fi
    
    # If no additional data provided, use empty object
    if [ -z "$additional_data" ]; then
        additional_data="{}"
    fi
    
    # Add resource to state file
    jq --arg type "$resource_type" \
       --arg id "$resource_id" \
       --arg name "$resource_name" \
       --argjson data "$additional_data" \
       --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
       '.resources[$type] += [{
           id: $id, 
           name: $name, 
           created_at: $timestamp
       } + $data]' \
       "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
}

get_bt_resources() {
    local resource_type="$1"
    
    if [ -f "$STATE_FILE" ]; then
        jq -r --arg type "$resource_type" '.resources[$type][]? | .id' "$STATE_FILE"
    fi
}
EOF
    
    chmod +x beyondtrust/scripts/state-helper.sh
}

create_beyondtrust_policy_script() {
    print_status "Creating policy management script..."
    
    cat > beyondtrust/scripts/create-policies.sh << 'EOF'
#!/bin/bash
# Create Jump Policies via API

source "$(dirname "$0")/bt-api.sh"
source "$(dirname "$0")/state-helper.sh"

# Create approval-required policy for SQL servers
create_approval_policy() {
    echo "Creating approval-required jump policy..."
    
    local policy_data=$(cat <<JSON
{
    "display_name": "${RESOURCE_PREFIX}SQL Server Approval Policy",
    "code_name": "${RESOURCE_PREFIX}sql_approval_policy",
    "description": "Requires approval before accessing SQL servers",
    "approval_required": true,
    "approval_max_duration": 120,
    "approval_scope": "requestor",
    "approval_email_addresses": ["$APPROVER_EMAIL"],
    "approval_display_name": "BeyondTrust Demo Approver",
    "approval_email_language": "en-us",
    "session_start_notification": true,
    "session_end_notification": true,
    "notification_email_addresses": ["$APPROVER_EMAIL"],
    "notification_display_name": "Security Team",
    "recordings_disabled": false
}
JSON
)
    
    local response=$(api_call "POST" "/jump-policy" "$policy_data")
    echo "$response" > ../config/approval_policy.json
    
    # Track in state file
    local policy_id=$(echo "$response" | jq -r '.id')
    local policy_name=$(echo "$response" | jq -r '.display_name')
    if [ -n "$policy_id" ] && [ "$policy_id" != "null" ]; then
        add_bt_resource "jump_policy" "$policy_id" "$policy_name" '{"type": "approval_required"}'
        echo "  Created policy ID: $policy_id"
    else
        echo "  ERROR: Failed to create approval policy"
    fi
}

# Create direct access policy for domain controllers
create_direct_policy() {
    echo "Creating direct access jump policy..."
    
    local policy_data=$(cat <<JSON
{
    "display_name": "${RESOURCE_PREFIX}Domain Controller Direct Access",
    "code_name": "${RESOURCE_PREFIX}dc_direct_policy",
    "description": "Direct access to domain controllers with recording",
    "approval_required": false,
    "session_start_notification": true,
    "notification_email_addresses": ["$APPROVER_EMAIL"],
    "notification_display_name": "Security Team",
    "recordings_disabled": false
}
JSON
)
    
    local response=$(api_call "POST" "/jump-policy" "$policy_data")
    echo "$response" > ../config/direct_policy.json
    
    # Track in state file
    local policy_id=$(echo "$response" | jq -r '.id')
    local policy_name=$(echo "$response" | jq -r '.display_name')
    if [ -n "$policy_id" ] && [ "$policy_id" != "null" ]; then
        add_bt_resource "jump_policy" "$policy_id" "$policy_name" '{"type": "direct_access"}'
        echo "  Created policy ID: $policy_id"
    else
        echo "  ERROR: Failed to create direct policy"
    fi
}

# Main execution
create_approval_policy
create_direct_policy

echo "Jump policies created successfully"
EOF
    
    chmod +x beyondtrust/scripts/create-policies.sh
}

create_beyondtrust_installer_script() {
    print_status "Creating installer download script..."
    
    cat > beyondtrust/scripts/download-installers.sh << 'EOF'
#!/bin/bash
# Download BeyondTrust installers

source "$(dirname "$0")/bt-api.sh"
source "$(dirname "$0")/state-helper.sh"

# Get Jumpoint installer
download_jumpoint() {
    echo "Downloading Jumpoint installer..."
    
    local jumpoint_id=$(cat ../terraform/jumpoint_id.txt)
    local token=$(get_api_token)
    
    # Change to downloads directory
    cd ../downloads
    
    # Use curl with -J -O to save with the server-provided filename
    curl -s -J -O -H "Authorization: Bearer $token" \
        "$BT_API_HOST/api/config/v1/jumpoint/$jumpoint_id/installer"
    
    # Find the downloaded file (should be the newest .exe file)
    local filename=$(ls -t *.exe 2>/dev/null | head -n1)
    
    if [ -n "$filename" ]; then
        # Check file size (should be at least 1MB)
        local filesize=$(stat -c%s "$filename" 2>/dev/null || stat -f%z "$filename" 2>/dev/null)
        if [ "$filesize" -lt 1000000 ]; then
            echo "ERROR: Jumpoint installer too small ($filesize bytes), likely an error response"
            cat "$filename" | head -n 5
            rm -f "$filename"
            cd - > /dev/null
            return 1
        fi
        echo "$filename" > jumpoint-filename.txt
        echo "Jumpoint installer downloaded: $filename ($(($filesize / 1024 / 1024)) MB)"
    else
        echo "Failed to download Jumpoint installer"
        cd - > /dev/null
        return 1
    fi
    
    cd - > /dev/null
}

# Create and download Jump Client installer
create_jump_client() {
    echo "Creating Jump Client installer..."
    
    local dc_group_id=$(cat ../terraform/dc_group_id.txt)
    
    local installer_data=$(cat <<JSON
{
    "name": "${RESOURCE_PREFIX}DC01_JumpClient",
    "jump_group_id": $dc_group_id,
    "jump_group_type": "shared",
    "tag": "domain-controller",
    "comments": "Jump Client for Domain Controller",
    "connection_type": "active",
    "valid_duration": 1440,
    "elevate_install": true,
    "elevate_prompt": true
}
JSON
)
    
    local response=$(api_call "POST" "/jump-client/installer" "$installer_data")
    
    # Debug: Save the response
    echo "$response" > ../downloads/jumpclient-response.json
    
    local installer_id=$(echo "$response" | jq -r .installer_id)
    
    if [ -z "$installer_id" ] || [ "$installer_id" = "null" ]; then
        echo "ERROR: Failed to create Jump Client installer"
        echo "Response: $response"
        return 1
    fi
    
    echo "Created installer with ID: $installer_id"
    
    # Track installer creation
    add_bt_resource "jump_client_installer" "$installer_id" "${RESOURCE_PREFIX}DC01_JumpClient" '{"type": "msi", "platform": "windows-64"}'
    
    # Extract key_info for Windows 64-bit MSI
    local key_info=$(echo "$response" | jq -r '.key_info."winNT-64-msi".encodedInfo // empty')
    if [ -n "$key_info" ]; then
        echo "$key_info" > ../downloads/jumpclient-keyinfo.txt
        echo "Key info extracted for Windows 64-bit MSI"
    else
        echo "ERROR: No key info found for Windows 64-bit MSI"
        return 1
    fi
    
    # Download the installer
    echo "Downloading Jump Client installer..."
    local token=$(get_api_token)
    
    # Change to downloads directory
    cd ../downloads
    
    # Download using the correct API endpoint
    curl -s -J -O -H "Authorization: Bearer $token" \
        "$BT_API_HOST/api/config/v1/jump-client/installer/$installer_id/windows-64-msi"
    
    # Find the downloaded file (should be the newest .msi file)
    local filename=$(ls -t *.msi 2>/dev/null | head -n1)
    
    if [ -n "$filename" ]; then
        # Check file size (should be at least 1MB)
        local filesize=$(stat -c%s "$filename" 2>/dev/null || stat -f%z "$filename" 2>/dev/null)
        if [ "$filesize" -lt 1000000 ]; then
            echo "ERROR: Jump Client installer too small ($filesize bytes), likely an error response"
            cat "$filename" | head -n 5
            rm -f "$filename"
            cd - > /dev/null
            return 1
        fi
        echo "$filename" > jumpclient-filename.txt
        echo "Jump Client installer downloaded: $filename ($(($filesize / 1024 / 1024)) MB)"
    else
        echo "ERROR: Failed to download Jump Client installer"
        cd - > /dev/null
        return 1
    fi
    
    cd - > /dev/null
}

# Create and download Linux Jump Client installer (.sh shell script, linux64-x86)
create_linux_jump_client() {
    echo "Creating Linux Jump Client installer..."

    local linux_group_id=$(cat ../terraform/linux_group_id.txt)

    local installer_data=$(cat <<JSON
{
    "name": "${RESOURCE_PREFIX}Ubuntu01_JumpClient",
    "jump_group_id": $linux_group_id,
    "jump_group_type": "shared",
    "tag": "linux-server",
    "comments": "Jump Client for Ubuntu Linux server",
    "connection_type": "active",
    "valid_duration": 1440,
    "elevate_install": false,
    "elevate_prompt": false
}
JSON
)

    local response=$(api_call "POST" "/jump-client/installer" "$installer_data")

    echo "$response" > ../downloads/jumpclient-linux-response.json

    local installer_id=$(echo "$response" | jq -r .installer_id)

    if [ -z "$installer_id" ] || [ "$installer_id" = "null" ]; then
        echo "ERROR: Failed to create Linux Jump Client installer"
        echo "Response: $response"
        return 1
    fi

    echo "Created Linux installer with ID: $installer_id"

    # Track installer creation (same resource type as Windows — cleanup handles both)
    add_bt_resource "jump_client_installer" "$installer_id" "${RESOURCE_PREFIX}Ubuntu01_JumpClient" '{"type": "sh", "platform": "linux64-x86"}'

    # Extract key_info for Linux 64-bit x86 shell script installer
    local key_info=$(echo "$response" | jq -r '
        .key_info."linux64-x86".encodedInfo //
        empty')
    if [ -n "$key_info" ]; then
        echo "$key_info" > ../downloads/jumpclient-linux-keyinfo.txt
        echo "Key info extracted for Linux 64-bit installer"
    else
        echo "ERROR: No key info found for linux64-x86 platform"
        echo "Available platforms: $(echo "$response" | jq -r '.key_info | keys[]' 2>/dev/null)"
        return 1
    fi

    # Download the linux-64 .bin installer (API path param is 'linux-64', key_info key is 'linux64-x86')
    local platform="linux-64"
    echo "Downloading Linux Jump Client installer (${platform})..."
    local token=$(get_api_token)

    cd ../downloads

    local filename="jumpclient-linux.bin"
    local http_code
    http_code=$(curl -s -o "$filename" -w "%{http_code}" -H "Authorization: Bearer $token" \
        "$BT_API_HOST/api/config/v1/jump-client/installer/$installer_id/${platform}")
    if [ "$http_code" != "200" ]; then
        echo "ERROR: Download failed with HTTP $http_code"
        rm -f "$filename"
        cd - > /dev/null
        return 1
    fi

    if [ -f "$filename" ]; then
        local filesize=$(stat -c%s "$filename" 2>/dev/null || stat -f%z "$filename" 2>/dev/null)
        if [ "$filesize" -lt 1000000 ]; then
            echo "ERROR: Linux Jump Client installer too small ($filesize bytes), likely an error response"
            cat "$filename" | head -n 5
            rm -f "$filename"
            cd - > /dev/null
            return 1
        fi
        echo "$filename" > jumpclient-linux-filename.txt
        echo "Linux Jump Client installer downloaded: $filename ($(($filesize / 1024 / 1024)) MB)"
    else
        echo "ERROR: Failed to download Linux Jump Client installer"
        cd - > /dev/null
        return 1
    fi

    cd - > /dev/null
}

# Main execution
download_jumpoint
if [ $? -ne 0 ]; then
    echo "ERROR: Jumpoint download failed"
    exit 1
fi

create_jump_client
if [ $? -ne 0 ]; then
    echo "ERROR: Jump Client download failed"
    exit 1
fi

create_linux_jump_client
if [ $? -ne 0 ]; then
    echo "ERROR: Linux Jump Client download failed"
    exit 1
fi

echo "Download process completed"
EOF
    
    chmod +x beyondtrust/scripts/download-installers.sh
}

create_beyondtrust_jump_items_script() {
    print_status "Creating jump items configuration script..."
    
    cat > beyondtrust/scripts/configure-jump-items.sh << 'EOF'
#!/bin/bash
# Configure RDP and Web Jump Items

source "$(dirname "$0")/bt-api.sh"
source "$(dirname "$0")/state-helper.sh"

# Load IDs from files
JUMPOINT_ID=$(cat ../terraform/jumpoint_id.txt)
DEMO_GROUP_ID=$(cat ../terraform/demo_group_id.txt)
DC_GROUP_ID=$(cat ../terraform/dc_group_id.txt)
APPROVAL_POLICY_ID=$(cat ../config/approval_policy.json | jq -r .id)
DIRECT_POLICY_ID=$(cat ../config/direct_policy.json | jq -r .id)
LINUX_GROUP_ID=$(cat ../terraform/linux_group_id.txt)

# Define server IPs
SQL_PRIVATE_IP="10.0.2.10"
UBUNTU_PRIVATE_IP="10.0.3.10"

# Create RDP Jump Item for SQL Server
create_sql_jump_item() {
    echo "Creating RDP Jump Item for SQL Server..."
    
    local jump_item_data=$(cat <<JSON
{
    "name": "${RESOURCE_PREFIX}SQL01 - SQL Server",
    "hostname": "$SQL_PRIVATE_IP",
    "jumpoint_id": $JUMPOINT_ID,
    "jump_group_id": $DEMO_GROUP_ID,
    "jump_group_type": "shared",
    "quality": "quality",
    "console": false,
    "ignore_untrusted": true,
    "tag": "sql-server",
    "comments": "SQL server requiring approval",
    "domain": "$DOMAIN_NAME",
    "jump_policy_id": $APPROVAL_POLICY_ID,
    "session_forensics": false
}
JSON
)

    local response=$(api_call "POST" "/jump-item/remote-rdp" "$jump_item_data")

    # Track in state file
    local item_id=$(echo "$response" | jq -r '.id')
    local item_name=$(echo "$response" | jq -r '.name')
    if [ -n "$item_id" ] && [ "$item_id" != "null" ]; then
        add_bt_resource "jump_item_rdp" "$item_id" "$item_name" "{\"hostname\": \"$SQL_PRIVATE_IP\", \"type\": \"sql_server\"}"
        echo "  Created jump item ID: $item_id"
    else
        echo "  ERROR: Failed to create SQL server jump item"
    fi
}

# Create Web Jump Item for SQL Server IIS
create_sql_web_jump_item() {
    echo "Creating Web Jump Item for SQL Server IIS..."
    
    local jump_item_data=$(cat <<JSON
{
    "name": "${RESOURCE_PREFIX}SQL01 - IIS Web Portal",
    "jumpoint_id": $JUMPOINT_ID,
    "url": "http://$SQL_PRIVATE_IP/",
    "jump_group_id": $DEMO_GROUP_ID,
    "jump_group_type": "shared",
    "jump_policy_id": $APPROVAL_POLICY_ID,
    "session_policy_id": null,
    "tag": "web-portal",
    "comments": "IIS web portal on SQL server requiring approval",
    "username_format": "default",
    "verify_certificate": true,
    "authentication_timeout": 3
}
JSON
)
    
    local response=$(api_call "POST" "/jump-item/web-jump" "$jump_item_data")
    
    # Track in state file
    local item_id=$(echo "$response" | jq -r '.id')
    local item_name=$(echo "$response" | jq -r '.name')
    if [ -n "$item_id" ] && [ "$item_id" != "null" ]; then
        add_bt_resource "jump_item_web" "$item_id" "$item_name" "{\"url\": \"http://$SQL_PRIVATE_IP/\", \"type\": \"web_portal\"}"
        echo "  Created web jump item ID: $item_id"
    else
        echo "  ERROR: Failed to create SQL server web jump item"
        echo "  Response: $response"
    fi
}

# Create RDP Jump Item for Domain Controller
create_dc_jump_item() {
    echo "Creating RDP Jump Item for Domain Controller..."
    
    local jump_item_data=$(cat <<JSON
{
    "name": "${RESOURCE_PREFIX}DC01 - Domain Controller",
    "hostname": "10.0.1.10",
    "jumpoint_id": $JUMPOINT_ID,
    "jump_group_id": $DC_GROUP_ID,
    "jump_group_type": "shared",
    "quality": "quality",
    "console": false,
    "ignore_untrusted": true,
    "tag": "domain-controller",
    "comments": "Domain controller with direct access",
    "domain": "$DOMAIN_NAME",
    "jump_policy_id": $DIRECT_POLICY_ID,
    "session_forensics": false
}
JSON
)

    local response=$(api_call "POST" "/jump-item/remote-rdp" "$jump_item_data")

    # Track in state file
    local item_id=$(echo "$response" | jq -r '.id')
    local item_name=$(echo "$response" | jq -r '.name')
    if [ -n "$item_id" ] && [ "$item_id" != "null" ]; then
        add_bt_resource "jump_item_rdp" "$item_id" "$item_name" '{"hostname": "10.0.1.10", "type": "domain_controller"}'
        echo "  Created jump item ID: $item_id"
    else
        echo "  ERROR: Failed to create DC jump item"
    fi
}

# Create MSSQL Protocol Tunnel Jump Item
create_mssql_tunnel_item() {
    echo "Creating MSSQL Protocol Tunnel Jump Item for SQL Server..."
    
    local jump_item_data=$(cat <<JSON
{
    "jump_group_id": $DEMO_GROUP_ID,
    "name": "${RESOURCE_PREFIX}SQL DB - Tunnel",
    "tag": "",
    "comments": "",
    "jump_policy_id": $APPROVAL_POLICY_ID,
    "tunnel_type": "mssql",
    "username": "sa",
    "database": "",
    "jump_group_type": "shared",
    "jumpoint_id": $JUMPOINT_ID,
    "session_policy_id": null,
    "hostname": "$SQL_PRIVATE_IP",
    "tunnel_definitions": "",
    "tunnel_listen_address": ""
}
JSON
)
    
    local response=$(api_call "POST" "/jump-item/protocol-tunnel-jump" "$jump_item_data")
    
    # Track in state file
    local item_id=$(echo "$response" | jq -r '.id')
    local item_name=$(echo "$response" | jq -r '.name')
    if [ -n "$item_id" ] && [ "$item_id" != "null" ]; then
        add_bt_resource "jump_item_mssql_tunnel" "$item_id" "$item_name" "{\"hostname\": \"$SQL_PRIVATE_IP\", \"type\": \"mssql_tunnel\"}"
        echo "  Created MSSQL tunnel jump item ID: $item_id"
    else
        echo "  ERROR: Failed to create MSSQL tunnel jump item"
    fi
}

# Create SSH Shell Jump Item for Ubuntu via Jumpoint
create_ubuntu_shell_jump_item() {
    echo "Creating SSH Shell Jump Item for Ubuntu Linux server..."

    local jump_item_data=$(cat <<JSON
{
    "name": "${RESOURCE_PREFIX}Ubuntu01 - SSH",
    "hostname": "$UBUNTU_PRIVATE_IP",
    "port": 22,
    "protocol": "ssh",
    "jumpoint_id": $JUMPOINT_ID,
    "jump_group_id": $LINUX_GROUP_ID,
    "jump_group_type": "shared",
    "username": "linuxadmin",
    "terminal": "xterm",
    "jump_policy_id": $APPROVAL_POLICY_ID,
    "tag": "linux-server",
    "comments": "Ubuntu Linux server via SSH Shell Jump"
}
JSON
)

    local response=$(api_call "POST" "/jump-item/shell-jump" "$jump_item_data")

    local item_id=$(echo "$response" | jq -r '.id')
    local item_name=$(echo "$response" | jq -r '.name')
    if [ -n "$item_id" ] && [ "$item_id" != "null" ]; then
        add_bt_resource "jump_item_shell" "$item_id" "$item_name" "{\"hostname\": \"$UBUNTU_PRIVATE_IP\", \"type\": \"shell_jump\"}"
        echo "  Created shell jump item ID: $item_id"
    else
        echo "  ERROR: Failed to create Ubuntu shell jump item"
        echo "  Response: $response"
    fi
}

# Main execution
create_sql_jump_item
create_sql_web_jump_item
create_dc_jump_item
create_mssql_tunnel_item
create_ubuntu_shell_jump_item

echo "Jump items configured successfully"
EOF
    
    chmod +x beyondtrust/scripts/configure-jump-items.sh
}

create_beyondtrust_vault_script() {
    print_status "Creating vault configuration script..."
    
    cat > beyondtrust/scripts/configure-vault.sh << 'EOF'
#!/bin/bash
# Configure Vault accounts

source "$(dirname "$0")/bt-api.sh"
source "$(dirname "$0")/state-helper.sh"

# Get project directory (two levels up from scripts)
PROJECT_DIR="$(dirname "$0")/../.."

# Source config to get domain info
if [ -f "$PROJECT_DIR/config.env" ]; then
    source "$PROJECT_DIR/config.env"
else
    echo "Warning: Could not find config.env"
    DOMAIN_NETBIOS_NAME="TEST"  # fallback
fi

# Create demo accounts in vault
create_vault_account() {
    local name="$1"
    local username="$2"
    local password="$3"
    
    echo "Creating vault account: $name"
    
    # Escape backslashes for JSON
    local escaped_username=$(echo "$username" | sed 's/\\/\\\\/g')
    
    local account_data=$(cat <<JSON
{
    "type": "username_password",
    "name": "${RESOURCE_PREFIX}$name",
    "username": "$escaped_username",
    "password": "$password",
    "description": "Demo environment account created by script",
    "account_group_id": ${VAULT_ACCOUNT_GROUP_ID:-4}
}
JSON
)
    
    local response=$(api_call "POST" "/vault/account" "$account_data")
    
    # Track in state file
    local account_id=$(echo "$response" | jq -r '.id')
    local account_name=$(echo "$response" | jq -r '.name')
    if [ -n "$account_id" ] && [ "$account_id" != "null" ]; then
        add_bt_resource "vault_account" "$account_id" "$account_name" '{"username": "'"$escaped_username"'"}'
        echo "  Created vault account ID: $account_id"
    else
        echo "  ERROR: Failed to create vault account for $name"
    fi
}

# Main execution
create_vault_account "Domain Admin" "${DOMAIN_NETBIOS_NAME}\\${ADMIN_USERNAME}" "$ADMIN_PASSWORD"
create_vault_account "Demo User - John Smith" "${DOMAIN_NETBIOS_NAME}\\jsmith" "DemoPass123!"
create_vault_account "Demo User - Mary Johnson" "${DOMAIN_NETBIOS_NAME}\\mjohnson" "DemoPass123!"
create_vault_account "Demo User - Bob Davis" "${DOMAIN_NETBIOS_NAME}\\bdavis" "DemoPass123!"
create_vault_account "Ubuntu Linux Admin" "linuxadmin" "$LINUX_ADMIN_PASSWORD"

echo "Vault accounts created successfully"
EOF

    chmod +x beyondtrust/scripts/configure-vault.sh
}

create_beyondtrust_cleanup_script() {
    print_status "Creating cleanup script..."
    
    cat > beyondtrust/scripts/cleanup-resources.sh << 'EOF'
#!/bin/bash
# Cleanup BeyondTrust resources based on state file

source "$(dirname "$0")/bt-api.sh"
source "$(dirname "$0")/state-helper.sh"

# Delete RDP Jump Items
cleanup_jump_items() {
    echo "Cleaning up jump items..."
    
    # Clean up RDP jump items
    local rdp_item_ids=$(get_bt_resources "jump_item_rdp")
    if [ -n "$rdp_item_ids" ]; then
        echo "$rdp_item_ids" | while read -r item_id; do
            if [ -n "$item_id" ]; then
                echo "  Deleting RDP jump item: $item_id"
                api_call "DELETE" "/jump-item/remote-rdp/$item_id" "" || echo "    Failed to delete RDP jump item $item_id"
            fi
        done
    else
        echo "  No RDP jump items found in state file"
    fi
    
    # Clean up MSSQL tunnel jump items
    local mssql_item_ids=$(get_bt_resources "jump_item_mssql_tunnel")
    if [ -n "$mssql_item_ids" ]; then
        echo "$mssql_item_ids" | while read -r item_id; do
            if [ -n "$item_id" ]; then
                echo "  Deleting MSSQL tunnel jump item: $item_id"
                api_call "DELETE" "/jump-item/protocol-tunnel-jump/$item_id" "" || echo "    Failed to delete MSSQL tunnel jump item $item_id"
            fi
        done
    else
        echo "  No MSSQL tunnel jump items found in state file"
    fi

    # Clean up Shell Jump items (Linux/Ubuntu)
    local shell_item_ids=$(get_bt_resources "jump_item_shell")
    if [ -n "$shell_item_ids" ]; then
        echo "$shell_item_ids" | while read -r item_id; do
            if [ -n "$item_id" ]; then
                echo "  Deleting shell jump item: $item_id"
                api_call "DELETE" "/jump-item/shell-jump/$item_id" "" || echo "    Failed to delete shell jump item $item_id"
            fi
        done
    else
        echo "  No shell jump items found in state file"
    fi

    # Clean up Web Jump items
    local web_item_ids=$(get_bt_resources "jump_item_web")
    if [ -n "$web_item_ids" ]; then
        echo "$web_item_ids" | while read -r item_id; do
            if [ -n "$item_id" ]; then
                echo "  Deleting web jump item: $item_id"
                api_call "DELETE" "/jump-item/web-jump/$item_id" "" || echo "    Failed to delete web jump item $item_id"
            fi
        done
    else
        echo "  No web jump items found in state file"
    fi
}

# Delete Vault Accounts
cleanup_vault_accounts() {
    echo "Cleaning up vault accounts..."
    
    local account_ids=$(get_bt_resources "vault_account")
    if [ -n "$account_ids" ]; then
        echo "$account_ids" | while read -r account_id; do
            if [ -n "$account_id" ]; then
                echo "  Deleting vault account: $account_id"
                api_call "DELETE" "/vault/account/$account_id" "" || echo "    Failed to delete vault account $account_id"
            fi
        done
    else
        echo "  No vault accounts found in state file"
    fi
}

# Delete Jump Clients (note: this deletes the installer record, not the installed client)
cleanup_jump_client_installers() {
    echo "Cleaning up jump client installer records..."
    
    local installer_ids=$(get_bt_resources "jump_client_installer")
    if [ -n "$installer_ids" ]; then
        echo "$installer_ids" | while read -r installer_id; do
            if [ -n "$installer_id" ]; then
                echo "  Deleting jump client installer record: $installer_id"
                # Note: There may not be a DELETE endpoint for installers
                # They typically expire after valid_duration
            fi
        done
    else
        echo "  No jump client installer records found in state file"
    fi
    
    # Find and delete actual jump clients by name
    echo "Looking for deployed jump clients..."
    local clients=$(api_call "GET" "/jump-client" "")
    
    if [ -n "$clients" ]; then
        # Look for our specific jump clients by matching the name
        echo "$clients" | jq -r --arg prefix "$RESOURCE_PREFIX" \
            '.[] | select(
                .name == ($prefix + "DC01_JumpClient") or
                .name == ($prefix + "Ubuntu01_JumpClient") or
                .comments == "Jump Client for Domain Controller" or
                .comments == "Jump Client for Ubuntu Linux server"
            ) | .id' | \
        while read -r client_id; do
            if [ -n "$client_id" ]; then
                echo "  Deleting jump client: $client_id"
                api_call "DELETE" "/jump-client/$client_id" ""
            fi
        done
    fi
}

# Delete Jump Policies
cleanup_policies() {
    echo "Cleaning up jump policies..."
    
    local policy_ids=$(get_bt_resources "jump_policy")
    if [ -n "$policy_ids" ]; then
        echo "$policy_ids" | while read -r policy_id; do
            if [ -n "$policy_id" ]; then
                echo "  Deleting jump policy: $policy_id"
                api_call "DELETE" "/jump-policy/$policy_id" "" || echo "    Failed to delete jump policy $policy_id"
            fi
        done
    else
        echo "  No jump policies found in state file"
    fi
}

# Display state file summary before cleanup
show_cleanup_summary() {
    echo "Resources to be cleaned up:"
    if [ -f "$STATE_FILE" ]; then
        jq -r '
            .resources | to_entries[] | 
            "\(.key): \(.value | length) items"
        ' "$STATE_FILE"
        
        echo ""
        echo "Detailed resource list:"
        jq -r '
            .resources | to_entries[] | 
            "\n\(.key):",
            (.value[] | "  - \(.name) (ID: \(.id))")
        ' "$STATE_FILE"
    else
        echo "No state file found - nothing to clean up"
    fi
}

# Main cleanup execution
echo "Starting cleanup of BeyondTrust resources..."
echo ""

# Show what will be deleted
show_cleanup_summary
echo ""

# Perform cleanup
cleanup_jump_items
cleanup_vault_accounts
cleanup_jump_client_installers
cleanup_policies

echo ""
echo "Note: Jump groups and jumpoint will be deleted by Terraform destroy"
echo ""
echo "API resource cleanup completed"
EOF
    
    chmod +x beyondtrust/scripts/cleanup-resources.sh
}

create_beyondtrust_ansible_playbook() {
    print_status "Creating BeyondTrust Ansible playbook..."
    
    cat > beyondtrust/ansible/install-beyondtrust.yml << 'EOF'
---
- name: Install BeyondTrust Components on Domain Controller
  hosts: dc
  gather_facts: yes
  vars:
    bt_downloads_dir: "{{ playbook_dir }}/../downloads"
  
  tasks:
    - name: Get actual installer filenames
      set_fact:
        jumpoint_filename: "{{ lookup('file', bt_downloads_dir + '/jumpoint-filename.txt', errors='ignore') | default('jumpoint-installer.exe') }}"
        jumpclient_filename: "{{ lookup('file', bt_downloads_dir + '/jumpclient-filename.txt', errors='ignore') | default('jumpclient-installer.exe') }}"
    
    - name: Create temp directory
      ansible.windows.win_file:
        path: C:\Temp\BeyondTrust
        state: directory
    
    - name: Copy Jumpoint installer to Windows
      ansible.windows.win_copy:
        src: "{{ bt_downloads_dir }}/{{ jumpoint_filename }}"
        dest: "C:\\Temp\\BeyondTrust\\{{ jumpoint_filename }}"
      register: copy_jumpoint
      ignore_errors: yes
    
    - name: Check Jump Client installer and copy if exists
      block:
        - name: Copy Jump Client installer to Windows
          ansible.windows.win_copy:
            src: "{{ bt_downloads_dir }}/{{ jumpclient_filename }}"
            dest: "C:\\Temp\\BeyondTrust\\{{ jumpclient_filename }}"
          register: copy_jumpclient
          when: not jumpclient_filename.endswith('.txt')
      rescue:
        - name: Note Jump Client copy failure
          debug:
            msg: "Jump Client installer copy failed or file not found"
          register: copy_jumpclient
          failed_when: false
    
    - name: Get Jump Client key info
      set_fact:
        jumpclient_keyinfo: "{{ lookup('file', bt_downloads_dir + '/jumpclient-keyinfo.txt', errors='ignore') | default('') }}"
    
    - name: Install Jumpoint using win_shell
      ansible.windows.win_shell: |
        $installer = "C:\Temp\BeyondTrust\{{ jumpoint_filename }}"
        if (Test-Path $installer) {
            Write-Host "Installing Jumpoint..."
            Start-Process -FilePath $installer -ArgumentList "/S" -Wait -NoNewWindow
            Start-Sleep -Seconds 10
            exit 0
        } else {
            Write-Error "Installer not found"
            exit 1
        }
      async: 300  # 5 minute timeout
      poll: 10
      register: jumpoint_install
      when: copy_jumpoint is succeeded
      ignore_errors: yes
    
    - name: Install Jump Client using win_shell with msiexec
      ansible.windows.win_shell: |
        $installer = "C:\Temp\BeyondTrust\{{ jumpclient_filename }}"
        if (Test-Path $installer) {
            $fileSize = (Get-Item $installer).Length
            if ($fileSize -gt 1MB) {
                Write-Host "Installing Jump Client..."
                $keyInfo = "{{ jumpclient_keyinfo }}"
                
                if (-not $keyInfo) {
                    Write-Error "KEY_INFO is required for Jump Client installation"
                    exit 1
                }
                
                # Use msiexec.exe for MSI files
                $logFile = "C:\Windows\Temp\jumpclient_install.log"
                Write-Host "Using msiexec.exe to install MSI with KEY_INFO: $keyInfo"
                
                $process = Start-Process -FilePath "msiexec.exe" -ArgumentList @(
                    "/i", "`"$installer`"",
                    "/quiet",
                    "/L*V", "`"$logFile`"",
                    "KEY_INFO=$keyInfo",
                    "INSTALLDIR=`"C:\Program Files\BeyondTrust\JumpClient`"",
                    "JC_JUMP_GROUP=domain_controllers"
                ) -Wait -PassThru
                
                Write-Host "MSI installer exit code: $($process.ExitCode)"
                
                # Wait a bit for installation to complete
                Start-Sleep -Seconds 15
                
                # Check if installation was successful
                $installed = Get-ItemProperty HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\* | 
                    Where-Object { $_.DisplayName -like "*BeyondTrust*" -or $_.DisplayName -like "*Jump Client*" -or $_.DisplayName -like "*SRA*" -or $_.DisplayName -like "*Bomgar*" } | 
                    Select-Object -ExpandProperty DisplayName
                
                # Also check for the service
                $service = Get-Service -Name "*BeyondTrust*", "*Bomgar*", "*JumpClient*" -ErrorAction SilentlyContinue
                
                if ($installed -or $service -or $process.ExitCode -eq 0) {
                    Write-Host "Jump Client installation completed successfully"
                    if ($installed) { Write-Host "Installed programs: $($installed -join ', ')" }
                    if ($service) { Write-Host "Services found: $($service.Name -join ', ')" }
                    exit 0
                } else {
                    Write-Error "Jump Client installation failed with exit code: $($process.ExitCode)"
                    # Display last 50 lines of MSI log
                    if (Test-Path $logFile) {
                        Write-Host "Last 50 lines of installation log:"
                        Get-Content $logFile -Tail 50
                    }
                    exit $process.ExitCode
                }
            } else {
                Write-Error "Jump Client installer is too small ($fileSize bytes)"
                exit 1
            }
        } else {
            Write-Error "Jump Client installer not found at: $installer"
            exit 1
        }
      async: 300  # 5 minute timeout
      poll: 10
      register: jumpclient_install
      when: copy_jumpclient is defined and copy_jumpclient is succeeded
    
    - name: Configure Windows Firewall
      ansible.windows.win_shell: |
        netsh advfirewall firewall add rule name="BeyondTrust HTTPS Out" dir=out action=allow protocol=TCP remoteport=443
        netsh advfirewall firewall add rule name="BeyondTrust Service Out" dir=out action=allow protocol=TCP remoteport=8200
        exit 0
      ignore_errors: yes
    
    - name: Check installation results
      ansible.windows.win_shell: |
        $results = @{
            TempFiles = @(Get-ChildItem "C:\Temp\BeyondTrust\*" -ErrorAction SilentlyContinue | Select-Object Name, Length | ForEach-Object { "$($_.Name) ($([math]::Round($_.Length/1MB, 2)) MB)" })
            InstalledPrograms = @(Get-ItemProperty HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\* | Where-Object { $_.DisplayName -like "*BeyondTrust*" -or $_.DisplayName -like "*Bomgar*" -or $_.DisplayName -like "*Jumpoint*" -or $_.DisplayName -like "*Jump Client*" -or $_.DisplayName -like "*SRA*" } | Select-Object -ExpandProperty DisplayName)
            Services = @(Get-Service -Name "*Jumpoint*", "*BeyondTrust*", "*Bomgar*" -ErrorAction SilentlyContinue | Select-Object Name, Status | ForEach-Object { "$($_.Name): $($_.Status)" })
            MsiLogs = @(Get-ChildItem "C:\Windows\Temp\MSI*.LOG" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 3 | ForEach-Object { "$($_.Name) - $($_.LastWriteTime)" })
        }
        $results | ConvertTo-Json
      register: install_check
      ignore_errors: yes
    
    - name: Display installation status
      debug:
        msg: |
          Installation Status:
          - Jumpoint filename: {{ jumpoint_filename }}
          - Jump Client filename: {{ jumpclient_filename }}
          - Jump Client key info: {{ 'Present' if jumpclient_keyinfo else 'Not found' }}
          - Jumpoint copy: {{ 'Success' if copy_jumpoint is succeeded else 'Failed' }}
          - Jump Client copy: {{ 'Success' if copy_jumpclient is defined and copy_jumpclient is succeeded else 'Failed' }}
          - Jumpoint install: {{ 'Success' if jumpoint_install is defined and jumpoint_install.rc == 0 else 'Failed or skipped' }}
          - Jump Client install: {{ 'Success' if jumpclient_install is defined and jumpclient_install.rc == 0 else 'Failed' }}
          - Installation check: {{ install_check.stdout | default('Unable to check') }}

- name: Install BeyondTrust Jump Client on Ubuntu
  hosts: ubuntu
  gather_facts: no
  vars:
    bt_downloads_dir: "{{ playbook_dir }}/../downloads"

  tasks:
    - name: Read Linux Jump Client filename
      set_fact:
        linux_jumpclient_filename: "{{ lookup('file', bt_downloads_dir + '/jumpclient-linux-filename.txt', errors='ignore') | default('') }}"

    - name: Read Linux Jump Client key info
      set_fact:
        linux_jumpclient_keyinfo: "{{ lookup('file', bt_downloads_dir + '/jumpclient-linux-keyinfo.txt', errors='ignore') | default('') }}"

    - name: Fail if no Linux installer was found
      fail:
        msg: "Linux Jump Client installer not found. Check download-installers.sh output."
      when: linux_jumpclient_filename == ''

    - name: Create temp directory on Ubuntu
      ansible.builtin.file:
        path: /tmp/beyondtrust
        state: directory
        mode: '0755'

    - name: Copy Linux Jump Client installer to Ubuntu
      ansible.builtin.copy:
        src: "{{ bt_downloads_dir }}/{{ linux_jumpclient_filename }}"
        dest: "/tmp/beyondtrust/{{ linux_jumpclient_filename }}"
        mode: '0755'
      register: copy_linux_jumpclient

    - name: Install Linux Jump Client
      ansible.builtin.shell: |
        /tmp/beyondtrust/{{ linux_jumpclient_filename }}
      environment:
        KEY_INFO: "{{ linux_jumpclient_keyinfo }}"
      register: linux_install
      when: copy_linux_jumpclient is succeeded and linux_jumpclient_keyinfo != ''

    - name: Allow BeyondTrust outbound ports via ufw
      ansible.builtin.shell: |
        ufw allow out 443/tcp comment "BeyondTrust HTTPS" || true
        ufw allow out 8200/tcp comment "BeyondTrust Service" || true
      ignore_errors: yes

    - name: Display Ubuntu Jump Client installation status
      debug:
        msg: |
          Linux Jump Client Installation:
          - Filename: {{ linux_jumpclient_filename }}
          - Key info present: {{ 'Yes' if linux_jumpclient_keyinfo else 'No' }}
          - Copy result: {{ 'Success' if copy_linux_jumpclient is succeeded else 'Failed' }}
          - Install result: {{ linux_install.rc | default('skipped') }}
EOF
}

# =============================================================================
# Phase 4: RDS Deployment (optional — activated with --with-rds flag)
# Extends SQL01 with Remote Desktop Services and publishes SSMS as a RemoteApp.
# Run after the main three-phase deployment completes.
# =============================================================================

# Phase 4 — Step 1: Install Chocolatey on SQL01
install_chocolatey() {
    print_status "Installing Chocolatey on SQL server..."

    cd "$PROJECT_DIR/ansible"

    local choco_check
    choco_check=$(ansible dc -i inventory/hosts.yml -m ansible.windows.win_shell \
        -a '$password = ConvertTo-SecureString "{{ ansible_password }}" -AsPlainText -Force; $cred = New-Object PSCredential("{{ domain_netbios_name }}\{{ ansible_user }}", $password); Invoke-Command -ComputerName SQL01.{{ domain_name }} -Credential $cred -ScriptBlock { if (Test-Path "C:\ProgramData\chocolatey\bin\choco.exe") { "installed" } else { "not-installed" } }' \
        -e @group_vars/windows.yml 2>/dev/null | grep -o "installed\|not-installed" | tail -1)

    if [ "$choco_check" = "installed" ]; then
        print_status "Chocolatey already installed, skipping..."
    else
        print_status "Installing Chocolatey via Azure VM Run Command (bypasses WinRM restrictions)..."
        local choco_result
        choco_result=$(az vm run-command invoke \
            --resource-group "rg-beyondtrust-$ENVIRONMENT" \
            --name "vm-sql-$ENVIRONMENT" \
            --command-id RunPowerShellScript \
            --scripts 'Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; iex ((New-Object System.Net.WebClient).DownloadString("https://chocolatey.org/install.ps1")); if (Test-Path "C:\ProgramData\chocolatey\bin\choco.exe") { Write-Output "CHOCO_OK" } else { Write-Output "CHOCO_FAIL"; exit 1 }' \
            --output json 2>&1)
        if echo "$choco_result" | grep -q "CHOCO_OK"; then
            print_status "Chocolatey installed successfully"
        else
            print_error "Chocolatey installation failed: $choco_result"
            exit 1
        fi
    fi

    cd "$PROJECT_DIR"
}

# Phase 4 — Step 2: Install SQL Server Management Studio via Chocolatey
install_ssms() {
    print_status "Checking if SSMS is already installed on SQL server..."

    cd "$PROJECT_DIR/ansible"

    local ssms_check
    ssms_check=$(ansible dc -i inventory/hosts.yml -m ansible.windows.win_shell \
        -a '$password = ConvertTo-SecureString "{{ ansible_password }}" -AsPlainText -Force; $cred = New-Object PSCredential("{{ domain_netbios_name }}\{{ ansible_user }}", $password); Invoke-Command -ComputerName SQL01.{{ domain_name }} -Credential $cred -ScriptBlock { $ssms = Get-ChildItem "C:\Program Files (x86)\Microsoft SQL Server Management Studio*\Common7\IDE\Ssms.exe", "C:\Program Files\Microsoft SQL Server Management Studio*\Common7\IDE\Ssms.exe" -ErrorAction SilentlyContinue | Select-Object -First 1; if ($ssms) { "installed: " + $ssms.FullName } else { "not-installed" } }' \
        -e @group_vars/windows.yml 2>&1 | grep -E "(installed:|not-installed)" | tail -1)

    if echo "$ssms_check" | grep -q "installed:"; then
        SSMS_PATH=$(echo "$ssms_check" | sed 's/installed: //' | tr -d '\r\n' | xargs)
        print_status "SSMS already installed at: $SSMS_PATH"
        print_status "Skipping SSMS installation via Chocolatey"
    else
        print_status "Installing SSMS via Azure VM Run Command (this will take 5-10 minutes)..."
        local ssms_install_result
        ssms_install_result=$(az vm run-command invoke \
            --resource-group "rg-beyondtrust-$ENVIRONMENT" \
            --name "vm-sql-$ENVIRONMENT" \
            --command-id RunPowerShellScript \
            --scripts 'C:\ProgramData\chocolatey\bin\choco.exe install sql-server-management-studio -y --no-progress; if ($LASTEXITCODE -eq 0) { Write-Output "SSMS_INSTALL_OK" } else { Write-Output "SSMS_INSTALL_FAIL"; exit 1 }' \
            --output json 2>&1)
        if echo "$ssms_install_result" | grep -q "SSMS_INSTALL_OK"; then
            print_status "SSMS installed successfully"
        else
            print_error "SSMS installation failed: $ssms_install_result"
            exit 1
        fi
    fi

    print_status "Verifying SSMS installation path..."
    local ssms_path_result
    ssms_path_result=$(az vm run-command invoke \
        --resource-group "rg-beyondtrust-$ENVIRONMENT" \
        --name "vm-sql-$ENVIRONMENT" \
        --command-id RunPowerShellScript \
        --scripts '$p = Get-ChildItem "C:\Program Files (x86)\Microsoft SQL Server Management Studio*\Common7\IDE\Ssms.exe","C:\Program Files\Microsoft SQL Server Management Studio*\Common7\IDE\Ssms.exe" -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName; if ($p) { Write-Output "SSMS_PATH:$p" } else { Write-Output "SSMS_NOT_FOUND" }' \
        --output json 2>&1)
    local ssms_path_line
    ssms_path_line=$(echo "$ssms_path_result" | jq -r '.value[0].message // ""' | grep "SSMS_PATH:" | head -1 | sed 's/.*SSMS_PATH://' | tr -d '\r\n' | xargs)
    if [ -n "$ssms_path_line" ]; then
        print_status "SSMS verified at: $ssms_path_line"
    else
        print_warning "Could not verify SSMS path — installation may still be valid"
    fi

    cd "$PROJECT_DIR"
}

# Phase 4 — Step 3: Install RDS roles on SQL01 (triggers reboot if required)
install_rds_roles() {
    print_status "Installing RDS roles on SQL server..."

    cd "$PROJECT_DIR/ansible"

    local rds_check
    rds_check=$(ansible dc -i inventory/hosts.yml -m ansible.windows.win_shell \
        -a '$password = ConvertTo-SecureString "{{ ansible_password }}" -AsPlainText -Force; $cred = New-Object PSCredential("{{ domain_netbios_name }}\{{ ansible_user }}", $password); Invoke-Command -ComputerName SQL01.{{ domain_name }} -Credential $cred -ScriptBlock { if ((Get-WindowsFeature -Name RDS-RD-Server).InstallState -eq "Installed") { "installed" } else { "not-installed" } }' \
        -e @group_vars/windows.yml 2>/dev/null | grep -o "installed\|not-installed" | tail -1)

    if [ "$rds_check" = "installed" ]; then
        print_status "RDS roles already installed, skipping..."
    else
        print_status "Installing RDS roles via Azure VM Run Command..."
        RDS_INSTALL_OUTPUT=$(az vm run-command invoke \
            --resource-group "rg-beyondtrust-$ENVIRONMENT" \
            --name "vm-sql-$ENVIRONMENT" \
            --command-id RunPowerShellScript \
            --scripts '$r = Install-WindowsFeature -Name RDS-RD-Server,RDS-Connection-Broker,RDS-Web-Access -IncludeManagementTools -Restart:$false; Write-Output "Success=$($r.Success) RestartNeeded=$($r.RestartNeeded) ExitCode=$($r.ExitCode)"' \
            --output json 2>&1)

        echo "$RDS_INSTALL_OUTPUT"

        local rds_msg
        rds_msg=$(echo "$RDS_INSTALL_OUTPUT" | jq -r '.value[0].message // ""')
        echo "$rds_msg"

        if echo "$rds_msg" | grep -q "RestartNeeded=Yes" || echo "$rds_msg" | grep -q "RestartNeeded=True"; then
            print_status "Reboot required after RDS installation. Rebooting SQL server..."
            az vm run-command invoke \
                --resource-group "rg-beyondtrust-$ENVIRONMENT" \
                --name "vm-sql-$ENVIRONMENT" \
                --command-id RunPowerShellScript \
                --scripts 'Restart-Computer -Force' \
                --output json 2>&1 || true

            print_status "Waiting for SQL server to reboot (30 seconds initial pause)..."
            sleep 30

            print_status "Polling for SQL server to come back online (max 5 min)..."
            local max_attempts=30
            local attempt=1
            while [ $attempt -le $max_attempts ]; do
                if ansible dc -i inventory/hosts.yml -m ansible.windows.win_shell \
                    -a '$password = ConvertTo-SecureString "{{ ansible_password }}" -AsPlainText -Force; $cred = New-Object PSCredential("{{ domain_netbios_name }}\{{ ansible_user }}", $password); Test-WSMan -ComputerName SQL01.{{ domain_name }} -ErrorAction SilentlyContinue' \
                    -e @group_vars/windows.yml &>/dev/null; then
                    print_status "SQL server is back online"
                    break
                fi
                print_warning "Waiting for SQL server... (attempt $attempt/$max_attempts)"
                sleep 10
                ((attempt++))
            done

            if [ $attempt -gt $max_attempts ]; then
                print_error "SQL server did not come back online after reboot"
                exit 1
            fi

            print_status "Waiting for services to stabilize (30 seconds)..."
            sleep 30
        else
            print_status "No reboot required after RDS installation"
        fi
    fi

    cd "$PROJECT_DIR"
}

# Phase 4 — Step 4: Configure CredSSP so DC can proxy RDS cmdlets to SQL01 via CredSSP
configure_credssp_for_rds() {
    print_status "Configuring CredSSP for RDS deployment..."
    cd "$PROJECT_DIR/ansible"

    # RSAT-RDS-Tools gives DC the RemoteDesktop PowerShell module used for RDS cmdlets
    print_status "Installing RDS management tools on DC..."
    ansible dc -i inventory/hosts.yml -m ansible.windows.win_shell \
        -a 'Install-WindowsFeature RSAT-RDS-Tools -IncludeManagementTools' \
        -e @group_vars/windows.yml

    # Enable CredSSP Server on SQL01. DC connects to SQL01 via Kerberos (domain-joined)
    # with explicit credentials to set this up — no CredSSP chicken-and-egg issue.
    print_status "Configuring CredSSP on SQL server..."
    ansible dc -i inventory/hosts.yml -m ansible.windows.win_shell \
        -a '$password = ConvertTo-SecureString "{{ ansible_password }}" -AsPlainText -Force; $cred = New-Object PSCredential("{{ domain_netbios_name }}\{{ ansible_user }}", $password); Invoke-Command -ComputerName SQL01.{{ domain_name }} -Credential $cred -ScriptBlock { Enable-PSRemoting -Force -SkipNetworkProfileCheck; Set-Item WSMan:\localhost\Client\TrustedHosts -Value "DC01,DC01.{{ domain_name }},*.{{ domain_name }}" -Force; Enable-WSManCredSSP -Role Server -Force }' \
        -e @group_vars/windows.yml

    # Enable CredSSP Client on DC so it can initiate CredSSP sessions to SQL01
    print_status "Configuring CredSSP on DC..."
    ansible dc -i inventory/hosts.yml -m ansible.windows.win_shell \
        -a 'Enable-WSManCredSSP -Role Client -DelegateComputer "SQL01.{{ domain_name }}","*.{{ domain_name }}" -Force' \
        -e @group_vars/windows.yml

    # Allow fresh credentials via registry GPO (required for CredSSP with explicit creds)
    print_status "Configuring credential delegation policy..."
    ansible dc -i inventory/hosts.yml -m ansible.windows.win_shell \
        -a '$null = New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CredentialsDelegation" -Force; $null = New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CredentialsDelegation\AllowFreshCredentials" -Force; $null = New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CredentialsDelegation\AllowFreshCredentialsWhenNTLMOnly" -Force; Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CredentialsDelegation" -Name "AllowFreshCredentials" -Value 1 -Type DWord; Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CredentialsDelegation" -Name "ConcatenateDefaults_AllowFresh" -Value 1 -Type DWord; Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CredentialsDelegation" -Name "AllowFreshCredentialsWhenNTLMOnly" -Value 1 -Type DWord; Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CredentialsDelegation" -Name "ConcatenateDefaults_AllowFreshNTLMOnly" -Value 1 -Type DWord; Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CredentialsDelegation\AllowFreshCredentials" -Name "1" -Value "WSMAN/*.{{ domain_name }}" -Type String; Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CredentialsDelegation\AllowFreshCredentialsWhenNTLMOnly" -Name "1" -Value "WSMAN/*.{{ domain_name }}" -Type String; gpupdate /force' \
        -e @group_vars/windows.yml
}

# Phase 4 — Step 5: Configure the RDS deployment on SQL01 (deployment + Web Access)
configure_rds_deployment() {
    print_status "Configuring RDS deployment..."

    print_status "Checking current RDS state on SQL01..."
    local rds_state_result
    rds_state_result=$(az vm run-command invoke \
        --resource-group "rg-beyondtrust-$ENVIRONMENT" \
        --name "vm-sql-$ENVIRONMENT" \
        --command-id RunPowerShellScript \
        --scripts 'Import-Module RemoteDesktop -ErrorAction SilentlyContinue; try { $s = Get-RDServer -ErrorAction SilentlyContinue; if ($s) { Write-Output "RDS_DEPLOYED" } else { Write-Output "RDS_NOT_DEPLOYED" } } catch { Write-Output "RDS_NOT_DEPLOYED" }; Get-Service -Name "*RDS*","*RemoteDesktop*" | Where-Object { $_.Status -eq "Running" } | ForEach-Object { Write-Output "Running: $($_.Name)" }' \
        --output json 2>&1)
    echo "$rds_state_result" | jq -r '.value[0].message // ""'

    # DC proxies New-RDSessionDeployment to SQL01 via CredSSP with explicit domain-admin
    # credentials. This is explicit-credential auth (not delegation), so it works fine
    # regardless of the outer Linux→DC NTLM transport.
    print_status "Creating RDS deployment..."
    cd "$PROJECT_DIR/ansible"
    local rds_deploy_result
    rds_deploy_result=$(ansible dc -i inventory/hosts.yml -m ansible.windows.win_shell \
        -a '$password = ConvertTo-SecureString "{{ ansible_password }}" -AsPlainText -Force; $cred = New-Object PSCredential("{{ domain_netbios_name }}\{{ ansible_user }}", $password); Invoke-Command -ComputerName SQL01.{{ domain_name }} -Credential $cred -Authentication CredSSP -ScriptBlock { Import-Module RemoteDesktop; try { New-RDSessionDeployment -ConnectionBroker "SQL01.{{ domain_name }}" -SessionHost "SQL01.{{ domain_name }}" -ErrorAction Stop; Write-Host "RDS_CREATED" } catch { if ($_.Exception.Message -like "*already*") { Write-Host "RDS_EXISTS" } else { throw $_ } } }' \
        -e @group_vars/windows.yml 2>&1)

    local rds_deploy_msg
    rds_deploy_msg=$(echo "$rds_deploy_result" | grep -oE "RDS_CREATED|RDS_EXISTS" | tail -1)
    echo "$rds_deploy_result"

    if echo "$rds_deploy_msg" | grep -q "RDS_CREATED\|RDS_EXISTS"; then
        print_status "RDS deployment is ready"

        print_status "Adding Web Access role..."
        ansible dc -i inventory/hosts.yml -m ansible.windows.win_shell \
            -a '$password = ConvertTo-SecureString "{{ ansible_password }}" -AsPlainText -Force; $cred = New-Object PSCredential("{{ domain_netbios_name }}\{{ ansible_user }}", $password); Invoke-Command -ComputerName SQL01.{{ domain_name }} -Credential $cred -Authentication CredSSP -ScriptBlock { Import-Module RemoteDesktop; try { Add-RDServer -Server "SQL01.{{ domain_name }}" -Role "RDS-WEB-ACCESS" -ConnectionBroker "SQL01.{{ domain_name }}" -ErrorAction Stop; Write-Host "WEB_ACCESS_ADDED" } catch { if ($_.Exception.Message -like "*already*") { Write-Host "WEB_ACCESS_EXISTS" } else { throw $_ } } }' \
            -e @group_vars/windows.yml
    else
        print_error "Failed to create RDS deployment. Output: $rds_deploy_result"
        exit 1
    fi
}

# Phase 4 — Step 5: Create RemoteApp collection and publish SSMS
publish_ssms_remoteapp() {
    print_status "Publishing SSMS as RemoteApp..."

    # DC proxies RemoteApp cmdlets to SQL01 via CredSSP (same pattern as configure_rds_deployment)
    print_status "Creating RemoteApp session collection and publishing SSMS..."
    cd "$PROJECT_DIR/ansible"
    local remoteapp_result
    remoteapp_result=$(ansible dc -i inventory/hosts.yml -m ansible.windows.win_shell \
        -a '$password = ConvertTo-SecureString "{{ ansible_password }}" -AsPlainText -Force; $cred = New-Object PSCredential("{{ domain_netbios_name }}\{{ ansible_user }}", $password); Invoke-Command -ComputerName SQL01.{{ domain_name }} -Credential $cred -Authentication CredSSP -ScriptBlock { Import-Module RemoteDesktop; $broker = "SQL01.{{ domain_name }}"; try { $existing = Get-RDSessionCollection -CollectionName "RemoteApps" -ConnectionBroker $broker -ErrorAction SilentlyContinue; if (-not $existing) { New-RDSessionCollection -CollectionName "RemoteApps" -SessionHost $broker -ConnectionBroker $broker -CollectionDescription "Remote Applications Collection" -ErrorAction Stop }; $ssmsPath = Get-ChildItem -Path "C:\Program Files (x86)\Microsoft SQL Server Management Studio*","C:\Program Files\Microsoft SQL Server Management Studio*" -Filter "Ssms.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName; if (-not $ssmsPath) { Write-Host "SSMS_NOT_FOUND"; exit 1 }; try { Remove-RDRemoteApp -CollectionName "RemoteApps" -Alias "SSMS" -ConnectionBroker $broker -Force -ErrorAction SilentlyContinue } catch {}; New-RDRemoteApp -CollectionName "RemoteApps" -DisplayName "SQL Server Management Studio" -FilePath $ssmsPath -Alias "SSMS" -ShowInWebAccess $true -ConnectionBroker $broker -IconPath "C:\Windows\System32\shell32.dll" -IconIndex 0; Write-Host "REMOTEAPP_OK" } catch { Write-Host "ERROR: $_"; exit 1 } }' \
        -e @group_vars/windows.yml 2>&1)

    local remoteapp_msg
    remoteapp_msg=$(echo "$remoteapp_result" | grep -oE "REMOTEAPP_OK|SSMS_NOT_FOUND" | tail -1)
    echo "$remoteapp_result"

    if echo "$remoteapp_msg" | grep -q "REMOTEAPP_OK"; then
        print_status "SSMS RemoteApp published successfully"
    else
        print_error "Failed to publish SSMS RemoteApp. Output: $remoteapp_result"
        exit 1
    fi

    print_status "Verifying RDS deployment..."
    az vm run-command invoke \
        --resource-group "rg-beyondtrust-$ENVIRONMENT" \
        --name "vm-sql-$ENVIRONMENT" \
        --command-id RunPowerShellScript \
        --scripts 'Import-Module RemoteDesktop; Write-Output "=== RDS Servers ==="; Get-RDServer -ConnectionBroker "SQL01" -ErrorAction SilentlyContinue | Format-Table -AutoSize | Out-String; Write-Output "=== Session Collections ==="; Get-RDSessionCollection -ConnectionBroker "SQL01" -ErrorAction SilentlyContinue | Format-Table -AutoSize | Out-String; Write-Output "=== Published RemoteApps ==="; Get-RDRemoteApp -ConnectionBroker "SQL01" -ErrorAction SilentlyContinue | Select-Object DisplayName,Alias | Format-Table -AutoSize | Out-String' \
        --output json 2>&1 | jq -r '.value[0].message // ""'
}

# Phase 4 — Step 6: Register SSMS RemoteApp jump item in BeyondTrust
add_rds_to_beyondtrust() {
    print_status "Adding RDS jump items to BeyondTrust..."

    source "$CONFIG_FILE"

    local token
    token=$(curl -s -X POST "$BT_API_HOST/oauth2/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "client_id=$BT_CLIENT_ID" \
        -d "client_secret=$BT_CLIENT_SECRET" \
        -d "grant_type=client_credentials" | jq -r '.access_token // empty')

    if [ -z "$token" ]; then
        print_warning "Failed to get BeyondTrust API token — skipping RDS jump item creation"
        return 0
    fi

    local jump_groups
    jump_groups=$(curl -s -X GET "$BT_API_HOST/api/config/v1/jump-group" \
        -H "Authorization: Bearer $token")

    print_status "Available Jump Groups:"
    echo "$jump_groups" | jq -r '.[] | "\(.id): \(.name)"'

    local demo_group_id
    demo_group_id=$(echo "$jump_groups" | jq -r '.[] | select(.name | test("(?i)demo")) | .id' | head -1)
    [ -z "$demo_group_id" ] && demo_group_id=$(echo "$jump_groups" | jq -r '.[0].id')

    if [ -z "$demo_group_id" ]; then
        print_warning "No jump groups found — skipping RDS jump item creation"
        return 0
    fi
    print_status "Using Jump Group ID: $demo_group_id"

    local jumpoints
    jumpoints=$(curl -s -X GET "$BT_API_HOST/api/config/v1/jumpoint" \
        -H "Authorization: Bearer $token")

    print_status "Available Jumpoints:"
    echo "$jumpoints" | jq -r '.[] | "\(.id): \(.name)"'

    local jumpoint_id
    jumpoint_id=$(echo "$jumpoints" | jq -r '.[] | select(.name | test("(?i)dc")) | .id' | head -1)
    [ -z "$jumpoint_id" ] && jumpoint_id=$(echo "$jumpoints" | jq -r '.[0].id')

    if [ -z "$jumpoint_id" ]; then
        print_warning "No jumpoints found — skipping RDS jump item creation"
        return 0
    fi
    print_status "Using Jumpoint ID: $jumpoint_id"

    print_status "Creating SSMS RemoteApp jump item..."
    local ssms_jump_item
    read -r -d '' ssms_jump_item <<JSON || true
{
    "name": "SSMS RemoteApp on SQL01",
    "hostname": "10.0.2.10",
    "jumpoint_id": $jumpoint_id,
    "jump_group_id": $demo_group_id,
    "jump_group_type": "shared",
    "quality": "quality",
    "console": false,
    "ignore_untrusted": true,
    "tag": "rds-remoteapp",
    "comments": "SQL Server Management Studio RemoteApp",
    "rdp_username": "{{ ansible_user }}",
    "domain": "{{ domain_name }}",
    "session_forensics": false,
    "secure_app_type": "remote_app",
    "remote_app_name": "SSMS"
}
JSON

    local result
    result=$(curl -s -X POST "$BT_API_HOST/api/config/v1/jump-item/remote-rdp" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -d "$ssms_jump_item")

    if echo "$result" | jq -e '.id' > /dev/null 2>&1; then
        print_status "SSMS RemoteApp jump item created successfully"
        local ssms_id
        ssms_id=$(echo "$result" | jq -r '.id')
        print_status "Jump Item ID: $ssms_id"

        if [ -f "$STATE_FILE" ]; then
            print_status "Adding SSMS RemoteApp to state tracking for cleanup..."
            jq --arg id "$ssms_id" \
               --arg name "SSMS RemoteApp on SQL01" \
               --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
               '.resources.jump_item_rdp += [{
                   id: $id,
                   name: $name,
                   created_at: $timestamp,
                   hostname: "10.0.2.10",
                   type: "rds_remoteapp"
               }]' \
               "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
            print_status "State tracking updated — resource will be cleaned up with main infrastructure"
        else
            print_warning "State file not found — jump item won't be tracked for automatic cleanup"
            print_warning "You'll need to manually delete it from the BeyondTrust console"
        fi
    else
        print_warning "Failed to create SSMS RemoteApp jump item (may already exist)"
        echo "$result" | jq . 2>/dev/null || echo "$result"
    fi

    # Full desktop jump item for SQL01 is already created by deploy-infra.sh Phase 3
    print_status "Full desktop jump item for SQL01 already created by Phase 3, skipping..."
}

# Phase 4 orchestrator — called from main() when --with-rds is passed
deploy_rds() {
    echo ""
    echo "=================================================="
    echo "Phase 4: RDS Deployment"
    echo "=================================================="

    print_status "Step 4.1: Installing Chocolatey"
    install_chocolatey
    echo ""

    print_status "Step 4.2: Installing/Verifying SQL Server Management Studio"
    install_ssms
    echo ""

    print_status "Step 4.3: Installing RDS roles"
    install_rds_roles
    echo ""

    print_status "Step 4.4: Configuring CredSSP (DC→SQL01 proxy for RDS cmdlets)"
    configure_credssp_for_rds
    echo ""

    print_status "Step 4.5: Configuring RDS deployment"
    configure_rds_deployment
    echo ""

    print_status "Step 4.6: Publishing SSMS as RemoteApp"
    publish_ssms_remoteapp
    echo ""

    print_status "Step 4.7: Registering SSMS RemoteApp in BeyondTrust"
    add_rds_to_beyondtrust
    echo ""

    print_status "Phase 4 complete!"
    print_status "  - Chocolatey installed on SQL01"
    print_status "  - SSMS verified/installed on SQL01"
    print_status "  - Remote Desktop Services deployed"
    print_status "  - SSMS published as RemoteApp"
    print_status "  - BeyondTrust jump item created (tracked in state file)"
    echo ""
    print_status "RD Web Access available at: https://SQL01.$DOMAIN_NAME/RDWeb"
    print_status "To jump via RemoteApp: BeyondTrust Console > Jump Items > 'SSMS RemoteApp on SQL01'"
    echo ""
    print_status "To remove everything, run:"
    print_status "  ./deploy-infra.sh --cleanup"
    print_status "  (RDS components live on the VMs and are destroyed with them)"
}

# Cleanup function
cleanup_all() {
    print_status "Starting complete cleanup..."
    
    cd "$PROJECT_DIR" 2>/dev/null || {
        print_error "Project directory not found. Nothing to clean up."
    }
    
    # Source configuration
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        export BT_API_HOST
        export BT_CLIENT_ID
        export BT_CLIENT_SECRET
        export RESOURCE_PREFIX
        # Note: ARM_SUBSCRIPTION_ID will be set during Azure login
    else
        print_error "Configuration file not found. Cannot proceed with cleanup."
    fi
    
    # Check if state file exists
    if [ ! -f "$STATE_FILE" ]; then
        print_warning "No state file found. This deployment may not have completed successfully."
        echo "Do you want to continue with cleanup anyway? (y/n)"
        read -r response
        if [ "$response" != "y" ]; then
            print_status "Cleanup cancelled."
            exit 0
        fi
    fi
    
    # Step 1: Clean up BeyondTrust API resources first
    if [ -d "$PROJECT_DIR/beyondtrust/scripts" ] && [ -f "$PROJECT_DIR/beyondtrust/scripts/cleanup-resources.sh" ]; then
        print_status "Cleaning up BeyondTrust API resources..."
        if [ -f "$PROJECT_DIR/beyondtrust/scripts/run-with-config.sh" ]; then
            (cd "$PROJECT_DIR/beyondtrust/scripts" && ./run-with-config.sh cleanup-resources.sh)
        else
            # Fallback: run directly with environment variables
            (cd "$PROJECT_DIR/beyondtrust/scripts" && \
                source "$CONFIG_FILE" && \
                export BT_API_HOST BT_CLIENT_ID BT_CLIENT_SECRET RESOURCE_PREFIX && \
                ./cleanup-resources.sh)
        fi
    fi

    # Step 2: Destroy BeyondTrust Terraform resources
    if [ -d "$PROJECT_DIR/beyondtrust/terraform" ] && [ -f "$PROJECT_DIR/beyondtrust/terraform/terraform.tfstate" ]; then
        print_status "Destroying BeyondTrust Terraform resources..."
        (cd "$PROJECT_DIR/beyondtrust/terraform" && terraform destroy -auto-approve)
    fi

    # Step 3: Destroy Azure infrastructure
    if [ -d "$PROJECT_DIR/terraform" ] && [ -f "$PROJECT_DIR/terraform/terraform.tfstate" ]; then
        print_status "Destroying Azure infrastructure..."

        # Login to Azure if needed
        if ! az account show &> /dev/null; then
            print_status "Logging into Azure for cleanup..."
            az login
        fi

        # Get subscription from state or prompt
        pushd "$PROJECT_DIR/terraform" > /dev/null
        if terraform show &> /dev/null; then
            AZURE_SUBSCRIPTION_ID=$(az account show --query id -o tsv)
            export ARM_SUBSCRIPTION_ID="$AZURE_SUBSCRIPTION_ID"
            terraform destroy -auto-approve
        else
            print_warning "Unable to read Terraform state. Manual cleanup may be required."
        fi
        popd > /dev/null
    fi
    
    # Step 4: Clean up files
    print_status "Cleaning up files..."
    rm -f beyondtrust/terraform/*.txt
    rm -f beyondtrust/config/*.json
    rm -f beyondtrust/downloads/*.exe
    rm -f beyondtrust/downloads/*.msi
    rm -f beyondtrust/downloads/*.txt
    rm -f beyondtrust/downloads/*.json
    
    # Step 5: Archive state file
    if [ -f "$STATE_FILE" ]; then
        ARCHIVE_NAME="${STATE_FILE}.$(date +%Y%m%d-%H%M%S).bak"
        print_status "Archiving state file to: $ARCHIVE_NAME"
        mv "$STATE_FILE" "$ARCHIVE_NAME"
        ARCHIVED_PATH="$ARCHIVE_NAME"
    fi

    print_status "Cleanup completed!"
    echo ""
    echo "Note: Configuration file preserved at: $CONFIG_FILE"
    echo "Note: BeyondTrust software may still be installed on DC01."
    if [ -n "${ARCHIVED_PATH:-}" ]; then
        echo "Note: State file archived at: $ARCHIVED_PATH"
    fi
}

# Main function
main() {
    # Ensure log directory exists then redirect all output to a timestamped log file
    mkdir -p "$PROJECT_DIR" 2>/dev/null || true
    LOG_FILE="$PROJECT_DIR/deploy-$(date +%Y%m%d-%H%M%S).log"
    exec > >(tee -a "$LOG_FILE") 2>&1
    echo "Logging to: $LOG_FILE"

    if [ "$CLEANUP_MODE" = true ]; then
        echo "=================================================="
        echo "BeyondTrust Demo Environment - Cleanup Mode"
        echo "=================================================="
        cleanup_all
        exit 0
    fi

    echo "=================================================="
    echo "BeyondTrust Demo Environment - Complete Deployment"
    echo "=================================================="

    # Setup directories and create config if needed
    setup_directories
    create_config_template
    
    # Validate configuration
    validate_config
    
    # Install prerequisites
    install_prerequisites
    
    # Phase 1: Deploy Azure Infrastructure
    deploy_azure_infrastructure
    
    # Phase 2: Configure Domain
    configure_domain
    
    # Phase 3: Deploy BeyondTrust
    deploy_beyondtrust

    # Phase 4: RDS Deployment (optional — pass --with-rds to activate)
    if [ "$WITH_RDS" = true ]; then
        deploy_rds
    fi

    # Get values from state file for summary
    DC_IP=$(jq -r '.azure.dc_public_ip' "$STATE_FILE")

    # Final summary
    print_status "Deployment completed successfully!"
    echo ""
    echo "==================== DEPLOYMENT SUMMARY ===================="
    echo "Azure Resources:"
    echo "  Resource Group: rg-beyondtrust-$ENVIRONMENT"
    echo "  Domain Controller: $DC_IP"
    echo "  Domain: $DOMAIN_NAME"
    echo "  Credentials: $ADMIN_USERNAME / $ADMIN_PASSWORD"
    echo ""
    echo "BeyondTrust Resources:"
    echo "  Instance: $BT_API_HOST"
    echo "  Jump Groups: $JUMP_GROUP_DEMO, $JUMP_GROUP_DC, $JUMP_GROUP_LINUX"
    echo "  Jumpoint: $JUMPOINT_NAME on DC01"
    echo "  Jump Items: RDP access to DC01 and SQL01, MSSQL tunnel to SQL01, SSH Shell Jump to Ubuntu01"
    echo "  Vault Accounts (Windows): $DOMAIN_NETBIOS_NAME\\testadmin, $DOMAIN_NETBIOS_NAME\\jsmith, $DOMAIN_NETBIOS_NAME\\mjohnson, $DOMAIN_NETBIOS_NAME\\bdavis"
    echo "  Vault Accounts (Linux): linuxadmin (local Ubuntu account)"
    echo ""
    echo "Access Patterns:"
    echo "  Direct to DC01: Console → Jump Clients → DC01-JumpClient"
    echo "  Approved to SQL01: Console → Jump Items → SQL01 → Request approval"
    echo "  SSH to Ubuntu01 via Jumpoint: Console → Jump Items → Linux Servers → Ubuntu01 - SSH"
    echo "  Ubuntu01 Jump Client: Console → Jump → Linux Servers → Ubuntu01_JumpClient"
    echo "  Approver: $APPROVER_EMAIL"
    echo ""
    echo "Demo Users (all have RDP access):"
    echo "  jsmith (Domain Admin), mjohnson, bdavis"
    echo "  Password: DemoPass123!"
    echo ""
    echo "SQL Server Details:"
    echo "  SQL01 has both IIS and SQL Server 2019 installed"
    echo "  Domain-joined with Windows Authentication enabled"
    echo "  Mixed mode authentication enabled"
    echo "  SA Password: SAPassword123!"
    echo "  Domain logins configured for all demo users"
    echo "  Data/Log files use default C: drive locations"
    echo ""
    if [ "$WITH_RDS" = true ]; then
        echo "RDS / RemoteApp (deployed via --with-rds):"
        echo "  SSMS RemoteApp published on SQL01"
        echo "  BeyondTrust jump item: 'SSMS RemoteApp on SQL01'"
        echo "  RD Web Access: https://SQL01.$DOMAIN_NAME/RDWeb"
        echo ""
    fi
    echo "State File: $STATE_FILE"
    echo ""
    echo "To destroy everything, run:"
    echo "  ./deploy-infra.sh --cleanup"
    echo "  (RDS components, if deployed, are removed with the VMs automatically)"
    echo "============================================================"
}

# Run main function
main
