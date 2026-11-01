# WINSVC.R4X

`WINSVC.R4X` is an independent R4OS service implemented in Zig.

## Package

- Version: see `module.R4MF`
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
fence metadata. Per-surface image revisions wake the existing Desktop activity wait through
the current R4DESK API. The copied private RIG1 snapshot (opcode4752) separates
queued-image/chain changes from consumer bookkeeping; unchanged queries and
ordinary Take/Return operations remain silent. The global producer-wait
revision retains its independent contract.
The existing `test` step covers retries, fence retirement, mailbox/FIFO,
resize and owner cleanup. See `Docs/Desktop/GrafikFenstertransport07937.txt`
in the workspace documentation for the transport contract.

Desktop operations accept a GUI boot shell or a GUI process carrying the
admitted `app.role=desktop_host` declaration (Kernel 0.1.238). A pending close
or ambiguous process status retains the exact existing owner generation;
only confirmed retirement permits rebinding to a restarted Desktop.

Roadmap 0.82.27 qualifies actual GA106 WSI pixel/depth readbacks, regular
Desktop window/fullscreen/resize/occlusion, source FP16/PQ capture, retained
producer fences beyond Deviceclose, full Desktop restart with surviving GUI,
and real MMU/FLR followed by fresh same-GUI pixels and exact warm retirement.
Headless windows explicitly use an all-zero output and portable system BOs;
the native producer's DeviceExecution fence keeps its actual GPU identity.
Old contract layouts and slots remain unchanged. Active TV/output integration
and manual variants stay in0.82.37/38. Evidence: GrafikVulkan07937.txt/.json
in Docs. Existing failed results and original software/model limits remain.

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

## Explicit Desktop diagnostic work

The current Desktop and Spectra also share
`../../Apps/Desktop/Contract/desktop_check_v2.zig`. This owner byte contract
is a source dependency of the workspace build. WINSVC queues one copied,
authenticated request and returns it in the existing Desktop tray exchange.
Exact caller/Desktop/broker generations, a ticket and a two-second transport
deadline reject stale work and late completion. Operation4500 stays passive.
The current v2 response is144 bytes; its appended counters retain their
actual64-bit values. The explicit maximize action and committed-frame bit
support Spectra's retained subsystem controller without a second scene owner.
No app registers a service endpoint and no additional polling loop is used.
The existing `desktop-test` step includes the bounded broker queue model.
Explicit benchmark sessions may declare up to300 seconds; each copied IPC
job still expires after at most two seconds. Desktop keeps the ordinary
CHECK limit at60 seconds and enforces the purpose of its exact reservation.
Prepared SNES geometry is bound through the same existing own-GUI operation;
the service never creates a child or transports a foreign process pointer.

## Restartable Desktop evidence handoff (0.88.97)

WINSVC29 owns a bounded16slot evidence broker over Contract67 service messages
4784..4790. It retains only while the existing early launch reference protects
the same process. Reserve has no kernel reference; Offer creates a separate
creator-bound WINSVC observation. Waiting offers promote before Desktop ACK.
ACK makes the saved canonical token durable until Release or service end;
unacknowledged reservations/offers expire after300000ms. Status never creates
references or applications. Lost launch history remains Unknown/Unavailable.

The192bit incarnation comes from the existing SDK actual-entropy provider.
R4DEV is a required manifest import for its hardware source. Missing entropy
makes Scope unavailable without blocking ordinary legacy launches. Raw kernel
binding IDs are never exported; external observers acquire no reap rights.
The original Completion128 and output flags are copied without normalization.

Normal Kernel452/SMP4/Desktop197/DESKRUN3 and source SDK126/Contract67 qualify
C/Rust/Zig consumers, saved-token recovery, two independent references,
17launch history pressure, real expiry and actual last-record/orphan cleanup.
A fresh boot repeats all numeric identities; only the service epoch differs
and rejects the old token. See Docs/Desktop/DeskRun.txt in workspace Docs.
Existing launch-test includes four focused broker cases and14launch cases;
no new periodic probe or workspace test gate is introduced. Source qualification
does not publish SDK/Full packages or qualify an external Studio application.

## Delegated WM actions (0.88.98)

WINSVC31 uses Contract68 fixed service messages4800..4807. Six records:
Token144, State168, Request192, Reply544, DesktopExchange640, CombinedReply640.
Sixteen copied grants bind the original launch requester, named live full
controller, exact child/window/Desktop/service and fresh192-bit epoch.
The original caller grants; only the named controller mutates. Read-only
status never creates an action. Unbound admission uses the original launch
deadline. The legacy launch receipt is slot+1; `windowIdFromLaunchReceipt`
maps1..4 to native GUI0..3 and zero to unavailable. Direct copying caused
the preserved first native failure; the existing owner case now covers it.

The real Desktop applies WM policy and retains one immutable original ACK.
Late offered timeouts stay Unknown until reconciled; no blind replacement
action. The applied snapshot/tick and separately current view remain distinct.
App paint ACKs are only candidates. Desktop CPU composition or the exact GPU
captured-frame completion provides visual proof; minimize proves invisibility
without inventing an app frame. The640-byte envelope replaces the existing
mode RPC one-for-one. No kernel ABI slot or additional permanent poll.

Existing launch-test/test contain14launch +4evidence +4action owner cases.
Normal452/SMP4/Desktop198/DESKRUN4 and sourceSDK127/Contract68/Lib40 qualify
all actions, clamp, saved-token C/Rust/Zig, QMP actual pixels/physical input,
normal close and separate actual GUI-slot reuse. Private trace copies are
diagnostic-only; clean native artifacts contain none of that instrumentation.
Full contracts/evidence: workspace Docs/Desktop/DeskRun.txt.
