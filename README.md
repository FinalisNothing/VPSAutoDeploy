# VPSAutoDeploy

Automated VPS deployment for Debian 13: a hardened base system, then a
**proxy scheme** of your choice running on bare Xray-core. A scheme is one
complete way of running the proxy (inputs, guide,
deployment, checks, client links); switching to another scheme later is one
command and leaves the rest of the machine alone.

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

### Phase 2: Proxy scheme (`phase2-deploy.sh`)

Run **after the phase1 kernel reboot** (log in as your user, `sudo -i`,
`cd VPSAutoDeploy`). Identity and login are already owned by the earlier
phases, so phase2 **never asks for usernames, passwords, or SSH ports** — a
read-only preflight detects the phase0 user (`SUDO_USER`) and the SSH port
(`sshd -T`), and verifies the earlier phases' contracts (key-only sshd, BBR
active) before touching anything.

What phase2 deploys is a **scheme** (`schemes/<id>/`): one complete way of
running the proxy — which ports it takes, the xray and nginx configuration, the
inputs it needs, the guide that walks you through them, the health checks and
the client links. You **choose the scheme first**; its guide then tells you what
to prepare and asks only for what that scheme needs, checking each preparation
(DNS, Cloudflare, …) as you go. `schemes/README.md` describes what a scheme is
and how to add one.

```bash
bash phase2-deploy.sh --list     # every scheme: entries, egress, what it needs
bash phase2-deploy.sh            # choose, follow the guide, deploy, verify, print client links
```

A run, in order:

1. **Preflight** — detected user and SSH port, earlier phases' contracts.
2. **Scheme** — `--scheme ID`, or `SCHEME=` from the conf file, or the active one on a re-run, or a menu.
3. **Guide** — the scheme's preparation notes, inputs and checks.
4. **Base**, independent of any scheme — UFW (incoming denied, SSH allowed), fail2ban (sshd + recidive).
5. **The scheme's steps** — each checks the machine before acting, so a failed run is continued by the next one.
6. **Verify** — observed health: listening sockets, real requests through every entry, real egress.
7. **Client share links** (also kept in `/etc/vpsautodeploy/schemes/<id>/links.txt`).

**Zero-touch:** write the conf file (anywhere — it is a plain template),
upload it with the files the scheme asks for, then run with `--yes`:

```bash
bash phase2-deploy.sh --generate-config <scheme> vpsautodeploy.conf
# fill it in, then:
scp -P <port> vpsautodeploy.conf <files the scheme asks for> <user>@<VPS_IP>:~/
bash phase2-deploy.sh --yes      # --yes also accepts the guide's warnings
```

- The conf file is `KEY=VALUE`, read literally — never executed.
- Uploads are only taken from `/root` and the deploy user's home, must be owned
  by root or that user, and count as complete when their content validates (a
  half-uploaded certificate does not parse). They are moved into
  `/etc/vpsautodeploy/`, so no key stays in a home directory and re-runs use the
  stored copy.
- **Keys** (client UUIDs, REALITY keys, …) are generated on the VPS by xray
  itself. To keep existing clients working on a new VPS, put the old values into
  the conf file's secrets section; they are imported as they are.

Other commands:

```bash
bash phase2-deploy.sh --status       # observed health of everything; exit 1 if a check fails
bash phase2-deploy.sh --links        # client links of the active scheme
bash phase2-deploy.sh --update       # xray-core (the scheme's pinned version; --xray-version latest for the newest)
                                     # and geodata - tested against the active config before they replace anything
bash phase2-deploy.sh --deactivate   # remove what the active scheme owns
```

**Switching schemes** is a normal run with another scheme chosen. The old
scheme is deactivated first: its firewall rules (comment
`vpsautodeploy:<id>`) are deleted, xray stops, nginx keeps serving only
`/nginx/conf/sites.d/`. Nothing else is touched — SSH, the firewall baseline,
fail2ban, certificates, other services, and the old scheme's stored inputs, so
switching back brings back the same keys and the same client links.

### What runs on the VPS

