# Home Assistant

Lean MQTT bridge `tsem-mqtt` (needs `mosquitto-client`). HA never touches firewall or Tailscale; it only publishes commands that run `tsem set|failover --source ha`.

1. `cp /etc/tsem/mqtt.conf.example /etc/tsem/mqtt.conf`, fill broker/user. Put the password alone in the file named by `MQTT_PASSFILE` (`/etc/tsem/mqtt.pass`, mode 600); it is never put on a command line.
2. The init script starts `tsem-mqtt` automatically when `/etc/tsem/mqtt.conf` exists (restart the service after creating it).
3. MQTT discovery creates: switches *German internet*, *Auto failover*; button *Failover now*; sensors state, active exit, last error, DNS, last check; binary sensors kill switch, leak risk, primary ok, secondary ok, error.
Commands are never retained; state topics expire (`expire_after`) so a dead bridge shows as unavailable.
