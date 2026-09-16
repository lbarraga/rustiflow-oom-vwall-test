#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# run-experiment.sh <victim|attacker>   — launched automatically by bootstrap.sh
#
# RustiFlow flow-table-exhaustion (OOM) experiment. The victim runs RustiFlow on
# the link (no memory cap, swap off) and samples its RSS + system memory + NIC
# drops until the kernel OOM-kills it. The attacker floods the victim at line rate
# with random 5-tuples (pktgen). The two nodes rendezvous via flag files on the
# NFS project share and write their CSVs there under rustiflow-oom/<slice>/<features>/.
# ---------------------------------------------------------------------------
set -uo pipefail

# ===== the one thing to change between runs: the RustiFlow feature set =====
FEATURES="rustiflow"    # basic | cic | cidds | nfstream | rustiflow

# ===== fixed experiment parameters =====
SAMPLE_SEC=0.1          # victim memory sampling period
NIC_EVERY=10            # sample NIC stats every Nth tick
MAX_SECONDS=1800        # safety cap if RustiFlow never OOMs
FLOOD_PKT_SIZE=60       # 60 -> 64B on the wire (max pps)
FLOOD_THREADS=4
FLOOD_SRC_MIN="10.0.0.0"; FLOOD_SRC_MAX="10.255.255.255"   # random spoofed source IPs

ROLE="${1:?usage: run-experiment.sh <victim|attacker>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/config.env"
source "$HERE/lib.sh"

EXP="$(experiment_name)"
SHARE="$(shared_dir || true)"
LOCAL="/local/rustiflow-oom/$EXP/$FEATURES"; mkdir -p "$LOCAL"
if [ -n "$SHARE" ]; then RUNDIR="$SHARE/rustiflow-oom/$EXP/$FEATURES"; mkdir -p "$RUNDIR"; else
  warn "no NFS share found — results stay in $LOCAL, no cross-node coordination"; RUNDIR="$LOCAL"; fi
log "experiment=$EXP features=$FEATURES role=$ROLE rundir=$RUNDIR"

BIN="$RUSTIFLOW_DIR/target/release/rustiflow"
PG=/proc/net/pktgen
case "$ROLE" in victim) SELF_IP="$VICTIM_IP";; attacker) SELF_IP="$ATTACKER_IP";; *) die "bad role";; esac

# bring up the experiment NIC (the HWE reboot leaves it down; emulab can't reapply)
ensure_experiment_iface || warn "iface config best-effort"
DEV="$(iface_for_ip "${SELF_IP%.*}.")"
[ -n "$DEV" ] || die "no experiment interface carries ${SELF_IP%.*}.x"

flag() { date -u +%FT%TZ > "$RUNDIR/$1" 2>/dev/null || true; }
# Poll for a peer flag. On NFS a repeated stat hits the cached negative dentry, so
# force a READDIR each round; wall-clock deadline (sleep can be unreliable).
wait_flag() { local f="$1" d; d=$(( $(date +%s) + ${2:-300} ))
  while :; do ls -a "$RUNDIR/" >/dev/null 2>&1; [ -e "$RUNDIR/$f" ] && return 0
    [ "$(date +%s)" -ge "$d" ] && return 1; sleep 2; done; }
