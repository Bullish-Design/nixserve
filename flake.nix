{
  description = "Self-hosted NixOS build server with binary cache";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixos-wsl.url = "github:nix-community/NixOS-WSL";
    nixos-wsl.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, nixos-wsl }: {
    # Primary module export
    nixosModules.default = import ./module.nix;

    # Pre-configured build server example
    nixosConfigurations.build-server = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        nixos-wsl.nixosModules.wsl
        self.nixosModules.default
        {
          wsl.enable = true;
          wsl.defaultUser = "nixos";

          services.nix-build-server = {
            enable = true;
            hostname = "build-server";
            repositories = [
              {
                url = "https://github.com/Bullish-Design/nix-terminal";
                branch = "dev";
                name = "nix-terminal";
              }
            ];
          };
        }
      ];
    };

    # Client tools package
    packages.x86_64-linux = {
      client = nixpkgs.legacyPackages.x86_64-linux.callPackage ./client-package.nix {};
      server = nixpkgs.legacyPackages.x86_64-linux.callPackage ./server-package.nix {};
    };

    # Default package
    packages.x86_64-linux.default = self.packages.x86_64-linux.client;
  };
}
