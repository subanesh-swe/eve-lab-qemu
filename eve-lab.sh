#!/usr/bin/env bash
# USAGE_BEGIN
# eve-lab — run EVE-NG inside a QEMU/KVM VM on any Linux host that
#           exposes /dev/kvm. Useful when you can't install EVE-NG
#           directly on the host (e.g. NixOS, containerized dev
#           environments, restricted hosts).
#
# Subcommands (run IN THIS ORDER, first time):
#   1. setup   [--iso-url URL] [--disk SIZE] [--downloader aria2|curl]
#        Download ISO, create qcow2, generate VNC password.
#        Defaults:  --iso-url = baked-in CE 6.2 direct link
#                   --disk 200G
#                   --downloader aria2
#        If the baked-in --iso-url goes stale, grab the current one at
#          https://www.eve-ng.net/index.php/download/
#          → "Free EVE Community Edition" → "CE Full ISO - direct link"
#
#   2. install [--mem SIZE] [--cpus N]
#        Boot with ISO to install EVE-NG. Runs the installer via VNC.
#        WILL NOT EXIT ON ITS OWN — expect 'failed unmounting: /cdrom'
#        at end of phase 1. When you see it (install has succeeded),
#        kill QEMU (Ctrl-a x) and move to step 3.
#        Defaults:  --mem 24G  --cpus 8
#
#   3. run     [--mem SIZE] [--cpus N]
#        Boot the installed disk (day-to-day; no CD). First-boot prompts
#        (root pw, hostname, DHCP) happen here via VNC.
#        Defaults:  --mem 24G  --cpus 8
#
#   4. check   [--port PORT] [--host HOST] [--timeout SECS]
#        Verify the VM web UI is reachable (run from a second SSH
#        session while 'run' is up).
#        Defaults:  --port $WEB_HOSTFWD_PORT (8080)
#                   --host 127.0.0.1
#                   --timeout 5
#
#   help
#        Show this message.
#
# On every subsequent session you only need step 3 (run) — plus 4
# (check) if you want to verify. setup and install are one-time.
#
# Session/path config lives in env vars (persistent, set once in your
# shell rc). Per-run values go on the CLI as flags — one spelling per
# knob, no precedence rules to remember.
#
# Session env vars (all optional, defaults shown):
#   EVE_DIR=$HOME/eve-lab                        where ISO + qcow2 live
#   VNC_PASS_FILE=$HOME/.eve-vnc-pass            VNC password file
#   VNC_PORT_OFFSET=1                            VNC :N → TCP 590N
#   WEB_HOSTFWD_PORT=8080                        host port → VM :80
#   WEB_TLS_HOSTFWD_PORT=8443                    host port → VM :443
#   QEMU_PROC_MATCH=qemu-system-x86_64.*eve-lab  (check) pgrep pattern
#
# Runtime dependencies (must be on PATH):
#   qemu-system-x86_64, qemu-img, openssl, curl, pgrep
#   aria2c (optional — only if --downloader aria2, which is the default)
# USAGE_END

set -euo pipefail

# Session/path config — env-only (persistent, set once in shell rc).
EVE_DIR="${EVE_DIR:-$HOME/eve-lab}"
VNC_PASS_FILE="${VNC_PASS_FILE:-$HOME/.eve-vnc-pass}"
VNC_PORT_OFFSET="${VNC_PORT_OFFSET:-1}"
WEB_HOSTFWD_PORT="${WEB_HOSTFWD_PORT:-8080}"
WEB_TLS_HOSTFWD_PORT="${WEB_TLS_HOSTFWD_PORT:-8443}"
QEMU_PROC_MATCH="${QEMU_PROC_MATCH:-qemu-system-x86_64.*eve-lab}"

# Per-run defaults — override via CLI flags on the relevant subcommand.
# These are plain assignments (no env fallback) so there's exactly one
# spelling per knob and no precedence confusion.
ISO_URL="https://customers.eve-ng.net/eve-ce-prod-6.2.0-4-full.iso"
DISK_SIZE="200G"
DOWNLOADER="aria2"
MEM="24G"
CPUS="8"
HOST="127.0.0.1"
TIMEOUT="5"
# PORT defaults to whatever WEB_HOSTFWD_PORT is (they're two views of the
# same thing) — set inside cmd_check so it reflects any env override.

usage() {
  # Prints everything between USAGE_BEGIN and USAGE_END markers, strips
  # the leading `# ` on each line. Markers themselves are omitted.
  sed -n '/^# USAGE_BEGIN$/,/^# USAGE_END$/{
    /^# USAGE_BEGIN$/d
    /^# USAGE_END$/d
    s/^# \{0,1\}//
    p
  }' "$0"
}

require_kvm() {
  if ! { test -r /dev/kvm && test -w /dev/kvm; }; then
    echo "eve-lab: /dev/kvm not usable — ask ops." >&2
    exit 1
  fi
}

