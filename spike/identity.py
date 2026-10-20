"""Print the portable tree identity, e.g. 7.1+ec15259, from _buildmeta.py."""

import importlib.util, pathlib, sys
prefix = pathlib.Path(sys.argv[1])
path = next(prefix.glob("lib/python3.*/site-packages/edb/_buildmeta.py"))
spec = importlib.util.spec_from_file_location("_buildmeta", path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
major, minor, stage, stage_no, local = mod.VERSION
build_hash = next(p[1:] for p in local if p.startswith("s"))
names = {0: "dev", 10: "alpha", 20: "beta", 30: "rc"}
suffix = "" if stage == 40 else f"-{names[stage]}.{stage_no}"
print(f"{major}.{minor}{suffix}+{build_hash}")
