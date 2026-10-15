# dsm-selective-dpi-proxy

A small, hardened HTTP proxy stack for a Synology NAS (tested design target: DS720+, DSM 7.2,
Portainer CE). It lets DSM clients reach a short, explicit list of websites that the ISP blocks with
SNI-based filtering, while all other traffic passes through unmodified.

```
DSM client ──HTTP proxy──▶ tinyproxy ──SOCKS5──▶ ByeDPI ──▶ internet (your normal ISP line)
 (127.0.0.1:8888)          edge + socks nets      socks (internal) + egress nets
```

* **Tinyproxy** is the HTTP/HTTPS (CONNECT) proxy that DSM talks to. It enforces client and
  destination restrictions and forwards every request to ByeDPI.
* **ByeDPI** (`ciadpi`) is a SOCKS5 proxy that, **only for the hostnames in `SPLIT_HOSTS`**, splits the
  TLS ClientHello into two TLS records inside the SNI field (`--tlsrec`), so SNI-based filters cannot
  read the hostname. Every other connection is relayed byte-for-byte.
* Traffic never leaves through another network or VPN: it still uses the NAS's own internet line.
  End-to-end TLS is untouched: the proxy cannot see or alter encrypted content, and certificate
  validation happens in the client as usual.

> This stack does **not** change any DSM setting by itself. Pointing DSM at the proxy is a manual,
> separate step (see [Stage 4](#stage-4--enable-the-dsm-system-proxy-manual-approval-gate)).

---

## Repository layout

```
.
├── docker-compose.yml        # the stack (Portainer reads this)
├── .env.example              # every setting, documented
├── .gitignore
├── byedpi/
│   ├── Dockerfile            # builds ciadpi from a pinned upstream commit
│   └── healthcheck.sh        # SOCKS5 handshake probe
├── tinyproxy/
│   ├── Dockerfile            # tinyproxy from Alpine's signed packages
│   ├── entrypoint.sh         # renders tinyproxy.conf from env vars, fails closed
│   └── filter.default        # destination deny rules
└── scripts/
    └── validate.sh           # read-only test script to run on the NAS
```

---

## Security design

| Concern | Control |
|---|---|
| Who can use the proxy | Port published on `127.0.0.1` only (default `BIND_ADDRESS`), so only processes on the NAS itself can connect; nothing on the LAN, the tailnet or the internet can. Tinyproxy additionally allows only `PROXY_ALLOW` (default: the `edge` network subnet, from which Docker relays loopback clients). Any other source gets `403 Access denied`. |
| SOCKS exposure | ByeDPI has **no published port**. Its SOCKS port is reachable only on the `socks` network, which is `internal: true` and shared with tinyproxy alone. |
| Destination restrictions | HTTPS `CONNECT` only to ports in `CONNECT_PORTS` (default `443`). Plain HTTP only to the default port 80. Literal loopback / RFC 1918 / link-local / CGNAT-Tailscale / IPv6 ULA and link-local targets and `.local`, `.internal`, `.lan`, `.home`, `.arpa`, `.ts.net` names are refused (`tinyproxy/filter.default`). |
| Which traffic is altered | Only TLS ClientHellos whose SNI matches `SPLIT_HOSTS` (label-boundary suffix match). ByeDPI is started with `--hosts=:<list> --proto=tls --tlsrec=<pos> --auto=none`: the options apply to the listed hosts only, and the trailing empty group relays everything else unmodified. |
| TLS integrity | The proxy never terminates TLS. Clients validate certificates end to end; nothing in this stack disables verification. |
| Container hardening | Read-only root filesystems, `cap_drop: [ALL]`, `no-new-privileges`, non-root user `65534`, no privileged mode, memory limits and a relative CPU weight, `restart: unless-stopped`, rotated `json-file` logs. |
| Supply chain | Both images build `FROM alpine:3.20@sha256:d9e853e8…` (digest-pinned). Tinyproxy comes from Alpine's signed package repo. ByeDPI is compiled from source at upstream commit `7efde1b1…` (tag `v0.17.3`); the build aborts if the checked-out tree does not hash to that commit. `pull_policy: build` prevents Docker from pulling look-alike images from a registry. |
| Secrets | None. No credentials, keys or machine-specific addresses are stored in the repository; per-host values live in Portainer stack variables. |

### Why ByeDPI is built from source

The ByeDPI project publishes no checksum files or signatures, and its release tags are not signed.
GitHub's asset digest only proves that the bytes match what GitHub stores; it is not an independent
statement from the author. Building from a pinned git commit makes the input content-addressed and
auditable (the source is a small MIT-licensed C codebase), which is the strongest verification
available for this project.

### Residual risks (accepted, documented)

* **Names that resolve to private addresses.** The filter blocks literal internal targets, but a
  public hostname whose DNS answer is a private IP would be relayed. This needs a host firewall to
  stop, which this stack intentionally does not touch. Because the proxy is reachable only from the
  NAS itself, this gives no process access it does not already have.
* **DSM-wide scope.** DSM's system proxy is used by several DSM services (e.g. Package Center,
  updates), not just Download Station. Those requests pass through unmodified (only `SPLIT_HOSTS` are
  altered) and leave over the same line, but they now depend on this stack being up. Keep
  "Bypass proxy server for local addresses" enabled.
* **Splitting can break some servers.** Servers or middleboxes that cannot reassemble a split
  ClientHello will fail for listed hosts. In testing, `nyaa.si` returned a self-signed certificate
  when split, so it must **not** be listed. Only add hosts you have confirmed are blocked.

---

## Requirements

* Synology NAS with Container Manager (Docker) and **Portainer CE running on the same NAS**.
* The NAS must be able to reach `github.com` and Alpine's package mirrors at deploy time (images are
  built locally).
