#!/bin/bash
# Complete BeyondTrust Demo Environment Deployment Script with State Tracking (FIXED VERSION)
# Incorporates all fixes discovered during initial deployment
# Modified to use SQL Server instead of plain member server
# COST OPTIMIZED VERSION: Reduced storage costs by ~70% through HDD storage, 
# removed unnecessary data disk, reduced OS disk sizes, and Basic SKU public IP
#
# Usage:
#   ./deploy-infra.sh                          # First run creates config, second run deploys
#   ./deploy-infra.sh --cleanup                # Remove only resources created by this script
#   ./deploy-infra.sh --with-rds               # Also deploy RDS roles and publish SSMS RemoteApp
#   ./deploy-infra.sh --group-policy-only      # Only assign asset groups to the group policy
#   ./deploy-infra.sh --group-policy-only --list  # List group policies and jump item roles
#   ./deploy-infra.sh --ssh-ca-only            # Only add SSH certificate login to Ubuntu01
#   ./deploy-infra.sh --k8s-only               # Only add the Kubernetes tunnel (k3s on Ubuntu01)

set -e

usage() {
    cat <<USAGE
Usage: ./deploy-infra.sh [FLAG]

  (no flag)                        Create config on first run, deploy on subsequent runs
  --cleanup                        Remove only the resources created by this script
  --with-rds                       Also deploy RDS roles and publish SSMS as a RemoteApp
  --group-policy-only              Assign the asset (Jump) groups to the group policy only.
                                   Requires an existing deployment; skips Azure, Terraform
                                   and Ansible. Safe to re-run - the assignment is idempotent.
  --group-policy-only --list       Show this instance's group policies, jump item roles and
                                   current assignments without changing anything
  --ssh-ca-only                    Add SSH certificate login (PRA Vault SSH CA) to Ubuntu01 on
                                   an existing deployment. Safe to re-run.
  --k8s-only                       Add the Kubernetes Cluster Tunnel (k3s and a Linux Jumpoint
                                   on Ubuntu01) to an existing deployment. Safe to re-run.
  --help, -h                       Show this message
USAGE
}

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

# Check for --group-policy-only flag. $2 is captured so that --list can be passed
# through to the generated script (main is invoked without "$@").
GROUP_POLICY_ONLY=false
GROUP_POLICY_ARGS=""
if [ "$1" = "--group-policy-only" ]; then
    GROUP_POLICY_ONLY=true
    GROUP_POLICY_ARGS="$2"
fi

# Check for --ssh-ca-only / --k8s-only: add one feature to an existing deployment
SSH_CA_ONLY=false
if [ "$1" = "--ssh-ca-only" ]; then
    SSH_CA_ONLY=true
fi

K8S_ONLY=false
if [ "$1" = "--k8s-only" ]; then
    K8S_ONLY=true
fi

if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    usage
    exit 0
fi

# Reject anything unrecognised rather than silently starting a full deployment
if [ -n "$1" ] && [ "$CLEANUP_MODE" = false ] && [ "$WITH_RDS" = false ] && [ "$GROUP_POLICY_ONLY" = false ] \
    && [ "$SSH_CA_ONLY" = false ] && [ "$K8S_ONLY" = false ]; then
    echo "Unknown option: $1"
    echo ""
    usage
    exit 1
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

# As add_resource, but skips the entry when this type and ID are already recorded, so a
# step that is re-run (e.g. by --k8s-only) does not duplicate the state
add_resource_once() {
    if [ -f "$STATE_FILE" ] && jq -e --arg type "$1" --arg id "$2" \
        '.resources[$type][]? | select(.id == $id)' "$STATE_FILE" > /dev/null 2>&1; then
        return 0
    fi
    add_resource "$@"
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
# Required permissions: Configuration API, Manage Vault Accounts, Group Policy
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

# Group Policy ID that the created asset (Jump) groups are assigned to
# Find this in the BeyondTrust console: Users & Security -> Group Policies
# The default of 2 is the built-in "Administrator" policy
GROUP_POLICY_ID="2"

# Jump Item Role granted to the group policy on those asset groups.
# Pin it by numeric ID here if you know it - find it under Jump -> Jump Item Roles,
# or run ./deploy-infra.sh --group-policy-only --list
JUMP_ITEM_ROLE_ID=""

# If JUMP_ITEM_ROLE_ID is left empty, the role is looked up by this name instead.
# Role IDs differ between instances; names do not, so this is the portable option.
JUMP_ITEM_ROLE_NAME="Administrator"

# To see the group policies and jump item roles on your instance, run:
#   ./deploy-infra.sh --group-policy-only --list"

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

#===========================================
# SSH CERTIFICATE LOGIN (PRA Vault SSH CA)
#===========================================

# Set to false to skip certificate login (needs PRA 23.3.1 or later)
ENABLE_SSH_CA="true"

# Ubuntu user that can only log in with a short lived certificate signed by the PRA
# Vault SSH CA. It is created with no password; its vault account holds the CA, not a secret.
# Must not be LINUX_ADMIN_USERNAME.
LINUX_CERT_USERNAME="certadmin"

#===========================================
# KUBERNETES CLUSTER TUNNEL (k3s on Ubuntu01)
#===========================================

# Set to false to skip the Kubernetes tunnel (needs PRA 24.1.1 or later). It also adds a
# Linux Jumpoint on Ubuntu01, because PRA only runs this tunnel through a Linux Jumpoint.
ENABLE_K8S_TUNNEL="true"

# k3s release to install, e.g. v1.33.4+k3s1. Leave empty for the current stable release.
K3S_VERSION=""
EOF
        
        print_warning "Configuration file created at: $CONFIG_FILE"
        print_warning "Please edit this file and add your BeyondTrust credentials"
        print_status "After configuration, run this script again to deploy"
        exit 0
    fi
}

