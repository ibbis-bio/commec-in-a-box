# commec update system

A GUI update notifier for the appliance that piggybacks on conda: it checks a channel for a
newer `commec`, prompts over fullscreen, and installs A/B (new env built alongside, switched in
only after a smoke test, old env kept for instant rollback).

## Pieces

- `commec-update-check` (`/usr/local/bin`, runs as the user) - probes reachability, `conda
  search`es the configured channels, writes one token to `$XDG_RUNTIME_DIR/commec-update.status`:
  `up-to-date` | `available:<ver>` | `offline`.
- `commec-update-popup.sh` (`/usr/local/bin`, autostarted) - poll loop + dialogs. Offline notice
  is one-and-done per boot (flag on tmpfs); an available update prompts Install/Later and, on
  Install, calls the apply helper with a pulsating progress dialog. Dialogs are `--on-top
  --sticky` and re-raised via `wmctrl -b add,above` so they sit over fullscreen apps.
- `commec-update-apply` (`/usr/local/sbin`, root via NOPASSWD) - `conda create -p
  /opt/miniconda/envs/commec-env-<ver> commec=<ver>`, smoke-test (`commec --version`), flip the
  `/opt/commec/current-env` symlink, write `/etc/commec-box/release.json`. `--rollback` flips back
  to the recorded `prev_env`.
- `update.conf` -> `/etc/commec-box/update.conf` - channel, conda channels, probe URL, poll timing.
- Installed + wired by `packer/provision/47-update-system.sh`.

## A/B env model

`20-commec.sh` still builds `commec-env`. `47-` adds `/opt/commec/current-env -> commec-env` and
repoints the shell's `conda activate` at that symlink. Updates create `commec-env-<ver>` and flip
the symlink; new shells pick it up immediately, and the previous env stays for rollback.

## Consent / privilege

Any GUI user (the autologin `commec-user`) can install - the apply helper has a narrow NOPASSWD
rule in `/etc/sudoers.d/zzz-commec-update`. The `zzz-` prefix is load-bearing: it must sort AFTER
`sudoers.d/commec-user` (first-boot's blanket rule) or sudo's last-match strips the NOPASSWD.

## Testing without minting (devel channel off rose)

1. On rose: `./commec-devbuild.sh 1.0.6.dev1` - builds the gui branch as a dev conda package into
   a local channel and serves it over HTTP on the tailnet. Release-safe (all local; never pushes,
   tags, or dispatches CI).
2. On the box, point `/etc/commec-box/update.conf` at it:
   ```
   channel=devel
   conda_channels=http://<rose-tailnet>:8000,conda-forge,bioconda
   probe_url=http://<rose-tailnet>:8000/noarch/repodata.json
   ```
3. The notifier prompts for `1.0.6.dev1`. Click Install -> A/B build -> flip. Verify `commec
   --version` in a new terminal. Roll back: `sudo commec-update-apply --rollback`.
4. Re-trigger: `./commec-devbuild.sh 1.0.6.dev2` (monotonic `.devN`), poll again.

Use a `.devN`/date-monotonic version that sorts ABOVE the box's version. Avoid negative/sentinel
versions - conda/PEP440 ordering treats a plain `.devN` as pre-release and monotonic dev builds as
newer, which is exactly the "always a bit ahead" behaviour you want.

## conky status (optional)

The status file is world-readable in the user runtime dir. Add to `~/.config/conky/conky.conf`
(inside the `${...}` text block):
```
commec: ${execi 60 cat $XDG_RUNTIME_DIR/commec-update.status 2>/dev/null || echo unknown}
```

## Waiting on upstream (reproducibility)

Today `apply` does `conda create ... commec=<ver>`, which re-resolves deps against the live
channel - reproducible only at the version level. When upstream publishes a per-release conda
**lockfile**, switch the one `conda create` line to `conda create --file <lock>` (fetched +
sha-verified from the manifest); everything else - smoke-test, flip, record, rollback - is
unchanged. See the note in `commec-update-apply`.
