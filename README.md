# BeyondTrust PRA Demo Environment

Automated deployment of a complete BeyondTrust Privileged Remote Access (PRA) demo environment on Microsoft Azure. The scripts provision Azure infrastructure (Active Directory domain controller, SQL Server and an Ubuntu server running a small Kubernetes cluster), then configure BeyondTrust PRA with jump items, vault accounts, and access policies, including SSH certificate login through the PRA Vault SSH CA and kubectl access through a Kubernetes Cluster Tunnel.

---

## What Gets Deployed

- **Azure Infrastructure**
  - Resource group, virtual network, and three subnets
  - Domain Controller VM (DC01) — Windows Server with Active Directory (public IP)
  - SQL Server VM (SQL01) — Windows Server with SQL Server 2022 Developer Edition
  - Ubuntu VM (Ubuntu01) — Ubuntu 24.04 LTS with BeyondTrust Jump Client (public IP)
    - Single node k3s Kubernetes cluster with a small demo app, and the Linux Jumpoint that reaches it
    - A `certadmin` user with no password that only accepts certificates signed by the PRA Vault SSH CA
  - Network security groups with appropriate firewall rules. The Kubernetes API (6443) and kubelet (10250) ports on Ubuntu01 are closed to the network entirely, so the cluster is only reachable through PRA.

- **BeyondTrust PRA Configuration**
  - Jumpoint installed on DC01, plus a Linux Jumpoint on Ubuntu01 (PRA only runs the Kubernetes Cluster Tunnel through a Linux Jumpoint)
  - Jump groups (asset groups) for demo servers, domain controllers, and Linux servers
  - All three asset groups assigned to a group policy (default: `administrators`, ID 2) so its members inherit access
  - Jump items: SQL Server RDP, DC01 RDP, IIS Web Portal, MSSQL protocol tunnel, Ubuntu01 SSH Shell Jump, Ubuntu01 Jump Client, Ubuntu01 SSH Shell Jump with a certificate, and a Kubernetes Cluster Tunnel to the k3s cluster
  - Jump policies: approval-required (SQL + Linux, including the certificate Shell Jump and the Kubernetes tunnel) and direct access (DC)
  - Vault accounts for domain admin, demo users (jsmith, mjohnson, bdavis), and Ubuntu local admin (linuxadmin)
  - A Vault SSH CA account for `certadmin` on Ubuntu01, and two Kubernetes service account tokens: `K8s Admin (cluster-admin)` and `K8s Read Only (view)`

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
- A BeyondTrust PRA instance with API access enabled. SSH certificate login needs PRA 23.3.1 or later and the Kubernetes Cluster Tunnel needs 24.1.1 or later; turn either off in `config.env` for older instances.
- An API account with *Configuration API*, *Manage Vault Accounts* and *Group Policy* permissions

To demo the Kubernetes tunnel you also need `kubectl` on the machine that runs the PRA access console, and the PRA user needs the Protocol Tunnel Jump permission (Jump Technology, set on the user or on their group policy).

---

## Setup

### Step 1 — Clone the repository

