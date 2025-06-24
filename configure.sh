#!/bin/sh
set -e

printf "Enter VPN username: "
read -r VPN_USER

printf "Enter VPN password (visible): "
read -r VPN_PASS

printf "Enter VPN server URL (e.g. vpn.example.com/?secret): "
read -r VPN_URL

VPN_DOMAIN=$(echo "$VPN_URL" | cut -d/ -f1)
VPN_IP=$(nslookup "$VPN_DOMAIN" | awk '/^Address: / { print $2 }' | tail -n1)
if [ -z "$VPN_IP" ]; then
  echo "Failed to resolve VPN IP"
  exit 1
fi

echo "$VPN_IP" > /etc/vpn-server-ip

opkg update && opkg install openconnect luci-proto-openconnect

# HOTPLUGS HERE

cat << 'EOF' > /etc/hotplug.d/iface/10-store-wan-route
#!/bin/sh

LOG="/var/log/hp-wan"
echo "$(date) HOTPLUG EVENT: $ACTION on $INTERFACE" >> $LOG

[ "$ACTION" = "ifup" ] || exit 0

case "$INTERFACE" in
  wan|wwan)
    ;;
  *)
    echo "Ignoring interface $INTERFACE" >> $LOG
    exit 0
    ;;
esac

for i in $(seq 1 10); do
  WAN_GW=$(ubus call network.interface.$INTERFACE status | jsonfilter -e '@.route[@.target="0.0.0.0"].nexthop')
  WAN_DEV=$(ubus call network.interface.$INTERFACE status | jsonfilter -e '@.l3_device')
  if [ -n "$WAN_GW" ] && [ -n "$WAN_DEV" ]; then
    echo "$WAN_GW $WAN_DEV" > /tmp/wan-route-info
    echo "Stored: $WAN_GW $WAN_DEV" >> $LOG
    exit 0
  fi
  echo "Attempt $i: WAN_GW='$WAN_GW', WAN_DEV='$WAN_DEV'" >> $LOG
  sleep 1
done

echo "Failed to capture WAN route info after 10 tries." >> $LOG
exit 1
EOF
chmod +x /etc/hotplug.d/iface/10-store-wan-route



echo "Created hotplug to set up gateway for VPN server ip"

# HOTPLUG 2

cat << 'EOF' > /etc/hotplug.d/iface/99-vpn-route
#!/bin/sh

LOGFILE="/var/log/vpngw"
VPN_IP_FILE="/etc/vpn-server-ip"   # Use persistent storage if needed
ROUTE_INFO="/tmp/wan-route-info"

echo "==== $(date) Hotplug event: $INTERFACE $ACTION ====" >> "$LOGFILE"

# Only run on VPN interface up
[ "$ACTION" = "ifup" ] || exit 0
[ "$INTERFACE" = "oc0" ] || {
  echo "Ignoring non-VPN interface: $INTERFACE" >> "$LOGFILE"
  exit 0
}

# Wait for stored VPN IP
VPN_IP=$(cat "$VPN_IP_FILE" 2>/dev/null)
[ -z "$VPN_IP" ] && {
  echo "Missing VPN IP in $VPN_IP_FILE, aborting." >> "$LOGFILE"
  exit 1
}

# Wait for WAN route info file (should be prepopulated at boot or connection)
for i in $(seq 1 10); do
  [ -f "$ROUTE_INFO" ] && break
  echo "Waiting for $ROUTE_INFO ($i)" >> "$LOGFILE"
  sleep 1
done

[ ! -f "$ROUTE_INFO" ] && {
  echo "Missing $ROUTE_INFO, aborting." >> "$LOGFILE"
  exit 1
}

WAN_GW=$(cut -d' ' -f1 "$ROUTE_INFO")
WAN_DEV=$(cut -d' ' -f2 "$ROUTE_INFO")

