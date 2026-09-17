#!/usr/bin/env python3
"""DevX manifest parser.

Reads a constrained subset of YAML on stdin and prints flat KEY=VALUE lines
on stdout for the `dev` bash script to consume. Stdlib only (no PyYAML).

Supported shape (everything optional):

    web: php                       # service that owns the public domain
    databases: [mysql, postgres]   # inline list ...
    databases:                     # ... or block list
      - mysql
      - redis
    php:
      version: "8.3"
      server: nginx                # apache | nginx
      docroot: public              # public | .
    node:
      version: "20"
      framework: adonis            # override auto-detect
      command: "node ace serve --hmr"
      port: 3333
    python: { version: "3.12", command: "...", port: 8000 }
    go:   { version: "1.22", port: 8080 }
    ruby: { version: "3.3", port: 3000 }

Output keys are flattened with `_`, e.g. `php_server=nginx`, `node_port=3333`.
Unknown / malformed lines are ignored rather than fatal.
"""
import sys
import re

LIST_KEYS = {"databases"}
out = []
sec = None
in_list = False
list_key = None
list_items = []


def clean(v):
    v = v.strip()
    # quoted value: return inner content, ignore any trailing inline comment
    if v and v[0] in "\"'":
        q = v[0]
        end = v.find(q, 1)
        if end != -1:
            return v[1:end]
        return v[1:]
    # unquoted value: strip trailing inline comment
    h = v.find(" #")
    if h >= 0:
        v = v[:h].rstrip()
    return v


def emit(key, value):
    key = key.strip()
    if not re.match(r"^[A-Za-z0-9_]+$", key):
        return
    value = clean(value)
    # inline list -> space separated
    if value.startswith("[") and value.endswith("]"):
        items = [clean(x) for x in value[1:-1].split(",") if x.strip()]
        value = " ".join(items)
    out.append("%s=%s" % (key, value))


def end_list():
    global in_list, list_key, list_items
    if in_list:
        out.append("%s=%s" % (list_key, " ".join(list_items)))
    in_list = False
    list_key = None
    list_items = []


for raw in sys.stdin:
    line = raw.rstrip("\n")
    if not line.strip() or line.strip().startswith("#"):
        continue
    indent = len(line) - len(line.lstrip(" "))
    s = line.strip()

    if in_list and s.startswith("- "):
        list_items.append(clean(s[2:]))
        continue
    if in_list:
        end_list()

    if indent == 0:
        if ":" not in s:
            continue
        k, v = s.split(":", 1)
        k = k.strip()
        v = v.strip()
        if v == "" and k in LIST_KEYS:
            in_list = True
            list_key = k
            list_items = []
            sec = None
            continue
        if v == "":
            sec = k
            continue
        sec = None
        emit(k, v)
    else:
        if sec and ":" in s:
            k, v = s.split(":", 1)
            emit("%s_%s" % (sec, k.strip()), v)

end_list()
if out:
    sys.stdout.write("\n".join(out) + "\n")
