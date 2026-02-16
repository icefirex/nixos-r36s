{
  description = "NixOS on R36S handheld gaming console (Rockchip RK3326)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    deploy-rs = {
      url = "github:serokell/deploy-rs";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, deploy-rs }:
    {
      nixosConfigurations.r36s = nixpkgs.lib.nixosSystem {
        modules = [
          {
            # Cross-compile from x86_64 to aarch64 (10-50x faster than QEMU emulation)
            nixpkgs.buildPlatform = "x86_64-linux";
            nixpkgs.hostPlatform = "aarch64-linux";
          }
          { system.configurationRevision = self.rev or "dirty"; }
          ./configuration.nix
        ];
      };

      # Remote deployment with automatic rollback:
      #   nix run .#deploy
      deploy.nodes.r36s = {
        hostname = "10.0.0.2";
        sshUser = "root";
        sshOpts = [ "-o" "StrictHostKeyChecking=no" "-o" "UserKnownHostsFile=/dev/null" ];
        # Auto-rollback if activation fails or SSH drops after switch
        magicRollback = true;
        autoRollback = true;
        profiles.system = {
          user = "root";
          path = deploy-rs.lib.aarch64-linux.activate.nixos
            self.nixosConfigurations.r36s;
        };
      };

      # `nix run .#deploy` to deploy from x86_64 host
      packages.x86_64-linux.deploy = deploy-rs.packages.x86_64-linux.default;

      # `nix develop` for a shell with the deploy tool
      devShells.x86_64-linux.default = nixpkgs.legacyPackages.x86_64-linux.mkShell {
        packages = [ deploy-rs.packages.x86_64-linux.default ];
      };
    };
}
