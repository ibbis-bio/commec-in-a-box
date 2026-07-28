# commec-in-a-box: minting pipeline

Reproducible pipeline that turns pinned inputs into a bootable **deployment stick**
(USB) which flashes a target box's HDD to Debian preloaded with IBBIS commec +
databases, ready after a guided first boot.


## Layout

```
minting/
  pins.json           pinned inputs (urls + hashes); single source of truth
  packer/             Packer/qemu build of the master image (Debian genericcloud + cloud-init)
    cloud-init/       seed (user-data / meta-data) for the build VM
    provision/        provisioning scripts (apt, miniconda, commec, desktop, db staging)
  assets/             wallpaper image + conky.conf (desktop overlay)
  firstboot/          systemd oneshot: set password, lock root, grow disk, decompress DBs
  wrap/               Clonezilla unattended deployment-USB builder
  release/            compressed, split GitHub release assets + reassembly helper
  downloads/          fetched inputs (gitignored)
```

## Inputs / pins (see pins.json)

- Debian 13 genericcloud qcow2, build 20260615-2510
- Miniconda py312_26.3.2-2
- commec 2.1.0.dev0 candidate from the exact pinned GUI commit, with the runtime
  updater pointed at the production conda-forge + bioconda channels
- commec databases from the stable R2 manifest: biorisk, low_concern,
  control_lists, and best_match
- Packer 1.15.4
- Clonezilla 3.3.2-31

## DB layout commec expects (target, base_paths.default)

```
<db>/biorisk/...
<db>/low_concern/...
<db>/control_lists/...
<db>/best_match/...
```

## Pipeline phases

1. **Build** (`packer/`): boot Debian cloud image, provision conda+commec, fetch
   small DBs, stage compressed main DBs into the image (NOT decompressed -> keeps
   the master small enough for the deployment stick). Output: qcow2 master.
2. **First boot** (`firstboot/`): force password, lock root, grow partition to fill
   the real 512 GB disk, then stream-decompress the DBs, set the done-flag, disable.
3. **Every boot**: XFCE desktop, kiosk GUI, HTTPS certificate export, update status,
   and operator launchers.
4. **Wrap** (`wrap/`): Clonezilla unattended restore image -> 24 GiB bootable
   deployment image for a nominal 32 GB USB drive.
5. **Test**: VM (qemu, blank 512 GB disk) then metal (ThinkCentre M75q Gen 2).
6. **Package** (`release/`): zstd-compressed, checksummed GitHub release assets.

## Hardware power tuning (IMPORTANT - hardware-dependent, set in `provision/00-base.sh`)

The appliance ships three power/stability settings baked into the image. **The clock cap is
tied to the specific CPU + power brick** - re-evaluate it for any other hardware.

| Setting | Default | Flag (build-time env) | Why |
|---|---|---|---|
| CPU governor | `performance` | `CPU_GOVERNOR` | max clocks for screening (amd-pstate-epp: performance/powersave only) |
| **Max-freq CLOCK CAP** | **3.0 GHz** (`3000000` kHz) | **`CPU_MAXFREQ_KHZ`** (`0`/`''` disables) | **65W-brick POWER SAFETY - see below** |
| Never suspend | masked | (none) | a headless screen has no GUI activity -> box would idle-suspend mid-run |

**The clock cap - read before shipping on other hardware:** the ThinkCentre M75q Gen 2 on its
stock **65 W** slim-tip brick is power-marginal. Under sustained all-core load the SoC draws ~58 W
(~89% of the brick), and in testing **both units intermittently hard-power-off** - abrupt, with
**no thermal/MCE/shutdown log and safe temps (~76 C)**, i.e. a power brownout, not heat. Capping
max frequency to 3.0 GHz (~2.64 GHz effective all-core, ~0.72x throughput -> ~61k seq/day, still
~12x over the 5k/day target) pulls peak draw back under the brick's ceiling and prevented the
crashes. **This is specific to this CPU + this 65 W brick.** Alternatives: fit a **90 W brick** and
disable the cap (`CPU_MAXFREQ_KHZ=0`), or raise the ceiling and re-test stability. Full data +
investigation: `aws/box/power-failure-log.md`.

## Host (mintbox) prerequisites

- KVM access: user in `kvm` group.
- Packages: `qemu-system-x86 qemu-utils ovmf xorriso cloud-image-utils mtools dosfstools gdisk`.
- Packer binary (pinned, fetched into a local bin; not in Debian repos).

## HTTPS access from another computer

Each box places its public CA certificate at
`~/Desktop/COMMEC-Box-CA.crt` during graphical login. Copy that file to a
client computer and import it as a trusted root certificate, then open
`https://commec-box`. The desktop copy is refreshed at each login if it is
deleted or modified.

The public certificate is safe to distribute to client computers. The CA
private key remains under the COMMEC user's mkcert data directory and must
never be copied from the box.

## License

This project is MIT-licensed; see the repository [`LICENSE`](../LICENSE). The screening, update, and MITOSIS
desktop icons adapt paths from the MIT-licensed Tabler Icons project. Their upstream copyright,
license, and pinned source revision are recorded in
[`assets/icons/LICENSE.tabler-icons`](assets/icons/LICENSE.tabler-icons).
