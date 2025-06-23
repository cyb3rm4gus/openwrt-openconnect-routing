#!/bin/sh
set -e

read -p "Enter VPN username: " VPN_USER
read -s -p "Enter VPN password: " VPN_PASS
echo
read -p "Enter VPN server URL (e.g. vpn.example.com/?secret): " VPN_URL

VPN_DOMAIN=$(echo "$VPN_URL" | cut -d/ -f1)
VPN_IP=$(nslookup "$VPN_DOMAIN" | awk '/^Address: / { print $2 }' | tail -n1)
[ -z "$VPN_IP" ] && echo "Failed to resolve VPN IP" && exit 1

opkg update && opkg install openconnect luci-proto-openconnect

uci set network.oc0="interface"
uci set network.oc0.proto="openconnect"
uci set network.oc0.username="$VPN_USER"
uci set network.oc0.password="$VPN_PASS"
uci set network.oc0.server="$VPN_URL"
uci set network.oc0.defaultroute="1"
uci set network.oc0.auto="1"
uci commit network

uci add firewall zone
uci set firewall.@zone[-1].name="vpn"
uci set firewall.@zone[-1].input="REJECT"
uci set firewall.@zone[-1].output="ACCEPT"
uci set firewall.@zone[-1].forward="REJECT"
uci add_list firewall.@zone[-1].network="oc0"

uci set firewall.@defaults[0].forward="REJECT"
uci add firewall forwarding
uci set firewall.@forwarding[-1].src="lan"
uci set firewall.@forwarding[-1].dest="vpn"

uci add firewall rule
uci set firewall.@rule[-1].name="Block WAN DNS"
uci set firewall.@rule[-1].src="lan"
uci set firewall.@rule[-1].dest="wan"
uci set firewall.@rule[-1].dest_port="53"
uci set firewall.@rule[-1].proto="tcp udp"
uci set firewall.@rule[-1].target="REJECT"

uci add firewall redirect
uci set firewall.@redirect[-1].name="Force LAN DNS to VPN-safe DNS"
uci set firewall.@redirect[-1].src="lan"
uci set firewall.@redirect[-1].proto="tcp udp"
uci set firewall.@redirect[-1].src_dport="53"
uci set firewall.@redirect[-1].dest_ip="1.1.1.1"
uci set firewall.@redirect[-1].dest_port="53"
uci set firewall.@redirect[-1].target="DNAT"

uci set dhcp.@dnsmasq[0].noresolv="1"
uci del dhcp.@dnsmasq[0].server
uci add_list dhcp.@dnsmasq[0].server="1.1.1.1"
uci add_list dhcp.@dnsmasq[0].server="9.9.9.9"
uci commit firewall
uci commit dhcp
/etc/init.d/firewall restart
/etc/init.d/dnsmasq restart

cat << 'EOF' > /etc/hotplug.d/iface/10-store-wan-route
#!/bin/sh
[ "$ACTION" = "ifup" ] || exit 0
case "$INTERFACE" in
  wan|wwan) ;;
  *) exit 0 ;;
esac
GW=$(ubus call network.interface.$INTERFACE status | jsonfilter -e '@.gateway')
DEV=$(ubus call network.interface.$INTERFACE status | jsonfilter -e '@.l3_device')
[ -n "$GW" ] && [ -n "$DEV" ] && echo "$GW $DEV" > /tmp/wan-route-info
EOF
chmod +x /etc/hotplug.d/iface/10-store-wan-route

cat << EOF > /etc/hotplug.d/iface/99-vpn-route
#!/bin/sh
LOGFILE="/tmp/hp.txt"
VPN_IP="$VPN_IP"

echo "=== \$(date) Hotplug: \$INTERFACE \$ACTION ===" >> \$LOGFILE
[ "\$ACTION" = "ifup" ] || exit 0
case "\$INTERFACE" in wan|wwan) ;; *) exit 0 ;; esac

for i in \$(seq 1 10); do
  [ -f /tmp/wan-route-info ] && break
  echo "Waiting for /tmp/wan-route-info (\$i)" >> \$LOGFILE
  sleep 1
done

[ ! -f /tmp/wan-route-info ] && {
  echo "No WAN info, exit" >> \$LOGFILE
  exit 1
}

GW=\$(cut -d' ' -f1 /tmp/wan-route-info)
DEV=\$(cut -d' ' -f2 /tmp/wan-route-info)

[ -n "\$GW" ] && [ -n "\$DEV" ] && ip route replace \$VPN_IP/32 via \$GW dev \$DEV
echo "Set route to \$VPN_IP via \$GW dev \$DEV" >> \$LOGFILE
EOF
chmod +x /etc/hotplug.d/iface/99-vpn-route

echo "✅ Setup complete. Reboot the router to activate VPN tunnel with DNS and route protection."
