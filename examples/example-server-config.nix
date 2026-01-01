# Example NixOS configuration for nix-build-server
#
# This example shows how to set up a build server using the nix-build-server module.
# You can use this as a starting point for your own configuration.
#
# To use this configuration:
# 1. Add the flake input to your flake.nix
# 2. Import the module
# 3. Configure the service
# 4. Deploy with nixos-rebuild

{ config, pkgs, ... }:

{
  # Import the nix-build-server module
  # In your flake.nix, add:
  #   inputs.nix-build-server.url = "github:Bullish-Design/nixserve";
  # Then in your configuration:
  #   imports = [ inputs.nix-build-server.nixosModules.default ];

  # Enable and configure the build server
  services.nix-build-server = {
    enable = true;

    # Hostname (will be used in Tailscale and cache key)
    hostname = "build-server";

    # Repositories to build
    repositories = [
      {
        url = "https://github.com/Bullish-Design/nix-terminal";
        branch = "dev";
        name = "nix-terminal";
      }
      {
        url = "https://github.com/Bullish-Design/atuin-bootstrap";
        branch = "main";
        name = "atuin-bootstrap";
      }
    ];

    # Port configuration
    cachePort = 5000;  # Harmonia binary cache
    apiPort = 8000;    # FastAPI server

    # Data directory
    dataDir = "/var/lib/nix-build-server";

    # User to run builds as
    user = "builder";
    group = "builder";

    # Enable web UI
    enableWebUI = true;
  };

  # Optional: Additional Nix configuration
  nix.settings = {
    # Build settings
    max-jobs = 4;
    cores = 0;

    # Trusted users (can add cache substituters)
    trusted-users = [ "root" "@wheel" ];
  };

  # Optional: Additional system packages
  environment.systemPackages = with pkgs; [
    git
    vim
    htop
    btop
  ];

  # Optional: SSH access
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = false;
    };
  };

  # Optional: Auto-upgrade
  system.autoUpgrade = {
    enable = true;
    allowReboot = false;
    dates = "weekly";
  };

  # System state version
  system.stateVersion = "24.05";
}
