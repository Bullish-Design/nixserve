# AGENTS.md - Autonomous Components Specification

## Overview

The nix-build-server system comprises five autonomous agents that work together to provide 
automated build caching across a Tailscale network. Each agent operates independently with 
well-defined interfaces and responsibilities.

---

## AGENT 1: Cache Key Manager

### Purpose
Automatically generate, store, and expose signing keys for the binary cache on first boot.

### Lifecycle
- **Initialization**: Runs once before Harmonia starts
- **Operation**: Remains inactive after successful key generation
- **Recovery**: Idempotent - safe to run multiple times

### Behavior Specification

**Startup Sequence:**
```
1. Check if /var/lib/harmonia/cache-key exists
2. IF exists:
     - Log "Using existing cache key"
     - Extract public key
     - Display to systemd journal
     - Exit success
3. ELSE:
     - Create /var/lib/harmonia directory (mode 700)
     - Generate key: nix key generate-secret --key-name ${hostname}
     - Write to /var/lib/harmonia/cache-key
     - Set permissions: 600
     - Set ownership: harmonia:harmonia
     - Extract public key
     - Display to systemd journal
     - Exit success
```

**Error Handling:**
- If nix command fails → Log error, exit 1
- If directory creation fails → Log error, exit 1
- If permission set fails → Log warning, continue (Harmonia will fail later with clear error)

**Outputs:**
- File: `/var/lib/harmonia/cache-key` (600, harmonia:harmonia)
- Stdout: Public key in format "hostname:base64string"
- Journal: Success/failure messages

**Dependencies:**
- Requires: Nix package manager
- Before: harmonia.service
- After: local-fs.target

**Configuration Inputs:**
- `config.services.nix-build-server.hostname`

**Service Definition:**
```systemd
[Unit]
Description=Initialize build server keys
Before=harmonia.service
After=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=true
ExecStart=/nix/store/.../init-keys.sh
```

---

## AGENT 2: API Server (FastAPI Application)

### Purpose
Provide HTTP endpoints for build triggering, status monitoring, and server information.

### Lifecycle
- **Initialization**: Starts with multi-user.target
- **Operation**: Continuous service, handles HTTP requests
- **Recovery**: Auto-restart on failure (10s delay)

### Behavior Specification

**Startup Sequence:**
```
1. Read environment variables:
   - BUILD_SERVER_DATA_DIR (default: /var/lib/nix-build-server)
   - BUILD_SERVER_HOSTNAME (default: build-server)
   - BUILD_SERVER_API_PORT (default: 8000)
   - BUILD_SERVER_CACHE_PORT (default: 5000)
   - ENABLE_WEB_UI (default: 1)

2. Initialize FastAPI application
3. Verify access to:
   - /var/lib/harmonia/cache-key (for public key extraction)
   - ${DATA_DIR}/status/ (create if missing)
   - ${DATA_DIR}/logs/ (create if missing)

4. Bind to [::]:${API_PORT}
5. Begin serving requests
```

**Endpoint Behaviors:**