warn_no_tmux() {
  if [ -z "${TMUX:-}" ]; then
    echo "WARNING: not running inside tmux. If your SSH connection drops," >&2
    echo "         the VM will die. Run:  tmux new -s eve" >&2
    echo "         then re-run this command inside the tmux session." >&2
    sleep 3
  fi
}

unknown_flag() {
  # $1 = subcommand name, $2 = the offending flag
  echo "eve-lab $1: unknown flag '$2'" >&2
  echo "  see 'eve-lab help' for available flags." >&2
  exit 1
}

need_value() {
  # $1 = flag name; asserts $2 (the value that came after) is present
  [ -n "${2:-}" ] || { echo "eve-lab: flag '$1' requires a value" >&2; exit 1; }
}

cmd_setup() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --iso-url)     need_value "$1" "${2:-}"; ISO_URL="$2";    shift 2 ;;
      --disk)        need_value "$1" "${2:-}"; DISK_SIZE="$2";  shift 2 ;;
      --downloader)  need_value "$1" "${2:-}"; DOWNLOADER="$2"; shift 2 ;;
      -h|--help)     usage; exit 0 ;;
      --)            shift; break ;;
      *)             unknown_flag setup "$1" ;;
    esac
  done

  echo "eve-lab setup"
  echo "  EVE_DIR=$EVE_DIR"
  echo "  ISO_URL=$ISO_URL"
  echo "  DISK_SIZE=$DISK_SIZE"
  echo

  mkdir -p "$EVE_DIR"
  cd "$EVE_DIR"

  # 1. VNC password (QEMU classic VNC auth truncates at 8 chars).
  if [ ! -f "$VNC_PASS_FILE" ]; then
    umask 077
    openssl rand -base64 9 | tr -d '/+=\n' | cut -c1-8 > "$VNC_PASS_FILE"
    chmod 0600 "$VNC_PASS_FILE"
    echo "Generated VNC password (in $VNC_PASS_FILE):"
    cat "$VNC_PASS_FILE"; echo
  else
    echo "VNC password already exists at $VNC_PASS_FILE"
  fi

  # 2. ISO download (resumable — both downloaders resume a partial file).
  if [ ! -f eve-ce.iso ]; then
    echo "Downloading EVE-NG CE ISO (~3.2 GiB)..."
    echo "  from:       $ISO_URL"
    echo "  downloader: $DOWNLOADER"
    case "$DOWNLOADER" in
      aria2)
        download_ok=false
        if command -v aria2c >/dev/null 2>&1; then
          aria2c -s 16 -x 16 -c -o eve-ce.iso "$ISO_URL" && download_ok=true
        else
          echo "eve-lab: aria2c not on PATH. Retry with --downloader curl or install aria2." >&2
        fi
        ;;
      curl)
        download_ok=false
        # -f: fail on HTTP errors  -L: follow redirects  -C -: resume partial
        curl -fL -C - -o eve-ce.iso "$ISO_URL" && download_ok=true
        ;;
      *)
        echo "eve-lab: unknown DOWNLOADER='$DOWNLOADER' (expected: aria2 | curl)" >&2
        exit 1
        ;;
    esac

    if [ "$download_ok" != true ]; then
      cat >&2 <<EOF

ERROR: could not download EVE-NG CE ISO from
  $ISO_URL

EVE-NG rotates download URLs per release, so the baked-in default
becomes stale. Get the current URL and re-run:

  1. Open: https://www.eve-ng.net/index.php/download/
  2. Click the "Free EVE Community Edition" tab.
  3. Copy the "EVE-NG CE Full ISO - direct link" URL.
  4. Re-run this command with it:

     ISO_URL='<pasted URL>' eve-lab setup

If aria2 is unavailable, force curl:

     DOWNLOADER=curl eve-lab setup

Also possible: this host has no outbound internet, or the mirror
is temporarily down. Try again after checking connectivity:

     curl -sSI https://www.eve-ng.net/ | head -1
EOF
      exit 1
    fi
  else
    echo "ISO already present: $(du -h eve-ce.iso | cut -f1)"
  fi

  # Print path + sha256 so the user can verify against the download page.
  # EVE-NG's ISO URLs rotate silently — a bad checksum here means either
  # a truncated download or a mid-air replacement.
  iso_path="$(pwd)/eve-ce.iso"
  iso_sha="$(sha256sum eve-ce.iso | awk '{print $1}')"
  cat <<EOF

ISO path:   $iso_path
ISO sha256: $iso_sha

Verify against the checksum published at:
  https://www.eve-ng.net/index.php/download/
