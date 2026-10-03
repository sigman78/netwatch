#!/usr/bin/env bash
# Cross-build netwatch for FreeBSD from a Linux host, with no FreeBSD machine.
#
#   scripts/freebsd-cross.sh [--freebsd 15.1] [--arch amd64] [build|check] [cargo args...]
#
# `build` (the default) runs `cargo build --release --target <triple>` and
# prints the binary's path and the shared libraries it needs; `check` runs
# `cargo check --target <triple>` instead, which is what CI uses. Anything
# after the mode goes to cargo as is, e.g. `build --locked`. The release and
# arch can also come from FREEBSD_RELEASE and FREEBSD_ARCH.
#
# The sysroot is FreeBSD's own base.txz for that release: libc, libthr,
# libpcap and their headers, exactly what the binary will link against on the
# target. It is downloaded once, checked against the sha256 in the release's
# MANIFEST, unpacked into
# ${NETWATCH_FREEBSD_CACHE:-${XDG_CACHE_HOME:-~/.cache}/netwatch/freebsd-sysroot}/<release>-<arch>
# and reused from then on; delete that directory to fetch it again. The
# tarball itself is removed once unpacked, so the directory is what to cache.
# Only lib, usr/lib, usr/include and usr/libdata are unpacked, minus base's
# libprivate* libraries, which nothing outside base may link and which are a
# third of the size.
#
# Compiling and linking is done by the host's clang and lld, pointed at the
# sysroot through two small wrapper scripts generated next to it. cc-rs needs
# them too: ring and mimalloc compile C in their build scripts, so CC, AR and
# CFLAGS are set for the target as well as the linker. The libpcap version is
# read out of the sysroot's libpcap, because the pcap crate's build script
# otherwise loads the host's libpcap to ask it, and would get the wrong answer.
#
# Needs clang, ld.lld, llvm-ar, curl, tar, xz, sha256sum (or shasum), and the
# rust target (`rustup target add x86_64-unknown-freebsd`). On Debian or
# Ubuntu: `sudo apt-get install clang lld llvm curl xz-utils`. CLANG, CLANGXX
# and LLVM_AR override the tool names, e.g. for a versioned clang-18.
#
# amd64 (x86_64-unknown-freebsd) is the tested arch: its binary runs on
# FreeBSD 15.1 and OPNsense 26.7 and passes the unit tests there. aarch64
# (aarch64-unknown-freebsd, FreeBSD's arm64) is wired up but has never been
# built or run: it is a tier 3 rust target, so rustup has no standard library
# for it, and it needs a nightly toolchain and `-Zbuild-std` passed through,
# or a toolchain that ships one.
set -euo pipefail

usage="usage: freebsd-cross.sh [--freebsd RELEASE] [--arch amd64|aarch64] [build|check] [cargo args...]"

die() { echo "freebsd-cross.sh: $*" >&2; exit 1; }

RELEASE="${FREEBSD_RELEASE:-15.1}"
ARCH="${FREEBSD_ARCH:-amd64}"
MODE=build

while [ $# -gt 0 ]; do
    case "$1" in
        --freebsd) RELEASE="${2:?${usage}}"; shift 2 ;;
        --freebsd=*) RELEASE="${1#*=}"; shift ;;
        --arch) ARCH="${2:?${usage}}"; shift 2 ;;
        --arch=*) ARCH="${1#*=}"; shift ;;
        -h | --help) echo "${usage}"; exit 0 ;;
        build | check) MODE="$1"; shift; break ;;
        --) shift; break ;;
        *) break ;;
    esac
done
# What is left in "$@" goes to cargo.

[[ "${RELEASE}" =~ ^[0-9]+\.[0-9]+$ ]] || die "${RELEASE} is not a FreeBSD release like 15.1"

# The download path's arch is FreeBSD's MACHINE/MACHINE_ARCH pair.
case "${ARCH}" in
    amd64 | x86_64)
        ARCH=amd64
        TRIPLE=x86_64-unknown-freebsd
        DIST_ARCH=amd64
        ;;
    aarch64 | arm64)
        # Untested: nothing has been built or run for this arch yet. Tier 3,
        # so there is no `rustup target add` for it; see the top.
        ARCH=aarch64
        TRIPLE=aarch64-unknown-freebsd
        DIST_ARCH=arm64/aarch64
        echo "freebsd-cross.sh: warning: ${TRIPLE} has never been tested" >&2
        ;;
    *) die "unknown arch ${ARCH}; amd64 or aarch64" ;;
