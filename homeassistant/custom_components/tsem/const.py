"""Constants for the TSEM integration."""

DOMAIN = "tsem"
CONF_SSL = "ssl"
CONF_SCAN_INTERVAL = "scan_interval"
# the LuCI web server (uhttpd) of a GL.iNet router answers the ubus API on 8080 (http) and 8443 (https, self-signed)
DEFAULT_PORT = 8443
DEFAULT_SSL = True
DEFAULT_SCAN_INTERVAL = 15
MIN_SCAN_INTERVAL = 5
PLATFORMS = ["switch", "sensor", "binary_sensor", "button"]
TO_REDACT = {"password", "username", "host", "token", "ubus_rpc_session"}
