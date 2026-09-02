#!/usr/bin/env bash
#
# 10-provision.sh — provision the tang/clevis NBDE anchor + uptime monitor.
#
# WHERE THIS RUNS: ON the anchor box itself (the netcup VPS you adopted with
# the terraform-piercloud-tang module), as root, via the netcup SCP remote
# console (browser VNC) — or your own SSH session if you added your own SSH
# key in the SCP. Nothing in this repo ever connects to the anchor.
#
#   curl -fsSL https://raw.githubusercontent.com/cad0p/terraform-piercloud-tang/main/scripts/10-provision.sh | bash
#
# Properties (see scripts/README.md): idempotent, human-run, no secrets.
# The tang keypair is generated ON THIS BOX and never leaves it. This script
# never sends key material anywhere; it only prints a public thumbprint.
#
set -euo pipefail

TANG_KEYS_DIR="/var/db/tang"
KUMA_CONTAINER="uptime-kuma"
KUMA_PORT="3001"

log()  { printf '\n\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARNING:\033[0m %s\n' "$*"; }
die()  { printf '\n\033[1;31mFAIL:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root (netcup SCP remote console, root login)"

# ---------------------------------------------------------------------------
# a) tang + tangd.socket (idempotent)
# ---------------------------------------------------------------------------
log "Installing tang (NBDE key server)"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq tang jq >/dev/null

log "Enabling tangd.socket (port 80)"
systemctl enable --now tangd.socket >/dev/null 2>&1 || true

# Defensive key generation: some base images ship tang without keys on disk.
if ! compgen -G "${TANG_KEYS_DIR}/*.jwk" >/dev/null; then
  log "No tang keys found — generating keypair on this box"
  if [ -x /usr/libexec/tangd-keygen ]; then
    /usr/libexec/tangd-keygen "${TANG_KEYS_DIR}"
  elif [ -x /usr/lib/tang/tangd-keygen ]; then
    /usr/lib/tang/tangd-keygen "${TANG_KEYS_DIR}"
  else
    die "tangd-keygen not found; reinstall the 'tang' package"
  fi
  systemctl restart tangd.socket 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# b) thumbprint — the ONE value you must save
# ---------------------------------------------------------------------------
log "tang is running. Your thumbprint (SAVE THIS NOW):"
echo
if command -v tang-show-keys >/dev/null 2>&1; then
  echo "    $(tang-show-keys 80)"
else
  echo "    $(jose jwk thp -a S256 -r -f "${TANG_KEYS_DIR}"/*.jwk | head -n1)"
fi
echo

# ---------------------------------------------------------------------------
# f) key-leak assertion (module invariant #1: tang keys never enter tf state —
#    this script prints no secrets, but if you happen to run it from a
#    directory holding OpenTofu/Terraform state, scan that state for key
#    material and fail loudly on a match)
# ---------------------------------------------------------------------------
assert_no_key_leak() {
  local leaked=0 states secret
  states=$(find . -maxdepth 3 \( -name '*.tfstate' -o -name '*.tfstate.*' -o -name '*.tfplan' \) -type f 2>/dev/null || true)
  if [ -z "${states}" ]; then
    log "Key-leak assertion: no terraform state files in $(pwd) — nothing to scan (OK)"
    return 0
  fi
  while IFS= read -r jwk; do
    [ -n "${jwk}" ] || continue
    # the private field "d" of each JWK, and every thumbprint algorithm
    secret=$(jq -r '.d // empty' "${jwk}" 2>/dev/null || true)
    if [ -n "${secret}" ] && grep -qF -- "${secret}" ${states}; then leaked=1; fi
    for alg in S1 S256 S512; do
      for secret in $(jose jwk thp -a "${alg}" -r -f "${jwk}" 2>/dev/null || true); do
        if grep -qF -- "${secret}" ${states}; then leaked=1; fi
      done
    done
  done < <(compgen -G "${TANG_KEYS_DIR}/*.jwk" || true)
  if [ "${leaked}" -eq 1 ]; then
    die "tang key material matched a terraform state/plan file in $(pwd). \
This violates the module's hard invariant #1 (tang keys never enter tf state). \
Do NOT apply that configuration; investigate before proceeding."
  fi
  log "Key-leak assertion: tang key material NOT present in terraform state files (OK)"
}
assert_no_key_leak

# ---------------------------------------------------------------------------
# c) docker + Uptime Kuma (idempotent; sqlite persists in a docker volume)
# ---------------------------------------------------------------------------
log "Installing docker"
if ! docker info >/dev/null 2>&1; then
  apt-get install -y -qq ca-certificates curl gnupg >/dev/null
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io >/dev/null
fi
systemctl enable --now docker >/dev/null 2>&1 || true

log "Running Uptime Kuma (bound to 127.0.0.1:${KUMA_PORT}, volume: uptime-kuma)"
if docker ps --format '{{.Names}}' | grep -qx "${KUMA_CONTAINER}"; then
  log "Uptime Kuma already running"
elif docker ps -a --format '{{.Names}}' | grep -qx "${KUMA_CONTAINER}"; then
  docker start "${KUMA_CONTAINER}" >/dev/null
else
  docker run -d --name "${KUMA_CONTAINER}" --restart unless-stopped \
    -p 127.0.0.1:${KUMA_PORT}:3001 -v uptime-kuma:/app/data \
    louislam/uptime-kuma:1 >/dev/null
fi

# ---------------------------------------------------------------------------
# d) one-time Kuma admin password (generated, printed ONCE, stored nowhere)
# ---------------------------------------------------------------------------
log "Generating a suggested Uptime Kuma admin password"
KUMA_PASSWORD=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20)
echo
echo "  ┌──────────────────────────────────────────────────────────────────┐"
echo "  │ SAVE THIS NOW — shown ONCE, never printed again, stored nowhere: │"
echo "  │                                                                  │"
echo "  │   Uptime Kuma admin password: ${KUMA_PASSWORD}   │"
echo "  └──────────────────────────────────────────────────────────────────┘"
echo
warn "When you first open the Kuma UI you create the admin account — use this \
password there. If you skip this now it is unrecoverable (re-run the script \
for a fresh suggestion)."
echo