* An `EDGE_SUBNET` that does not collide with existing Docker or LAN networks.

---

## Deploy with Portainer (Git repository)

1. Portainer → **Stacks** → **Add stack** → **Repository**.
2. **Repository URL**: this repository's HTTPS URL. **Reference**: `refs/heads/main` (or a tag).
   **Compose path**: `docker-compose.yml`.
3. **Environment variables**: add at least `SPLIT_HOSTS` (e.g. `rarbg.to`). Review the defaults in
   `.env.example`; change `EDGE_SUBNET` **and** `PROXY_ALLOW` together if `172.30.88.0/29` collides.
4. Deploy. The first deploy builds both images (about 1–3 minutes on a DS720+).
5. Check that both containers are **healthy** (Portainer → Containers).

Do **not** enable Portainer's "relative path volumes" or add bind mounts: the stack needs none.
All configuration is passed as environment variables and rendered inside the container.

### Configuration reference

| Variable | Default | Purpose |
|---|---|---|
| `SPLIT_HOSTS` | *(required)* | Space-separated hostnames to split. |
| `TLSREC_POS` | `1+s` | `--tlsrec` position: offset `1` relative to the SNI (`+s`). |
| `BIND_ADDRESS` | `127.0.0.1` | Host address the proxy port is published on. Keep loopback. |
| `PROXY_PORT` | `8888` | Host port of the proxy. |
| `EDGE_SUBNET` | `172.30.88.0/29` | Subnet of the `edge` network. |
| `PROXY_ALLOW` | `172.30.88.0/29` | Allowed client addresses/CIDRs (comma-separated). |
| `CONNECT_PORTS` | `443` | Allowed CONNECT destination ports. |
| `EXTRA_DENY_PATTERNS` | *(empty)* | Extra tinyproxy deny regexes, `;`-separated. |
| `LOG_LEVEL` | `Connect` | Tinyproxy log level (`Connect` logs every request and client). |
| `MAX_CLIENTS`, `PROXY_TIMEOUT`, `BYEDPI_MAX_CONN` | `32`, `120`, `256` | Resource limits. |
| `BYEDPI_COMMIT` | `7efde1b…` | Upstream commit to build. Change only together with a source review. |

---

## Validation plan (staged)

Run the stages in order and keep the output. Stages 1–3 change nothing on the NAS outside the stack.

### Stage 1 — stack health
* Both containers `healthy`; `docker logs <stack>-tinyproxy-1` shows the rendered settings line.
* `sudo ss -ltnp | grep 8888` on the NAS shows the port bound to `127.0.0.1` only.
* No port 1080 is listening on the host.

### Stage 2 — proxy behaviour from the NAS shell
```
sh scripts/validate.sh            # or: PROXY_URL=http://127.0.0.1:8888 sh scripts/validate.sh
```
Expected:
* **Baseline (direct)** is run over IPv4 and IPv6 separately. A host that fails over **IPv4** is a
  candidate for `SPLIT_HOSTS` (SNI filtering). A host that fails **only over IPv6** has an IPv6
  routing problem instead; do not list it. The proxy path is IPv4-only, so it works through the
  proxy anyway.
* **Through the proxy**: listed hosts `OK` with `verify=0` (valid certificate); unlisted hosts `OK`
  exactly as in the baseline.
* **Refusals**: every line in section 4 is `DENIED`.
* Tinyproxy log: client address is inside `PROXY_ALLOW`. On some Docker setups loopback clients
  appear as `127.0.0.1` or another gateway address; if requests are refused with
  `Unauthorized connection from "<addr>"`, add exactly that address to `PROXY_ALLOW`.

