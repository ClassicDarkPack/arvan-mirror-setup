#!/bin/bash

# Auto-detect Ubuntu codename
CODENAME=$(lsb_release -cs 2>/dev/null || grep VERSION_CODENAME /etc/os-release | cut -d= -f2)

if [ -z "$CODENAME" ]; then
  echo "Could not detect Ubuntu version!"
  exit 1
fi

echo "Detected codename: $CODENAME"

MIRROR="http://mirror.arvancloud.ir/ubuntu"

# ---------- Legacy format: sources.list ----------
if [ -f /etc/apt/sources.list ]; then
  sudo cp /etc/apt/sources.list /etc/apt/sources.list.bak
  sudo bash -c "cat > /etc/apt/sources.list" << EOF
deb $MIRROR/ $CODENAME main restricted universe multiverse
deb $MIRROR/ $CODENAME-updates main restricted universe multiverse
deb $MIRROR/ $CODENAME-backports main restricted universe multiverse
deb $MIRROR/ $CODENAME-security main restricted universe multiverse
EOF
  echo "sources.list updated successfully."
fi

# ---------- New format: ubuntu.sources (deb822, noble and later) ----------
if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then
  sudo cp /etc/apt/sources.list.d/ubuntu.sources /etc/apt/sources.list.d/ubuntu.sources.bak
  sudo bash -c "cat > /etc/apt/sources.list.d/ubuntu.sources" << EOF
Types: deb
URIs: $MIRROR/
Suites: $CODENAME $CODENAME-updates $CODENAME-backports $CODENAME-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
  echo "ubuntu.sources updated successfully."
fi

# ---------- Final update ----------
echo "Updating package lists..."
sudo apt update

echo "Done. If you see any errors or warnings, send them to me."
