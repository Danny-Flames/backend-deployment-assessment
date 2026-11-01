#!/bin/bash
#
# user_data for the MongoDB EC2 instance (Amazon Linux 2).
#
# Installs MongoDB Community Edition 8.0 from the official MongoDB yum repo,
# configures it to listen on the instance's private network interface, and
# starts it as a single-node replica set.
#
# Why a replica set rather than a standalone server:
#   internal/handlers/user.go uses StartSession() + WithTransaction(). MongoDB
#   only permits multi-document transactions on a replica set or a sharded
#   cluster, so a standalone mongod would fail at runtime with
#   "Transaction numbers are only allowed on a replica set member or mongos".
#
# Network exposure is controlled entirely by the MongoDB security group, which
# accepts port 27017 from the backend security group only. The instance has no
# public IP and sits in a private subnet.
#
# Output is written to /var/log/user-data.log for debugging.

set -euxo pipefail
exec > >(tee -a /var/log/user-data.log) 2>&1

echo "[user_data] mongodb_setup.sh starting at $(date -u +'%Y-%m-%dT%H:%M:%SZ')"

# --- 1. MongoDB yum repository ---------------------------------------------
cat > /etc/yum.repos.d/mongodb-org-8.0.repo <<'REPO'
[mongodb-org-8.0]
name=MongoDB Repository
baseurl=https://repo.mongodb.org/yum/amazon/2/mongodb-org/8.0/x86_64/
gpgcheck=1
enabled=1
gpgkey=https://pgp.mongodb.com/server-8.0.asc
REPO

# --- 2. Install -------------------------------------------------------------
yum install -y mongodb-org

# --- 3. Configure -----------------------------------------------------------
# Bind to loopback plus this instance's private IP so the backend server can
# reach it across the VPC, without ever listening on a public interface.
PRIVATE_IP="$(curl -fsSL http://169.254.169.254/latest/meta-data/local-ipv4)"

cat > /etc/mongod.conf <<CONF
storage:
  dbPath: /var/lib/mongo
systemLog:
  destination: file
  logAppend: true
  path: /var/log/mongodb/mongod.log
net:
  port: 27017
  bindIp: 127.0.0.1,${PRIVATE_IP}
processManagement:
  timeZoneInfo: /usr/share/zoneinfo
replication:
  replSetName: rs0
CONF

# --- 4. Start ---------------------------------------------------------------
systemctl enable --now mongod

# Give mongod a moment to accept connections before initiating the replica set.
for _ in $(seq 1 30); do
  if mongosh --quiet --eval 'db.adminCommand({ ping: 1 })' >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

# --- 5. Initiate the single-node replica set --------------------------------
# Guarded so that a re-run (or an instance reboot) does not fail.
mongosh --quiet --eval "
  try {
    rs.status();
    print('Replica set already initiated.');
  } catch (e) {
    rs.initiate({_id: 'rs0', members: [{_id: 0, host: '${PRIVATE_IP}:27017'}]});
    print('Replica set rs0 initiated.');
  }
"

echo "[user_data] mongodb_setup.sh completed successfully at $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
touch /var/log/mongodb-setup-complete
