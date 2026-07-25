#!/usr/bin/env python3
"""Machine-readable database-update status for the commec appliance.

Emits ONE json object describing whether the installed screening databases are behind the
revisions published in commec's R2 bucket. It is the database half of the update check
(commec-update-check); the conda half stays in shell.

Run it with the CURRENT ENV'S python (/opt/commec/current-env/bin/python) - it imports
commec.setup, so the answer always reflects the commec that is actually installed. That
matters for the "blocked" case below: the supported-revision ceiling lives in the package
(commec/database_compatibility.yaml), so a newer DB revision can be unavailable to THIS
commec and become available after a software update.

Why not just parse `commec setup -m`: its output is prose meant for a human ("biorisk 1.1
will be updated to revision 1.2."), with colour escapes, and it does not distinguish
"blocked by commec version" from "up to date" in any stable way. Upstream has no structured
status field (issue filed); we derive one here from the public API instead.

Exit status: 0 whenever a json object was produced (including offline / error cases - read
the "ok" and "online" fields), 2 on usage error.

Output schema:
  {
    "ok": bool,                       # false = could not determine (see "error")
    "online": bool,                   # false = R2 unreachable
    "error": str|null,
    "db_dir": str,
    "channel": "latest"|"experimental",
    "commec_version": str,
    "blocked_by_commec_version": bool,# some DB is behind but needs a newer commec first
    "update_count": int,              # databases needing a download (excludes blocked)
    "download_bytes": int,            # sum of the pending tarballs
    "required_bytes": int,            # download + estimated extracted size
    "databases": {
      "<name>": {
        "have": str|null,             # null = not installed / no manifest
        "latest": str,
        "status": "up-to-date"|"update"|"missing"|"revert"|"blocked",
        "bytes": int|null             # tarball size, null if unknown/not needed
      }, ...
    }
  }
"""

import argparse
import json
import os
import sys
from urllib import error, request

# Compressed -> extracted growth factor for the DB tarballs, used only to size the
# free-space preflight. Measured on the real artifacts: best_match 6.2 GB -> ~36 GB (5.8x),
# biorisk 0.45 GB -> 2.2 GB (4.9x). 6.0 keeps the estimate on the safe side.
EXTRACT_FACTOR = 6.0

STATUS_UP_TO_DATE = "up-to-date"
STATUS_UPDATE = "update"
STATUS_MISSING = "missing"
STATUS_REVERT = "revert"
STATUS_BLOCKED = "blocked"


def emit(payload, code=0):
    json.dump(payload, sys.stdout)
    sys.stdout.write("\n")
    sys.exit(code)


