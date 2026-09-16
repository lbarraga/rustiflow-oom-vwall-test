# rustiflow-vwall

Reproducible two-node [RustiFlow](https://github.com/idlab-discover/RustiFlow)
experiments on the imec [Virtual Wall](https://doc.ilabt.imec.be/ilabt/virtualwall/).
Two bare-metal nodes, one dedicated 1 Gbps link, everything declarative — no
"swap in the nodes, then SSH in and do stuff by hand".

**Current experiment: a preflight smoke test.** It does not yet measure anything;
it answers *"is this slice actually usable for RustiFlow measurements?"* — RustiFlow
builds and its eBPF loads on the node kernel, the two nodes reach each other over
the link, kernels are new enough, and the link really runs at ~1 Gbps. This is the
foundation the real throughput / packet-loss experiments get built on next.

## How it fits together (three layers)

| Layer | Owned by | Artifact |
|---|---|---|
| **Provision** 2 nodes + 1 Gbps link | GENI RSpec / jFed | [`rspec/preflight.rspec`](rspec/preflight.rspec) |
| **Configure** each node identically | `bootstrap.sh` + **Nix** | [`bootstrap.sh`](bootstrap.sh) + [`flake.lock`](flake.lock) |
| **Run** the smoke test | `preflight.sh` + `just` | [`preflight.sh`](preflight.sh), [`justfile`](justfile) |

The Virtual Wall has no Terraform/Nix provider — provisioning goes through the GENI
Aggregate Manager, whose declarative artifact is the RSpec. So the RSpec is a
committed file, swapped in headlessly. Nix owns the *middle* layer: this repo's
[`flake.lock`](flake.lock) pins **both** the exact RustiFlow source revision (the
`rustiflow` input) **and** the build toolchain (nightly + `bpf-linker`), and
`bootstrap.sh` builds that pinned source on the node. The RSpec's `<services>` block
is deliberately thin — it only clones this repo and calls `bootstrap.sh`; all real
logic is version-controlled here.

### How RustiFlow is pinned

RustiFlow is a **flake input**, so its commit is recorded in `flake.lock` — not a
mutable `git checkout main`. Bump it with `nix flake update rustiflow` (or point the
input at your own fork/branch in `flake.nix` and re-lock), then commit `flake.lock`.

It is a *source-only* input (`flake = false`) because RustiFlow upstream ships no
`flake.nix`, so this repo's flake owns the build toolchain (kept in sync with
RustiFlow's local dev flake). We deliberately do **not** package RustiFlow as a
`nix build .#rustiflow` derivation: its eBPF build needs `-Z build-std=core` +
`bpf-linker` + an `xtask` that embeds the compiled eBPF into the userspace binary,
which upstream builds via a devShell, not a package. `bootstrap.sh` copies the
lockfile-pinned source to a writable tree and builds it in that same pinned shell.

## Quick start

1. **Push this repo** somewhere the nodes can reach, and set the URL in two places:
   - `VWALL_REPO` in [`config.env`](config.env)
   - the `git clone …` URLs in [`rspec/preflight.rspec`](rspec/preflight.rspec) (both nodes)

   (The RustiFlow revision is already pinned in `flake.lock` — see *How RustiFlow
   is pinned* above; `nix flake update rustiflow` to bump it.)

2. **Swap in** the topology — load `rspec/preflight.rspec` in the jFed GUI and hit
   Run, or `just up` if you have the jFed CLI. At swap-in each node self-provisions
   (NAT → Nix → build RustiFlow); first build takes ~10–20 min. Track it with
   `just wait victim=… attacker=…` or by tailing `/local/bootstrap.log` on a node.

3. **Run the smoke test:**
   ```
   just check victim=me@node0host attacker=me@node1host
   ```
   (SSH targets come from the jFed manifest.) Or run it manually — `just manual`
   prints the two-terminal sequence.

## What a healthy run looks like

```
============================================================
 RustiFlow vwall preflight — role=attacker  host=n081-02  kernel=5.15.0-...
============================================================
RESULT CHECK                        DETAIL
------ -----                        ------
PASS   kernel >= 5.8                5.15.0-...
PASS   experiment NIC               eth1 @ 10.0.1.2
PASS   NIC speed >= 1Gb/s           1000Mb/s
PASS   rustiflow binary             /local/RustiFlow/target/release/rustiflow
PASS   rustiflow userspace runs     rustiflow 0.x.y
PASS   reachability (ping)          10.0.1.1 reachable over link
PASS   effective link speed         941 Mbit/s (>= 850, ~1Gbps)
PASS   rustiflow eBPF load          capture ran, CSV written
PASS   rustiflow live capture       37 flow record(s)
------------------------------------------------------------
 9 passed, 0 failed
============================================================
```

The `rustiflow eBPF load` / `live capture` checks are the important ones: they run
a real capture on the link and prove RustiFlow's eBPF programs load and process
packets *on this node's kernel* — the thing most likely to break on a testbed image.

## Design decisions

- **Virtual Wall 2 + Ubuntu 20.04, with an automated kernel upgrade.** RustiFlow's
  ring buffers need kernel ≥ 5.8. Wall2 has no `UBUNTU22`/`UBUNTU24` image, and
  wall1 (which has 24.04) is chronically full — so we stay on wall2's 20.04
  (kernel 5.4) and let `bootstrap.sh` install the HWE kernel (5.15) and **reboot
  the node itself**, resuming provisioning through a one-shot systemd unit. No
  manual reboot; the only visible effect is that a node takes one extra reboot
  cycle to reach `READY`.
- **1 Gbps is declarative** via `<property capacity="1000000">` on the link — no
  hand-run `tc`.
- **Interface discovery by IP**, not a hardcoded `ethX` — vwall interface names vary
  per swap-in.
- **On-node Nix build** so the eBPF objects match the running kernel, with both
  the RustiFlow source revision and the toolchain pinned by this repo's `flake.lock`.

## Files

```
config.env              all tunables (repo URLs, IPs, thresholds)
rspec/preflight.rspec   2 nodes + 1 Gbps link, thin bootstrap hook
bootstrap.sh            swap-in provisioning (NAT, Nix, build RustiFlow)
preflight.sh            the smoke test (kernel, reachability, link speed, eBPF)
lib.sh                  shared helpers + PASS/FAIL check framework
justfile                operator commands (up / wait / check / down / lint)
flake.nix               harness devshell (just, jq, iperf, shellcheck)
```

## Next steps (not built yet)

Swap `preflight.sh` for a real scenario behind the same provisioning: a
`tcpreplay`-driven throughput/packet-loss sweep at controlled rates (comparable to
the RustiFlow paper's methodology), reading RustiFlow's eBPF ring-buffer drop
counters as ground-truth loss, with `pidstat`/`dstat` for CPU+RSS. The OOM /
flow-table stress scenario is a separate selectable experiment.
