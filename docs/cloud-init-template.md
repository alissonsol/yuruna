# Cloud-init template pipeline

Three host platforms (Hyper-V, KVM, UTM) each install Ubuntu Server
or Amazon Linux 2023 into a freshly-created VM via cloud-init's
NoCloud datasource. Each guest type has its own base + per-host
overlay set; the `ubuntu.server.*` and `amazon.linux.2023.*` files
are described below. The seed ISO they generate contains a
`user-data` file rendered from a shared base + a per-host overlay +
a per-cycle replacement table. The rendering pipeline lives in
[`automation/Yuruna.CloudInitTemplate.psm1`](../automation/Yuruna.CloudInitTemplate.psm1).

Before the pipeline landed, each of the six `New-VM.ps1` scripts
(3 platforms × {Ubuntu Server 24, Ubuntu Server 26}) carried its own
near-identical `vmconfig/user-data` file (~240 lines each) plus a
600-character `.Replace(...).Replace(...)...` chain across 11
placeholders plus a 3-line base64 dance for the two guest-side helper
scripts. Whenever a fix landed in one copy, the other five drifted — captured
as the "three parallel user-data copies" trap class in the workspace's
contributor memory.

## Three-stage rendering

| Stage | Function | Inputs | Output |
|---|---|---|---|
| 1. **Merge** | `Merge-CloudInitUserData` | shared base + per-host overlay (one of `hyperv` / `kvm` / `utm`) | Resolved template with anchors substituted, still carrying `*_PLACEHOLDER` tokens |
| 2. **Base64-encode** | `Get-YurunaGuestScriptBase64` | `<RepoRoot>/automation/{yuruna-retry.sh,yuruna-versions.sh,fetch-and-execute.sh,yuruna-network.sh}` | `@{ RetryLib = '<base64>'; VersionsLib = '<base64>'; FetchAndExecute = '<base64>'; NetworkLib = '<base64>' }` |
| 3. **Resolve** | `Resolve-CloudInitPlaceholder` | Merged template + replacement hashtable | Final user-data string |

`Build-CloudInitUserData` is the high-level wrapper every per-guest
`New-VM.ps1` calls — it chains the three stages, auto-populates the
`YURUNA_*_BASE64_PLACEHOLDER` entries from the guest scripts, and
optionally writes the result to `-OutputPath` (UTF-8 without BOM, LF
line endings — the cloud-init contract).

## Files on disk

| File | Role |
|---|---|
| `host/vmconfig/ubuntu.server.base.user-data` | The shared base — same for Ubuntu Server 24 and 26. Contains anchor lines like `# === YURUNA_OVERLAY_NETWORK ===` that the merger replaces. |
| `host/vmconfig/ubuntu.server.hyperv.overlay.yml` | Per-host overlay: `hv_balloon` denylist + `hyperv_fb` framebuffer pin. |
| `host/vmconfig/ubuntu.server.kvm.overlay.yml` | Per-host overlay: VT-blanking early-command + `consoleblank=0` + fb-safe GRUB cmdline. |
| `host/vmconfig/ubuntu.server.utm.overlay.yml` | Per-host overlay: `network:` block pinning IPv4 DHCP and refusing IPv6 RA. |
| `host/vmconfig/amazon.linux.2023.base.user-data` | The shared AL2023 base. Uses cloud-init `runcmd:` (the AL2023 cloud image boots from a prebuilt image rather than running an Ubuntu-style autoinstall), with its own anchor set. |
| `host/vmconfig/amazon.linux.2023.hyperv.overlay.yml` | Per-host AL2023 overlay (Hyper-V). |
| `host/vmconfig/amazon.linux.2023.kvm.overlay.yml` | Per-host AL2023 overlay (KVM): `consoleblank=0` runcmd. |
| `host/vmconfig/amazon.linux.2023.utm.overlay.yml` | Per-host AL2023 overlay (UTM). |
| `automation/yuruna-retry.sh`, `automation/yuruna-versions.sh`, `automation/fetch-and-execute.sh`, `automation/yuruna-network.sh` | Guest-side helper scripts baked into the seed as base64 `write_files` entries. `yuruna-versions.sh` holds the pinned dependency versions and is sourced by `yuruna-retry.sh`. |

## Anchor contract

Each anchor line in the base looks like
`# === YURUNA_OVERLAY_<NAME> ===`. The anchor set differs by guest
type because Ubuntu Server runs an autoinstall while AL2023 boots a
prebuilt cloud image and configures itself via `runcmd:`.

**Ubuntu Server** — four anchors:

| Anchor | Purpose | Used by overlays |
|---|---|---|
| `NETWORK` | Per-host network: block | UTM only (Hyper-V/KVM use cloud-init defaults) |
| `EARLY_COMMANDS` | Pre-install commands | KVM only (disable VT blanking) |
| `GRUB_PRE_CONSOLE_QUIET` | Kernel quirks before `console-quiet` block | Hyper-V (`hv_balloon`+`hyperv_fb`), KVM (`consoleblank`) |
| `GRUB_POST_CONSOLE_QUIET` | Kernel quirks after `console-quiet` block | KVM only (`nomodeset` fb-safe) |