If they don't match, delete the ISO and re-run 'eve-lab setup'.
EOF

  # 3. qcow2 disk (thin-provisioned).
  if [ ! -f eve.qcow2 ]; then
    echo "Creating qcow2 disk ($DISK_SIZE)..."
    qemu-img create -f qcow2 eve.qcow2 "$DISK_SIZE"
  else
    echo "Disk already present: $(du -h eve.qcow2 | cut -f1)"
  fi

  echo
  echo "Setup complete. Next:  eve-lab install"
}

cmd_install() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --mem)      need_value "$1" "${2:-}"; MEM="$2";  shift 2 ;;
      --cpus)     need_value "$1" "${2:-}"; CPUS="$2"; shift 2 ;;
      -h|--help)  usage; exit 0 ;;
      --)         shift; break ;;
      *)          unknown_flag install "$1" ;;
    esac
  done

  require_kvm
  [ -f "$EVE_DIR/eve-ce.iso" ] || { echo "run 'eve-lab setup' first (no ISO in $EVE_DIR)" >&2; exit 1; }
  [ -f "$EVE_DIR/eve.qcow2"  ] || { echo "run 'eve-lab setup' first (no qcow2 in $EVE_DIR)" >&2; exit 1; }
  [ -f "$VNC_PASS_FILE"      ] || { echo "run 'eve-lab setup' first (no VNC password)" >&2; exit 1; }
  warn_no_tmux

  vnc_port=$((5900 + VNC_PORT_OFFSET))
  cat <<EOF
eve-lab install starting.

  VNC console:        127.0.0.1:$vnc_port  (on this host)
  VNC password:       $(cat "$VNC_PASS_FILE")
  Web UI (after run): 127.0.0.1:$WEB_HOSTFWD_PORT  (on this host)

  From your workstation, in a NEW terminal, tunnel these ports:
    ssh -N -L $vnc_port:localhost:$vnc_port <this-host>       # VNC (install)
    ssh -N -L $WEB_HOSTFWD_PORT:localhost:$WEB_HOSTFWD_PORT <this-host>       # Web UI (later)
  Then open a VNC client to localhost:$vnc_port.

╔══════════════════════════════════════════════════════════════════╗
║  READ THIS BEFORE THE INSTALLER STARTS                           ║
║                                                                   ║
║  This command will NOT exit on its own. When you see             ║
║      failed unmounting: /cdrom                                    ║
║  (~5-15 min from now, at end of phase 1) — the install has       ║
║  SUCCEEDED. The VM just can't unmount the CD to reboot cleanly.  ║
║                                                                   ║
║  1. Kill QEMU:   press Ctrl-a  then  x                           ║
║  2. Then run:    eve-lab run                                     ║
║  3. Reconnect VNC, complete the first-boot prompts.              ║
║                                                                   ║
║  If you wait for it to finish on its own, it will loop forever.  ║
╚══════════════════════════════════════════════════════════════════╝

EOF
  # Small pause so the banner isn't scrolled off the top by QEMU's own output.
  sleep 3

  exec qemu-system-x86_64 \
    -enable-kvm -cpu host -smp "$CPUS" -m "$MEM" \
    -machine q35 \
    -device virtio-scsi-pci,id=scsi0 \
    -drive "file=$EVE_DIR/eve.qcow2,if=none,id=hd0,cache=writeback,discard=unmap" \
    -device scsi-hd,drive=hd0,bus=scsi0.0,bootindex=2 \
    -drive "file=$EVE_DIR/eve-ce.iso,if=none,id=cd0,media=cdrom,readonly=on" \
    -device scsi-cd,drive=cd0,bus=scsi0.0,bootindex=1 \
    -netdev "user,id=n0,hostfwd=tcp::${WEB_HOSTFWD_PORT}-:80,hostfwd=tcp::${WEB_TLS_HOSTFWD_PORT}-:443" \
    -device virtio-net-pci,netdev=n0 \
    -object "secret,id=vncsec,file=$VNC_PASS_FILE" \
    -vnc "127.0.0.1:${VNC_PORT_OFFSET},password-secret=vncsec" \
    -serial mon:stdio -name eve-lab
}

cmd_run() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --mem)      need_value "$1" "${2:-}"; MEM="$2";  shift 2 ;;
      --cpus)     need_value "$1" "${2:-}"; CPUS="$2"; shift 2 ;;
      -h|--help)  usage; exit 0 ;;
      --)         shift; break ;;
      *)          unknown_flag run "$1" ;;
    esac
  done

  require_kvm
  [ -f "$EVE_DIR/eve.qcow2" ] || { echo "run 'eve-lab setup' + 'eve-lab install' first (no qcow2 in $EVE_DIR)" >&2; exit 1; }
  [ -f "$VNC_PASS_FILE"     ] || { echo "run 'eve-lab setup' first (no VNC password)" >&2; exit 1; }
  warn_no_tmux

  vnc_port=$((5900 + VNC_PORT_OFFSET))
  cat <<EOF