if [ -n "$WAN_GW" ] && [ -n "$WAN_DEV" ]; then
  ip route add "${VPN_IP}/32" via "$WAN_GW" dev "$WAN_DEV" 2>>"$LOGFILE" && \
    echo "Added route: ${VPN_IP}/32 via $WAN_GW dev $WAN_DEV" >> "$LOGFILE" || \
    echo "Route already exists: ${VPN_IP}/32 via $WAN_GW dev $WAN_DEV" >> "$LOGFILE"
else
  echo "Invalid WAN route info" >> "$LOGFILE"
  exit 1
fi
EOF

chmod +x /etc/hotplug.d/iface/99-vpn-route

cat << 'EOF' > /etc/hotplug.d/iface/99-set-vpn-mtu
#!/bin/sh
[ "$ACTION" = "ifup" ] || exit 0
[ "$INTERFACE" = "oc0" ] || exit 0

ip link set dev vpn-oc0 mtu 1350
EOF

chmod +x /etc/hotplug.d/iface/99-set-vpn-mtu

echo "Created hotplug to set up routing"

# HOTPLUGS END

uci set network.oc0="interface"
uci set network.oc0.proto="openconnect"
uci set network.oc0.username="$VPN_USER"
uci set network.oc0.password="$VPN_PASS"
uci set network.oc0.server="$VPN_URL"
uci set network.oc0.vpn_protocol="anyconnect"
uci set network.oc0.defaultroute="1"
uci set network.oc0.mtu="1350"
uci commit network

echo "Created network interface"

ZONE_ID=$(uci add firewall zone)
uci set firewall.$ZONE_ID.name="vpn"
uci set firewall.$ZONE_ID.input="REJECT"
uci set firewall.$ZONE_ID.output="ACCEPT"
uci set firewall.$ZONE_ID.forward="REJECT"
uci set firewall.$ZONE_ID.masq="1"
uci set firewall.$ZONE_ID.mtu_fix="1"
uci add_list firewall.$ZONE_ID.network="oc0"
uci commit firewall

echo "Added firewall zone"

FORWARD_ID=$(uci add firewall forwarding)
uci set firewall.$FORWARD_ID.src="lan"
uci set firewall.$FORWARD_ID.dest="vpn"
uci commit firewall

uci delete firewall.@forwarding[0]
uci commit firewall

echo "Allowed forwarding LAN > VPN, removed LAN > WAN, killswitch in place"

RULE_ID=$(uci add firewall rule)
uci set firewall.$RULE_ID.name="Block WAN DNS"
uci set firewall.$RULE_ID.src="lan"
uci set firewall.$RULE_ID.dest="wan"
uci set firewall.$RULE_ID.dest_port="53"
uci set firewall.$RULE_ID.proto="tcp udp"
uci set firewall.$RULE_ID.target="REJECT"
uci commit firewall

echo "Added firewall rule to block DNS queries LAN > WAN"

REDIRECT_ID=$(uci add firewall redirect)
uci set firewall.$REDIRECT_ID.name="Force LAN DNS to VPN-safe DNS"
uci set firewall.$REDIRECT_ID.src="lan"
uci set firewall.$REDIRECT_ID.proto="tcp udp"
uci set firewall.$REDIRECT_ID.src_dport="53"
uci set firewall.$REDIRECT_ID.dest_ip="1.1.1.1"
uci set firewall.$REDIRECT_ID.dest_port="53"
uci set firewall.$REDIRECT_ID.target="DNAT"
uci commit firewall

echo "Added redirect for DNS queries LAN > VPN"

/etc/init.d/firewall restart
echo "Restarted firewall"

uci add_list dhcp.@dnsmasq[0].server="1.1.1.1"
uci add_list dhcp.@dnsmasq[0].server="9.9.9.9"
uci commit dhcp


echo "Configured dnsmasq to use cloudflare DNS"

echo "VPN setup complete. Reboot router to apply all changes."
