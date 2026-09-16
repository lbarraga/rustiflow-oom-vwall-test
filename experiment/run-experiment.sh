#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# run-experiment.sh <victim|attacker>
#
# Fully automatic RustiFlow flow-table-exhaustion (OOM) experiment. Launched by
# bootstrap.sh after a node reaches READY; the two nodes self-coordinate through
# flag files on the NFS project share and write their results there as CSVs.
#
#   victim (node0):   runs RustiFlow (as intended, NO memory cap) on the link,
#                     samples RustiFlow RSS + system memory + NIC drops to a local
#                     CSV at high rate, waits for RustiFlow to be OOM-killed (or a
#                     time cap), captures the kernel OOM evidence, then copies
#                     everything to the share.
#   attacker (node1): floods the victim at line rate with random 5-tuples
#                     (pktgen), samples packets-sent/pps, stops when the victim is
#                     done, copies its CSV to the share.
#
# Survival design (no cap): the sampler protects itself with oom_score_adj=-1000
# so the kernel kills RustiFlow (the big hog), never the sampler; samples go to
# LOCAL disk during the run and are published to the (memory-hungry) NFS share
# only AFTER RustiFlow dies and memory is freed.
# ---------------------------------------------------------------------------
set -uo pipefail

ROLE="${1:?usage: run-experiment.sh <victim|attacker>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=../config.env
source "$ROOT/config.env"
# shellcheck source=../lib.sh
source "$ROOT/lib.sh"

EXP="$(experiment_name)"
SHARE="$(shared_dir || true)"
LOCAL="/local/rustiflow-oom/$EXP"
mkdir -p "$LOCAL"
if [ -n "$SHARE" ]; then RUNDIR="$SHARE/rustiflow-oom/$EXP"; mkdir -p "$RUNDIR"; else
  warn "no NFS share found — results stay in $LOCAL, and cross-node coordination is unavailable"
  RUNDIR="$LOCAL"
fi
log "experiment=$EXP role=$ROLE rundir=$RUNDIR"

BIN="$RUSTIFLOW_DIR/target/release/rustiflow"
PG=/proc/net/pktgen

case "$ROLE" in
  victim)   SELF_IP="$VICTIM_IP" ;;
  attacker) SELF_IP="$ATTACKER_IP" ;;
  *) die "role must be victim or attacker" ;;
esac
# configure the experiment NIC ourselves (don't depend on bootstrap having done it;
# the HWE-reboot leaves it down and emulab's rc.ifconfig can't reapply it)
ensure_experiment_iface || warn "experiment iface config was best-effort only"
DEV="$(iface_for_ip "${SELF_IP%.*}.")"
[ -n "$DEV" ] || die "no experiment interface carries ${SELF_IP%.*}.x (iface config failed)"

# --- flag helpers (coordination via the shared dir) ------------------------
flag()      { date -u +%FT%TZ > "$RUNDIR/$1" 2>/dev/null || true; }
wait_flag() { local f="$1" max="${2:-300}" i=0; until [ -e "$RUNDIR/$f" ]; do
                sleep 1; i=$((i+1)); [ "$i" -ge "$max" ] && return 1; done; }

nic_rx() { # -> "rx_packets rx_dropped rx_missed"
  sudo ethtool -S "$DEV" 2>/dev/null | awk '
    /(^|[^_])rx_packets:/{p=$2}
    /rx_dropped:/{d=$2}
    /rx_missed_errors:/{m=$2}
    /rx_no_buffer_count:/{if(m=="")m=$2}
    END{printf "%s %s %s", p+0, d+0, m+0}'
}