esac

CLANG="${CLANG:-clang}"
CLANGXX="${CLANGXX:-clang++}"
LLVM_AR="${LLVM_AR:-llvm-ar}"

# Every missing tool at once, rather than one per run.
missing=()
for tool in "${CLANG}" ld.lld "${LLVM_AR}" curl tar xz cargo rustc; do
    command -v "${tool}" > /dev/null || missing+=("${tool}")
done
if command -v sha256sum > /dev/null; then
    sha256() { sha256sum "$1" | awk '{ print $1 }'; }
elif command -v shasum > /dev/null; then
    sha256() { shasum -a 256 "$1" | awk '{ print $1 }'; }
else
    missing+=(sha256sum)
fi
[ ${#missing[@]} -eq 0 ] ||
    die "missing ${missing[*]}; on Debian or Ubuntu: sudo apt-get install clang lld llvm curl xz-utils"

# Not `rustup target list`: this works for a toolchain rustup does not manage.
# A -Zbuild-std build has no prebuilt standard library to find.
if [[ " $* " != *" -Zbuild-std"* ]] && [ ! -d "$(rustc --print sysroot)/lib/rustlib/${TRIPLE}" ]; then
    if [ "${ARCH}" = amd64 ]; then
        die "the rust standard library for ${TRIPLE} is not installed; run: rustup target add ${TRIPLE}"
    fi
    die "${TRIPLE} is a tier 3 rust target with no prebuilt standard library; use a nightly toolchain and pass -Zbuild-std through to cargo"
fi

root=$(cd "$(dirname "$0")/.." && pwd)
cd "${root}"

cache="${NETWATCH_FREEBSD_CACHE:-${XDG_CACHE_HOME:-${HOME}/.cache}/netwatch/freebsd-sysroot}/${RELEASE}-${ARCH}"
SYSROOT="${cache}/sysroot"
url="https://download.freebsd.org/ftp/releases/${DIST_ARCH}/${RELEASE}-RELEASE"
mkdir -p "${cache}"

# The marker is written last, after the sysroot is renamed into place, so an
# interrupted download or unpack is redone instead of half-used.
if [ -f "${SYSROOT}/.netwatch-sysroot" ]; then
    echo "Using the FreeBSD ${RELEASE} ${ARCH} sysroot at ${SYSROOT}"
else
    echo "Fetching FreeBSD ${RELEASE} ${ARCH} base.txz from ${url}"
    # MANIFEST comes over the same HTTPS as base.txz; it is what pins the
    # tarball, so a truncated or swapped download is refused.
    curl -fsSL --retry 3 -o "${cache}/MANIFEST" "${url}/MANIFEST"
    want=$(awk -F '\t' '$1 == "base.txz" { print $2 }' "${cache}/MANIFEST")
    [[ "${want}" =~ ^[0-9a-f]{64}$ ]] || die "no sha256 for base.txz in ${url}/MANIFEST"

    if [ ! -f "${cache}/base.txz" ] || [ "$(sha256 "${cache}/base.txz")" != "${want}" ]; then
        curl -fsSL --retry 3 -o "${cache}/base.txz.part" "${url}/base.txz"
        mv "${cache}/base.txz.part" "${cache}/base.txz"
    fi
    got=$(sha256 "${cache}/base.txz")
    if [ "${got}" != "${want}" ]; then
        rm -f "${cache}/base.txz"
        die "base.txz sha256 is ${got}, MANIFEST says ${want}; deleted it, run again to re-download"
    fi
    echo "base.txz sha256 ${got} matches MANIFEST"

    rm -rf "${SYSROOT}" "${SYSROOT}.part"
    mkdir -p "${SYSROOT}.part"
    # FreeBSD's tar writes file flags as SCHILY.fflags headers, which GNU
    # tar does not know and warns about once per file. They are only flags.
    quiet=()
    if tar --version 2> /dev/null | grep -q 'GNU tar'; then
        quiet=(--warning=no-unknown-keyword)
    fi
    tar -xJf "${cache}/base.txz" -C "${SYSROOT}.part" ${quiet[@]+"${quiet[@]}"} \
        --exclude './usr/lib/libprivate*' \
        ./lib ./usr/lib ./usr/include ./usr/libdata
    mv "${SYSROOT}.part" "${SYSROOT}"
    printf 'FreeBSD %s %s base.txz sha256 %s\n' "${RELEASE}" "${ARCH}" "${got}" \
        > "${SYSROOT}/.netwatch-sysroot"
    rm -f "${cache}/base.txz"
    echo "Unpacked the sysroot into ${SYSROOT}"
fi

# Regenerated every run: they are two lines each, and carry the sysroot's
# path, which moves with the cache directory.
quote() { printf "'%s'" "${1//\'/\'\\\'\'}"; }
clang_target="${TRIPLE}${RELEASE%%.*}"
mkdir -p "${cache}/bin"
for pair in "freebsd-clang:${CLANG}" "freebsd-clang++:${CLANGXX}"; do
    wrapper="${cache}/bin/${pair%%:*}"
    printf '#!/bin/sh\nexec %s --target=%s --sysroot=%s -fuse-ld=lld "$@"\n' \
        "$(quote "${pair#*:}")" "${clang_target}" "$(quote "${SYSROOT}")" > "${wrapper}"
    chmod +x "${wrapper}"
done

# The version string libpcap answers pcap_lib_version() with, read without
# running it. LIBPCAP_VER in the environment wins, for a sysroot without one.
if [ -z "${LIBPCAP_VER:-}" ]; then
    for lib in "${SYSROOT}"/lib/libpcap.so.* "${SYSROOT}"/usr/lib/libpcap.so.*; do
        [ -f "${lib}" ] || continue
        LIBPCAP_VER=$(grep -a -o -E 'libpcap version [0-9]+(\.[0-9]+)+' "${lib}" | sed -n '1s/.* //p')
        [ -n "${LIBPCAP_VER}" ] && break
    done
    [ -n "${LIBPCAP_VER:-}" ] ||
        die "found no libpcap version in ${SYSROOT}; set LIBPCAP_VER to the target's libpcap version"
fi
echo "Target libpcap ${LIBPCAP_VER}"

target_env="${TRIPLE//-/_}"
target_var=$(tr '[:lower:]' '[:upper:]' <<< "${target_env}")
export "CARGO_TARGET_${target_var}_LINKER=${cache}/bin/freebsd-clang"
export "CC_${target_env}=${cache}/bin/freebsd-clang"
export "CXX_${target_env}=${cache}/bin/freebsd-clang++"
export "AR_${target_env}=${LLVM_AR}"
export "CFLAGS_${target_env}=--sysroot=${SYSROOT}"
export "CXXFLAGS_${target_env}=--sysroot=${SYSROOT}"
# Given a LIBPCAP_LIBDIR, the pcap crate's build script adds it to the link
# search path and skips pkg-config; given LIBPCAP_VER, it does not try to
# load the library to ask for its version.
export LIBPCAP_LIBDIR="${SYSROOT}/usr/lib"
export LIBPCAP_VER
export PKG_CONFIG_ALLOW_CROSS=1

if [ "${MODE}" = check ]; then
    echo "+ cargo check --target ${TRIPLE} $*"
    cargo check --target "${TRIPLE}" "$@"
    echo "cargo check for ${TRIPLE} (FreeBSD ${RELEASE}) passed"
    exit 0
fi

echo "+ cargo build --release --target ${TRIPLE} $*"
cargo build --release --target "${TRIPLE}" "$@"

bin="${CARGO_TARGET_DIR:-${root}/target}/${TRIPLE}/release/netwatch"
# A --profile or --target-dir passed through puts it somewhere else.
[ -f "${bin}" ] || die "the build passed but ${bin} is not there; look under the target directory you gave cargo"
echo
echo "Built ${bin}"
if command -v file > /dev/null; then
    file -b "${bin}"
fi
echo "Needs, on the target:"
if command -v llvm-objdump > /dev/null; then
    llvm-objdump -p "${bin}" | awk '$1 == "NEEDED" { print "  " $2 }'
elif command -v readelf > /dev/null; then
    readelf -d "${bin}" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/  \1/p'
else
    echo "  (no llvm-objdump or readelf to say)"
fi
