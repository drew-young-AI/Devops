#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Every file the Alertmanager config names must be mounted into its container.

WHY THIS EXISTS (2026-09-13).

`setup_notifications.sh` emits `auth_password_file:
/etc/alertmanager/smtp-password` whenever mail is configured. `compose.yaml`
mounted `config.yml` and `telegram-token` and nothing else, so that path did
not exist inside the container.

Nothing caught it. `amtool check-config` validates syntax and never opens the
file, so the config was accepted; the container started; the board would have
gone green. The failure could only surface at the first actual send -- which is
the day somebody finishes configuring mail and starts expecting notifications.
That is the same shape as 2026-08-19, when an alert fired for 3h55m into a
receiver that went nowhere.

DERIVED FROM BOTH SIDES. The paths come from a generated config, the mounts
come from compose.yaml. Neither is a hand-written list, so neither can drift
from the thing it describes.

Usage: alertmanager_mount_check.py <generated-config.yml> <compose.yaml>
Exit 0 and print MOUNTS OK, or exit 1 naming what is unmounted.
"""

import io
import re
import sys


def config_file_paths(text):
    """Absolute container paths named by any `*_file:` key."""
    out = set()
    for m in re.finditer(r"^\s*\w*_file\s*:\s*(\S+)\s*$", text, re.M):
        v = m.group(1).strip().strip('"').strip("'")
        if v.startswith("/"):
            out.add(v)
    return out


def alertmanager_mounts(text):
    """Container-side destinations bind-mounted into the alertmanager service."""
    i = text.find("alertmanager:")
    if i < 0:
        raise SystemExit("REFUSING: no alertmanager service in the compose file")
    seg = text[i:]
    j = seg.find("volumes:")
    if j < 0:
        raise SystemExit("REFUSING: the alertmanager service declares no volumes")
    out = set()
    for line in seg[j:].splitlines()[1:]:
        if line.strip() and not line.startswith(" " * 6):
            break
        m = re.match(r"\s*-\s*([^\s:]+):([^\s:]+)(:ro|:rw)?\s*$", line)
        if m:
            out.add(m.group(2))
    return out


def main(argv):
    if len(argv) != 2:
        raise SystemExit(__doc__.strip().splitlines()[-3])
    cfg = io.open(argv[0], encoding="utf-8").read()
    comp = io.open(argv[1], encoding="utf-8").read()

    named = config_file_paths(cfg)
    mounts = alertmanager_mounts(comp)
    if not mounts:
        raise SystemExit("REFUSING: parsed zero mounts -- an empty scan is not a pass")

    missing = sorted(p for p in named if p not in mounts)
    if missing:
        print("UNMOUNTED: the config names files the container cannot open:")
        for p in missing:
            print("   %s" % p)
        print("mounted destinations were: %s" % ", ".join(sorted(mounts)))
        return 1
    print("MOUNTS OK (%d file path(s) named, all mounted: %s)"
          % (len(named), ", ".join(sorted(named)) if named else "none"))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