# Defaults for the certificate login and Kubernetes settings, which older config files do
# not have. deploy_beyondtrust calls this again after it re-reads config.env.
apply_feature_defaults() {
    ENABLE_SSH_CA="${ENABLE_SSH_CA:-true}"
    ENABLE_K8S_TUNNEL="${ENABLE_K8S_TUNNEL:-true}"
    LINUX_CERT_USERNAME="${LINUX_CERT_USERNAME:-certadmin}"
    K3S_VERSION="${K3S_VERSION:-}"
    # Deliberately not configurable: re-reading config.env would drop the prefix from an
    # override, and run-with-config.sh derives the same name
    LINUX_JUMPOINT_NAME="${RESOURCE_PREFIX}Ubuntu01_Jumpoint"
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
    GROUP_POLICY_ID="${GROUP_POLICY_ID:-2}"
    JUMP_ITEM_ROLE_NAME="${JUMP_ITEM_ROLE_NAME-Administrator}"
    LINUX_ADMIN_USERNAME="${LINUX_ADMIN_USERNAME:-linuxadmin}"
    LINUX_ADMIN_PASSWORD="${LINUX_ADMIN_PASSWORD:-UbuntuPass123!}"
    JUMP_GROUP_LINUX="${RESOURCE_PREFIX}${JUMP_GROUP_LINUX:-Linux Servers}"
    apply_feature_defaults

    if [ "$ENABLE_SSH_CA" != true ] && [ "$ENABLE_SSH_CA" != false ]; then
        print_error "ENABLE_SSH_CA must be true or false in $CONFIG_FILE"
    fi
    if [ "$ENABLE_K8S_TUNNEL" != true ] && [ "$ENABLE_K8S_TUNNEL" != false ]; then
        print_error "ENABLE_K8S_TUNNEL must be true or false in $CONFIG_FILE"
    fi

    # Both values end up in scripts that run as root on Ubuntu01, so only plain values are
    # accepted. The certificate user is locked and given passwordless sudo, so it must never
    # be the admin account that the password Shell Jump relies on.
    if ! echo "$LINUX_CERT_USERNAME" | grep -qE '^[a-z_][a-z0-9_-]{0,31}$' \
        || [ "$LINUX_CERT_USERNAME" = "$LINUX_ADMIN_USERNAME" ] || [ "$LINUX_CERT_USERNAME" = "root" ]; then
        print_error "LINUX_CERT_USERNAME must be a new lowercase Linux user name (not root or $LINUX_ADMIN_USERNAME)"
    fi
    if [ -n "$K3S_VERSION" ] && ! echo "$K3S_VERSION" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+\+k3s[0-9]+$'; then
        print_error "K3S_VERSION must look like v1.33.4+k3s1, or be empty for the current stable release"
    fi

    # EXPORT ALL VARIABLES (FIX)
    export BT_API_HOST BT_CLIENT_ID BT_CLIENT_SECRET APPROVER_EMAIL RESOURCE_PREFIX
    export DOMAIN_NAME DOMAIN_NETBIOS_NAME ADMIN_USERNAME ADMIN_PASSWORD
    export JUMP_GROUP_DEMO JUMP_GROUP_DC JUMPOINT_NAME VAULT_ACCOUNT_GROUP_ID
    export LINUX_ADMIN_USERNAME LINUX_ADMIN_PASSWORD JUMP_GROUP_LINUX
    export GROUP_POLICY_ID JUMP_ITEM_ROLE_ID JUMP_ITEM_ROLE_NAME
    export ENABLE_SSH_CA ENABLE_K8S_TUNNEL LINUX_CERT_USERNAME K3S_VERSION LINUX_JUMPOINT_NAME

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

  # k3s API server and kubelet. The only client is the Linux Jumpoint on the same VM,
  # which connects locally and never crosses the NSG, so nothing may reach these ports
  # over the network. The only way to the cluster is through PRA.
  security_rule {
    name                       = "K8s-Deny-Inbound"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["6443", "10250"]
    source_address_prefix      = "*"
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

resource "azurerm_public_ip" "ubuntu" {
  name                = "pip-ubuntu-${var.environment}"
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
    public_ip_address_id          = azurerm_public_ip.ubuntu.id
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

output "ubuntu_public_ip" {
  value = azurerm_public_ip.ubuntu.ip_address
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

# Assign asset groups to the group policy against an already-deployed environment.
# Skips Azure, Terraform and Ansible entirely - see --group-policy-only.
run_group_policy_assignment_only() {
    print_status "Assigning asset groups to group policy (existing deployment)..."

    if [ ! -f "$STATE_FILE" ]; then
        print_error "No deployment state found at $STATE_FILE. Run ./deploy-infra.sh first."
    fi

    cd "$PROJECT_DIR"

    # Regenerate the scripts this step needs so they match the current source
    create_beyondtrust_api_helper
    create_beyondtrust_state_helper
    create_beyondtrust_run_wrapper
    create_beyondtrust_group_policy_script

    (cd "$PROJECT_DIR/beyondtrust/scripts" && ./run-with-config.sh configure-group-policy.sh $GROUP_POLICY_ARGS)
}

# =============================================================================
# Ubuntu01: SSH certificate login and the Kubernetes Cluster Tunnel
# Everything on the VM goes through Azure run-command, as the Jump Client install does.
# These steps are optional: callers treat a non-zero return as "not configured", so each
# function returns 1 on failure rather than calling print_error.
# =============================================================================

# Quote a value for a POSIX sh script: wrap it in single quotes, escaping any inside it
sh_quote() {
    local s=${1//\'/\'\\\'\'}
    printf "'%s'" "$s"
}

# Build a script for Ubuntu01: NAME=value lines (quoted with sh_quote), then the body that
# the function named in $1 prints. Values only ever reach the VM as variables, so the
# bodies are quoted heredocs that need no escaping. Usage: build_remote_script FN [NAME VALUE]...
build_remote_script() {
    local body_fn="$1"
    shift
    while [ $# -ge 2 ]; do
        printf '%s=%s\n' "$1" "$(sh_quote "$2")"
        shift 2
    done
    "$body_fn"
}

# Run a script on Ubuntu01 and leave the combined output in RUN_MESSAGE rather than
# printing it, so callers decide what to show (never secrets). Returns 1 only when az
# itself fails: run-command reports success even when the script fails, so callers read
# the script's own NAME_OK / NAME_FAILED marker instead of an exit code.
run_on_ubuntu() {
    local script="$1"
    local subscription result err_file
    local sub_args=()

    RUN_MESSAGE=""
    # Standalone runs may start with a different default subscription in az
    subscription=$(jq -r '.azure.subscription_id // empty' "$STATE_FILE" 2>/dev/null)
    if [ -n "$subscription" ]; then
        sub_args=(--subscription "$subscription")
    fi

    err_file=$(mktemp)
    if ! result=$(az vm run-command invoke "${sub_args[@]}" \
        --resource-group "rg-beyondtrust-${ENVIRONMENT}" \
        --name "vm-ubuntu-${ENVIRONMENT}" \
        --command-id RunShellScript \
        --scripts "$script" \
        --only-show-errors \
        --output json 2>"$err_file"); then
        print_warning "Azure run-command on Ubuntu01 failed: $(head -c 600 "$err_file")"
        rm -f "$err_file"
        return 1
    fi
    rm -f "$err_file"
    RUN_MESSAGE=$(echo "$result" | jq -r '.value[0].message // empty' 2>/dev/null)
}

# Print the value of the last "NAME:value" line in the [stdout] part of RUN_MESSAGE.
# Only stdout counts, so nothing written to stderr can pass for a marker.
ubuntu_marker() {
    printf '%s\n' "$RUN_MESSAGE" | awk -v m="$1:" '
        $0 == "[stdout]" { s = 1; next }
        $0 == "[stderr]" { s = 0; next }
        s && index($0, m) == 1 { v = substr($0, length(m) + 1); f = 1 }
        END { if (f && v != "") print v; else exit 1 }'
}

# Run a remote script that ends with MARKER_OK:<info> or MARKER_FAILED:<reason>, report
# the result, and print the script's output (which ends with its log) when it failed
run_ubuntu_step() {
    local label="$1"
    local marker="$2"
    local script="$3"
    local value

    run_on_ubuntu "$script" || return 1
    if value=$(ubuntu_marker "${marker}_OK"); then
        print_status "$label: $value"
        return 0
    fi
    print_warning "$label failed: $(ubuntu_marker "${marker}_FAILED" || echo "no result from the script")"
    printf '%s\n' "$RUN_MESSAGE"
    return 1
}

# Remote script: install the Linux Jumpoint and run it under systemd.
# Needs BT_API_HOST, BT_TOKEN and JUMPOINT_ID.
remote_jumpoint_body() {
    cat <<'REMOTE'
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
JP_DIR=/opt/beyondtrust/jumpoint
JP_USER=prajumpoint
UNIT=/etc/systemd/system/pra-jumpoint.service
mkdir -p /var/log/pra-demo
LOG=/var/log/pra-demo/jumpoint.log
APT_LOG=/var/log/pra-demo/jumpoint-apt.log
# fail REASON [LOGFILE [BYTES]]: print the end of the log that explains it, then the marker
fail() {
    echo "--- end of ${2:-$LOG} ---"
    tail -c "${3:-1500}" "${2:-$LOG}" 2>/dev/null
    echo "JUMPOINT_FAILED:$1"
    exit 0
}
LIBS_NOTE=""

export DEBIAN_FRONTEND=noninteractive
APT="apt-get -o DPkg::Lock::Timeout=300 -y -q --no-install-recommends"
# apt is chatty, so it gets its own log and the failure output shows the installer instead.
# The package lists are refreshed once per run, only when something is about to be installed.
APT_UPDATED=0
apt_update() {
    [ "$APT_UPDATED" = 1 ] && return 0
    apt-get -o DPkg::Lock::Timeout=300 -q update >>"$APT_LOG" 2>&1
    APT_UPDATED=1
}

# True when apt can actually install the package. apt-cache show also succeeds for virtual
# names (on Ubuntu 24.04 libasound2 only points at libasound2t64), which apt then refuses.
# (sh has no local variables, so the name must not clash with pkg_for_lib's)
installable() {
    apt_candidate=$(apt-cache policy "$1" 2>/dev/null | sed -n 's/^ *Candidate: *//p' | head -n 1)
    [ -n "$apt_candidate" ] && [ "$apt_candidate" != "(none)" ]
}

# Print the package that provides a shared library, guessed from its soname and confirmed
# with apt: libpulse.so.0 -> libpulse0, libGL.so.1 -> libgl1, libglib-2.0.so.0 -> libglib2.0-0t64,
# libnetfilter_queue.so.1 -> libnetfilter-queue1 (package names cannot contain underscores)
pkg_for_lib() {
    name=$(echo "${1%%.so*}" | tr '[:upper:]_' '[:lower:]-')
    ver=""
    case "$1" in *.so.*) ver=${1##*.so.}; ver=${ver%%.*} ;; esac
    for base in "$name" "$(echo "$name" | sed 's/-\([0-9]\)/\1/')"; do
        for cand in "$base$ver" "$base-$ver" "${base}${ver}t64" "$base-${ver}t64"; do
            if installable "$cand"; then
                echo "$cand"
                return 0
            fi
        done
    done
    return 1
}

# init-script is run as root and switches to this user with su, which needs a real shell
# (nologin makes su print "This account is currently not available" and start nothing).
# The account stays locked, with no password or keys, so it still cannot be logged in to.
if ! id "$JP_USER" >/dev/null 2>&1; then
    useradd --system --home-dir "$JP_DIR" --shell /bin/sh "$JP_USER" >>"$LOG" 2>&1 \
        || fail "could not create user $JP_USER"
fi
usermod --shell /bin/sh "$JP_USER" >>"$LOG" 2>&1 || fail "could not set the shell of $JP_USER"
usermod --lock "$JP_USER" >>"$LOG" 2>&1 || fail "could not lock $JP_USER"

# Install when missing, or reinstall when this VM holds a different Jumpoint (recreated in PRA)
CHANGED=0
if [ ! -x "$JP_DIR/init-script" ] || [ "$(cat "$JP_DIR/.pra-jumpoint-id" 2>/dev/null)" != "$JUMPOINT_ID" ]; then
    if [ -x "$JP_DIR/init-script" ]; then
        systemctl stop pra-jumpoint.service >>"$LOG" 2>&1
        "$JP_DIR/init-script" stop >>"$LOG" 2>&1
        rm -rf "$JP_DIR"
    fi
    WORK=$(mktemp -d)
    (cd "$WORK" && curl -fsS -J -O -H "Authorization: Bearer $BT_TOKEN" \
        "$BT_API_HOST/api/config/v1/jumpoint/$JUMPOINT_ID/installer") >>"$LOG" 2>&1 \
        || fail "installer download failed"
    set -- "$WORK"/*
    if [ $# -ne 1 ] || [ ! -f "$1" ] || [ "$(stat -c %s "$1")" -lt 1000000 ]; then
        fail "unexpected installer download: $*"
    fi
    INSTALLER="$1"

    # The Jumpoint binary links against desktop libraries (audio, X, GL) that a server image
    # does not ship. Install the ones BeyondTrust recommends, plus libpulse, up front; names
    # this release does not know are skipped rather than failing the whole install.
    apt_update
    BASE_PKGS=""
    # The web engine (sra-web) also needs the GTK 3 and Chromium runtime stack, and the
    # protocol tunnel (sra-tnl) needs libnetfilter_queue. Both the older and the t64
    # package names are listed; apt-cache drops whichever does not exist.
    for p in libpulse0 libglx0 libgl1 libegl1 libxkbcommon0 libxkbcommon-x11-0 libfontconfig1 \
        libfreetype6 libx11-6 libx11-xcb1 libxcb1 libxext6 libxrender1 libdbus-1-3 \
        libcairo2 libpango-1.0-0 libpangocairo-1.0-0 libgdk-pixbuf-2.0-0 libgtk-3-0 libgtk-3-0t64 \
        libatk1.0-0 libatk1.0-0t64 libatk-bridge2.0-0 libatk-bridge2.0-0t64 libglib2.0-0 \
        libglib2.0-0t64 libnss3 libnspr4 libasound2 libasound2t64 libcups2 libcups2t64 libgbm1 \
        libdrm2 libxshmfence1 libxcomposite1 libxcursor1 libxdamage1 libxfixes3 libxi6 libxinerama1 \
        libxrandr2 libxss1 libxtst6 libexpat1 fonts-liberation libnetfilter-queue1; do
        if installable "$p"; then BASE_PKGS="$BASE_PKGS $p"; fi
    done
    # One package apt will not take should not block the rest, so fall back to one at a time.
    # Anything still missing is reported by the installer and handled by the loop below.
    if ! $APT install $BASE_PKGS >>"$APT_LOG" 2>&1; then
        for p in $BASE_PKGS; do
            $APT install "$p" >>"$APT_LOG" 2>&1 || echo "Could not install $p, continuing" >>"$LOG"
        done
    fi

    # The loader only names the first missing library, so install whatever the installer
    # reports and try again, a bounded number of times
    EXTRA_PKGS=""
    LAST_LIB=""
    TRIES=0
    while :; do
        TRIES=$((TRIES + 1))
        # A failed attempt can leave files behind, and the installer refuses a directory that
        # already exists, so remove it and let the installer create it for $JP_USER
        rm -rf "$JP_DIR"
        mkdir -p "$(dirname "$JP_DIR")" || fail "could not create $(dirname "$JP_DIR")"

        echo "Installing $(basename "$INSTALLER") (attempt $TRIES)" >>"$LOG"
        ATTEMPT=$(mktemp)
        # No terminal to answer a prompt, so give up rather than hang until run-command times out
        timeout 900 sh "$INSTALLER" --install-dir "$JP_DIR" --user "$JP_USER" </dev/null >"$ATTEMPT" 2>&1
        RC=$?
        cat "$ATTEMPT" >>"$LOG"
        LIB=$(sed -n 's/.*error while loading shared libraries: \([^:]*\):.*/\1/p' "$ATTEMPT" | tail -n 1)
        rm -f "$ATTEMPT"
        [ "$RC" -eq 0 ] && break

        [ -n "$LIB" ] || fail "installer exited with status $RC"
        [ "$LIB" != "$LAST_LIB" ] || fail "missing library $LIB is still missing after installing its package"
        [ "$TRIES" -lt 30 ] || fail "libraries still missing after $TRIES attempts (last: $LIB)"
        PKG=$(pkg_for_lib "$LIB") || fail "missing library $LIB, no package found for it"
        echo "Installing $PKG for $LIB" >>"$LOG"
        $APT install "$PKG" >>"$APT_LOG" 2>&1 || fail "could not install $PKG for $LIB" "$APT_LOG"
        EXTRA_PKGS="$EXTRA_PKGS $PKG"
        LAST_LIB="$LIB"
    done
    rm -rf "$WORK"
    # The installer should hand the directory to --user; make sure, without failing on it
    chown -R "$JP_USER" "$JP_DIR" >>"$LOG" 2>&1 || echo "Could not chown $JP_DIR to $JP_USER" >>"$LOG"
    if [ -n "$EXTRA_PKGS" ]; then LIBS_NOTE="; also installed$EXTRA_PKGS"; fi
    [ -x "$JP_DIR/init-script" ] || fail "no init-script in $JP_DIR after the install"
    echo "$JUMPOINT_ID" > "$JP_DIR/.pra-jumpoint-id"
    CHANGED=1
fi

# The installer only runs some of the Jumpoint's binaries. Others, such as the protocol tunnel
# (sra-tnl), are first loaded when a session starts, so check every binary with ldd on every
# run and install what they are missing. Libraries shipped inside $JP_DIR are left alone.
missing_libs() {
    find "$JP_DIR" -type f \( -perm -u+x -o -name '*.so*' \) 2>/dev/null | while read -r f; do
        ldd "$f" 2>/dev/null | sed -n 's/^[[:space:]]*\([^[:space:]]*\) => not found.*/\1/p'
    done | sort -u | while read -r lib; do
        [ -n "$(find "$JP_DIR" -name "$lib" 2>/dev/null | head -n 1)" ] || echo "$lib"
    done
}
# A new library can need another one, so repeat a few rounds while each one adds something
ROUND=0
MISSING=$(missing_libs)
while [ -n "$MISSING" ] && [ "$ROUND" -lt 5 ]; do
    ROUND=$((ROUND + 1))
    echo "ldd round $ROUND, missing: $(echo "$MISSING" | tr '\n' ' ')" >>"$LOG"
    ADDED=""
    for lib in $MISSING; do
        apt_update
        if PKG=$(pkg_for_lib "$lib") && $APT install "$PKG" >>"$APT_LOG" 2>&1; then
            echo "Installing $PKG for $lib" >>"$LOG"
            ADDED="$ADDED $PKG"
        else
            echo "No package found or installed for $lib" >>"$LOG"
        fi
    done
    [ -n "$ADDED" ] || break
    case "$LIBS_NOTE" in
        "") LIBS_NOTE="; also installed$ADDED" ;;
        *) LIBS_NOTE="$LIBS_NOTE$ADDED" ;;
    esac
    CHANGED=1
    MISSING=$(missing_libs)
done
# Not fatal, since a helper binary may never be used, but named so a failed session is easy to explain
if [ -n "$MISSING" ]; then
    LIBS_NOTE="$LIBS_NOTE; unresolved libraries: $(echo "$MISSING" | tr '\n' ' ')(see $LOG)"
fi

# The installer prints an example systemd unit (also kept in its POST-INSTALL-NOTES.txt).
# Follow its Type= when it has one, otherwise wrap init-script the way systemd wraps a
# classic init script. Its User= is deliberately ignored: init-script must run as root and
# does its own su, which would ask for a password if run as the Jumpoint user.
NOTES="$JP_DIR/POST-INSTALL-NOTES.txt"
HINT_FILES="$LOG"
if [ -f "$NOTES" ]; then HINT_FILES="$LOG $NOTES"; fi
grep -hE '^[[:space:]]*(Type|User|ExecStart|PIDFile)=' $HINT_FILES | sort -u | head -n 8 | sed 's/^[[:space:]]*/JUMPOINT_UNIT_HINT:/'
UNIT_TYPE=$(sed -n 's/^[[:space:]]*Type=\([a-z]*\).*/\1/p' $HINT_FILES | tail -n 1)
[ -n "$UNIT_TYPE" ] || UNIT_TYPE=forking
{
    echo "[Unit]"
    echo "Description=BeyondTrust PRA Linux Jumpoint"
    echo "After=network-online.target"
    echo "Wants=network-online.target"
    echo ""
    echo "[Service]"
    echo "Type=$UNIT_TYPE"
    echo "ExecStart=$JP_DIR/init-script start"
    echo "ExecStop=$JP_DIR/init-script stop"
    # init-script's su opens a login session, which moves the Jumpoint out of this unit's
    # cgroup. Without RemainAfterExit systemd then sees an empty unit, decides it died and
    # runs ExecStop, killing it. This is how systemd itself wraps classic init scripts.
    echo "RemainAfterExit=yes"
    echo "GuessMainPID=no"
    echo "KillMode=process"
    echo "TimeoutStartSec=120"
    echo ""
    echo "[Install]"
    echo "WantedBy=multi-user.target"
} > "$UNIT.new"
if cmp -s "$UNIT.new" "$UNIT"; then
    rm -f "$UNIT.new"
else
    mv "$UNIT.new" "$UNIT"
    systemctl daemon-reload >>"$LOG" 2>&1
    CHANGED=1
fi

jumpoint_running() {
    "$JP_DIR/init-script" status >/dev/null 2>&1 && pgrep -u "$JP_USER" >/dev/null 2>&1
}

# Everything that helps explain a Jumpoint that will not stay up, for the failure output
jumpoint_diagnostics() {
    DIAG=/var/log/pra-demo/jumpoint-diag.log
    {
        echo "--- end of $LOG ---"
        tail -c 600 "$LOG" 2>/dev/null
        echo "--- init-script status ---"
        "$JP_DIR/init-script" status 2>&1 | tail -n 5
        echo "--- processes of $JP_USER ---"
        ps -u "$JP_USER" -o pid,cmd 2>&1 | head -n 6
        echo "--- $JP_DIR/POST-INSTALL-NOTES.txt ---"
        head -c 1200 "$JP_DIR/POST-INSTALL-NOTES.txt" 2>/dev/null
    } > "$DIAG" 2>&1
}

# Anything the installer started runs outside systemd, so stop it and let the unit own it
if ! systemctl is-active --quiet pra-jumpoint.service; then
    "$JP_DIR/init-script" stop >>"$LOG" 2>&1
fi
systemctl enable pra-jumpoint.service >>"$LOG" 2>&1 || fail "could not enable pra-jumpoint.service"
# With RemainAfterExit the unit can read "active" while the Jumpoint is gone, so restart
# whenever it is not actually running, not only when something changed
if [ "$CHANGED" = 1 ] || ! jumpoint_running; then
    systemctl restart pra-jumpoint.service >>"$LOG" 2>&1
else
    systemctl start pra-jumpoint.service >>"$LOG" 2>&1
fi

# Judge by the Jumpoint itself: its own status check and a process running as its user
i=0
until jumpoint_running; do
    i=$((i + 1))
    if [ "$i" -gt 15 ]; then
        systemctl status pra-jumpoint.service --no-pager >>"$LOG" 2>&1
        jumpoint_diagnostics
        fail "the Jumpoint is not running 30 seconds after starting pra-jumpoint.service" "$DIAG" 2800
    fi
    sleep 2
done
systemctl is-active --quiet pra-jumpoint.service || fail "pra-jumpoint.service is not active"
echo "JUMPOINT_OK:running under systemd as pra-jumpoint.service (Type=$UNIT_TYPE)$LIBS_NOTE"
exit 0
REMOTE
}

# Remote script: install k3s, create the demo service accounts and a small demo app.
# Needs K3S_VERSION (empty for the stable release).
remote_k3s_body() {
    cat <<'REMOTE'
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
mkdir -p /var/log/pra-demo
LOG=/var/log/pra-demo/k3s.log
fail() {
    echo "--- end of $LOG ---"
    tail -c 1500 "$LOG" 2>/dev/null
    echo "K3S_FAILED:$1"
    exit 0
}
kc() { k3s kubectl "$@"; }

# Settings go in config.yaml, which k3s reads on every start, so re-runs converge.
# The API certificate must name 10.0.3.10, the address the Linux Jumpoint connects to.
mkdir -p /etc/rancher/k3s
cat > /etc/rancher/k3s/config.yaml.new <<'YAML'
# Written by deploy-infra.sh for the BeyondTrust PRA demo
tls-san:
  - "10.0.3.10"
write-kubeconfig-mode: "0600"
disable:
  - traefik
  - servicelb
YAML
CONFIG_CHANGED=0
if cmp -s /etc/rancher/k3s/config.yaml.new /etc/rancher/k3s/config.yaml; then
    rm -f /etc/rancher/k3s/config.yaml.new
else
    mv /etc/rancher/k3s/config.yaml.new /etc/rancher/k3s/config.yaml
    CONFIG_CHANGED=1
fi

if ! command -v k3s >/dev/null 2>&1; then
    # Download, then run: sh has no pipefail, so curl | sh would hide a failed download
    curl -fsSL https://get.k3s.io -o /tmp/k3s-install.sh >>"$LOG" 2>&1 || fail "could not download the k3s installer"
    INSTALL_K3S_VERSION="$K3S_VERSION" sh /tmp/k3s-install.sh >>"$LOG" 2>&1 || fail "the k3s installer failed"
    rm -f /tmp/k3s-install.sh
elif [ "$CONFIG_CHANGED" = 1 ]; then
    systemctl restart k3s >>"$LOG" 2>&1 || fail "k3s did not restart"
else
    systemctl start k3s >>"$LOG" 2>&1 || fail "k3s did not start"
fi

i=0
until kc get --raw /readyz >/dev/null 2>&1; do
    i=$((i + 1))
    [ "$i" -le 60 ] || fail "the API server was not ready after 5 minutes"
    sleep 5
done
# wait fails at once if no node has registered yet, so wait for one to exist first
i=0
until [ -n "$(kc get nodes -o name 2>/dev/null)" ]; do
    i=$((i + 1))
    [ "$i" -le 60 ] || fail "no node registered"
    sleep 2
done
kc wait --for=condition=Ready node --all --timeout=300s >>"$LOG" 2>&1 || fail "the node is not Ready"

# Service accounts come before their token Secrets, which are deleted if created first
kc apply -f - >>"$LOG" 2>&1 <<'YAML' || fail "could not apply the demo manifests"
apiVersion: v1
kind: Namespace
metadata:
  name: pra-demo
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: pra-admin
  namespace: pra-demo
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: pra-readonly
  namespace: pra-demo
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: pra-demo-admin
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
  - kind: ServiceAccount
    name: pra-admin
    namespace: pra-demo
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: pra-demo-readonly
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: view
subjects:
  - kind: ServiceAccount
    name: pra-readonly
    namespace: pra-demo
---
apiVersion: v1
kind: Secret
metadata:
  name: pra-admin-token
  namespace: pra-demo
  annotations:
    kubernetes.io/service-account.name: pra-admin
type: kubernetes.io/service-account-token
---
apiVersion: v1
kind: Secret
metadata:
  name: pra-readonly-token
  namespace: pra-demo
  annotations:
    kubernetes.io/service-account.name: pra-readonly
type: kubernetes.io/service-account-token
---
apiVersion: v1
kind: Namespace
metadata:
  name: demo-apps
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: demo-apps
spec:
  replicas: 2
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
        - name: nginx
          image: nginx:1.27-alpine
          ports:
            - containerPort: 80
YAML

for sa in pra-admin pra-readonly; do
    i=0
    until [ -n "$(kc -n pra-demo get secret "$sa-token" -o jsonpath='{.data.token}' 2>/dev/null)" ]; do
        i=$((i + 1))
        [ "$i" -le 60 ] || fail "no token was issued for $sa"
        sleep 2
    done
done

# Prove the two identities really differ before PRA vaults them
[ "$(kc auth can-i delete pods -n demo-apps --as=system:serviceaccount:pra-demo:pra-readonly 2>/dev/null)" = "no" ] \
    || fail "pra-readonly can delete pods, so it is not read only"
[ "$(kc auth can-i '*' '*' --as=system:serviceaccount:pra-demo:pra-admin 2>/dev/null)" = "yes" ] \
    || fail "pra-admin is not cluster-admin"

WARN=""
kc -n demo-apps rollout status deployment/web --timeout=180s >>"$LOG" 2>&1 || WARN=", demo app still starting"
echo "K3S_OK:$(k3s --version | head -n 1 | cut -d' ' -f3) ready$WARN"
exit 0
REMOTE
}

# Remote script: print the cluster CA and both service account tokens. Its output holds
# secrets, so the caller parses it and never prints it. Order matters: run-command keeps
# the end of the output, so the OK marker comes last and every item is checked.
remote_k8s_export_body() {
    cat <<'REMOTE'
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
fail() {
    echo "K8S_EXPORT_FAILED:$1"
    exit 0
}
CA=/var/lib/rancher/k3s/server/tls/server-ca.crt
[ -s "$CA" ] || fail "no cluster CA at $CA"

for sa in pra-admin pra-readonly; do
    t=$(k3s kubectl -n pra-demo get secret "$sa-token" -o jsonpath='{.data.token}' 2>/dev/null | base64 -d 2>/dev/null)
    [ -n "$t" ] || fail "no token for $sa"
    # One request proves the CA, the certificate name and the token together
    code=$(curl -s -o /dev/null -w '%{http_code}' --cacert "$CA" -H "Authorization: Bearer $t" https://10.0.3.10:6443/api)
    [ "$code" = "200" ] || fail "https://10.0.3.10:6443 rejected the $sa token (HTTP $code)"
    echo "K8S_TOKEN_$sa:$t"
done
echo "K8S_CA_B64:$(base64 -w0 "$CA")"
echo "K8S_EXPORT_OK:2 tokens"
exit 0
REMOTE
}

# Remote script: trust the PRA Vault SSH CA for a certificate only user.
# Needs CERT_USER and CA_KEY (the bare public key, no cert-authority prefix).
remote_ssh_ca_body() {
    cat <<'REMOTE'
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
MARK="PRA certificate login demo"
CA_FILE=/etc/ssh/pra_user_ca.pub
DROPIN=/etc/ssh/sshd_config.d/60-pra-ssh-ca.conf
SUDOERS=/etc/sudoers.d/60-pra-cert-user
mkdir -p /var/log/pra-demo
LOG=/var/log/pra-demo/ssh-ca.log
fail() {
    echo "--- end of $LOG ---"
    tail -c 1500 "$LOG" 2>/dev/null
    echo "SSH_CA_FAILED:$1"
    exit 0
}

# Only ever manage a user this script created, so an existing account (such as the admin
# account the password Shell Jump uses) can never be locked by mistake
if id "$CERT_USER" >/dev/null 2>&1; then
    [ "$(getent passwd "$CERT_USER" | cut -d: -f5)" = "$MARK" ] \
        || fail "user $CERT_USER already exists and was not created by this script"
else
    useradd --create-home --shell /bin/bash --comment "$MARK" "$CERT_USER" >>"$LOG" 2>&1 \
        || fail "could not create $CERT_USER"
fi
# No usable password: a certificate signed by the PRA CA is the only way in
usermod --lock "$CERT_USER" >>"$LOG" 2>&1 || fail "could not lock the password of $CERT_USER"

# Passwordless sudo, since the account has no password to type (demo convenience)
TMP=$(mktemp)
printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$CERT_USER" > "$TMP"
if ! visudo -cf "$TMP" >>"$LOG" 2>&1; then
    rm -f "$TMP"
    fail "the sudoers entry did not validate"
fi
install -m 0440 -o root -g root "$TMP" "$SUDOERS" || fail "could not install $SUDOERS"
rm -f "$TMP"

printf '%s\n' "$CA_KEY" > "$CA_FILE.new"
FP=$(ssh-keygen -l -f "$CA_FILE.new" 2>>"$LOG") || { rm -f "$CA_FILE.new"; fail "the CA public key did not parse"; }
chmod 0644 "$CA_FILE.new"
mv "$CA_FILE.new" "$CA_FILE" || fail "could not install $CA_FILE"

printf '%s\n' "# Accept user certificates signed by the BeyondTrust PRA Vault SSH CA (deploy-infra.sh)" \
    "TrustedUserCAKeys $CA_FILE" > "$DROPIN"
chmod 0644 "$DROPIN"

# Never leave sshd with a configuration it rejects: that would break the password login too
mkdir -p /run/sshd
if ! sshd -t >>"$LOG" 2>&1; then
    rm -f "$DROPIN"
    fail "sshd rejected the configuration, so the change was reverted"
fi
# Ubuntu 24.04 starts ssh on demand; if it is not running, the next connection reads the new config
systemctl try-restart ssh.service >>"$LOG" 2>&1 || fail "could not restart ssh"
sshd -T 2>>"$LOG" | grep -qi "^trustedusercakeys $CA_FILE" || fail "sshd is not using $CA_FILE"
echo "SSH_CA_OK:$(echo "$FP" | cut -d' ' -f2)"
exit 0
REMOTE
}

# Install the Linux Jumpoint on Ubuntu01
install_linux_jumpoint_on_ubuntu() {
    local id_file="$PROJECT_DIR/beyondtrust/terraform/linux_jumpoint_id.txt"
    local jumpoint_id="" bt_token script

    print_status "Installing the Linux Jumpoint on Ubuntu01 via Azure run-command..."
    if [ -f "$id_file" ]; then
        jumpoint_id=$(tr -d '[:space:]' < "$id_file")
    fi
    if ! echo "$jumpoint_id" | grep -qE '^[0-9]+$'; then
        print_warning "No Linux Jumpoint ID in $id_file"
        return 1
    fi

    # A fresh token for the VM to download the installer with, fetched just before use
    if ! bt_token=$(cd "$PROJECT_DIR/beyondtrust/scripts" && source ./bt-api.sh && get_api_token); then
        print_warning "Could not get a BeyondTrust API token for the Jumpoint download"
        return 1
    fi

    script=$(build_remote_script remote_jumpoint_body \
        BT_API_HOST "$BT_API_HOST" BT_TOKEN "$bt_token" JUMPOINT_ID "$jumpoint_id") || return 1
    run_ubuntu_step "Linux Jumpoint" "JUMPOINT" "$script"
}

install_k3s_on_ubuntu() {
    local script

    print_status "Installing k3s on Ubuntu01 via Azure run-command (a first install takes a few minutes)..."
    script=$(build_remote_script remote_k3s_body K3S_VERSION "$K3S_VERSION") || return 1
    run_ubuntu_step "k3s" "K3S" "$script"
}

# Read the cluster CA (into downloads) and the two tokens (into the private folder $1).
# The run-command output holds the tokens, so it is parsed but never printed, and the copy
# Azure keeps on the VM is overwritten straight afterwards.
export_k8s_credentials() {
    local secrets_dir="$1"
    local ca_file="$PROJECT_DIR/beyondtrust/downloads/k8s-ca.pem"
    local script sa token ca_b64 reason=""

    print_status "Reading the cluster CA and service account tokens from Ubuntu01..."
    script=$(build_remote_script remote_k8s_export_body) || return 1
    if ! run_on_ubuntu "$script"; then
        # The script may still have run and left the tokens in the VM's run-command output
        run_on_ubuntu 'echo "STATUS_CLEARED:1"' || true
        RUN_MESSAGE=""
        return 1
    fi

    if ! ubuntu_marker "K8S_EXPORT_OK" > /dev/null; then
        reason=$(ubuntu_marker "K8S_EXPORT_FAILED" || echo "no result from the script")
    fi
    if [ -z "$reason" ]; then
        for sa in pra-admin pra-readonly; do
            token=$(ubuntu_marker "K8S_TOKEN_$sa" || true)
            # A JWT is three base64url parts; anything else means the output was cut short
            if ! echo "$token" | grep -qE '^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$'; then
                reason="the $sa token was missing or incomplete"
                break
            fi
            (umask 077 && printf '%s' "$token" > "$secrets_dir/token-$sa")
        done
    fi
    if [ -z "$reason" ]; then
        ca_b64=$(ubuntu_marker "K8S_CA_B64" || true)
        if ! printf '%s' "$ca_b64" | base64 -d > "$ca_file" 2>/dev/null \
            || ! grep -q 'BEGIN CERTIFICATE' "$ca_file"; then
            reason="the cluster CA was missing or incomplete"
            rm -f "$ca_file"
        fi
    fi
    token=""
    RUN_MESSAGE=""

    # Azure keeps the last run-command output on the VM, readable with Reader access
    if ! run_on_ubuntu 'echo "STATUS_CLEARED:1"'; then
        print_warning "Could not overwrite the run-command output on Ubuntu01. Run any command on the VM to clear the tokens from it."
    fi
    RUN_MESSAGE=""

    if [ -n "$reason" ]; then
        print_warning "Could not read the Kubernetes credentials: $reason"
        return 1
    fi
    print_status "Cluster CA saved to $ca_file; both tokens held in a private temporary folder"
}

# Trust the PRA SSH CA on Ubuntu01 for the certificate only user
configure_ssh_ca_on_ubuntu() {
    local ca_file="$PROJECT_DIR/beyondtrust/downloads/pra-ssh-ca.pub"
    local ca_key script local_fp remote_fp

    print_status "Configuring Ubuntu01 to trust the PRA SSH CA for $LINUX_CERT_USERNAME via Azure run-command..."
    ca_key=$(head -n 1 "$ca_file" 2>/dev/null)
    if ! echo "$ca_key" | grep -qE '^(ssh-ed25519|ecdsa-sha2-nistp(256|384|521)|ssh-rsa) [A-Za-z0-9+/]+=*$'; then
        print_warning "No usable CA public key in $ca_file"
        return 1
    fi

    script=$(build_remote_script remote_ssh_ca_body \
        CERT_USER "$LINUX_CERT_USERNAME" CA_KEY "$ca_key") || return 1
    run_ubuntu_step "SSH CA trusted on Ubuntu01, fingerprint" "SSH_CA" "$script" || return 1

    # The key Ubuntu01 now trusts must be the one PRA holds
    if command -v ssh-keygen > /dev/null 2>&1; then
        local_fp=$(ssh-keygen -l -f "$ca_file" 2>/dev/null | cut -d' ' -f2)
        remote_fp=$(ubuntu_marker "SSH_CA_OK" || true)
        if [ -n "$local_fp" ] && [ "$local_fp" != "$remote_fp" ]; then
            print_warning "CA fingerprint mismatch: PRA holds $local_fp, Ubuntu01 trusts $remote_fp"
            return 1
        fi
    fi
}

# Step 8: certificate login for Ubuntu01. The Shell Jump is only created once Ubuntu01
# trusts the CA, so a failure never leaves a jump item in the console that cannot log in.
deploy_ssh_certificate_login() {
    print_status "Setting up SSH certificate login for Ubuntu01 (PRA Vault SSH CA)..."
    (cd "$PROJECT_DIR/beyondtrust/scripts" && ./run-with-config.sh configure-ssh-ca.sh account) || return 1
    configure_ssh_ca_on_ubuntu || return 1
    (cd "$PROJECT_DIR/beyondtrust/scripts" && ./run-with-config.sh configure-ssh-ca.sh jump-item) || return 1
}

# Step 9: Kubernetes Cluster Tunnel through the Linux Jumpoint. The tokens only ever sit in
# a private temporary folder, removed when this returns whatever happened.
deploy_kubernetes_tunnel() {
    local secrets_dir rc

    print_status "Setting up the Kubernetes Cluster Tunnel (k3s on Ubuntu01)..."
    secrets_dir=$(mktemp -d) || return 1
    if install_linux_jumpoint_on_ubuntu \
        && install_k3s_on_ubuntu \
        && export_k8s_credentials "$secrets_dir" \
        && (cd "$PROJECT_DIR/beyondtrust/scripts" \
            && K8S_SECRETS_DIR="$secrets_dir" ./run-with-config.sh configure-k8s-tunnel.sh); then
        rc=0
    else
        rc=1
    fi
    rm -rf "$secrets_dir"
    return "$rc"
}

# Stop early when Ubuntu01 is not running: demo VMs are often deallocated to save cost
require_ubuntu_running() {
    local subscription state
    local sub_args=()

    subscription=$(jq -r '.azure.subscription_id // empty' "$STATE_FILE" 2>/dev/null)
    if [ -n "$subscription" ]; then
        sub_args=(--subscription "$subscription")
    fi
    state=$(az vm get-instance-view "${sub_args[@]}" \
        --resource-group "rg-beyondtrust-${ENVIRONMENT}" --name "vm-ubuntu-${ENVIRONMENT}" \
        --query "instanceView.statuses[?starts_with(code, 'PowerState/')].code | [0]" \
        --output tsv 2>/dev/null || true)
    if [ "$state" != "PowerState/running" ]; then
        print_error "Ubuntu01 (vm-ubuntu-${ENVIRONMENT}) is ${state:-not reachable}. Start it with: az vm start ${sub_args[*]} --resource-group rg-beyondtrust-${ENVIRONMENT} --name vm-ubuntu-${ENVIRONMENT}"
    fi
}

# The K8s-Deny-Inbound rule from the Azure Terraform, for deployments made before it
# existed. Same name and properties, so a later terraform apply sees no change.
ensure_k8s_nsg_rule() {
    local subscription
    local sub_args=()
    local rg="rg-beyondtrust-${ENVIRONMENT}"
    local nsg="nsg-linux-${ENVIRONMENT}"

    subscription=$(jq -r '.azure.subscription_id // empty' "$STATE_FILE" 2>/dev/null)
    if [ -n "$subscription" ]; then
        sub_args=(--subscription "$subscription")
    fi
    if az network nsg rule show "${sub_args[@]}" --resource-group "$rg" --nsg-name "$nsg" \
        --name K8s-Deny-Inbound --output none &> /dev/null; then
        return 0
    fi

    print_status "Closing the Kubernetes ports (6443, 10250) on $nsg..."
    if ! az network nsg rule create "${sub_args[@]}" --resource-group "$rg" --nsg-name "$nsg" \
        --name K8s-Deny-Inbound --priority 110 --direction Inbound --access Deny --protocol Tcp \
        --source-address-prefixes '*' --source-port-ranges '*' \
        --destination-address-prefixes '*' --destination-port-ranges 6443 10250 \
        --only-show-errors --output none; then
        print_warning "Could not add the NSG rule. Azure's default rules still block these ports from the internet."
    fi
}

# Checks and script regeneration shared by --ssh-ca-only and --k8s-only, which work on an
# existing deployment and skip everything else. Extra arguments are tools that must exist.
prepare_feature_only_run() {
    local enabled="$1"
    local setting="$2"
    local tool
    shift 2

    if [ ! -f "$STATE_FILE" ]; then
        print_error "No deployment state found at $STATE_FILE. Run ./deploy-infra.sh first."
    fi
    if [ "$enabled" != true ]; then
        print_error "$setting is false in $CONFIG_FILE. Set it to true to use this option."
    fi
    for tool in az jq curl "$@"; do
        if ! command -v "$tool" &> /dev/null; then
            print_error "$tool is not installed. Run ./deploy-infra.sh once to install the prerequisites."
        fi
    done

    cd "$PROJECT_DIR"
    if ! az account show &> /dev/null; then
        az login
    fi
    require_ubuntu_running

    # Regenerate the scripts these steps need so they match the current source. The
    # cleanup script is included so --cleanup removes what this run creates.
    create_beyondtrust_api_helper
    create_beyondtrust_state_helper
    create_beyondtrust_run_wrapper
    create_beyondtrust_cleanup_script
}

# --ssh-ca-only: add SSH certificate login to an existing deployment
run_ssh_ca_only() {
    print_status "Adding SSH certificate login to the existing deployment..."
    prepare_feature_only_run "$ENABLE_SSH_CA" "ENABLE_SSH_CA"
    create_beyondtrust_ssh_ca_script

    if ! deploy_ssh_certificate_login; then
        print_error "SSH certificate login is not configured, see the output above. It is safe to re-run."
    fi

    print_status "SSH certificate login is ready"
    echo "  Jump Item: ${RESOURCE_PREFIX}Ubuntu01 - SSH (Certificate) in $JUMP_GROUP_LINUX"
    echo "  Vault Account: ${RESOURCE_PREFIX}Ubuntu01 Cert Admin (SSH CA), logs in as $LINUX_CERT_USERNAME (no password on Ubuntu01)"
}

# --k8s-only: add the Kubernetes Cluster Tunnel to an existing deployment
run_k8s_only() {
    print_status "Adding the Kubernetes Cluster Tunnel to the existing deployment..."
    prepare_feature_only_run "$ENABLE_K8S_TUNNEL" "ENABLE_K8S_TUNNEL" terraform

    # Adds the Linux Jumpoint; the jump groups and the DC01 Jumpoint are left as they are
    print_status "Applying BeyondTrust Terraform to add the Linux Jumpoint..."
    create_beyondtrust_terraform_config
    apply_beyondtrust_terraform
    ensure_k8s_nsg_rule
    create_beyondtrust_k8s_tunnel_script

    if ! deploy_kubernetes_tunnel; then
        print_error "The Kubernetes tunnel is not configured, see the output above. It is safe to re-run."
    fi

    print_status "Kubernetes Cluster Tunnel is ready"
    echo "  Jump Item: ${RESOURCE_PREFIX}Ubuntu01 - Kubernetes (k3s) in $JUMP_GROUP_LINUX, through $LINUX_JUMPOINT_NAME"
    echo "  Vault Accounts: ${RESOURCE_PREFIX}K8s Admin (cluster-admin), ${RESOURCE_PREFIX}K8s Read Only (view)"
}

# Phase 3: BeyondTrust Integration
deploy_beyondtrust() {
    print_status "Phase 3: Deploying BeyondTrust PRA integration..."
    
    cd "$PROJECT_DIR"
    
    # Source config and EXPORT ALL VARIABLES (FIX)
    source "$CONFIG_FILE"
    apply_feature_defaults
    export BT_API_HOST BT_CLIENT_ID BT_CLIENT_SECRET RESOURCE_PREFIX APPROVER_EMAIL
    export JUMP_GROUP_DEMO JUMP_GROUP_DC JUMPOINT_NAME ADMIN_USERNAME ADMIN_PASSWORD DOMAIN_NAME
    export VAULT_ACCOUNT_GROUP_ID
    export GROUP_POLICY_ID JUMP_ITEM_ROLE_ID JUMP_ITEM_ROLE_NAME
    export ENABLE_SSH_CA ENABLE_K8S_TUNNEL LINUX_CERT_USERNAME K3S_VERSION LINUX_JUMPOINT_NAME

    # Update state
    update_metadata "beyondtrust_instance" "$BT_API_HOST"
    update_metadata "resource_prefix" "$RESOURCE_PREFIX"
    
    # Create all BeyondTrust scripts
    create_beyondtrust_terraform_config
    create_beyondtrust_api_helper
    create_beyondtrust_state_helper
    create_beyondtrust_run_wrapper  # NEW: Create wrapper script
    create_beyondtrust_policy_script
    create_beyondtrust_group_policy_script
    create_beyondtrust_installer_script
    create_beyondtrust_jump_items_script
    create_beyondtrust_vault_script
    create_beyondtrust_ssh_ca_script
    create_beyondtrust_k8s_tunnel_script
    create_beyondtrust_cleanup_script
    create_beyondtrust_ansible_playbook
    
    # Step 1: Deploy Terraform resources
    print_status "Deploying BeyondTrust Terraform resources..."
    apply_beyondtrust_terraform

    # Step 2: Assign asset groups to the group policy (using wrapper)
    print_status "Assigning asset groups to group policy..."
    GROUP_POLICY_ASSIGNED=true
    (cd "$PROJECT_DIR/beyondtrust/scripts" && ./run-with-config.sh configure-group-policy.sh) || {
        GROUP_POLICY_ASSIGNED=false
        print_warning "Asset group assignment failed - see output above. Continuing deployment."
    }

    # Step 3: Create policies via API (using wrapper)
    print_status "Creating jump policies..."
    (cd "$PROJECT_DIR/beyondtrust/scripts" && ./run-with-config.sh create-policies.sh)

    # Step 4: Download installers (using wrapper)
    print_status "Downloading installers..."
    (cd "$PROJECT_DIR/beyondtrust/scripts" && ./run-with-config.sh download-installers.sh) || {
        print_error "Failed to download installers. Check your BeyondTrust API credentials and network connectivity."
    }

    # Step 5: Install software via Ansible
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

    # Step 4b: Install Jump Client on Ubuntu directly via Azure VM run-command
    # (bypasses Ansible entirely — avoids WinRM/SSH connection plugin conflicts)
    print_status "Installing BeyondTrust Jump Client on Ubuntu via Azure run-command..."
    local downloads_dir="$PROJECT_DIR/beyondtrust/downloads"
    local key_info_file="$downloads_dir/jumpclient-linux-keyinfo.txt"
    local installer_id_file="$downloads_dir/jumpclient-linux-installer-id.txt"

    if [ -f "$key_info_file" ] && [ -f "$installer_id_file" ]; then
        local bt_key_info
        bt_key_info=$(cat "$key_info_file")
        local bt_installer_id
        bt_installer_id=$(cat "$installer_id_file")

        # Get a fresh BeyondTrust API token for the VM to download the installer
        local bt_token
        bt_token=$(curl -s -X POST "${BT_API_HOST}/oauth2/token" \
            -H "Content-Type: application/x-www-form-urlencoded" \
            -d "grant_type=client_credentials&client_id=${BT_CLIENT_ID}&client_secret=${BT_CLIENT_SECRET}" \
            | jq -r '.access_token // empty')

        if [ -z "$bt_token" ]; then
            print_warning "Failed to get BeyondTrust API token — skipping Ubuntu Jump Client installation"
        else
            local ubuntu_script
            ubuntu_script="echo 'Downloading Jump Client installer from BeyondTrust...'
touch /tmp/jc_before
cd /tmp
curl -sf -J -O -H 'Authorization: Bearer ${bt_token}' '${BT_API_HOST}/api/config/v1/jump-client/installer/${bt_installer_id}/linux-64'
INSTALLER=\$(find /tmp -maxdepth 1 -newer /tmp/jc_before -type f 2>/dev/null | head -1)
rm -f /tmp/jc_before
if [ -z \"\$INSTALLER\" ]; then
  echo 'ERROR: installer not found after download'
  ls -la /tmp/
  exit 1
fi
echo \"Found installer: \$INSTALLER\"
chmod +x \"\$INSTALLER\"
echo 'Installing Jump Client...'
\"\$INSTALLER\" --key-info '${bt_key_info}' --headless --scope system --startup systemd --install-dir /opt/beyondtrust/jumpclient --session-user linuxadmin
INSTALL_RC=\$?
echo \"Installer exit code: \$INSTALL_RC\"
if [ \$INSTALL_RC -ne 0 ]; then
  echo 'ERROR: Jump Client installation failed with exit code '\$INSTALL_RC
  exit 1
fi
echo 'Jump Client installation complete'
echo 'Checking service status...'
sleep 10
systemctl list-units --type=service --no-legend | grep -iE 'scc|bomgar|beyond' || echo 'WARNING: no BeyondTrust service unit found'
systemctl list-units --type=service --state=active --no-legend | grep -iE 'scc|bomgar|beyond' && echo 'Service is active' || echo 'WARNING: service not active yet'
echo 'Recent service journal (last 30 lines):'
journalctl --no-pager -n 30 2>/dev/null | grep -iE 'scc|bomgar|beyond|jumpclient' || echo 'No relevant journal entries found'"

            local run_result
            run_result=$(az vm run-command invoke \
                --resource-group "rg-beyondtrust-${ENVIRONMENT}" \
                --name "vm-ubuntu-${ENVIRONMENT}" \
                --command-id RunShellScript \
                --scripts "$ubuntu_script" \
                --output json 2>&1)

            local az_exit=$?
            if [ $az_exit -eq 0 ]; then
                local stdout
                stdout=$(echo "$run_result" | jq -r '.value[0].message // "completed"' 2>/dev/null)
                print_status "Ubuntu Jump Client installation output:"
                echo "$stdout"
            else
                print_warning "Azure run-command for Ubuntu returned non-zero exit ($az_exit). Output:"
                echo "$run_result" | head -20
            fi
        fi
    else
        print_warning "Linux Jump Client download files not found — skipping Ubuntu installation"
        print_warning "  Missing: ${key_info_file} or ${installer_id_file}"
    fi

    # Step 6: Configure jump items (using wrapper)
    print_status "Configuring jump items..."
    (cd "$PROJECT_DIR/beyondtrust/scripts" && ./run-with-config.sh configure-jump-items.sh)

    # Step 7: Configure vault (using wrapper)
    print_status "Configuring vault accounts..."
    (cd "$PROJECT_DIR/beyondtrust/scripts" && ./run-with-config.sh configure-vault.sh)

    # Step 8: SSH certificate login for Ubuntu01. Optional, so a failure does not stop the
    # deployment; --ssh-ca-only finishes it later.
    SSH_CA_CONFIGURED=skipped
    if [ "$ENABLE_SSH_CA" = true ]; then
        if deploy_ssh_certificate_login; then
            SSH_CA_CONFIGURED=true
        else
            SSH_CA_CONFIGURED=false
            print_warning "SSH certificate login is not fully configured, see the output above. Continuing deployment."
        fi
    fi

    # Step 9: Kubernetes Cluster Tunnel (k3s and the Linux Jumpoint on Ubuntu01). Optional in
    # the same way; --k8s-only finishes it later.
    K8S_TUNNEL_CONFIGURED=skipped
    if [ "$ENABLE_K8S_TUNNEL" = true ]; then
        if deploy_kubernetes_tunnel; then
            K8S_TUNNEL_CONFIGURED=true
        else
            K8S_TUNNEL_CONFIGURED=false
            print_warning "The Kubernetes tunnel is not fully configured, see the output above. Continuing deployment."
        fi
    fi

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
export GROUP_POLICY_ID="${GROUP_POLICY_ID:-2}"
export JUMP_ITEM_ROLE_ID="${JUMP_ITEM_ROLE_ID:-}"
export JUMP_ITEM_ROLE_NAME="${JUMP_ITEM_ROLE_NAME-Administrator}"
export JUMP_GROUP_DEMO="${RESOURCE_PREFIX}Demo Servers"
export JUMP_GROUP_DC="${RESOURCE_PREFIX}Domain Controllers"
export JUMP_GROUP_LINUX="${RESOURCE_PREFIX}Linux Servers"
export JUMPOINT_NAME="${RESOURCE_PREFIX}DC01_Jumpoint"
export LINUX_JUMPOINT_NAME="${RESOURCE_PREFIX}Ubuntu01_Jumpoint"
export LINUX_CERT_USERNAME="${LINUX_CERT_USERNAME:-certadmin}"

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

    # PRA only runs the Kubernetes Cluster Tunnel through a Linux Jumpoint, so a second
    # Jumpoint is created for Ubuntu01 when that feature is enabled
    if [ "${ENABLE_K8S_TUNNEL:-true}" = true ]; then
        cat >> beyondtrust/terraform/main.tf << EOF

# Linux Jumpoint on Ubuntu01, used only by the Kubernetes Cluster Tunnel
resource "sra_jumpoint" "linux_jumpoint" {
  name                    = "$LINUX_JUMPOINT_NAME"
  code_name               = "ubuntu01_jumpoint"
  platform                = "linux-x86"
  shell_jump_enabled      = false
  protocol_tunnel_enabled = true
  enabled                 = true
  comments                = "Linux Jumpoint on Ubuntu01 for the Kubernetes Cluster Tunnel"
}

output "linux_jumpoint_id" {
  value = sra_jumpoint.linux_jumpoint.id
}
EOF
    fi
}

# Apply the BeyondTrust Terraform (jump groups and Jumpoints), save the IDs that the
# generated scripts read, and record them in the state file. Used by the full deployment
# and by --k8s-only, which adds the Linux Jumpoint to an existing deployment.
apply_beyondtrust_terraform() {
    pushd "$PROJECT_DIR/beyondtrust/terraform" > /dev/null
    terraform init
    terraform apply -auto-approve

    # Save IDs for later use
    terraform output -raw jump_group_demo_id > demo_group_id.txt
    terraform output -raw jump_group_dc_id > dc_group_id.txt
    terraform output -raw jumpoint_id > jumpoint_id.txt
    terraform output -raw jump_group_linux_id > linux_group_id.txt
    if [ "$ENABLE_K8S_TUNNEL" = true ]; then
        terraform output -raw linux_jumpoint_id > linux_jumpoint_id.txt
    fi

    # Track Terraform resources in state
    add_resource_once "jump_group" "$(cat demo_group_id.txt)" "$JUMP_GROUP_DEMO" '{"type": "shared", "managed_by": "terraform"}'
    add_resource_once "jump_group" "$(cat dc_group_id.txt)" "$JUMP_GROUP_DC" '{"type": "shared", "managed_by": "terraform"}'
    add_resource_once "jump_group" "$(cat linux_group_id.txt)" "$JUMP_GROUP_LINUX" '{"type": "shared", "managed_by": "terraform"}'
    add_resource_once "jumpoint" "$(cat jumpoint_id.txt)" "$JUMPOINT_NAME" '{"platform": "windows-x86", "managed_by": "terraform"}'
    if [ "$ENABLE_K8S_TUNNEL" = true ]; then
        add_resource_once "jumpoint" "$(cat linux_jumpoint_id.txt)" "$LINUX_JUMPOINT_NAME" '{"platform": "linux-x86", "managed_by": "terraform"}'
    fi
    popd > /dev/null
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

# As api_call, but appends the HTTP status code as a final line so callers can
# distinguish "rejected" from "succeeded with an unexpected body shape".
api_call_status() {
    local method="$1"
    local endpoint="$2"
    local data="$3"

    local token
    token=$(get_api_token) || return 1

    local args=(-s -w '\n%{http_code}' -X "$method" "$BT_API_HOST/api/config/v1$endpoint" \
        -H "Authorization: Bearer $token" \
        -H "Accept: application/json")

    if [ -n "$data" ]; then
        args+=(-H "Content-Type: application/json" -d "$data")
    fi

    curl "${args[@]}"
}

# Split the "body + trailing status line" produced by api_call_status
http_body() { echo "$1" | sed '$d'; }
http_code() { echo "$1" | tail -n1; }
is_2xx() { case "$1" in 2??) return 0 ;; *) return 1 ;; esac; }

# Limit a vault account to one jump item, matched by its exact name. An account level
# association replaces the one inherited from the account group. POST is only accepted
# while none is defined and PATCH only once one is, so try the likely verb first and fall
# back to the other. If both fail the account keeps its account group's association.
associate_vault_account() {
    local account_id="$1"
    local item_name="$2"
    local endpoint="/vault/account/$account_id/jump-item-association"
    local payload response code verb

    # All five criteria arrays must be present; null is rejected
    payload=$(jq -n --arg item "$item_name" '{
        filter_type: "criteria",
        criteria: {shared_jump_groups: [], host: [], name: [$item], tag: [], comment: []},
        jump_items: []
    }')

    response=$(api_call_status "GET" "$endpoint" "")
    if [ "$(http_code "$response")" = "404" ]; then verb="POST"; else verb="PATCH"; fi

    response=$(api_call_status "$verb" "$endpoint" "$payload")
    code=$(http_code "$response")
    if ! is_2xx "$code"; then
        if [ "$verb" = "POST" ]; then verb="PATCH"; else verb="POST"; fi
        response=$(api_call_status "$verb" "$endpoint" "$payload")
        code=$(http_code "$response")
    fi

    if is_2xx "$code"; then
        echo "  Associated vault account $account_id with \"$item_name\" only"
        return 0
    fi
    echo "  WARNING: Could not associate vault account $account_id with \"$item_name\" - HTTP $code"
    echo "           API response: $(http_body "$response")"
    echo "           The account keeps its account group's jump item association instead."
    return 1
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

# Print the ID most recently recorded for a resource of this type whose field matches,
# e.g. find_bt_resource jump_policy type approval_required. Objects this deployment made
# are always found through the state file, never by name through the API: on a shared
# tenant someone else's deployment can own an object with exactly the same name.
find_bt_resource() {
    local resource_type="$1"
    local field="$2"
    local value="$3"

    if [ -f "$STATE_FILE" ]; then
        jq -r --arg type "$resource_type" --arg field "$field" --arg value "$value" \
            '[.resources[$type][]? | select(.[$field] == $value) | .id] | last // empty' "$STATE_FILE"
    fi
}

# Remove a resource from the state file, e.g. one that was deleted in the console
remove_bt_resource() {
    local resource_type="$1"
    local resource_id="$2"

    [ -f "$STATE_FILE" ] || return 0
    jq --arg type "$resource_type" --arg id "$resource_id" \
       'if .resources[$type] then .resources[$type] |= map(select(.id != $id)) else . end' \
       "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
}

# Print the ID of a prerequisite this deployment created: the file 'terraform output'
# wrote if it holds a number, otherwise the state file
known_bt_id() {
    local file="$1"
    local resource_type="$2"
    local field="$3"
    local value="$4"
    local id=""

    if [ -f "$file" ]; then
        id=$(tr -d '[:space:]' < "$file")
    fi
    if ! echo "$id" | grep -qE '^[0-9]+$'; then
        id=$(find_bt_resource "$resource_type" "$field" "$value")
    fi
    echo "$id"
}

# Check whether an object this deployment recorded earlier still exists, so re-runs reuse
# it instead of creating a duplicate. Sets BT_ID and BT_BODY when it does. Returns 1 only
# when the check itself failed (e.g. 401 or an outage), so that never creates a duplicate.
# Needs bt-api.sh sourced first.
find_existing_bt_object() {
    local state_type="$1"
    local name="$2"
    local endpoint="$3"
    local id response code

    BT_ID=""
    BT_BODY=""
    id=$(find_bt_resource "$state_type" "name" "$name")
    [ -n "$id" ] || return 0

    response=$(api_call_status "GET" "$endpoint/$id" "")
    code=$(http_code "$response")
    if is_2xx "$code"; then
        BT_ID="$id"
        BT_BODY=$(http_body "$response")
    elif [ "$code" = "404" ]; then
        echo "  $name (ID: $id) no longer exists, it will be created again"
        remove_bt_resource "$state_type" "$id"
    else
        echo "  ERROR: Could not check $name (ID: $id) - HTTP $code"
        echo "         API response: $(http_body "$response")"
        return 1
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

create_beyondtrust_group_policy_script() {
    print_status "Creating group policy assignment script..."

    cat > beyondtrust/scripts/configure-group-policy.sh << 'EOF'
#!/bin/bash
# Assign the asset (Jump) groups created by Terraform to an existing group policy
#
# Usage:
#   ./configure-group-policy.sh          Assign the asset groups (idempotent)
#   ./configure-group-policy.sh --list   Show policies, jump item roles and current
#                                        assignments without changing anything

source "$(dirname "$0")/bt-api.sh"
source "$(dirname "$0")/state-helper.sh"

GROUP_POLICY_ID="${GROUP_POLICY_ID:-2}"
JUMP_ITEM_ROLE_NAME="${JUMP_ITEM_ROLE_NAME-Administrator}"
JUMP_ITEM_ROLE_ID="${JUMP_ITEM_ROLE_ID:-}"
TF_DIR="$(dirname "$0")/../terraform"

FAILURES=0

# Split the "body + trailing status line" produced by api_call_status
http_body() { echo "$1" | sed '$d'; }
http_code() { echo "$1" | tail -n1; }

# Turn a status code into an explanation worth acting on
explain_failure() {
    case "$1" in
        401) echo "         The API credentials were rejected. Check BT_CLIENT_ID / BT_CLIENT_SECRET." ;;
        403) echo "         The API account is not permitted to manage group policies. In the console," ;
             echo "         open Configuration -> API Accounts and grant it Group Policy access." ;;
        404) echo "         The endpoint or object does not exist. Check GROUP_POLICY_ID in config.env." ;;
    esac
}

# Print the instance's group policies, jump item roles and current assignments
list_options() {
    local response

    echo "Group policies (set GROUP_POLICY_ID in config.env):"
    response=$(api_call "GET" "/group-policy" "")
    echo "$response" | jq -r '.[]? | "  \(.id): \(.name)"' 2>/dev/null \
        || echo "  Could not list group policies: $response"

    echo ""
    echo "Jump item roles (set JUMP_ITEM_ROLE_ID in config.env):"
    response=$(api_call "GET" "/jump-item-role" "")
    echo "$response" | jq -r '.[]? | "  \(.id): \(.name)"' 2>/dev/null \
        || echo "  Could not list jump item roles: $response"

    echo ""
    echo "Asset groups currently assigned to group policy $GROUP_POLICY_ID:"
    response=$(api_call "GET" "/group-policy/$GROUP_POLICY_ID/jump-group" "")
    if [ "$(echo "$response" | jq -r 'if type == "array" then length else 0 end' 2>/dev/null)" = "0" ]; then
        echo "  (none)"
    else
        echo "$response" | jq -r '.[]? | "  jump_group_id \(.jump_group_id), jump_item_role_id \(.jump_item_role_id // "none")"'
    fi
}

# Resolve the jump item role to a numeric ID. Names are stable across instances,
# the numeric IDs are not - a hardcoded 2 turned out to be "Start Sessions Only"
# rather than "Administrator". JUMP_ITEM_ROLE_ID pins it by number if set and
# JUMP_ITEM_ROLE_NAME is empty.
resolve_jump_item_role() {
    local roles

    if [ -n "$JUMP_ITEM_ROLE_ID" ]; then
        echo "Using jump item role ID $JUMP_ITEM_ROLE_ID (pinned by JUMP_ITEM_ROLE_ID)"
        return 0
    fi

    if [ -z "$JUMP_ITEM_ROLE_NAME" ]; then
        echo "ERROR: Set JUMP_ITEM_ROLE_ID or JUMP_ITEM_ROLE_NAME in config.env"
        return 1
    fi

    roles=$(api_call "GET" "/jump-item-role" "")
    JUMP_ITEM_ROLE_ID=$(echo "$roles" \
        | jq -r --arg n "$JUMP_ITEM_ROLE_NAME" '.[]? | select(.name == $n) | .id' 2>/dev/null | head -1)

    if [ -z "$JUMP_ITEM_ROLE_ID" ] || [ "$JUMP_ITEM_ROLE_ID" = "null" ]; then
        echo "ERROR: No jump item role named \"$JUMP_ITEM_ROLE_NAME\" on $BT_API_HOST"
        echo "       Available roles:"
        echo "$roles" | jq -r '.[]? | "         \(.id): \(.name)"' 2>/dev/null \
            || echo "         Could not list roles: $roles"
        echo "       Set JUMP_ITEM_ROLE_NAME in config.env to one of the names above."
        return 1
    fi

    echo "Using jump item role \"$JUMP_ITEM_ROLE_NAME\" (ID $JUMP_ITEM_ROLE_ID)"
}

# Confirm the target group policy exists before attempting any assignment.
# A bad ID here would otherwise fail once per asset group with the same opaque error.
verify_group_policy() {
    local response body code policy_name
    response=$(api_call_status "GET" "/group-policy/$GROUP_POLICY_ID" "")
    body=$(http_body "$response")
    code=$(http_code "$response")

    policy_name=$(echo "$body" | jq -r '.name // empty' 2>/dev/null)
    if [ "$code" -lt 200 ] || [ "$code" -ge 300 ] || [ -z "$policy_name" ]; then
        echo "ERROR: Could not read group policy $GROUP_POLICY_ID from $BT_API_HOST (HTTP $code)"
        echo "       API response: $body"
        explain_failure "$code"
        echo "       Run with --list to see the group policies on this instance."
        return 1
    fi

    echo "Assigning asset groups to group policy $GROUP_POLICY_ID ($policy_name)"
}

# Change the jump item role on an assignment that already exists. Tries PATCH first;
# some versions expose only create/delete on this endpoint, so fall back to
# delete-then-recreate.
update_jump_item_role() {
    local jump_group_id="$1"
    local label="$2"
    local current_role="$3"

    local payload response code
    payload="{\"jump_item_role_id\": $JUMP_ITEM_ROLE_ID}"

    response=$(api_call_status "PATCH" "/group-policy/$GROUP_POLICY_ID/jump-group/$jump_group_id" "$payload")
    code=$(http_code "$response")

    if [ "$code" -lt 200 ] || [ "$code" -ge 300 ]; then
        # Fall back to delete + recreate
        api_call_status "DELETE" "/group-policy/$GROUP_POLICY_ID/jump-group/$jump_group_id" "" > /dev/null
        response=$(api_call_status "POST" "/group-policy/$GROUP_POLICY_ID/jump-group" \
            "$(assignment_payload "$jump_group_id")")
        code=$(http_code "$response")
    fi

    if [ "$code" -ge 200 ] && [ "$code" -lt 300 ]; then
        echo "  $label (ID: $jump_group_id) jump item role changed from ${current_role:-none} to $JUMP_ITEM_ROLE_ID"
    else
        echo "  ERROR: Failed to change jump item role on $label (ID: $jump_group_id) - HTTP $code"
        echo "         API response: $(http_body "$response")"
        explain_failure "$code"
        FAILURES=$((FAILURES + 1))
    fi
}

# The POST body for an assignment. This endpoint accepts only jump_group_id and
# jump_item_role_id; jump_group_type (valid on the jump-item endpoints) is rejected.
assignment_payload() {
    cat <<JSON
{
    "jump_group_id": $1,
    "jump_item_role_id": $JUMP_ITEM_ROLE_ID
}
JSON
}

# Add a single asset (Jump) group to the group policy
assign_jump_group() {
    local jump_group_id="$1"
    local label="$2"

    if [ -z "$jump_group_id" ] || [ "$jump_group_id" = "null" ]; then
        echo "  ERROR: No Jump Group ID available for $label - cannot assign"
        FAILURES=$((FAILURES + 1))
        return
    fi

    # Already assigned? A 404 here just means "not assigned yet". If it is assigned
    # but with the wrong jump item role, correct it rather than skipping.
    local existing existing_code current_role
    existing=$(api_call_status "GET" "/group-policy/$GROUP_POLICY_ID/jump-group/$jump_group_id" "")
    existing_code=$(http_code "$existing")
    if [ "$existing_code" -ge 200 ] && [ "$existing_code" -lt 300 ]; then
        if [ "$(http_body "$existing" | jq -r '.jump_group_id // empty' 2>/dev/null)" = "$jump_group_id" ]; then
            current_role=$(http_body "$existing" | jq -r '.jump_item_role_id // empty' 2>/dev/null)
            if [ "$current_role" = "$JUMP_ITEM_ROLE_ID" ]; then
                echo "  $label (ID: $jump_group_id) already assigned with jump item role $JUMP_ITEM_ROLE_ID"
                return
            fi
            update_jump_item_role "$jump_group_id" "$label" "$current_role"
            return
        fi
    fi

    local assignment_data
    assignment_data=$(assignment_payload "$jump_group_id")

    local response body code
    response=$(api_call_status "POST" "/group-policy/$GROUP_POLICY_ID/jump-group" "$assignment_data")
    body=$(http_body "$response")
    code=$(http_code "$response")

    if [ "$code" -ge 200 ] && [ "$code" -lt 300 ]; then
        add_bt_resource "group_policy_jump_group" "$jump_group_id" "$label" \
            '{"group_policy_id": "'"$GROUP_POLICY_ID"'", "jump_item_role_id": "'"$JUMP_ITEM_ROLE_ID"'"}'
        echo "  Assigned $label (ID: $jump_group_id) with jump item role $JUMP_ITEM_ROLE_ID"
    else
        echo "  ERROR: Failed to assign $label (ID: $jump_group_id) - HTTP $code"
        echo "         API response: $body"
        explain_failure "$code"
        FAILURES=$((FAILURES + 1))
    fi
}

# Resolve a Jump Group ID: prefer the file written by 'terraform output', and fall
# back to an exact name lookup (the *_id.txt files are removed by --cleanup).
resolve_group_id() {
    local file="$TF_DIR/$1"
    local name="$2"
    local id=""

    if [ -f "$file" ]; then
        id=$(tr -d '[:space:]' < "$file")
    fi

    if [ -z "$id" ] || [ "$id" = "null" ]; then
        id=$(api_call "GET" "/jump-group" "" \
            | jq -r --arg n "$name" '.[]? | select(.name == $n) | .id' 2>/dev/null | head -1)
    fi

    echo "$id"
}

# Main execution
if [ "$1" = "--list" ]; then
    list_options
    exit 0
fi

verify_group_policy || exit 1
resolve_jump_item_role || exit 1

JUMP_GROUP_DEMO="${JUMP_GROUP_DEMO:-Demo Servers}"
JUMP_GROUP_DC="${JUMP_GROUP_DC:-Domain Controllers}"
JUMP_GROUP_LINUX="${JUMP_GROUP_LINUX:-Linux Servers}"

assign_jump_group "$(resolve_group_id demo_group_id.txt "$JUMP_GROUP_DEMO")" "$JUMP_GROUP_DEMO"
assign_jump_group "$(resolve_group_id dc_group_id.txt "$JUMP_GROUP_DC")" "$JUMP_GROUP_DC"
assign_jump_group "$(resolve_group_id linux_group_id.txt "$JUMP_GROUP_LINUX")" "$JUMP_GROUP_LINUX"

if [ "$FAILURES" -gt 0 ]; then
    echo "Asset group assignment FAILED for $FAILURES of 3 groups"
    echo "Run './run-with-config.sh configure-group-policy.sh --list' to inspect this instance."
    exit 1
fi

echo "Asset group assignment completed"
EOF

    chmod +x beyondtrust/scripts/configure-group-policy.sh
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
    echo "$installer_id" > ../downloads/jumpclient-linux-installer-id.txt

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

create_beyondtrust_ssh_ca_script() {
    print_status "Creating SSH certificate login script..."

    cat > beyondtrust/scripts/configure-ssh-ca.sh << 'EOF'
#!/bin/bash
# Certificate login for Ubuntu01 through a PRA Vault SSH CA
#
# Usage:
#   ./configure-ssh-ca.sh account     Create (or reuse) the SSH CA vault account and write its
#                                     public key to ../downloads/pra-ssh-ca.pub
#   ./configure-ssh-ca.sh jump-item   Create (or reuse) the certificate Shell Jump and limit
#                                     the SSH CA account to it
#
# deploy-infra.sh runs "account", installs the key on Ubuntu01, then runs "jump-item", so the
# jump item only appears once the server trusts the CA. Safe to re-run: objects recorded in
# the state file are reused. Payloads are built with jq -n here because some values (keys)
# contain characters that the heredoc style used elsewhere would not escape.

source "$(dirname "${BASH_SOURCE[0]}")/bt-api.sh"
source "$(dirname "${BASH_SOURCE[0]}")/state-helper.sh"

CERT_USER="${LINUX_CERT_USERNAME:-certadmin}"
ACCOUNT_NAME="${RESOURCE_PREFIX}Ubuntu01 Cert Admin (SSH CA)"
ITEM_NAME="${RESOURCE_PREFIX}Ubuntu01 - SSH (Certificate)"
CA_PUB_FILE="../downloads/pra-ssh-ca.pub"
UBUNTU_PRIVATE_IP="10.0.3.10"

# Create the SSH CA account. Vault generates the CA key pair itself when no private key is
# supplied; if this version insists on one, upload a key generated here instead and delete
# the local copy straight away. Sets ACCOUNT_ID and PUBLIC_KEY.
create_ssh_ca_account() {
    local base response code key_type tmp_dir payload

    base=$(jq -n --arg name "$ACCOUNT_NAME" --arg user "$CERT_USER" \
        --argjson group "${VAULT_ACCOUNT_GROUP_ID:-4}" '{
        type: "ssh_ca",
        name: $name,
        username: $user,
        description: "Certificate authority trusted by Ubuntu01. PRA signs a short lived certificate for each session; the Linux account has no password.",
        account_group_id: $group
    }')

    response=$(api_call_status "POST" "/vault/account" "$base")
    code=$(http_code "$response")

    if ! is_2xx "$code" && [ "$code" != "401" ] && [ "$code" != "403" ] \
        && command -v ssh-keygen > /dev/null 2>&1; then
        echo "  Vault did not generate a CA key (HTTP $code), uploading one generated locally instead"
        for key_type in ed25519 rsa; do
            tmp_dir=$(mktemp -d)
            if [ "$key_type" = "ed25519" ]; then
                ssh-keygen -q -t ed25519 -N '' -C "$ACCOUNT_NAME" -f "$tmp_dir/ca"
            else
                ssh-keygen -q -t rsa -b 3072 -m PEM -N '' -C "$ACCOUNT_NAME" -f "$tmp_dir/ca"
            fi
            payload=$(echo "$base" | jq --rawfile key "$tmp_dir/ca" '. + {private_key: $key}')
            rm -rf "$tmp_dir"
            response=$(api_call_status "POST" "/vault/account" "$payload")
            code=$(http_code "$response")
            is_2xx "$code" && break
        done
    fi

    if ! is_2xx "$code"; then
        echo "  ERROR: Failed to create the SSH CA vault account - HTTP $code"
        echo "         API response: $(http_body "$response")"
        echo "         SSH CA accounts need PRA 23.3.1 or later, and the API account needs"
        echo "         Manage Vault Accounts (Management -> API Configuration)."
        return 1
    fi

    ACCOUNT_ID=$(http_body "$response" | jq -r '.id // empty')
    PUBLIC_KEY=$(http_body "$response" | jq -r '.public_key // empty')
    if [ -z "$ACCOUNT_ID" ]; then
        echo "  ERROR: PRA accepted the SSH CA account but returned no ID"
        return 1
    fi
    add_bt_resource "vault_account" "$ACCOUNT_ID" "$ACCOUNT_NAME" \
        '{"username": "'"$CERT_USER"'", "type": "ssh_ca"}'
    echo "  Created SSH CA vault account ID: $ACCOUNT_ID"
}

ensure_ssh_ca_account() {
    echo "Creating SSH CA vault account for $CERT_USER on Ubuntu01..."

    find_existing_bt_object "vault_account" "$ACCOUNT_NAME" "/vault/account" || return 1
    if [ -n "$BT_ID" ]; then
        ACCOUNT_ID="$BT_ID"
        PUBLIC_KEY=$(echo "$BT_BODY" | jq -r '.public_key // empty')
        echo "  Reusing SSH CA vault account ID: $ACCOUNT_ID"
    else
        create_ssh_ca_account || return 1
    fi

    # PRA returns the key in authorized_keys form ("cert-authority ssh-ed25519 AAAA...").
    # TrustedUserCAKeys wants the bare key, and sshd skips the whole file when a line does
    # not start with a key type, so keep only the type and the base64 blob.
    local ca_key
    ca_key=$(echo "$PUBLIC_KEY" \
        | grep -oE '(ssh-ed25519|ecdsa-sha2-nistp(256|384|521)|ssh-rsa) [A-Za-z0-9+/]+=*' | head -1)
    if [ -z "$ca_key" ]; then
        echo "  ERROR: PRA returned no usable public key for vault account $ACCOUNT_ID: ${PUBLIC_KEY:-<empty>}"
        return 1
    fi

    echo "$ca_key" > "$CA_PUB_FILE"
    echo "  CA public key saved to $CA_PUB_FILE ($(echo "$ca_key" | cut -d' ' -f1))"
}

ensure_cert_shell_jump() {
    local jumpoint_id linux_group_id policy_id account_id payload response code

    jumpoint_id=$(known_bt_id ../terraform/jumpoint_id.txt "jumpoint" "platform" "windows-x86")
    linux_group_id=$(known_bt_id ../terraform/linux_group_id.txt "jump_group" "name" "$JUMP_GROUP_LINUX")
    # approval_policy.json can hold an error body after a re-run, so use the state file
    policy_id=$(find_bt_resource "jump_policy" "type" "approval_required")
    account_id=$(find_bt_resource "vault_account" "name" "$ACCOUNT_NAME")

    if ! echo "$jumpoint_id $linux_group_id $policy_id $account_id" \
        | grep -qE '^[0-9]+ [0-9]+ [0-9]+ [0-9]+$'; then
        echo "  ERROR: Missing IDs (Jumpoint '$jumpoint_id', Linux group '$linux_group_id'," \
            "approval policy '$policy_id', SSH CA account '$account_id')."
        echo "         Run the full deployment first, then './configure-ssh-ca.sh account'."
        return 1
    fi

    echo "Creating certificate Shell Jump Item for Ubuntu01..."
    find_existing_bt_object "jump_item_shell" "$ITEM_NAME" "/jump-item/shell-jump" || return 1
    if [ -n "$BT_ID" ]; then
        echo "  Reusing shell jump item ID: $BT_ID"
    else
        payload=$(jq -n --arg name "$ITEM_NAME" --arg host "$UBUNTU_PRIVATE_IP" --arg user "$CERT_USER" \
            --argjson jumpoint "$jumpoint_id" --argjson group "$linux_group_id" --argjson policy "$policy_id" '{
            name: $name,
            hostname: $host,
            port: 22,
            protocol: "ssh",
            jumpoint_id: $jumpoint,
            jump_group_id: $group,
            jump_group_type: "shared",
            username: $user,
            terminal: "xterm",
            jump_policy_id: $policy,
            tag: "ssh-certificate",
            comments: "Ubuntu01 with a PRA signed certificate. Choose the SSH CA credential; the account has no password."
        }')

        response=$(api_call_status "POST" "/jump-item/shell-jump" "$payload")
        code=$(http_code "$response")
        BT_ID=$(http_body "$response" | jq -r '.id // empty' 2>/dev/null)
        if ! is_2xx "$code" || [ -z "$BT_ID" ]; then
            echo "  ERROR: Failed to create the certificate Shell Jump item - HTTP $code"
            echo "         API response: $(http_body "$response")"
            return 1
        fi
        add_bt_resource "jump_item_shell" "$BT_ID" "$ITEM_NAME" \
            "{\"hostname\": \"$UBUNTU_PRIVATE_IP\", \"type\": \"shell_jump_certificate\"}"
        echo "  Created shell jump item ID: $BT_ID"
    fi

    # Offer the SSH CA credential on this jump item only. A failure here is not fatal: the
    # account then follows its account group's association, which is how the other demo
    # accounts are offered.
    associate_vault_account "$account_id" "$ITEM_NAME" || true
}

main() {
    case "$1" in
        account)   ensure_ssh_ca_account ;;
        jump-item) ensure_cert_shell_jump ;;
        *)         echo "Usage: $0 account|jump-item"; return 1 ;;
    esac
}

# Only run when executed, so the functions can be sourced for testing
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@" || exit 1
fi
EOF

    chmod +x beyondtrust/scripts/configure-ssh-ca.sh
}

create_beyondtrust_k8s_tunnel_script() {
    print_status "Creating Kubernetes tunnel script..."

    cat > beyondtrust/scripts/configure-k8s-tunnel.sh << 'EOF'
#!/bin/bash
# Kubernetes Cluster Tunnel to the k3s cluster on Ubuntu01 through the Linux Jumpoint, and
# the two service account tokens PRA injects into kubectl requests. The access console
# gives the user a temporary kubeconfig; the tokens never reach their machine.
#
# Needs ../downloads/k8s-ca.pem, plus token-pra-admin and token-pra-readonly in
# K8S_SECRETS_DIR, all written by deploy-infra.sh. Safe to re-run: objects recorded in the
# state file are reused and their CA certificate and tokens refreshed. Payloads are built
# with jq -n because the certificate is multi line and the tokens are long.

source "$(dirname "${BASH_SOURCE[0]}")/bt-api.sh"
source "$(dirname "${BASH_SOURCE[0]}")/state-helper.sh"

ITEM_NAME="${RESOURCE_PREFIX}Ubuntu01 - Kubernetes (k3s)"
K8S_URL="https://10.0.3.10:6443"
CA_FILE="../downloads/k8s-ca.pem"

# Create (or reuse) the tunnel. Sets ITEM_ID.
ensure_k8s_tunnel() {
    local jumpoint_id linux_group_id policy_id payload response code attempt

    jumpoint_id=$(known_bt_id ../terraform/linux_jumpoint_id.txt "jumpoint" "platform" "linux-x86")
    linux_group_id=$(known_bt_id ../terraform/linux_group_id.txt "jump_group" "name" "$JUMP_GROUP_LINUX")
    # approval_policy.json can hold an error body after a re-run, so use the state file
    policy_id=$(find_bt_resource "jump_policy" "type" "approval_required")

    if ! echo "$jumpoint_id $linux_group_id $policy_id" | grep -qE '^[0-9]+ [0-9]+ [0-9]+$'; then
        echo "  ERROR: Missing IDs (Linux Jumpoint '$jumpoint_id', Linux group '$linux_group_id'," \
            "approval policy '$policy_id'). Run the full deployment or --k8s-only first."
        return 1
    fi
    if ! grep -q 'BEGIN CERTIFICATE' "$CA_FILE" 2>/dev/null; then
        echo "  ERROR: No cluster CA certificate at $CA_FILE"
        return 1
    fi

    echo "Creating Kubernetes Cluster Tunnel Jump Item for Ubuntu01..."
    find_existing_bt_object "jump_item_k8s_tunnel" "$ITEM_NAME" "/jump-item/protocol-tunnel-jump" || return 1
    if [ -n "$BT_ID" ]; then
        ITEM_ID="$BT_ID"
        # Keep the CA current in case k3s was reinstalled
        payload=$(jq -n --arg url "$K8S_URL" --rawfile ca "$CA_FILE" '{url: $url, ca_certificates: $ca}')
        response=$(api_call_status "PATCH" "/jump-item/protocol-tunnel-jump/$ITEM_ID" "$payload")
        if is_2xx "$(http_code "$response")"; then
            echo "  Reusing tunnel jump item ID: $ITEM_ID (cluster CA refreshed)"
        else
            echo "  Reusing tunnel jump item ID: $ITEM_ID (WARNING: could not refresh its CA, HTTP $(http_code "$response"))"
        fi
        return 0
    fi

    payload=$(jq -n --arg name "$ITEM_NAME" --arg url "$K8S_URL" --rawfile ca "$CA_FILE" \
        --argjson jumpoint "$jumpoint_id" --argjson group "$linux_group_id" --argjson policy "$policy_id" '{
        name: $name,
        tunnel_type: "k8s",
        url: $url,
        ca_certificates: $ca,
        jumpoint_id: $jumpoint,
        jump_group_id: $group,
        jump_group_type: "shared",
        jump_policy_id: $policy,
        session_policy_id: null,
        tag: "kubernetes",
        comments: "k3s on Ubuntu01. Choose a token credential, then run kubectl with the kubeconfig the console shows."
    }')

    # The Linux Jumpoint may still be connecting for the first time, so allow a short retry
    for attempt in 1 2 3; do
        response=$(api_call_status "POST" "/jump-item/protocol-tunnel-jump" "$payload")
        code=$(http_code "$response")
        if is_2xx "$code" || [ "$code" = "401" ] || [ "$code" = "403" ] || [ "$attempt" -eq 3 ]; then
            break
        fi
        echo "  Tunnel not accepted yet (HTTP $code), retrying in 20s ($attempt/3)..."
        sleep 20
    done

    ITEM_ID=$(http_body "$response" | jq -r '.id // empty' 2>/dev/null)
    if ! is_2xx "$code" || [ -z "$ITEM_ID" ]; then
        echo "  ERROR: Failed to create the Kubernetes tunnel jump item - HTTP $code"
        echo "         API response: $(http_body "$response")"
        echo "         Kubernetes tunnels need PRA 24.1.1 or later and a connected Linux Jumpoint."
        return 1
    fi
    add_bt_resource "jump_item_k8s_tunnel" "$ITEM_ID" "$ITEM_NAME" \
        "{\"url\": \"$K8S_URL\", \"type\": \"k8s_tunnel\"}"
    echo "  Created tunnel jump item ID: $ITEM_ID"
}

# Create (or refresh the token of) one vault token account. Sets TOKEN_ACCOUNT_ID.
ensure_token_account() {
    local name="$1"
    local token_file="$2"
    local description="$3"
    local token payload response code

    echo "Creating Kubernetes token vault account: $name"
    token=""
    if [ -s "$token_file" ]; then
        token=$(tr -d '[:space:]' < "$token_file")
    fi
    if [ -z "$token" ] || [ "${#token}" -gt 4096 ]; then
        echo "  ERROR: No usable token in $token_file (the vault accepts up to 4096 characters)"
        return 1
    fi

    find_existing_bt_object "vault_account" "$name" "/vault/account" || return 1
    if [ -n "$BT_ID" ]; then
        TOKEN_ACCOUNT_ID="$BT_ID"
        # Refresh the token in case the cluster was rebuilt
        payload=$(jq -n --arg token "$token" '{type: "opaque_token", token: $token}')
        response=$(api_call_status "PATCH" "/vault/account/$TOKEN_ACCOUNT_ID" "$payload")
        if is_2xx "$(http_code "$response")"; then
            echo "  Reusing vault account ID: $TOKEN_ACCOUNT_ID (token refreshed)"
        else
            echo "  Reusing vault account ID: $TOKEN_ACCOUNT_ID (WARNING: could not refresh its token, HTTP $(http_code "$response"))"
        fi
        return 0
    fi

    payload=$(jq -n --arg name "$name" --arg token "$token" --arg desc "$description" \
        --argjson group "${VAULT_ACCOUNT_GROUP_ID:-4}" '{
        type: "opaque_token",
        name: $name,
        token: $token,
        description: $desc,
        account_group_id: $group
    }')
    response=$(api_call_status "POST" "/vault/account" "$payload")
    code=$(http_code "$response")
    TOKEN_ACCOUNT_ID=$(http_body "$response" | jq -r '.id // empty' 2>/dev/null)
    if ! is_2xx "$code" || [ -z "$TOKEN_ACCOUNT_ID" ]; then
        echo "  ERROR: Failed to create vault account $name - HTTP $code"
        echo "         API response: $(http_body "$response")"
        return 1
    fi
    add_bt_resource "vault_account" "$TOKEN_ACCOUNT_ID" "$name" '{"type": "opaque_token"}'
    echo "  Created vault account ID: $TOKEN_ACCOUNT_ID"
}

main() {
    local failed=0

    if [ -z "$K8S_SECRETS_DIR" ] || [ ! -d "$K8S_SECRETS_DIR" ]; then
        echo "ERROR: K8S_SECRETS_DIR is not set. Run this through './deploy-infra.sh --k8s-only'."
        return 1
    fi

    ensure_k8s_tunnel || return 1

    if ensure_token_account "${RESOURCE_PREFIX}K8s Admin (cluster-admin)" "$K8S_SECRETS_DIR/token-pra-admin" \
        "Service account pra-demo/pra-admin, bound to cluster-admin on the k3s cluster on Ubuntu01. PRA injects it into kubectl requests."; then
        associate_vault_account "$TOKEN_ACCOUNT_ID" "$ITEM_NAME" || true
    else
        failed=1
    fi

    if ensure_token_account "${RESOURCE_PREFIX}K8s Read Only (view)" "$K8S_SECRETS_DIR/token-pra-readonly" \
        "Service account pra-demo/pra-readonly, bound to the view ClusterRole (read only, no secrets) on the k3s cluster on Ubuntu01."; then
        associate_vault_account "$TOKEN_ACCOUNT_ID" "$ITEM_NAME" || true
    else
        failed=1
    fi

    [ "$failed" -eq 0 ]
}

# Only run when executed, so the functions can be sourced for testing
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@" || exit 1
fi
EOF

    chmod +x beyondtrust/scripts/configure-k8s-tunnel.sh
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

    # Clean up Kubernetes tunnel jump items. These use the Linux Jumpoint, so they must go
    # before terraform destroy removes it.
    local k8s_item_ids=$(get_bt_resources "jump_item_k8s_tunnel")
    if [ -n "$k8s_item_ids" ]; then
        echo "$k8s_item_ids" | while read -r item_id; do
            if [ -n "$item_id" ]; then
                echo "  Deleting Kubernetes tunnel jump item: $item_id"
                api_call "DELETE" "/jump-item/protocol-tunnel-jump/$item_id" "" || echo "    Failed to delete Kubernetes tunnel jump item $item_id"
            fi
        done
    else
        echo "  No Kubernetes tunnel jump items found in state file"
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

# Remove asset (Jump) group assignments from the group policy.
# Must run before terraform destroy removes the Jump Groups themselves.
cleanup_group_policy_assignments() {
    echo "Cleaning up group policy asset group assignments..."

    local assignments
    assignments=$(jq -r '.resources["group_policy_jump_group"][]? | "\(.group_policy_id) \(.id)"' "$STATE_FILE" 2>/dev/null)

    if [ -n "$assignments" ]; then
        echo "$assignments" | while read -r gp_id jg_id; do
            if [ -n "$gp_id" ] && [ -n "$jg_id" ]; then
                echo "  Removing jump group $jg_id from group policy $gp_id"
                api_call "DELETE" "/group-policy/$gp_id/jump-group/$jg_id" "" \
                    || echo "    Failed to remove jump group $jg_id from group policy $gp_id"
            fi
        done
    else
        echo "  No group policy assignments found in state file"
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
cleanup_group_policy_assignments
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
    
    # Regenerate the cleanup script so it knows every resource type this version creates,
    # even when the deployment was made with an older copy of this script
    if [ -f "$PROJECT_DIR/beyondtrust/scripts/cleanup-resources.sh" ]; then
        create_beyondtrust_api_helper
        create_beyondtrust_state_helper
        create_beyondtrust_run_wrapper
        create_beyondtrust_cleanup_script
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
        # Carry on to the Azure resources even if this fails, so the VMs stop billing
        (cd "$PROJECT_DIR/beyondtrust/terraform" && terraform destroy -auto-approve) || \
            print_warning "BeyondTrust Terraform destroy failed, see above. Continuing with Azure; run ./deploy-infra.sh --cleanup again afterwards to retry it."
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
    rm -f beyondtrust/downloads/*.pem
    rm -f beyondtrust/downloads/*.pub
    
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

    # Assign asset groups to the group policy only, against an existing deployment
    if [ "$GROUP_POLICY_ONLY" = true ]; then
        run_group_policy_assignment_only
        exit 0
    fi

    # Add one optional feature to an existing deployment
    if [ "$SSH_CA_ONLY" = true ]; then
        run_ssh_ca_only
        exit 0
    fi
    if [ "$K8S_ONLY" = true ]; then
        run_k8s_only
        exit 0
    fi

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
    if [ "${GROUP_POLICY_ASSIGNED:-false}" = true ]; then
        echo "  Group Policy: ID $GROUP_POLICY_ID - all three asset groups assigned with jump item role ${JUMP_ITEM_ROLE_ID:-$JUMP_ITEM_ROLE_NAME}"
    else
        echo "  Group Policy: ID $GROUP_POLICY_ID - ASSIGNMENT FAILED, asset groups are NOT assigned"
        echo "                Re-run with: ./deploy-infra.sh --group-policy-only"
    fi
    if [ "$ENABLE_K8S_TUNNEL" = true ]; then
        echo "  Jumpoints: $JUMPOINT_NAME on DC01, $LINUX_JUMPOINT_NAME on Ubuntu01 (Kubernetes tunnel)"
    else
        echo "  Jumpoint: $JUMPOINT_NAME on DC01"
    fi
    echo "  Jump Items: RDP access to DC01 and SQL01, MSSQL tunnel to SQL01, SSH Shell Jump to Ubuntu01"
    echo "  Vault Accounts (Windows): $DOMAIN_NETBIOS_NAME\\testadmin, $DOMAIN_NETBIOS_NAME\\jsmith, $DOMAIN_NETBIOS_NAME\\mjohnson, $DOMAIN_NETBIOS_NAME\\bdavis"
    echo "  Vault Accounts (Linux): linuxadmin (local Ubuntu account)"
    case "${SSH_CA_CONFIGURED:-skipped}" in
        true)
            echo "  SSH Certificate Login: ${RESOURCE_PREFIX}Ubuntu01 - SSH (Certificate), SSH CA vault account for $LINUX_CERT_USERNAME (no password on Ubuntu01)" ;;
        false)
            echo "  SSH Certificate Login: NOT configured, re-run with: ./deploy-infra.sh --ssh-ca-only" ;;
    esac
    case "${K8S_TUNNEL_CONFIGURED:-skipped}" in
        true)
            echo "  Kubernetes Tunnel: ${RESOURCE_PREFIX}Ubuntu01 - Kubernetes (k3s), token vault accounts K8s Admin (cluster-admin) and K8s Read Only (view)" ;;
        false)
            echo "  Kubernetes Tunnel: NOT configured, re-run with: ./deploy-infra.sh --k8s-only" ;;
    esac
    echo ""
    echo "Access Patterns:"
    echo "  Direct to DC01: Console → Jump Clients → DC01-JumpClient"
    echo "  Approved to SQL01: Console → Jump Items → SQL01 → Request approval"
    echo "  SSH to Ubuntu01 via Jumpoint: Console → Jump Items → Linux Servers → Ubuntu01 - SSH"
    echo "  Ubuntu01 Jump Client: Console → Jump → Linux Servers → Ubuntu01_JumpClient"
    if [ "${SSH_CA_CONFIGURED:-skipped}" = true ]; then
        echo "  SSH with a certificate: Console → Jump Items → Linux Servers → Ubuntu01 - SSH (Certificate) → choose the SSH CA credential"
    fi
    if [ "${K8S_TUNNEL_CONFIGURED:-skipped}" = true ]; then
        echo "  kubectl through PRA: Console → Jump Items → Linux Servers → Ubuntu01 - Kubernetes (k3s) → choose a token, then run kubectl with the kubeconfig the console shows"
    fi
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
