# BeyondTrust Privileged Remote Access: Jump Clients

Source: https://docs.beyondtrust.com/pra/docs/pf-jump-clients

---

## What are Jump Clients?

Jump Clients are software agents installed on remote systems, enabling secure, unattended access to those systems for support or administrative tasks.

They provide reliable, always-available access to remote systems, improving efficiency by allowing teams to resolve issues without requiring user intervention. They enhance security through encrypted connections and customizable access controls.

---

## Accessing the Jump Clients Page

1. Sign into **app.beyondtrust.io**
2. From the main menu, click **Privileged Remote Access > Jump**
3. The Jump page opens with the **Jump Clients** tab displayed by default

---

## Jump Clients Page Overview

The page is broken into the following sections:

- **Left menu** — Navigation to all PRA pages: Status, Consoles & Downloads, My Account, Configuration, Jump, Vault, Console Settings, Users & Security, Reports, Management, and Appliance
- **Status** — Opens the Status page
- **Header** — Change tenant site, manage profile, access documentation
- **Add** — Creates a new Jump Client installer
- **Jump Clients columns** — The list of installed Jump Clients

### Jump Clients Table Columns

| Column | Description |
|---|---|
| Name | Identifier for the Jump Client |
| Jump Group | The group the Jump Client is assigned to, controlling access and organisation |
| Expires | How long the installer is valid, set by the "This Installer Is Valid For" setting |
| Prompt if Elevating on Deploy | Whether the Jump Client prompts for admin credentials during deployment |
| Comments | Additional notes about the Jump Client's purpose or configuration |
| Tag | Keywords/labels for filtering, searching, or categorisation |

### Jump Client Row Actions

- **Share icon** — Download the installer, email the direct download link, or copy the link to clipboard
- **Key icon** — View key info for use with the generic Jump Client installer
- **Clock icon** — Extend how long the installer will be valid
- **Trash icon** — Delete the installer (does not delete any Jump Clients already deployed from it)

### Additional Page Sections

- **Generic Jump Client Installer Download** — Downloads a generic installer not tied to a specific deployment
- **Jump Client Installer Usage** — Command line help for large deployments
- **Jump Client Statistics** — Configure which statistics are gathered (CPU, Console User, Disk, Screen, Uptime)
- **Upgrade** — Control automatic Jump Client upgrades
- **Maintenance** — Manage deletion and lost client thresholds
- **Miscellaneous** — Wake on LAN (WOL) configuration

---

## Jump Client Installer List

The installer list shows all existing Jump Client installers. A platform warning is displayed:

> Installing more than one Jump Client as the same user or more than one Jump Client as a service on the same system is being phased out in a future release. In the Access Console you may use the copy action on a Jump Client to apply different policies to the same endpoint.

Click **Dismiss** to hide the message.

---

## Jump Client Mass Deployment Wizard

To create a new installer, click **Add** at the top of the Jump Client Installer List.

The Mass Deployment Wizard lets administrators deploy Jump Clients to one or more remote computers for unattended access. The only required field is **Jump Group**. Once all fields are completed, click **Create**.

### Wizard Fields

| Field | Description |
|---|---|
| Jump Group | Pin the Jump Client to your personal list or a shared Jump Group. Personal means only you (and higher-ranking roles) can access the system. A shared Jump Group makes it available to all group members. |
| This Installer Is Valid For | How long the installer remains usable (10 minutes to 1 year). If the installer is run after expiry, installation fails. If the Jump Client cannot connect to the appliance within the validity window, it uninstalls automatically. Once installed, a Jump Client stays active until explicitly uninstalled. |
| Name | Display name for the Jump Item (max 128 characters). |
| Comments | Additional notes, helpful for searching and identifying remote systems. |
| Jump Policy | Controls when users can access this Jump Client. Configured under Jump > Jump Policies. If none is applied, access is available at any time. |
| Tag | Organises Jump Clients into categories within the console. |
| Session Policy | The session policy with the highest priority for setting session permissions. |
| Jumpoint Proxy | Specifies which Jumpoint the Jump Client should use as a proxy if it cannot connect directly to the appliance and multicast DNS is not available. |
| Maximum Offline Minutes Before Deletion | Overrides the global setting for how long the Jump Client can be offline before deletion. |
| Attempt an Elevated Install If the Client Supports It | Installs the Jump Client as a system service with admin rights. If unsuccessful or unchecked, installs in user mode. Note: User mode is deprecated and will be removed. Applies only to macOS Desktop and Linux Desktop. |
| Prompt for Elevation Credentials If Needed | Prompts for admin credentials if needed during elevated install. Applies to macOS Desktop only. |
| Connection Type | Active (persistent connection) or Standby (listens for connection requests). |
| Customer Client Start Mode | Normal or Minimised. |
| Support Button Profile | Associates a Support Button profile. |
| Support Button Direct Queue | Associates a direct queue. |

