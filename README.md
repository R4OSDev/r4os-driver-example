# EXAMPLE.R4D

`EXAMPLE.R4D` is an independent R4OS driver implemented in Zig. It
deliberately keeps its storage fixture on the synchronous depth-one adapter
while exercising the DriverApi v19 pin/map/sync/unmap DMA lifetime.

## Package

- Version: `0.1.9`
- Image target: `/R4OS/DRIVERS/EXAMPLE.R4D`
- Image scope: `test`
- Canonical project manifest: `module.R4MF`

The manifest is the single source of truth for the artifact, imports, image
target, and package metadata.

The test fixture also exercises the complete DriverApi v21 USB-host v2
descriptor, including productive callback capabilities and owner-bound
shutdown during unregister.

On DriverApi34 the same DMA lifetime fixture checks byte-range sync against
the actual retained mapping: first/last bytes, invalid extents and headers,
forged descriptor lengths and stale handles after unmap. Older providers
keep the original whole-mapping fixture. No device DMA engine is submitted;
independent bounce-buffer field preservation is tested by the kernel owner
on the host.

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

On Kernel 0.1.154 the same memory fixture executes its 80-MB/DMA path in
ordinary Work, imports the Init buffer without copying, checks returned and
cached MMIO denial and rejects BO access from a real dedicated Task. Use
`GRAPHICS=AUTO` for its existing immutable boot-image probe. The optional
`OPTION EXAMPLE memory-close=yes` deliberately returns init code -79 after
holding small CPU/DMA/GPU residency leases. The real failed-load Shutdown
then checks closed admission and balanced cached-table cleanup. This is an
explicit test fixture, with no GPU submission or added recurring gate.

`OPTION EXAMPLE mode=gfx-queue-test` selects the DriverApi v26 queue fixture.
It registers a diagnostic adapter (0xFFFF0006), holds real BO leases and
checks page-bounded DMA descriptors without submitting hardware work. Copy
requests receive a deliberately failed completion after three seconds from
the shared timer IRQ. The IRQ checks stale, duplicate and unproven completion;
logging, reset tests and job acquisition run through driver-work callbacks.
DISPLAYD uses the delay to test cancellation, multiple waits and producer
death. The fixture cannot be used as a rendering backend. Unregister proves
quiescence because this fixture has no DMA engine.

`OPTION EXAMPLE mode=gfx-output-test` selects a DriverApi27 virtual connector
(adapter 0xFFFF0007). Queue barriers publish disconnect, an earlier Hisense
65U8QF base block, and a reset/reconnect to the QEMU fixture. Publication is
copied, owner-bound and generation-safe. This exercises the catalog and the
existing desktop activity wake, with no GPU, physical hotplug or HDMI I/O.
The driver uses manifest-declared compiled `r4gfx_edid`/`r4gfx_outputs`
modules; shared PS7 orchestration in SDK/Tools/BuildModule.ps1 builds them
from local Settings.R4S mappings on Windows and Linux.
