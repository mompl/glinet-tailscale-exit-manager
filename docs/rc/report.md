# Statistics and the weekly report (v1.2)

TSEM keeps a short history of state changes (a few lines a week, written only when something changes) in `/etc/tsem/history` and answers:
how long was the router in which mode, how often did a backup exit node take over, how often and how long was it BLOCKED, how often did
it restart.

```sh
tsem report                 # the last 7 days
tsem report --days 30       # 1 to 90 days
tsem report --json
tsem report --notify        # sends a one-line summary through the message settings
```

Example:

```
tsem report: the last 7 day(s), measured while the router was running (6d 21h 40m)
Germany            6d 18h 2m    97%
backup exit node   3h 10m       1%
BLOCKED            4m           0% (1 time(s), longest 4m)
DIRECT             1h 20m       0% (2 time(s))
router was off     8h 15m
failovers: 3   restarts: 2
```

**Router off is not a mode.** The controller notes once an hour that it is alive. After a restart the gap since that note is shown as
"router was off" and is not counted as time in a mode. A mobile router that is often switched off therefore reports honestly. Entries
from before the clock was set (the router has no clock battery) are ignored.

**The weekly message.** Add `report` to `NOTIFY_EVENTS` (`/etc/tsem/notify.conf`, or the message settings): the controller then sends
the one-line report about once a week, from the first tick after seven days. It is off by default and needs no cron job. Example:
`router: week report (7 d): Germany 97%, backup node 3h 10m, BLOCKED 4m (1 x), DIRECT 1h 20m (2 x), 3 failover(s), 2 restart(s)`.

The GL.iNet page has a **Statistics** card (last 7 days); the API method `report` (`{"days":7}`) returns the same numbers. The history
starts when this version is installed, so a new installation says "not enough data yet" for a while. It is not part of `tsem backup`.
