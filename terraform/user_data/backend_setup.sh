#!/bin/bash
#
# user_data for the Backend EC2 instance (Amazon Linux 2).
#
# Installs Docker, the Docker Compose v2 CLI plugin and git, so the backend
# application can be cloned and started with `docker compose up -d`.
#
# Notes on Amazon Linux 2:
#   * Docker ships through amazon-linux-extras, not the default yum repos.
#   * AL2 has no `docker-compose-plugin` package, so the Compose v2 plugin is
#     installed manually into the Docker CLI plugins directory. Installing it
#     there (rather than as standalone `docker-compose`) is what makes the
#     modern `docker compose` subcommand work.
#
# Output is written to /var/log/user-data.log for debugging, and a marker file
# is written on success so it is easy to confirm the script finished.

set -euxo pipefail
exec > >(tee -a /var/log/user-data.log) 2>&1

echo "[user_data] backend_setup.sh starting at $(date -u +'%Y-%m-%dT%H:%M:%SZ')"

COMPOSE_VERSION="v2.39.1"

# --- 1. System packages -----------------------------------------------------
yum update -y
yum install -y git

# --- 2. Docker engine -------------------------------------------------------
amazon-linux-extras install -y docker
systemctl enable --now docker

# Let the default ec2-user run docker without sudo. This takes effect on the
# next login, which is why the README tells you to log out and back in.
usermod -aG docker ec2-user

# --- 3. Docker Compose v2 (CLI plugin) --------------------------------------
# Installed for all users under /usr/local/lib so that both ec2-user and root
# get the `docker compose` subcommand.
install -d -m 0755 /usr/local/lib/docker/cli-plugins
curl -fsSL \
  "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-x86_64" \
  -o /usr/local/lib/docker/cli-plugins/docker-compose
chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

# --- 4. Verify --------------------------------------------------------------
docker --version
docker compose version

echo "[user_data] backend_setup.sh completed successfully at $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
touch /var/log/backend-setup-complete
