#!/bin/bash
# Description: This script updates the Nimbus unified client (EL+CL) to the latest version.

# Web3 Pi - Nimbus unified client version update
# https://github.com/status-im/nimbus-eth1

# /releases/latest returns the "nightly" tag for nimbus-eth1, so pick the newest v* release instead
NU_RELEASES_URL="https://api.github.com/repos/status-im/nimbus-eth1/releases?per_page=15"
NU_RELEASE_JSON=$(curl -s "$NU_RELEASES_URL" | jq '[.[] | select(.tag_name | startswith("v"))][0]')
NU_LATEST=$(echo "$NU_RELEASE_JSON" | jq -r .tag_name)
# nimbus --version prints e.g. "Nimbus/v0.3.1-47d76a76/linux-arm64/Nim-2.2.10"
NU_CURRENT=$(nimbus --version | head -n 1 | grep -o 'v[0-9]\+\.[0-9]\+\.[0-9]\+' | head -n 1)

if [ "$NU_LATEST" = "$NU_CURRENT" ]; then
	echo "Nimbus unified client is up to date (version: $NU_CURRENT)."
	exit 0
else
	echo "Update available: current version is $NU_CURRENT, but latest version is $NU_LATEST."
fi

# Check for required privileges
if [ "$EUID" -ne 0 ]; then
	echo -e "\nRoot privileges are required. Re-run with sudo"
	exit 1
fi

# Stop the unified client service if it is running (exact unit name - do not
# substring-match "nimbus", that would also catch w3p_nimbus-beacon.service)
NU_WAS_RUNNING=false
if systemctl is-active --quiet w3p_nimbus-unified.service; then
	NU_WAS_RUNNING=true
	echo -e "\nStopping w3p_nimbus-unified.service..."
	systemctl stop w3p_nimbus-unified.service
fi

# Update the binary
echo -e "\nDownloading latest version..."
NU_BINARIES_URL=$(echo "$NU_RELEASE_JSON" | jq -r '.assets[] | select(.name | test("^nimbus-linux-arm64-.*\\.tar\\.gz$")) | .browser_download_url')
wget -O /tmp/nimbus-unified.tar.gz "$NU_BINARIES_URL"
mkdir -p /tmp/nimbus-unified
tar -xzf /tmp/nimbus-unified.tar.gz -C /tmp/nimbus-unified
# Tarball layout: ./build/nimbus
mv /tmp/nimbus-unified/build/nimbus /usr/bin/nimbus
chmod +x /usr/bin/nimbus
rm -rf /tmp/nimbus-unified /tmp/nimbus-unified.tar.gz

# Restart the service if it was running before the update
if [ "$NU_WAS_RUNNING" = true ]; then
	echo -e "\nStarting w3p_nimbus-unified.service..."
	systemctl start w3p_nimbus-unified.service
fi

# Check if update was successful
NU_CURRENT=$(nimbus --version | head -n 1 | grep -o 'v[0-9]\+\.[0-9]\+\.[0-9]\+' | head -n 1)

if [ "$NU_LATEST" = "$NU_CURRENT" ]; then
	echo -e "\nNimbus unified client updated successfully (version: $NU_CURRENT)."
	exit 0
else
	echo -e "\nUpdate failed. Current Nimbus unified client version: $NU_CURRENT, but the latest is: $NU_LATEST"
	exit 2
fi
