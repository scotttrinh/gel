"""Make a Linux install tree self-contained.

Copies every shared library that an ELF file in the tree needs, and that
isn't on the allowed system list, into <prefix>/lib.  Then points each ELF
file that needs one of those libraries at <prefix>/lib with an
$ORIGIN-relative RUNPATH.  Finally, re-checks every ELF file without
LD_LIBRARY_PATH and fails if anything resolves outside the tree or the
allowed list.
"""

import argparse
import collections
import os
import pathlib
import re
import shutil
import subprocess
import sys

# manylinux_2_28 policy libraries that every glibc system has.
ALLOWED = {
    "gnu": {
        "libc.so.6", "libm.so.6", "libdl.so.2", "libpthread.so.0",
        "librt.so.1", "libutil.so.1", "libresolv.so.2", "libgcc_s.so.1",
        "libstdc++.so.6", "ld-linux-x86-64.so.2", "ld-linux-aarch64.so.1",
        "linux-vdso.so.1",
    },
    "musl": {
        "libc.musl-x86_64.so.1", "libc.musl-aarch64.so.1",
        "ld-musl-x86_64.so.1", "ld-musl-aarch64.so.1",
    },
}
LDD_LINE = re.compile(r"^\s*(\S+)\s*=>\s*(\S+)")


def is_elf(path: pathlib.Path) -> bool:
    if path.is_symlink() or not path.is_file():
        return False
    with open(path, "rb") as f:
        return f.read(4) == b"\x7fELF"


def ldd(path: pathlib.Path, env: dict[str, str]) -> dict[str, str] | None:
    proc = subprocess.run(
        ["ldd", str(path)], capture_output=True, text=True, env=env
    )
    out = proc.stdout + proc.stderr
    if "not a dynamic executable" in out or "statically linked" in out:
        return None
    deps = {}
    for line in out.splitlines():
        if m := LDD_LINE.match(line):
            deps[m.group(1)] = m.group(2)
        elif line.strip().startswith("/"):
            # musl prints the loader as a bare path
            p = line.split()[0]
            deps[os.path.basename(p)] = p
    return deps


def patchelf(*args: str) -> str:
    return subprocess.run(
        ["patchelf", *args], capture_output=True, text=True, check=True
    ).stdout.strip()


def inside(path: str, prefix: pathlib.Path) -> bool:
    return os.path.realpath(path).startswith(str(prefix) + os.sep)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--prefix", required=True, type=pathlib.Path)
    ap.add_argument("--libc", required=True, choices=sorted(ALLOWED))
    ap.add_argument("--search", action="append", default=[])
    ap.add_argument("--report", required=True, type=pathlib.Path)
    args = ap.parse_args()

    prefix = args.prefix.resolve()
    libdir = prefix / "lib"
    allowed = ALLOWED[args.libc]
    build_env = dict(os.environ)
    build_env["LD_LIBRARY_PATH"] = ":".join([str(libdir), *args.search])

    # 1. bundle
    bundled: dict[str, str] = {}
    pending = [p for p in prefix.rglob("*") if is_elf(p)]
    seen: set[pathlib.Path] = set()
    while pending:
        elf = pending.pop()
        if elf in seen:
            continue
        seen.add(elf)
        deps = ldd(elf, build_env)
        if not deps:
            continue
        for name, path in deps.items():
            if name in allowed or os.path.basename(path) in allowed:
                continue
            if path == "not" or path == "not found":
                raise SystemExit(f"{elf}: {name} not found at build time")
            if inside(path, prefix) or name in bundled:
                continue
            dest = libdir / name
            shutil.copy2(os.path.realpath(path), dest)
            dest.chmod(0o755)
            bundled[name] = os.path.realpath(path)
            pending.append(dest)

    # 2. rpath
    in_lib = {p.name for p in libdir.iterdir() if p.is_file() or p.is_symlink()}
    patched = 0
    for elf in sorted(seen | {libdir / n for n in bundled}):
        if not is_elf(elf) or ldd(elf, build_env) is None:
            continue
        try:
            needed = patchelf("--print-needed", str(elf)).split()
            old = patchelf("--print-rpath", str(elf))
        except subprocess.CalledProcessError:
            continue
        old_entries = [e for e in old.split(":") if e]
        keep = [e for e in old_entries if e.startswith("$ORIGIN")]
        absolute = [e for e in old_entries if not e.startswith("$ORIGIN")]
        if not (set(needed) & in_lib) and not absolute:
            continue
        rel = os.path.relpath(libdir, elf.parent)
        first = "$ORIGIN" if rel == "." else f"$ORIGIN/{rel}"
        new = [first] + [e for e in keep if e != first]
        if new != old_entries:
            patchelf("--set-rpath", ":".join(new), str(elf))
            patched += 1

    # 3. verify, as a user would run it
    clean_env = {k: v for k, v in os.environ.items() if k != "LD_LIBRARY_PATH"}
    problems = []
    system_use: collections.Counter[str] = collections.Counter()
    checked = 0
    for elf in sorted(p for p in prefix.rglob("*") if is_elf(p)):
        deps = ldd(elf, clean_env)
        if deps is None:
            continue
        checked += 1
        for name, path in deps.items():
            if path in ("not", "not found"):
                problems.append(f"{elf.relative_to(prefix)}: {name} not found")
            elif inside(path, prefix):
                continue
            elif name in allowed or os.path.basename(path) in allowed:
                system_use[name] += 1
            else:
                problems.append(
                    f"{elf.relative_to(prefix)}: {name} => {path} (outside tree)"
                )
        for entry in patchelf("--print-rpath", str(elf)).split(":"):
            if entry and not entry.startswith("$ORIGIN"):
                problems.append(f"{elf.relative_to(prefix)}: absolute rpath {entry}")

    with open(args.report, "w") as f:
        f.write(f"elf files checked: {checked}\nrpaths patched: {patched}\n")
        f.write("\nbundled libraries:\n")
        for name, src in sorted(bundled.items()):
            f.write(f"  {name} <= {src}\n")
        f.write("\nsystem libraries used (count of ELF files):\n")
        for name, n in sorted(system_use.items()):
            f.write(f"  {name}: {n}\n")
        f.write(f"\nproblems: {len(problems)}\n")
        for p in problems:
            f.write(f"  {p}\n")
    print(args.report.read_text())
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
