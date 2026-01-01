{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.nix-build-server;
  serverPackage = pkgs.callPackage ./server-package.nix {};

  # Validation functions
  isValidHostname = hostname:
    builtins.match "^[a-z0-9-]{1,63}$" hostname != null;

  isValidUrl = url:
    builtins.match "^https?://.*$" url != null;

  isValidBranch = branch:
    builtins.match "^[a-zA-Z0-9/_-]+$" branch != null;

  isValidRepoName = name:
    builtins.match "^[a-z0-9-]+$" name != null;

  # Repository type
  repositoryType = types.submodule {
    options = {
      url = mkOption {
        type = types.str;
        description = "Git repository URL (HTTP/HTTPS)";
        example = "https://github.com/user/repo";
      };

      branch = mkOption {
        type = types.str;
        default = "main";
        description = "Git branch to build";
        example = "dev";
      };

      name = mkOption {
        type = types.str;
        description = "Unique repository identifier";
        example = "nix-terminal";
      };
    };
  };

  # Port type
  portType = types.addCheck types.int (port: port >= 1 && port <= 65535);

in {
  options.services.nix-build-server = {
    enable = mkEnableOption "NixOS build server with binary cache";

    hostname = mkOption {
      type = types.str;
      default = "build-server";
      description = "Hostname for the build server (used in Tailscale and cache key)";
      example = "build-server";
    };

    repositories = mkOption {
      type = types.listOf repositoryType;
      default = [];
      description = "List of repositories to build";
      example = literalExpression ''
        [
          {
            url = "https://github.com/user/repo";
            branch = "dev";
            name = "my-repo";
          }
        ]
      '';
    };

    cachePort = mkOption {
      type = portType;
      default = 5000;
      description = "Port for Harmonia binary cache server";
    };

    apiPort = mkOption {
      type = portType;
      default = 8000;
      description = "Port for build server API";
    };

    dataDir = mkOption {
      type = types.path;
      default = "/var/lib/nix-build-server";
      description = "Directory for build data, logs, and status files";
    };

    user = mkOption {
      type = types.str;
      default = "builder";
      description = "User to run build services as";
    };

    group = mkOption {
      type = types.str;
      default = "builder";
      description = "Group to run build services as";
    };

    enableWebUI = mkOption {
      type = types.bool;
      default = true;
      description = "Enable web UI for monitoring builds";
    };
  };

  config = mkIf cfg.enable {
    # Assertions for validation
    assertions = [
      {
        assertion = isValidHostname cfg.hostname;
        message = "services.nix-build-server.hostname must be a valid DNS label (1-63 chars, lowercase alphanumeric and hyphens)";
      }
      {
        assertion = cfg.cachePort != cfg.apiPort;
        message = "services.nix-build-server.cachePort and apiPort must be different";
      }
      {
        assertion = all (repo: isValidUrl repo.url) cfg.repositories;
        message = "All repository URLs must be valid HTTP/HTTPS URLs";
      }
      {
        assertion = all (repo: isValidBranch repo.branch) cfg.repositories;
        message = "All repository branches must be valid git refs";
      }
      {
        assertion = all (repo: isValidRepoName repo.name) cfg.repositories;
        message = "All repository names must be valid (lowercase alphanumeric and hyphens)";
      }
      {
        assertion =
          let names = map (repo: repo.name) cfg.repositories;
          in length names == length (unique names);
        message = "All repository names must be unique";
      }
    ];

    # 1. Key initialization service
    systemd.services.nix-build-server-init = {
      description = "Initialize Harmonia cache key";
      wantedBy = [ "multi-user.target" ];
      before = [ "harmonia.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "init-cache-key" ''
          KEY_FILE="/var/lib/harmonia/cache-key"
          if [ ! -f "$KEY_FILE" ]; then
            echo "Generating new cache signing key..."
            mkdir -p /var/lib/harmonia
            ${pkgs.nix}/bin/nix key generate-secret --key-name ${cfg.hostname} > "$KEY_FILE"
            chmod 600 "$KEY_FILE"
            chown harmonia:harmonia "$KEY_FILE"
            echo "Cache key generated at $KEY_FILE"
          else
            echo "Cache key already exists at $KEY_FILE"
          fi
        '';
      };
    };

    # 2. Harmonia configuration
    services.harmonia = {
      enable = true;
      signKeyPath = "/var/lib/harmonia/cache-key";
      settings = {
        bind = "[::]:${toString cfg.cachePort}";
        workers = 4;
        max_connection_rate = 256;
        priority = 40;
      };
    };

    # 3. Tailscale configuration
    services.tailscale = {
      enable = true;
      useRoutingFeatures = "server";
    };

    networking.hostName = cfg.hostname;

    # 4. Create user and group
    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
      description = "Build server user";
      home = cfg.dataDir;
      createHome = false;
    };

    users.groups.${cfg.group} = {};

    # 5. Directory creation
    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0755 ${cfg.user} ${cfg.group} -"
      "d ${cfg.dataDir}/builds 0755 ${cfg.user} ${cfg.group} -"
      "d ${cfg.dataDir}/logs 0755 ${cfg.user} ${cfg.group} -"
      "d ${cfg.dataDir}/status 0755 ${cfg.user} ${cfg.group} -"
    ];

    # 6. API server service
    systemd.services.nix-build-server-api = {
      description = "Build Server API";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" "nix-build-server-init.service" ];
      wants = [ "nix-build-server-init.service" ];

      environment = {
        BUILD_SERVER_DATA_DIR = cfg.dataDir;
        BUILD_SERVER_HOSTNAME = cfg.hostname;
        BUILD_SERVER_API_PORT = toString cfg.apiPort;
        BUILD_SERVER_CACHE_PORT = toString cfg.cachePort;
        ENABLE_WEB_UI = if cfg.enableWebUI then "1" else "0";
      };

      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = cfg.group;
        ExecStart = "${serverPackage}/bin/build-server";
        Restart = "on-failure";
        RestartSec = "5s";

        # Hardening
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [ cfg.dataDir ];
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
        RestrictNamespaces = true;
        LockPersonality = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        PrivateMounts = true;
      };
    };

    # 7. Sudo rules for API server to trigger builds
    security.sudo.extraRules = [{
      users = [ cfg.user ];
      commands = [
        {
          command = "${pkgs.systemd}/bin/systemctl start nix-build-*";
          options = [ "NOPASSWD" ];
        }
        {
          command = "${pkgs.systemd}/bin/systemctl is-active nix-build-*";
          options = [ "NOPASSWD" ];
        }
      ];
    }];

    # 8. Per-repository build services
    systemd.services = listToAttrs (map (repo:
      nameValuePair "nix-build-${repo.name}" {
        description = "Build ${repo.name}";

        serviceConfig = {
          Type = "oneshot";
          User = cfg.user;
          Group = cfg.group;
          WorkingDirectory = "${cfg.dataDir}/builds";
          ExecStart = "${serverPackage}/bin/build-repository ${escapeShellArg repo.url} ${escapeShellArg repo.branch} ${escapeShellArg repo.name}";

          Environment = [
            "NIX_PATH=nixpkgs=${pkgs.path}"
            "BUILD_SERVER_DATA_DIR=${cfg.dataDir}"
          ];

          # Allow network access for git and nix
          PrivateNetwork = false;

          # Timeout after 2 hours
          TimeoutStartSec = "2h";
        };

        # Don't start automatically
        wantedBy = [];
      }
    ) cfg.repositories);

    # 9. Firewall configuration
    networking.firewall = {
      allowedTCPPorts = [ cfg.cachePort cfg.apiPort ];
      # Trust Tailscale interface
      trustedInterfaces = [ "tailscale0" ];
    };

    # 10. Nix configuration
    nix.settings = {
      # Enable flakes
      experimental-features = [ "nix-command" "flakes" ];

      # Allow substituters
      trusted-substituters = [ "https://cache.nixos.org" ];

      # Build settings
      max-jobs = "auto";
      cores = 0;

      # Auto-optimize store
      auto-optimise-store = true;
    };

    # Garbage collection
    nix.gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 30d";
    };

    # 11. System packages
    environment.systemPackages = with pkgs; [
      git
      jq
      curl
      htop
      serverPackage
    ];

    # 12. Info display service (runs once on boot)
    systemd.services.nix-build-server-info = {
      description = "Display build server information";
      wantedBy = [ "multi-user.target" ];
      after = [
        "nix-build-server-api.service"
        "harmonia.service"
        "tailscale.service"
        "nix-build-server-init.service"
      ];
      wants = [
        "nix-build-server-api.service"
        "harmonia.service"
        "tailscale.service"
      ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "show-server-info" ''
          set -euo pipefail

          echo "=================================="
          echo "NixOS Build Server Information"
          echo "=================================="
          echo ""
          echo "Hostname: ${cfg.hostname}"
          echo "API Port: ${toString cfg.apiPort}"
          echo "Cache Port: ${toString cfg.cachePort}"
          echo ""
          echo "API URL: http://${cfg.hostname}:${toString cfg.apiPort}"
          echo "Cache URL: http://${cfg.hostname}:${toString cfg.cachePort}"
          echo ""
          echo "Repositories:"
          ${concatMapStringsSep "\n" (repo: "echo \"  - ${repo.name} (${repo.url} @ ${repo.branch})\"") cfg.repositories}
          echo ""
          echo "To get the public key, run:"
          echo "  curl http://${cfg.hostname}:${toString cfg.apiPort}/info | ${pkgs.jq}/bin/jq -r '.public_key'"
          echo ""
          echo "Or visit the web UI at:"
          echo "  http://${cfg.hostname}:${toString cfg.apiPort}/"
          echo ""
          echo "=================================="
        '';
      };
    };
  };
}