**GET /**
```
IF ENABLE_WEB_UI == "1":
    1. Query systemctl for all nix-build-* services
    2. Parse service names to extract repository names
    3. For each repository:
        - Read ${DATA_DIR}/status/${repo}.json
        - Check systemctl is-active nix-build-${repo}
        - Merge status
    4. Read /var/lib/harmonia/cache-key public key
    5. Generate HTML with:
        - Server hostname and ports
        - Public key in copyable format
        - Repository cards showing status
        - Trigger buttons (POST to /build/trigger/${repo})
        - Auto-refresh meta tag (5 seconds)
    6. Return HTML
ELSE:
    Return 200 with simple message "Web UI disabled"
```

**GET /info**
```
1. Extract public key from /var/lib/harmonia/cache-key
2. Query systemctl for repository list
3. Return JSON:
   {
     "hostname": "${HOSTNAME}",
     "api_port": ${API_PORT},
     "cache_port": ${CACHE_PORT},
     "cache_url": "http://${HOSTNAME}:${CACHE_PORT}",
     "public_key": "${PUBLIC_KEY}",
     "repositories": ["repo1", "repo2", ...]
   }
```

**POST /build/trigger/{repository}**
```
1. Validate repository exists:
   - Query: systemctl list-units nix-build-${repository}
   - IF not found: Return 404 "Repository not found"

2. Check if already running:
   - Query: systemctl is-active nix-build-${repository}
   - IF active: Return 200 {status: "already_running"}

3. Trigger build:
   - Execute: sudo systemctl start nix-build-${repository}
   - IF success: Return 200 {status: "triggered", repository: "${repository}"}
   - IF failure: Return 500 with stderr

4. Log action to journal
```

**GET /build/status/{repository}**
```
1. Validate repository exists (404 if not)
2. Read ${DATA_DIR}/status/${repository}.json
   - IF missing: Return default status (is_running: false)
3. Check live status:
   - Query: systemctl is-active nix-build-${repository}
   - Update is_running field
4. Return BuildStatus JSON
```

**GET /build/logs/{repository}?lines=N**
```
1. Validate repository exists (404 if not)
2. Read ${DATA_DIR}/logs/${repository}.log
   - IF missing: Return {logs: []}
3. Execute: tail -n ${lines} ${log_file}
4. Return {logs: ["line1", "line2", ...]}
```

**GET /health**
```
1. Check systemctl is-active harmonia
2. Query repository count
3. Return {
     status: "healthy",
     cache_running: bool,
     repositories: [...]
   }
```

**Error Handling:**
- 404 for unknown repositories
- 500 for systemctl failures
- Log all errors to systemd journal
- Continue serving other requests on error

**Dependencies:**
- Requires: Python 3.11+, FastAPI, Uvicorn, Pydantic
- After: network.target, tailscale.service
- Wants: harmonia.service (soft dependency)

**Service Definition:**
```systemd
[Unit]
Description=Build Server API
After=network.target tailscale.service

[Service]
Type=simple
User=builder
WorkingDirectory=${DATA_DIR}
ExecStart=uv run /path/to/build-server.py
Restart=always
RestartSec=10s
Environment=PYTHONUNBUFFERED=1
```

---

## AGENT 3: Build Orchestrator (Per-Repository)

### Purpose
Execute git clone/update and nix build for a specific repository, updating status throughout.

### Lifecycle
- **Initialization**: Triggered by systemctl (oneshot service)
- **Operation**: Runs to completion
- **Recovery**: Can be re-triggered immediately after completion

### Behavior Specification

**Input Parameters:**
- `$1`: Repository URL (e.g., https://github.com/user/repo)
- `$2`: Branch name (e.g., dev, main)
- `$3`: Repository name (e.g., nix-terminal)

**Environment Variables:**
- `BUILD_SERVER_DATA_DIR`: Base directory for builds/logs/status
- `NIX_PATH`: Set to nixpkgs path

**Execution Flow:**

**Phase 1: Initialization**
```bash
1. Set derived paths:
   REPO_DIR = ${DATA_DIR}/builds/${REPO_NAME}
   LOG_FILE = ${DATA_DIR}/logs/${REPO_NAME}.log
   STATUS_FILE = ${DATA_DIR}/status/${REPO_NAME}.json

2. Write initial status:
   {
     "is_running": true,
     "last_start": "$(date -Iseconds)",
     "last_finish": null,
     "last_status": null,
     "last_commit": null,
     "repository": "${REPO_NAME}"
   }

3. Log to LOG_FILE: "Starting build for ${REPO_NAME}"
```

**Phase 2: Repository Sync**
```bash
IF ${REPO_DIR} does not exist:
    1. Log: "Cloning repository..."
    2. Execute: git clone --branch ${BRANCH} ${REPO_URL} ${REPO_DIR}
    3. IF failure:
        - Log error
        - Update status: is_running=false, last_status="failed"
        - Exit 1
ELSE:
    1. Log: "Updating repository..."
    2. cd ${REPO_DIR}
    3. Execute: git fetch origin
    4. Execute: git reset --hard origin/${BRANCH}
    5. IF failure:
        - Log error
        - Update status: is_running=false, last_status="failed"
        - Exit 1

4. Extract commit: COMMIT=$(git rev-parse --short HEAD)
5. Log: "Building commit ${COMMIT}"
```

**Phase 3: Flake Detection & Update**
```bash
IF flake.nix exists:
    1. Log: "Updating flake inputs..."
    2. Execute: nix flake update
       - Continue on non-zero exit (log warning)
    
    3. Log: "Checking flake..."
    4. Execute: nix flake check --print-build-logs
       - Continue on non-zero exit (log warning)
ELSE:
    Log: "No flake.nix found, will attempt default.nix"
```

**Phase 4: Build Strategy**

**Strategy A: Flake-based Build**
```bash
IF flake.nix exists:
    1. Enumerate packages:
       Execute: nix flake show --json 2>/dev/null
       Parse: .packages."x86_64-linux" | keys[]
    
    2. For each package:
       Execute: nix build .#${package} --print-build-logs --keep-going
       - Log success/failure per package
       - Continue on failure (build other packages)
    
    3. Check for homeManagerModules:
       Execute: nix flake show --json 2>/dev/null
       Parse: jq -e '.homeManagerModules'
    
    4. IF homeManagerModules exist:
       - Create /tmp/test-home-${REPO_NAME}.nix with minimal config
       - Build: nix build --impure --expr "
           let
             pkgs = import <nixpkgs> {};
             home-manager = builtins.getFlake \"github:nix-community/home-manager\";
             flake = builtins.getFlake \"path:${REPO_DIR}\";
           in
           home-manager.lib.homeManagerConfiguration {
             inherit pkgs;
             modules = [ 
               /tmp/test-home-${REPO_NAME}.nix
             ] ++ (if flake ? homeManagerModules.default 
                   then [ flake.homeManagerModules.default ]
                   else []);
           }
         " --print-build-logs --keep-going
       - Log success/failure
       - Continue on failure
```

**Strategy B: Legacy Build**
```bash
ELSE (no flake.nix):
    Execute: nix-build --print-build-logs --keep-going
    IF failure:
        - Log error
        - Update status: is_running=false, last_status="failed", last_commit=${COMMIT}
        - Exit 1
```

**Phase 5: Completion**
```bash
1. Log: "Build complete. All dependencies cached."

2. Update status:
   {
     "is_running": false,
     "last_start": "${START_TIME}",
     "last_finish": "$(date -Iseconds)",
     "last_status": "success",
     "last_commit": "${COMMIT}",
     "repository": "${REPO_NAME}"
   }

3. Log: "Build finished successfully for commit ${COMMIT}"

4. Exit 0
```

**Error Handling:**
- All git/nix errors logged to LOG_FILE
- Status file always updated before exit
- Partial build success still caches completed packages
- Non-critical errors (flake check) don't fail entire build

**Service Definition (Generated per repository):**
```systemd
[Unit]
Description=Build ${repository.name}

[Service]
Type=oneshot
User=builder
WorkingDirectory=${DATA_DIR}/builds
ExecStart=/path/to/build-repository.sh ${url} ${branch} ${name}
Environment=NIX_PATH=nixpkgs=${pkgs.path}
Environment=BUILD_SERVER_DATA_DIR=${DATA_DIR}
```

---

## AGENT 4: Cache Server (Harmonia)

### Purpose
Serve built Nix packages over HTTP with signature verification.

### Lifecycle
- **Initialization**: Starts with multi-user.target after key generation
- **Operation**: Continuous service, handles cache requests
- **Recovery**: Auto-restart on failure

### Behavior Specification

**Startup Sequence:**
```
1. Verify /var/lib/harmonia/cache-key exists
   - IF missing: Fail with clear error
   
2. Read signing key from /var/lib/harmonia/cache-key

3. Scan /nix/store for available packages

4. Bind to [::]:${CACHE_PORT}

5. Begin serving cache requests
```

**Request Handling:**

**GET /nix-cache-info**
```
Return:
  StoreDir: /nix/store
  WantMassQuery: 1
  Priority: 40
  PublicKeys: ${hostname}:${public_key}
```

**GET /<store-path>.narinfo**
```
1. Parse store path from URL
2. Query /nix/store for path
3. IF exists:
     - Generate .narinfo metadata:
       - StorePath
       - URL (nar file location)
       - Compression (xz)
       - FileHash
       - FileSize
       - NarHash
       - NarSize
       - References
       - Sig (signature using cache-key)
     - Return narinfo
4. ELSE:
     - Return 404
```

**GET /nar/<hash>.nar.xz**
```
1. Parse hash from URL
2. Locate corresponding /nix/store path
3. IF exists:
     - Stream compressed NAR archive
     - Set appropriate headers
4. ELSE:
     - Return 404
```

**Performance Characteristics:**
- Async I/O for concurrent requests
- Streaming for large NARs
- Caching of .narinfo files
- Signature pre-computation

**Dependencies:**
- Requires: /var/lib/harmonia/cache-key
- After: nix-build-server-init.service
- Wants: nix-daemon.service

**Configuration:**
```nix
services.harmonia = {
  enable = true;
  signKeyPath = "/var/lib/harmonia/cache-key";
  settings = {
    bind = "[::]:${cachePort}";
    priority = 40;
  };
};
```

---

## AGENT 5: Tailscale Network Manager

### Purpose
Establish secure mesh network and advertise server hostname.

### Lifecycle
- **Initialization**: Starts early in boot
- **Operation**: Maintains persistent VPN connection
- **Recovery**: Auto-restart, auto-reconnect

### Behavior Specification

**Startup Sequence:**
```
1. Read /var/lib/tailscale/tailscaled.state
   - IF exists: Resume existing session
   - ELSE: Wait for manual "tailscale up"

2. Establish connection to Tailscale control plane

3. Advertise routes (if configured):
   - useRoutingFeatures = "both"
   - Accept subnet routes
   - Accept exit node

4. Register hostname with MagicDNS:
   - Hostname: ${config.networking.hostName}
   - Resolves to: Tailscale IP (100.x.y.z)

5. Maintain connection
```

**Network Behavior:**
- All build-server traffic flows through tailscale0 interface
- Firewall configured to trust only tailscale0
- MagicDNS provides: build-server, build-server.tail-scale.ts.net
- IPv4 and IPv6 supported
- Automatic hole-punching/relay selection

**Integration Points:**
- API server binds to [::] but only accessible via tailscale0 (firewall)
- Cache server same behavior
- Web UI accessible via Tailscale hostname

**Configuration:**
```nix
services.tailscale = {
  enable = true;
  useRoutingFeatures = "both";
};

networking.hostName = "${config.services.nix-build-server.hostname}";

networking.firewall = {
  enable = true;
  trustedInterfaces = [ "tailscale0" ];
  allowedTCPPorts = [ ];  # All access via Tailscale
};
```

---

## Agent Interaction Matrix

```
         │ KeyMgr │ API │ BuildOrch │ Harmonia │ Tailscale │
─────────┼────────┼─────┼───────────┼──────────┼───────────┤
KeyMgr   │   -    │  →  │     →     │    →→    │     -     │
API      │   ←    │  -  │    →→     │    ←     │     ←     │
BuildOrch│   -    │  ←  │     -     │    →     │     -     │
Harmonia │   ←←   │  →  │     ←     │    -     │     ←     │
Tailscale│   -    │  →  │     -     │    →     │     -     │

Legend:
  →   : Reads from
  →→  : Hard dependency (must exist)
  ←   : Provides data to
  ←←  : Critical provider
```

**Interaction Details:**

1. **KeyMgr → Harmonia**: Provides signing key (critical)
2. **KeyMgr → API**: Provides public key for /info endpoint
3. **API → BuildOrch**: Triggers builds via systemctl
4. **BuildOrch → Harmonia**: Populates /nix/store with packages
5. **API → Harmonia**: Checks status via systemctl
6. **Tailscale → API**: Network layer for HTTP access
7. **Tailscale → Harmonia**: Network layer for cache access

---

## State Management

### Persistent State Locations

**Key Material:**
- `/var/lib/harmonia/cache-key` (600, harmonia:harmonia)
  - Generated once, persists forever
  - Changing this invalidates all client trust

**Build State:**
- `${DATA_DIR}/builds/${repo}/` - Git repositories
- `${DATA_DIR}/status/${repo}.json` - Build status
- `${DATA_DIR}/logs/${repo}.log` - Build logs

**Nix Store:**
- `/nix/store/*` - Built packages
  - Managed by nix-daemon
  - Garbage collected weekly
  - Referenced by Harmonia

**Tailscale State:**
- `/var/lib/tailscale/tailscaled.state` - Connection state
  - Persists across reboots
  - Re-auth required if deleted

### State Transitions

**Build Status State Machine:**
```
NULL → {is_running: false}
  ↓ (trigger)
{is_running: true, last_status: null}
  ↓ (build completes)
{is_running: false, last_status: "success", last_commit: "abc123"}
  OR
{is_running: false, last_status: "failed", last_commit: "abc123"}
  ↓ (trigger again)
{is_running: true, ...}  (loop)
```

**Service State Machine:**
```
inactive → starting → active → stopping → inactive
                     ↓
                   failed
                     ↓
                  restarting → active
```

---

## Failure Modes & Recovery

### Agent-Specific Failures

**KeyMgr Failure:**
- **Symptom**: Harmonia won't start
- **Detection**: systemctl status harmonia shows "key not found"
- **Recovery**: Automatic on next boot OR manual: systemctl restart nix-build-server-init

**API Server Failure:**
- **Symptom**: HTTP requests timeout
- **Detection**: systemctl status nix-build-server-api
- **Recovery**: Auto-restart after 10s, max 5 attempts
- **Mitigation**: Continue using cache, manual trigger via systemctl

**Build Orchestrator Failure:**
- **Symptom**: status.json shows "failed"
- **Detection**: GET /build/status/{repo} returns last_status: "failed"
- **Recovery**: Manual re-trigger OR fix repository and retry
- **Mitigation**: Previous successful builds still cached

**Harmonia Failure:**
- **Symptom**: Cache requests return connection refused
- **Detection**: systemctl status harmonia
- **Recovery**: Auto-restart by systemd
- **Mitigation**: Clients fall back to cache.nixos.org

**Tailscale Failure:**
- **Symptom**: hostname unreachable
- **Detection**: tailscale status shows "not running"
- **Recovery**: Auto-restart by systemd
- **Mitigation**: Use direct IP if known

### Cascade Failures

**Scenario: Disk Full**
```
1. Build fails (no space for /nix/store)
2. status.json update fails (no space)
3. Log write fails (no space)
→ Recovery: nix-collect-garbage -d, systemd alerts
```

**Scenario: Network Partition**
```
1. Tailscale connection lost
2. Clients can't reach server
3. Builds continue locally on server
→ Recovery: Automatic when network restored
→ Mitigation: Clients use cache.nixos.org
```

**Scenario: Key Corruption**
```
1. /var/lib/harmonia/cache-key becomes unreadable
2. Harmonia fails to start
3. Cache becomes unavailable
→ Recovery: Delete key, restart init service (generates new key)
→ Impact: All clients must update trusted-public-keys
```

---

## Monitoring & Observability

### Log Locations

**SystemD Journal:**
- `journalctl -u nix-build-server-init` - Key generation
- `journalctl -u nix-build-server-api` - API requests
- `journalctl -u nix-build-${repo}` - Build execution
- `journalctl -u harmonia` - Cache serving
- `journalctl -u tailscale` - Network events

**Application Logs:**
- `${DATA_DIR}/logs/${repo}.log` - Per-repository build logs
- API logs go to journal (structured with FastAPI)

### Metrics (Available via API)

**GET /health**
```json
{
  "status": "healthy",
  "cache_running": true,
  "repositories": ["nix-terminal", "nixvim"]
}
```

**GET /info**
```json
{
  "hostname": "build-server",
  "api_port": 8000,
  "cache_port": 5000,
  "cache_url": "http://build-server:5000",
  "public_key": "build-server:AbCdEf...",
  "repositories": ["nix-terminal", "nixvim"]
}
```

**GET /build/status/{repo}**
```json
{
  "is_running": false,
  "last_start": "2026-01-15T14:30:00Z",
  "last_finish": "2026-01-15T14:35:22Z",
  "last_status": "success",
  "last_commit": "abc1234",
  "repository": "nix-terminal"
}
```

### Health Checks

**Critical:**
- Harmonia responding on :5000
- Public key extractable
- Tailscale connected

**Warning:**
- Disk >80% full
- Build failed status
- API slow responses (>1s)

**Info:**
- Build triggered
- New commit built
- GC completed

---

## Security Model

### Agent Privileges

**KeyMgr (root):**
- Runs as: root (oneshot)
- Can: Generate keys, create directories, chown
- Cannot: Network access, persistent process

**API Server (builder):**
- Runs as: builder (unprivileged user)
- Can: Read status files, trigger systemctl via sudo
- Cannot: Write to /nix/store, modify keys
- Sudo: Limited to `systemctl start nix-build-*`

**Build Orchestrator (builder):**
- Runs as: builder
- Can: Clone repos, run nix build (populates /nix/store)
- Cannot: Modify system, access other users
- Network: Full (needs git clone)

**Harmonia (harmonia):**
- Runs as: harmonia (dedicated user)
- Can: Read /nix/store, sign packages
- Cannot: Write to /nix/store, modify packages
- Network: Listen on :5000 only

**Tailscale (root):**
- Runs as: root (needs network config)
- Can: Modify routing, create interfaces
- Cannot: Access user data

### Trust Boundaries

**External → Tailscale:**
- Encrypted WireGuard tunnel
- Authentication via Tailscale ACLs
- No public internet exposure

**Tailscale → API:**
- HTTP (plaintext within Tailscale)
- No authentication (network trust)
- Rate limiting via Tailscale

**API → SystemD:**
- Unix domain socket
- sudo with NOPASSWD for specific commands
- Command injection prevented (fixed service names)

**Client → Harmonia:**
- HTTP (plaintext within Tailscale)
- Signature verification (cryptographic trust)
- No authentication needed (signatures prove authenticity)

### Attack Surface

**Minimal:**
- No ports exposed to internet
- No password authentication
- No user input to system commands

**Mitigations:**
- Firewall: Only Tailscale interface trusted
- Sudo: Whitelisted commands only
- Nix: Signatures prevent MITM
- SystemD: Sandboxing for build processes

---

## Performance Characteristics

### Agent Resource Usage

**KeyMgr:**
- CPU: Negligible (runs once)
- Memory: <10MB
- Disk: 1KB (key file)
- Network: None

**API Server:**
- CPU: <1% idle, <5% under load
- Memory: 50-100MB (Python + FastAPI)
- Disk: Negligible (no persistent writes)
- Network: ~1KB/request

**Build Orchestrator:**
- CPU: 100% (multi-core during compilation)
- Memory: 500MB - 4GB (depends on package)
- Disk: Writes to /nix/store (GB-scale)
- Network: Git clone (MB), Nix download (GB)

**Harmonia:**
- CPU: <5% (I/O bound)
- Memory: 100-200MB
- Disk: Reads from /nix/store (streaming)
- Network: Limited by client bandwidth

**Tailscale:**
- CPU: <1%
- Memory: 50-100MB
- Disk: <1MB
- Network: Encapsulation overhead ~5%

### Throughput

**Build Server:**
- Concurrent builds: 1 per repository
- Build time: 5-60 minutes (package dependent)
- Cache serving: 50-100 MB/s per client

**API:**
- Requests/second: 100+ (FastAPI async)
- Latency: <50ms for status checks
- Concurrent clients: 50+ (websocket capable)

### Scalability Limits

**Single Server:**
- Repositories: 10-20 (systemd service limit)
- Concurrent cache clients: 50-100
- /nix/store size: Limited by disk
- Build queue: Sequential (no parallelism)

**Workarounds:**
- Multiple build servers (different repos)
- Distributed cache (attic)
- Build prioritization (future enhancement)

---

## Configuration Interface

### Required Configuration

```nix
services.nix-build-server = {
  enable = true;  # REQUIRED: Start the service
  
  repositories = [  # REQUIRED: At least one repo
    {
      url = "https://github.com/user/repo";  # REQUIRED
      branch = "dev";  # REQUIRED
      name = "repo";  # REQUIRED: Unique identifier
    }
  ];
};
```

### Optional Configuration

```nix
services.nix-build-server = {
  hostname = "build-server";  # Default: "build-server"
  cachePort = 5000;  # Default: 5000
  apiPort = 8000;  # Default: 8000
  dataDir = "/var/lib/nix-build-server";  # Default
  user = "builder";  # Default: "builder"
  enableWebUI = true;  # Default: true
};
```

### Dynamic Behavior

**Adding Repository:**
```
1. Add to repositories list
2. nixos-rebuild switch
3. New systemd service created
4. New API endpoints available
5. Build can be triggered immediately
```

**Removing Repository:**
```
1. Remove from repositories list
2. nixos-rebuild switch
3. Service disabled (not deleted)
4. Status/logs preserved
5. /nix/store entries remain (GC'd later)
```

---

## Agent Communication Protocols

### API → Build Orchestrator
**Protocol:** systemd D-Bus
**Message:** StartUnit("nix-build-${repo}.service")
**Response:** Job ID (async)
**Timeout:** None (fire and forget)

### Build Orchestrator → Status File
**Protocol:** JSON file write
**Format:**
```json
{
  "is_running": bool,
  "last_start": "ISO8601",
  "last_finish": "ISO8601",
  "last_status": "success|failed|null",
  "last_commit": "git_sha_short",
  "repository": "repo_name"
}
```
**Atomicity:** Write to temp, rename

### API → Harmonia
**Protocol:** systemd D-Bus
**Message:** GetUnit("harmonia.service").ActiveState
**Response:** "active|inactive|failed"
**Frequency:** Per /health request

### Client → API
**Protocol:** HTTP/1.1 REST
**Endpoints:** See AGENT 2
**Auth:** None (Tailscale network trust)
**Format:** JSON

### Client → Harmonia
**Protocol:** HTTP/1.1 (Nix cache protocol)
**Flow:**
```
1. GET /nix-cache-info
2. GET /<storepath>.narinfo
3. Verify signature
4. GET /nar/<hash>.nar.xz
5. Decompress and install
```

---

## Testing & Validation

### Per-Agent Tests

**KeyMgr:**
```bash
# Test 1: First run generates key
rm -f /var/lib/harmonia/cache-key
systemctl start nix-build-server-init
test -f /var/lib/harmonia/cache-key  # Should exist
stat -c %a /var/lib/harmonia/cache-key | grep 600  # Should be 600

# Test 2: Idempotent
systemctl restart nix-build-server-init
# Should succeed, not regenerate
```

**API Server:**
```bash
# Test 1: Server responds
curl http://localhost:8000/health
# Expected: 200 OK

# Test 2: Repository trigger
curl -X POST http://localhost:8000/build/trigger/nix-terminal
# Expected: {"status": "triggered"} OR {"status": "already_running"}

# Test 3: Status check
curl http://localhost:8000/build/status/nix-terminal
# Expected: Valid JSON with BuildStatus schema
```

**Build Orchestrator:**
```bash
# Test 1: Manual execution
sudo -u builder /path/to/build-repository.sh \
  https://github.com/user/repo dev test-repo
# Expected: Exit 0, status file created

# Test 2: Status file
cat /var/lib/nix-build-server/status/test-repo.json
# Expected: Valid JSON with success status

# Test 3: Build output
ls /nix/store | grep <package-name>
# Expected: Packages exist
```

**Harmonia:**
```bash
# Test 1: Cache info
curl http://localhost:5000/nix-cache-info
# Expected: PublicKeys line with build-server:...

# Test 2: Package query
STORE_PATH=$(ls /nix/store | head -1)
curl http://localhost:5000/${STORE_PATH}.narinfo
# Expected: Valid narinfo OR 404
```

**Integration Test:**
```bash
# Full flow
curl -X POST http://build-server:8000/build/trigger/nix-terminal
sleep 60  # Wait for build
curl http://build-server:8000/build/status/nix-terminal
# Expected: last_status: "success"

# Client test
nix build .#package \
  --option substituters http://build-server:5000 \
  --option trusted-public-keys "build-server:..."
# Expected: Download from cache (not rebuild)
```

---

This specification provides complete behavioral documentation for implementing all autonomous 
components of the nix-build-server system. Each agent can be developed independently following 
these specifications and will integrate correctly via the defined interfaces.
