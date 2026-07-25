# commec update system

An appliance update system covering the two things that go out of date independently:

- **the commec package**, updated through conda, A/B style (a new env is built alongside the
  running one and switched in only after it smoke-tests, with the old env kept for rollback);
- **the screening databases**, updated through `commec setup` against commec's Cloudflare R2
  bucket, staged-then-swapped (downloaded beside the live databases and moved into place only
  after they verify).

A headless poller keeps an online/update-available status for the conky overlay, and one desktop
icon checks and installs both.

## Ordering

commec first, then databases. A database revision can require a newer commec
(`commec/database_compatibility.yaml` declares the supported revision range, and
`commec setup` refuses a revision beyond it), so after a package update the database check is
re-run against the newly live environment before anything is downloaded. When a database is
behind but its latest revision needs a newer commec than is installed, the check reports it as
`blocked` and the dialog says so rather than silently omitting it.

## Pieces

- `commec-update-check` (`/usr/local/bin`, runs as the user) - probes reachability, `conda
  search`es the configured channels, runs the database check, and writes two files into
  `$XDG_RUNTIME_DIR`: `commec-update.json` (full state: versions, per-database revisions and
  sizes) and `commec-update.status` (one token for cheap readers). Tokens: `up-to-date` |
  `available:sw=<ver>` | `available:db=<n>` | `available:sw=<ver>,db=<n>` | `blocked:<n>` |
  `offline`. `blocked:<n>` means a newer database exists that this commec is too old to accept
  and no commec update is on offer yet: the box is behind and cannot act on it, which must not
  be reported as up to date. The check's own stderr goes to `commec-update-check.log` beside
  those files - a check that fails silently shows up only as a wrong conky label, which is hard
  to diagnose from the desktop.
- `commec-db-status.py` (`/usr/local/lib/commec-box`) - the database half of the check. Run with
  the CURRENT ENV's python (`/opt/commec/current-env/bin/python`), because the supported-revision
  ceiling lives in the installed commec package; imports `commec.setup` and emits json describing
  each database's installed revision, the published revision, a status
  (`up-to-date`/`update`/`missing`/`revert`/`blocked`) and the download size. It is a lib, not a
  PATH tool: nothing should call it with the wrong interpreter.
- `commec-update-poll.sh` (`/usr/local/bin`, autostarted) - headless loop that periodically runs
  the check (`poll_interval`, default 10 min) so the status stays fresh for the conky overlay.
  No dialogs.
- `commec-update-nm-dispatcher` (`/etc/NetworkManager/dispatcher.d/90-commec-update`) - re-runs
  the check the moment connectivity comes up (NM `up`/`connectivity-change`), so a post-boot wifi
  connect reflects in conky immediately instead of waiting for the next poll. Runs the check as
  the GUI user, detached + debounced.
- `commec-update-now.sh` (`/usr/local/bin`, the "Update Commec" desktop icon) - runs
  the check and always shows a result: offline notice / "up to date" / one install prompt listing
  everything pending with sizes. It refuses while a screening run is active. On Install it
  applies the package, re-checks, then applies the databases, showing real download progress.
- `commec-screen-state` (`/usr/local/lib/commec-box`) - shared running-screen probe used by the
  UI and both privileged apply helpers. It combines the GUI's `/status` state with a process
  check so terminal-launched screens are also protected.
- `commec-patch-config` (`/usr/local/sbin`) - patches a given env's `screen-default-config.yaml`
  (DB paths + `blast_mt_mode=0`) using that env's own python. Called at mint
  (`30-commec-setup.sh`) and by `commec-update-apply` after each `conda create`, so a freshly
  built env is configured identically to the mint env (without it, an updated env ships commec's
  pristine config and screening breaks after the flip).
- `commec-update-apply` (`/usr/local/sbin`, root via NOPASSWD) - `conda create -p
  /opt/miniconda/envs/commec-env-<ver> commec=<ver>`, patch the new env's config, smoke-test
  (`commec --version`), flip the `/opt/commec/current-env` symlink, write
  `/etc/commec-box/release.json`, restart `commec-gui.service`. `--rollback` flips back to the
  recorded `prev_env` (and also restarts the GUI). Apply and rollback refuse while a screen is
  running; apply rechecks immediately before activation in case one started during the build.
- `commec-db-apply` (`/usr/local/sbin`, root via NOPASSWD) - the database updater. See below.
- `update.conf` -> `/etc/commec-box/update.conf` - channels, probe URL, poll timing, and the
  `db_*` settings (directory, revision channel, free-space margin, owning user, GUI status URL).
- Installed + wired by `packer/provision/47-update-system.sh` (`commec-patch-config` by
  `30-commec-setup.sh`).

## A/B env model

`20-commec.sh` builds `commec-env`. `47-` adds `/opt/commec/current-env -> commec-env` and
repoints the shell's `conda activate` at it. Updates create `commec-env-<ver>` and flip the
symlink; new shells pick it up immediately, and the previous env stays for rollback.

## How a database update is applied

`commec setup` is not safe to point at the live database directory, so `commec-db-apply` wraps
it:

1. **Preflight.** Refuse if a screen is running, if the databases cannot be reached, or if free
   space is under the download plus its extracted size plus `db_free_margin_gb`.
2. **Stage.** `commec setup -d <db_dir>/.commec-staging`, run as `db_user`. The staging area is
   seeded with the manifests of the databases that are already current, so setup downloads
   exactly the pending set instead of everything.
3. **Verify.** Check each staged manifest and that the tree is non-empty, then delete the
   downloaded `.tar.zst` (setup leaves it behind, which for `best_match` is over 6 GB).
4. **Swap.** Recheck that no screen started during the download, rename the live directory
   aside, move the staged one in, then remove the old copy. Whole-directory renames mean a new
   revision cannot leave stale files behind, and a failure at any earlier point leaves the live
   databases untouched.
5. **Record.** Write the new revisions to `release.json` under `databases`, keeping the outgoing
   set as `databases_previous`, then restart the GUI.

`--rollback` restores `databases_previous` by handing those revisions to `commec setup -r`,
which re-downloads them. Database rollback is therefore forward-work, not a local snapshot: it
needs the network, and it goes through the same preflight and staging as any other update.
`--dry-run` reports what would happen and touches nothing.

The staging-and-swap design exists because `commec setup` leaves its tarballs behind, has no
free-space preflight, and extracts over the existing directory. Those are filed upstream; the
one behaviour that could not be worked around from outside - exiting 0 after a failed download -
was fixed upstream, and `commec-db-apply` depends on it.

## Consent / privilege

Any GUI user (the autologin `commec-user`) can install - both apply helpers have narrow NOPASSWD
rules in `/etc/sudoers.d/zzz-commec-update`. The `zzz-` prefix is vital: it must sort AFTER
`sudoers.d/commec-user` (first-boot's blanket rule) or sudo's last-match strips the NOPASSWD.

## conky status

The overlay shows an Update line driven by `commec-conky-update` (`minting/assets/`), which
reads the status token: green `Up to date` / yellow `<ver> available`, `<n> database(s)
available`, or both / red `Offline`. It does no network of its own - "can we reach the update
services?" comes from the check's `offline` token, refreshed by the poller and the
NetworkManager dispatcher.

## Waiting on upstream (reproducibility)

Today `apply` does `conda create ... commec=<ver>`, which re-resolves deps against the live
channel - reproducible only at the version level. When upstream publishes a per-release conda
**lockfile**, switch the one `conda create` line to `conda create --file <lock>` (fetched +
sha-verified from the manifest); everything else - smoke-test, flip, record, rollback - is
unchanged. See the note in `commec-update-apply`.