def head_size(url, timeout=10):
    """Content-Length of an object, or None. Never raises."""
    req = request.Request(url, method="HEAD", headers={"User-Agent": "commec-box"})
    try:
        with request.urlopen(req, timeout=timeout) as response:
            return int(response.headers.get("Content-Length") or 0) or None
    except (error.URLError, error.HTTPError, ValueError, OSError):
        return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db-dir", required=True,
                        help="Database parent directory (as passed to `commec setup -d`).")
    parser.add_argument("--base-url", default=None,
                        help="R2 base URL. Defaults to commec's own R2_PUBLIC_BASE_URL.")
    parser.add_argument("--channel", default="latest", choices=("latest", "experimental"),
                        help="Which key of latest.json to read.")
    parser.add_argument("--no-sizes", action="store_true",
                        help="Skip the HEAD requests that size pending downloads.")
    parser.add_argument("--revisions", default=None,
                        help='Target these revisions instead of latest.json, as json '
                             '{"<db>": "<rev>"}. Used for rollback, where the target comes '
                             "from release.json rather than from what is newest.")
    args = parser.parse_args()

    base = {
        "ok": False, "online": False, "error": None,
        "db_dir": args.db_dir, "channel": args.channel, "commec_version": None,
        "blocked_by_commec_version": False, "update_count": 0,
        "download_bytes": 0, "required_bytes": 0, "databases": {},
    }

    # Import inside main so an unusable env reports as a clean json error rather than a
    # traceback on stderr that the shell caller would have to interpret.
    try:
        from commec import __version__ as commec_version
        from commec.setup import (
            R2_PUBLIC_BASE_URL,
            CommecDatabaseUpdater,
            fetch_latest_revisions,
            fetch_supported_revisions,
            DatabaseRevision,
        )
    except Exception as exc:  # noqa: BLE001 - any import failure is "cannot determine"
        base["error"] = f"cannot import commec.setup: {exc}"
        emit(base)

    base["commec_version"] = commec_version
    base_url = (args.base_url or R2_PUBLIC_BASE_URL).rstrip("/")

    if args.revisions:
        # Explicit targets (rollback): no manifest to fetch, but R2 must still be reachable
        # for the downloads that follow, which the size HEADs below will establish.
        try:
            revisions = json.loads(args.revisions)
        except ValueError as exc:
            base["error"] = f"--revisions is not valid json: {exc}"
            emit(base, 2)
        if not isinstance(revisions, dict) or not revisions:
            base["error"] = "--revisions must be a non-empty json object"
            emit(base, 2)
    else:
        # fetch_latest_revisions() returns None when R2 is unreachable OR when the manifest is
        # unparseable; either way we cannot say anything about updates, so report offline.
        try:
            latest = fetch_latest_revisions()
        except Exception as exc:  # noqa: BLE001 - upstream raises bare urllib errors here
            latest = None
            base["error"] = f"fetching latest.json: {exc}"
        if not latest:
            base["error"] = base["error"] or "could not fetch latest.json"
            emit(base)

        revisions = latest.get(args.channel)
        if not revisions:
            base["online"] = True
            base["error"] = f"latest.json has no '{args.channel}' section"
            emit(base)

    try:
        supported = fetch_supported_revisions()
    except Exception as exc:  # noqa: BLE001
        base["online"] = True
        base["error"] = f"reading database_compatibility.yaml: {exc}"
        emit(base)

    base["online"] = True
    download_bytes = 0
    update_count = 0

    for name, wanted in sorted(revisions.items()):
        updater = CommecDatabaseUpdater(os.path.join(args.db_dir, name))
        updater.name = name

        try:
            requested = DatabaseRevision(wanted)
        except ValueError:
            base["databases"][name] = {
                "have": None, "latest": str(wanted), "status": STATUS_BLOCKED, "bytes": None,
            }
            continue

        have = updater.existing_revision
        have_str = None if (have is None or have.invalid()) else str(have)

        # The package's supported range wins: upstream refuses (and we must not attempt) a
        # revision at or beyond this commec's ceiling. Mirrors CommecDatabaseUpdater
        # .check_for_update(), which reports update_required=False in exactly this case -
        # indistinguishable from "up to date" without repeating the comparison here.
        _min_rev, max_rev = supported.get(name, (None, None))
        if max_rev is not None and requested >= max_rev:
            status = STATUS_BLOCKED
            base["blocked_by_commec_version"] = True
        elif have_str is None:
            status = STATUS_MISSING
        elif have < requested:
            status = STATUS_UPDATE
        elif have > requested:
            status = STATUS_REVERT
        else:
            status = STATUS_UP_TO_DATE

        size = None
        if status in (STATUS_UPDATE, STATUS_MISSING, STATUS_REVERT):
            update_count += 1
            if not args.no_sizes:
                size = head_size(f"{base_url}/{name}/{requested}/{name}.tar.zst")
                if size:
                    download_bytes += size

        base["databases"][name] = {
            "have": have_str, "latest": str(requested), "status": status, "bytes": size,
        }

    base["ok"] = True
    base["update_count"] = update_count
    base["download_bytes"] = download_bytes
    # Peak requirement: the tarball plus what it expands to. commec-db-apply adds its own
    # margin on top and compares against real free space.
    base["required_bytes"] = int(download_bytes * (1.0 + EXTRACT_FACTOR))
    emit(base)


if __name__ == "__main__":
    main()