# ===========================================================================
run_victim() {
  echo -1000 | sudo tee /proc/$$/oom_score_adj >/dev/null   # never OOM-kill the sampler
  flag victim_provisioned
  log "waiting for the attacker to finish provisioning..."
  wait_flag attacker_provisioned 900 || warn "attacker not provisioned in time — starting anyway"
  local csv="$LOCAL/victim.csv"
  echo "ts_unix,rf_rss_kb,rf_swap_kb,mem_avail_kb,mem_free_kb,swap_free_kb,rx_packets,rx_dropped,rx_missed" > "$csv"

  log "starting RustiFlow (features=$EXP_FEATURES) on $DEV — as intended, no memory cap"
  sudo "$BIN" --features "$EXP_FEATURES" --output print realtime "$DEV" \
      >/dev/null 2>"$LOCAL/rf.stderr.log" &
  sleep 2
  local rfpid; rfpid="$(pgrep -x rustiflow | head -n1)"
  if [ -z "$rfpid" ]; then
    warn "rustiflow did not start"; cp -f "$LOCAL/rf.stderr.log" "$RUNDIR/" 2>/dev/null || true
    flag victim_ready; flag victim_done; return 1
  fi
  echo 800 | sudo tee "/proc/$rfpid/oom_score_adj" >/dev/null   # prefer to kill RustiFlow

  { echo "experiment=$EXP"; echo "role=victim"; echo "host=$(hostname -f)";
    echo "kernel=$(uname -r)"; echo "features=$EXP_FEATURES"; echo "iface=$DEV";
    echo "rf_pid=$rfpid"; echo "start_unix=$(date +%s)";
  } > "$LOCAL/meta-victim.txt"

  flag victim_ready
  log "sampling every ${VICTIM_SAMPLE_SEC}s until RustiFlow OOMs or ${EXP_MAX_SECONDS}s elapses"

  local start; start="$(date +%s)"
  local i=0 nic="0 0 0" oom=0 now rss swp ma mf sf
  while :; do
    now="$(date +%s.%N)"
    if [ -r "/proc/$rfpid/status" ]; then
      rss="$(awk '/^VmRSS:/{print $2}' "/proc/$rfpid/status" 2>/dev/null)"
      swp="$(awk '/^VmSwap:/{print $2}' "/proc/$rfpid/status" 2>/dev/null)"
    else rss=""; swp=""; fi
    read -r ma mf sf < <(awk '/^MemAvailable:/{a=$2}/^MemFree:/{f=$2}/^SwapFree:/{s=$2}END{print a,f,s}' /proc/meminfo)
    [ $((i % NIC_SAMPLE_EVERY)) -eq 0 ] && nic="$(nic_rx)"
    echo "$now,${rss:-},${swp:-},$ma,$mf,$sf,${nic// /,}" >> "$csv"

    if [ -z "$rss" ] || ! kill -0 "$rfpid" 2>/dev/null; then oom=1; break; fi
    [ "$(printf '%.0f' "$now")" -ge "$((start + EXP_MAX_SECONDS))" ] && break
    i=$((i+1)); sleep "$VICTIM_SAMPLE_SEC"
  done
  local end; end="$(date +%s)"
  log "RustiFlow ended (oom_killed=$oom) after $((end-start))s"

  { echo "=== dmesg (oom) ==="; dmesg 2>/dev/null | grep -iE 'out of memory|killed process|oom-kill' | tail -n 30;
    echo "=== journal -k (oom) ==="; journalctl -k --no-pager 2>/dev/null | grep -iE 'out of memory|killed process|oom-kill' | tail -n 30;
  } > "$LOCAL/oom-evidence.txt"
  { echo "end_unix=$end"; echo "duration_s=$((end-start))"; echo "rf_oom_killed=$oom";
    echo "rf_exit_rss_kb=$(awk -F, 'END{print $2}' "$csv")";
  } >> "$LOCAL/meta-victim.txt"

  sync
  flag victim_done
  cp -f "$csv" "$LOCAL/meta-victim.txt" "$LOCAL/oom-evidence.txt" "$LOCAL/rf.stderr.log" "$RUNDIR/" 2>/dev/null || true
  log "victim results published to $RUNDIR"
}

# ===========================================================================
pgset() { echo "$1" | sudo tee "$2" >/dev/null; }

