# wrap/ - Clonezilla deployment-stick wrapping

Turns the built master image (`commec-box.qcow2`) into a bootable **deployment stick**
that restores it onto a target box's internal disk.

All scripts are **parameterized via env vars** (no hardcoded paths) so they run the same
on a workstation and a future CI runner. Config + shared helpers live in `lib.sh`.

## Pipeline

```
save.sh         master qcow2  ->  Clonezilla image (in CZ_REPO_IMG:/partimag/<IMAGE_NAME>)
build-stick.sh  Clonezilla image  ->  bootable deployment-stick disk image
test-restore.sh restore the image onto a blank disk (VM validation of the restore path)
flash-stick.sh  deployment-stick image  ->  verified physical USB with a valid backup GPT
```

## Key env vars (see lib.sh for all + defaults)

| Var | Default | Meaning |
|-----|---------|---------|
| `MASTER_IMAGE` | `$WORK_DIR/commec-box.qcow2` | input master image to wrap |
| `WORK_DIR` | `<repo>/minting/_work` | scratch/artifacts dir |
| `CZ_REPO_IMG` | `$WORK_DIR/clz-repo.qcow2` | qcow2 holding the Clonezilla image |
| `IMAGE_NAME` | `commec-v1` | Clonezilla image name |
| `CZ_ISO` | from `pins.json` (fetched+verified) | Clonezilla Live ISO |
| `STICK_IMG` | `$WORK_DIR/commec-deploy-stick.img` | output deployment image |
| `STICK_SIZE` | `24G` | deployment image size; must exceed the baked payload and fit the physical USB |
| `COMMEC_FLASH_CONFIRM` | unset | exact resolved target device for non-interactive flashing |
| `COMMEC_FLASH_ALLOW_FIXED` | `0` | permit non-USB/non-removable media; reserved for VM/test use |
| `QEMU_ACCEL` | `kvm` | set `tcg` only for KVM-less CI (very slow) |
| `QEMU_MEM_MB` / `QEMU_SMP` | `4096` / `4` | guest resources |

DB source / object storage (R2): the *build* (packer/) takes the DB tarballs; point it at
a URL or local path via its own env (see packer/build.sh). Wrapping here only needs the
already-built `MASTER_IMAGE`.

## Running

```bash
# 1. save the master into a Clonezilla image
MASTER_IMAGE=~/commec-build/commec-box-v1.qcow2 ./save.sh
# 2. (optional) validate the restore path onto a blank 512 GB disk
./test-restore.sh
# 3. bake the deployment stick
./build-stick.sh
# 4. flash, read back, repair the backup GPT for the physical media, and validate
./flash-stick.sh /dev/sdX
```

## Notes

- `save.sh` and `test-restore.sh` run qemu in the **foreground** (block until the guest
  powers off) - correct for CI and normal use. The wrapping/flashing scripts use `sudo`
  for block-device, filesystem, and partition-table operations.
- Clonezilla unattended gotchas are encoded in `lib.sh`: `locales=`/`keyboard-layouts=`
  must be non-empty (else it stops on the language menu); `ocs_live_run` runs on tty1, so
  watch progress via disk growth / QMP screenshots, not serial; restore must NOT use `-k`
  on a blank target.
- **This dev sandbox only:** the harness reaps backgrounded qemu, so launch via
  `sudo systemd-run --unit=NAME --collect --working-directory=$PWD bash ./save.sh` and poll
  the unit. That wrapper is NOT part of the scripts - a normal runner needs no such thing.
- CI/CD is a future plan; these scripts are structured for it but not wired to any CI yet.
- `build-stick.sh` is authored from the proven save/restore params but has not yet been
  test-booted end to end.
- A raw whole-disk image carries its backup GPT at the image boundary. `flash-stick.sh`
  relocates that backup to the physical end when the USB is larger than `STICK_IMG`, then
  validates the final GPT and FAT filesystem. Do not replace it with a bare `dd` command.
