{ pkgs, lib, writeShellScriptBin }:

let
  mkClientScript = name: script: writeShellScriptBin name ''
    BUILD_SERVER="''${BUILD_SERVER:-build-server}"
    ${script}
  '';

  # Individual client scripts
  info = mkClientScript "build-server-info" ''
    ${pkgs.curl}/bin/curl -s "http://''${BUILD_SERVER}:8000/info" | \
      ${pkgs.jq}/bin/jq
  '';

  trigger = mkClientScript "build-trigger" ''
    REPO="''${1:-nix-terminal}"
    ${pkgs.curl}/bin/curl -s -X POST \
      "http://''${BUILD_SERVER}:8000/build/trigger/''${REPO}" | \
      ${pkgs.jq}/bin/jq
  '';

  status = mkClientScript "build-status" ''
    REPO="''${1:-nix-terminal}"
    ${pkgs.curl}/bin/curl -s \
      "http://''${BUILD_SERVER}:8000/build/status/''${REPO}" | \
      ${pkgs.jq}/bin/jq -C
  '';

  logs = mkClientScript "build-logs" ''
    REPO="''${1:-nix-terminal}"
    LINES="''${2:-50}"
    ${pkgs.curl}/bin/curl -s \
      "http://''${BUILD_SERVER}:8000/build/logs/''${REPO}?lines=''${LINES}" | \
      ${pkgs.jq}/bin/jq -r '.logs[]'
  '';

  watch = mkClientScript "build-watch" ''
    REPO="''${1:-nix-terminal}"
    ${pkgs.watch}/bin/watch -n 2 \
      "${pkgs.curl}/bin/curl -s http://''${BUILD_SERVER}:8000/build/status/''${REPO} | \
       ${pkgs.jq}/bin/jq"
  '';

  health = mkClientScript "build-health" ''
    ${pkgs.curl}/bin/curl -s \
      "http://''${BUILD_SERVER}:8000/health" | \
      ${pkgs.jq}/bin/jq -C
  '';

  add-cache = mkClientScript "build-server-add-cache" ''
    echo "Fetching server info..."
    INFO=$(${pkgs.curl}/bin/curl -s "http://''${BUILD_SERVER}:8000/info")

    CACHE_URL=$(echo "$INFO" | ${pkgs.jq}/bin/jq -r '.cache_url')
    PUBLIC_KEY=$(echo "$INFO" | ${pkgs.jq}/bin/jq -r '.public_key')

    echo ""
    echo "Add this to your NixOS configuration:"
    echo ""
    echo "  nix.settings = {"
    echo "    substituters = [ \"$CACHE_URL\" ];"
    echo "    trusted-public-keys = [ \"$PUBLIC_KEY\" ];"
    echo "  };"
    echo ""
    echo "Or run as root:"
    echo ""
    echo "  nix build --option substituters \"$CACHE_URL\" --option trusted-public-keys \"$PUBLIC_KEY\" ..."
    echo ""
  '';

in pkgs.symlinkJoin {
  name = "nix-build-server-client";
  paths = [ info trigger status logs watch health add-cache ];

  meta = {
    description = "Client tools for nix-build-server";
    longDescription = ''
      Command-line tools to interact with a nix-build-server instance.

      Available commands:
      - build-server-info: Get server information and public key
      - build-trigger <repo>: Trigger a build for a repository
      - build-status <repo>: Get build status for a repository
      - build-logs <repo> [lines]: Get build logs (default: 50 lines)
      - build-watch <repo>: Watch build status (auto-refresh)
      - build-health: Check server health
      - build-server-add-cache: Show how to add the cache to your config

      Set BUILD_SERVER environment variable to use a different server:
        export BUILD_SERVER=my-build-server
    '';
    mainProgram = "build-server-info";
    license = lib.licenses.mit;
    platforms = lib.platforms.all;
  };
}
