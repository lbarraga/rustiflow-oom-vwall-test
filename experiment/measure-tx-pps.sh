#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# measure-tx-pps.sh [dst_ip] [duration_s] [pkt_size] [nthreads]
#
# Measure the maximum packets/sec the ATTACKER can push over the experiment link,
# using the kernel pktgen module across N CPU threads. Packets are UDP with a
# RANDOM source port (unique 5-tuples) — the same shape as the OOM flood — so this
# doubles as "how fast can we create new flows".
#
# Defaults: dst 10.0.1.1, 10 s, 60-byte frames (max pps), 4 threads.
# Run on the attacker (node1) as a normal user; it uses sudo internally.
#
# NOTE: over a 1 Gbps link, 60-byte frames cap at ~1.49 Mpps (line rate), so with
# small packets the LINK, not the CPU, is usually the ceiling. Extra cores help you
# reach line rate, not exceed it. For pure CPU-send capacity, raise pkt_size or set
# CLONE=100000 (reuses one skb — but then the source port stops varying).
# ---------------------------------------------------------------------------
set -euo pipefail

DST_IP="${1:-10.0.1.1}"
DURATION="${2:-10}"
PKT_SIZE="${3:-60}"
NTHREADS="${4:-4}"
CLONE="${CLONE:-0}"          # 0 = rebuild each packet (varies src port). >0 = faster, fixed 5-tuple.

# discover the experiment NIC by its 10.0.1.x address
DEV="$(ip -o -4 addr show 2>/dev/null | awk '$4 ~ /^10\.0\.1\./{sub(/:.*/,"",$2); print $2; exit}')"
[ -n "$DEV" ] || { echo "no interface carries 10.0.1.x — is the link up?"; exit 1; }

# resolve the peer's MAC (pktgen needs the L2 dest); ping to populate the ARP cache
ping -c1 -W1 "$DST_IP" >/dev/null 2>&1 || true
DST_MAC="$(ip neigh show "$DST_IP" 2>/dev/null | awk '/lladdr/{for(i=1;i<=NF;i++)if($i=="lladdr")print $(i+1); exit}')"
[ -n "$DST_MAC" ] || { echo "could not resolve MAC for $DST_IP (ping it first)"; exit 1; }

sudo modprobe pktgen
PG=/proc/net/pktgen
pgset() { echo "$1" | sudo tee "$2" >/dev/null; }

echo "device=$DEV  dst=$DST_IP ($DST_MAC)  threads=$NTHREADS  pkt_size=$PKT_SIZE  clone_skb=$CLONE  dur=${DURATION}s"

# clear any previous config on the threads we use
for t in $(seq 0 $((NTHREADS-1))); do pgset "rem_device_all" "$PG/kpktgend_$t"; done

# one device queue per thread
for t in $(seq 0 $((NTHREADS-1))); do
  pgset "add_device ${DEV}@${t}" "$PG/kpktgend_$t"
  D="$PG/${DEV}@${t}"
  pgset "count 0"            "$D"    # 0 = run until we stop it (by time, below)
  pgset "clone_skb $CLONE"  "$D"
  pgset "pkt_size $PKT_SIZE" "$D"
  pgset "dst $DST_IP"        "$D"
  pgset "dst_mac $DST_MAC"   "$D"
  pgset "flag QUEUE_MAP_CPU" "$D"    # pin each thread to its own TX queue
  pgset "flag UDPSRC_RND"    "$D"    # random source port -> unique 5-tuples
  pgset "udp_src_min 1"      "$D"
  pgset "udp_src_max 65535"  "$D"
  pgset "udp_dst_min 9"      "$D"
  pgset "udp_dst_max 9"      "$D"
done

# stop after DURATION, then start (start blocks until stopped)
( sleep "$DURATION"; pgset "stop" "$PG/pgctrl" ) &
echo "running..."
pgset "start" "$PG/pgctrl"

# tally
echo "=== results ==="
total=0
for t in $(seq 0 $((NTHREADS-1))); do
  line="$(sudo grep -E '^[[:space:]]*[0-9]+pps' "$PG/${DEV}@${t}" | head -1)"
  p="$(echo "$line" | grep -oE '[0-9]+pps' | tr -d 'pps')"
  printf 'thread %d (%s@%d): %s\n' "$t" "$DEV" "$t" "${line:-<no result>}"
  total=$((total + ${p:-0}))
done
mpps="$(awk -v x="$total" 'BEGIN{printf "%.3f", x/1000000}')"
echo "-------------------------------------------"
echo "TOTAL: $total pps  (${mpps} Mpps)"
