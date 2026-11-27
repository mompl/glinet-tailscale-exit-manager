# Notifications without Home Assistant (v1.1, servers and tokens v1.2)

`tsem-notify` sends a short message when tsem changes state: a backup exit node took over, the router is BLOCKED, it is back on the
primary, or you switched to DIRECT. It uses [ntfy](https://ntfy.sh) (push to the ntfy phone app) or a generic webhook. It is off until you
configure it.

## Which server? You choose

| | **Your own ntfy server** (recommended) | **The public server ntfy.sh** |
|---|---|---|
| Who sees the messages | only you | the server operator; anyone who knows the topic |
| Protection | login with an access token | none: a long random topic acts like a password |
| Reachable | LAN, tailnet and, if you publish it, the Internet | from everywhere |
| Setup | run ntfy yourself (Docker image `binwiederhier/ntfy`) | nothing to run |

TSEM does not ship an address of anyone. You give your own server, or choose the public one on purpose.

## Set up

### In the GL.iNet web page

APPLICATIONS > Tailscale Exit Manager > **Messages (ntfy)**: choose *My own server* or *Public server ntfy.sh*, fill in the address,
the topic and, if your server needs it, an access token. An optional **backup server** is tried when the first one cannot be reached
(for example your server in the LAN while the Internet is cut). Empty fields keep their current value; a token is stored on the router
only and never shown again. **Send test message** tries it at once.

### With `setup.sh` (new installation or update)

```sh
# your own server, with a backup address in the LAN
sh setup.sh --yes --primary NODE --notify-server https://ntfy.example.com --notify-topic <long random topic> \
   --notify-token-file /etc/tsem/notify.token --notify-fallback-server http://192.0.2.10:8098

# the public server (a random topic is created and printed once)
sh setup.sh --yes --primary NODE --notify-public
```

Store the token first, so it never appears in a command line or the shell history:

```sh
printf '%s\n' 'tk_...' | tsem-notify token /etc/tsem/notify.token        # mode 600
```

### With `tsem-notify`

```sh
tsem-notify setup --server https://ntfy.example.com --topic <topic> --token-file /etc/tsem/notify.token \
                  --fallback-server http://192.0.2.10:8098 --fallback-token-file /etc/tsem/notify.token2 \
                  --name my-router --events "failover blocked recovered exit direct error"
tsem-notify setup --public --name my-router      # ntfy.sh, random topic, prints a warning
tsem-notify show                                  # what is set: server names only, never the topic or a token
tsem-notify test                                  # sends a test message
```

`setup` checks every value and replaces `/etc/tsem/notify.conf` (mode 600) in one step; a refused value leaves the old file untouched.
Install the ntfy app on the phone and subscribe to the same topic on the same server. The file can also be written by hand, see
`/etc/tsem/notify.conf.example`: `NOTIFY_URL`, `NOTIFY_URL_FALLBACK`, `NOTIFY_TOKEN_FILE`, `NOTIFY_TOKEN_FILE_FALLBACK`, `NOTIFY_NAME`,
`NOTIFY_EVENTS`, `NOTIFY_TYPE` (`ntfy` or `webhook`).

**Tokens:** every address can have its own token (`NOTIFY_TOKEN_FILE` for the main one, `NOTIFY_TOKEN_FILE_FALLBACK` for the backup). Without
a token of its own the backup uses the main one. A token is sent only to the address it belongs to. In the web page you can only set one
or replace it, never read it.

## What is sent

| Event | When | Default |
|---|---|---|
| `failover` | the secondary exit node took over | yes |
| `blocked` | no usable exit node, the router is BLOCKED | yes |
| `recovered` | back on the primary after a failover or BLOCKED | yes |
| `exit` | the exit-node mode became active | no |
| `direct` | DIRECT: the kill switch is off | no |
| `error` | the controller reports an error | no |
| `report` | once a week, a one-line summary (see `docs/rc/report.md`) | no |

Choose with `NOTIFY_EVENTS`. Changing the mode by hand also sends a message: `tsem set direct` and `tsem set blocked` do; `tsem set exit`
does when the exit node is really active (not during a transitional BLOCKED). The message is sent after the change is applied, so it
names the exit node.

## Without Internet, and BLOCKED: the message may be late

While the router is BLOCKED the kill switch closes the router's own Internet access, so a message to a public server **cannot leave**.
It waits in a queue (`tsem-notify queue`, in RAM, at most 20 entries) and is sent, with its original time, as soon as a server is
reachable again. A **backup server** that stays reachable in BLOCKED (a server on your tailnet, traffic through `tailscale0` stays open;
or in a LAN that is allowed) delivers the message during BLOCKED.

For the phone: if the Internet is down but the phone is in your Wi-Fi (or on the tailnet), add your server **a second time** in the ntfy
app with its LAN address (for example `http://192.0.2.10:8098`) and subscribe to the same topic. The app then fetches messages from the
server directly. Not verified on iOS: instant push goes through Apple and `ntfy.sh` and needs the Internet; without it the app can only
fetch messages when it is open.

## Safety

- It only talks to the configured addresses. It never changes firewall rules, routes or Tailscale, and the controller starts it detached
  and never waits for it (a slow server cannot delay a failover).
- Addresses, topics, names and file names are validated; unsafe values are refused or ignored. Tokens are read from a file and passed to
  `curl` through a temporary config file, not on the command line. `show`, `test`, the web page and the API never print a topic or a token.
- On a public server the topic is the only secret. Use a long random one.
- It needs `curl` on the router.

## Your own ntfy server: an example with a public address and a LAN address

A phone needs a public HTTPS address to get messages anywhere (iOS fetches the text from your server after the push wake-up that is
relayed by ntfy.sh; only a message ID goes through ntfy.sh, if you set `upstream-base-url`). A router in BLOCKED has no Internet, so it needs
a second address that stays reachable. One server, two addresses, one topic:

```
NOTIFY_URL=https://ntfy.example.com/<long random topic>          # main address: public, works from everywhere
NOTIFY_URL_FALLBACK=http://192.0.2.10:8098/<same topic>          # tried when the main one does not work (BLOCKED, Internet down)
NOTIFY_TOKEN_FILE=/etc/tsem/notify.token                          # token of a user that may publish to the topic (mode 600)
```

Server example (Docker, for instance managed in the Unraid GUI):

1. Image `binwiederhier/ntfy:latest`, command `serve`, a free host port (check first: `ss -ltn | grep :8098`, `docker ps`), a path for
   `server.yml` and one for the cache.
2. `server.yml`: `base-url`, `cache-file`, `behind-proxy: true` when a proxy or tunnel is in front, `upstream-base-url: "https://ntfy.sh"`
   (iOS instant delivery), and for any server that is reachable from the Internet `auth-file`, `auth-default-access: deny-all`,
   `enable-login: true`, `enable-signup: false`. Create one user for the routers with write-only access to the topic (`ntfy access <user> 'tsem-*' wo`)
   and one for the phones; create a token for the routers (`ntfy token add <user>`).
3. Public address: a reverse proxy or a Cloudflare Tunnel with a name that points to the server. Never expose the server without
   authentication.
4. Phones: install the ntfy app, add the server, log in, subscribe to the topic. Routers: the settings above.
