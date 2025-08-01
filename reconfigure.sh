#!/bin/sh
set -e

# Prompt for new credentials and URL
printf "Enter new VPN username: "
read -r VPN_USER

printf "Enter new VPN password (visible): "
read -r VPN_PASS

printf "Enter new VPN server URL (e.g. vpn.example.com/?secret): "
read -r VPN_URL

# Extract domain from full URL (before first slash or ?)
VPN_DOMAIN=$(echo "$VPN_URL" | cut -d/ -f1 | cut -d'?' -f1)

# Resolve IP of the VPN domain
VPN_IP=$(nslookup "$VPN_DOMAIN" | awk '/^Address: / { print $2 }' | tail -n1)
if [ -z "$VPN_IP" ]; then
  echo "❌ Failed to resolve VPN IP for $VPN_DOMAIN"
  exit 1
fi

# Update UCI settings for oc0
uci set network.oc0.username="$VPN_USER"
uci set network.oc0.password="$VPN_PASS"
uci set network.oc0.server="$VPN_URL"
uci commit network

# Update stored IP for hotplug routing
echo "$VPN_IP" > /etc/vpn-server-ip
chmod 600 /etc/vpn-server-ip

# Restart OpenConnect VPN interface
ifdown oc0 2>/dev/null || true
ifup oc0

echo "✅ VPN credentials and routing IP updated:"
echo "   - Username: $VPN_USER"
echo "   - Server:   $VPN_URL"
echo "   - VPN IP:   $VPN_IP"
