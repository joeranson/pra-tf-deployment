# BeyondTrust PRA Demo Environment

Automated deployment of a complete BeyondTrust Privileged Remote Access (PRA) demo environment on Microsoft Azure. The scripts provision Azure infrastructure (Active Directory domain controller and SQL Server), then configure BeyondTrust PRA with jump items, vault accounts, and access policies.

---

## What Gets Deployed

- **Azure Infrastructure**
  - Resource group, virtual network, and three subnets
  - Domain Controller VM (DC01) — Windows Server with Active Directory (public IP)
  - SQL Server VM (SQL01) — Windows Server with SQL Server 2022 Developer Edition
  - Ubuntu VM (Ubuntu01) — Ubuntu 24.04 LTS with BeyondTrust Jump Client (public IP)
  - Network security groups with appropriate firewall rules

- **BeyondTrust PRA Configuration**
  - Jumpoint installed on DC01
  - Jump groups for demo servers, domain controllers, and Linux servers
  - Jump items: SQL Server RDP, DC01 RDP, IIS Web Portal, MSSQL protocol tunnel, Ubuntu01 SSH Shell Jump, Ubuntu01 Jump Client
  - Jump policies: approval-required (SQL + Linux) and direct access (DC)
  - Vault accounts for domain admin, demo users (jsmith, mjohnson, bdavis), and Ubuntu local admin (linuxadmin)

- **Optional: RDS / RemoteApp** (via `--with-rds`)
  - RDS role on SQL01
  - SSMS published as a RemoteApp jump item

---

## Prerequisites

The deployment script (`deploy-infra.sh`) automatically installs all required tools on first run, including Azure CLI, Terraform, Ansible, `jq`, and `curl`. No manual installation is needed.

You will need:
- A Linux machine running a Debian/Ubuntu-based distribution (for `apt-get` based installs)
- `sudo` access (to install system packages)
- An active Azure subscription
- A BeyondTrust PRA instance with API access enabled

---

## Setup

### Step 1 — Clone the repository

```bash
git clone <repository-url>
cd pra-tf-deployment
```

### Step 2 — Generate the configuration file

Run the deployment script once. On first run it detects no configuration exists and creates a template at `~/beyondtrust-demo/config.env`, then exits:

```bash
./deploy-infra.sh
```

### Step 3 — Edit the configuration file

Open `~/beyondtrust-demo/config.env` in your preferred editor and fill in the required values:

```bash
nano ~/beyondtrust-demo/config.env
```

