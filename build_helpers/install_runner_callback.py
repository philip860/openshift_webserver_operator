#!/usr/bin/env python3
import os
import glob
import shutil
import configparser

import ansible_runner

def main() -> None:
    pkg_dir = os.path.dirname(ansible_runner.__file__)

    candidates = [
        os.path.join(pkg_dir, "plugins", "callback"),
        os.path.join(pkg_dir, "display_callback", "callback"),
        os.path.join(pkg_dir, "interface", "callback"),
    ]

    found = None
    pyfiles = []
    for d in candidates:
        if os.path.isdir(d):
            pyfiles = [p for p in glob.glob(os.path.join(d, "*.py")) if not p.endswith("__init__.py")]
            if pyfiles:
                found = d
                break

    if not found:
        raise SystemExit(f"ERROR: Could not find ansible-runner callback dir. Tried: {candidates}")

    dst = "/usr/share/ansible/plugins/callback"
    os.makedirs(dst, exist_ok=True)

    for p in pyfiles:
        shutil.copy2(p, os.path.join(dst, os.path.basename(p)))

    names = [os.path.splitext(os.path.basename(p))[0] for p in pyfiles]

    preferred = None
    for cand in ("ansible_runner", "runner", "awx_display", "display"):
        if cand in names:
            preferred = cand
            break
    if not preferred:
        preferred = sorted(names)[0]

    cfg_path = "/etc/ansible/ansible.cfg"
    os.makedirs("/etc/ansible", exist_ok=True)
    with open(cfg_path, "w", encoding="utf-8") as f:
        f.write("[defaults]\n")
        f.write("callback_plugins = /usr/share/ansible/plugins/callback\n")
        f.write(f"stdout_callback = {preferred}\n")
        f.write("bin_ansible_callbacks = True\n")
        f.write("nocows = 1\n")

    print("Callback dir:", found)
    print("Copied plugins:", ",".join(sorted(names)))
    print("Configured stdout_callback:", preferred)

    cfg = configparser.ConfigParser()
    cfg.read(cfg_path)
    print("Sanity stdout_callback:", cfg.get("defaults", "stdout_callback", fallback=""))

if __name__ == "__main__":
    main()