eve-lab run starting.

  VNC console:  127.0.0.1:$vnc_port                   (on this host)
  Web UI:       http://127.0.0.1:$WEB_HOSTFWD_PORT/   (on this host, once EVE-NG is up)

  From your workstation, in a NEW terminal, tunnel the web port:
    ssh -N -L $WEB_HOSTFWD_PORT:localhost:$WEB_HOSTFWD_PORT <this-host>
  Then open a browser at http://localhost:$WEB_HOSTFWD_PORT/  (admin / eve).

  For VNC (only needed for first-boot prompts or recovery):
    ssh -N -L $vnc_port:localhost:$vnc_port <this-host>
  Point a VNC client at localhost:$vnc_port (password in $VNC_PASS_FILE).

EOF

  exec qemu-system-x86_64 \
    -enable-kvm -cpu host -smp "$CPUS" -m "$MEM" \
    -machine q35 \
    -device virtio-scsi-pci,id=scsi0 \
    -drive "file=$EVE_DIR/eve.qcow2,if=none,id=hd0,cache=writeback,discard=unmap" \
    -device scsi-hd,drive=hd0,bus=scsi0.0,bootindex=1 \
    -netdev "user,id=n0,hostfwd=tcp::${WEB_HOSTFWD_PORT}-:80,hostfwd=tcp::${WEB_TLS_HOSTFWD_PORT}-:443" \
    -device virtio-net-pci,netdev=n0 \
    -object "secret,id=vncsec,file=$VNC_PASS_FILE" \
    -vnc "127.0.0.1:${VNC_PORT_OFFSET},password-secret=vncsec" \
    -serial mon:stdio -name eve-lab
}

cmd_check() {
  PORT="$WEB_HOSTFWD_PORT"      # default to whatever hostfwd routes to
  while [ $# -gt 0 ]; do
    case "$1" in
      --port)     need_value "$1" "${2:-}"; PORT="$2";    shift 2 ;;
      --host)     need_value "$1" "${2:-}"; HOST="$2";    shift 2 ;;
      --timeout)  need_value "$1" "${2:-}"; TIMEOUT="$2"; shift 2 ;;
      -h|--help)  usage; exit 0 ;;
      --)         shift; break ;;
      *)          unknown_flag check "$1" ;;
    esac
  done

  fail() { echo "FAIL: $*" >&2; exit 1; }
  ok()   { echo "OK:   $*"; }

  echo "eve-lab check"
  echo "  target: http://$HOST:$PORT/"
  echo

  # 1. QEMU process running.
  if pgrep -f "$QEMU_PROC_MATCH" >/dev/null 2>&1; then
    ok "QEMU eve-lab process running (PID: $(pgrep -f "$QEMU_PROC_MATCH" | tr '\n' ' '))"
  else
    fail "no QEMU eve-lab process — start it with:  eve-lab run"
  fi

  # 2. TCP port open.
  if ! (echo >/dev/tcp/"$HOST"/"$PORT") 2>/dev/null; then
    fail "TCP connect to $HOST:$PORT failed — QEMU up but hostfwd not routing (VM not booted yet?)"
  fi
  ok "TCP $HOST:$PORT accepting connections"

  # 3. HTTP responds.
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$TIMEOUT" "http://$HOST:$PORT/" || echo "000")
  case "$code" in
    200|301|302) ok "HTTP $code from http://$HOST:$PORT/" ;;
    000)         fail "no HTTP response within ${TIMEOUT}s (VM booted but nginx not up yet?)" ;;
    *)           fail "unexpected HTTP $code (expected 200/301/302)" ;;
  esac

  # 4. Response body looks EVE-NG-shaped.
  body=$(curl -s --max-time "$TIMEOUT" "http://$HOST:$PORT/" || true)
  if echo "$body" | grep -qiE 'eve-?ng|unetlab|EVE Community'; then
    ok "response looks like EVE-NG"
  else
    echo "WARN: HTTP responded but body doesn't mention EVE-NG (nginx default page?)"
    echo "      first 200 chars: $(echo "$body" | head -c 200)"
  fi

  echo
  echo "eve-lab reachable. From your workstation, tunnel the web port:"
  echo "  ssh -N -L $PORT:localhost:$PORT <this-host>"
  echo "then browse http://localhost:$PORT/  (login admin / eve)"
}

sub="${1:-help}"
shift || true    # tolerate zero-arg invocation
case "$sub" in
  setup)   cmd_setup   "$@" ;;
  install) cmd_install "$@" ;;
  run)     cmd_run     "$@" ;;
  check)   cmd_check   "$@" ;;
  help|-h|--help) usage ;;
  *) echo "eve-lab: unknown command '$sub'" >&2; usage >&2; exit 1 ;;
esac
