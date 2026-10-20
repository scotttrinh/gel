"""Point python-build-standalone's sysconfig at the system toolchain.

PBS records the clang toolchain it was built with (clang, musl-clang,
--rtlib=compiler-rt, /tools/llvm/bin/llvm-ar), so building C extensions
against it fails on a machine without that toolchain.  uv rewrites the same
values when it installs a managed Python; this does the equivalent.
"""

import pathlib
import re
import sys

REPLACEMENTS = [
    (re.compile(r"/tools/llvm/bin/llvm-ar"), "ar"),
    (re.compile(r"(?<![\w/-])musl-clang(?![\w-])"), "cc"),
    (re.compile(r"(?<![\w/-])clang\+\+(?![\w-])"), "c++"),
    (re.compile(r"(?<![\w/-])clang(?![\w+-])"), "cc"),
    (re.compile(r" ?--rtlib=compiler-rt"), ""),
]


def main() -> None:
    prefix = pathlib.Path(sys.argv[1])
    targets = [
        *prefix.glob("lib/python3.*/_sysconfigdata_*.py"),
        *prefix.glob("lib/python3.*/config-3.*/Makefile"),
        *prefix.glob("lib/pkgconfig/python-3.*.pc"),
    ]
    for path in targets:
        text = path.read_text()
        new = text
        for pattern, repl in REPLACEMENTS:
            new = pattern.sub(repl, new)
        if new != text:
            path.write_text(new)
            print(f"patched {path.relative_to(prefix)}")
    for f in prefix.glob("lib/python3.*/__pycache__/_sysconfigdata_*.pyc"):
        f.unlink()


if __name__ == "__main__":
    main()
