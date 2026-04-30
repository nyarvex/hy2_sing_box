#!/bin/bash
[ "$EUID" -ne 0 ] && exit 1

chattr -i /etc/resolv.conf 2>/dev/null || true
rm -f /etc/resolv.conf

mkdir -p /etc/systemd
cat > /etc/systemd/resolved.conf << 'EOF'
[Resolve]
DNS=94.140.14.14 94.140.15.15 2a10:50c0::ad1:ff 2a10:50c0::ad2:ff
FallbackDNS=
DNSSEC=yes
DNSOverTLS=no
DNSOverHTTPS=dns.adguard-dns.com
Cache=yes
ReadEtcHosts=yes
LLMNR=no
MulticastDNS=no
DNSStubListener=yes
EOF

systemctl restart systemd-resolved 2>/dev/null || true
systemctl enable systemd-resolved 2>/dev/null || true

if [ -e /run/systemd/resolve/stub-resolv.conf ]; then
    ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
elif [ -e /run/systemd/resolve/resolv.conf ]; then
    ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
else
    echo -e "nameserver 94.140.14.14\nnameserver 94.140.15.15" > /etc/resolv.conf
    chattr +i /etc/resolv.conf 2>/dev/null || true
fi
