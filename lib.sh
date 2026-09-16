# shellcheck shell=bash
# ---------------------------------------------------------------------------
# Shared helpers for bootstrap.sh and preflight.sh.
# Source after config.env.
# ---------------------------------------------------------------------------

# --- logging ---------------------------------------------------------------
log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '\033[1;33m[%s] WARN\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
die()  { printf '\033[1;31m[%s] ERROR\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }

# --- version comparison ----------------------------------------------------
# ver_ge A B  -> true if A >= B  (semantic, via sort -V)
ver_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]; }

# kernel major.minor of the running kernel, e.g. "5.15"
kernel_mm() { uname -r | grep -oE '^[0-9]+\.[0-9]+'; }

# --- interface discovery ---------------------------------------------------
# The experiment NIC name is not stable across swap-ins (eth1/eno1/enp8s0f0...),
# so find it by the IPv4 address it carries on the experiment subnet.
iface_for_ip() {
  # $1 may be a full IPv4 (10.0.1.1) or a dotted prefix (10.0.1.); returns the
  # dev whose address field (e.g. "10.0.1.1/24") starts with it. Dots are matched
  # literally, and there is NO trailing "/" so a prefix match works too.
  local pat
  pat="$(printf '%s' "$1" | sed 's/\./\\./g')"
  ip -o -4 addr show 2>/dev/null | awk -v p="^$pat" '$4 ~ p {print $2; exit}'
}

# --- internet access (NAT) -------------------------------------------------
# Idempotent: enables IPv4 NAT so apt/nix/git downloads work. No-op if already up.
enable_nat() {
  if curl -fsS --max-time 8 https://install.determinate.systems >/dev/null 2>&1; then
    return 0   # already have IPv4 internet
  fi
  log "enabling IPv4 NAT (vwall)"
  wget -O - -q --ciphers 'DEFAULT@SECLEVEL=1' \
    https://www.wall2.ilabt.iminds.be/enable-nat.sh | sudo bash || \
  wget -O - -q https://www.wall2.ilabt.iminds.be/enable-nat.sh | sudo bash
}

# --- experiment interface configuration ------------------------------------
# After our HWE-kernel reboot, emulab's rc.ifconfig fails to map the experiment
# NIC's MAC to its (renamed) Linux interface and leaves it DOWN with no IP. We
# redo that job from the testbed's own interface data: match MAC -> current dev,
# bring it up, assign the intended IP. Idempotent and best-effort.

mask2prefix() {
  case "$1" in
    255.255.255.0|"") echo 24 ;;
    255.255.0.0)      echo 16 ;;
    255.255.255.128)  echo 25 ;;
    255.255.255.192)  echo 26 ;;
    255.255.255.252)  echo 30 ;;
    *) local IFS=. o p=0; for o in $1; do while [ "${o:-0}" -gt 0 ]; do p=$((p + (o & 1))); o=$((o >> 1)); done; done; echo "$p" ;;
  esac
}

# Emulab's intended interface config as INET/MASK/MAC lines. rc.ifconfig is the
# proven source on these nodes (it echoes the INTERFACE lines even when it can't
# apply them — IFACE= empty after the HWE kernel rename), so try it FIRST; the
# tmcc cache paths were guesses that didn't pan out, kept only as fallbacks.
experiment_ifconfig_data() {
  if [ -x /usr/local/etc/emulab/rc/rc.ifconfig ]; then
    sudo /usr/local/etc/emulab/rc/rc.ifconfig 2>&1
    return 0
  fi
  local f t
  for f in /var/emulab/boot/tmcc/ifconfig /var/emulab/boot/tmcc.ifconfig; do
    [ -r "$f" ] && { cat "$f"; return 0; }
  done
  for t in /usr/local/etc/emulab/bin/tmcc /usr/local/etc/emulab/tmcc "$(command -v tmcc 2>/dev/null)"; do
    [ -n "$t" ] && [ -x "$t" ] && { sudo "$t" ifconfig 2>/dev/null; return 0; }
  done
  return 0
}

