# EXAMPLE.R4D

`EXAMPLE.R4D` is an independent R4OS driver implemented in Zig. It
deliberately keeps its storage fixture on the synchronous depth-one adapter
while exercising the DriverApi v19 pin/map/sync/unmap DMA lifetime.

## Package

- Version: `0.1.4`
- Image target: `/R4OS/DRIVERS/EXAMPLE.R4D`
- Image scope: `test`
- Canonical project manifest: `module.R4MF`

The manifest is the single source of truth for the artifact, imports, image
target, and package metadata.

The test fixture also exercises the complete DriverApi v21 USB-host v2
descriptor, including productive callback capabilities and owner-bound
shutdown during unregister.

## Build

On Windows:

    Build.bat

On Linux or macOS:

    ./Build.sh

The build starters resolve the current local R4OS dependency checkouts through
`Settings.R4S`. The URL and hash entries in `build.zig.zon` record the
last verified standalone dependency identities; workspace builds use the
mapped local checkouts.

## Documentation

Detailed German technical notes from the migration are preserved in
`DOCUMENTATION.de.txt`. Source-transfer provenance is recorded in
`PROVENANCE.txt`.

## License

Original R4OS material is licensed under Apache License 2.0. See `LICENSE`
and `NOTICE`. Any repository-specific external material is documented in
`THIRD_PARTY_NOTICES.md`.

`OPTION EXAMPLE mode=gfx-memory-test` selects a bounded DriverApi v25 fixture:
an 80-MB resident BO, 20,480 direct DMA segments, a distinct GPU residency VA,
concurrent CPU maps, rejected forged/incomplete completions and balanced
release. This mode performs no GPU submission and replaces the ordinary
EXAMPLE fixtures for that boot. Native GPU page tables, VRAM and scanout are
outside this memory-contract test.
