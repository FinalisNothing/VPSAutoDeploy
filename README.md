# VPSAutoDeploy

Automated VPS deployment scripts for Debian 13 with Xray + Nginx + 3x-ui.

## Deployment Phases

### Phase 0: Reinstall (`phase0-reinstall.sh`)

Run on the **provider's original system** (any distro), as root. It wraps
[bin456789/reinstall](https://github.com/bin456789/reinstall) as
`--username <user> --password <pw> --ssh-port <port> debian 13` — wiping the VPS
and installing a fresh Debian 13 that boots with SSH already on your chosen port.

**First check whether your network reaches the VPS on port 22** (`ssh <provider's account>@<VPS_IP> -p 22`):

- **Reachable** — run phase0 inside that SSH session. Pick a port yourself or press Enter for a random one.
- **Blocked** — open the provider's web VNC console and type the same two commands there.
  VNC has no paste, so press **Enter at the password and port prompts** (the script
  generates random values) and **record what it prints** — copy by hand or photograph
  with an offline device, never into an online note. No separate "change the port
  first, then SSH in" detour is needed — the reinstall itself sets the port.

```bash
curl -O https://raw.githubusercontent.com/FinalisNothing/VPSAutoDeploy/main/phase0-reinstall.sh
bash phase0-reinstall.sh
# prompts: username / password / SSH port -> YES -> run 'reboot' to start (~5-10 min)
```

The result of reinstall's **non-root mode** (what phase0 always uses):

- Log in with `ssh <username>@<VPS_IP> -p <port>` and the password from the
  confirmation summary.
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

It closes the five gaps reinstall's password mode leaves open, fact-checking
each change on the spot (`ssh-keygen -lf`, `passwd -S`, `sudo -l`, `sshd -T`):

| Before (reinstall password mode) | After |
|---|---|
| the user logs in with a password | the user logs in with **your ed25519 key** (generated on your local machine: `ssh-keygen -t ed25519`, public key pasted into the prompt) |
| the user's password may have been shown on a VNC screen (phase0's random one) | optionally replaced over the SSH session — Enter keeps it; kept or replaced, it is the **sudo password** from then on |
| sshd accepts passwords | `PasswordAuthentication no` + `KbdInteractiveAuthentication no` |
| sudo asks no password (`/etc/sudoers.d/99-<user>`) | that file is removed — sudo asks for the **user's own password** |
| root has no password at all | root has a password for **`su -` and VNC-console rescue**; SSH still rejects root (`PermitRootLogin` keeps the default `prohibit-password`, and root has no key) |

The script ends by telling you to prove the key login from a **second terminal
before closing the working session**. If the key is ever lost, the provider's
VNC console + the root password is the way back in — the VNC console does not
pass through sshd, so the SSH restrictions do not apply there.

### Phase 1: Kernel Replacement (`phase1-kernel.sh`)

Run on the **freshly reinstalled system**. Updates packages, blacklists
`virtio_balloon` (it takes effect at the reboot this phase ends with),
installs a BBR v3 kernel, and lets you choose a queue discipline
(fq/fq_codel/fq_pie/cake).

```bash
bash phase1-kernel.sh
# Updates system → blacklists balloon → installs kernel → queue algorithm → reboot
```

### Phase 2: Service Deployment (`phase2-deploy.sh`)

Run **after the phase1 kernel reboot** (log in as your user, `sudo -i`,
`cd VPSAutoDeploy`). Identity and login are already owned by the earlier
phases, so phase2 **never asks for usernames, passwords, or SSH ports** — a
read-only preflight detects the phase0 user (`SUDO_USER`) and the SSH port
(`sshd -T`), and verifies the earlier phases' contracts (key-only sshd, BBR
active) before touching anything.

The 11 steps, all scoped to the service stack:

1. UFW firewall (detected SSH port + 80/443 TCP+UDP, IPv4 only)
2. Deploy custom-built Nginx from GitHub Release
3. Install jemalloc (for nginx only)
4. Create nginx.service with jemalloc LD_PRELOAD
5. ACME certificate (ZeroSSL via acme.sh, with an A-record sanity check)
6. Cloudflare origin certificate (pre-uploaded file or paste; validated with openssl)
7. Certificate directory permissions
8. cloudflare-ips.geo (via `update-cloudflare-ips.sh`) + final nginx.conf
9. Install 3x-ui (interactive config skipped via sed)
10. Restore x-ui.db (pre-uploaded file or scp wait; upload-completion detected by size stability)
11. Deploy Fail2ban (jail.d layout, SSH port passed through)

> **Note:** jemalloc is only applied to nginx (C program). 3x-ui and Xray are
> Go static binaries — `LD_PRELOAD` has no effect on them.

```bash
# Recommended: pre-fill config, then run
bash phase2-deploy.sh --generate-config
nano /root/vpsautodeploy.conf
bash phase2-deploy.sh

# Or fully interactive
bash phase2-deploy.sh

# Other commands
bash phase2-deploy.sh --status           # Show all service status
bash phase2-deploy.sh --reset            # Restore backups, stop services (never touches SSH/UFW)
bash phase2-deploy.sh --generate-config  # Generate config template
```

The config file holds **service parameters only** (email, domains, paths,
panel port, disguise backend) — no credentials. It can be edited locally and
uploaded via SCP; the script auto-detects it in `/root/` or any `/home/*/`:

```bash
scp -P <port> vpsautodeploy.conf <user>@<VPS_IP>:~/
```

**Zero-touch run:** upload the optional artifacts together with the config
and phase2 completes without a single prompt:

```bash
scp -P <port> vpsautodeploy.conf cf-fullchain.pem cf-privkey.pem x-ui.db <user>@<VPS_IP>:~/
# cf-fullchain.pem / cf-privkey.pem : Cloudflare origin cert for CDN_DOMAIN
# x-ui.db                           : existing 3x-ui database to restore
```

### Fail2ban layout

Fail2ban config is deployed as `jail.d` drop-ins instead of one `jail.local`:

- `00-default.local` — shared defaults (UFW ban action, progressive bans)
- `01-ignoreip.local` — **generated** by `update-cloudflare-ips.sh` (localhost +
  your entries from `/etc/fail2ban/ignoreip.custom` + fetched Cloudflare ranges)
- `10-sshd.local` — rendered with the detected SSH port; `backend = systemd`
  (minimal Debian 13 has no rsyslog, sshd logs only to the journal)
- `20-nginx.local` / `30-recidive.local` — nginx jails and escalation

`update-cloudflare-ips.sh` is the single source of truth for Cloudflare IPs:
it regenerates both the nginx geo file and the fail2ban ignoreip drop-in,
updates whichever target exists, and runs monthly via cron. Permanent custom
safe-list entries go in `/etc/fail2ban/ignoreip.custom` (one per line) and
survive every refresh.

## Repository Structure

```
VPSAutoDeploy/
├── README.md
├── phase0-reinstall.sh
├── harden-ssh.sh
├── phase1-kernel.sh
├── phase2-deploy.sh
├── templates/
│   ├── nginx.conf.template
│   ├── nginx-temp.conf.template
│   └── nginx.service
├── lib/
│   └── common.sh
└── fail2ban/
    ├── deploy.sh
    ├── update-cloudflare-ips.sh
    ├── unban_timerange.sh
    ├── jail.d/
    │   ├── 00-default.local
    │   ├── 10-sshd.local.template
    │   ├── 20-nginx.local
    │   └── 30-recidive.local
    └── filter.d/
        └── ...
```

## External Script Dependencies

> These are third-party scripts fetched at runtime. Their interfaces may change without notice.

| External Script | Source | Our Handling | Change Risk |
|---|---|---|---|
| `reinstall.sh` | [bin456789/reinstall](https://github.com/bin456789/reinstall) | `--username/--password/--ssh-port` to bypass interaction (never `--ssh-key`) | Parameter format may change |
| BBR v3 `install.sh` | [byJoey/Actions-bbr-v3](https://github.com/byJoey/Actions-bbr-v3) | Menu action numbers derived from the downloaded script; qdisc applied through the installer | Menu order may change |
| 3x-ui `install.sh` | [mhsanaei/3x-ui](https://github.com/mhsanaei/3x-ui) | Download then `sed` to comment out `config_after_install` call | Function name may be renamed |
| 3x-ui `update.sh` | [MHSanaei/3x-ui](https://github.com/MHSanaei/3x-ui) | Download then `sed` to comment out `config_after_update` call | Same as above |
| Fail2ban `deploy.sh` | This repository | Pass `SSH_PORT` env var (auto-detected from `sshd -T` if unset) | No external risk |

## Post-Deployment Updates

### 3x-ui Update

Do **not** use `x-ui update`. Instead:

```bash
curl -Ls -o /tmp/x-ui-update.sh https://raw.githubusercontent.com/MHSanaei/3x-ui/main/update.sh
sed -i 's/^[[:space:]]*config_after_update$/#config_after_update/' /tmp/x-ui-update.sh
bash /tmp/x-ui-update.sh
```

The `sed` only comments out the `config_after_update` function **call** (not the function definition), which skips the interactive SSL/credential prompts while preserving database migration.

## Verification Checklist

- [ ] phase0: reinstall successful, `ssh <username>@<VPS_IP> -p <port>` works, `sudo -i` reaches root
- [ ] harden-ssh: key login works, password login rejected, `sudo` asks the user's password, `su -` accepts the root password
- [ ] phase1: `uname -r` shows BBR v3 kernel
- [ ] phase1: `sysctl net.ipv4.tcp_congestion_control` shows `bbr`
- [ ] phase1: `sysctl net.core.default_qdisc` shows chosen algorithm (fq/fq_codel/fq_pie/cake)
- [ ] phase1: `lsmod | grep balloon` returns empty (after the reboot)
- [ ] phase2 preflight: detected user and SSH port match what phase0 set
- [ ] UFW: `ufw status` shows IPv4 rules only, 80/443(tcp+udp)/SSH allowed
- [ ] Nginx: `curl http://DIRECT_DOMAIN/.well-known/acme-challenge/test` returns 200/404 (not connection refused)
- [ ] Certificate: `openssl s_client -connect DIRECT_DOMAIN:443` shows valid cert
- [ ] CF cert: CDN domain accessible via Cloudflare
- [ ] Fail2ban: `fail2ban-client status` shows all jails active
- [ ] 3x-ui: `https://DIRECT_DOMAIN/XUI_PANEL_PATH/` accessible in browser
- [ ] jemalloc: `grep libjemalloc /proc/$(pgrep -x nginx -o)/maps` shows loaded

## State Files

After deployment, these files exist on the VPS:

| File | Purpose | Safe to delete? |
|---|---|---|
| `/root/vpsautodeploy.conf` | Saved configuration (service parameters, no credentials) | Yes, after deployment is verified |
| `/root/vpsautodeploy.state` | Completed step tracking | Yes, after deployment is verified |
| `/root/vpsautodeploy.backup/` | Pre-modification config backups | Keep until confident |
