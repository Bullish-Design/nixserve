# nixserve - NixOS Build Server with Binary Cache

A self-hosted NixOS build server with integrated binary cache, designed for private Tailscale networks. Build your Nix packages once on a powerful server and share them across all your machines.

## Features

- 🏗️ **Automated Builds**: Trigger builds via API or web UI
- 📦 **Binary Cache**: Powered by Harmonia for fast, signed package distribution
- 🌐 **Web UI**: Monitor build status and logs from your browser
- 🔒 **Secure**: Runs on Tailscale with cryptographic package signing
- 🎯 **Multi-Repository**: Build and cache multiple projects simultaneously
- 🐍 **Modern Stack**: FastAPI + Python 3.11+ with async support
- 🔧 **Easy Setup**: Single NixOS module with sensible defaults

## Quick Start

### Server Setup

1. **Add to your flake inputs:**

```nix
{
  inputs.nixserve.url = "github:Bullish-Design/nixserve";
}
```

2. **Configure your NixOS system:**

```nix
{
  imports = [ inputs.nixserve.nixosModules.default ];

  services.nix-build-server = {
    enable = true;
    hostname = "build-server";
    repositories = [
      {
        url = "https://github.com/user/repo";
        branch = "main";
        name = "my-project";
      }
    ];
  };
}
```

3. **Deploy:**

```bash
sudo nixos-rebuild switch --flake .#
```

4. **Get your cache public key:**

```bash
curl http://build-server:8000/info | jq -r '.public_key'
```

### Client Setup

Add to your NixOS or Home Manager configuration:

```nix
{
  nix.settings = {
    substituters = [ "http://build-server:5000" ];
    trusted-public-keys = [ "build-server:YOUR_KEY_HERE" ];
  };
}
```

## Usage

### Web UI

Visit `http://build-server:8000/` to:
- View build status for all repositories
- Trigger builds with one click
- See build logs and commit history
- Copy cache configuration

### API Endpoints

- `GET /info` - Server information and public key
- `GET /health` - Health check
- `POST /build/trigger/{repo}` - Trigger a build
- `GET /build/status/{repo}` - Get build status
- `GET /build/logs/{repo}?lines=100` - Get build logs

### Client Tools

Install the client tools package:

```nix
environment.systemPackages = [
  inputs.nixserve.packages.x86_64-linux.client
];
```

Available commands:
- `build-server-info` - Show server information
- `build-trigger <repo>` - Trigger a build
- `build-status <repo>` - Check build status
- `build-logs <repo> [lines]` - View logs
- `build-watch <repo>` - Watch status (auto-refresh)
- `build-health` - Server health check
- `build-server-add-cache` - Show cache setup instructions

## Configuration Options

```nix
services.nix-build-server = {
  enable = true;                    # Enable the service
  hostname = "build-server";        # Server hostname
  cachePort = 5000;                 # Harmonia cache port
  apiPort = 8000;                   # API server port
  dataDir = "/var/lib/nix-build-server";  # Data directory
  user = "builder";                 # Build user
  group = "builder";                # Build group
  enableWebUI = true;               # Enable web interface

  repositories = [
    {
      url = "https://github.com/user/repo";  # Git URL
      branch = "main";                       # Git branch
      name = "repo-name";                    # Unique identifier
    }
  ];
};
```

## Architecture

```
┌─────────────────────────────────────────┐
│         nix-build-server                │
├─────────────────────────────────────────┤
│  ┌──────────┐  ┌──────────┐  ┌────────┐│
│  │ NixOS    │  │ FastAPI  │  │Harmonia││
│  │ Module   │──│ Server   │──│ Cache  ││
│  └──────────┘  └──────────┘  └────────┘│
│                                         │
│  Storage:                               │
│  • /nix/store (packages)                │
│  • /var/lib/harmonia (keys)             │
│  • /var/lib/nix-build-server (data)     │
└─────────────────────────────────────────┘
```

## Documentation

- [SPEC.md](SPEC.md) - Complete technical specification
- [AGENTS.md](AGENTS.md) - Development guidelines and agent instructions
- [examples/](examples/) - Example configurations

## Requirements

- NixOS 24.05 or later
- 20GB+ disk space
- 4GB+ RAM
- Tailscale network

## License

MIT

## Contributing

Contributions welcome! Please read [AGENTS.md](AGENTS.md) for development guidelines.

## Support

For issues and questions:
- GitHub Issues: https://github.com/Bullish-Design/nixserve/issues
- Documentation: See SPEC.md for detailed information 