nic_rx() { sudo ethtool -S "$DEV" 2>/dev/null | awk '
  /(^|[^_])rx_packets:/{p=$2} /rx_dropped:/{d=$2} /rx_missed_errors:/{m=$2}
  /rx_no_buffer_count:/{if(m=="")m=$2} END{printf "%s %s %s",p+0,d+0,m+0}'; }
pgset() { echo "$1" | sudo tee "$2" >/dev/null; }

run_victim() {
  echo -1000 | sudo tee /proc/$$/oom_score_adj >/dev/null    # never OOM-kill the sampler
  flag victim_provisioned
  log "waiting for attacker..."; wait_flag attacker_provisioned 900 || warn "attacker late — starting anyway"
  local csv="$LOCAL/victim.csv"
  echo "ts_unix,rf_rss_kb,rf_swap_kb,mem_avail_kb,mem_free_kb,swap_free_kb,rx_packets,rx_dropped,rx_missed" > "$csv"

  log "disabling swap so OOM fires at RAM exhaustion"; sudo swapoff -a 2>/dev/null || warn "swapoff failed"
  log "starting RustiFlow (features=$FEATURES) on $DEV — no memory cap"
  sudo "$BIN" --features "$FEATURES" --output print realtime "$DEV" >/dev/null 2>"$LOCAL/rf.stderr.log" &
  sleep 2
  local rfpid; rfpid="$(pgrep -x rustiflow | head -n1)"
  if [ -z "$rfpid" ]; then warn "rustiflow did not start"; cp -f "$LOCAL/rf.stderr.log" "$RUNDIR/" 2>/dev/null || true
    flag victim_ready; flag victim_done; return 1; fi
  echo 800 | sudo tee "/proc/$rfpid/oom_score_adj" >/dev/null

  { echo "experiment=$EXP"; echo "role=victim"; echo "host=$(hostname -f)"; echo "kernel=$(uname -r)";
    echo "features=$FEATURES"; echo "iface=$DEV"; echo "rf_pid=$rfpid"; echo "swap_disabled=1";
    echo "start_unix=$(date +%s)"; } > "$LOCAL/meta-victim.txt"
  flag victim_ready
  log "sampling every ${SAMPLE_SEC}s until OOM or ${MAX_SECONDS}s"

  local start; start="$(date +%s)"; local i=0 nic="0 0 0" oom=0 now rss swp ma mf sf
  while :; do
    now="$(date +%s.%N)"
    if [ -r "/proc/$rfpid/status" ]; then
      rss="$(awk '/^VmRSS:/{print $2}' "/proc/$rfpid/status" 2>/dev/null)"
      swp="$(awk '/^VmSwap:/{print $2}' "/proc/$rfpid/status" 2>/dev/null)"
    else rss=""; swp=""; fi
    read -r ma mf sf < <(awk '/^MemAvailable:/{a=$2}/^MemFree:/{f=$2}/^SwapFree:/{s=$2}END{print a,f,s}' /proc/meminfo)
    [ $((i % NIC_EVERY)) -eq 0 ] && nic="$(nic_rx)"
    echo "$now,${rss:-},${swp:-},$ma,$mf,$sf,${nic// /,}" >> "$csv"
    if [ -z "$rss" ] || ! kill -0 "$rfpid" 2>/dev/null; then oom=1; break; fi
    [ "$(printf '%.0f' "$now")" -ge "$((start + MAX_SECONDS))" ] && break
    i=$((i+1)); sleep "$SAMPLE_SEC"
  done
  local end; end="$(date +%s)"
  log "RustiFlow ended (oom_killed=$oom) after $((end-start))s"; sudo swapon -a 2>/dev/null || true

  { echo "=== dmesg (oom) ==="; dmesg 2>/dev/null | grep -iE 'out of memory|killed process|oom-kill' | tail -n 30;
  } > "$LOCAL/oom-evidence.txt"
  { echo "end_unix=$end"; echo "duration_s=$((end-start))"; echo "rf_oom_killed=$oom"; } >> "$LOCAL/meta-victim.txt"
  sync; flag victim_done
  cp -f "$csv" "$LOCAL/meta-victim.txt" "$LOCAL/oom-evidence.txt" "$LOCAL/rf.stderr.log" "$RUNDIR/" 2>/dev/null || true
  log "victim results in $RUNDIR"
}

flood_configure() {
  local dst_mac t D
  ping -c1 -W1 "$VICTIM_IP" >/dev/null 2>&1 || true
  dst_mac="$(ip neigh show "$VICTIM_IP" 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="lladdr")print $(i+1)}' | head -n1)"
  [ -n "$dst_mac" ] || die "cannot resolve MAC of $VICTIM_IP"
  sudo modprobe pktgen
  for t in $(seq 0 $((FLOOD_THREADS-1))); do pgset "rem_device_all" "$PG/kpktgend_$t"; done
  for t in $(seq 0 $((FLOOD_THREADS-1))); do
    pgset "add_device ${DEV}@${t}" "$PG/kpktgend_$t"; D="$PG/${DEV}@${t}"
    pgset "count 0" "$D"; pgset "clone_skb 0" "$D"; pgset "pkt_size $FLOOD_PKT_SIZE" "$D"
    pgset "dst $VICTIM_IP" "$D"; pgset "dst_mac $dst_mac" "$D"; pgset "flag QUEUE_MAP_CPU" "$D"
    pgset "flag IPSRC_RND" "$D"; pgset "src_min $FLOOD_SRC_MIN" "$D"; pgset "src_max $FLOOD_SRC_MAX" "$D"
    pgset "flag UDPSRC_RND" "$D"; pgset "udp_src_min 1" "$D"; pgset "udp_src_max 65535" "$D"
    pgset "flag UDPDST_RND" "$D"; pgset "udp_dst_min 1" "$D"; pgset "udp_dst_max 65535" "$D"
  done
}
pktgen_sofar() { local t s=0 n; for t in $(seq 0 $((FLOOD_THREADS-1))); do
  n="$(sudo grep -oE 'pkts-sofar: [0-9]+' "$PG/${DEV}@${t}" 2>/dev/null | awk '{print $2}' | head -n1)"
  s=$((s + ${n:-0})); done; echo "$s"; }

run_attacker() {
  echo -1000 | sudo tee /proc/$$/oom_score_adj >/dev/null
  flag attacker_provisioned
  log "waiting for victim..."; wait_flag victim_ready 900 || { warn "victim never ready — aborting"; flag attacker_done; return 1; }
  flood_configure
  local csv="$LOCAL/attacker.csv"; echo "ts_unix,total_sent,pps" > "$csv"
  { echo "experiment=$EXP"; echo "role=attacker"; echo "host=$(hostname -f)"; echo "iface=$DEV";
    echo "dst=$VICTIM_IP"; echo "pkt_size=$FLOOD_PKT_SIZE"; echo "threads=$FLOOD_THREADS";
    echo "src_range=$FLOOD_SRC_MIN-$FLOOD_SRC_MAX"; echo "start_unix=$(date +%s)"; } > "$LOCAL/meta-attacker.txt"
  log "flooding $VICTIM_IP (random 5-tuples)"
  ( echo start | sudo tee "$PG/pgctrl" >/dev/null ) &
  local start prev=0 now sent pps; start="$(date +%s)"
  while :; do
    sleep 1; now="$(date +%s)"; sent="$(pktgen_sofar)"; pps=$((sent - prev)); prev="$sent"
    echo "$now,$sent,$pps" >> "$csv"
    [ -e "$RUNDIR/victim_done" ] && { log "victim done — stopping flood"; break; }
    [ $((now - start)) -ge "$MAX_SECONDS" ] && break
  done
  echo stop | sudo tee "$PG/pgctrl" >/dev/null
  { echo "end_unix=$(date +%s)"; echo "total_sent=$(pktgen_sofar)"; } >> "$LOCAL/meta-attacker.txt"
  sync; cp -f "$csv" "$LOCAL/meta-attacker.txt" "$RUNDIR/" 2>/dev/null || true
  flag attacker_done; log "attacker results in $RUNDIR"
}

case "$ROLE" in victim) run_victim;; attacker) run_attacker;; esac
