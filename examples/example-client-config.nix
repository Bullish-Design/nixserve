# Example client configuration for using nix-build-server
#
# This example shows how to configure a client machine to use the build server's
# binary cache and optionally install the client tools.
#
# This can be used in both NixOS configurations and Home Manager configurations.

{ config, pkgs, ... }:

{
  # For Home Manager users, add the flake input:
  #   inputs.nix-build-server.url = "github:Bullish-Design/nixserve";

  # Option 1: Configure Nix to use the build server cache
  # (This works in both NixOS and Home Manager)
  nix.settings = {
    # Add your build server as a substituter
    # Replace 'build-server' with your actual hostname
    substituters = [
      "https://cache.nixos.org"
      "http://build-server:5000"
    ];

    # Add the public key from your build server
    # Get this by running: curl http://build-server:8000/info | jq -r '.public_key'
    # Or visit http://build-server:8000/ and copy it from the web UI
    trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      "build-server:YOUR_PUBLIC_KEY_HERE"  # Replace with actual key
    ];
  };

  # Option 2: Install client tools (Home Manager or NixOS)
  # Uncomment the appropriate section below:

  # For Home Manager:
  # home.packages = [
  #   inputs.nix-build-server.packages.x86_64-linux.client
  # ];

  # For NixOS:
  # environment.systemPackages = [
  #   inputs.nix-build-server.packages.x86_64-linux.client
  # ];

  # Option 3: Add shell aliases for convenience
  # (Home Manager example)
  # programs.bash.shellAliases = {
  #   bs = "build-status";
  #   bt = "build-trigger";
  #   bl = "build-logs";
  #   bi = "build-server-info";
  # };

  # programs.zsh.shellAliases = {
  #   bs = "build-status";
  #   bt = "build-trigger";
  #   bl = "build-logs";
  #   bi = "build-server-info";
  # };

  # Option 4: Set default build server
  # home.sessionVariables = {
  #   BUILD_SERVER = "build-server";  # Replace with your hostname
  # };

  # Example usage after setup:
  #
  # 1. Check server info:
  #    $ build-server-info
  #
  # 2. Trigger a build:
  #    $ build-trigger nix-terminal
  #
  # 3. Check build status:
  #    $ build-status nix-terminal
  #
  # 4. View build logs:
  #    $ build-logs nix-terminal 100
  #
  # 5. Watch build status (auto-refresh):
  #    $ build-watch nix-terminal
  #
  # 6. Check server health:
  #    $ build-health
  #
  # 7. Show how to add cache:
  #    $ build-server-add-cache
}
