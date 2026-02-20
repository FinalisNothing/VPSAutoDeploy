# VPSAutoDeploy

Automated VPS deployment scripts for Debian 13 with Xray + Nginx + 3x-ui + CLIProxyAPI.

## Deployment Phases

### Phase 0: DD Reinstall (`phase0-reinstall.sh`)

Run on the **old system**. Downloads and executes the DD reinstall script to wipe the VPS and install a fresh Debian 13.

```bash
bash phase0-reinstall.sh
# After reboot, SSH in with: ssh root@VPS_IP -p 22
```

### Phase 1: Kernel Replacement (`phase1-kernel.sh`)

Run on the **freshly reinstalled system**. Updates packages and replaces the kernel with a BBR v3 build.

```bash
bash phase1-kernel.sh
# VPS reboots automatically
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
nano /root/.vpsautodeploy.conf
bash phase2-configure.sh

# Other commands
bash phase2-configure.sh --status   # Show all service status
bash phase2-configure.sh --reset    # Restore backups, stop services
```

## Repository Structure

```
VPSAutoDeploy/
├── README.md
├── phase0-reinstall.sh
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
| `reinstall.sh` | [bin456789/reinstall](https://github.com/bin456789/reinstall) | `--password` parameter to bypass interaction | Parameter format may change |
| BBR v3 `install.sh` | [byJoey/Actions-bbr-v3](https://github.com/byJoey/Actions-bbr-v3) | `echo "1\ny"` piped to stdin | Menu order may change |
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

- [ ] phase0: DD reinstall successful, SSH login works
- [ ] phase1: `uname -r` shows BBR v3 kernel, `sysctl net.ipv4.tcp_congestion_control` shows bbr
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
