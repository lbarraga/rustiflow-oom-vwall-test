#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# preflight.sh <victim|attacker>
#
# The experiment (for now): a smoke test that answers "is this testbed slice
# actually usable for RustiFlow measurements?". It checks, per node:
#
#   * kernel >= 5.8            (RustiFlow eBPF ring buffers)
#   * experiment NIC found     (carries the 10.0.1.x link address)
#   * NIC link speed           (ethtool; physical negotiation)
#   * RustiFlow deployed        (binary present, userspace runs)
#   * RustiFlow eBPF loads      (live capture on the link -> real proof on THIS kernel)
#
# and, pairwise (driven from the attacker, victim just runs an iperf3 server):
#
#   * reachability over the link   (ping the peer)
#   * effective link speed         (iperf3 ~1 Gbps end to end)
#
# USAGE (manual): on the victim first, then the attacker within ~CAP_SECS:
#   victim$   ./preflight.sh victim      # runs checks, starts iperf3 server, captures
#   attacker$ ./preflight.sh attacker    # runs checks, pings + iperf3 to victim, reports
#
# Or drive both over SSH with `just check`.
# ---------------------------------------------------------------------------
set -uo pipefail   # NOTE: no -e; checks must all run even when one fails.

ROLE="${1:?usage: preflight.sh <victim|attacker>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.env
source "$HERE/config.env"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

BIN="$RUSTIFLOW_DIR/target/release/rustiflow"

case "$ROLE" in
  victim)   SELF_IP="$VICTIM_IP";   PEER_IP="$ATTACKER_IP" ;;
  attacker) SELF_IP="$ATTACKER_IP"; PEER_IP="$VICTIM_IP" ;;
  *) die "role must be 'victim' or 'attacker'" ;;
esac

# --- 1. kernel --------------------------------------------------------------
KVER="$(kernel_mm)"
if ver_ge "$KVER" "$MIN_KERNEL"; then ok "kernel >= $MIN_KERNEL" "$(uname -r)"
else bad "kernel >= $MIN_KERNEL" "$(uname -r) — eBPF ring buffers need >= $MIN_KERNEL"; fi

# --- 2. experiment interface ------------------------------------------------
IFACE="$(iface_for_ip "${SELF_IP%.*}.")"   # match by /24 prefix, robust to the exact host octet
if [ -n "$IFACE" ]; then ok "experiment NIC" "$IFACE @ $SELF_IP"
else bad "experiment NIC" "no interface carries ${SELF_IP%.*}.x — is the link up?"; fi

# --- 3. NIC link speed (physical) -------------------------------------------
if [ -n "$IFACE" ]; then
  SPEED="$(sudo ethtool "$IFACE" 2>/dev/null | awk -F': ' '/Speed/{print $2}')"
  SNUM="$(echo "$SPEED" | grep -oE '^[0-9]+')"
  if [ -n "$SNUM" ] && [ "$SNUM" -ge $((LINK_GBPS*1000)) ]; then
    ok "NIC speed >= ${LINK_GBPS}Gb/s" "$SPEED"
  elif echo "$SPEED" | grep -qi unknown; then
    ok "NIC speed" "Unknown (tc-shaped link) — effective rate verified by iperf3"
  else
    bad "NIC speed >= ${LINK_GBPS}Gb/s" "${SPEED:-<no ethtool speed>}"
  fi
fi

# --- 4. RustiFlow deployed --------------------------------------------------
if [ -x "$BIN" ]; then
  ok "rustiflow binary" "$BIN"
  if VOUT="$("$BIN" --version 2>&1)"; then ok "rustiflow userspace runs" "$VOUT"
  else bad "rustiflow userspace runs" "$VOUT"; fi
else
  bad "rustiflow binary" "missing — run bootstrap.sh / \`just provision\`"
fi

# --- start iperf3 server on the victim so the attacker can measure ----------
if [ "$ROLE" = "victim" ]; then
  pkill -x iperf3 2>/dev/null || true
  iperf3 -s -D >/dev/null 2>&1 && ok "iperf3 server" "listening on $SELF_IP:5201" \
                               || bad "iperf3 server" "failed to start"
fi