**Amazon Linux 2023** — three anchors:

| Anchor | Purpose | Used by overlays |
|---|---|---|
| `RUNCMD_CONSOLEBLANK` | `runcmd:` block pinning `consoleblank=0` | KVM only |
| `RUNCMD_QUIET_LOGLEVEL` | `runcmd:` block for quiet/loglevel kernel-cmdline quirks | per-host as needed |
| `POWER_STATE` | `power_state:` directive (reboot/poweroff after first boot) | per-host as needed |

The overlay file uses the same line format as section headers; the
lines between one header and the next (or end of file) are the
substitution payload. An empty payload deletes the anchor line
outright.

Anchors not represented in the overlay are a hard error — a silent
miss would let a removed anchor leak the literal marker into the
final user-data and confuse cloud-init.

## Placeholder safety net

`Resolve-CloudInitPlaceholder` iterates the caller's hashtable and
applies `.Replace(name, value)` for each entry. After substitution it
scans the result for any remaining `<NAME>_PLACEHOLDER` token; if any
are found, it throws with the offending names.

This catches typos at New-VM time — a forgotten entry in the
caller's hashtable or a new placeholder added to the base that no
caller is supplying a value for — instead of letting a literal
placeholder string ship to the guest where it would fail mid-
autoinstall with a confusing diagnostic.

| Placeholder | Source |
|---|---|
| `HOSTNAME_PLACEHOLDER` | `-VMName` (caller) |
| `USERNAME_PLACEHOLDER` | `-Username` (caller) |
| `HASH_PLACEHOLDER` | `-PasswordHash` (caller — passlib-format SHA-512 crypt) |
| `PLAINTEXT_PASSWORD_PLACEHOLDER` | `-Password` (caller — AL2023 path only; feeds the `chpasswd.list` directive) |
| `SSH_AUTHORIZED_KEY_PLACEHOLDER` | `Get-YurunaSshPublicKey` |
| `APT_PROXY_BLOCK_PLACEHOLDER` | Caching-proxy YAML block (or empty) |
| `CACHING_PROXY_URL_PLACEHOLDER` | Detected caching-proxy URL (or empty) |
| `CA_CERT_BASE64_PLACEHOLDER` | Caching-proxy CA cert (or empty) |
| `YURUNA_HOST_IP_PLACEHOLDER` / `YURUNA_HOST_PORT_PLACEHOLDER` | Host coordinates the guest writes to `/etc/yuruna/host.env` |
| `YURUNA_RETRY_LIB_BASE64_PLACEHOLDER` / `YURUNA_VERSIONS_BASE64_PLACEHOLDER` / `YURUNA_FAE_BASE64_PLACEHOLDER` / `YURUNA_NETWORK_BASE64_PLACEHOLDER` | Auto-populated from `Get-YurunaGuestScriptBase64` |

## Adding a new placeholder

1. Add the literal `<NAME>_PLACEHOLDER` token to
   `host/vmconfig/ubuntu.server.base.user-data` at the appropriate
   spot.
2. Add the matching entry to every `New-VM.ps1` caller's
   `-Replacement` hashtable. The safety net catches any caller that
   forgot.
3. If the value derives from the repo (a new bundled helper
   script), add it to `Get-YurunaGuestScriptBase64` and let
   `Build-CloudInitUserData` auto-populate.

## Adding a new platform overlay

1. Create `host/vmconfig/ubuntu.server.<platform>.overlay.yml` with
   the four anchor headers (empty payloads for anchors the platform
   doesn't use).
2. Add a `New-VM.ps1` under `host/<platform>/guest.ubuntu.server.{24,26}/`
   that calls `Build-CloudInitUserData` with the new overlay path.
3. The merger validates anchor coverage at merge time — a missing
   anchor in the overlay raises.

## Output encoding

`Build-CloudInitUserData -OutputPath <file>` writes UTF-8 without a
BOM and LF line endings. cloud-init >= 22 tolerates `\r\n` but older
guests trip on CR-sensitive shell heredocs in the rendered
`late-commands` block, so the LF-only output is the durable choice.

## Related

- [Test harness](test-harness.md) — overall architecture.
- [Network](network.md) — caching proxy + `YURUNA_HOST_IP` injection.
- [VM config](vmconfig.md) — per-anchor URLs (`#hv_balloon-denylist`, `#hyperv_fb-framebuffer-pin`, `#pin-ipv4-dhcp-refuse-ipv6-ra`, ...) the comment-anchor URLs in the base file reach.

---

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.07.10

Back to [Yuruna](../README.md)
