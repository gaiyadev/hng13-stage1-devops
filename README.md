# DevOps Intern — Stage 1 Deployment Script

This repository contains `deploy.sh`, a Bash script that automates setting up and deploying a Dockerized application to a remote Linux server.

## Features

- Interactive prompts for Git repo, PAT, branch, remote SSH details, SSH key, and container port.
- Clones or updates the repository locally (supports branch selection).
- Transfers files to remote server using `rsync` (or `scp` fallback).
- Installs Docker, Docker Compose, and Nginx on remote (attempts to use distro package manager or Docker install script).
- Builds and runs containers (supports `docker-compose.yml` or `Dockerfile`).
- Configures Nginx as a reverse proxy to the app's internal port.
- Validates deployment with `curl`.
- Logs all actions to `./logs/deploy_YYYYMMDD_HHMMSS.log`.
- Idempotent behavior: stops old containers before redeploy.
- `--cleanup` flag to remove deployed resources.

## Usage

1. Make the script executable:

```bash
chmod +x deploy.sh
```

2. Run interactively:

```bash
./deploy.sh
```

You'll be prompted for:

- Git repository URL (HTTPS)
- Personal Access Token (hidden input)
- Branch (defaults to `main`)
- Remote SSH username
- Remote server IP/hostname
- SSH key path (e.g. `~/.ssh/id_rsa`)
- Application internal container port (e.g. `3000`)
- Remote project directory (optional)

3. To cleanup deployed resources:

```bash
./deploy.sh --cleanup
```

## Notes & Limitations

- The script attempts to support both Debian/Ubuntu (apt) and RHEL/CentOS (yum) based systems. It uses the official Docker installation script when necessary.
- You must supply a PAT if the repo is private. The PAT is used to clone the repo over HTTPS; it is not stored by the script beyond the git clone operation.
- For production use, consider adding proper TLS (Certbot + Let's Encrypt) and hardened Nginx config. This script creates a simple config that listens on port 80.
- The script assumes the remote user can use `sudo` without interactive password prompts for some operations. If `sudo` requires a password, the script may fail unless you adapt it.
- This is intended as a starting point — extend and secure as needed.
