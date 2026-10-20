"""Make a macOS install tree self-contained.

Every Mach-O file's dependencies outside /usr/lib and /System are copied
into <prefix>/lib (if not already in the tree) and rewritten to
@loader_path-relative names.  Modified files are ad-hoc re-signed, which
arm64 macOS requires.  Finally every Mach-O file is re-checked.
"""

import argparse
import os
import pathlib
import shutil
import subprocess
import sys

SYSTEM = ("/usr/lib/", "/System/")
MAGIC = {
    b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf",  # 64-bit
    b"\xca\xfe\xba\xbe",  # fat
}


def is_macho(path: pathlib.Path) -> bool:
    if path.is_symlink() or not path.is_file():
        return False
    with open(path, "rb") as f:
        return f.read(4) in MAGIC


def deps(path: pathlib.Path) -> list[str]:
    out = subprocess.run(
        ["otool", "-L", str(path)], capture_output=True, text=True, check=True
    ).stdout.splitlines()[1:]
    result = [line.strip().split(" (")[0] for line in out if line.strip()]
    # For dylibs, the first entry is the library's own install name.
    if path.suffix in (".dylib", ".so") and result:
        own = id_of(path)
        result = [d for d in result if d != own]
    return result


def id_of(path: pathlib.Path) -> str | None:
    out = subprocess.run(
        ["otool", "-D", str(path)], capture_output=True, text=True
    ).stdout.splitlines()
    return out[1].strip() if len(out) > 1 else None


def rpaths(path: pathlib.Path) -> list[str]:
    out = subprocess.run(
        ["otool", "-l", str(path)], capture_output=True, text=True, check=True
    ).stdout.splitlines()
    result = []
    for i, line in enumerate(out):
        if line.strip() == "cmd LC_RPATH":
            result.append(out[i + 2].strip().split()[1])
    return result


def run(*args: str) -> None:
    subprocess.run(args, check=True, capture_output=True)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--prefix", required=True, type=pathlib.Path)
    ap.add_argument("--report", required=True, type=pathlib.Path)
    args = ap.parse_args()
    prefix = args.prefix.resolve()
    libdir = prefix / "lib"

    files = [p for p in prefix.rglob("*") if is_macho(p)]
    by_name = {p.name: p for p in files if p.parent == libdir}
    bundled: dict[str, str] = {}
    changed: set[pathlib.Path] = set()

    i = 0
    while i < len(files):
        f = files[i]
        i += 1
        for dep in deps(f):
            if dep.startswith(SYSTEM) or dep.startswith("@"):
                continue
            name = os.path.basename(dep)
            real = pathlib.Path(dep).resolve()
            if str(real).startswith(str(prefix) + os.sep):
                target = real
            elif name in by_name:
                target = by_name[name]
            else:
                target = libdir / name
                shutil.copy2(real, target)
                target.chmod(0o755)
                by_name[name] = target
                bundled[name] = str(real)
                files.append(target)
            rel = os.path.relpath(target, f.parent)
            run("install_name_tool", "-change", dep, f"@loader_path/{rel}", str(f))
            changed.add(f)
        if f.suffix in (".dylib",) or f.parent == libdir:
            own = id_of(f)
            if own and not own.startswith("@"):
                run("install_name_tool", "-id", f"@rpath/{f.name}", str(f))
                changed.add(f)
        for rp in rpaths(f):
            if not rp.startswith("@"):
                run("install_name_tool", "-delete_rpath", rp, str(f))
                changed.add(f)

    for f in changed:
        run("codesign", "--force", "--sign", "-", str(f))

    problems = []
    for f in sorted(p for p in prefix.rglob("*") if is_macho(p)):
        for dep in deps(f):
            if dep.startswith(SYSTEM):
                continue
            if dep.startswith("@loader_path/"):
                resolved = (f.parent / dep.removeprefix("@loader_path/")).resolve()
                if not resolved.exists():
                    problems.append(f"{f.relative_to(prefix)}: {dep} missing")
                continue
            if dep.startswith(("@rpath/", "@executable_path/")):
                continue
            problems.append(f"{f.relative_to(prefix)}: {dep} (outside tree)")
        for rp in rpaths(f):
            if not rp.startswith("@"):
                problems.append(f"{f.relative_to(prefix)}: absolute rpath {rp}")

    with open(args.report, "w") as out:
        out.write(f"mach-o files: {len(files)}\nmodified: {len(changed)}\n")
        out.write("\nbundled libraries:\n")
        for name, src in sorted(bundled.items()):
            out.write(f"  {name} <= {src}\n")
        out.write(f"\nproblems: {len(problems)}\n")
        for p in problems:
            out.write(f"  {p}\n")
    print(args.report.read_text())
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
