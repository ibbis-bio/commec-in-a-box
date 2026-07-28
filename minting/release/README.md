# Release image packaging

`package-image.sh` compresses the wrapped deployment image with zstd and splits the
archive into numbered files smaller than GitHub's 2 GiB per-asset limit. The output
also contains checksums for every part and the reconstructed archive.

```bash
./package-image.sh ../_work/commec-deploy-stick.img
```

Download all release assets into one directory and reconstruct the archive with:

```bash
chmod +x reassemble-image.sh
./reassemble-image.sh
```

The helper verifies each downloaded part before joining them, verifies the completed
archive, and refuses to overwrite an existing archive.