See the [Configuration Reference](#configuration-reference) section below for a full description of every variable.

**Required fields** (the deployment will not proceed without these):

| Variable | Where to find it |
|----------|-----------------|
| `BT_API_HOST` | Your BeyondTrust instance URL, e.g. `https://yourinstance.beyondtrustcloud.com` |
| `BT_CLIENT_ID` | BeyondTrust console → Configuration → API Accounts → create or select an account |
| `BT_CLIENT_SECRET` | Same API account page as above |
| `APPROVER_EMAIL` | Email address that will receive jump approval notifications |
| `VAULT_ACCOUNT_GROUP_ID` | BeyondTrust console → Vault → Account Groups → select the target group and note its numeric ID |

### Step 4 — Deploy

Run the script again. It will log in to Azure, provision infrastructure with Terraform, configure Windows VMs via Ansible, and set up BeyondTrust resources:

```bash
./deploy-infra.sh
```

The full deployment typically takes 20–35 minutes. Progress is printed to the terminal at each phase.

### Step 5 (optional) — Deploy RDS / RemoteApp

To also publish SSMS as a RemoteApp through RDS on SQL01:

```bash
./deploy-infra.sh --with-rds
```

---

## Configuration Reference

All variables live in `~/beyondtrust-demo/config.env`.

### Azure Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `AZURE_REGION` | `East US 2` | Azure region for all resources |
| `ENVIRONMENT` | `demo` | Environment label used in resource naming |
| `ADMIN_USERNAME` | `testadmin` | Local administrator username on both VMs |
| `ADMIN_PASSWORD` | `TestPassword123!` | Local administrator password |
| `DOMAIN_NAME` | `test.local` | Active Directory fully-qualified domain name |
| `DOMAIN_NETBIOS_NAME` | `TEST` | Active Directory NetBIOS name |
| `SAFE_MODE_PASSWORD` | `SafeModePass123!` | AD DS Safe Mode Administrator password |

### BeyondTrust Configuration

| Variable | Default | Required | Description |
|----------|---------|----------|-------------|
| `BT_API_HOST` | _(empty)_ | Yes | BeyondTrust instance URL |
| `BT_CLIENT_ID` | _(empty)_ | Yes | API account client ID |
| `BT_CLIENT_SECRET` | _(empty)_ | Yes | API account client secret |
| `APPROVER_EMAIL` | _(empty)_ | Yes | Email for approval workflow notifications |
| `RESOURCE_PREFIX` | `Demo_` | No | Prefix applied to all created BeyondTrust resources |
| `VAULT_ACCOUNT_GROUP_ID` | `4` | Yes | Numeric ID of the vault account group that demo accounts are assigned to. Find it in BeyondTrust console → Vault → Account Groups. |
| `JUMP_GROUP_DEMO` | `Demo Servers` | No | Name of the jump group for demo servers |
| `JUMP_GROUP_DC` | `Domain Controllers` | No | Name of the jump group for domain controllers |
| `JUMP_GROUP_LINUX` | `Linux Servers` | No | Name of the jump group for Linux servers |
| `JUMPOINT_NAME` | `DC01_Jumpoint` | No | Name of the Jumpoint installed on DC01 |

### Linux VM Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `LINUX_ADMIN_USERNAME` | `linuxadmin` | Local administrator username for the Ubuntu VM |
| `LINUX_ADMIN_PASSWORD` | `UbuntuPass123!` | Local administrator password for the Ubuntu VM |

### Demo User Configuration (optional)

The following variables allow customisation of the demo user accounts created in the vault. They are commented out by default and the built-in defaults are used.

```bash
# DEMO_USER_1="jsmith:John:Smith:DemoPass123!"
# DEMO_USER_2="mjohnson:Mary:Johnson:DemoPass123!"
# DEMO_USER_3="bdavis:Bob:Davis:DemoPass123!"
```

Format: `username:FirstName:LastName:Password`

---

## Finding Your Vault Account Group ID

1. Log in to the BeyondTrust PRA console
2. Navigate to **Vault** → **Account Groups**
3. Click the account group you want demo accounts assigned to
4. The numeric group ID is shown in the page URL or the group details panel
5. Enter this number as `VAULT_ACCOUNT_GROUP_ID` in `config.env`

---

## Cleanup

To remove all resources created by the deployment:

```bash
./deploy-infra.sh --cleanup
```


---

## Architecture Overview

```
Azure Virtual Network (10.0.0.0/16)
├── Subnet 1 (10.0.1.0/24)
│   └── DC01 (10.0.1.10) — Domain Controller + Jumpoint  [public IP]
├── Subnet 2 (10.0.2.0/24)
│   └── SQL01 (10.0.2.10) — SQL Server 2022
└── Subnet 3 (10.0.3.0/24)
    └── Ubuntu01 (10.0.3.10) — Ubuntu 24.04 + Jump Client  [public IP]

BeyondTrust PRA
├── Jumpoint (on DC01) — proxies connections to internal resources
├── Jump Groups
│   ├── Demo Servers       — SQL01 jump items
│   ├── Domain Controllers — DC01 jump items
│   └── Linux Servers      — Ubuntu01 jump items
├── Jump Items
│   ├── SQL01 RDP          — approval-required policy
│   ├── SQL01 IIS Web      — approval-required policy
│   ├── SQL DB Tunnel      — MSSQL protocol tunnel
│   ├── DC01 RDP           — direct access policy
│   ├── Ubuntu01 SSH       — Shell Jump via Jumpoint (approval-required)
│   └── Ubuntu01 JumpClient — Jump Client agent (direct session)
└── Vault
    └── Account Group → Domain Admin, jsmith, mjohnson, bdavis, linuxadmin
```

---

## Troubleshooting

**Deployment fails at Azure login**
Run `az login` manually before executing the script to pre-authenticate.

**BeyondTrust API calls return 401**
Verify `BT_CLIENT_ID` and `BT_CLIENT_SECRET` are correct and that the API account has *Configuration API* and *Manage Vault Accounts* permissions.

**Vault accounts fail to create**
Confirm that `VAULT_ACCOUNT_GROUP_ID` matches an existing group in your BeyondTrust instance. The default value of `4` may not exist in your environment.

**Ansible tasks time out connecting to VMs**
The VMs need a few minutes after provisioning before WinRM is available. The script includes retry logic, but in some regions VMs start more slowly. Re-running the script is safe — it uses state tracking to skip already-completed steps.
