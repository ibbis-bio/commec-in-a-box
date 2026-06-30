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
  everyboot/          boots to XFCE desktop (wallpaper + conky); future: commec-gui
  wrap/               Clonezilla unattended deployment-USB builder
  downloads/          fetched inputs (gitignored)
```

## Inputs / pins (see pins.json)

- Debian 13 genericcloud qcow2, build 20260615-2510
- Miniconda py312_26.3.2-2
- commec 1.0.5 (bioconda) + a build-time conda lockfile
- commec-databases v1.1.0 (biorisk + low_concern, ~313 MB)
- main BLAST DBs (staged): nr.tar (BLAST nr) + core_nt.tar (BLAST core_nt),
  ~82 GB compressed / ~298 GB decompressed. Working copies on the COMMEC
  external at /mnt/commec/dbs-staging.
- Packer 1.15.4
- Clonezilla (TBD)

## DB layout commec expects (target, base_paths.default)

```
<db>/biorisk/...            from commec-dbs.zip
<db>/low_concern/...        from commec-dbs.zip
<db>/nr_blast/nr            from nr.tar         (BLAST protein; default protein_search_tool=blastx)
<db>/nt_blast/core_nt       from core_nt.tar    (BLAST nucleotide)
<db>/taxonomy/              NCBI taxdump
<db>/nr_dmnd/nr.dmnd        NOT provided (optional DIAMOND protein path)
```

## Pipeline phases

1. **Build** (`packer/`): boot Debian cloud image, provision conda+commec, fetch
   small DBs, stage compressed main DBs into the image (NOT decompressed -> keeps
   the master small enough for the 128 GB stick). Output: qcow2 master.
2. **First boot** (`firstboot/`): force password, lock root, grow partition to fill
   the real 512 GB disk, then stream-decompress the DBs, set the done-flag, disable.
3. **Every boot** (`everyboot/`): placeholder terminal (future commec-gui).
4. **Wrap** (`wrap/`): Clonezilla unattended restore image -> bootable 128 GB stick.
5. **Test**: VM (qemu, blank 512 GB disk) then metal (ThinkCentre M75q Gen 2).

## Host (mintbox) prerequisites

- KVM access: user in `kvm` group.
- Packages: `qemu-system-x86 qemu-utils ovmf xorriso cloud-image-utils mtools dosfstools gdisk`.
- Packer binary (pinned, fetched into a local bin; not in Debian repos).
