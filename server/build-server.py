#!/usr/bin/env -S uv run
# /// script
# dependencies = [
#   "fastapi>=0.115.0",
#   "uvicorn[standard]>=0.32.0",
#   "pydantic>=2.0.0",
# ]
# ///

from __future__ import annotations

import json
import logging
import os
import subprocess
from datetime import datetime
from pathlib import Path
from typing import Literal

from fastapi import FastAPI, HTTPException
from fastapi.responses import HTMLResponse
from pydantic import BaseModel

# Configuration
DATA_DIR = Path(os.getenv("BUILD_SERVER_DATA_DIR", "/var/lib/nix-build-server"))
HOSTNAME = os.getenv("BUILD_SERVER_HOSTNAME", "build-server")
API_PORT = int(os.getenv("BUILD_SERVER_API_PORT", "8000"))
CACHE_PORT = int(os.getenv("BUILD_SERVER_CACHE_PORT", "5000"))
ENABLE_WEB_UI = os.getenv("ENABLE_WEB_UI", "1") == "1"

# Logging
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger(__name__)

# Pydantic models
class BuildStatus(BaseModel):
    is_running: bool
    last_start: datetime | None = None
    last_finish: datetime | None = None
    last_status: Literal["success", "failed"] | None = None
    last_commit: str | None = None
    repository: str

class BuildTriggerResponse(BaseModel):
    status: Literal["triggered", "already_running"]
    message: str
    repository: str

class ServerInfo(BaseModel):
    hostname: str
    api_port: int
    cache_port: int
    cache_url: str
    public_key: str
    repositories: list[str]

class BuildLogs(BaseModel):
    logs: list[str]

class HealthCheck(BaseModel):
    status: Literal["healthy", "degraded", "down"]
    cache_running: bool
    repositories: list[str]

# FastAPI app
app = FastAPI(
    title="NixOS Build Server",
    version="0.1.0",
    description="Self-hosted build server with binary cache"
)

# Helper functions
def get_public_key() -> str:
    """Extract public key from Harmonia cache key."""
    try:
        with open("/var/lib/harmonia/cache-key", "rb") as f:
            result = subprocess.run(
                ["nix", "key", "convert-secret-to-public"],
                stdin=f,
                capture_output=True,
                text=True,
                check=True,
            )
        return result.stdout.strip()
    except Exception as e:
        logger.error(f"Failed to get public key: {e}")
        return "ERROR"

def get_available_repos() -> list[str]:
    """Query systemd for all nix-build-* services."""
    result = subprocess.run(
        ["systemctl", "list-units", "--all", "nix-build-*",
         "--no-pager", "--no-legend"],
        capture_output=True,
        text=True,
    )
    repos = []
    for line in result.stdout.split("\n"):
        if "nix-build-" in line:
            parts = line.split()
            if parts:
                service_name = parts[0].replace(".service", "")
                repo_name = service_name.replace("nix-build-", "")
                repos.append(repo_name)
    return sorted(set(repos))

def is_build_running(repo: str) -> bool:
    """Check if build service is active."""
    result = subprocess.run(
        ["systemctl", "is-active", f"nix-build-{repo}"],
        capture_output=True,
        text=True,
    )
    return result.stdout.strip() == "active"

def is_cache_running() -> bool:
    """Check if Harmonia is active."""
    result = subprocess.run(
        ["systemctl", "is-active", "harmonia"],
        capture_output=True,
        text=True,
    )
    return result.stdout.strip() == "active"

def get_build_status(repo: str) -> BuildStatus:
    """Read build status from file and merge with live status."""
    status_file = DATA_DIR / "status" / f"{repo}.json"

    if not status_file.exists():
        return BuildStatus(is_running=False, repository=repo)

    try:
        data = json.loads(status_file.read_text())
        status = BuildStatus(**data)
        status.is_running = is_build_running(repo)
        return status
    except Exception as e:
        logger.error(f"Error reading status for {repo}: {e}")
        return BuildStatus(is_running=is_build_running(repo), repository=repo)

