{
  description = "Run EVE-NG in a QEMU/KVM VM on any Linux host with /dev/kvm";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems
        (system: f { inherit system; pkgs = import nixpkgs { inherit system; }; });
    in {
      packages = forAllSystems ({ pkgs, ... }: rec {
        eve-lab = pkgs.writeShellApplication {
          name = "eve-lab";
          runtimeInputs = with pkgs; [ qemu aria2 openssl coreutils curl gnugrep procps ];
          text = builtins.readFile ./eve-lab.sh;
        };
        default = eve-lab;
      });

      # `nix run .# -- <subcommand>`
      # `nix run .#eve-lab -- setup|install|run|check|help`
      apps = forAllSystems ({ system, pkgs }:
        let
          p = self.packages.${system};
          eve-lab-app = {
            type = "app";
            program = "${p.eve-lab}/bin/eve-lab";
            meta = {
              description = "EVE-NG lab (setup/install/run/check) via QEMU/KVM";
              mainProgram = "eve-lab";
              license = pkgs.lib.licenses.asl20;
              platforms = pkgs.lib.platforms.linux;
            };
          };
        in {
          eve-lab = eve-lab-app;
          default = eve-lab-app;
        });

      # `nix flake check` — sandbox-safe verification (no /dev/kvm, no network).
      # Runtime verification is `nix run .# -- check` on the target machine.
      checks = forAllSystems ({ system, pkgs }: {
        # writeShellApplication runs shellcheck at build time. Building = clean.
        script-build = self.packages.${system}.eve-lab;

        # `bash -n` parse check on the raw source, independent of the wrapper.
        script-parse = pkgs.runCommand "eve-lab-script-parse" {
          nativeBuildInputs = [ pkgs.bash ];
        } ''
          bash -n ${./eve-lab.sh}
          touch $out
        '';

        # `eve-lab help` exits 0 without needing KVM/net — good end-to-end
        # smoke that the wrapper + script dispatch actually work.
        help-runs = pkgs.runCommand "eve-lab-help-runs" {
          nativeBuildInputs = [ self.packages.${system}.eve-lab ];
        } ''
          eve-lab help > $out
          grep -q "^Subcommands" $out
        '';

        # QEMU is available and knows the specific devices we depend on.
        qemu-smoke = pkgs.runCommand "eve-lab-qemu-smoke" {
          nativeBuildInputs = [ pkgs.qemu ];
        } ''
          qemu-system-x86_64 --version | grep -q 'QEMU emulator'
          qemu-system-x86_64 -device help 2>&1 | grep -q virtio-scsi-pci
          qemu-system-x86_64 -device help 2>&1 | grep -q virtio-net-pci
          qemu-system-x86_64 -object help 2>&1 | grep -q secret
          touch $out
        '';
      });
    };
}
