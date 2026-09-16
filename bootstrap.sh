#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# bootstrap.sh <victim|attacker>
#
# Runs automatically at swap-in (invoked from experiment.rspec) and is safe
# to re-run by hand. It leaves the node fully built and ready:
#
#   1. enable IPv4 NAT              (internet for the steps below)
#   2. ensure kernel >= MIN_KERNEL  (Virtual Wall 2's Ubuntu 20.04 ships 5.4;
#                                    install the HWE kernel 5.15 and AUTO-REBOOT.
#                                    A one-shot systemd unit re-runs this script
#                                    after the reboot, so it stays hands-off.)
#   3. install base tools           (iperf3, ethtool, curl, git)
#   4. install Nix                  (Determinate installer, flakes on)
#   5. build RustiFlow              (flake.lock-pinned source + toolchain)
#   6. write a provisioning marker  (status READY when done)
#
# All heavy lifting lives here, in version control — the rspec only kicks it off.
# ---------------------------------------------------------------------------
set -euo pipefail

ROLE="${1:?usage: bootstrap.sh <victim|attacker>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.env
source "$HERE/config.env"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

# The systemd resume unit runs this as root with a minimal environment (no HOME,
# no USER). Nix's profile script, cargo and git all need HOME, and `set -u` would
# turn an unset HOME into a fatal error — so pin sane values up front.
export HOME="${HOME:-/root}"
export USER="${USER:-$(id -un)}"

RESUME_UNIT="rustiflow-bootstrap.service"
READY_SENTINEL="$MARKER_DIR/$ROLE.ready"

# Install a one-shot systemd unit that re-runs this script after a reboot, until
# provisioning completes (guarded by the ready sentinel so it never loops).
install_resume_unit() {
  sudo mkdir -p "$MARKER_DIR"
  sudo tee "/etc/systemd/system/$RESUME_UNIT" >/dev/null <<EOF
[Unit]
Description=rustiflow-vwall bootstrap resume (post-reboot)
After=network-online.target
Wants=network-online.target
ConditionPathExists=!$READY_SENTINEL

[Service]
Type=oneshot
Environment=HOME=/root
Environment=USER=root
ExecStart=/bin/bash -lc '$HERE/bootstrap.sh $ROLE >> /local/bootstrap.log 2>&1'
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF
  sudo systemctl daemon-reload
  sudo systemctl enable "$RESUME_UNIT" >/dev/null 2>&1 || true
}
disable_resume_unit() { sudo systemctl disable "$RESUME_UNIT" >/dev/null 2>&1 || true; }

EXP_UNIT="rustiflow-experiment.service"
# Launch the OOM experiment as its own transient-ish unit so it outlives bootstrap.
# OOMPolicy=continue: when the kernel OOM-kills RustiFlow, don't tear down the unit
# (the sampler must keep running). Not enabled for boot; a sentinel prevents reruns.
start_experiment() {
  sudo tee "/etc/systemd/system/$EXP_UNIT" >/dev/null <<EOF
[Unit]
Description=RustiFlow OOM experiment ($ROLE)
After=network-online.target
Wants=network-online.target
ConditionPathExists=!$MARKER_DIR/$ROLE.experiment-started

[Service]
Type=simple
OOMPolicy=continue
Environment=HOME=/root
ExecStartPre=/bin/touch $MARKER_DIR/$ROLE.experiment-started
ExecStart=/bin/bash -lc '$HERE/run-experiment.sh $ROLE >> /local/experiment.log 2>&1'

[Install]
WantedBy=multi-user.target
EOF
  sudo systemctl daemon-reload
  sudo systemctl start "$EXP_UNIT" >/dev/null 2>&1 || true
  log "OOM experiment launched ($EXP_UNIT) — see /local/experiment.log"
}

trap 'mark "$ROLE" FAILED; die "bootstrap failed (see output above / /local/bootstrap.log)"' ERR

mark "$ROLE" PROVISIONING

# 1. internet -----------------------------------------------------------------
enable_nat