def generate_web_ui_html(hostname: str, cache_port: int, public_key: str, statuses: dict) -> str:
    """Generate HTML for web UI."""
    repos_html = ""
    for repo, status in statuses.items():
        status_color = "green" if status.last_status == "success" else "red" if status.last_status == "failed" else "gray"
        running_badge = '<span style="background: orange; color: white; padding: 2px 6px; border-radius: 3px; font-size: 12px;">RUNNING</span>' if status.is_running else ""

        last_status_text = status.last_status or "never built"
        last_commit_text = status.last_commit or "N/A"
        last_finish_text = status.last_finish.strftime("%Y-%m-%d %H:%M:%S") if status.last_finish else "N/A"

        repos_html += f"""
        <div style="border: 1px solid #ddd; padding: 15px; margin: 10px 0; border-radius: 5px; background: #f9f9f9;">
            <h3 style="margin: 0 0 10px 0;">{repo} {running_badge}</h3>
            <p style="margin: 5px 0;"><strong>Status:</strong> <span style="color: {status_color};">{last_status_text}</span></p>
            <p style="margin: 5px 0;"><strong>Last Commit:</strong> {last_commit_text}</p>
            <p style="margin: 5px 0;"><strong>Last Finish:</strong> {last_finish_text}</p>
            <div style="margin-top: 10px;">
                <button onclick="triggerBuild('{repo}')" style="background: #4CAF50; color: white; border: none; padding: 8px 16px; cursor: pointer; border-radius: 3px; margin-right: 5px;">
                    Trigger Build
                </button>
                <a href="/build/logs/{repo}?lines=100" target="_blank" style="text-decoration: none;">
                    <button style="background: #2196F3; color: white; border: none; padding: 8px 16px; cursor: pointer; border-radius: 3px;">
                        View Logs
                    </button>
                </a>
            </div>
        </div>
        """

    return f"""
    <!DOCTYPE html>
    <html>
    <head>
        <title>NixOS Build Server - {hostname}</title>
        <meta http-equiv="refresh" content="5">
        <style>
            body {{
                font-family: Arial, sans-serif;
                max-width: 1200px;
                margin: 0 auto;
                padding: 20px;
                background: #f5f5f5;
            }}
            .header {{
                background: white;
                padding: 20px;
                border-radius: 5px;
                margin-bottom: 20px;
                box-shadow: 0 2px 4px rgba(0,0,0,0.1);
            }}
            .info {{
                background: #e3f2fd;
                padding: 15px;
                border-radius: 5px;
                margin: 15px 0;
                border-left: 4px solid #2196F3;
            }}
            code {{
                background: #f5f5f5;
                padding: 2px 6px;
                border-radius: 3px;
                font-family: monospace;
            }}
        </style>
    </head>
    <body>
        <div class="header">
            <h1>🏗️ NixOS Build Server</h1>
            <p><strong>Hostname:</strong> {hostname}</p>
            <p><strong>API Port:</strong> {API_PORT}</p>
            <p><strong>Cache URL:</strong> <code>http://{hostname}:{cache_port}</code></p>
        </div>

        <div class="info">
            <h3>📦 Binary Cache Configuration</h3>
            <p>Add this to your NixOS configuration to use this cache:</p>
            <pre style="background: white; padding: 10px; border-radius: 3px; overflow-x: auto;">nix.settings = {{
  substituters = [ "http://{hostname}:{cache_port}" ];
  trusted-public-keys = [ "{public_key}" ];
}};</pre>
        </div>

        <h2>Repositories</h2>
        {repos_html}

        <div style="margin-top: 30px; padding: 15px; background: white; border-radius: 5px; text-align: center; color: #666; font-size: 12px;">
            Auto-refreshes every 5 seconds • <a href="/info" style="color: #2196F3;">API Info</a> • <a href="/health" style="color: #2196F3;">Health Check</a>
        </div>

        <script>
        function triggerBuild(repo) {{
            fetch(`/build/trigger/${{repo}}`, {{ method: 'POST' }})
                .then(response => response.json())
                .then(data => {{
                    alert(data.message);
                    location.reload();
                }})
                .catch(error => alert('Error: ' + error));
        }}
        </script>
    </body>
    </html>
    """

