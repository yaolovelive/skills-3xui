---
name: 3x-ui-node-provisioning
description: Automates deploying and configuring 3x-ui (Xray panel) on remote Linux servers (supporting direct SSH or ProxyJump bastion hosts), system optimization (BBR), panel hardening, and programmatic inbound node creation (VLESS/VMess/Trojan/Reality).
---

# 3x-ui Deployment & Node Provisioning Skill

## Overview
This skill guides the end-to-end deployment of the **3x-ui** panel (`MHSanaei/3x-ui`) and automated creation of proxy nodes on a remote Linux VPS.

---

## Phase 1: Remote Connectivity & Environment Inspection

### 1.1 Connection Modes
Support both direct SSH and Bastion/Jump Host (`ProxyJump` / `-J`) connections:

- **Direct SSH**:
  ```bash
  ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new <TARGET_USER>@<TARGET_HOST> "<COMMAND>"
  ```
- **Via Jump Host (Bastion)**:
  ```bash
  ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -J <JUMP_USER>@<JUMP_HOST> <TARGET_USER>@<TARGET_HOST> "<COMMAND>"
  ```

### 1.2 Pre-flight Environment Check
Before installing 3x-ui, inspect OS version, kernel, sudo privileges, existing `x-ui` service, TCP congestion control (BBR), firewall status, and listening ports:

```bash
uname -a
cat /etc/os-release
sudo -n true 2>/dev/null && echo "SUDO_NOPASSWD_OK" || echo "SUDO_NEEDS_PASS"
sudo systemctl status x-ui 2>&1 || true
sysctl net.ipv4.tcp_congestion_control
sudo ufw status 2>&1 || true
ss -tulpn
```

> **Cloud Provider Note (e.g., GCP / AWS / Alicloud)**:
> If the kernel or hostname indicates a cloud instance (such as `*-gcp`), remind the user or verify that cloud-level VPC firewall rules must allow the panel port (or use SSH local port forwarding `-L`) and inbound node ports.

---

## Phase 2: System Optimization & Preparation

### 2.1 Enable TCP BBR + FQ
Use a drop-in file `/etc/sysctl.d/99-bbr.conf` instead of modifying `/etc/sysctl.conf` directly to ensure idempotency and clean system upgrades:

```bash
sudo tee /etc/sysctl.d/99-bbr.conf >/dev/null <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
sudo sysctl --system >/dev/null
sysctl net.ipv4.tcp_available_congestion_control net.ipv4.tcp_congestion_control net.core.default_qdisc
```
- **Expected verification**: `net.ipv4.tcp_congestion_control = bbr` and `net.core.default_qdisc = fq`.

### 2.2 Check Base Utilities
Verify essential tools (`curl`, `wget`, `tar`, `jq`, `openssl`, and optionally `sqlite3`) are present:
```bash
for cmd in curl wget tar jq sqlite3 openssl; do
  command -v "$cmd" >/dev/null && echo "$cmd: OK" || echo "$cmd: MISSING"
done
```

---

## Phase 3: 3x-ui Installation & Panel Hardening

### 3.1 Non-Interactive Installation (Official `MHSanaei/3x-ui`)
The official `install.sh` supports full non-interactive automation via `XUI_NONINTERACTIVE=1` (or piped stdin) and environment variables:

