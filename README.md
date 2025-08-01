# openwrt-openconnect-routing

To configure a freshly-reset openwrt 23+ router
```
sh -c "$(wget -qO- https://raw.githubusercontent.com/cyb3rm4gus/openwrt-openconnect-routing/refs/heads/main/configure.sh)"
```

To reconfigure a router that was configured using script above (change VPN server URL, login & password)
```
sh -c "$(wget -qO- https://raw.githubusercontent.com/cyb3rm4gus/openwrt-openconnect-routing/refs/heads/main/reconfigure.sh)"
```
