#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# bootstrap.sh <victim|attacker>
#
# Runs automatically at swap-in (invoked from rspec/preflight.rspec) and is safe
# to re-run by hand (`just provision`). It leaves the node fully built and ready:
#
#   1. enable IPv4 NAT              (internet for the steps below)
#   2. install base tools           (iperf3, ethtool, curl, git)
#   3. install Nix                  (Determinate installer, flakes on)
#   4. clone + build RustiFlow      (its own pinned flake -> reproducible toolchain)
#   5. write a provisioning marker  (so `just wait` / preflight know it is ready)
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

trap 'mark "$ROLE" FAILED; die "bootstrap failed (see output above / /local/bootstrap.log)"' ERR

mark "$ROLE" PROVISIONING

# 1. internet -----------------------------------------------------------------
enable_nat

# 2. base tools ---------------------------------------------------------------
log "installing base packages"
sudo apt-get update -y
sudo apt-get install -y git iperf3 ethtool curl xz-utils ca-certificates

# 3. Nix ----------------------------------------------------------------------
if ! command -v nix >/dev/null 2>&1; then
  log "installing Nix (Determinate)"
  curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix \
    | sh -s -- install linux --no-confirm --init systemd
fi
# make nix available in this non-login shell
if [ -f /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]; then
  # shellcheck disable=SC1091
  source /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
fi
command -v nix >/dev/null 2>&1 || die "nix not on PATH after install"

# 4. RustiFlow ----------------------------------------------------------------
log "fetching RustiFlow ($RUSTIFLOW_REPO @ $RUSTIFLOW_REV)"
mkdir -p "$(dirname "$RUSTIFLOW_DIR")"
if [ ! -d "$RUSTIFLOW_DIR/.git" ]; then
  git clone "$RUSTIFLOW_REPO" "$RUSTIFLOW_DIR"
fi
git -C "$RUSTIFLOW_DIR" fetch --all --tags -q
git -C "$RUSTIFLOW_DIR" checkout -q "$RUSTIFLOW_REV"

log "building RustiFlow (eBPF + userspace) via its pinned flake — this can take a while"
( cd "$RUSTIFLOW_DIR"
  nix develop --command bash -lc '
    set -euo pipefail
    cargo xtask ebpf-ipv4
    cargo xtask ebpf-ipv6
    cargo build --release
  '
)
test -x "$RUSTIFLOW_DIR/target/release/rustiflow" \
  || die "rustiflow binary missing after build"

# 5. done ---------------------------------------------------------------------
mark "$ROLE" READY
log "READY — role=$ROLE  kernel=$(uname -r)  rustiflow=$RUSTIFLOW_DIR/target/release/rustiflow"
