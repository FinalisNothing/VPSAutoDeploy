# VPSAutoDeploy

Automated VPS deployment scripts for Debian 13 with Xray + Nginx + 3x-ui + CLIProxyAPI.

## Deployment Phases

### Phase 0: Reinstall (`phase0-reinstall.sh`)

Run on the **provider's original system** (any distro), as root. It wraps
[bin456789/reinstall](https://github.com/bin456789/reinstall) as
`--username <user> --password <pw> --ssh-port <port> debian 13` — wiping the VPS
and installing a fresh Debian 13 that boots with SSH already on your chosen port.

**First check whether your network reaches the VPS on port 22** (`ssh <provider's account>@<VPS_IP> -p 22`):

- **Reachable** — run phase0 inside that SSH session. Pick a port yourself or press Enter for a random one.
- **Blocked** — open the provider's web VNC console and type the same two commands there.
  VNC has no paste, so press **Enter for a random port** and **write down the port the
  script prints**. No separate "change the port first, then SSH in" detour is needed —
  the reinstall itself sets the port.

```bash
curl -O https://raw.githubusercontent.com/FinalisNothing/VPSAutoDeploy/main/phase0-reinstall.sh
bash phase0-reinstall.sh
# prompts: username / password / SSH port -> YES -> run 'reboot' to start (~5-10 min)
```

The result of reinstall's **non-root mode** (what phase0 always uses):

- Log in with `ssh <username>@<VPS_IP> -p <port>` and the password you set.
  **Not `ssh root@...`** — root has no password and cannot log in; become root with `sudo -i`
  (reinstall configures passwordless sudo for the user).
- If the provider has a firewall/security group, allow TCP `<port>` there — the script
  reminds you before the reboot.

### First-login hardening (`harden-ssh.sh`)

Run on the **fresh Debian 13**, right after the first SSH login, before phase1.
This is a real SSH session, so pasting is safe — which is exactly why the key
is not supplied during phase0/VNC.

```bash
ssh <username>@<VPS_IP> -p <port>        # password from phase0
sudo -i
apt update && apt install -y git
git clone https://github.com/FinalisNothing/VPSAutoDeploy.git
cd VPSAutoDeploy && bash harden-ssh.sh
```

It closes the four gaps reinstall's password mode leaves open, fact-checking
each change on the spot (`ssh-keygen -lf`, `passwd -S`, `sudo -l`, `sshd -T`):

| Before (reinstall password mode) | After |
|---|---|
| the user logs in with a password | the user logs in with **your ed25519 key** (generated on your local machine: `ssh-keygen -t ed25519`, public key pasted into the prompt) |
| sshd accepts passwords | `PasswordAuthentication no` + `KbdInteractiveAuthentication no` |
| sudo asks no password (`/etc/sudoers.d/99-<user>`) | that file is removed — sudo asks for the **user's own password** |
| root has no password at all | root has a password for **`su -` and VNC-console rescue**; SSH still rejects root (`PermitRootLogin` keeps the default `prohibit-password`, and root has no key) |

The script ends by telling you to prove the key login from a **second terminal
before closing the working session**. If the key is ever lost, the provider's
VNC console + the root password is the way back in — the VNC console does not
pass through sshd, so the SSH restrictions do not apply there.

### Phase 1: Kernel Replacement (`phase1-kernel.sh`)

Run on the **freshly reinstalled system**. Updates packages, installs a BBR v3 kernel, and lets you choose a queue discipline (fq/fq_codel/fq_pie/cake).

```bash
bash phase1-kernel.sh
# Installs kernel → prompts for queue algorithm → asks to reboot
```

### Phase 2: Main Configuration (`phase2-configure.sh`)

Run **after kernel reboot**. This is the main script covering 17 steps:

1. Disable virtio_balloon
2. Create user + set passwords
3. SSH port + root login hardening
4. UFW firewall (IPv4 only: SSH/80/443 TCP+UDP)
5. Deploy custom-built Nginx from GitHub Release
6. Install jemalloc (for nginx only)
7. Create nginx.service with jemalloc LD_PRELOAD
8. ACME certificate (ZeroSSL via acme.sh)
9. Cloudflare origin certificate (manual paste)
10. Certificate directory permissions
11. Generate cloudflare-ips.geo
12. Deploy final nginx.conf from template
13. Deploy Fail2ban
14. Install 3x-ui (interactive config skipped via sed)
15. Replace x-ui.db (user uploads via scp, manual confirmation)
16. Install CLIProxyAPI
17. SSH key authentication (disable password login)

> **Note:** jemalloc is only applied to nginx (C program). 3x-ui, Xray, and CLIProxyAPI are Go static binaries — `LD_PRELOAD` has no effect on them.

```bash
# Interactive mode
bash phase2-configure.sh

# Or pre-fill config first (recommended for repeatability)
bash phase2-configure.sh --generate-config
nano /root/vpsautodeploy.conf
bash phase2-configure.sh

# Other commands
bash phase2-configure.sh --status           # Show all service status
bash phase2-configure.sh --reset            # Restore backups, stop services
bash phase2-configure.sh --generate-config  # Generate config template
```

The config file can also be edited locally and uploaded via SCP:
```bash
scp vpsautodeploy.conf root@<VPS_IP>:~/
# or
scp vpsautodeploy.conf <user>@<VPS_IP>:~/
```

The script auto-detects and loads config from `/root/` or any `/home/*/` directory.

## Repository Structure

```
VPSAutoDeploy/
├── README.md
├── phase0-reinstall.sh
├── harden-ssh.sh
├── phase1-kernel.sh
├── phase2-configure.sh
├── templates/
│   ├── nginx.conf.template
│   ├── nginx-temp.conf.template
│   └── nginx.service
├── lib/
│   └── common.sh
└── fail2ban/
    ├── deploy.sh
    ├── jail.local
    ├── update-cloudflare-ips.sh
    ├── unban_timerange.sh
    ├── nginx-additions.conf
    └── filter.d/
        ├── ...
```

## External Script Dependencies

> These are third-party scripts fetched at runtime. Their interfaces may change without notice.

| External Script | Source | Our Handling | Change Risk |
|---|---|---|---|
| `reinstall.sh` | [bin456789/reinstall](https://github.com/bin456789/reinstall) | `--username/--password/--ssh-port` to bypass interaction (never `--ssh-key`) | Parameter format may change |
| BBR v3 `install.sh` | [byJoey/Actions-bbr-v3](https://github.com/byJoey/Actions-bbr-v3) | `echo "1\nn"` to install kernel without auto-reboot; queue algorithm configured via sysctl file | Menu order may change |
| 3x-ui `install.sh` | [mhsanaei/3x-ui](https://github.com/mhsanaei/3x-ui) | Download then `sed` to comment out `config_after_install` call | Function name may be renamed |
| 3x-ui `update.sh` | [MHSanaei/3x-ui](https://github.com/MHSanaei/3x-ui) | Download then `sed` to comment out `config_after_update` call | Same as above |
| CLIProxyAPI installer | [brokechubb/cliproxyapi-installer](https://github.com/brokechubb/cliproxyapi-installer) | Direct execution (zero interaction) | Service file format may change |
| Fail2ban `deploy.sh` | This repository | Pass `SSH_PORT` env var | No external risk |

## Post-Deployment Updates

### 3x-ui Update

Do **not** use `x-ui update`. Instead:

```bash
curl -Ls -o /tmp/x-ui-update.sh https://raw.githubusercontent.com/MHSanaei/3x-ui/main/update.sh
sed -i 's/^[[:space:]]*config_after_update$/#config_after_update/' /tmp/x-ui-update.sh
bash /tmp/x-ui-update.sh
```

The `sed` only comments out the `config_after_update` function **call** (not the function definition), which skips the interactive SSL/credential prompts while preserving database migration.

### CLIProxyAPI Update

Re-run the installer as the service user:

```bash
curl -fsSL https://raw.githubusercontent.com/brokechubb/cliproxyapi-installer/refs/heads/master/cliproxyapi-installer | bash
```

The installer preserves existing `config.yaml` via automatic backup/restore.

## Verification Checklist

- [ ] phase0: reinstall successful, `ssh <username>@<VPS_IP> -p <port>` works, `sudo -i` reaches root
- [ ] harden-ssh: key login works, password login rejected, `sudo` asks the user's password, `su -` accepts the root password
- [ ] phase1: `uname -r` shows BBR v3 kernel
- [ ] phase1: `sysctl net.ipv4.tcp_congestion_control` shows `bbr`
- [ ] phase1: `sysctl net.core.default_qdisc` shows chosen algorithm (fq/fq_codel/fq_pie/cake)
- [ ] virtio_balloon: `lsmod | grep balloon` returns empty
- [ ] User: new user can `sudo`
- [ ] SSH: custom port works
- [ ] UFW: `ufw status` shows IPv4 rules only, 80/443(tcp+udp)/SSH allowed
- [ ] Nginx: `curl http://DIRECT_DOMAIN/.well-known/acme-challenge/test` returns 200/404 (not connection refused)
- [ ] Certificate: `openssl s_client -connect DIRECT_DOMAIN:443` shows valid cert
- [ ] CF cert: CDN domain accessible via Cloudflare
- [ ] Fail2ban: `fail2ban-client status` shows all jails active
- [ ] 3x-ui: `https://DIRECT_DOMAIN/XUI_PANEL_PATH/` accessible in browser
- [ ] CLIProxyAPI: endpoint accessible
- [ ] jemalloc: `grep libjemalloc /proc/$(pgrep -x nginx -o)/maps` shows loaded
- [ ] SSH key: key login works, password login rejected

## State Files

After deployment, these files exist on the VPS:

| File | Purpose | Safe to delete? |
|---|---|---|
| `/root/vpsautodeploy.conf` | Saved configuration (passwords in cleartext) | Yes, after deployment is verified |
| `/root/vpsautodeploy.state` | Completed step tracking | Yes, after deployment is verified |
| `/root/vpsautodeploy.backup/` | Pre-modification config backups | Keep until confident |