> **Warning:** Mass deployment installers are tied to the user account that created them. If that user is removed from the Jump Group or deleted, the installer will fail.

---

## Distributing the Installer

After clicking **Create**:

1. The **Platform** dropdown defaults to your OS. Change it if deploying to another platform.
2. Choose how to distribute:
   - Download immediately to run locally or push via a systems management tool
   - Copy a direct download link or a cURL/wget/btapi command
   - Email the link to one or more recipients (multiple recipients can install from the same link)
3. Run the installer. The Jump Client attempts to connect to the appliance.
   - If successful, it appears in the Jump interface of the representative console.
   - If it cannot connect immediately, it keeps retrying until it succeeds.
   - If it fails to connect within the "Valid For" window, it uninstalls automatically.

---

## Install on Windows

### Command Line Parameters

| Parameter | Value | Description |
|---|---|---|
| `KEY_INFO=` | `<keyinfo>` | Required for generic installer. Built into the filename for standard installers. |
| `INSTALLDIR=` | `<directory_path>` | Custom install directory (Windows and Linux only). Directory must not already exist. |
| `JC_NAME=` | `<name>` | Sets the Jump Client name (requires override to be enabled). |
| `JC_JUMP_GROUP=` | `user:<username>` or `jumpgroup:<codename>` | Overrides the Jump Group. |
| `JC_SESSION_POLICY=` | `<codename>` | Sets the session policy. |
| `JC_JUMP_POLICY=` | `<codename>` | Sets the Jump Policy. |
| `JC_TAG=` | `<tag-name>` | Sets the tag. |
| `JC_COMMENTS=` | `<comments>` | Sets the comments. |
| `JC_MAX_OFFLINE_MINUTES=` | `<minutes>` | Sets the offline timeout before the client is considered lost. |
| `JC_EPHEMERAL=1` | — | Sets the client to ephemeral mode (marks as uninstalled after 5 minutes offline). |
| `ONLINE_INSTALL=1` | — | Installation fails immediately if the appliance cannot be reached. |
| `START_SERVICES=""` | — | Prevents services from starting after installation. |

> If a parameter is passed but not marked for override in the admin interface, installation fails. Check the OS event log for errors.

### Example msiexec Commands

```
msiexec /i sra-scc-win32.msi jc_jump_group=jumpgroup:general jc_tag=servers
```

```
start /wait msiexec /qn /i sra-pin-21fce94dee1940e.msi ONLINE_INSTALL=1
echo %ERRORLEVEL%
```

Error codes: https://learn.microsoft.com/en-us/windows/win32/msi/error-codes

A silent install can be done by adding `/quiet` to the msiexec command.

### Modifying Windows Proxy Settings

If a deployed Jump Client needs its proxy configuration updated manually:

1. Navigate to `C:\ProgramData\sra-scc-<uid>\`
2. Open and edit `settings.ini`
3. Replace the `[Proxy]` section with:

```ini
[Proxy]
version=1
ProxyUser=myDomain\proxyUser
ProxyPass=MyPassword

