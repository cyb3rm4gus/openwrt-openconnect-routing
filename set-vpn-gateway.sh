#!/bin/sh

LOGFILE="/var/log/vpngw"

[ -z "$1" ] && {
  echo "$(date) ERROR: VPN IP not provided" >> "$LOGFILE"
  exit 1
}

VPN_IP="$1"

echo "==== $(date) VPN route hook for $VPN_IP ====" >> "$LOGFILE"

# Wait for route info file (max 10 seconds)
for i in $(seq 1 10); do
  [ -f /tmp/wan-route-info ] && break
  echo "Waiting for /tmp/wan-route-info ($i)" >> "$LOGFILE"
  sleep 1
done

[ ! -f /tmp/wan-route-info ] && {
  echo "No WAN route info, exiting." >> "$LOGFILE"
  exit 1
}

WAN_GW=$(cut -d' ' -f1 /tmp/wan-route-info)
WAN_DEV=$(cut -d' ' -f2 /tmp/wan-route-info)

if [ -n "$WAN_GW" ] && [ -n "$WAN_DEV" ]; then
  ip route replace ${VPN_IP}/32 via $WAN_GW dev $WAN_DEV
  echo "Route set: ${VPN_IP}/32 via $WAN_GW dev $WAN_DEV" >> "$LOGFILE"
else
  echo "Incomplete WAN route info." >> "$LOGFILE"
  exit 1
fi