# 2. kernel gate --------------------------------------------------------------
# RustiFlow's eBPF ring buffers need kernel >= MIN_KERNEL. Wall2's Ubuntu 20.04
# boots 5.4, so upgrade to the HWE kernel and reboot into it automatically.
if ! ver_ge "$(kernel_mm)" "$MIN_KERNEL"; then
  log "kernel $(uname -r) < $MIN_KERNEL — installing HWE kernel and auto-rebooting"
  sudo apt-get update -y
  sudo apt-get install -y linux-generic-hwe-20.04
  install_resume_unit
  mark "$ROLE" REBOOTING
  log "rebooting into HWE kernel; provisioning resumes automatically after boot"
  sudo systemctl reboot
  exit 0
fi
log "kernel $(uname -r) satisfies >= $MIN_KERNEL"

# 2b. experiment interface ----------------------------------------------------
# The HWE-kernel reboot leaves emulab's experiment NIC down/unaddressed; reassert
# it from the testbed's own interface data (best-effort, idempotent).
ensure_experiment_iface || warn "experiment iface config was best-effort only"

# 3. base tools ---------------------------------------------------------------
log "installing base packages"
sudo apt-get update -y
sudo apt-get install -y git iperf3 ethtool curl xz-utils ca-certificates

# 4. Nix ----------------------------------------------------------------------
if ! command -v nix >/dev/null 2>&1; then
  log "installing Nix (Determinate)"
  curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix \
    | sh -s -- install linux --no-confirm --init systemd
fi
# make nix available in this non-login shell (the profile script references $HOME
# and other unset vars, so relax `set -u` just around the source)
if [ -f /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]; then
  set +u
  # shellcheck disable=SC1091
  source /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
  set -u
fi
command -v nix >/dev/null 2>&1 || die "nix not on PATH after install"

# The harness repo was cloned by the swap-in user; the build runs as root, so git
# would refuse the flake dir as "dubious ownership". Whitelist it (needs HOME set).
git config --global --add safe.directory "$VWALL_DIR" 2>/dev/null || true

# 5. RustiFlow ----------------------------------------------------------------
# Source revision is pinned in flake.lock (the `rustiflow` input); resolve it to
# a store path and copy it out to a writable tree (cargo needs to write there).
log "resolving pinned RustiFlow source from flake.lock"
RF_STORE="$(nix build "$VWALL_DIR#rustiflow-src" --no-link --print-out-paths)"
RF_REV="$(cat "$(nix build "$VWALL_DIR#rustiflow-rev" --no-link --print-out-paths)")"
export RF_REV
log "RustiFlow pinned at rev $RF_REV"

rm -rf "$RUSTIFLOW_DIR"
mkdir -p "$(dirname "$RUSTIFLOW_DIR")"
cp -rT --no-preserve=mode,ownership "$RF_STORE" "$RUSTIFLOW_DIR"

log "building RustiFlow (eBPF + userspace) in the pinned toolchain shell — this can take a while"
( cd "$RUSTIFLOW_DIR"
  nix develop "$VWALL_DIR#rustiflow" --command bash -lc '
    set -euo pipefail
    # eBPF objects MUST match the userspace profile: the release binary loads them
    # from target/bpfel-unknown-none/release/ (see ebpf_binary_path in realtime.rs).
    cargo xtask ebpf-ipv4 --release
    cargo xtask ebpf-ipv6 --release
    cargo build --release
  '
)
test -x "$RUSTIFLOW_DIR/target/release/rustiflow" \
  || die "rustiflow binary missing after build"

# 6. done ---------------------------------------------------------------------
sudo touch "$READY_SENTINEL"      # stops the resume unit from ever running again
disable_resume_unit
mark "$ROLE" READY
log "READY — role=$ROLE  kernel=$(uname -r)  rustiflow=$RUSTIFLOW_DIR/target/release/rustiflow"

# 7. kick off the experiment (self-coordinates with the peer via the NFS share) ---
start_experiment
