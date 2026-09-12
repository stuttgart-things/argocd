#!/usr/bin/env python3
"""Every `# renovate:` comment must sit directly above the line it pins.

renovate.json's custom manager matches `# renovate: datasource=… depName=…`
IMMEDIATELY followed by a `key: value` line. Anything in between -- an
explanation comment, a blank line -- and renovate silently stops seeing that
pin: no error, no PR, the version just ages. That happened to four homerun2
catalog pins (omniPitcher, coreCatcher, scout, notificationCatcher) until
stuttgart-things/argocd#392.

Scans the same files the manager does (values.yaml anywhere, platforms/**.yaml)
and fails on any renovate comment whose next line is not a key: value line.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
COMMENT = re.compile(r"^\s*# renovate: datasource=\S+ depName=\S+")
KEYLINE = re.compile(r"^\s*[\w.]+: ?\"?[^\s\"]+")


def files(root: Path):
    for p in sorted(root.rglob("*.yaml")):
        rel = p.relative_to(root).as_posix()
        if "/.git/" in f"/{rel}":
            continue
        if p.name == "values.yaml" or rel.startswith("platforms/"):
            yield p


def main(root: Path) -> int:
    bad = []
    checked = 0
    for p in files(root):
        lines = p.read_text().splitlines()
        for i, line in enumerate(lines):
            if not COMMENT.match(line):
                continue
            checked += 1
            nxt = lines[i + 1] if i + 1 < len(lines) else ""
            if nxt.lstrip().startswith("#") or not KEYLINE.match(nxt):
                bad.append((p.relative_to(root), i + 1, line.strip(), nxt.strip()))
    for rel, n, line, nxt in bad:
        print(f"{rel}:{n}: renovate comment is not directly above its pin", file=sys.stderr)
        print(f"    {line}", file=sys.stderr)
        print(f"    next line: {nxt or '<end of file>'}", file=sys.stderr)
        print("    move explanations ABOVE the '# renovate:' line; renovate needs the key on the very next line", file=sys.stderr)
    if bad:
        return 1
    print(f"OK: {checked} renovate comment(s), each directly above its pin")
    return 0


if __name__ == "__main__":
    sys.exit(main(Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT))