# Endpoints
@app.get("/", response_class=HTMLResponse)
async def web_ui():
    """Web UI for monitoring builds."""
    if not ENABLE_WEB_UI:
        return HTMLResponse("<h1>Web UI disabled</h1>")

    repos = get_available_repos()
    statuses = {repo: get_build_status(repo) for repo in repos}
    public_key = get_public_key()

    html = generate_web_ui_html(HOSTNAME, CACHE_PORT, public_key, statuses)
    return HTMLResponse(html)

@app.get("/info", response_model=ServerInfo)
async def server_info():
    """Get server information and public key."""
    return ServerInfo(
        hostname=HOSTNAME,
        api_port=API_PORT,
        cache_port=CACHE_PORT,
        cache_url=f"http://{HOSTNAME}:{CACHE_PORT}",
        public_key=get_public_key(),
        repositories=get_available_repos(),
    )

@app.post("/build/trigger/{repository}", response_model=BuildTriggerResponse)
async def trigger_build(repository: str):
    """Trigger build for repository."""
    repos = get_available_repos()
    if repository not in repos:
        raise HTTPException(
            status_code=404,
            detail=f"Repository '{repository}' not found"
        )

    if is_build_running(repository):
        return BuildTriggerResponse(
            status="already_running",
            message=f"Build for {repository} already in progress",
            repository=repository,
        )

    try:
        subprocess.run(
            ["sudo", "systemctl", "start", f"nix-build-{repository}"],
            check=True,
            capture_output=True,
            text=True,
        )
        logger.info(f"Build triggered for {repository}")
        return BuildTriggerResponse(
            status="triggered",
            message=f"Build started for {repository}",
            repository=repository,
        )
    except subprocess.CalledProcessError as e:
        logger.error(f"Failed to trigger build for {repository}: {e.stderr}")
        raise HTTPException(
            status_code=500,
            detail=f"Build trigger failed: {e.stderr}"
        )

@app.get("/build/status/{repository}", response_model=BuildStatus)
async def build_status(repository: str):
    """Get build status for repository."""
    repos = get_available_repos()
    if repository not in repos:
        raise HTTPException(
            status_code=404,
            detail=f"Repository '{repository}' not found"
        )

    return get_build_status(repository)

@app.get("/build/logs/{repository}", response_model=BuildLogs)
async def build_logs(repository: str, lines: int = 100):
    """Get build logs for repository."""
    repos = get_available_repos()
    if repository not in repos:
        raise HTTPException(
            status_code=404,
            detail=f"Repository '{repository}' not found"
        )

    log_file = DATA_DIR / "logs" / f"{repository}.log"

    if not log_file.exists():
        return BuildLogs(logs=[])

    # Limit lines to prevent memory exhaustion
    lines = min(lines, 10000)

    result = subprocess.run(
        ["tail", "-n", str(lines), str(log_file)],
        capture_output=True,
        text=True,
    )
    return BuildLogs(logs=result.stdout.split("\n"))

@app.get("/health", response_model=HealthCheck)
async def health():
    """Health check endpoint."""
    cache_running = is_cache_running()
    repos = get_available_repos()

    if not cache_running:
        status = "degraded"
    else:
        status = "healthy"

    return HealthCheck(
        status=status,
        cache_running=cache_running,
        repositories=repos,
    )

# Main
if __name__ == "__main__":
    import uvicorn

    uvicorn.run(
        app,
        host="0.0.0.0",
        port=API_PORT,
        log_level="info",
    )