# ---------------------------------------------------------------------------
# e) Kuma monitor — the socket.io API is not clean to script from bash,
#    so print the exact manual settings instead (guided setup).
# ---------------------------------------------------------------------------
log "Kuma monitor setup (manual, 2 minutes — the socket.io API is not scriptable)"
ANCHOR_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
cat <<MON
  Open the Kuma UI (see "Reaching the Kuma UI" below), create the admin
  account, then add TWO monitors:

  Monitor 1 — "tang local"
    Type:             HTTP(s)
    URL:              http://127.0.0.1/adv
    Heartbeat interval: 60 s    Retries: 3
    (tang answers GET /adv with its public key set; 200 = alive)

  Monitor 2 — "tang via firewall path"
    Type:             HTTP(s)
    URL:              http://${ANCHOR_IP}/adv
    Heartbeat interval: 300 s   Retries: 3
    (proves tangd + the local firewall path stay up; your MAIN box's
    reachability is what actually matters and is checked at every boot by
    clevis itself)
MON
echo
cat <<UI
  Reaching the Kuma UI: it listens on 127.0.0.1:${KUMA_PORT} only.
  The module's firewall admits TCP/80 from your main box — not ${KUMA_PORT}.
  Reach Kuma via YOUR OWN SSH tunnel (needs an SSH key YOU added in the
  netcup SCP; this module provisions no SSH):

      ssh -L ${KUMA_PORT}:127.0.0.1:${KUMA_PORT} root@${ANCHOR_IP:-<anchor-ip>}
      then open http://localhost:${KUMA_PORT}

  (If you accept the exposure, you may instead bind 0.0.0.0 and add an
  ingress TCP/${KUMA_PORT} rule for your main-box IP in the netcup SCP.)
UI
echo

# ---------------------------------------------------------------------------
# g) next steps on your MAIN box
# ---------------------------------------------------------------------------
log "Next steps — on your MAIN box (not here):"
cat <<NEXT
  1. Install the client pieces:
       apt-get install clevis clevis-luks clevis-initramfs
  2. Bind your LUKS device to THIS anchor (find <device> with \`lsblk -f\`,
     e.g. /dev/nvme0n1p3). At bind time, clevis shows a thumbprint —
     it MUST match the thumbprint printed above. If it does not match,
     ANSWER NO and investigate:
       clevis luks bind -d <device> tang '{"url":"http://${ANCHOR_IP:-<anchor-ip>}"}'
  3. Rebuild the initramfs:
       update-initramfs -u
  4. Reboot test: the unlock prompt may appear briefly, then continue on
     its own when clevis reaches this anchor. That is success.
  5. Keep the LUKS passphrase keyslot. This anchor is availability,
     never the security anchor; if it is down, you type the passphrase.
NEXT
echo
log "Done. tang is up, the thumbprint is above, Kuma is installing its UI."
