#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# summarize.sh [experiment]
#
# Print a quick summary of an OOM experiment's CSVs (time-to-OOM, peak RSS,
# packets sent, drops). Run on a node that has the NFS share mounted; with no
# argument it uses this node's experiment name, else pass a slice name.
# ---------------------------------------------------------------------------
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=../config.env
source "$ROOT/config.env"
# shellcheck source=../lib.sh
source "$ROOT/lib.sh"

# RUN may be "<exp>" or "<exp>/<featureset>" (runs are stored per feature set).
RUN="${1:-$(experiment_name)}"
SHARE="$(shared_dir 2>/dev/null || true)"
list_runs() { find "$SHARE/rustiflow-oom" /local/rustiflow-oom -name victim.csv 2>/dev/null \
  | sed 's#.*/rustiflow-oom/##; s#/victim.csv##' | sort -u | sed 's/^/  /'; }
D=""
for base in "$SHARE" /local; do
  [ -n "$base" ] && [ -f "$base/rustiflow-oom/$RUN/victim.csv" ] && { D="$base/rustiflow-oom/$RUN"; break; }
done
if [ -z "$D" ]; then
  echo "no results for run '$RUN'."
  echo "available runs (pass one as the argument):"; list_runs
  exit 1
fi

echo "======================================================"
echo " RustiFlow OOM experiment: $RUN"
echo " $D"
echo "======================================================"

[ -f "$D/meta-victim.txt" ]   && { echo "[victim meta]";   sed 's/^/  /' "$D/meta-victim.txt"; echo; }

if [ -f "$D/victim.csv" ]; then
  awk -F, 'NR>1{
    if($2!=""){ if(rss0=="")rss0=$2; rss=$2; if($2+0>peak)peak=$2 }
    if(t0=="")t0=$1; t1=$1
    if($7!=""){ if(rxp0=="")rxp0=$7; rxp1=$7 } if($8!="")rxd=$8; if($9!="")rxm=$9
    n++
  } END{
    printf "[victim RustiFlow memory]\n"
    printf "  samples          : %d\n", n
    printf "  peak RSS         : %.1f MB\n", peak/1024
    printf "  RSS at end       : %.1f MB\n", rss/1024
    printf "  wall duration    : %.1f s\n", t1-t0
    if(t1>t0) printf "  avg growth rate  : %.1f MB/s (peak/duration)\n", (peak/1024)/(t1-t0)
    printf "  NIC rx_packets Δ : %d\n", (rxp1+0)-(rxp0+0)
    printf "  NIC rx_dropped   : %s   rx_missed: %s\n", rxd, rxm
    print ""
  }' "$D/victim.csv"
fi

if [ -f "$D/attacker.csv" ]; then
  awk -F, 'NR>1{ sent=$2; if($3+0>peak)peak=$3; if(t0=="")t0=$1; t1=$1 } END{
    printf "[attacker flood]\n"
    printf "  packets sent     : %s\n", sent
    printf "  peak pps         : %s\n", peak
    if(t1>t0) printf "  avg pps          : %.0f\n", sent/(t1-t0)
    print ""
  }' "$D/attacker.csv"
fi

# rough loss estimate: sent vs what reached the victim NIC
if [ -f "$D/attacker.csv" ] && [ -f "$D/victim.csv" ]; then
  SENT=$(awk -F, 'NR>1{s=$2}END{print s+0}' "$D/attacker.csv")
  RXD=$(awk -F, 'NR>1 && $7!=""{if(a=="")a=$7;b=$7}END{print (b+0)-(a+0)}' "$D/victim.csv")
  if [ "${SENT:-0}" -gt 0 ]; then
    awk -v s="$SENT" -v r="$RXD" 'BEGIN{
      printf "[loss estimate]\n"
      printf "  sent (attacker)     : %d\n", s
      printf "  arrived at NIC (Δ)  : %d\n", r
      printf "  not counted at NIC  : %d  (%.1f%%)\n", s-r, (s>0?100*(s-r)/s:0)
      print "  (rx_dropped/rx_missed above = NIC drops when the host couldn'\''t drain)"
      print ""
    }'
  fi
fi

echo "[OOM evidence]"
grep -iE 'killed process|out of memory|oom-kill' "$D/oom-evidence.txt" 2>/dev/null | tail -n 4 | sed 's/^/  /' \
  || echo "  (none captured — RustiFlow may not have OOMed within the time cap)"
