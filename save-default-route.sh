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
