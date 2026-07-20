#!/usr/bin/env python3
"""
Convert a Netscape cookies.txt blob (or a raw Cookie header) into a canonical
Cookie header string for the YouTube Music plugin.

The user pastes either:
  (a) the contents of a cookies.txt exported by "Get cookies.txt LOCALLY" or a
      similar browser extension, beginning with '# Netscape HTTP Cookie File'
      and followed by tab-separated lines
      (domain  includeSubdomains  path  secure  expiry  name  value), or
  (b) a raw "Cookie:" request header copied from DevTools.

This helper detects which format was pasted and returns a single normalized
Cookie header string (name=value pairs joined by '; '). Only cookies whose
domain is relevant to YouTube Music are kept (.youtube.com, .google.com and
their subdomains), so junk from other sites in the same cookies.txt is dropped.

Usage:
  python3 ytm_netscape_to_cookie.py "<pasted-text>" [prefs_dir]

Prints the normalized Cookie header string on stdout (single line). On error
prints ERROR: ... and exits non-zero. The optional prefs_dir argument is
accepted for symmetry with the other helpers but unused here.
"""
import sys
import os


# Domains we care about for YouTube Music auth. Subdomain match: the Netscape
# "includeSubdomains" flag is TRUE for these, but we still keep any cookie whose
# domain ends with one of these suffixes to be safe.
_YT_DOMAINS = ('.youtube.com', '.google.com', '.googleusercontent.com',
               '.googlevideo.com', '.ytimg.com', '.accounts.google.com',
               '.music.youtube.com')


def _is_yt_domain(domain):
    d = domain.lower().lstrip('.')
    for yd in _YT_DOMAINS:
        if d == yd.lstrip('.') or d.endswith(yd):
            return True
    return False


def parse_netscape(text):
    """Parse Netscape cookies.txt content. Return list of (name, value)."""
    pairs = []
    for line in text.splitlines():
        line = line.rstrip('\n')
        if not line:
            continue
        if line.startswith('#'):
            continue
        fields = line.split('\t')
        if len(fields) < 7:
            # Some exporters use spaces; try splitting on whitespace, but the
            # value (last field) may contain spaces, so split with maxsplit.
            fields = line.split(None, 6)
        if len(fields) < 7:
            continue
        domain, _inc, _path, _secure, _expiry, name, value = fields[:7]
        if not name or not _is_yt_domain(domain):
            continue
        pairs.append((name, value))
    return pairs


def parse_raw_header(text):
    """Parse a raw Cookie header (may start with 'Cookie:' or just be k=v; ...)."""
    s = text.strip()
    # Strip a leading "Cookie:" label if present
    if s.lower().startswith('cookie:'):
        s = s.split(':', 1)[1].strip()
    pairs = []
    for part in s.split(';'):
        part = part.strip()
        if not part:
            continue
        if '=' in part:
            name, value = part.split('=', 1)
            pairs.append((name.strip(), value.strip()))
    return pairs


def looks_like_netscape(text):
    """Heuristic: Netscape format has the header line or tab-separated rows."""
    if '# netscape' in text.lower() and 'cookie file' in text.lower():
        return True
    # Count tab-heavy lines
    tab_lines = sum(1 for ln in text.splitlines()
                    if ln.count('\t') >= 6 and not ln.startswith('#'))
    return tab_lines >= 3


def main():
    # Accept the pasted text either as argv[1] or, when invoked with "-" or
    # with no args, from stdin. The Perl caller passes via stdin to avoid
    # argv length and quoting pitfalls.
    if len(sys.argv) >= 2 and sys.argv[1] != '-':
        text = sys.argv[1]
    else:
        text = sys.stdin.read()

    if looks_like_netscape(text):
        pairs = parse_netscape(text)
        src = 'netscape'
    else:
        pairs = parse_raw_header(text)
        src = 'raw-header'

    if not pairs:
        print("ERROR: no cookies parsed from input")
        sys.exit(1)

    # Dedup keeping last occurrence (cookies.txt can contain both .youtube.com
    # and .music.youtube.com variants of the same name).
    seen = {}
    for k, v in pairs:
        seen[k] = v

    cookie = '; '.join(f'{k}={v}' for k, v in seen.items())

    # Sanity: the load-bearing cookies for YouTube Music auth. Warn (on stderr)
    # if any are missing, but still return what we have.
    required = ('SAPISID', '__Secure-3PSID')
    missing = [r for r in required if r not in seen]
    if missing:
        sys.stderr.write(
            f"WARNING: source={src}, missing key cookies: {', '.join(missing)} "
            "(authentication may fail)\n"
        )

    sys.stdout.write(cookie)
    sys.stderr.write(f"OK: source={src}, cookies={len(seen)}\n")


if __name__ == '__main__':
    main()
