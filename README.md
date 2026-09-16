# rustiflow-vwall

Two-node RustiFlow flow-table-exhaustion (OOM) experiment on the imec Virtual Wall.
Deploy the RSpec; both nodes self-provision, run the experiment, and write CSVs to
the NFS project share.

## Run

1. Push this repo to a **public** URL and set it in `experiment.rspec` (the two
   `git clone` lines) — the nodes clone it at swap-in.
2. Pick the feature set: edit `FEATURES` at the top of `run-experiment.sh`
   (`basic | cic | cidds | nfstream | rustiflow`).
3. In jFed, load `experiment.rspec` and swap in on **Virtual Wall 2**. Wait ~15–25 min
   (installs the HWE kernel + reboots, builds RustiFlow via Nix, floods, and OOMs).

## Results

CSVs land in `<project-share>/rustiflow-oom/<slice>/<features>/`:
`victim.csv` (RustiFlow RSS, system memory and NIC drops over time), `attacker.csv`
(packets sent / pps), plus `meta-*.txt` and `oom-evidence.txt`. Pull them:

    scp -r -P 22 -i <key> -oProxyCommand="ssh -i <key> <user>@bastion.ilabt.imec.be -W %h:%p" \
      <user>@<node>.wall2.ilabt.iminds.be:/proj/<project>/rustiflow-oom/<slice> ./results

## Files

    experiment.rspec   two nodes + 1 GbE link; clones this repo and runs bootstrap.sh
    bootstrap.sh       per-node setup: NAT, HWE kernel + reboot, Nix, build RustiFlow, launch
    run-experiment.sh  the experiment (edit FEATURES at the top)
    lib.sh, config.env helpers and shared paths
    flake.nix/.lock    pins the RustiFlow build (source revision + toolchain)
