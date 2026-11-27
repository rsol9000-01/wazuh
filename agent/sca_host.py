#!/usr/bin/env python3
"""
Build "host" copies of the Wazuh SCA (CIS) policies so that a containerized
agent evaluates the host, not its own container.

Why: the agent runs in Docker. The official policies read paths such as
/etc/ssh/sshd_config and run commands such as `systemctl` or `sshd -T`.
Inside the container those paths and commands belong to the agent image,
so the CIS report would describe the image, not the server.

What it changes in each policy (nothing else):
  - f: and d: checks, and path variables  ->  prefixed with /host
    (the host root, mounted read-only at /host)
  - c: checks                              ->  run inside the host namespaces
    with `nsenter -t 1 -m -u -i -n -p --` (needs pid: host, SYS_ADMIN,
    SYS_PTRACE). chroot is not used: systemctl cannot reach systemd from a
    chroot ("Failed to connect to bus"). The host PID namespace is needed:
    without it, systemctl and ps fail in the host mount namespace (they cannot
    find /proc/self). pid: host is only safe with the agent image of this
    repository, whose Dockerfile removes s6-nuke (see agent/Dockerfile).
  - policy id gets the suffix _host and the name the suffix " (host)"

Which policy: only the one for the host operating system and version,
chosen from /host/etc/os-release (ID and VERSION_ID). The requirements of
the official policies are not enough to choose: several only check that a
file exists (for example, the Debian 7 to 10 policies pass on Ubuntu because
Ubuntu also has /etc/debian_version). The Wazuh installer chooses by OS when
it installs the agent; here the agent image is not the host OS, so the
choice is made here. If no policy matches, the distribution-independent
Linux policy is used.

Usage:
  sca_host.py <source dir with the official .yml> <output dir>
"""
import os
import re
import sys

import yaml

NSENTER = "nsenter -t 1 -m -u -i -n -p -- "
HOST = "/host"
OS_RELEASE = HOST + "/etc/os-release"
GENERIC = os.path.join("generic", "sca_distro_independent_linux.yml")

# os-release ID -> folder of the Wazuh ruleset
FOLDERS = {"ubuntu": "ubuntu", "debian": "debian", "almalinux": "almalinux",
           "rocky": "rocky", "amzn": "amazon", "centos": "centos", "ol": "ol",
           "rhel": "rhel", "sles": "sles", "sled": "sles"}

RULE = re.compile(r"^(?P<neg>not\s+)?(?P<type>[fdc]):(?P<rest>.*)$", re.S)


# ---------------------------------------------------------------------------
# Prefix every absolute path of a comma-separated list with /host
# ---------------------------------------------------------------------------
def host_paths(value):
    items = []
    for item in value.split(","):
        stripped = item.strip()
        items.append(HOST + stripped if stripped.startswith("/") else stripped)
    return ",".join(items)


# ---------------------------------------------------------------------------
# Rewrite one SCA rule string
# ---------------------------------------------------------------------------
def host_rule(rule):
    m = RULE.match(rule)
    if not m:
        return rule                          # p:, r: and others stay as they are
    neg, kind, rest = m.group("neg") or "", m.group("type"), m.group("rest")
    target, sep, tail = rest.partition(" -> ")
    if kind in ("f", "d"):
        target = host_paths(target)
    else:
        target = NSENTER + target
    return f"{neg}{kind}:{target}{sep}{tail}"


# ---------------------------------------------------------------------------
# Rewrite one policy document
# ---------------------------------------------------------------------------
def host_policy(doc):
    pol = doc.get("policy", {})
    pol["id"] = f"{pol.get('id', 'policy')}_host"
    pol["name"] = f"{pol.get('name', '')} (host)"
    if "file" in pol:
        pol["file"] = pol["file"].replace(".yml", "_host.yml")

    req = doc.get("requirements") or {}
    req["rules"] = [host_rule(r) for r in req.get("rules", [])]

    variables = doc.get("variables") or {}
    for key, value in variables.items():
        if isinstance(value, str):
            variables[key] = host_paths(value)

    for check in doc.get("checks") or []:
        check["rules"] = [host_rule(r) for r in check.get("rules", [])]
    return doc


# ---------------------------------------------------------------------------
# Read ID and VERSION_ID of the host. An absolute symlink is resolved under
# /host, because inside the container it would point to the agent image.
# ---------------------------------------------------------------------------
def host_os(path=OS_RELEASE):
    if os.path.islink(path) and os.readlink(path).startswith("/"):
        path = HOST + os.readlink(path)
    info = {}
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                key, sep, value = line.strip().partition("=")
                if sep:
                    info[key] = value.strip().strip('"')
    except OSError:
        pass
    return info.get("ID", "").lower(), info.get("VERSION_ID", "")


# ---------------------------------------------------------------------------
# Choose the official policy for that OS and version (path relative to src)
# ---------------------------------------------------------------------------
def choose_policy(src, os_id, version):
    folder = FOLDERS.get(os_id)
    if folder and version:
        if os_id == "ubuntu":                   # 24.04 -> cis_ubuntu24-04.yml
            token = re.compile(re.escape(version.replace(".", "-")) + r"(?!\d)")
        else:                                   # 12 -> cis_debian12.yml, rhel/9/...
            token = re.compile(r"(?<!\d)" + re.escape(version.split(".")[0]) + r"(?!\d)")
        base = os.path.join(src, folder)
        for root, _dirs, files in sorted(os.walk(base)):
            for name in sorted(files):
                rel = os.path.relpath(os.path.join(root, name), src)
                if name.endswith((".yml", ".yaml")) and token.search(os.path.relpath(rel, folder)):
                    return rel
    return GENERIC


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    src, out = sys.argv[1], sys.argv[2]
    os.makedirs(out, exist_ok=True)
    os_id, version = host_os()
    rel = choose_policy(src, os_id, version)
    with open(os.path.join(src, rel), encoding="utf-8") as fh:
        doc = yaml.safe_load(fh)
    name = os.path.basename(rel).rsplit(".", 1)[0] + "_host.yml"
    with open(os.path.join(out, name), "w", encoding="utf-8") as fh:
        yaml.safe_dump(host_policy(doc), fh, sort_keys=False,
                       allow_unicode=True, width=1_000_000)
    print(f"SCA: host {os_id or '?'} {version or '?'} -> {rel} -> {out}/{name}")


if __name__ == "__main__":
    main()
