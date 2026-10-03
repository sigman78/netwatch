# Packaging — FreeBSD / OPNsense

A pkg(8) package for FreeBSD and OPNsense, which has no ports tree and no
compiler: `pkg add` the file and netwatch is installed, with an rc(8) script
for the fleet agent. Every release attaches one, built in the release
workflow's FreeBSD VM.

| File | Installed as |
|---|---|
| `MANIFEST.in` | the package manifest; `@VERSION@`, `@ABI@`, `@ARCH@` and `@SHLIBS@` are filled in at build time |
| `plist` | the file list, relative to `/usr/local` |
| `netwatch.rc` | `/usr/local/etc/rc.d/netwatch` |
| `agent.env.sample` | `/usr/local/etc/netwatch/agent.env.sample`, copied to `agent.env` on install |

The rest of the package is what the .deb and .rpm install: the binary,
shell completions, the man page, README, CHANGELOG and LICENSE.

## Building

```sh
scripts/freebsd-pkg.sh [path/to/netwatch]
# target/freebsd-pkg/netwatch-0.35.1.pkg
```

The binary defaults to `target/x86_64-unknown-freebsd/release/netwatch`, which
`scripts/freebsd-cross.sh` builds on Linux. The script stages the files,
strips the binary, and packs them one of two ways:

- **`pkg create`**, when pkg(8) is on `PATH` — FreeBSD, the CI VM, or an
  OPNsense box. This is what the release workflow uses.
- **`scripts/freebsd-pkg.py`** everywhere else. It needs `python3` and `zstd`
  and writes the same archive pkg would: two JSON manifests, then the files.

The version comes from `cargo metadata`. Where there is no cargo, such as a
FreeBSD host with only the binary, set it:

```sh
NETWATCH_VERSION=0.35.1 scripts/freebsd-pkg.sh ./netwatch
```

The package's ABI is `FreeBSD:<major>:amd64`, where the major is the running
FreeBSD's, or 15 on other hosts; `FREEBSD_MAJOR` overrides it. `PACKER=pkg`
or `PACKER=python` forces a route.

The manifest declares no dependencies: the binary links only against
libraries in FreeBSD base (libpcap, libc, libm, libthr, libgcc_s). On
FreeBSD the script checks that with ldd(1) and refuses a binary linked
against the libpcap *package* in `/usr/local/lib`, which pkg-config picks
whenever that package is installed. Build with `LIBPCAP_LIBDIR=/usr/lib` to
get base's.

## Installing on OPNsense

As root, from the console or an SSH shell:

```sh
fetch https://github.com/matthart1983/netwatch/releases/download/v0.35.1/netwatch-0.35.1.pkg
pkg add ./netwatch-0.35.1.pkg
netwatch
```

Run it as root: capture opens `/dev/bpf`. To run the fleet agent as a
service, set the URL and key in `/usr/local/etc/netwatch/agent.env`, then:

```sh
sysrc netwatch_enable=YES
service netwatch start
```

The agent's output goes to syslog under the tag `netwatch`, its own log to
`/var/cache/netwatch`, and its learned state to `/var/db/netwatch`.
`netwatch_flags` adds arguments to `netwatch daemon`, e.g.
`--insecure-remote`.

`agent.env` behaves like a ports `@sample` file: install creates it from the
sample if it does not exist, and removal deletes it only if it was never
edited.

Two things that do not happen on their own:

- **Updates.** A package added from a file belongs to no repository, so
  `pkg upgrade` and OPNsense's updater leave it alone. To update, `pkg add`
  the newer release's package over the installed one; an edited `agent.env`
  is kept. `pkg delete netwatch` removes it, and also keeps an edited
  `agent.env`.
- **A new FreeBSD major.** pkg refuses a package whose ABI is not the
  host's. When OPNsense moves to the next FreeBSD major, the package has to
  be rebuilt on that major (in CI: the release workflow's FreeBSD VM) and
  added again.
