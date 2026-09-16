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
  ip -o -4 addr show 2>/dev/null | awk -v ip="$1" '$4 ~ "^"ip"/" {print $2; exit}'
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

# --- provisioning markers --------------------------------------------------
mark() { # mark <role> <STATUS>
  sudo mkdir -p "$MARKER_DIR"
  echo "$2 $(date -u +%FT%TZ) rev=$(git -C "$RUSTIFLOW_DIR" rev-parse --short HEAD 2>/dev/null || echo '?')" \
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
