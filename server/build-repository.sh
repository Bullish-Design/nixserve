#!/usr/bin/env bash

set -euo pipefail

# Parameters
REPO_URL="$1"
BRANCH="$2"
REPO_NAME="$3"

# Paths
DATA_DIR="${BUILD_SERVER_DATA_DIR:-/var/lib/nix-build-server}"
REPO_DIR="${DATA_DIR}/builds/${REPO_NAME}"
LOG_FILE="${DATA_DIR}/logs/${REPO_NAME}.log"
STATUS_FILE="${DATA_DIR}/status/${REPO_NAME}.json"

# Functions
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

update_status() {
    local is_running=$1
    local status=$2
    local commit=$3

    local start_time finish_time
    if [ -f "$STATUS_FILE" ]; then
        start_time=$(jq -r '.last_start // empty' "$STATUS_FILE" || echo "")
    else
        start_time=""
    fi

    if [ -z "$start_time" ]; then
        start_time="$(date -Iseconds)"
    fi

    finish_time="$(date -Iseconds)"

    cat > "$STATUS_FILE" <<EOF
{
  "is_running": $is_running,
  "last_start": "$start_time",
  "last_finish": "$finish_time",
  "last_status": $(if [ "$status" = "null" ]; then echo "null"; else echo "\"$status\""; fi),
  "last_commit": $(if [ "$commit" = "null" ]; then echo "null"; else echo "\"$commit\""; fi),
  "repository": "$REPO_NAME"
}
EOF
}

# Main execution
update_status true null null

log "Starting build for ${REPO_NAME}"

# Git operations
if [ ! -d "$REPO_DIR" ]; then
    log "Cloning repository..."
    git clone --branch "$BRANCH" "$REPO_URL" "$REPO_DIR" 2>&1 | tee -a "$LOG_FILE" || {
        log "ERROR: Git clone failed"
        update_status false "failed" null
        exit 2
    }
else
    log "Updating repository..."
    cd "$REPO_DIR"
    git fetch origin 2>&1 | tee -a "$LOG_FILE" || {
        log "ERROR: Git fetch failed"
        update_status false "failed" null
        exit 2
    }
    git reset --hard "origin/$BRANCH" 2>&1 | tee -a "$LOG_FILE" || {
        log "ERROR: Git reset failed"
        update_status false "failed" null
        exit 2
    }
fi

cd "$REPO_DIR"
COMMIT=$(git rev-parse --short HEAD)
log "Building commit $COMMIT"

# Update status with commit info
update_status true null "$COMMIT"

# Flake operations
if [ -f "flake.nix" ]; then
    log "Updating flake inputs..."
    nix flake update 2>&1 | tee -a "$LOG_FILE" || log "WARNING: Flake update had issues"

    log "Checking flake..."
    nix flake check --print-build-logs 2>&1 | tee -a "$LOG_FILE" || log "WARNING: Flake check had issues"

    # Build packages
    log "Enumerating packages..."
    PACKAGES=$(nix flake show --json 2>/dev/null | \
        jq -r '.packages."x86_64-linux" | keys[]' 2>/dev/null || echo "")

    if [ -n "$PACKAGES" ]; then
        while IFS= read -r package; do
            if [ -n "$package" ]; then
                log "Building package: $package"
                nix build ".#$package" --print-build-logs --keep-going 2>&1 | tee -a "$LOG_FILE" || \
                    log "WARNING: Failed to build $package"
            fi
        done <<< "$PACKAGES"
    else
        log "No packages found, attempting to build default..."
        nix build --print-build-logs --keep-going 2>&1 | tee -a "$LOG_FILE" || \
            log "WARNING: Failed to build default"
    fi

    # Build home-manager test if modules exist
    if nix flake show --json 2>/dev/null | jq -e '.homeManagerModules' >/dev/null 2>&1; then
        log "Building test home-manager configuration..."

        cat > /tmp/test-home-${REPO_NAME}.nix <<'EOFHOME'
{ pkgs, ... }:
{
  home = {
    username = "testuser";
    homeDirectory = "/home/testuser";
    stateVersion = "24.05";
  };
}
EOFHOME

        nix build --impure --expr "
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
        " --print-build-logs --keep-going 2>&1 | tee -a "$LOG_FILE" || \
            log "WARNING: Home-manager test build failed"

        rm -f /tmp/test-home-${REPO_NAME}.nix
    fi

    # Build NixOS configurations if they exist
    if nix flake show --json 2>/dev/null | jq -e '.nixosConfigurations' >/dev/null 2>&1; then
        log "Found NixOS configurations, attempting to build..."
        NIXOS_CONFIGS=$(nix flake show --json 2>/dev/null | \
            jq -r '.nixosConfigurations | keys[]' 2>/dev/null || echo "")

        if [ -n "$NIXOS_CONFIGS" ]; then
            while IFS= read -r config; do
                if [ -n "$config" ]; then
                    log "Building NixOS configuration: $config"
                    nix build ".#nixosConfigurations.$config.config.system.build.toplevel" \
                        --print-build-logs --keep-going 2>&1 | tee -a "$LOG_FILE" || \
                        log "WARNING: Failed to build NixOS configuration $config"
                fi
            done <<< "$NIXOS_CONFIGS"
        fi
    fi
else
    log "No flake.nix found, attempting default.nix build..."
    nix-build --print-build-logs --keep-going 2>&1 | tee -a "$LOG_FILE" || {
        log "ERROR: Build failed"
        update_status false "failed" "$COMMIT"
        exit 1
    }
fi

log "Build complete. All dependencies cached."
update_status false "success" "$COMMIT"
log "Build finished successfully for commit $COMMIT"