```bash
git clone <repository-url>
cd pra-tf-deployment
chmod +x ./deploy-infra.sh
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

### Step 6 (optional) — Re-run just the group policy assignment

Assigning the asset groups to the group policy is idempotent and can be re-run on its own against an
existing deployment, without touching Azure, Terraform or Ansible:

```bash
./deploy-infra.sh --group-policy-only
```

To see the group policies and jump item roles that exist on your instance — useful if the defaults of
`2` don't match — run it in read-only mode:

```bash
./deploy-infra.sh --group-policy-only --list
```

### Step 7 (optional): Add certificate login or the Kubernetes tunnel to an existing deployment

A full deployment sets both up. To add them to an environment you deployed before they existed, or to finish one that did not complete, run just that part. Both are safe to re-run: objects already created are reused rather than duplicated.

```bash
./deploy-infra.sh --ssh-ca-only   # PRA Vault SSH CA, certadmin on Ubuntu01, certificate Shell Jump
./deploy-infra.sh --k8s-only      # Linux Jumpoint and k3s on Ubuntu01, Kubernetes tunnel, token accounts
```

Ubuntu01 must be running. These skip Azure, Terraform for the VMs and Ansible, except that `--k8s-only` applies the BeyondTrust Terraform to add the Linux Jumpoint and adds the NSG rule that closes the Kubernetes ports.

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
| `GROUP_POLICY_ID` | `2` | No | Numeric ID of the group policy the asset (jump) groups are assigned to. `2` is the built-in `Administrator` policy. Find it with `--group-policy-only --list`, or in BeyondTrust console → Users & Security → Group Policies. |
| `JUMP_ITEM_ROLE_ID` | _(empty)_ | No | Numeric ID of the jump item role granted to that group policy on the asset groups. Takes precedence over `JUMP_ITEM_ROLE_NAME` when set. Find it with `--group-policy-only --list`, or in BeyondTrust console → Jump → Jump Item Roles. |
| `JUMP_ITEM_ROLE_NAME` | `Administrator` | No | Used when `JUMP_ITEM_ROLE_ID` is empty: the role is looked up by name. Role IDs differ between instances, names generally don't, so this is the portable option. |
| `JUMP_GROUP_DEMO` | `Demo Servers` | No | Name of the jump group for demo servers |
| `JUMP_GROUP_DC` | `Domain Controllers` | No | Name of the jump group for domain controllers |
| `JUMP_GROUP_LINUX` | `Linux Servers` | No | Name of the jump group for Linux servers |
| `JUMPOINT_NAME` | `DC01_Jumpoint` | No | Name of the Jumpoint installed on DC01 |

### Linux VM Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `LINUX_ADMIN_USERNAME` | `linuxadmin` | Local administrator username for the Ubuntu VM |
| `LINUX_ADMIN_PASSWORD` | `UbuntuPass123!` | Local administrator password for the Ubuntu VM |

### SSH Certificate Login and Kubernetes Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `ENABLE_SSH_CA` | `true` | Set up certificate login for Ubuntu01 through a PRA Vault SSH CA. Needs PRA 23.3.1 or later. |
| `LINUX_CERT_USERNAME` | `certadmin` | Ubuntu user created for certificate login. It has no password and passwordless sudo, and only accepts certificates PRA signs. Must be a new user, not `LINUX_ADMIN_USERNAME` or `root`. |
| `ENABLE_K8S_TUNNEL` | `true` | Install k3s and a Linux Jumpoint on Ubuntu01 and create the Kubernetes Cluster Tunnel. Needs PRA 24.1.1 or later. |
| `K3S_VERSION` | _(empty)_ | k3s release to install, for example `v1.33.4+k3s1`. Empty means the current stable release. |

Config files created before these settings existed work unchanged: the defaults above apply.

### Demo User Configuration (optional)

The following variables allow customisation of the demo user accounts created in the vault. They are commented out by default and the built-in defaults are used.

```bash
# DEMO_USER_1="jsmith:John:Smith:DemoPass123!"
# DEMO_USER_2="mjohnson:Mary:Johnson:DemoPass123!"
# DEMO_USER_3="bdavis:Bob:Davis:DemoPass123!"
```

Format: `username:FirstName:LastName:Password`

---

## Demo Walkthrough: Certificate Login and kubectl

**SSH with a short lived certificate**
1. In the access console, open Jump Items → Linux Servers → `Ubuntu01 - SSH (Certificate)` and request access; the approver gets the email.
2. Once approved, start the session and choose the `Ubuntu01 Cert Admin (SSH CA)` credential. PRA signs a certificate for this session only (valid for five hours) and injects it; nobody sees a key or a password.
3. You land on Ubuntu01 as `certadmin`. Show that the account has no password (`sudo passwd -S certadmin` reports `L`, locked) and no `~/.ssh/authorized_keys`, and that `sudo journalctl -u ssh -n 5` records the login as `Accepted publickey for certadmin ... ED25519-CERT ... CA ...`: a certificate signed by the PRA CA.
4. The session is recorded like any other Shell Jump.

**kubectl through PRA**
1. Open `Ubuntu01 - Kubernetes (k3s)`, request access, and start it with the `K8s Read Only (view)` token.
2. The console shows an environment variable and a command line argument pointing at a temporary kubeconfig. Run kubectl locally with either, e.g. `kubectl get pods -A`.
3. `kubectl delete pod -n demo-apps --all` is refused (Forbidden): the read only token can look but not touch.
4. End the session, start again with `K8s Admin (cluster-admin)`, and the same command works. The token never reaches your machine, the temporary kubeconfig is deleted when the session closes, and the Kubernetes API has no network exposure at all: the only way in is through the Jumpoint.

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

This includes the Linux Jumpoint, the Kubernetes tunnel, the token accounts and the SSH CA account. Deleting that account deletes the CA itself, so nothing else can ever be trusted through it.


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
        ├── k3s (API on 6443, closed to the network by the NSG)
        ├── Linux Jumpoint (reaches the k3s API locally)
        └── certadmin (no password, trusts the PRA Vault SSH CA)

BeyondTrust PRA
├── Jumpoint (on DC01) — proxies connections to internal resources
├── Linux Jumpoint (on Ubuntu01): carries the Kubernetes Cluster Tunnel
├── Jump Groups (Asset Groups)
│   ├── Demo Servers       — SQL01 jump items
│   ├── Domain Controllers — DC01 jump items
│   └── Linux Servers      — Ubuntu01 jump items
├── Group Policy (ID 2 — Administrator)
│   └── all three asset groups assigned with the Administrator jump item role
├── Jump Items
│   ├── SQL01 RDP          — approval-required policy
│   ├── SQL01 IIS Web      — approval-required policy
│   ├── SQL DB Tunnel      — MSSQL protocol tunnel
│   ├── DC01 RDP           — direct access policy
│   ├── Ubuntu01 SSH       — Shell Jump via Jumpoint (approval-required)
│   ├── Ubuntu01 SSH (Certificate): Shell Jump as certadmin with a PRA signed certificate (approval required)
│   ├── Ubuntu01 Kubernetes (k3s): Kubernetes Cluster Tunnel via the Linux Jumpoint (approval required)
│   └── Ubuntu01 JumpClient — Jump Client agent (direct session)
└── Vault
    ├── Account Group → Domain Admin, jsmith, mjohnson, bdavis, linuxadmin
    ├── SSH CA account → Ubuntu01 Cert Admin (offered on the certificate Shell Jump only)
    └── Token accounts → K8s Admin (cluster-admin), K8s Read Only (view) (offered on the tunnel only)
```

