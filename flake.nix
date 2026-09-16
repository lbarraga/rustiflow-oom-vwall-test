{
  description = "rustiflow-vwall — operator/harness tooling for Virtual Wall RustiFlow experiments";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # RustiFlow itself, pinned to an exact commit in flake.lock. Source-only
    # (flake = false) because upstream ships no flake.nix — so THIS flake owns
    # the build toolchain below. To move to a newer RustiFlow:
    #   nix flake update rustiflow      (then commit flake.lock)
    # To build your own fork/branch, change this url and re-lock.
    rustiflow = {
      url = "github:idlab-discover/RustiFlow";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, flake-utils, rust-overlay, rustiflow }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ rust-overlay.overlays.default ];
        };

        # --- RustiFlow build toolchain (kept in sync with RustiFlow's own
        # flake.nix; it is not published upstream, so it lives here). A single
        # nightly covers the userspace crates and the ebpf-ipv4/ebpf-ipv6 crates,
        # which need `-Z build-std=core` + rust-src.
        rustToolchain = pkgs.rust-bin.nightly.latest.default.override {
          extensions = [ "rust-src" "clippy" "rustfmt" ];
        };

        # bpf-linker rebuilt against an LLVM major matching the nightly toolchain
        # (see the comment in RustiFlow's flake.nix). Bump llvmPackages_NN if the
        # nightly's LLVM drifts.
        bpfLinker = pkgs.bpf-linker.override {
          llvmPackagesForLinker = pkgs.llvmPackages_23;
        };

        rustiflowBuildInputs = [
          rustToolchain
          bpfLinker
          pkgs.libpcap    # pcap crate (offline pcap reading)
          pkgs.pkg-config
        ];
      in
      {
        packages = {
          # The exact RustiFlow source tree, resolved from flake.lock. bootstrap.sh
          # copies this to a writable dir and builds it — so the source revision is
          # lockfile-pinned, not a mutable git checkout.
          rustiflow-src = pkgs.runCommand "rustiflow-src" { } "cp -r ${rustiflow} $out";

          # Locked revision, for provenance/markers.
          rustiflow-rev = pkgs.writeText "rustiflow-rev"
            (rustiflow.rev or "unknown");
        };

        devShells = {
          # RustiFlow build environment (pinned toolchain). bootstrap.sh builds
          # inside this, so the toolchain is pinned via OUR lockfile.
          rustiflow = pkgs.mkShell { buildInputs = rustiflowBuildInputs; };

          # Operator/harness shell.
          default = pkgs.mkShell {
            buildInputs = [
              pkgs.just
              pkgs.jq
              pkgs.iperf
              pkgs.ethtool
              pkgs.shellcheck
              pkgs.openssh
            ];
            shellHook = ''
              echo "rustiflow-vwall harness shell"
              echo "  just            # list commands"
              echo "  just check victim=user@h1 attacker=user@h2"
            '';
          };
        };
      });
}
