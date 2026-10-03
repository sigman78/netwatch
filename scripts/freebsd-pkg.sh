#!/bin/sh
# Build the FreeBSD/OPNsense package from an already-built binary.
#
#   scripts/freebsd-pkg.sh [path/to/netwatch]
#
# The binary defaults to target/x86_64-unknown-freebsd/release/netwatch, the
# cross build; the release workflow passes target/release/netwatch from its
# FreeBSD VM. Run from the repository root. Prints the path of the package,
# target/freebsd-pkg/netwatch-<version>.pkg.
#
# Stages the same files as the .deb and .rpm (binary, completions, man page,
# README, CHANGELOG, LICENSE) plus the rc(8) script and agent.env.sample from
# packaging/freebsd/, then packs them one of two ways:
#
#   - `pkg create`, when a working pkg(8) is on PATH: FreeBSD, the CI VM, or
#     OPNsense itself;
#   - scripts/freebsd-pkg.py otherwise, which needs python3 and zstd and
#     writes a package pkg installs the same way.
#
# Plain sh, not bash: a stock FreeBSD VM has no bash.
#
# Environment:
#   NETWATCH_VERSION  package version; default is Cargo.toml's, read with
#                     `cargo metadata`. Set it where there is no cargo.
#   FREEBSD_MAJOR     FreeBSD major the binary was built for; default is the
#                     running FreeBSD's, or 15 (OPNsense 26.7) elsewhere. pkg
#                     refuses a package whose ABI is not the host's.
#   FREEBSD_ARCH      amd64 (default) or aarch64.
#   OUT_DIR           where the package goes; default target/freebsd-pkg.
#   PACKER            `pkg` or `python` to force a route.
#   NO_STRIP          set to install the binary unstripped.
set -eu

BIN="${1:-target/x86_64-unknown-freebsd/release/netwatch}"
OUT="${OUT_DIR:-target/freebsd-pkg}"
SRC="packaging/freebsd"

die() { echo "freebsd-pkg.sh: $*" >&2; exit 1; }

{ [ -f Cargo.toml ] && [ -d "${SRC}" ]; } || die "run from the repository root"
[ -f "${BIN}" ] || die "${BIN} not found: build it first, or pass its path"

# `cargo metadata --no-deps` puts the crate first, and its "version" key is
# the first one in the output.
version="${NETWATCH_VERSION:-}"
if [ -z "${version}" ] && command -v cargo >/dev/null 2>&1; then
    version=$(cargo metadata --no-deps --format-version 1 | tr ',' '\n' |
        sed -n 's/^"version":"\([^"]*\)"$/\1/p' | head -n 1)
fi
[ -n "${version}" ] || die "no cargo to read the version from: set NETWATCH_VERSION"

if [ "$(uname -s)" = FreeBSD ]; then
    host_major=$(uname -r | cut -d. -f1)
else
    host_major=15
fi
major="${FREEBSD_MAJOR:-${host_major}}"
case "${FREEBSD_ARCH:-amd64}" in
    amd64)   abi="FreeBSD:${major}:amd64";   arch="freebsd:${major}:x86:64" ;;
    aarch64) abi="FreeBSD:${major}:aarch64"; arch="freebsd:${major}:aarch64:64" ;;
    *) die "FREEBSD_ARCH must be amd64 or aarch64, not ${FREEBSD_ARCH}" ;;
esac

if [ -n "${PACKER:-}" ]; then
    packer="${PACKER}"
elif command -v pkg >/dev/null 2>&1 && pkg -N >/dev/null 2>&1; then
    # `pkg -N` fails on base's bootstrap stub, which would otherwise try to
    # fetch pkg from the network.
    packer=pkg
else
    packer=python
fi