---

## Troubleshooting

**Deployment fails at Azure login**
Run `az login` manually before executing the script to pre-authenticate.

**BeyondTrust API calls return 401**
Verify `BT_CLIENT_ID` and `BT_CLIENT_SECRET` are correct and that the API account has *Configuration API*, *Manage Vault Accounts* and *Group Policy* permissions.

**Vault accounts fail to create**
Confirm that `VAULT_ACCOUNT_GROUP_ID` matches an existing group in your BeyondTrust instance. The default value of `4` may not exist in your environment.

**Asset groups are not assigned to the group policy**
The assignment step reports the HTTP status and the API response for every failure, and exits non-zero if any group could not be assigned. Start by listing what actually exists on your instance:

```bash
./deploy-infra.sh --group-policy-only --list
```

Then set `GROUP_POLICY_ID` and `JUMP_ITEM_ROLE_ID` in `config.env` to match, and re-run:

```bash
./deploy-infra.sh --group-policy-only
```

If the asset groups end up with the wrong permissions — for example *Start Sessions Only* instead of *Administrator* — the jump item role is wrong. Jump item role IDs are **not** consistent between instances, so prefer leaving `JUMP_ITEM_ROLE_ID` empty and letting `JUMP_ITEM_ROLE_NAME` resolve it. Re-running after changing either value corrects groups that are already assigned; it does not silently skip them.

A `403` means the API account cannot manage group policies — grant it *Group Policy* access under Configuration → API Accounts. A failed assignment no longer stops the rest of the deployment; it prints a warning and the final summary says the groups were not assigned.

**Ansible tasks time out connecting to VMs**
The VMs need a few minutes after provisioning before WinRM is available. The script includes retry logic, but in some regions VMs start more slowly.

**The summary says SSH certificate login or the Kubernetes tunnel is NOT configured**
These steps never stop the rest of the deployment. Fix the cause shown in the output, then run `./deploy-infra.sh --ssh-ca-only` or `./deploy-infra.sh --k8s-only`. Anything on Ubuntu01 is logged in `/var/log/pra-demo/` on the VM. A `422` or `404` from the API usually means the PRA instance is older than the feature needs (23.3.1 for the SSH CA, 24.1.1 for the Kubernetes tunnel); set `ENABLE_SSH_CA` or `ENABLE_K8S_TUNNEL` to `false` to skip it.

**The new credential does not appear when starting a session**
Each new vault account is limited to its own jump item by name, and users only see accounts they may inject. The new accounts go into `VAULT_ACCOUNT_GROUP_ID`, so check that the group policy has access to that account group. If limiting an account to its jump item failed, the output says so and the account falls back to its account group's jump item association.

**The certificate login is rejected**
sshd only accepts a certificate whose principals include the login name, and the vault account's username is `LINUX_CERT_USERNAME`. To see what PRA signs, check the account out with `POST /api/config/v1/vault/account/{id}/check-out`, save `signed_public_cert` to a file and run `ssh-keygen -L -f` on it. On Ubuntu01, `sudo sshd -T | grep -i trustedusercakeys` should show `/etc/ssh/pra_user_ca.pub`, and `sudo journalctl -u ssh` shows why a login failed.

**The Kubernetes tunnel does not connect**
The Linux Jumpoint must be online in /login (Jump → Jumpoints). Its binary needs desktop libraries (audio, X, GL) that the Ubuntu server image lacks; the script installs the ones BeyondTrust recommends, then any other library the installer reports missing, and names any it could not match to a package. In that case install the package with `sudo apt-get install <package>` and run `./deploy-infra.sh --k8s-only` again. On Ubuntu01, check `sudo systemctl status pra-jumpoint` and `sudo /opt/beyondtrust/jumpoint/init-script status`; the install log is `/var/log/pra-demo/jumpoint.log`. For k3s, `sudo k3s kubectl get nodes` and `/var/log/pra-demo/k3s.log`. If k3s was rebuilt, run `./deploy-infra.sh --k8s-only` to refresh the cluster CA and tokens in PRA.

Note that re-running `./deploy-infra.sh` repeats **every** phase: it re-runs `terraform apply` and all of the Ansible plays, and the BeyondTrust jump policies, jump items and vault accounts are created again rather than reused. The exceptions are the SSH certificate login and Kubernetes tunnel objects, which are reused (and their CA and tokens refreshed) when the state file shows they already exist. The state file records what was created for cleanup; it is not used to skip the other steps. To redo only the group policy assignment, use `--group-policy-only`.
