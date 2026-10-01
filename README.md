# WINSVC.R4X

`WINSVC.R4X` is an independent R4OS service implemented in Zig.

## Package

- Version: `0.1.11`
- Image target: `/R4OS/SERVICES/WINSVC.R4X`
- Image scope: `slim`
- Canonical project manifest: `module.R4MF`

The manifest is the single source of truth for the artifact, imports, image
target, and package metadata.

The common GPU-window broker imports bounded canonical BO references and
transports generation-bound producer/consumer leases through WINSVC. It
does not map pixels, wait on the GPU, or implement composition/color/output
policy. Desktop and Vulkan WSI use this transport for GPU-backed windows.
Consumers receive an explicit acknowledgement before releasing borrowed
fence metadata. Changed graphics revisions wake the existing Desktop activity
wait through the optional R4DESK tail; unchanged queries remain silent.
The existing `test` step covers retries, fence retirement, mailbox/FIFO,
resize and owner cleanup. See `Docs/Desktop/GrafikFenstertransport07937.txt`
in the workspace documentation for the transport contract.

Desktop operations accept a GUI boot shell or a GUI process carrying the
admitted `app.role=desktop_host` declaration (Kernel 0.1.238). A pending close
or ambiguous process status retains the exact existing owner generation;
only confirmed retirement permits rebinding to a restarted Desktop.

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