stage="${OUT}/stage"
rm -rf "${stage}" "${OUT}/netwatch-${version}.pkg"
mkdir -p "${OUT}"
p="${stage}/usr/local"
install -d "${p}/bin" "${p}/etc/rc.d" "${p}/etc/netwatch" "${p}/share/man/man1" \
    "${p}/share/bash-completion/completions" "${p}/share/zsh/site-functions" \
    "${p}/share/fish/vendor_completions.d" "${p}/share/doc/netwatch" \
    "${p}/share/licenses/netwatch"

install -m 0755 "${BIN}" "${p}/bin/netwatch"
if [ -z "${NO_STRIP:-}" ]; then
    # A strip that does not know the binary's architecture fails rather than
    # rewriting it, so a failure only costs the size.
    stripped=""
    for s in llvm-strip strip; do
        if command -v "${s}" >/dev/null 2>&1 && "${s}" "${p}/bin/netwatch" 2>/dev/null; then
            stripped="${s}"
            break
        fi
    done
    [ -n "${stripped}" ] || echo "freebsd-pkg.sh: could not strip ${BIN}; packaging it as is" >&2
fi
install -m 0755 "${SRC}/netwatch.rc" "${p}/etc/rc.d/netwatch"
install -m 0640 "${SRC}/agent.env.sample" "${p}/etc/netwatch/agent.env.sample"
gzip -9 -n -c docs/netwatch.1 > "${p}/share/man/man1/netwatch.1.gz"
chmod 0644 "${p}/share/man/man1/netwatch.1.gz"
install -m 0644 completions/netwatch.bash "${p}/share/bash-completion/completions/netwatch"
install -m 0644 completions/_netwatch "${p}/share/zsh/site-functions/_netwatch"
install -m 0644 completions/netwatch.fish "${p}/share/fish/vendor_completions.d/netwatch.fish"
install -m 0644 README.md CHANGELOG.md "${p}/share/doc/netwatch/"
install -m 0644 LICENSE "${p}/share/licenses/netwatch/LICENSE"

# The base libraries the binary links against, for shlibs_required. GNU and
# FreeBSD readelf both print "Shared library: [libfoo.so.N]".
shlibs=""
if command -v readelf >/dev/null 2>&1; then
    shlibs=$(readelf -d "${p}/bin/netwatch" |
        sed -n 's/.*Shared library: \[\(.*\)\].*/"\1"/p' | sort | paste -s -d, -)
else
    echo "freebsd-pkg.sh: no readelf; shlibs_required left empty" >&2
fi
# The manifest has no deps, so everything the binary links has to come from
# base. One linked against the libpcap package (/usr/local/lib/libpcap.so.1,
# what pkg-config finds once that package is installed) would install
# cleanly and then fail to start on a firewall without it. Only FreeBSD can
# resolve the libraries; elsewhere the shlibs list above is all there is.
if [ "$(uname -s)" = FreeBSD ]; then
    if ldd "${p}/bin/netwatch" | grep -E '=> (/usr/local/|not found)' >&2; then
        die "${BIN} needs libraries outside FreeBSD base; build it against base's libpcap (LIBPCAP_LIBDIR=/usr/lib)"
    fi
fi

manifest="${OUT}/MANIFEST.json"
plist="${OUT}/plist"
sed -e '/^#/d' -e "s|@VERSION@|${version}|g" -e "s|@ABI@|${abi}|g" \
    -e "s|@ARCH@|${arch}|g" -e "s|@SHLIBS@|${shlibs}|g" \
    "${SRC}/MANIFEST.in" > "${manifest}"
cp "${SRC}/plist" "${plist}"

case "${packer}" in
    pkg)
        pkg create -M "${manifest}" -p "${plist}" -r "${stage}" -o "${OUT}" >&2
        ;;
    python)
        python3 scripts/freebsd-pkg.py "${stage}" "${plist}" "${manifest}" "${OUT}" >/dev/null
        ;;
    *) die "PACKER must be pkg or python, not ${packer}" ;;
esac

out="${OUT}/netwatch-${version}.pkg"
[ -f "${out}" ] || die "${packer} did not write ${out}"
echo "${out}"
