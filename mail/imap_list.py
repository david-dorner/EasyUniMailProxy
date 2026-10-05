#!/usr/bin/env python3
"""Shared IMAP LIST parsing: decode modified UTF-7 names and pull folder names
(optionally with their flags) out of imaplib's raw LIST/LSUB responses.

Used by special_use.py, idle.py, and sync.py so the three places that need to
know "what folders actually exist over there" agree on exactly how to parse it.
"""
import base64
import re

_LIST_RE = re.compile(rb'^\((?P<flags>[^)]*)\)\s+(?:"(?P<sep>[^"]*)"|NIL)\s+(?P<name>.+)$')


def imap_utf7_decode(s: str) -> str:
    """Decode IMAP modified UTF-7 (RFC 3501) folder names to real UTF-8, so a
    folder like 'Entw&APw-rfe' reads as 'Entwürfe'."""
    out = []
    i = 0
    while i < len(s):
        c = s[i]
        if c == "&":
            j = s.find("-", i)
            if j == -1:
                out.append(s[i:])
                break
            chunk = s[i + 1:j]
            if chunk == "":
                out.append("&")  # '&-' is a literal '&'
            else:
                b64 = chunk.replace(",", "/")
                b64 += "=" * (-len(b64) % 4)
                out.append(base64.b64decode(b64).decode("utf-16-be"))
            i = j + 1
        else:
            out.append(c)
            i += 1
    return "".join(out)


def parse_list(lines) -> list[tuple[str, list[str], str]]:
    """Parse imaplib LIST/LSUB response lines into [(name, [flags], sep), ...],
    names decoded from modified UTF-7. Lines that don't parse are skipped."""
    out = []
    for raw in lines or []:
        if not raw:
            continue
        m = _LIST_RE.match(raw.strip())
        if not m:
            continue
        flags = m.group("flags").decode("ascii", "replace").split()
        sep = (m.group("sep") or b"").decode("ascii", "replace")
        name = m.group("name").strip()
        if name.startswith(b'"') and name.endswith(b'"'):
            name = name[1:-1]
        out.append((imap_utf7_decode(name.decode("ascii", "replace")), flags, sep))
    return out


def list_names(lines) -> list[str]:
    """Just the decoded folder names, in LIST/LSUB order."""
    return [name for name, _flags, _sep in parse_list(lines)]