Result codes: `OK` = 2xx/3xx with valid certificate · `CF` = Cloudflare challenge (site reachable,
blocks automated clients; not fixable here) · `DENIED` = refused by the proxy · `HTTP-4xx` = the
site answered with an error · `CONN-FAIL` = no response · `TLS-FAIL` = certificate invalid.

### Stage 3 — confirm only listed hosts are altered (optional, diagnostic)
Temporarily add `--debug=2` to the ByeDPI command (Portainer editor), redeploy, run Stage 2, and check
`docker logs <stack>-byedpi-1`: listed hosts show `desync TCP: group=0` followed by `tlsrec: pos=…`;
unlisted hosts show `group=1` with no `tlsrec`. `resolve: <hostname>` lines confirm the hostname is
passed through SOCKS (ByeDPI resolves it, tinyproxy does not). Remove `--debug` afterwards.

### Stage 4 — enable the DSM system proxy (manual approval gate)
Only after Stages 1–2 pass:
DSM → **Control Panel → Network → General → Advanced settings / Proxy** → enable
**Connect via a proxy server**: address `127.0.0.1`, port `8888` (or your `PROXY_PORT`),
tick **Bypass proxy server for local addresses**. No authentication.

### Stage 5 — does Download Station's search actually use the system proxy?
Do not assume it does. With `docker logs -f <stack>-tinyproxy-1` running:
1. In Download Station → BT Search, run a search (searching does not download anything).
2. **Uses the proxy** if tinyproxy logs `CONNECT <search-site>:443` lines from an allowed client at the
   time of the search, and modules for listed hosts now return results.
3. **Does not use the proxy** if no such lines appear while the search runs. Confirm on the NAS with
   `sudo ss -tnp | grep ':443'` during a search: direct connections from Download Station processes
   to the search sites mean the system proxy is bypassed. In that case, stop and revert Stage 4; a
   different design is needed (for example, a per-application proxy setting), and this stack alone
   does not solve the problem.

### Stage 6 — torrent data stays off the proxy
Without starting any download:
* Tinyproxy's log must show only HTTP(S) requests (search pages, possibly HTTP tracker announces);
  BitTorrent peer connections are not HTTP and cannot use an HTTP proxy.
* If you later decide to test with a download, check `sudo ss -tnp` for Download Station's peer
  connections (to many remote IPs on high ports, not to `127.0.0.1:8888`) and that tinyproxy logs no
  peer addresses. HTTP(S) **tracker announces** may go through the proxy when the system proxy is on;
  they are relayed unmodified unless a tracker host is in `SPLIT_HOSTS`.

---

## Optional: LAN mode (let other devices on the home network use the proxy)

By default the proxy is reachable only from the NAS itself. To let other devices on the same LAN
use it:

1. In the Portainer stack variables set:
   * `BIND_ADDRESS` = the NAS's **LAN** IPv4 address (a static/DHCP-reserved address), e.g. `192.168.1.10`
   * `PROXY_ALLOW` = `172.30.88.0/29,<your LAN subnet>` (e.g. `172.30.88.0/29,192.168.1.0/24`)

   Then **Update the stack**.
2. Point DSM's system proxy at the same LAN address (the loopback binding is replaced).
3. On each device that should use it, set an HTTP proxy of `<NAS LAN IP>:8888`
   (Windows: Settings → Network → Proxy; macOS: Network → Details → Proxies; Android/iOS: Wi-Fi
   network → Proxy → Manual).

Notes:
* Never use `0.0.0.0`: that would also publish the proxy on VPN/Tailscale and every other interface.
* Binding to the LAN address does not expose it to the internet unless your router forwards the
  port. Do not add a port forward for it.
* Tailscale: the proxy is not reachable from the tailnet unless the NAS advertises the LAN subnet
  route. If it does, add a deny or keep `PROXY_ALLOW` limited to the LAN subnet.
* Devices behind the proxy still validate TLS certificates themselves; only connections to
  `SPLIT_HOSTS` are altered.

---

## Optional: PAC (automatic proxy configuration) for LAN devices

Instead of toggling a manual proxy on every device, the stack can serve a **PAC file** so each device
sends **only the blocked hosts** through the proxy and everything else stays DIRECT. This is the
recommended way to cover a whole LAN selectively.

1. The `pac` service is included in the stack and serves `http://<BIND_ADDRESS>:<PAC_PORT>/proxy.pac`
   (`PAC_PORT` default `8080`). Like the proxy port it binds to `BIND_ADDRESS`, so it is loopback-only
   until you switch to LAN mode (set `BIND_ADDRESS` to the NAS LAN IP, as above).
2. `PAC_HOSTS` defaults to `SPLIT_HOSTS`, so the auto-config routes exactly the hosts ByeDPI splits.
   `PAC_PROXY` defaults to `BIND_ADDRESS:PROXY_PORT`; override either if the proxy clients should
   reach it at a different address.
