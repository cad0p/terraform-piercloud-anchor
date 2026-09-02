#!/usr/bin/env bash
#
# 010-provision.sh — provision the tang/clevis NBDE anchor + uptime monitor.
#
# WHERE THIS RUNS: ON the anchor box itself (the netcup VPS you adopted with
# the terraform-piercloud-tang module), as root, via the netcup SCP remote
# console (browser VNC) — or your own SSH session if you added your own SSH
# key in the SCP. Nothing in this repo ever connects to the anchor.
#
#   curl -fsSL https://raw.githubusercontent.com/cad0p/terraform-piercloud-tang/main/scripts/010-provision.sh | bash
#
# Properties (see scripts/README.md): idempotent, human-run, no secrets.
# The tang keypair is generated ON THIS BOX and never leaves it. This script
# never sends key material anywhere; it only prints a public thumbprint.
#
set -euo pipefail

TANG_KEYS_DIR="/var/db/tang"
# renovate: depName=twinproduction/gatus datasource=docker
GATUS_IMAGE="twinproduction/gatus:v5.36.0"
GATUS_PORT="8080"
GATUS_CONFIG="/etc/gatus/config.yaml"

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
# c) docker + Gatus monitor (idempotent; config-as-file, no UI bootstrap)
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

log "Running Gatus monitor (bound to 127.0.0.1:${GATUS_PORT}, config: ${GATUS_CONFIG})"
if docker ps --format '{{.Names}}' | grep -qx "gatus"; then
  log "Gatus already running"
elif docker ps -a --format '{{.Names}}' | grep -qx "gatus"; then
  docker start gatus >/dev/null
else
  docker run -d --name gatus --restart unless-stopped \
    -p 127.0.0.1:${GATUS_PORT}:8080 \
    -v "${GATUS_CONFIG}:/config/config.yaml:ro" \
    --mount type=volume,source=gatus-data,target=/data \
    "${GATUS_IMAGE}" >/dev/null
fi

# ---------------------------------------------------------------------------
# d) Gatus config (written on first run only - user edits are never clobbered;
#    sqlite storage in the gatus-data volume keeps the availability history)
# ---------------------------------------------------------------------------
if [ -f "${GATUS_CONFIG}" ]; then
  log "Gatus config already present at ${GATUS_CONFIG} - kept as-is"
else
  log "Writing Gatus config to ${GATUS_CONFIG}"
  ANCHOR_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
  mkdir -p "$(dirname "${GATUS_CONFIG}")"
  cat > "${GATUS_CONFIG}" <<GCFG
# Managed by terraform-piercloud-tang (scripts/010-provision.sh).
# Edit freely - re-running the script will NOT overwrite this file.
# Docs: https://gatus.io/docs

storage:
  path: /data/gatus.db   # sqlite in the gatus-data volume: history survives restarts

alerting:
  # Pick ONE channel and fill it in, then reference it from each endpoint's
  # "alerts" list. Gatus PUSHES alerts when an endpoint fails - a dashboard
  # you never open is useless; the push is the point. Examples:
  #
  #   ntfy:      # self-hostable push, simplest
  #     url: https://ntfy.yourdomain.tld
  #     topic: piercloud-anchor
  #   telegram:
  #     token: <bot-token>
  #     id: <chat-id>
  #   smtp:      # plain email
  #     username: you@example.com
  #     password: <app-password>
  #     from: gatus@example.com
  #     to: ["you@example.com"]

metrics: false

endpoints:
  # The anchor itself - local only, never firewalled, always accurate.
  - name: tang (local)
    url: http://127.0.0.1/adv
    interval: 60s
    conditions:
      - "[STATUS] == 200"
    # alerts:
    #   - type: ntfy        # <- match the channel you configured above

  # YOUR MAIN SERVER - probe it by DNS NAME, not IP: Gatus never caches DNS,
  # so when you migrate and flip the record, the monitor follows automatically
  # and the availability history stays continuous across the cutover.
  # Uncomment and adapt (HTTPS, TCP, ICMP, DNS record checks all supported):
  #
  # - name: main-server https
  #   url: https://your-main-server.example.com
  #   interval: 60s
  #   conditions:
  #     - "[STATUS] == 200"
  #   alerts:
  #     - type: ntfy
  #       failure-threshold: 3
  #
  # - name: main-server ssh
  #   host: "ssh://your-main-server.example.com:22"
  #   interval: 60s
  #   conditions:
  #     - "[CONNECTED] == true"
GCFG
  echo
  cat <<MON
  The monitor config is at ${GATUS_CONFIG} - this is the one file to edit:

    1. Configure an alerting channel (ntfy / Telegram / SMTP) in "alerting".
    2. Uncomment the "YOUR MAIN SERVER" endpoints and point them at your
       server's real DNS names (they follow DNS flips automatically).
    3. Apply:  docker restart gatus
    4. Sanity-check:  docker logs gatus   (config errors show there)

  Gatus UI: bound to 127.0.0.1:${GATUS_PORT} on the anchor. Reach it via YOUR
  OWN SSH tunnel (needs an SSH key YOU added in the netcup SCP; this module
  provisions no SSH):

      ssh -L ${GATUS_PORT}:127.0.0.1:${GATUS_PORT} root@${ANCHOR_IP:-<anchor-ip>}
      then open http://localhost:${GATUS_PORT}
MON
echo
fi

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
  6. From your MAIN box, verify the external path any time (the anchor
     cannot probe its own external address through the firewall):
       curl -fsS http://${ANCHOR_IP:-<anchor-ip>}/adv    # 200 + JSON = tang is answering
NEXT
echo
log "Done. tang is up, the thumbprint is above, Gatus config is at ${GATUS_CONFIG}."
