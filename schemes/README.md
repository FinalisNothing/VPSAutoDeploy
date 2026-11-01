# Proxy schemes

A scheme is one complete way of running the proxy on the VPS: which ports it
takes, which components it installs, the xray (and nginx, …) configuration,
the guide that walks the user through what it needs, the health checks and the
client links. `phase2-deploy.sh` is the engine that runs a scheme; it knows
nothing about any particular one.

The user's whole mental model is the short description a scheme shows when it
is chosen (`phase2-deploy.sh --list`). Everything else — inputs, preparation,
order of steps — comes from the scheme, because only the scheme knows what it
needs: a REALITY-only scheme asks for no domain at all, a CDN scheme needs DNS
and an origin certificate before anything can be deployed.

## Layout

```
schemes/<id>/
├── scheme.sh      metadata, inputs, guide, steps, checks, links (sourced by the engine)
├── xray.json      xray config template
└── …              any other templates the steps render (nginx.conf, …)
```

`<id>` is lowercase letters, digits and dashes. Private schemes can live outside
the repository: `VPSAD_SCHEME_PATH=/root/my-schemes` (colon-separated) adds
directories to the search.

## Contract

`scheme.sh` only defines variables and functions; sourcing it has no side
effects.

| Name | Required | Meaning |
|---|---|---|
| `SCHEME_TITLE` | yes | One line. |
| `SCHEME_SUMMARY` | yes | Array of lines the user reads when choosing: client entries, egress policy, **what the user must prepare**. |
| `SCHEME_PORTS` | yes | Public ports as `tcp/443`, `udp/443`. Opened by `fw_open`; they must be free or held by the scheme's own components. |
| `SCHEME_COMPONENTS` | yes | Components the scheme runs (`nginx`, `xray`). On deactivation the engine calls `<component>_release` for each, and their processes may hold `SCHEME_PORTS`. |
| `SCHEME_PROVIDES` | no | Interfaces other local services rely on (a local proxy port, …). Switching to a scheme that lacks one warns the user. |
| `SCHEME_XRAY_VERSION` | if xray is used | The Xray-core release the templates were verified against. Installed by default; `--xray-version` overrides. |
| `scheme_inputs()` | yes | Declares every value with `input` (below). |
| `scheme_guide()` | yes | Interactive part: explain what to prepare, `ask` for inputs, check the preparation. Must also run unattended when every value comes from the conf file. |
| `scheme_deploy()` | yes | Non-interactive part: a sequence of `step` calls. |
| `scheme_verify()` | yes | Observes the running system with `check_ok` / `check_warn` / `check_fail`. Used after deployment and by `--status`. |
| `scheme_links()` | no | Prints client share links (`vless_link`). |
| `scheme_values ARRAY` | no | Fills the values templates are rendered with when they need more than the inputs (constants, derived paths). |
| `scheme_deactivate()` | no | Cleanup beyond what the engine already does (firewall rules, component release). |

### Inputs

```bash
input NAME KIND "prompt" [--default V] [--advanced] [--secret] [--optional] [--help TEXT]
```

- *plain*: asked when missing; `--default` makes Enter accept the default.
- `--advanced`: never asked; the conf file or the default decides.
- `--secret`: never asked; empty means "generated during deployment" with
  `ensure_secret NAME GENERATOR…`, a value from the conf file is imported as is
  (that is how existing clients survive a move to a new VPS).
- `--optional`: may stay empty.

Kinds (`lib/common.sh`, `valid_value`) are strict on purpose — a valid value
can never break out of the JSON string, nginx directive or URL it is rendered
into: `email domain port path word uuid key32 wgkey vlessdec cidr4 cidr6
hostport shortids bytes3`. Add a kind there rather than accepting free text.

Values come from the uploaded `vpsautodeploy.conf`, then from the values an
earlier run stored in `/etc/vpsautodeploy/schemes/<id>/params`, then from the
guide's prompts.

### Templates

- `{{NAME}}` is replaced by the value's text; `"{{NAME:json}}"` (quotes
  included) by the value as raw JSON (arrays, numbers).
- `render_template` refuses a missing value, a leftover placeholder, and JSON
  output that does not parse.
