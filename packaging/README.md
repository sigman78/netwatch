# Packaging — netwatch fleet agent

Service definitions for running `netwatch daemon` (the headless agent) as a
long-running service that streams to a netwatch cloud / NetWatch Core backend.

The daemon runs the same collectors as the TUI with no rendering, buffers
snapshots in a durable bounded queue, and flushes that queue on SIGTERM before
exiting.

## Configuration

The units pass the backend endpoint and API key via environment variables
(`NETWATCH_REMOTE_URL`, `NETWATCH_API_KEY`) rather than CLI flags, so the key
never appears in `ps`. The equivalent manual invocation is:

```sh
NETWATCH_API_KEY=<key> netwatch daemon --remote https://cloud.example.com
```

`--api-key <key>` still works, but it puts the key where any user on the host
can read it with `ps`.

The URL must be `https://`. netwatch refuses an `http://` URL, which would
send the API key in cleartext, unless `--insecure-remote` is also given; for
a unit, that means adding the flag to `ExecStart` or `ProgramArguments`.

## Linux (systemd)

```sh
sudo useradd --system --no-create-home --shell /usr/sbin/nologin netwatch
sudo install -m0755 target/release/netwatch /usr/bin/netwatch
sudo install -d -m0750 -o netwatch -g netwatch /etc/netwatch
printf 'NETWATCH_REMOTE_URL=%s\nNETWATCH_API_KEY=%s\n' \
  "https://cloud.example.com" "<key>" | sudo tee /etc/netwatch/agent.env >/dev/null
sudo chmod 0640 /etc/netwatch/agent.env && sudo chown root:netwatch /etc/netwatch/agent.env
sudo cp packaging/systemd/netwatch.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now netwatch
journalctl -u netwatch -f
```

The unit runs unprivileged with only `CAP_NET_RAW`, `CAP_BPF`, and
`CAP_PERFMON` (eBPF process attribution needs the latter two). netwatch applies
its own Landlock sandbox on top after startup.

## macOS (launchd)

```sh
sudo install -m0755 target/release/netwatch /usr/local/bin/netwatch
sudo cp packaging/launchd/com.netwatch.agent.plist /Library/LaunchDaemons/
# edit NETWATCH_REMOTE_URL / NETWATCH_API_KEY in the plist, then:
sudo launchctl bootstrap system /Library/LaunchDaemons/com.netwatch.agent.plist
```

Full eBPF/PKTAP attribution on macOS requires root; without it the daemon falls
back to lsof/ss-based attribution.

## FreeBSD / OPNsense (rc.d)

```sh
pkg add ./netwatch-<version>.pkg      # the release asset; see packaging/freebsd/
# set NETWATCH_REMOTE_URL / NETWATCH_API_KEY in /usr/local/etc/netwatch/agent.env, then:
sysrc netwatch_enable=YES
service netwatch start
```

The package installs `packaging/freebsd/netwatch.rc` as
`/usr/local/etc/rc.d/netwatch` and creates `agent.env` (root:wheel, 0640) from
its sample. The rc script reads the file and runs `netwatch daemon` under
daemon(8), which restarts it if it exits and sends its output to syslog. It
runs as root: capture on FreeBSD needs `/dev/bpf`, which has no capability to
grant in its place. `packaging/freebsd/README.md` covers building the package.
