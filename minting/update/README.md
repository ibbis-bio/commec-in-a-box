# commec update system

An appliance update system that piggybacks on conda: a headless poller keeps an online/offline +
update-available status for the conky overlay, a desktop icon lets the operator check and install
on demand, and installs are A/B (new env built alongside, switched in only after a smoke test, old
env kept for instant rollback).

## Pieces

- `commec-update-check` (`/usr/local/bin`, runs as the user) - probes reachability, `conda
  search`es the configured channels, writes one token to `$XDG_RUNTIME_DIR/commec-update.status`:
  `up-to-date` | `available:<ver>` | `offline`.
- `commec-update-poll.sh` (`/usr/local/bin`, autostarted) - headless loop that periodically runs
  the check (`poll_interval`, default 10 min) so the status file stays fresh for the conky overlay.
  No dialogs.
- `commec-update-nm-dispatcher` (`/etc/NetworkManager/dispatcher.d/90-commec-update`) - re-runs the
  check the moment connectivity comes up (NM `up`/`connectivity-change`), so a post-boot wifi connect
  reflects in conky immediately instead of waiting for the next poll. Runs the check as the GUI user,
  detached + debounced.
- `commec-update-now.sh` (`/usr/local/bin`, the "Check for Commec Updates" desktop icon) - runs the
  check on demand and always shows a result: offline notice / "up to date" / an Install prompt that,
  on Install, calls the apply helper with a pulsating progress dialog. Dialogs are `--on-top
  --sticky` and re-raised via `wmctrl -b add,above` so they sit over fullscreen apps.
- `commec-patch-config` (`/usr/local/sbin`) - patches a given env's `screen-default-config.yaml`
  (DB paths + `blast_mt_mode=0`) using that env's own python. Called at mint (`30-commec-setup.sh`)
  and by `commec-update-apply` after each `conda create`, so a freshly-built env is configured
  identically to the mint env (without it, an updated env ships commec's pristine config and
  screening breaks after the flip).
- `commec-update-apply` (`/usr/local/sbin`, root via NOPASSWD) - `conda create -p
  /opt/miniconda/envs/commec-env-<ver> commec=<ver>`, patch the new env's config, smoke-test
  (`commec --version`), flip the `/opt/commec/current-env` symlink, write
  `/etc/commec-box/release.json`, restart `commec-gui.service`. `--rollback` flips back to the
  recorded `prev_env` (and also restarts the GUI).
- `update.conf` -> `/etc/commec-box/update.conf` - channel, conda channels, probe URL, poll timing,
  `db_dir` (passed to `commec-patch-config`).
- Installed + wired by `packer/provision/47-update-system.sh` (`commec-patch-config` by
  `30-commec-setup.sh`).

## A/B env model

`20-commec.sh` still builds `commec-env`. `47-` adds `/opt/commec/current-env -> commec-env` and
repoints the shell's `conda activate` at that symlink. Updates create `commec-env-<ver>` and flip
the symlink; new shells pick it up immediately, and the previous env stays for rollback.

## Consent / privilege

Any GUI user (the autologin `commec-user`) can install - the apply helper has a narrow NOPASSWD
rule in `/etc/sudoers.d/zzz-commec-update`. The `zzz-` prefix is vital: it must sort AFTER
`sudoers.d/commec-user` (first-boot's blanket rule) or sudo's last-match strips the NOPASSWD.

## conky status

The overlay shows an Update line driven by `commec-conky-update` (`minting/assets/`), which reads
the status token the check writes: green `Up to date` / orange `Update <ver> available` / red
`Offline`. The label reflects the actual update state when online, not just connectivity. It does
no network of its own - "can hit conda?" comes from the check's `offline` token, refreshed by the
poller and the NetworkManager dispatcher.

## Waiting on upstream (reproducibility)

Today `apply` does `conda create ... commec=<ver>`, which re-resolves deps against the live
channel - reproducible only at the version level. When upstream publishes a per-release conda
**lockfile**, switch the one `conda create` line to `conda create --file <lock>` (fetched +
sha-verified from the manifest); everything else - smoke-test, flip, record, rollback - is
unchanged. See the note in `commec-update-apply`.
