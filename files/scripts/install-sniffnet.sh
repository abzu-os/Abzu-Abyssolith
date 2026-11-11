#!/usr/bin/env bash
set -euo pipefail

SNIFFNET_VERSION="1.3.0"  # Check https://github.com/GyulyVGC/sniffnet/releases for the latest
RPM_URL="https://github.com/GyulyVGC/sniffnet/releases/download/v${SNIFFNET_VERSION}/sniffnet-${SNIFFNET_VERSION}-1.x86_64.rpm"

curl -fLs "${RPM_URL}" -o /tmp/sniffnet.rpm
dnf install -y /tmp/sniffnet.rpm
rm -f /tmp/sniffnet.rpm

# Grant the binary the capabilities it needs to inspect traffic without full root
setcap cap_net_raw,cap_net_admin=eip /usr/bin/sniffnet
