{
  description = "rustiflow-vwall — operator/harness tooling for Virtual Wall RustiFlow experiments";

  # This flake is the *harness* shell (things the operator or a node needs around
  # the experiment: just, jq, iperf, shellcheck). RustiFlow itself is built on the
  # nodes with ITS OWN pinned flake (see bootstrap.sh) — that is where toolchain
  # reproducibility lives.
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let pkgs = import nixpkgs { inherit system; };
      in {
        devShells.default = pkgs.mkShell {
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
      });
}
