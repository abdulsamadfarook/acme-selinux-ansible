#!/usr/bin/python3
"""Turn raw audit records (ausearch --raw on stdin) into a discovery summary.

JSON output:
  total           AVC / USER_AVC denial records
  enforced        how many of those had permissive=0 (already breaking something)
  selinux_errors  SELINUX_ERR / USER_SELINUX_ERR records (not AVCs, but real failures)
  denials         unique (process, source, target, class, perms) tuples with counts
  root_causes     denials grouped into the change a human would actually make:
                    port   - name_bind / name_connect on a port of the wrong type
                    label  - a confined domain touching a generic / mislabelled file type
                    policy - anything else: a boolean or a custom module (see hint)

Why root causes: one mislabelled data directory produces a row per permission per
file (getattr, open, read, write, ...). Counting rows overstates the work; counting
root causes is what a change board and a discovery slide need.
"""
import json
import os
import re
import subprocess
import sys
from collections import OrderedDict

AVC = re.compile(r"avc:\s+denied\s+\{ (?P<perms>[^}]+) \}")
FIELD = re.compile(r'(\w+)=("[^"]*"|\S+)')

# Types a correctly configured app should almost never need: hitting one of these
# means "this object is missing a specific label", not "policy is missing a rule".
GENERIC_TYPES = {
    "default_t", "unlabeled_t", "file_t", "var_t", "var_run_t", "var_log_t",
    "var_lib_t", "tmp_t", "user_tmp_t", "user_home_t", "user_home_dir_t",
    "admin_home_t", "home_root_t", "usr_t", "etc_t", "mnt_t",
}
FILE_CLASSES = {"file", "dir", "sock_file", "lnk_file", "fifo_file", "chr_file", "blk_file"}
PORT_PERMS = {"name_bind", "name_connect"}
# A denial on one of these means "the port has no specific type yet" -> label it.
# A denial on an already-specific type (e.g. http_port_t) means the port is fine and
# the DOMAIN lacks permission -> boolean or policy, not a port label.
GENERIC_PORT_TYPES = {"unreserved_port_t", "reserved_port_t", "hi_reserved_port_t",
                      "port_t", "ephemeral_port_t"}


def ctx_type(ctx):
    parts = ctx.split(":")
    return parts[2] if len(parts) > 2 else ctx


def audit2why_hint(raw_line):
    """Ask audit2why what it thinks; keep only the actionable sentence."""
    try:
        out = subprocess.run(["audit2why"], input=raw_line, capture_output=True,
                             text=True, timeout=20).stdout
    except Exception:  # audit2why missing or slow: the hint is optional
        return ""
    booleans = re.findall(r"setsebool -P (\S+) 1", out)
    if booleans:
        return "audit2why: boolean " + ", ".join(sorted(set(booleans)))
    if "Missing type enforcement" in out:
        return "audit2why: missing allow rule"
    if "constraint" in out.lower():
        return "audit2why: constraint violation"
    return ""


def classify(f, perms):
    scon, tcon, tclass = f["s"], f["t"], f["tclass"]
    if (tclass in ("tcp_socket", "udp_socket", "sctp_socket") and set(perms) & PORT_PERMS
            and tcon in GENERIC_PORT_TYPES):
        port = f.get("src") or f.get("dest") or "?"
        return ("port", scon, tcon, tclass, port)
    if tclass in FILE_CLASSES and tcon in GENERIC_TYPES:
        return ("label", scon, tcon, "", "")
    return ("policy", scon, tcon, tclass, "")


def main():
    denials = OrderedDict()
    causes = OrderedDict()
    total = enforced = errors = 0
    for line in sys.stdin:
        if "type=SELINUX_ERR" in line or "type=USER_SELINUX_ERR" in line:
            errors += 1
            continue
        m = AVC.search(line)
        if not m:
            continue
        total += 1
        f = {k: v.strip('"') for k, v in FIELD.findall(line)}
        f["s"] = ctx_type(f.get("scontext", "?"))
        f["t"] = ctx_type(f.get("tcontext", "?"))
        f["tclass"] = f.get("tclass", "?")
        perms = m.group("perms").split()
        permissive = f.get("permissive", "?")
        if permissive == "0":
            enforced += 1
        where = f.get("path") or f.get("name") or f.get("src") or f.get("dest") or ""

        dkey = (f.get("comm", "?"), f["s"], f["t"], f["tclass"], " ".join(perms), permissive)
        d = denials.setdefault(dkey, {"count": 0, "sample_name": where})
        d["count"] += 1

        ckey = classify(f, perms)
        c = causes.get(ckey)
        if c is None:
            c = causes[ckey] = {
                "fix": ckey[0], "scontext": ckey[1], "tcontext": ckey[2],
                "tclass": ckey[3] or None, "port": ckey[4] or None,
                "records": 0, "perms": set(), "comms": set(), "examples": [],
                "enforced": False, "_raw": line,
            }
        c["records"] += 1
        c["perms"].update(perms)
        c["comms"].add(f.get("comm", "?"))
        c["enforced"] = c["enforced"] or permissive == "0"
        if where and where not in c["examples"] and len(c["examples"]) < 5:
            c["examples"].append(where)

    root_causes = []
    for c in causes.values():
        c["hint"] = audit2why_hint(c.pop("_raw"))
        c["perms"] = sorted(c["perms"])
        c["comms"] = sorted(c["comms"])
        dirs = sorted({os.path.dirname(e) for e in c["examples"] if e.startswith("/")})
        if c["fix"] == "port":
            c["suggestion"] = (f"semanage port -a -t <port type {c['scontext']} may "
                               f"{'/'.join(sorted(set(c['perms']) & PORT_PERMS))}> -p tcp {c['port']}")
        elif c["fix"] == "label":
            target = dirs[0] if dirs else "<dir>"
            c["suggestion"] = (f"semanage fcontext -a -t <type for {c['scontext']}> "
                               f"'{target}(/.*)?' && restorecon -Rv {target}")
        else:
            c["suggestion"] = "boolean if audit2why names one, otherwise a targeted module rule (review!)"
        root_causes.append(c)

    out_denials = [
        dict(zip(("comm", "scontext", "tcontext", "tclass", "perms", "permissive"), k), **v)
        for k, v in denials.items()
    ]
    json.dump({"total": total, "enforced": enforced, "selinux_errors": errors,
               "denials": out_denials, "root_causes": root_causes}, sys.stdout)


if __name__ == "__main__":
    main()
