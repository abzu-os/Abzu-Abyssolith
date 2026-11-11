#!/usr/bin/env bash
set -euo pipefail

RPM_URL="https://github.com/GyulyVGC/sniffnet/releases/latest/download/Sniffnet_LinuxRPM_x86_64.rpm"

curl -fLs "${RPM_URL}" -o /tmp/sniffnet.rpm
dnf install -y --nogpgcheck /tmp/sniffnet.rpm
rm -f /tmp/sniffnet.rpm

# Grant the binary the capabilities it needs to inspect traffic without full root
command -v setcap >/dev/null || dnf install -y libcap
setcap cap_net_raw,cap_net_admin=eip /usr/bin/sniffnet