| Environment Variable | Default (Non-Interactive) | Description |
| :--- | :--- | :--- |
| `XUI_NONINTERACTIVE` | `1` (when piped) | Forces non-interactive installation without TTY prompts |
| `XUI_DB_TYPE` | `sqlite` | `sqlite` (`/etc/x-ui/x-ui.db`) or `postgres` |
| `XUI_PANEL_PORT` | Random (`1024-62000`) | Custom panel listening port |
| `XUI_USERNAME` | Random 10-char alphanumeric | Initial admin username |
| `XUI_PASSWORD` | Random 10-char alphanumeric | Initial admin password |
| `XUI_WEB_BASE_PATH` | Random 18-char alphanumeric | Security URI prefix (`/<webBasePath>/`) |
| `XUI_SSL_MODE` | `none` | `none` (HTTP/SSH tunnel), `ip` (Let's Encrypt 6-day IP cert), or `domain` (requires `XUI_DOMAIN`) |
| `XUI_ENABLE_FAIL2BAN` | `true` | Automatically installs and configures Fail2ban for IP Limit |

**Standard Automated Install Command:**
```bash
curl -fsSL https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh | sudo XUI_NONINTERACTIVE=1 bash
```

### 3.2 Reading Installed Credentials & API Token
Upon completion, `install.sh` persists machine-parseable credentials to `/etc/x-ui/install-result.env` (`chmod 600`):
```bash
sudo cat /etc/x-ui/install-result.env
# Contains:
# XUI_USERNAME=...
# XUI_PASSWORD=...
# XUI_PANEL_PORT=...
# XUI_WEB_BASE_PATH=...
# XUI_ACCESS_URL=...
# XUI_API_TOKEN=...
# XUI_DB_TYPE=...
```
Alternatively, query directly via the `x-ui` CLI:
```bash
sudo /usr/local/x-ui/x-ui setting -show true
sudo /usr/local/x-ui/x-ui setting -getApiToken
```

### 3.3 Updating Panel Credentials / Settings Post-Install
To update username, password, port, or `webBasePath` after installation:
> **Pitfall Warning**: Passwords containing special shell characters (`!`, `{`, `}`, `$`, `"`) **must** be wrapped in single quotes `'...'` when passed over SSH/bash to prevent history expansion or brace/variable expansion.

```bash
sudo /usr/local/x-ui/x-ui setting -username '<NEW_USERNAME>' -password '<NEW_PASSWORD>'
sudo systemctl restart x-ui
```
*(Optional)* Keep `/etc/x-ui/install-result.env` synchronized after updating credentials.

### 3.4 Programmatic API Token Management & Authentication (3x-ui v3.x+)
3x-ui v3.x supports scoped API tokens (`admin`, `monitor`, `node-sync`) and enforces **CSRF protection** on cookie-based browser sessions.

#### Creating & Listing Scoped API Tokens
1. **Via `x-ui` CLI (Works Offline / Without Existing Token)**:
   ```bash
   # Mint or rotate a named token with scope: admin | monitor | node-sync
   sudo /usr/local/x-ui/x-ui setting -getApiToken -tokenName "admin" -tokenScope "admin"
   ```
   *(Note: Initial installation also creates an `install` token with `admin` scope stored in `/etc/x-ui/install-result.env` as `XUI_API_TOKEN`.)*

2. **Via REST API (Non-Destructive Multi-Token Creation)**:
   - **Create Token** (`POST /<webBasePath>/panel/api/setting/apiTokens/create`):
     ```bash
     curl -s --resolve "<DOMAIN>:${XUI_PANEL_PORT}:127.0.0.1" \
       -X POST "https://<DOMAIN>:${XUI_PANEL_PORT}/${XUI_WEB_BASE_PATH}/panel/api/setting/apiTokens/create" \
       -H "Authorization: Bearer ${XUI_API_TOKEN}" \
       -H "Content-Type: application/json" \
       -d '{"name":"admin","scope":"admin","expiresAt":0}' | jq .
     ```
     > **Important**: The plaintext `.obj.token` is only returned once upon creation (only its hash is stored in the database). Save it immediately.
   - **List Tokens** (`GET /<webBasePath>/panel/api/setting/apiTokens`):
     ```bash
     curl -s --resolve "<DOMAIN>:${XUI_PANEL_PORT}:127.0.0.1" \
       "https://<DOMAIN>:${XUI_PANEL_PORT}/${XUI_WEB_BASE_PATH}/panel/api/setting/apiTokens" \
       -H "Authorization: Bearer ${XUI_API_TOKEN}" | jq .
     ```
   - **Toggle / Delete Token**:
     - `POST /<webBasePath>/panel/api/setting/apiTokens/setEnabled/{id}`
     - `POST /<webBasePath>/panel/api/setting/apiTokens/delete/{id}`

#### Authenticating API Requests
1. **Method A — Bearer Token (Recommended for Automation)**:
   - Pass header `Authorization: Bearer <API_TOKEN>` (no CSRF token or cookie jar needed):
     ```bash
     curl -s "https://<DOMAIN>:${XUI_PANEL_PORT}/${XUI_WEB_BASE_PATH}/panel/api/inbounds/list" \
       -H "Authorization: Bearer ${XUI_API_TOKEN}"
     ```

2. **Method B — Session Cookie + CSRF Token (For Login Verification)**:
   - Step 1: Mint a CSRF token and session cookie via `GET /<webBasePath>/csrf-token`:
     ```bash
     CSRF=$(curl -s -c /tmp/xui.cookies "https://<DOMAIN>:${XUI_PANEL_PORT}/${XUI_WEB_BASE_PATH}/csrf-token" | jq -r .obj)
     ```
   - Step 2: Authenticate with `X-CSRF-Token` header and `--data-urlencode`:
     ```bash
     curl -s -b /tmp/xui.cookies -c /tmp/xui.cookies -X POST \
       "https://<DOMAIN>:${XUI_PANEL_PORT}/${XUI_WEB_BASE_PATH}/login" \
       -H "X-CSRF-Token: ${CSRF}" \
       --data-urlencode "username=${XUI_USERNAME}" \
       --data-urlencode "password=${XUI_PASSWORD}"
     ```

### 3.5 Cloud Firewall & Security Group Automation (CLI Detection & Fallback)
When opening inbound ports (`80`, `443`, or custom node ports) and restricting the 3x-ui management port (`<XUI_PANEL_PORT>`) to a specific CIDR (`<ADMIN_CIDR>`):

#### Step 1: Identify Cloud Provider & Instance Metadata from Target VPS
Query the cloud metadata service on the target VPS to extract the exact Project/Account ID, Instance Name, Zone/Region, VPC Network, and Current Tags:

- **Google Cloud (GCP)**:
  ```bash
  curl -s -H "Metadata-Flavor: Google" \
    "http://metadata.google.internal/computeMetadata/v1/?recursive=true" \
    | jq '{projectId: .project.projectId, numericProjectId: .project.numericProjectId, name: .instance.name, zone: .instance.zone, network: .instance.networkInterfaces[0].network, tags: .instance.tags}'
  ```
- **AWS / Alibaba Cloud / Tencent Cloud / DigitalOcean**:
  Check `dmidecode -s system-manufacturer` or cloud-init data (`/run/cloud-init/instance-data.json`) to identify the provider, region, and instance ID.

#### Step 2: Check Local Cloud CLI & Match Credentials
1. Check if the corresponding CLI (`gcloud`, `aws`, `aliyun`, `tccli`, `doctl`) is installed locally.
2. **Multi-Account Pitfall (GCP)**: The active default `gcloud` project/account on the operator's workstation may differ from the VPS's project. List all authenticated accounts (`gcloud auth list`) and test access against the extracted `<PROJECT_ID>` using `--project=<PROJECT_ID> --account=<ACCOUNT>`.
3. **If CLI is Missing or Unauthenticated**:
   - Prompt the user with the one-line CLI install/auth command (e.g., `brew install --cask google-cloud-sdk && gcloud auth login`), **OR**
   - Provide exact parameters for the user to add in the Cloud Console (VPC Network -> Firewall Rules -> Ingress, Target Tags, Source IPv4 Ranges, TCP/UDP Ports).

#### Step 3: Execute Least-Privilege Firewall Provisioning (GCP Example)
1. **Inspect Existing VPC Firewall Rules**:
   ```bash
   gcloud compute firewall-rules list --project="<PROJECT_ID>" --account="<ACCOUNT>" \
     --filter="network~<VPC_NAME>" \
     --format="table(name,network,direction,sourceRanges.list(),allowed[].map().firewall_rule().list(),targetTags.list())"
   ```
2. **Reuse Existing 80/443 Rules or Create If Missing**:
   - If the VPC already has rules allowing `tcp:80,udp:80` (e.g., tag `http` / `http-server`) and `tcp:443,udp:443` (e.g., tag `https` / `https-server`), reuse those tags instead of creating duplicate rules.
3. **Create Restricted Management Port Rule (`<ADMIN_CIDR>` only)**:
   ```bash
   gcloud compute firewall-rules create "<VPC_NAME>-allow-xui-<INSTANCE_NAME>" \
     --project="<PROJECT_ID>" --account="<ACCOUNT>" \
     --network="<VPC_NAME>" --direction=INGRESS --priority=1000 --action=ALLOW \
     --rules="tcp:${XUI_PANEL_PORT}" \
     --source-ranges="<ADMIN_CIDR>" \
     --target-tags="<INSTANCE_NAME>-xui" \
     --description="Allow 3x-ui panel port ${XUI_PANEL_PORT} for <INSTANCE_NAME> from <ADMIN_CIDR>"
   ```
4. **Attach Tags to the Instance**:
   ```bash
   gcloud compute instances add-tags "<INSTANCE_NAME>" \
     --project="<PROJECT_ID>" --account="<ACCOUNT>" \
     --zone="<ZONE>" \
     --tags="http,http-server,https,<INSTANCE_NAME>-xui"
   ```

### 3.6 SSL Certificate Issuance via Cloudflare DNS-01 (`acme.sh`)
When issuing a domain certificate (e.g., `kr.example.com` + wildcard `*.kr.example.com`), prefer **Cloudflare DNS-01 (`--dns dns_cf`)** over HTTP-01 standalone mode because:
- It supports wildcard certificates (`-d <DOMAIN> -d "*.<DOMAIN>"`).
- It works even before the domain's `A`/`AAAA` record points to the new server IP or when Cloudflare proxy (orange cloud) is enabled.
- It does not require stopping services on port 80 during renewal.

#### Step 1: Verify Domain DNS & Auto-Resolve `CF_Account_ID` / `CF_Zone_ID` from `CF_Token`
1. **DNS Sanity Check (Catches Wrong Domain Early)**:
   Before issuing a certificate, always check whether `<DOMAIN>` resolves to `<TARGET_HOST>`:
   ```bash
   dig +short "<DOMAIN>" A @1.1.1.1
   ```
   If it resolves to a different IP, immediately alert the user to confirm whether the domain name is a typo or needs a DNS `A` record update.
2. **Auto-Resolve `CF_Zone_ID` & `CF_Account_ID` from a Single `CF_Token`**:
   `acme.sh`'s `dns_cf` plugin works best when `CF_Token`, `CF_Account_ID`, and `CF_Zone_ID` are all exported. When the user only provides `CF_Token` and `<DOMAIN>` (where `<ROOT_DOMAIN>` is the registrable domain, e.g., `example.com`), query the Cloudflare API directly to retrieve `CF_Zone_ID` and `CF_Account_ID`:
   ```bash
   ZONE_JSON=$(curl -s -H "Authorization: Bearer ${CF_TOKEN}" \
     "https://api.cloudflare.com/client/v4/zones?name=${ROOT_DOMAIN}")
   CF_ZONE_ID=$(echo "$ZONE_JSON" | jq -r '.result[0].id')
   CF_ACCOUNT_ID=$(echo "$ZONE_JSON" | jq -r '.result[0].account.id')
   ```

#### Step 2: Issue & Install Certificate on Target Server
```bash
sudo bash -c '
export CF_Token="<CF_API_TOKEN>"
export CF_Account_ID="<CF_ACCOUNT_ID>"
export CF_Zone_ID="<CF_ZONE_ID>"

if [ ! -f /root/.acme.sh/acme.sh ]; then
  curl -fsSL https://get.acme.sh | sh -s email="<ADMIN_EMAIL>"
fi

/root/.acme.sh/acme.sh --set-default-ca --server letsencrypt
/root/.acme.sh/acme.sh --issue --dns dns_cf \
  -d "<DOMAIN>" -d "*.<DOMAIN>" \
  --keylength ec-256 --force

mkdir -p "/root/cert/<DOMAIN>"
/root/.acme.sh/acme.sh --installcert --ecc -d "<DOMAIN>" \
  --key-file "/root/cert/<DOMAIN>/privkey.pem" \
  --fullchain-file "/root/cert/<DOMAIN>/fullchain.pem" \
  --reloadcmd "systemctl restart x-ui"

chmod 600 "/root/cert/<DOMAIN>/privkey.pem"
chmod 644 "/root/cert/<DOMAIN>/fullchain.pem"

# Bind certificate to 3x-ui panel and restart
/usr/local/x-ui/x-ui cert \
  -webCert "/root/cert/<DOMAIN>/fullchain.pem" \
  -webCertKey "/root/cert/<DOMAIN>/privkey.pem"
systemctl restart x-ui
'
```
> **API Note**: Once the certificate is applied to the panel, `http://127.0.0.1:${XUI_PANEL_PORT}` switches to **HTTPS** (`https://127.0.0.1:${XUI_PANEL_PORT}`). Local `curl` calls against `127.0.0.1` must use `curl -k https://127.0.0.1:...` (or `--resolve <DOMAIN>:${XUI_PANEL_PORT}:127.0.0.1`).

### 3.7 Dynamic DNS (DDNS) via Cloudflare API & Systemd Timer
For VPS instances using ephemeral/dynamic IPv4 or IPv6 addresses, deploy the bundled dual-stack updater script [`scripts/cf-ddns.sh`](scripts/cf-ddns.sh) managed by a systemd timer (`cf-ddns.timer`).

#### Features of `scripts/cf-ddns.sh`
- **Dual-Stack (`A` + `AAAA`)**: Automatically detects public IPv4 and IPv6 addresses with multi-provider fallback (`ipify.org`, `icanhazip.com`, `ident.me`).
- **Idempotent Check-Before-Write**: Queries Cloudflare API first; skips `PUT` when the DNS record already matches the current IP, creates (`POST`) if missing, and updates (`PUT`) only when changed.
- **Auto Zone Discovery**: Automatically resolves `CF_ZONE_ID` from `CF_RECORD_NAME` if `CF_ZONE_ID` is not explicitly set.

#### Deployment Steps on Target Server
1. Copy [`scripts/cf-ddns.sh`](scripts/cf-ddns.sh) to `/usr/local/bin/cf-ddns.sh` (`chmod 755`).
2. Create `/etc/cf-ddns.env` (`chmod 600`):
   ```bash
   CF_TOKEN="<CF_API_TOKEN>"
   CF_ZONE_ID="<CF_ZONE_ID>"
   CF_RECORD_NAME="<DOMAIN>"
   CF_PROXIED="false"
   CF_TTL="60"
   ENABLE_IPV4="true"
   ENABLE_IPV6="true"
   ```
3. Configure and enable both `cf-ddns.service` (triggers immediately on `network-online.target` at boot) and `cf-ddns.timer` (triggers `OnBootSec=30s` and every 5 minutes `OnUnitActiveSec=5min`):
   ```bash
   systemctl daemon-reload
   systemctl enable --now cf-ddns.service cf-ddns.timer
   ```

### 3.8 Fail2ban (`3x-ipl` & `sshd`) and Firewall Whitelisting
When adding an administrative CIDR (e.g., `139.227.76.0/24`) to the whitelist so that 3x-ui's IP Limit (`3x-ipl`) and host/cloud firewalls never block or rate-limit it:

#### 1. Fail2ban Whitelist (`ignoreip`)
- **Override Persistence Pitfall**: Modifying `/etc/fail2ban/jail.d/3x-ipl.conf` alone can be overwritten when `x-ui` updates IP Limit settings. Always create `/etc/fail2ban/jail.d/99-whitelist.conf` (loaded lexically after `3x-ipl.conf`) in addition to updating `3x-ipl.conf`:
  ```bash
  sudo tee /etc/fail2ban/jail.d/99-whitelist.conf >/dev/null <<'EOF'
  [DEFAULT]
  ignoreip = 127.0.0.1/8 ::1 <ADMIN_CIDR>

  [3x-ipl]
  ignoreip = 127.0.0.1/8 ::1 <ADMIN_CIDR>

  [sshd]
  ignoreip = 127.0.0.1/8 ::1 <ADMIN_CIDR>
  EOF
  sudo systemctl reload-or-restart fail2ban
  ```
- **Socket Readiness Pitfall**: After `systemctl restart fail2ban`, wait until `/var/run/fail2ban/fail2ban.sock` is ready (or use `fail2ban-client reload`) before running `fail2ban-client get 3x-ipl ignoreip`.

#### 2. Host Firewall (`iptables` / `ufw`) & Cloud Firewall Whitelist
- **Host Firewall**:
  ```bash
  sudo ufw allow from <ADMIN_CIDR> comment "Whitelist Admin CIDR" >/dev/null 2>&1 || true
  sudo iptables -C INPUT -s <ADMIN_CIDR> -j ACCEPT 2>/dev/null || sudo iptables -I INPUT 1 -s <ADMIN_CIDR> -j ACCEPT
  ```
- **Cloud VPC Firewall (GCP)**:
  Allow all protocols (`--rules=all`) or management ports from `--source-ranges=<ADMIN_CIDR>` for the target instance tag.

### 3.9 Accessing the Panel Safely via SSH Tunnel (Alternative When Port Is Not Exposed)
When `XUI_SSL_MODE=none` or when cloud firewall rules block the panel port:
- **Direct SSH Tunnel**:
  ```bash
  ssh -L <LOCAL_PORT>:127.0.0.1:<XUI_PANEL_PORT> <TARGET_USER>@<TARGET_HOST>
  ```
- **Via Jump Host Tunnel**:
  ```bash
  ssh -J <JUMP_USER>@<JUMP_HOST> -L <LOCAL_PORT>:127.0.0.1:<XUI_PANEL_PORT> <TARGET_USER>@<TARGET_HOST>
  ```
Then open `http://localhost:<LOCAL_PORT>/<XUI_WEB_BASE_PATH>` in the local browser.

---

## Phase 4: Verification & Handover Checklist
Before concluding the deployment, verify and present a structured summary to the user:
1. **Service Health**: `systemctl is-active x-ui fail2ban cf-ddns.timer` all return `active`.
2. **Panel Access URL**: `https://<DOMAIN>:<XUI_PANEL_PORT>/<XUI_WEB_BASE_PATH>/` (verified with standard TLS certificate validation via `curl --resolve`).
3. **Credentials & API Token**: Admin username, password, and newly minted `admin`-scoped API Token (`Authorization: Bearer <TOKEN>`).
4. **Network & Security Posture**:
   - TCP BBR + `fq` enabled (`/etc/sysctl.d/99-bbr.conf`).
   - Cloud firewall & host firewall rules open `80`/`443` and restrict/whitelist `<ADMIN_CIDR>`.
   - Fail2ban (`3x-ipl` and `sshd`) `ignoreip` includes `<ADMIN_CIDR>` via `/etc/fail2ban/jail.d/99-whitelist.conf`.
   - Dual-stack DDNS (`cf-ddns.timer`) active for `A` and `AAAA` records.