[Proxy\Manual]
ProxyMethod=200
ProxyHost=myproxyserver.example.com
ProxyPort=8443
```

ProxyMethod values: `0` = DIRECT, `100` = HTTP CONNECT, `200` = SOCKS4

4. Save the file and restart the BeyondTrust Jump Client service (or reboot).

Note: After saving, plaintext credentials are automatically hashed.

### Mass Deployment on Windows (Avoiding Duplicates)

Recommended deployment rate: no more than **60 clients per minute** to avoid failures.

To prevent duplicate installations, use one of these approaches:

**Using INSTALLDIR:**
```
msiexec /i sra-scc-win64.msi KEY_INFO=<key_info_string> INSTALLDIR=<your_chosen_dir>
```
The MSI aborts automatically if the directory already exists.

**Using a custom file:** Deploy a marker file (e.g., `PRAJumpClient.txt`) during installation and configure your deployment tool to abort if the file already exists.

**Detecting existing clients:** Abort if any of these are true:
- `sra-scc.exe` processes are running
- Registry has a `DisplayName` entry matching `BeyondTrust Privileged Remote Access Jump Client [your-appliance-hostname]`

---

## Install on Linux

### Changes in Version 25.2+

- Headless and desktop installers are now combined into one. The platform shows as **Linux (64)** instead of separate headless/desktop options.
- Headless can now be deployed in both service mode and user mode.
- The `--silent` parameter has been removed.
- New parameters added: `--scope`, `--startup`, `--headless`, `--online-install`, `--session-user`

### Command Line Parameters

| Parameter | Value | Description |
|---|---|---|
| `--scope` | `system` (default) or `user` | `system` services all users and requires root. `user` services only the installing user. |
| `--startup` | `auto` (default), `systemd`, `xdg`, or `none` | Controls how the service starts on boot. |
| `--headless` | — | Disables any functionality requiring a graphical session. |
| `--install-dir` | `<path>` | Custom install directory. Must not already exist. |
| `--key-info` | `<keyinfo>` | Required for generic installer. |
| `--jc-name` | `<name>` | Sets the Jump Client name. |
| `--jc-jump-group` | `user:<username>` or `jumpgroup:<codename>` | Overrides the Jump Group. |
| `--jc-session-policy` | `<codename>` | Sets the session policy. |
| `--jc-jump-policy` | `<codename>` | Sets the Jump Policy. |
| `--jc-tag` | `<tag-name>` | Sets the tag. |
| `--jc-comments` | `<comments>` | Sets the comments. |
| `--jc-max-offline-minutes` | `<minutes>` | Sets the offline timeout. |
| `--jc-ephemeral` | — | Ephemeral mode (uninstalls after 5 minutes offline). |
| `--online-install` | — | Fails immediately if the server cannot be reached during install. |
| `--session-user` | `<username>` | Sessions run as this user. Only applicable with `--scope system` and `--headless`. Without this, sessions run as root. |
| `--help` | — | Displays argument help. |

### Service Mode Installation

To install in service mode, run as root:

```bash
sudo sh ./Downloads/sra-pin-[uid].bin
```

Service mode allows sessions even when no user is logged in and allows logging off and switching users. User mode does not support this.

### Uninstalling on Headless Linux

Remove the Jump Client via the access console, then run the uninstall script:

```bash
# User mode
/install/folder/uninstall

