#!/bin/bash
set -euo pipefail

# Auto-detect Ubuntu codename
CODENAME=$(lsb_release -cs 2>/dev/null || true)
if [ -z "$CODENAME" ]; then
  CODENAME=$(grep -oP '^VERSION_CODENAME=\K.*' /etc/os-release 2>/dev/null || true)
fi
CODENAME=${CODENAME//\"/}

if [ -z "$CODENAME" ]; then
  echo "Could not detect Ubuntu version!" >&2
  exit 1
fi

echo "Detected codename: $CODENAME"

MIRROR="http://mirror.arvancloud.ir/ubuntu"
STAMP=$(date +%F-%H%M%S)

# Prefer the new deb822 format if it exists (Ubuntu 24.04+ / noble)
if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then
  echo "Using deb822 format: /etc/apt/sources.list.d/ubuntu.sources"

  sudo cp /etc/apt/sources.list.d/ubuntu.sources \
    /etc/apt/sources.list.d/ubuntu.sources.bak.$STAMP

  sudo tee /etc/apt/sources.list.d/ubuntu.sources > /dev/null <<EOF
Types: deb
URIs: $MIRROR/
Suites: $CODENAME $CODENAME-updates $CODENAME-backports $CODENAME-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF

  echo "ubuntu.sources updated successfully."

  # Prevent duplicate entries from the legacy sources.list
  if [ -f /etc/apt/sources.list ]; then
    sudo cp /etc/apt/sources.list /etc/apt/sources.list.bak.$STAMP

    # Comment out any active Arvan mirror lines
    sudo sed -i -E 's|^([^#].*mirror\.arvancloud\.ir.*)$|#\1|' /etc/apt/sources.list

    echo "Legacy /etc/apt/sources.list Arvan lines commented out."
  fi

# Fallback to legacy format for older Ubuntu versions
elif [ -f /etc/apt/sources.list ]; then
  echo "Using legacy format: /etc/apt/sources.list"

  sudo cp /etc/apt/sources.list /etc/apt/sources.list.bak.$STAMP

  sudo tee /etc/apt/sources.list > /dev/null <<EOF
deb $MIRROR/ $CODENAME main restricted universe multiverse
deb $MIRROR/ $CODENAME-updates main restricted universe multiverse
deb $MIRROR/ $CODENAME-backports main restricted universe multiverse
deb $MIRROR/ $CODENAME-security main restricted universe multiverse
EOF

  echo "sources.list updated successfully."

else
  echo "No APT sources file found!" >&2
  exit 1
fi

echo "Updating package lists..."
sudo apt update

echo "Done. If you see any errors or warnings, send them to me."