ensure_experiment_iface() {
  local data line inet mask mac cmac dev prefix
  data="$(experiment_ifconfig_data)"
  [ -n "$data" ] || { warn "no emulab interface data found; skipping iface config"; return 0; }
  # Match any line carrying both INET= and MAC= — covers tmcc's "INTERFACE ..."
  # lines and rc.ifconfig's "*** WARNING: Bad ifconfig line: INTERFACE ..." echoes.
  printf '%s\n' "$data" | grep -iE 'INET=[0-9.]+.*MAC=[0-9a-fA-F]+' | while IFS= read -r line; do
    inet="$(sed -n 's/.*INET=\([0-9.][0-9.]*\).*/\1/p' <<<"$line")"
    mask="$(sed -n 's/.*MASK=\([0-9.][0-9.]*\).*/\1/p' <<<"$line")
    mac="$(sed -n 's/.*MAC=\([0-9a-fA-F][0-9a-fA-F]*\).*/\1/p' <<<"$line")
    [ -n "$inet" ] && [ -n "$mac" ] || continue
    cmac="$(sed 's/\(..\)/\1:/g; s/:$//' <<<"$mac" | tr 'A-F' 'a-f')"
    dev="$(ip -o link 2>/dev/null | awk -v m="$cmac" 'tolower($0) ~ m {print $2}' | sed 's/[:@].*//' | head -n1)"
    [ -n "$dev" ] || { warn "no local interface matches MAC $cmac (INET $inet)"; continue; }
    prefix="$(mask2prefix "$mask")"
    sudo ip link set dev "$dev" up || true
    if ip -o -4 addr show dev "$dev" 2>/dev/null | grep -qw "$inet"; then
      log "experiment iface $dev already has $inet/$prefix"
    else
      sudo ip addr add "$inet/$prefix" dev "$dev" && log "configured experiment iface $dev = $inet/$prefix"
    fi
  done
  return 0
}

# --- shared NFS project dir + per-swap-in run identity ---------------------
# The vwall project NFS share is auto-mounted on all nodes and persists after the
# experiment ends — the coordination bus AND the results sink.
shared_dir() {
  if [ -n "${SHARED_DIR:-}" ]; then echo "$SHARED_DIR"; return 0; fi
  local d
  for d in /groups/*/ /proj/*/; do
    [ -d "$d" ] && { echo "${d%/}"; return 0; }
  done
  return 1
}

# Experiment (slice/eid) name, identical on every node in the experiment and
# unique per swap-in — so both nodes derive the same run directory with no
# coordination. Emulab's nickname file is authoritative (vname.eid.pid); fall
# back to the FQDN only if it is missing.
experiment_name() {
  local eid
  eid="$(cut -d. -f2 /var/emulab/boot/nickname 2>/dev/null)"
  [ -n "$eid" ] && { echo "$eid"; return 0; }
  hostname -f 2>/dev/null | cut -d. -f2
}

# --- provisioning markers --------------------------------------------------
mark() { # mark <role> <STATUS>   (RF_REV, if set by bootstrap, records the pinned rev)
  sudo mkdir -p "$MARKER_DIR"
  echo "$2 $(date -u +%FT%TZ) rustiflow=${RF_REV:-?}" \
    | sudo tee "$MARKER_DIR/$1.status" >/dev/null
}
marker_status() { cat "$MARKER_DIR/$1.status" 2>/dev/null || echo "MISSING"; }

# --- check framework (used by preflight.sh) --------------------------------
declare -a _RESULTS=()
_PASS=0
_FAIL=0
ok()  { _RESULTS+=("PASS|$1|$2"); _PASS=$((_PASS+1)); }
bad() { _RESULTS+=("FAIL|$1|$2"); _FAIL=$((_FAIL+1)); }

# assert "name" "detail" <exit-status-of-a-test>  — convenience wrapper
assert() { if [ "$3" -eq 0 ]; then ok "$1" "$2"; else bad "$1" "$2"; fi; }

print_report() { # print_report <title>
  echo
  echo "============================================================"
  echo " $1"
  echo "============================================================"
  printf '%-6s %-28s %s\n' "RESULT" "CHECK" "DETAIL"
  printf '%-6s %-28s %s\n' "------" "-----" "------"
  local r name detail status
  for r in "${_RESULTS[@]}"; do
    IFS='|' read -r status name detail <<<"$r"
    printf '%-6s %-28s %s\n' "$status" "$name" "$detail"
  done
  echo "------------------------------------------------------------"
  echo " $_PASS passed, $_FAIL failed"
  echo "============================================================"
  [ "$_FAIL" -eq 0 ]
}