# --- 5. RustiFlow eBPF load + live capture ----------------------------------
# Capture on the link for CAP_SECS. On the attacker we drive iperf3 during the
# window, so flows are guaranteed; on the victim, flows appear if the attacker
# runs concurrently (a bonus — an empty-but-loaded capture still proves eBPF works).
if [ -x "$BIN" ] && [ -n "$IFACE" ]; then
  RLOG="$(mktemp /tmp/rf.XXXXXX.log)"
  log "starting ${CAP_SECS}s eBPF capture on $IFACE"
  # Print mode (not CSV). rustiflow only flushes/prints on SIGINT graceful shutdown
  # (realtime.rs waits on ctrl_c), so send SIGINT (-s INT) with a generous SIGKILL
  # backstop (-k 20) — CSV+packet-graph shutdown could outrun a short backstop and
  # get killed before the counters print. Print mode also sidesteps the sticky-/tmp
  # root-create issue. RUST_LOG=info surfaces "Attached ... tc classifier" and the
  # per-hook "matched_packets=N" counters (the direct capture signal); flows print
  # to stdout. (info, not debug: debug changes realtime behaviour.)
  sudo RUST_LOG=info timeout -k 20 -s INT "$CAP_SECS" "$BIN" \
      --features basic --output print \
      --idle-timeout 5 --expiration-check-interval 2 \
      realtime "$IFACE" >"$RLOG" 2>&1 &
  RF_PID=$!

  # generate guaranteed traffic from the attacker side during the capture
  if [ "$ROLE" = "attacker" ]; then
    sleep 1
    ping -c 3 -W 2 "$PEER_IP" >/dev/null 2>&1 \
      && ok "reachability (ping)" "$PEER_IP reachable over link" \
      || bad "reachability (ping)" "$PEER_IP unreachable — check link/IPs"
    IPERF="$(iperf3 -c "$PEER_IP" -t $((CAP_SECS-4)) -f m 2>&1)"
    MBIT="$(echo "$IPERF" | awk '/receiver/{print $(NF-2)}' | tail -n1)"
    MBIT="${MBIT%.*}"
    if [ -n "$MBIT" ] && [ "$MBIT" -ge "$MIN_IPERF_MBIT" ]; then
      ok "effective link speed" "${MBIT} Mbit/s (>= $MIN_IPERF_MBIT, ~${LINK_GBPS}Gbps)"
    else
      bad "effective link speed" "${MBIT:-?} Mbit/s (want >= $MIN_IPERF_MBIT)"
    fi
  fi

  wait "$RF_PID" 2>/dev/null   # timeout ends it; exit status is expected non-zero

  # evaluate from the log, not the CSV: "Attached ... tc classifier" proves the
  # eBPF loaded+attached, and the summed matched_packets counters prove capture —
  # both independent of whether any flow expired/flushed to the CSV.
  if grep -qiE 'Failed to load eBPF|Error during realtime processing|panicked|Permission denied' "$RLOG"; then
    REASON="$(grep -iE 'Failed to load eBPF|Error during realtime processing|panicked|Permission denied' "$RLOG" | head -n1 | cut -c1-90)"
    bad "rustiflow eBPF load" "$REASON"
  elif grep -qi 'Attached IPv4 tc classifier' "$RLOG"; then
    ok "rustiflow eBPF load" "tc classifiers attached (ingress+egress)"
    MATCHED="$(grep -oE 'matched_packets=[0-9]+' "$RLOG" | awk -F= '{s+=$2} END{print s+0}')"
    FLOWS="$(grep -cE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+-' "$RLOG" 2>/dev/null || echo 0)"
    if [ "${MATCHED:-0}" -gt 0 ]; then
      ok "rustiflow live capture" "$MATCHED packets matched, $FLOWS flow(s)"
    elif [ "$ROLE" = "attacker" ]; then
      bad "rustiflow live capture" "0 packets matched despite iperf3 traffic — investigate"
    else
      ok "rustiflow live capture" "0 packets (no peer traffic in window — attach OK)"
    fi
  else
    bad "rustiflow eBPF load" "no attach confirmation in log (see below)"
  fi
  # surface the capture log on any eBPF/capture problem, BEFORE cleanup
  if grep -q FAIL <<<"${_RESULTS[*]}" && [ -f "$RLOG" ]; then
    echo "---- rustiflow capture log tail ($RLOG) ----"; tail -n 20 "$RLOG"; echo "--------------------------------------------"
  fi
  rm -f "$RLOG"
fi

# --- report -----------------------------------------------------------------
print_report "RustiFlow vwall preflight — role=$ROLE  host=$(hostname -s)  kernel=$(uname -r)"
RC=$?

# optionally persist to the project NFS share
if [ -n "$SHARED_DIR" ]; then
  mkdir -p "$SHARED_DIR" 2>/dev/null && \
  print_report "role=$ROLE host=$(hostname -s)" >"$SHARED_DIR/preflight-$ROLE.txt" 2>/dev/null && \
  log "report written to $SHARED_DIR/preflight-$ROLE.txt"
fi

exit "$RC"