# Service mode
sudo /install/folder/uninstall
```

Note: Manual boot configuration changes (systemd units, etc.) are not removed by the script.

### Headless Linux Installation

```bash
sudo sh ./sra-pin-[uid].bin --headless --scope system --session-user <username>
```

### Screen Sharing on Headless Clients (v25.3+)

Available if X11 is present. Requirements:
- The headless SCC must know the correct `$DISPLAY` value
- `xauth` must permit the session user to connect to the X server

#### Option 1: Run Everything as Root

Create `/opt/beyondtrust/session-wrapper.sh`:

```bash
#!/bin/bash
export DISPLAY=:0
export SHELL=/bin/bash
exec "$@"
```

Install:

```bash
chmod +x /opt/beyondtrust/session-wrapper.sh
sh "sra-pin-xxx.bin" --headless --session-wrapper /opt/beyondtrust/session-wrapper.sh
```

Sessions run as root. Full screen sharing and file transfer available.

#### Option 2: Install as Root, Run Sessions as a Specific User

Create `/opt/beyondtrust/session-wrapper.sh`:

```bash
#!/bin/bash
export DISPLAY=:0
exec "$@"
```

Install:

```bash
sh "sra-pin-xxx.bin" --headless --session-wrapper /opt/beyondtrust/session-wrapper.sh --session-user sessionuser
```

Sessions run as `sessionuser`. File transfer limited to that user's permissions.

#### Option 3: Install Everything as a Non-Root User

```bash
sh "sra-pin-xxx.bin" --scope user --headless
```

No root permissions required at any point. Startup must be configured manually. Note the init-script path printed at the end of installation and arrange for it to run at boot.

### Wayland Support

Requires the Wayland to X11 Video Bridge (preinstalled on most distros). Supported capabilities:
- Mouse and keyboard support
- Screen sharing
- Ubuntu 24.04 and RHEL 10
- English keyboards

Current limitations:
- Jump Client thumbnails not supported
- Team Monitoring not supported

To disable Wayland for troubleshooting:

1. Edit `/etc/gdm3/custom.conf`
2. Set `WaylandEnable=false`
3. Restart the system

---

## Install on Mac

### Command Line Parameters

| Parameter | Value | Description |
|---|---|---|
| `--key-info` | `<keyinfo>` | Required for generic installer. |
| `--install-dir` | `<path>` | Custom install directory. |
| `--jc-name` | `<name>` | Sets the Jump Client name. |
| `--jc-jump-group` | `user:<username>` or `jumpgroup:<codename>` | Overrides the Jump Group. |
| `--jc-session-policy` | `<codename>` | Sets the session policy. |
| `--jc-jump-policy` | `<codename>` | Sets the Jump Policy. |
| `--jc-tag` | `<tag-name>` | Sets the tag. |
| `--jc-comments` | `<comments>` | Sets the comments. |
| `--jc-max-offline-minutes` | `<minutes>` | Sets the offline timeout. |
| `--jc-ephemeral` | — | Ephemeral mode. |

### macOS Privacy Policy Preference Control (PPPC)

Required for macOS Mojave (10.14) and later. Deploy a PPPC profile via MDM targeting:

- **Identifier:** `com.bomgar.bomgar-scc`
- **Identifier Type:** Bundle ID
- **Code Requirement:** `identifier "com.bomgar.bomgar-scc" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = B65TM49E24`

| Service | Purpose | Setting |
|---|---|---|
| Accessibility | Screen Sharing | true |
| SystemPolicyAllFiles (Full Disk Access) | File Transfer | true |
| ScreenCapture (Screen Recording) | Screen Sharing | AllowStandardUserToSetSystemService |

### macOS Managed Login Items (Ventura 13+)

Deploy a configuration profile with:

| Rule Type | Rule Value |
|---|---|
| Label Prefix | Bomgar |
| Team Identifier | B65TM49E24 |
| Label Prefix | com.bomgar |

### Mass Deploy on macOS: Prerequisites

Create a **service account** with:
- Access to endpoints enabled
- All Session Management and User-to-User Screen Sharing unchecked
- Under Allowed Jump Item Methods: Jump Clients only
- Jump Item Roles: Default = Administrator, System = Administrator

### Create a Jump Client Installer Package for macOS

1. Log into PRA, go to Jump > Jump Clients > Add
2. Select a default Jump Group
3. Check **Allow Override During Installation** for all options
4. Set a validity period
5. Check **Start Customer Client Minimized When Session is Started**
6. Click **Create**, select **macOS**, click **Download**

Do not rename the downloaded DMG file. It follows the format `sra-scc-<uid>.dmg`.

### Deploy Sequence

1. Stage the DMG in a temp location
2. Mount the DMG
3. Install the Jump Client
4. Unmount the disk image
5. Remove the DMG from the temp location

### Deploy via JAMF Pro

**Upload the package:**
1. Computers > Management Settings > Computer Management > Packages > New
2. Fill in the display name and upload the DMG, then Save

**Create the deployment script** (PRA 23.3.1 and later):

```bash
hdiutil attach /Library/Application\ Support/JAMF/Waiting\ Room/sra-scc-<uid>.dmg
sudo /Volumes/sra-scc/Open\ To\ Start\ Support\ Session.app/Contents/MacOS/sdcust --silent
sleep 15
```

For versions before 23.3.1:

```bash
hdiutil attach /Library/Application\ Support/JAMF/Waiting\ Room/sra-scc-<uid>.dmg
sudo /Volumes/sra-scc/Double-Click\ To\ Start\ Support\ Session.app/Contents/MacOS/sdcust --silent
sleep 15
```

If quarantine issues arise, add to the script:

```bash
xattr -d com.apple.quarantine sra-scc-[uid].dmg
```

**Create the deployment policy:**
- Execution Frequency: Once Per Computer
- Add the package, set action to **Cache**
- Add the deployment script, priority set to **After**

---

## Install on Raspberry Pi

1. In the admin interface, go to Jump > Jump Clients
2. Select a Jump Group
3. Optionally apply a Jump Policy and Session Policy
4. Add a Tag if desired
5. Set Connection Type: Active (persistent) or Passive (listens for requests)
6. Add Comments
7. Set the validity period
8. Click **Create**, select **Raspberry Pi OS**, click **Download**
9. Transfer the installer to the Raspberry Pi
10. Install with a writable directory:

```bash
sh ./sra-scc-{uid}.bin --install-dir /home/pi/<dir>
```

### Raspberry Pi Command Line Parameters

| Parameter | Value | Description |
|---|---|---|
| `--jc-jump-group` | `user:<username>` or `jumpgroup:<codename>` | Overrides the Jump Group. |
| `--jc-session-policy` | `<codename>` | Sets the session policy. |
| `--jc-jump-policy` | `<codename>` | Sets the Jump Policy. |
| `--jc-tag` | `<tag-name>` | Sets the tag. |
| `--jc-comments` | `<comments>` | Sets the comments. |

### Starting the Jump Client

```bash
/home/username/jumpclient/init-script start
```

The init script also accepts: `stop`, `restart`, `status`

### Configure to Start on Boot (systemd)

```bash
cd /etc/systemd/system
vi filename.service
# paste the systemd unit content printed by the installer
chmod 777 filename.service
# reload daemon, enable and start the service
```

### Uninstall on Raspberry Pi

Run the uninstall script AND remove via the access console (both steps required):

```bash
/home/pi/<dir>/uninstall
```

---

## Generic Jump Client Installer

A generic installer is not tied to a specific Jump Client installer, making it useful for automated or ephemeral deployments on VM images.

To use:
1. Select platform and click **Download**
2. Copy the provided CLI command, replacing `insert key info here` with the key from the installer list (Key icon)
3. If using the Windows MSI via the UI, enter the key when prompted

---

## Jump Client Statistics

Configure which stats are collected site-wide (shown in the representative console):

- CPU
- Console User
- Disk Usage
- Screen
- Uptime

**Active Jump Client Statistics Update Interval:** Controls how often Jump Clients push updates. Increase this value as the number of deployed clients grows to conserve bandwidth.

---

## Upgrade Settings

- **Disabled** — Permanently disables automatic upgrades
- **Enabled for this version only** — Temporarily enables upgrades for the current cycle
- **Enabled always** — Permanently enables automatic upgrades

To manually update Jump Clients in the Privileged Web Access Console, automatic upgrades must first be disabled.

---

## Maintenance Settings

| Setting | Description |
|---|---|
| Number of days before Jump Clients that have not connected are automatically deleted | Minimum 15 days. The client also receives this setting and will self-uninstall after the period even if it cannot reach the appliance. |
| Number of days before Jump Clients that have not connected are considered lost | Minimum 15 days. No action is taken, but the client is labelled as lost. Set this lower than the deletion threshold to identify lost clients before they are purged. |
| Uninstalled Jump Client Behavior | When a client is uninstalled at the endpoint: keep it in the list marked as "Uninstalled", or remove it from the list entirely. Applies only to future uninstalls. |

---

## Miscellaneous: Wake on LAN

Allows a representative to attempt to wake a Jump Client by broadcasting Wake-on-LAN (WOL) packets through another Jump Client on the same network.

- After a WOL attempt, the option is unavailable for 30 seconds before another attempt
- WOL must be enabled on the target machine and its network
- Gateway information is used to determine which other Jump Clients are on the same network
- An advanced option allows providing a WOL password for secure WOL environments