| Component | Where | Notes |
|---|---|---|
| Xray-core | `/usr/local/bin/xray` → `/usr/local/lib/vpsautodeploy/xray/<version>/` | Official release, SHA2-256 from the release `.dgst`. Runs as user `xray` with only `CAP_NET_BIND_SERVICE`; config in `/usr/local/etc/xray/config.json`, logs in `/var/log/xray/` (logrotate daily, 7 kept). |
| Geodata | `/usr/local/share/xray/` | Loyalsoldier `geoip.dat` / `geosite.dat`, sha256-verified. |
| nginx | `/nginx` | Custom stealth build ([nginx-build](https://github.com/FinalisNothing/nginx-build)), SHA256SUMS-verified, jemalloc preloaded. Other local services add server blocks in `/nginx/conf/sites.d/`. |
| Certificates | `/etc/vpsautodeploy/certs/<domain>/` | ZeroSSL via acme.sh (renewed by its cron), or files you supply. |
| UFW, fail2ban | | Baseline belongs to the machine; scheme ports are tagged with the scheme. |

Every config is **tested before it replaces the running one** (`nginx -t`,
`xray run -test` as the unprivileged `xray` user), the previous one is backed
up to `/etc/vpsautodeploy/backup/`, and a service that does not come up with
the new config is rolled back.

### Fail2ban layout

Fail2ban config is deployed as `jail.d` drop-ins instead of one `jail.local`:

- `00-default.local` — shared defaults (UFW ban action, progressive bans)
- `01-ignoreip.local` — **generated** by `update-cloudflare-ips.sh` (localhost +
  your entries from `/etc/fail2ban/ignoreip.custom` + fetched Cloudflare ranges)
- `10-sshd.local` — rendered with the detected SSH port; `backend = systemd`
  (minimal Debian 13 has no rsyslog, sshd logs only to the journal)
- `30-recidive.local` — escalation for repeat offenders
- `20-nginx.local` — nginx jails, deployed by schemes that use nginx

`update-cloudflare-ips.sh` is the single source of truth for Cloudflare IPs:
it regenerates both the nginx geo file and the fail2ban ignoreip drop-in,
updates whichever target exists, and runs monthly via cron. Permanent custom
safe-list entries go in `/etc/fail2ban/ignoreip.custom` (one per line) and
survive every refresh.

## Repository Structure

```
VPSAutoDeploy/
├── phase0-reinstall.sh, harden-ssh.sh, phase1-kernel.sh   base system
├── phase2-deploy.sh                 the scheme engine's entry point
├── lib/
│   ├── common.sh                    messages, value kinds, KEY=VALUE files, templates, downloads
│   ├── engine.sh                    scheme loading, inputs, uploads, steps, switching
│   └── guide.sh                     checks a scheme's guide uses (DNS, Cloudflare, HTTPS, IPv6)
├── components/                      building blocks schemes use
│   ├── firewall/  fail2ban/  nginx/  certs/  xray/
├── schemes/
│   ├── README.md                    what a scheme is, the contract, how to add one
│   └── <id>/                        scheme.sh + templates (and a README)
└── tests/e2e/                       Debian 13 container test (deploy, clients, switching)
```

## External Dependencies

> Fetched at deploy time. Everything with a published checksum is verified;
> release assets and their checksum files come from the same pinned release tag.

| Dependency | Source | Our Handling | Change Risk |
|---|---|---|---|
| `reinstall.sh` | [bin456789/reinstall](https://github.com/bin456789/reinstall) | `--username/--password/--ssh-port` to bypass interaction (never `--ssh-key`) | Parameter format may change |
| BBR v3 `install.sh` | [byJoey/Actions-bbr-v3](https://github.com/byJoey/Actions-bbr-v3) | Menu action numbers derived from the downloaded script; qdisc applied through the installer | Menu order may change |
| Xray-core release | [XTLS/Xray-core](https://github.com/XTLS/Xray-core/releases) | Version pinned by the scheme; SHA2-256 from `.dgst`; new versions must pass `run -test` on the active config | Config keys get deprecated / removed |
| Geodata | [Loyalsoldier/v2ray-rules-dat](https://github.com/Loyalsoldier/v2ray-rules-dat) | `.sha256sum` verified; active config tested against new files first | Category names may change |
| nginx build | [FinalisNothing/nginx-build](https://github.com/FinalisNothing/nginx-build) | `SHA256SUMS.txt` verified; needs x86-64-v2 | — |
| acme.sh | [get.acme.sh](https://github.com/acmesh-official/acme.sh) | Downloaded, then run; ZeroSSL, HTTP-01 on nginx | Installer behaviour may change |
| Cloudflare IP lists | `cloudflare.com/ips-v4`, `ips-v6` | Sanity-checked (count, CIDR syntax) before use | — |

## Testing

`tests/e2e/run.sh` (needs docker and internet; no real VPS) deploys in a
Debian 13 systemd container with a local test CA standing in for DNS and ACME,
connects through **every client link** with a real xray client, re-runs to check
that nothing changes, switches to a test scheme and back (same links), and
deactivates.

## Verification Checklist

- [ ] phase0: reinstall successful, `ssh <username>@<VPS_IP> -p <port>` works, `sudo -i` reaches root
- [ ] harden-ssh: key login works, password login rejected, `sudo` asks the user's password, `su -` accepts the root password
- [ ] phase1: `uname -r` shows BBR v3 kernel
- [ ] phase1: `sysctl net.ipv4.tcp_congestion_control` shows `bbr`
- [ ] phase1: `sysctl net.core.default_qdisc` shows chosen algorithm (fq/fq_codel/fq_pie/cake)
- [ ] phase1: `lsmod | grep balloon` returns empty (after the reboot)
- [ ] phase2 preflight: detected user and SSH port match what phase0 set
- [ ] phase2: `bash phase2-deploy.sh --status` exits 0 (it checks listeners, real requests through every entry, egress, certificates, UFW, fail2ban)
- [ ] phase2: each client link connects from a real client
- [ ] UFW: `ufw status` shows IPv4 rules only: SSH plus the scheme's ports (comment `vpsautodeploy:<id>`)
- [ ] jemalloc: `grep libjemalloc /proc/$(pgrep -x nginx -o)/maps` shows loaded

## State on the VPS

| Path | Purpose | Safe to delete? |
|---|---|---|
| `/etc/vpsautodeploy/engine.state` | Active scheme and whether its deployment finished | No |
| `/etc/vpsautodeploy/schemes/<id>/params` | The scheme's inputs **and keys** (mode 600) — back it up privately to move clients to a new VPS | No |
| `/etc/vpsautodeploy/schemes/<id>/files/` | Uploaded files (e.g. origin certificate) | No |
| `/etc/vpsautodeploy/schemes/<id>/links.txt` | Client links | Yes (`--links` recreates it) |
| `/etc/vpsautodeploy/certs/` | TLS certificates | No |
| `/etc/vpsautodeploy/backup/` | Configs replaced by later runs | Yes, once you are confident |
