#!/usr/bin/env python3
"""Pack a staged tree into a FreeBSD pkg(8) package, on a host without pkg.

    scripts/freebsd-pkg.py <stage-root> <plist> <manifest.json> <out-dir>

scripts/freebsd-pkg.sh runs this when `pkg` is not on PATH (on Linux, say),
with the same plist and rendered manifest it would otherwise hand to
`pkg create`, so the two routes install the same files with the same
metadata. Prints the path of the package it wrote.

A .pkg is a tar archive, zstd-compressed since pkg 1.17. Its first two
entries are +COMPACT_MANIFEST and +MANIFEST, both JSON; the installed files
follow, under their absolute paths. +MANIFEST lists every file with its
checksum in pkg's "<type>$<digest>" form, and type 1 is a hex sha256. pkg
2.8.4 on OPNsense 26.7 installs what this writes and `pkg check -s` passes.

The plist is the `pkg create -p` format, one path per line relative to the
manifest's prefix. The only keyword understood is `@(user,group,mode)`, which
sets the owner and mode of the next path; any field may be empty. Every
other file is root:wheel with the staged file's mode. Anything else that
starts with `@` is an error rather than silently dropped.

Needs Python 3.8+ and the zstd command-line tool. SOURCE_DATE_EPOCH, when
set, is the mtime of the two manifest entries.
"""
import hashlib
import io
import json
import os
import shutil
import subprocess
import sys
import tarfile
import time

# Keys `pkg create` leaves out of +COMPACT_MANIFEST, which is what pkg reads
# when it only needs to know what a package is, not what it installs.
NOT_COMPACT = ("files", "directories", "scripts", "lua_scripts", "messages", "config")


def read_plist(path, prefix):
    """Yield (absolute install path, (user, group, mode or None))."""
    with open(path, encoding="utf-8") as f:
        for lineno, raw in enumerate(f, 1):
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            user, group, mode = "root", "wheel", None
            if line.startswith("@"):
                keyword, _, line = line.partition(" ")
                if not (keyword.startswith("@(") and keyword.endswith(")")):
                    sys.exit(f"{path}:{lineno}: unsupported plist keyword {keyword}")
                fields = keyword[2:-1].split(",")
                if len(fields) != 3:
                    sys.exit(f"{path}:{lineno}: expected @(user,group,mode), got {keyword}")
                user = fields[0] or user
                group = fields[1] or group
                mode = int(fields[2], 8) if fields[2] else None
                line = line.strip()
            yield os.path.join(prefix, line), (user, group, mode)


def tar_bytes(tar, name, data, mtime):
    info = tarfile.TarInfo(name)
    info.size, info.mode, info.mtime = len(data), 0o644, mtime
    info.uname, info.gname = "root", "wheel"
    tar.addfile(info, io.BytesIO(data))


def main():
    if len(sys.argv) != 5:
        sys.exit("usage: " + __doc__.strip().splitlines()[2].strip())
    stage, plist, manifest_path, outdir = sys.argv[1:]
    if shutil.which("zstd") is None:
        sys.exit("freebsd-pkg.py: needs the zstd command-line tool")

    with open(manifest_path, encoding="utf-8") as f:
        manifest = json.load(f)
    prefix = manifest.get("prefix", "/usr/local")

    entries, files, flatsize = [], {}, 0
    for path, owner in read_plist(plist, prefix):
        src = os.path.join(stage, path.lstrip("/"))
        if not os.path.isfile(src) or os.path.islink(src):
            sys.exit(f"freebsd-pkg.py: {src} is in the plist but is not a regular file")
        h = hashlib.sha256()
        with open(src, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                h.update(chunk)
        st = os.stat(src)
        user, group, mode = owner
        mode = st.st_mode & 0o7777 if mode is None else mode
        # The form `pkg create` writes. pkg also takes a bare checksum, but
        # then records no owner, and `pkg query %Fu` comes back empty.
        files[path] = {
            "sum": "1$" + h.hexdigest(),
            "uname": user,
            "gname": group,
            "perm": f"{mode:04o}",
            "mtime": int(st.st_mtime),
        }
        flatsize += st.st_size
        entries.append((path, src, (user, group, mode)))

    manifest["flatsize"] = flatsize
    manifest["files"] = files
    compact = {k: v for k, v in manifest.items() if k not in NOT_COMPACT}

    os.makedirs(outdir, exist_ok=True)
    out = os.path.join(outdir, f"{manifest['name']}-{manifest['version']}.pkg")
    mtime = int(os.environ.get("SOURCE_DATE_EPOCH") or time.time())

    zstd = subprocess.Popen(["zstd", "-19", "-q", "-f", "-o", out], stdin=subprocess.PIPE)
    with tarfile.open(fileobj=zstd.stdin, mode="w|", format=tarfile.PAX_FORMAT) as tar:
        tar_bytes(tar, "+COMPACT_MANIFEST", json.dumps(compact).encode(), mtime)
        tar_bytes(tar, "+MANIFEST", json.dumps(manifest).encode(), mtime)
        for path, src, (user, group, mode) in entries:
            info = tar.gettarinfo(src)
            # pkg stores absolute paths; gettarinfo would strip the slash.
            info.name = path
            info.uid = info.gid = 0
            info.uname, info.gname, info.mode = user, group, mode
            with open(src, "rb") as f:
                tar.addfile(info, f)
    zstd.stdin.close()
    if zstd.wait() != 0:
        sys.exit("freebsd-pkg.py: zstd failed")
    print(out)


if __name__ == "__main__":
    main()