3. On each device (or router/DHCP option 252 for the whole LAN) set **Automatic proxy configuration /
   PAC URL** to `http://<NAS LAN IP>:8080/proxy.pac`. Windows: Settings → Network → Proxy → *Use setup
   script*. macOS: Network → Proxies → *Automatic Proxy Configuration*. Android/iOS: Wi-Fi → Proxy →
   *Auto*.

The PAC returns `PROXY <PAC_PROXY>` for a host that equals or is a sub-domain of a `PAC_HOSTS` entry,
and `DIRECT` for everything else. It is a plain static file; it holds no credentials and alters no
traffic itself.

> The PAC and the proxy only carry **TCP/TLS** (HTTP `CONNECT`). Protocols a browser proxy never sees
> — notably Discord **voice** (UDP/WebRTC) — are unaffected; use a VPN for those. Text, login and web
> for `SPLIT_HOSTS` work over the proxy.

---

## Troubleshooting

| Symptom | Check |
|---|---|
| `403 Access denied` / `Unauthorized connection from "<addr>"` in logs | Client address not in `PROXY_ALLOW`; add the logged address. |
| `CONNECT tunnel failed, response 403`, log `Refused CONNECT method on port N` | Port not in `CONNECT_PORTS`. |
| `Proxying refused on filtered url` | Destination matches `filter.default` or `EXTRA_DENY_PATTERNS`. |
| Many hosts fail directly but work through the proxy without being listed | Check the `direct6` lines: if IPv6 fails for every host, the NAS has an IPv6 default route without working IPv6 connectivity. Fix IPv6 on the router/DSM, or rely on the IPv4-only proxy path. |
| Listed host still `CONN-FAIL` through the proxy | Try another `TLSREC_POS` (e.g. `3+s`), redeploy, re-test. The ISP may use a different technique for that host. |
| A listed host returns a self-signed certificate (`TLS-FAIL`) | Its server cannot handle a split ClientHello. Remove it from `SPLIT_HOSTS`. |
| `NanoCPUs can not be set ... CPU CFS scheduler` or a `PidsLimit` error | The kernel lacks CFS quota / the pids cgroup (Synology DSM 7, kernel 4.4). The stack therefore uses only `mem_limit` and `cpu_shares`; do not add `cpus:` or `pids_limit:`. |
| tinyproxy restarts with `can't create directory '/run/tinyproxy'` or `not writable` | The tmpfs must be owned by uid 65534. Keep the `uid=65534,gid=65534` tmpfs options; Synology's Docker ignores `mode=`. |
| Stack fails to deploy: subnet overlap | Change `EDGE_SUBNET` and `PROXY_ALLOW` together. |
| Build fails at `git fetch` | The NAS cannot reach GitHub, or `BYEDPI_COMMIT` is wrong. |
| tinyproxy stays `starting` | ByeDPI is unhealthy; check `docker logs <stack>-byedpi-1`. |

---

## Updates

* **Hosts or settings**: edit the stack variables in Portainer → **Update the stack**.
* **Repository changes**: Portainer → stack → **Pull and redeploy** (enable "Re-pull image and
  redeploy" is not needed; images are built locally).
* **New ByeDPI version**: review the upstream diff, set `BYEDPI_COMMIT` to the new commit, redeploy,
  then repeat Stages 1–3.
* **Base image**: update the `alpine:3.20@sha256:…` digest in both Dockerfiles deliberately (look up
  the current index digest of the tag), commit, redeploy.

---

## Rollback

1. If Stage 4 was done: DSM → Control Panel → Network → proxy → **disable** "Connect via a proxy
   server". DSM is immediately back to direct connections.
2. Portainer → Stacks → this stack → **Delete** (removes containers and networks).
3. Remove the locally built images: Portainer → Images, or
   `docker image rm dsm-selective-dpi-proxy/byedpi:<commit> dsm-selective-dpi-proxy/tinyproxy:1.11.2-alpine3.20`.

Nothing else on the NAS is modified by this stack (no host files, firewall rules or DSM settings).

---

## Limitations that can only be verified on the NAS

* Whether Download Station's BT search modules honour the DSM system proxy (Stage 5).
* The exact client address Synology's Docker uses for loopback-published ports (Stage 2 log check).
* Whether Portainer on the NAS builds images from a Git stack in your Portainer version.
* Whether the ISP's filtering of a given host is defeated by `--tlsrec` from the NAS's line.

## Licence and credits

* ByeDPI © hufrea and contributors, MIT licence: <https://github.com/hufrea/byedpi>.
* Tinyproxy, GPL-2.0, packaged by Alpine Linux.