- A value used by two templates (a socket path shared by nginx and xray) is
  defined once — an input or a constant passed through `scheme_values` — never
  written twice.

## Rules

1. **Secrets never enter the repository.** Keys, UUIDs and registrations are
   `--secret` inputs, generated on the VPS or imported from the conf file.
2. **Steps are idempotent** and check the machine before acting; a re-run
   converges. Never keep "done" markers instead of looking.
3. **Shared services stay up.** Activate configs only through the component
   functions (`nginx_apply_config`, `xray_apply_config`): they test the new
   config, back up the old one, swap, and roll back if the service does not
   come up.
4. **Touch only what the scheme owns.** Ports through `fw_open` (tagged with the
   scheme's id, removed on deactivation). An nginx config must
   `include /nginx/conf/sites.d/*.conf;` — other local services keep their
   server blocks there across scheme switches. SSH, the firewall baseline and
   fail2ban's sshd jail belong to the machine.
5. **Verify by observation.** Listening sockets, real HTTP requests through the
   entry points, real egress — not exit codes.
6. **Write down coupled values** in the header of `scheme.sh`: values that only
   work together (a REALITY target and the certificate it serves, an encryption
   setting that excludes fallbacks, …).
7. **Pin `SCHEME_XRAY_VERSION`** to the version the templates were verified
   against; bump it only after verifying them again.
8. **Prove it in a container**: `tests/e2e/run.sh` deploys, checks every client
   link through a real xray client, switches schemes and back. A new scheme adds
   its own assertions there.

## Components

Defined in `components/<name>/component.sh` and available to every scheme:

| Function | Does |
|---|---|
| `fw_open SPEC…` | Allows `tcp/N` / `udp/N` (IPv4), tagged with the scheme. |
| `nginx_install`, `nginx_service` | Custom nginx build (sha256-verified) under `/nginx`, `nginx.service` with jemalloc. |
| `nginx_apply_config FILE` | Test, back up, swap, reload/start, roll back. |
| `acme_ensure DOMAIN EMAIL [KEYLEN]` | ZeroSSL certificate via acme.sh (HTTP-01 on nginx), skipped while one with 30+ days exists. |
| `cert_install_pair DOMAIN CERT KEY`, `cert_dir DOMAIN` | User-supplied certificates; `/etc/vpsautodeploy/certs/<domain>/`. |
| `cert_chain_bytes HOST:PORT SNI` | Size of the served chain (REALITY's ML-DSA-65 needs > 3500 bytes from its target). |
| `fail2ban_nginx`, `cloudflare_ips_update` | nginx jails; Cloudflare ranges for the nginx geo file and fail2ban's ignoreip. |
| `xray_install VERSION` | Release binary (sha256-verified), `xray` user and unit, logrotate, Loyalsoldier geodata. |
| `xray_apply_config FILE` | `xray run -test` as the unprivileged user, back up, swap, restart, roll back. |
| `xray_gen KIND`, `xray_derive KIND SECRET` | Keys from the installed binary; client halves (REALITY password, ML-DSA-65 verify, ML-KEM client key). |
| `warp_register ARRAY` | Registers a Cloudflare WARP device. |
| `vless_link UUID HOST PORT NAME KEY=VALUE…` | Share link per XTLS/Xray-core discussion #716. |

Engine helpers: `input`, `ask`, `ask_file`, `param`, `set_param`,
`ensure_secret`, `step`, `check_*`, `check_listening`, `check_unix_socket`,
`check_service`; guide helpers in `lib/guide.sh`: `guide_text`,
`guide_check_points_here`, `guide_check_behind_cloudflare`,
`guide_check_https`, `guide_check_ipv6_egress`, `guide_problem`.

## Adding a scheme

1. Design it; write down every coupled value in the header of `scheme.sh`.
2. Write the templates; give every secret, domain and path an input.
3. Write the guide in the order the user has to act: what to prepare outside
   the VPS, then the inputs that depend on it, each followed by a check.
4. Steps through components only; `scheme_verify` covers every entry point.
5. `tests/e2e/run.sh` passes, with assertions for the new scheme.
