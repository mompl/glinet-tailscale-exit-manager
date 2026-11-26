# Notifications without Home Assistant (v1.1)

`tsem-notify` sends a short message when tsem changes state: a backup exit node took over, the router is BLOCKED, or it is back on the
primary. It uses [ntfy](https://ntfy.sh) (push to the ntfy phone app) or a generic webhook. It is off until you create the config file.

## Set up (ntfy)

```sh
cp /etc/tsem/notify.conf.example /etc/tsem/notify.conf
chmod 600 /etc/tsem/notify.conf
vi /etc/tsem/notify.conf        # NOTIFY_URL=https://ntfy.sh/<a long random topic>, NOTIFY_NAME=<router name>
tsem-notify test                # sends a test message
```

Install the ntfy app on the phone and subscribe to the same topic. Anyone who knows the topic name can read the messages, so use a long
random one (or your own ntfy server with a token: `NOTIFY_TOKEN_FILE`).

## What is sent

| Event | When | Default |
|---|---|---|
| `failover` | the secondary exit node took over | yes |
| `blocked` | no usable exit node, the router is BLOCKED | yes |
| `recovered` | back on the primary after a failover or BLOCKED | yes |
| `exit` | the exit-node mode became active | no |
| `error` | the controller reports an error | no |

Choose with `NOTIFY_EVENTS="failover blocked recovered"`. Changes you make yourself (`tsem set direct` / `blocked`, the GUI, the
switch) are not reported: you know about them.

## BLOCKED and the kill switch: the message may be late

While the router is BLOCKED the kill switch closes the router's own Internet access, so a message to ntfy.sh **cannot leave**. It waits
in a queue (`tsem-notify queue`, in RAM, at most 20 entries) and is sent, with its original time, as soon as the router can reach the
server again (after recovery, or when you switch to DIRECT). If you want the message **during** BLOCKED, run the notification server on
your tailnet (for example ntfy in a container on a machine in the tailnet) and use its `http://100.x.y.z:port/topic` address: traffic
through `tailscale0` stays open in BLOCKED.

## Safety

- It only talks to `NOTIFY_URL`. It never changes firewall rules, routes or Tailscale, and the controller starts it detached and never
  waits for it (a slow server cannot delay a failover).
- The URL and name are validated; unsafe values are ignored. The token is read from a file and passed to `curl` through a temporary
  config file, not on the command line.
- It needs `curl` on the router.

## Your own ntfy server (recommended): public address for phones, tailnet address as the fallback for routers

A phone needs a public HTTPS address to get the full text anywhere (iOS fetches the message from your server after the push
wake-up that is relayed by ntfy.sh; only a message ID goes through ntfy.sh). A router in BLOCKED has no Internet, so it needs a second
address that stays reachable: a server on your tailnet or LAN behind a subnet route. One server, two addresses, one topic:

```
NOTIFY_URL=https://ntfy.example.com/<long random topic>          # main address: public, works from everywhere
NOTIFY_URL_FALLBACK=http://192.0.2.10:8098/<same topic>          # tried when the main one does not work (BLOCKED, Internet down)
NOTIFY_TOKEN_FILE=/etc/tsem/notify.token                          # token of a user that may publish to the topic (mode 600)
```

### Server on Unraid (Docker, managed in the Unraid GUI)

1. Template `my-ntfy.xml` in `/boot/config/plugins/dockerMan/templates-user/`, image `binwiederhier/ntfy:latest`, command `serve`,
   port `8098:80`, paths `/mnt/user/appdata/ntfy/etc` (server.yml) and `/mnt/user/appdata/ntfy/cache`. Check that the host port is free first
   (`ss -ltn | grep :8098`, `docker ps`).
2. `server.yml`: `base-url`, `cache-file`, `upstream-base-url: "https://ntfy.sh"` (iOS instant delivery), and for a public server
   `auth-file`, `auth-default-access: deny-all`. Create one user per purpose (routers publish, phones subscribe) and give each its own token.
3. Public address: a Cloudflare Tunnel (for example an existing `cloudflared` container) with a subdomain that points to `http://<unraid>:8098`.
   Never expose the server without authentication.
4. Phones: install the ntfy app, add the server, subscribe to the topic with the phone's token. Routers: `NOTIFY_URL`, `NOTIFY_URL_FALLBACK`, token file as above.

What a message says: `EXIT is active via <exit node name>`, `BLOCKED`, `DIRECT`, backup took over, back on the primary. A manual `tsem set direct`
or `blocked` sends a message too; `tsem set exit` sends it when the exit node is really active (not a transitional BLOCKED).
Found on real hardware (GL-MG1300 with ntfy on Unraid): the message is sent after the change is applied, so it names the exit node.
