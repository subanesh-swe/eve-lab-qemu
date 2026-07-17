# eve-lab-qemu

Run **[EVE-NG Community Edition](https://www.eve-ng.net/)** inside a
QEMU/KVM VM on any Linux host that exposes `/dev/kvm`. Useful when you
can't install EVE-NG directly on the host — e.g. NixOS, containerised
dev environments, restricted machines where you'd rather not touch the
host OS.

Two files:

- `eve-lab.sh` — one bash script with subcommands
  (`setup`, `install`, `run`, `check`, `help`).
- `flake.nix` — packages the script and declares sandbox-safe tests.

## Prerequisites

On the host that will run the VM:

- `/dev/kvm` readable/writable by your user
  (`test -r /dev/kvm && test -w /dev/kvm` must succeed).
- CPU with VT-x/EPT (Intel) or AMD-V (AMD) — nested guest emulation
  needs it. `grep -Eo 'vmx|svm' /proc/cpuinfo` should return something.
- ≥ 32 GiB memory and ≥ 60 GiB free disk in `$HOME` (defaults; smaller
  works for small labs — see env-var table).
- `tmux` — install steps must run inside a tmux session, or SSH
  disconnect kills a 10-minute install.

On your workstation (the machine you `ssh` from):

- An SSH client (for tunnelling VNC + web ports back).
- A VNC client (for the install + first-boot prompts). Any works;
  `vncviewer`, TigerVNC, macOS Screen Sharing, Remmina.
- A browser (day-to-day EVE-NG use).

## Usage — direct from GitHub (no clone)

If you have Nix with flakes enabled, run directly against the repo:

```sh
tmux new -s eve                        # essential — VM dies without it

nix --refresh run github:subanesh-swe/eve-lab-qemu -- setup
nix --refresh run github:subanesh-swe/eve-lab-qemu -- install
nix --refresh run github:subanesh-swe/eve-lab-qemu -- run

# in a second SSH session on the same host:
nix --refresh run github:subanesh-swe/eve-lab-qemu -- check
```

Notes:
- `--refresh` forces Nix to re-fetch the latest commit each run — drop
  it once you want to lock to a specific version and stop pulling
  updates.
- Pin to a specific commit for reproducibility:
  `nix run github:subanesh-swe/eve-lab-qemu/<commit-sha> -- run`
- First invocation downloads the flake + nixpkgs; subsequent runs are
  cached.

### If you hit GitHub API rate limits

The `github:owner/repo` form uses GitHub's API to resolve the ref,
which is capped at 60 requests/hour for unauthenticated clients. If
you see `HTTP 403: API rate limit exceeded`, fetch the archive
directly (goes through GitHub's CDN, no API involved):

```sh
nix run https://github.com/subanesh-swe/eve-lab-qemu/archive/master.zip -- setup
nix run https://github.com/subanesh-swe/eve-lab-qemu/archive/master.zip -- install
nix run https://github.com/subanesh-swe/eve-lab-qemu/archive/master.zip -- run
nix run https://github.com/subanesh-swe/eve-lab-qemu/archive/master.zip -- check
```

Pin to a specific commit for reproducibility:

```sh
nix run https://github.com/subanesh-swe/eve-lab-qemu/archive/<commit-sha>.zip -- run
```

Or authenticate `gh` (`gh auth login`) to raise your API limit to
5000/hour and keep using the `github:` form.

## Usage — with a local clone

```sh
git clone https://github.com/subanesh-swe/eve-lab-qemu.git
cd eve-lab-qemu
tmux new -s eve

nix run .# -- setup                    # ISO + qcow2 + VNC password (once)
nix run .# -- install                  # boot ISO, install EVE-NG (once)
                                       # WILL NOT EXIT — kill at
                                       # "failed unmounting: /cdrom"
                                       # (Ctrl-a then x). Subiquity bug,
                                       # install has succeeded.
nix run .# -- run                      # boot the installed VM
                                       # (every session goes through this)
nix run .# -- check                    # HTTP-probe the web UI
```

Use a local clone if you want to edit the script, run `nix flake check`
locally, or contribute changes.

## Usage — without Nix

Same script works standalone if `qemu-system-x86_64`, `qemu-img`,
`aria2c`, `openssl`, `curl`, `pgrep` are on your `$PATH`:

```sh
chmod +x eve-lab.sh
tmux new -s eve
./eve-lab.sh setup
./eve-lab.sh install
./eve-lab.sh run
./eve-lab.sh check
```

## Order of operations

`setup` and `install` are **one-time**. Every subsequent session goes:

```
  tmux a -t eve           # re-attach the existing session
  eve-lab run             # boot the VM (if it isn't already running)
  eve-lab check           # optional, from a second SSH session
```

## Port forwarding from your workstation

The VM's ports are forwarded to loopback on the host, not exposed
externally. Reach them by tunnelling through SSH:

```sh
# Web UI — day-to-day
ssh -N -L 8080:localhost:8080 <host>
# then browse http://localhost:8080/  (login admin / eve)

# VNC — install + first-boot prompts only
ssh -N -L 5901:localhost:5901 <host>
# then VNC client to localhost:5901  (password in ~/.eve-vnc-pass)
```

Both `install` and `run` print the exact commands with your configured
ports every time — no need to memorise.

## Flags and environment variables

Design rule: **one spelling per knob**.

- Per-run values → **CLI flags** (`--flag value`). No env-var fallback.
- Session/path config → **env vars** (persistent in your shell rc).

No precedence rules to remember; each option has exactly one place to
set it.

### Per-run flags

```
eve-lab setup   [--iso-url URL]   [--disk SIZE]   [--downloader aria2|curl]
eve-lab install [--mem SIZE]      [--cpus N]
eve-lab run     [--mem SIZE]      [--cpus N]
eve-lab check   [--port PORT]     [--host HOST]   [--timeout SECS]
```

Run `eve-lab help` for defaults and per-flag notes.

### Session env vars

Set once in your shell rc. All optional; defaults shown.

| var | default | meaning |
|---|---|---|
| `EVE_DIR` | `~/eve-lab` | where ISO + qcow2 live |
| `VNC_PASS_FILE` | `~/.eve-vnc-pass` | VNC password file |
| `VNC_PORT_OFFSET` | `1` | VNC `:N` → TCP `590N` |
| `WEB_HOSTFWD_PORT` | `8080` | host port → VM :80 (also the `check --port` default) |
| `WEB_TLS_HOSTFWD_PORT` | `8443` | host port → VM :443 |
| `QEMU_PROC_MATCH` | `qemu-system-x86_64.*eve-lab` | pgrep pattern for `check` |

**Finding the current ISO URL** — EVE-NG rotates URLs per release. If
`setup` fails to download, get a fresh URL:

1. Open [https://www.eve-ng.net/index.php/download/](https://www.eve-ng.net/index.php/download/)
2. Click the "Free EVE Community Edition" tab.
3. Copy the "EVE-NG CE Full ISO – direct link".
4. Re-run: `eve-lab setup --iso-url '<pasted URL>'`

## Tests

### Sandbox-safe (`nix flake check`)

Runs anywhere with Nix; no KVM, no network needed.

1. `script-build` — `writeShellApplication` runs `shellcheck` at build
   time. Building = clean.
2. `script-parse` — `bash -n` on the raw source; catches syntax breaks.
3. `help-runs` — builds the wrapper, invokes `eve-lab help`, greps for
   the expected header. Exercises the dispatch table.
4. `qemu-smoke` — QEMU exists and knows `virtio-scsi-pci`,
   `virtio-net-pci`, and the `secret` object we use.

### Runtime

```sh
nix run .# -- check
# or: ./eve-lab.sh check
```

Four graded probes: QEMU process running → TCP accept → HTTP
200/301/302 → body mentions EVE-NG. Exit 0 = all pass.

## What this does NOT do

- Doesn't fix host prerequisites (missing `/dev/kvm`, low memory,
  small disk). Those are the host operator's job.
- Doesn't automate the EVE-NG installer prompts (root password,
  hostname, DHCP/static IP). Those still happen via VNC.
- Doesn't back up your labs. Use EVE-NG's web UI → export.

## References

- EVE-NG CE Cookbook v6.2:
  [https://www.eve-ng.net/wp-content/uploads/2024/05/EVE-CE-BOOK-6.2-2024.pdf](https://www.eve-ng.net/wp-content/uploads/2024/05/EVE-CE-BOOK-6.2-2024.pdf)
- EVE-NG downloads:
  [https://www.eve-ng.net/index.php/download/](https://www.eve-ng.net/index.php/download/)

## License

Apache License 2.0 — see [LICENSE](./LICENSE) and [NOTICE](./NOTICE).

Copyright 2026 Subanesh Kumarasamy.