flood_configure() {
  local dst_ip="$VICTIM_IP" dst_mac t D
  ping -c1 -W1 "$dst_ip" >/dev/null 2>&1 || true
  dst_mac="$(ip neigh show "$dst_ip" 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="lladdr")print $(i+1)}' | head -n1)"
  [ -n "$dst_mac" ] || die "cannot resolve MAC of $dst_ip"
  echo "$dst_mac" > "$LOCAL/flood-dstmac.txt"
  sudo modprobe pktgen
  for t in $(seq 0 $((FLOOD_THREADS-1))); do pgset "rem_device_all" "$PG/kpktgend_$t"; done
  for t in $(seq 0 $((FLOOD_THREADS-1))); do
    pgset "add_device ${DEV}@${t}" "$PG/kpktgend_$t"; D="$PG/${DEV}@${t}"
    pgset "count 0"                 "$D"
    pgset "clone_skb 0"             "$D"     # rebuild each packet so fields vary
    pgset "pkt_size $FLOOD_PKT_SIZE" "$D"
    pgset "dst $dst_ip"             "$D"
    pgset "dst_mac $dst_mac"        "$D"
    pgset "flag QUEUE_MAP_CPU"      "$D"
    pgset "flag IPSRC_RND"          "$D"; pgset "src_min $FLOOD_SRC_MIN" "$D"; pgset "src_max $FLOOD_SRC_MAX" "$D"
    pgset "flag UDPSRC_RND"         "$D"; pgset "udp_src_min 1" "$D"; pgset "udp_src_max 65535" "$D"
    pgset "flag UDPDST_RND"         "$D"; pgset "udp_dst_min 1" "$D"; pgset "udp_dst_max 65535" "$D"
  done
}

pktgen_sofar() { local t s=0 n; for t in $(seq 0 $((FLOOD_THREADS-1))); do
  n="$(sudo grep -oE 'pkts-sofar: [0-9]+' "$PG/${DEV}@${t}" 2>/dev/null | awk '{print $2}' | head -n1)"
  s=$((s + ${n:-0})); done; echo "$s"; }

run_attacker() {
  echo -1000 | sudo tee /proc/$$/oom_score_adj >/dev/null
  flag attacker_provisioned
  log "waiting for victim to start RustiFlow..."
  wait_flag victim_ready 900 || { warn "victim never became ready — aborting flood"; flag attacker_done; return 1; }

  flood_configure
  local csv="$LOCAL/attacker.csv"; echo "ts_unix,total_sent,pps" > "$csv"
  { echo "experiment=$EXP"; echo "role=attacker"; echo "host=$(hostname -f)";
    echo "iface=$DEV"; echo "dst=$VICTIM_IP"; echo "pkt_size=$FLOOD_PKT_SIZE";
    echo "threads=$FLOOD_THREADS"; echo "src_range=$FLOOD_SRC_MIN-$FLOOD_SRC_MAX";
    echo "start_unix=$(date +%s)"; } > "$LOCAL/meta-attacker.txt"

  log "starting pktgen flood -> $VICTIM_IP (random 5-tuples)"
  ( echo start | sudo tee "$PG/pgctrl" >/dev/null ) &     # blocks until stopped

  local start prev=0 now sent pps
  start="$(date +%s)"
  while :; do
    sleep 1; now="$(date +%s)"; sent="$(pktgen_sofar)"; pps=$((sent - prev)); prev="$sent"
    echo "$now,$sent,$pps" >> "$csv"
    [ -e "$RUNDIR/victim_done" ] && { log "victim done — stopping flood"; break; }
    [ $((now - start)) -ge "$EXP_MAX_SECONDS" ] && { warn "time cap reached"; break; }
  done
  echo stop | sudo tee "$PG/pgctrl" >/dev/null

  { echo "end_unix=$(date +%s)"; echo "total_sent=$(pktgen_sofar)"; } >> "$LOCAL/meta-attacker.txt"
  { local t; for t in $(seq 0 $((FLOOD_THREADS-1))); do
      echo "--- ${DEV}@${t} ---"; sudo grep -E 'pps|sofar|errors' "$PG/${DEV}@${t}" 2>/dev/null; done
  } > "$LOCAL/flood-final.txt"

  sync
  cp -f "$csv" "$LOCAL/meta-attacker.txt" "$LOCAL/flood-final.txt" "$RUNDIR/" 2>/dev/null || true
  flag attacker_done
  log "attacker results published to $RUNDIR"
}

case "$ROLE" in
  victim)   run_victim ;;
  attacker) run_attacker ;;
esac
