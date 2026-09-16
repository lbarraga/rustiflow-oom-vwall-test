# RustiFlow OOM experiment

A fully automatic flow-table-exhaustion experiment. **You only deploy the RSpec** —
both nodes self-provision, self-coordinate over the NFS project share, run the
experiment, and drop CSVs on the share. Nothing to run by hand.

## What happens

1. Swap in `rspec/preflight.rspec` (two nodes). Each self-provisions via `bootstrap.sh`.
2. When a node reaches `READY`, `bootstrap.sh` starts `rustiflow-experiment.service`,
   which runs `experiment/run-experiment.sh <role>`.
3. The nodes rendezvous through flag files on the share (`<share>/rustiflow-oom/<exp>/`):
   - **attacker** builds the pktgen flood, waits for the victim.
   - **victim** starts RustiFlow (`--features basic`, **no memory cap**) on the link,
     drops `oom_score_adj=-1000` on the sampler (so the kernel kills RustiFlow, never
     the sampler), and samples RSS + memory + NIC drops to **local disk** every 100 ms.
   - **attacker** floods at line rate (~1.49 Mpps) with **random src IP + src/dst port**
     → a huge unique-5-tuple space → RustiFlow's flow table grows without bound.
   - RustiFlow eventually gets **OOM-killed**; the sampler survives, records the moment,
     grabs the kernel OOM evidence, and — now that memory is free — copies everything
     to the share.
4. `EXP_MAX_SECONDS` (default 900 s) caps the run if RustiFlow never OOMs.

## Where the results land

`<share>/rustiflow-oom/<experiment>/` (share auto-discovered under `/groups/*` or
`/proj/*`; `<experiment>` is the slice name, e.g. `rfoom4`):

| file | from | contents |
|---|---|---|
| `victim.csv` | node0 | per-tick `ts_unix, rf_rss_kb, rf_swap_kb, mem_avail_kb, mem_free_kb, swap_free_kb, rx_packets, rx_dropped, rx_missed` |
| `meta-victim.txt` | node0 | kernel, features, RF pid, start/end, `rf_oom_killed`, RSS at exit |
| `oom-evidence.txt` | node0 | the `dmesg`/journal OOM-kill lines (RSS at death, timestamp) |
| `rf.stderr.log` | node0 | RustiFlow's stderr |
| `attacker.csv` | node1 | per-second `ts_unix, total_sent, pps` |
| `meta-attacker.txt` | node1 | flood params, total packets sent |
| `flood-final.txt` | node1 | final per-thread pktgen pps/sofar/errors |

## Reading it

- **Memory-to-OOM curve:** plot `rf_rss_kb` vs `ts_unix` from `victim.csv` — the growth
  rate and the RSS ceiling at the kill. `meta-victim.txt`/`oom-evidence.txt` give the
  exact OOM point.
- **Offered load:** `attacker.csv` `pps` / `total_sent` — what was thrown at the victim.
- **Where it drops:** compare attacker `total_sent` vs victim `rx_packets` (arrived) and
  `rx_dropped`/`rx_missed` (NIC couldn't drain) — the host-side loss as memory fills.
- **Time-to-OOM vs config:** re-run varying `EXP_FEATURES` (bigger records → faster OOM)
  in `config.env`, redeploy, compare.

## Knobs (`config.env`)

- `RUN_EXPERIMENT=0` — provision only, don't auto-run (e.g. to run the preflight instead).
- `EXP_FEATURES` — `basic | cic | cidds | nfstream | rustiflow` (record size → OOM speed).
- `EXP_MAX_SECONDS`, `VICTIM_SAMPLE_SEC`, `FLOOD_*`.

## Notes / caveats

- **Sample locally, publish after OOM.** CSVs are written to `/local` during the run and
  copied to the NFS share only after RustiFlow dies — NFS writes can block under memory
  pressure, so we don't rely on them mid-run.
- RustiFlow only flushes *flows* on SIGINT, but this experiment cares about the flow
  *table* (memory), which the sampler reads live — so a hard OOM loses no measurement.
- On the vwall NICs only the **ingress** tc hook captures; the victim is the ingress side
  of the flood, so that's the path that matters here.
- The flood uses spoofed random source IPs (L2-delivered by dst MAC) — it stays on the
  isolated experiment VLAN.
