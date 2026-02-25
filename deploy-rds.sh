#!/bin/bash

# Complete RDS Deployment Script with BeyondTrust Integration (SQL Server Version)
# This script:
# 1. Installs Chocolatey on SQL server
# 2. Installs SSMS via Chocolatey
# 3. Installs RDS roles
# 4. Creates RDS deployment
# 5. Publishes SSMS as RemoteApp
# 6. Adds jump items to BeyondTrust
# 7. Tracks resources in main state file for unified cleanup
#
# Usage:
#   ./deploy-rds.sh          # Deploy RDS and configure BeyondTrust
#   ./deploy-rds.sh --cleanup # Show cleanup instructions

set -e

# Check for cleanup flag
CLEANUP_MODE=false
if [ "$1" = "--cleanup" ]; then
    CLEANUP_MODE=true
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status() { echo -e "${GREEN}[*]${NC} $1"; }
print_error() { echo -e "${RED}[!]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
print_info() { echo -e "${BLUE}[i]${NC} $1"; }

# Project directory (consistent with deploy-infra.sh)
PROJECT_DIR="$HOME/beyondtrust-demo"
CONFIG_FILE="$PROJECT_DIR/config.env"
STATE_FILE="$PROJECT_DIR/deployment-state.json"

# Check prerequisites
check_prerequisites() {
    print_status "Checking prerequisites..."
    
    # Check for project directory
    if [ ! -d "$PROJECT_DIR" ]; then
        print_error "Project directory not found at $PROJECT_DIR"
        print_error "Please run deploy-infra.sh first to set up the environment."
        exit 1
    fi
    
    # Check for config file
    if [ ! -f "$CONFIG_FILE" ]; then
        print_error "config.env not found at $CONFIG_FILE"
        print_error "Please run deploy-infra.sh first to create the configuration."
        exit 1
    fi
    
    # Source configuration
    source "$CONFIG_FILE"
    
    # Check for ansible directory
    if [ ! -d "$PROJECT_DIR/ansible" ]; then
        print_error "Ansible directory not found. Please run deploy-infra.sh first."
        exit 1
    fi
    
    # Check for required files
    if [ ! -f "$PROJECT_DIR/ansible/inventory/hosts.yml" ] || [ ! -f "$PROJECT_DIR/ansible/group_vars/windows.yml" ]; then
        print_error "Ansible inventory files not found. Please run infrastructure deployment first."
        exit 1
    fi
    
    # Check for state file (warn if missing but don't fail)
    if [ ! -f "$STATE_FILE" ]; then
        print_warning "State file not found at $STATE_FILE"
        print_warning "BeyondTrust resources won't be tracked for cleanup"
    else
        print_info "State file found - resources will be tracked for cleanup"
    fi
    
    print_status "Prerequisites check passed"
}

# Simplified cleanup function
cleanup_rds() {
    print_status "RDS Cleanup Information"
    echo ""
    print_info "RDS components (SSMS, RemoteApps, Chocolatey) are installed on the SQL VM."
    print_info "They will be automatically removed when the VM is destroyed."
    echo ""
    print_info "BeyondTrust jump items created by this script are tracked in the main state file."
    print_info "They will be cleaned up automatically when you run infrastructure cleanup."
    echo ""
    print_status "To remove everything (including VMs), run:"
    echo "    ./deploy-infra.sh --cleanup"
    echo ""
}

# Step 1: Install Chocolatey
install_chocolatey() {
    print_status "Installing Chocolatey on SQL server..."
    
    cd "$PROJECT_DIR/ansible"
    
    # Check if Chocolatey is already installed
    local choco_check=$(ansible dc -i inventory/hosts.yml -m ansible.windows.win_shell \
        -a '$password = ConvertTo-SecureString "{{ ansible_password }}" -AsPlainText -Force; $cred = New-Object PSCredential("{{ domain_netbios_name }}\{{ ansible_user }}", $password); Invoke-Command -ComputerName SQL01.{{ domain_name }} -Credential $cred -ScriptBlock { if (Test-Path "C:\ProgramData\chocolatey\bin\choco.exe") { "installed" } else { "not-installed" } }' \
        -e @group_vars/windows.yml 2>/dev/null | grep -o "installed\|not-installed" | tail -1)
    
    if [ "$choco_check" = "installed" ]; then
        print_info "Chocolatey already installed, skipping..."
    else
        print_status "Installing Chocolatey..."
        ansible dc -i inventory/hosts.yml -m ansible.windows.win_shell \
            -a '$password = ConvertTo-SecureString "{{ ansible_password }}" -AsPlainText -Force; $cred = New-Object PSCredential("{{ domain_netbios_name }}\{{ ansible_user }}", $password); Invoke-Command -ComputerName SQL01.{{ domain_name }} -Credential $cred -ScriptBlock { Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; iex ((New-Object System.Net.WebClient).DownloadString("https://chocolatey.org/install.ps1")) }' \
            -e @group_vars/windows.yml
    fi
    
    cd "$PROJECT_DIR"
}

# Step 2: Install SSMS
install_ssms() {
    print_status "Checking if SSMS is already installed on SQL server..."
    
    cd "$PROJECT_DIR/ansible"
    
    # SQL Server 2019 Developer Edition comes with SSMS, but let's check if we need a newer version
    local ssms_check=$(ansible dc -i inventory/hosts.yml -m ansible.windows.win_shell \
        -a '$password = ConvertTo-SecureString "{{ ansible_password }}" -AsPlainText -Force; $cred = New-Object PSCredential("{{ domain_netbios_name }}\{{ ansible_user }}", $password); Invoke-Command -ComputerName SQL01.{{ domain_name }} -Credential $cred -ScriptBlock { $ssms = Get-ChildItem "C:\Program Files (x86)\Microsoft SQL Server Management Studio*\Common7\IDE\Ssms.exe", "C:\Program Files\Microsoft SQL Server Management Studio*\Common7\IDE\Ssms.exe" -ErrorAction SilentlyContinue | Select-Object -First 1; if ($ssms) { "installed: " + $ssms.FullName } else { "not-installed" } }' \
        -e @group_vars/windows.yml 2>&1 | grep -E "(installed:|not-installed)" | tail -1)
    
    if echo "$ssms_check" | grep -q "installed:"; then
        SSMS_PATH=$(echo "$ssms_check" | sed 's/installed: //' | tr -d '\r\n' | xargs)
        print_info "SSMS already installed at: $SSMS_PATH"
        print_info "Skipping SSMS installation via Chocolatey"
    else
        print_status "Installing SSMS via Chocolatey (this will take 5-10 minutes)..."
        ansible dc -i inventory/hosts.yml -m ansible.windows.win_shell \
            -a '$password = ConvertTo-SecureString "{{ ansible_password }}" -AsPlainText -Force; $cred = New-Object PSCredential("{{ domain_netbios_name }}\{{ ansible_user }}", $password); Invoke-Command -ComputerName SQL01.{{ domain_name }} -Credential $cred -ScriptBlock { C:\ProgramData\chocolatey\bin\choco.exe install sql-server-management-studio -y --no-progress }' \
            -e @group_vars/windows.yml -B 1200 -P 30
    fi
    
    # Get SSMS path
    print_status "Verifying SSMS installation path..."
    ansible dc -i inventory/hosts.yml -m ansible.windows.win_shell \
        -a '$password = ConvertTo-SecureString "{{ ansible_password }}" -AsPlainText -Force; $cred = New-Object PSCredential("{{ domain_netbios_name }}\{{ ansible_user }}", $password); Invoke-Command -ComputerName SQL01.{{ domain_name }} -Credential $cred -ScriptBlock { Get-ChildItem "C:\Program Files (x86)\Microsoft SQL Server Management Studio*\Common7\IDE\Ssms.exe", "C:\Program Files\Microsoft SQL Server Management Studio*\Common7\IDE\Ssms.exe" -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName }' \
        -e @group_vars/windows.yml
    
    cd "$PROJECT_DIR"
}

# Step 3: Install RDS Roles
install_rds_roles() {
    print_status "Installing RDS roles on SQL server..."
    
    cd "$PROJECT_DIR/ansible"
    
    # Check if RDS roles are installed
    local rds_check=$(ansible dc -i inventory/hosts.yml -m ansible.windows.win_shell \
        -a '$password = ConvertTo-SecureString "{{ ansible_password }}" -AsPlainText -Force; $cred = New-Object PSCredential("{{ domain_netbios_name }}\{{ ansible_user }}", $password); Invoke-Command -ComputerName SQL01.{{ domain_name }} -Credential $cred -ScriptBlock { if ((Get-WindowsFeature -Name RDS-RD-Server).InstallState -eq "Installed") { "installed" } else { "not-installed" } }' \
        -e @group_vars/windows.yml 2>/dev/null | grep -o "installed\|not-installed" | tail -1)
    
    if [ "$rds_check" = "installed" ]; then
        print_info "RDS roles already installed, skipping..."
    else
        print_status "Installing RDS roles..."
        RDS_INSTALL_OUTPUT=$(ansible dc -i inventory/hosts.yml -m ansible.windows.win_shell \
            -a '$password = ConvertTo-SecureString "{{ ansible_password }}" -AsPlainText -Force; $cred = New-Object PSCredential("{{ domain_netbios_name }}\{{ ansible_user }}", $password); Invoke-Command -ComputerName SQL01.{{ domain_name }} -Credential $cred -ScriptBlock { Install-WindowsFeature -Name RDS-RD-Server, RDS-Connection-Broker, RDS-Web-Access -IncludeManagementTools -Restart:$false }' \
            -e @group_vars/windows.yml -B 600 -P 30 2>&1)
        
        echo "$RDS_INSTALL_OUTPUT"
        
        # Check if reboot is required from the installation output
        print_status "Checking if reboot is required..."
        if echo "$RDS_INSTALL_OUTPUT" | grep -q "RestartNeeded  : Yes" || echo "$RDS_INSTALL_OUTPUT" | grep -q "SuccessRestartRequired"; then
            print_status "Reboot required after RDS installation. Rebooting SQL server..."
            ansible dc -i inventory/hosts.yml -m ansible.windows.win_shell \
                -a '$password = ConvertTo-SecureString "{{ ansible_password }}" -AsPlainText -Force; $cred = New-Object PSCredential("{{ domain_netbios_name }}\{{ ansible_user }}", $password); Invoke-Command -ComputerName SQL01.{{ domain_name }} -Credential $cred -ScriptBlock { Restart-Computer -Force }' \
                -e @group_vars/windows.yml
            
            print_status "Waiting for SQL server to reboot (90 seconds)..."
            sleep 90
            
            # Wait for server to come back online
            print_status "Waiting for SQL server to come back online..."
            local max_attempts=30
            local attempt=1
            while [ $attempt -le $max_attempts ]; do
                if ansible dc -i inventory/hosts.yml -m ansible.windows.win_shell \
                    -a '$password = ConvertTo-SecureString "{{ ansible_password }}" -AsPlainText -Force; $cred = New-Object PSCredential("{{ domain_netbios_name }}\{{ ansible_user }}", $password); Test-WSMan -ComputerName SQL01.{{ domain_name }} -ErrorAction SilentlyContinue' \
                    -e @group_vars/windows.yml &>/dev/null; then
                    print_status "SQL server is back online"
                    break
                fi
                print_info "Waiting for SQL server... (attempt $attempt/$max_attempts)"
                sleep 10
                ((attempt++))
            done
            
            if [ $attempt -gt $max_attempts ]; then
                print_error "SQL server did not come back online after reboot"
                exit 1
            fi
            
            # Give services time to start
            print_status "Waiting for services to stabilize (30 seconds)..."
            sleep 30
        else
            print_info "No reboot required after RDS installation"
        fi
    fi
    
    cd "$PROJECT_DIR"
}

# Step 4: Configure RDS Deployment
configure_rds_deployment() {
    print_status "Configuring RDS deployment..."
    
    cd "$PROJECT_DIR/ansible"
    
    # Step 4.1: Install RDS tools on DC
    print_status "Installing RDS management tools on DC..."
    ansible dc -i inventory/hosts.yml -m ansible.windows.win_shell \
        -a 'Install-WindowsFeature RSAT-RDS-Tools -IncludeManagementTools' \
        -e @group_vars/windows.yml
    
    # Step 4.2: Configure CredSSP on SQL server
    print_status "Configuring CredSSP on SQL server..."
    ansible dc -i inventory/hosts.yml -m ansible.windows.win_shell \
        -a '$password = ConvertTo-SecureString "{{ ansible_password }}" -AsPlainText -Force; $cred = New-Object PSCredential("{{ domain_netbios_name }}\{{ ansible_user }}", $password); Invoke-Command -ComputerName SQL01.{{ domain_name }} -Credential $cred -ScriptBlock { Enable-PSRemoting -Force -SkipNetworkProfileCheck; Set-Item WSMan:\localhost\Client\TrustedHosts -Value "DC01,DC01.{{ domain_name }},*.{{ domain_name }}" -Force; Enable-WSManCredSSP -Role Server -Force }' \
        -e @group_vars/windows.yml
    
    # Step 4.3: Configure CredSSP on DC
    print_status "Configuring CredSSP on DC..."
    ansible dc -i inventory/hosts.yml -m ansible.windows.win_shell \
        -a 'Enable-WSManCredSSP -Role Client -DelegateComputer "SQL01.{{ domain_name }}","*.{{ domain_name }}" -Force' \
        -e @group_vars/windows.yml
    
    # Step 4.4: Configure credential delegation policy
    print_status "Configuring credential delegation policy..."
    ansible dc -i inventory/hosts.yml -m ansible.windows.win_shell \
        -a '$null = New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CredentialsDelegation" -Force; $null = New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CredentialsDelegation\AllowFreshCredentials" -Force; $null = New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CredentialsDelegation\AllowFreshCredentialsWhenNTLMOnly" -Force; Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CredentialsDelegation" -Name "AllowFreshCredentials" -Value 1 -Type DWord; Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CredentialsDelegation" -Name "ConcatenateDefaults_AllowFresh" -Value 1 -Type DWord; Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CredentialsDelegation" -Name "AllowFreshCredentialsWhenNTLMOnly" -Value 1 -Type DWord; Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CredentialsDelegation" -Name "ConcatenateDefaults_AllowFreshNTLMOnly" -Value 1 -Type DWord; Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CredentialsDelegation\AllowFreshCredentials" -Name "1" -Value "WSMAN/*.{{ domain_name }}" -Type String; Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CredentialsDelegation\AllowFreshCredentialsWhenNTLMOnly" -Name "1" -Value "WSMAN/*.{{ domain_name }}" -Type String; gpupdate /force' \
        -e @group_vars/windows.yml
    
    # Step 4.5: Create RDS deployment
    print_status "Checking RDS deployment status..."
    
    # First, let's see what state RDS is in
    ansible dc -i inventory/hosts.yml -m ansible.windows.win_shell \
        -a '$password = ConvertTo-SecureString "{{ ansible_password }}" -AsPlainText -Force; $cred = New-Object PSCredential("{{ domain_netbios_name }}\{{ ansible_user }}", $password); Invoke-Command -ComputerName SQL01.{{ domain_name }} -Credential $cred -Authentication CredSSP -ScriptBlock { Import-Module RemoteDesktop; Write-Host "=== Checking RDS State ==="; try { $servers = Get-RDServer -ErrorAction SilentlyContinue; if ($servers) { Write-Host "RDS Servers found:"; $servers | Format-Table -AutoSize } else { Write-Host "No RDS deployment found" } } catch { Write-Host "Error checking RDS: $_" }; Write-Host "`n=== RDS Services ==="; Get-Service -Name "*RDS*","*RemoteDesktop*" | Where-Object { $_.Status -eq "Running" } | Format-Table -AutoSize }' \
        -e @group_vars/windows.yml
    
    print_status "Creating RDS deployment..."
    
    # Try to create the deployment, handling any errors
    RDS_DEPLOY_RESULT=$(ansible dc -i inventory/hosts.yml -m ansible.windows.win_shell \
        -a 'Import-Module RemoteDesktop; $password = ConvertTo-SecureString "{{ ansible_password }}" -AsPlainText -Force; $cred = New-Object PSCredential("{{ domain_netbios_name }}\{{ ansible_user }}", $password); Invoke-Command -ComputerName SQL01.{{ domain_name }} -Credential $cred -Authentication CredSSP -ScriptBlock { Import-Module RemoteDesktop; try { New-RDSessionDeployment -ConnectionBroker "SQL01.{{ domain_name }}" -SessionHost "SQL01.{{ domain_name }}" -ErrorAction Stop; Write-Host "RDS deployment created successfully" } catch { if ($_.Exception.Message -like "*already exists*" -or $_.Exception.Message -like "*deployment is already*") { Write-Host "RDS deployment already exists" } else { throw $_ } } }' \
        -e @group_vars/windows.yml 2>&1)
    
    echo "$RDS_DEPLOY_RESULT"
    
    if echo "$RDS_DEPLOY_RESULT" | grep -q "created successfully\|already exists"; then
        print_status "RDS deployment is ready"
        
        # Add Web Access role
        print_status "Adding Web Access role..."
        ansible dc -i inventory/hosts.yml -m ansible.windows.win_shell \
            -a '$password = ConvertTo-SecureString "{{ ansible_password }}" -AsPlainText -Force; $cred = New-Object PSCredential("{{ domain_netbios_name }}\{{ ansible_user }}", $password); Invoke-Command -ComputerName SQL01.{{ domain_name }} -Credential $cred -Authentication CredSSP -ScriptBlock { Import-Module RemoteDesktop; try { Add-RDServer -Server "SQL01.{{ domain_name }}" -Role "RDS-WEB-ACCESS" -ConnectionBroker "SQL01.{{ domain_name }}" -ErrorAction Stop; Write-Host "Web Access role added successfully" } catch { if ($_.Exception.Message -like "*already*") { Write-Host "Web Access role already configured" } else { throw $_ } } }' \
            -e @group_vars/windows.yml
    else
        print_error "Failed to create RDS deployment. You may need to run cleanup and try again."
        exit 1
    fi
    
    cd "$PROJECT_DIR"
}

# Step 5: Create RemoteApp Collection and Publish SSMS
publish_ssms_remoteapp() {
    print_status "Publishing SSMS as RemoteApp..."
    
    cd "$PROJECT_DIR/ansible"
    
    # Step 5.1: Create session collection
    print_status "Creating RemoteApp session collection..."
    
    # First check what collections exist
    print_status "Checking existing session collections..."
    ansible dc -i inventory/hosts.yml -m ansible.windows.win_shell \
        -a '$password = ConvertTo-SecureString "{{ ansible_password }}" -AsPlainText -Force; $cred = New-Object PSCredential("{{ domain_netbios_name }}\{{ ansible_user }}", $password); Invoke-Command -ComputerName SQL01.{{ domain_name }} -Credential $cred -Authentication CredSSP -ScriptBlock { Import-Module RemoteDesktop; try { $collections = Get-RDSessionCollection -ConnectionBroker "SQL01.{{ domain_name }}" -ErrorAction SilentlyContinue; if ($collections) { Write-Host "Found collections:"; $collections | Format-Table -AutoSize } else { Write-Host "No collections found" } } catch { Write-Host "Error checking collections: $_" } }' \
        -e @group_vars/windows.yml
    
    # Create or verify collection
    COLLECTION_RESULT=$(ansible dc -i inventory/hosts.yml -m ansible.windows.win_shell \
        -a '$password = ConvertTo-SecureString "{{ ansible_password }}" -AsPlainText -Force; $cred = New-Object PSCredential("{{ domain_netbios_name }}\{{ ansible_user }}", $password); Invoke-Command -ComputerName SQL01.{{ domain_name }} -Credential $cred -Authentication CredSSP -ScriptBlock { Import-Module RemoteDesktop; try { $existing = Get-RDSessionCollection -CollectionName "RemoteApps" -ConnectionBroker "SQL01.{{ domain_name }}" -ErrorAction SilentlyContinue; if ($existing) { Write-Host "COLLECTION_EXISTS"; return } } catch { }; try { New-RDSessionCollection -CollectionName "RemoteApps" -SessionHost "SQL01.{{ domain_name }}" -ConnectionBroker "SQL01.{{ domain_name }}" -CollectionDescription "Remote Applications Collection" -ErrorAction Stop; Write-Host "COLLECTION_CREATED" } catch { Write-Host "COLLECTION_ERROR: $_"; throw } }' \
        -e @group_vars/windows.yml 2>&1)
    
    echo "$COLLECTION_RESULT"
    
    if echo "$COLLECTION_RESULT" | grep -q "COLLECTION_EXISTS\|COLLECTION_CREATED"; then
        print_status "RemoteApp collection is ready"
    else
        print_error "Failed to create session collection"
        exit 1
    fi
    
    # Step 5.2: Publish SSMS
    print_status "Publishing SSMS RemoteApp..."
    
    # First, let's find the SSMS path
    print_status "Locating SSMS installation..."
    SSMS_PATH_RESULT=$(ansible dc -i inventory/hosts.yml -m ansible.windows.win_shell \
        -a '$password = ConvertTo-SecureString "{{ ansible_password }}" -AsPlainText -Force; $cred = New-Object PSCredential("{{ domain_netbios_name }}\{{ ansible_user }}", $password); Invoke-Command -ComputerName SQL01.{{ domain_name }} -Credential $cred -Authentication CredSSP -ScriptBlock { $ssmsPath = Get-ChildItem -Path "C:\Program Files (x86)\Microsoft SQL Server Management Studio*", "C:\Program Files\Microsoft SQL Server Management Studio*" -Filter "Ssms.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName; if ($ssmsPath) { Write-Output "SSMS_PATH:$ssmsPath" } else { Write-Output "SSMS_NOT_FOUND" } }' \
        -e @group_vars/windows.yml 2>&1)
    
    if echo "$SSMS_PATH_RESULT" | grep -q "SSMS_NOT_FOUND"; then
        print_error "SSMS executable not found. Please ensure SSMS is installed."
        exit 1
    fi
    
    # Extract the path and fix backslashes
    SSMS_PATH=$(echo "$SSMS_PATH_RESULT" | grep "SSMS_PATH:" | sed 's/SSMS_PATH://g' | tr -d '\r\n' | sed 's/\\r//g' | sed 's/\\n//g' | xargs)
    print_info "Found SSMS at: $SSMS_PATH"
    
    # Publish SSMS directly without checking if it exists
    print_status "Publishing SSMS as RemoteApp..."
    ansible dc -i inventory/hosts.yml -m ansible.windows.win_shell \
        -a '$password = ConvertTo-SecureString "{{ ansible_password }}" -AsPlainText -Force; $cred = New-Object PSCredential("{{ domain_netbios_name }}\{{ ansible_user }}", $password); Invoke-Command -ComputerName SQL01.{{ domain_name }} -Credential $cred -Authentication CredSSP -ScriptBlock { Import-Module RemoteDesktop; $ssmsPath = Get-ChildItem -Path "C:\Program Files (x86)\Microsoft SQL Server Management Studio*", "C:\Program Files\Microsoft SQL Server Management Studio*" -Filter "Ssms.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName; if (-not $ssmsPath) { throw "SSMS not found" }; try { Remove-RDRemoteApp -CollectionName "RemoteApps" -Alias "SSMS" -ConnectionBroker "SQL01.{{ domain_name }}" -Force -ErrorAction SilentlyContinue } catch { }; New-RDRemoteApp -CollectionName "RemoteApps" -DisplayName "SQL Server Management Studio" -FilePath $ssmsPath -Alias "SSMS" -ShowInWebAccess $true -ConnectionBroker "SQL01.{{ domain_name }}" -IconPath "C:\Windows\System32\shell32.dll" -IconIndex 0 }' \
        -e @group_vars/windows.yml
    
    # Verify deployment
    print_status "Verifying RDS deployment..."
    ansible dc -i inventory/hosts.yml -m ansible.windows.win_shell \
        -a '$password = ConvertTo-SecureString "{{ ansible_password }}" -AsPlainText -Force; $cred = New-Object PSCredential("{{ domain_netbios_name }}\{{ ansible_user }}", $password); Invoke-Command -ComputerName SQL01.{{ domain_name }} -Credential $cred -Authentication CredSSP -ScriptBlock { Import-Module RemoteDesktop; Write-Host "=== RDS Servers ==="; Get-RDServer -ConnectionBroker "SQL01.{{ domain_name }}"; Write-Host "`n=== Session Collections ==="; Get-RDSessionCollection -ConnectionBroker "SQL01.{{ domain_name }}"; Write-Host "`n=== Published RemoteApps ==="; Get-RDRemoteApp -ConnectionBroker "SQL01.{{ domain_name }}" | Select-Object DisplayName, Alias }' \
        -e @group_vars/windows.yml
    
    cd "$PROJECT_DIR"
}

# Step 6: Add to BeyondTrust
add_to_beyondtrust() {
    print_status "Adding RDS jump items to BeyondTrust..."
    
    # Source configuration
    source "$CONFIG_FILE"
    
    # Function to get API token
    get_api_token() {
        local response=$(curl -s -X POST "$BT_API_HOST/oauth2/token" \
            -H "Content-Type: application/x-www-form-urlencoded" \
            -d "client_id=$BT_CLIENT_ID" \
            -d "client_secret=$BT_CLIENT_SECRET" \
            -d "grant_type=client_credentials")
        
        echo "$response" | jq -r '.access_token // empty'
    }
    
    TOKEN=$(get_api_token)
    
    if [ -z "$TOKEN" ]; then
        print_error "Failed to get BeyondTrust API token"
        return 1
    fi
    
    # Get required IDs
    print_status "Getting BeyondTrust resource IDs..."
    
    # Get Jump Groups
    JUMP_GROUPS=$(curl -s -X GET "$BT_API_HOST/api/config/v1/jump-group" \
        -H "Authorization: Bearer $TOKEN")
    
    echo "Available Jump Groups:"
    echo "$JUMP_GROUPS" | jq -r '.[] | "\(.id): \(.name)"'
    
    # Try to find Demo jump group
    DEMO_GROUP_ID=$(echo "$JUMP_GROUPS" | jq -r '.[] | select(.name | contains("Demo") or contains("demo")) | .id' | head -1)
    
    # If no demo group found, use the first available group
    if [ -z "$DEMO_GROUP_ID" ]; then
        DEMO_GROUP_ID=$(echo "$JUMP_GROUPS" | jq -r '.[0].id')
    fi
    
    if [ -z "$DEMO_GROUP_ID" ]; then
        print_error "No jump groups found. Please create a jump group in BeyondTrust first."
        return 1
    fi
    
    print_info "Using Jump Group ID: $DEMO_GROUP_ID"
    
    # Get Jumpoints
    JUMPOINTS=$(curl -s -X GET "$BT_API_HOST/api/config/v1/jumpoint" \
        -H "Authorization: Bearer $TOKEN")
    
    echo "Available Jumpoints:"
    echo "$JUMPOINTS" | jq -r '.[] | "\(.id): \(.name)"'
    
    # Try to find DC jumpoint
    JUMPOINT_ID=$(echo "$JUMPOINTS" | jq -r '.[] | select(.name | contains("DC") or contains("dc")) | .id' | head -1)
    
    # If no DC jumpoint found, use the first available jumpoint
    if [ -z "$JUMPOINT_ID" ]; then
        JUMPOINT_ID=$(echo "$JUMPOINTS" | jq -r '.[0].id')
    fi
    
    if [ -z "$JUMPOINT_ID" ]; then
        print_error "No jumpoints found. Please create a jumpoint in BeyondTrust first."
        return 1
    fi
    
    print_info "Using Jumpoint ID: $JUMPOINT_ID"
    
    # Create SSMS RemoteApp jump item
    print_status "Creating SSMS RemoteApp jump item..."
    
    read -r -d '' SSMS_JUMP_ITEM <<JSON || true
{
    "name": "SSMS RemoteApp on SQL01",
    "hostname": "10.0.2.10",
    "jumpoint_id": $JUMPOINT_ID,
    "jump_group_id": $DEMO_GROUP_ID,
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
    
    RESULT=$(curl -s -X POST "$BT_API_HOST/api/config/v1/jump-item/remote-rdp" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d "$SSMS_JUMP_ITEM")
    
    if echo "$RESULT" | jq -e '.id' > /dev/null 2>&1; then
        print_status "✓ SSMS RemoteApp jump item created successfully"
        SSMS_ID=$(echo "$RESULT" | jq -r '.id')
        print_info "Jump Item ID: $SSMS_ID"
        
        # Track in main state file for cleanup
        if [ -f "$STATE_FILE" ]; then
            print_status "Adding SSMS RemoteApp to state tracking for cleanup..."
            jq --arg id "$SSMS_ID" \
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
            print_status "✓ State tracking updated - resource will be cleaned up with main infrastructure"
        else
            print_warning "State file not found - jump item won't be tracked for automatic cleanup"
            print_warning "You'll need to manually delete it from BeyondTrust console"
        fi
    else
        print_warning "Failed to create SSMS RemoteApp jump item (may already exist)"
        echo "$RESULT" | jq . 2>/dev/null || echo "$RESULT"
    fi
    
    # Skip creating standard RDP jump item as it's already handled by deploy-infra.sh
    print_info "Full desktop jump item for SQL01 already created by deploy-infra.sh, skipping..."
}

# Main execution
main() {
    # Handle cleanup mode
    if [ "$CLEANUP_MODE" = true ]; then
        echo "=================================================="
        echo "RDS Deployment - Cleanup Information"
        echo "=================================================="
        echo ""
        check_prerequisites
        cleanup_rds
        exit 0
    fi
    
    # Normal deployment mode
    print_status "Starting RDS deployment with BeyondTrust integration on SQL Server"
    echo ""
    
    check_prerequisites
    
    print_status "Step 1: Installing Chocolatey"
    install_chocolatey
    echo ""
    
    print_status "Step 2: Installing/Verifying SQL Server Management Studio"
    install_ssms
    echo ""
    
    print_status "Step 3: Installing RDS roles"
    install_rds_roles
    echo ""
    
    print_status "Step 4: Configuring RDS deployment"
    configure_rds_deployment
    echo ""
    
    print_status "Step 5: Publishing SSMS as RemoteApp"
    publish_ssms_remoteapp
    echo ""
    
    print_status "Step 6: Adding to BeyondTrust"
    add_to_beyondtrust
    echo ""
    
    print_status "✅ RDS deployment with BeyondTrust integration complete!"
    print_status ""
    print_status "What was deployed:"
    print_status "  - Chocolatey package manager on SQL01"
    print_status "  - SQL Server Management Studio (SSMS) verified/installed"
    print_status "  - Remote Desktop Services with all roles"
    print_status "  - RemoteApp collection with SSMS published"
    print_status "  - BeyondTrust jump item for SSMS RemoteApp (tracked in state file)"
    print_status ""
    print_status "To test the deployment:"
    print_status "1. Log into BeyondTrust at: $BT_API_HOST"
    print_status "2. Navigate to Jump > Jump Items"
    print_status "3. Click 'Jump' on 'SSMS RemoteApp on SQL01'"
    print_status "4. SSMS should launch directly without showing the desktop"
    print_status ""
    print_status "RD Web Access is available at: https://SQL01.$DOMAIN_NAME/RDWeb"
    print_status ""
    print_status "To remove everything (VMs + BeyondTrust resources), run:"
    print_status "  ./deploy-infra.sh --cleanup"
    print_status ""
    print_status "Note: The SSMS RemoteApp jump item is tracked in the main state file"
    print_status "      and will be automatically cleaned up with infrastructure."
}

# Run main function
main
