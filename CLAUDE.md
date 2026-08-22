# messaging_middlewear

NATS Core performance verification environment. See README.md for setup/usage.

## Conventions

- **NATS Core only.** `docker-compose.yml` must not gain `-js` (JetStream) — that's a
  separate concern from what this project benchmarks. If JetStream testing is ever added,
  do it as an additional service/profile, not a flag change to the existing `nats` service.
- **Single node only.** No cluster port (6222) is published; no multi-node scenarios.
- **Native Bash (`.sh`) is the scripting language** for this project, targeting a real
  Linux host directly (see README.md's "実機Linuxで実行する"). This replaced an earlier
  PowerShell (`.ps1`) implementation — see "Why Bash, not PowerShell" below for what
  motivated the rewrite and which PowerShell-specific pitfalls it structurally eliminates.
- **Every benchmark run writes to a fresh timestamped folder** under `results/<category>/`
  via `new_run_dir` in `scripts/common.sh` — never overwrite a prior run's output.
  Timestamps use `date +%Y%m%d-%H%M%S` (no colons — kept from the original Windows
  filename constraint, harmless on Linux too).
- **`nats bench --csv` output has a `#`-prefixed header line** (e.g. `#RunID,ClientID,MsgCount,...`).
  Any parsing of this CSV must skip that line (`tail -n +2`) before processing — see
  `parse_nats_bench_csv_aggregate` in `scripts/common.sh` for the pattern.
- **`nats bench` is subcommand-based** (`nats bench pub|sub|service serve|service request`),
  not a flat `--pub/--sub` command. Flags drift between CLI releases — check
  `nats bench <subcommand> --help` before assuming a flag exists.
- **`jq` is a hard prerequisite** for all JSON handling (`meta.json`/`result.json`
  construction, `scenarios.json` parsing) — chosen over hand-built JSON strings for
  correctness/escaping safety. Any real Linux target installs it via `apt`/`yum`.
- See `TODO.md` for the active backlog and priority order of follow-up work.
- All `bench-*.sh` scripts accept `--label` for consistency — `scripts/scenarios.json`-driven
  runs depend on this to name result folders after the scenario instead of each script's
  internal default.
- **`msg_loss` must be computed from the requested parameter value (`$MSGS`/`$total_msgs`),
  never from `nats bench pub`'s own reported total.** If pub fails outright (confirmed:
  unthrottled bursts above ~10-25 concurrent clients hit `flushing: nats: timeout` on the
  Windows/Docker Desktop environment this was first measured on), pub.csv is empty, its
  reported total is 0, and using that as "expected" makes msg_loss silently read 0 even
  though nothing was delivered. Always check `nats bench pub`'s exit code too and
  propagate failure (non-zero script exit) - don't let the script report success just
  because it reached the end of its statements.
- **`nats bench sub` does not accept `--multisubjectmax`** (pub-only flag). When building
  `--multisubject` argument lists, always split them into separate pub-args/sub-args sets
  (sub gets `--multisubject` alone) — passing pub's full multisubject args to sub makes it
  print a usage error and exit, so the subscription never registers and every message is
  silently lost. This bug existed in an earlier version of `bench-scalability.ps1` (the
  predecessor to today's `bench-scalability.sh`); fixed there and avoided from the start
  in `bench-throughput.sh`.
- **Rate limiting**: `convert_to_nats_sleep_duration` in `common.sh` converts a target
  aggregate msgs/sec into the per-client `--sleep=DURATION` `nats bench pub` expects
  (`nats bench` has no direct `--rate` flag). Reuse this helper rather than recomputing
  the conversion in each script.
- **Result reporting**: every `bench-*.sh` script calls `save_result` (in `common.sh`)
  in addition to `save_meta` — `save_meta` is reproducibility info (tool/server versions),
  `save_result` is the parsed metrics (`result.json` per run + one row appended to
  `results/run-index.csv`, the cross-category summary table). Use
  `parse_nats_bench_csv_aggregate` (strips the `#`-prefixed header, sums multi-client CSV
  rows using MAX duration across rows since clients run concurrently) to build the
  metrics from `nats bench --csv` output rather than re-deriving this per script.
  `msg_loss` is computed as `pub total * SubClients - sub total` because each independent
  subscriber client receives a full copy of the published stream (fan-out, not a work
  queue — confirmed empirically), not `pub total - sub total`.
- **One-way latency uses a custom C++ tool, not the `nats` CLI.** `bench-latency.sh`
  (`nats bench service serve/request`) measures round-trip time only. True publisher→
  subscriber one-way latency is `tools/latency_oneway/` (C++), driven by
  `scripts/bench-latency-oneway.sh`, built inside `docker/latency-tool/Dockerfile`.
  **This tool's language/runtime is fixed to CentOS 7 / gcc 11 / C++17 to match
  production** — do not port it to Python or another language, even for convenience;
  a non-native client's own overhead (GC, interpreter, event-loop scheduling) would get
  measured as if it were NATS latency (see `TODO.md` #4 for the full reasoning).
  `nats.c`'s CMake package exports as `cnats` (not `NATS` as its README implies) —
  `find_package(cnats REQUIRED)`, target `cnats::nats_static`, and `find_package(Threads
  REQUIRED)` must run first or CMake fails to resolve `cnats`'s link interface.
- **`latency_oneway` has no unthrottled-burst mode at all — `--rate` (msgs/sec) and
  `--duration-sec` are both required; `--msgs` does not exist as a CLI flag.** Total
  message count is derived (`round(rate * duration)`), never settable directly. This was
  a deliberate redesign, not the original interface: an earlier version took `--msgs`
  directly with an optional `--rate` that defaulted to 0 ("unthrottled"), and unthrottled
  bursts measured queueing delay building up in the subscriber, not NATS's actual
  steady-state one-way latency (confirmed by measurement: ~2.3ms at msg 0 climbing to
  ~5.3ms by msg 999 in one 1000-msg unthrottled run). `bench-latency-oneway.sh` and
  `bench-crosshost.sh` (its `--tool latency-oneway` mode) match this —
  `--target-msgs-per-sec`/`--duration-sec`, not `--msgs`. `bench-crosshost.sh`'s
  `--tool nats-bench` mode is unaffected and keeps `--msgs`/unthrottled-by-default
  semantics, since a burst/saturation throughput test IS a meaningful thing to measure —
  only the one-way *latency* tool's burst mode was meaningless, not throughput testing
  in general.
- **`docker/latency-tool` is a general "host client" image, not just the one-way latency
  tool.** It bundles both `latency_oneway` and the `nats` CLI, and its `ENTRYPOINT` is a
  generic wrapper (`entrypoint.sh`) — callers must name the binary explicitly (e.g.
  `docker compose run --rm latency-tool latency_oneway --mode both ...` or
  `... latency-tool nats bench pub ...`), it no longer defaults to `latency_oneway`.
  `latency_oneway --mode pub`/`--mode sub` (added for TODO.md #3) let publisher and
  subscriber run in separate containers/processes; `--mode both` (same-host, single
  process) is unchanged and still the default.
- **`tc netem` does not work on Docker Desktop for Windows** — the bundled WSL2/Hyper-V
  kernel lacks the `sch_netem` module (confirmed: plain `tc qdisc add ... pfifo`
  succeeds, `... netem` fails with `RTNETLINK answers: No such file or directory`,
  regardless of `cap_add: NET_ADMIN`). This is a host-kernel limitation, not fixable from
  inside a container — expected to work on a real Linux Docker host (see README.md).
  `entrypoint.sh`'s netem injection is therefore non-fatal on failure (warns and
  continues) — do not make it `set -e`-fatal, and don't assume `--netem-delay-ms`
  actually did anything without checking for that warning in the output.
- **Never retrieve `docker/latency-tool` results via a `-v <local>:/out` bind mount —
  always use `docker_run_and_copy_out` (`common.sh`), which uses `docker cp` instead.**
  A bind-mount path is resolved by the *Docker daemon*, not by whoever runs the `docker`
  command, so it silently returns nothing the moment `docker` points at a remote host via
  `docker context` (e.g. SSH to a Linux box from a different driver machine — see
  README.md). `docker cp` works identically for local and remote daemons. Because a bind
  mount used to be what created `/out` automatically, `docker/latency-tool/entrypoint.sh`
  now does `mkdir -p /out` itself — don't remove that, `latency_oneway`'s
  `std::ofstream` writes fail silently (no exception) if the directory doesn't exist, so
  the tool prints a normal-looking summary to stdout while quietly writing no
  `result.json`/`oneway.csv` at all.
- **Every path in this project uses `/`, never `\`** — this is native Linux Bash, so
  there's no Windows-path concern to design around in the first place (unlike the
  PowerShell predecessor, which needed a deliberate pass for this).

## Why Bash, not PowerShell

This project was originally written in PowerShell (`.ps1`), matching the primary shell
on the machine it was first developed on. Once the actual verification target became "a
real Linux server reachable via SSH" rather than the Windows/Docker Desktop dev machine,
it became clear the scripts themselves should just be native Bash rather than PowerShell
Core (`pwsh`) running on Linux — simpler toolchain, no cross-platform PowerShell
dependency to install on the target, and idiomatic for the actual runtime.

This rewrite turned out to *simplify* the implementation, not just translate syntax —
several PowerShell-specific problems fought hard in the original version don't exist
structurally in Bash:

- **`Start-Job` ran script blocks in a separate runspace**, inheriting neither the
  caller's working directory (`Push-Location`) nor its function definitions — every
  backgrounded subscriber needed explicit `Set-Location`/re-dot-sourcing workarounds.
  Bash's `&` backgrounding runs in the *same* shell, inheriting both naturally.
- **A child script's `exit` terminated the entire PowerShell host process**, not just
  that script's scope, when invoked in-process (`& script.ps1`) — the orchestrator
  (`run-all-benchmarks.ps1`) needed an `Invoke-ScriptIsolated` helper that spawned a real
  child `powershell.exe` process just to contain this. In Bash, `bash script.sh` is
  already a genuine child process — `exit` inside it only ever ends that child.
- **Native command stdout leaking into a function's `return` value** — an uncaptured
  native process's output inside a PowerShell function that also `return`s a value gets
  bundled into that return value as an array at the call site, corrupting exit-code
  checks. This bit the project twice (`Invoke-ScriptIsolated`, then again in
  `Invoke-DockerRunAndCopyOut`). Bash functions have no equivalent hazard — `return` sets
  only a numeric exit status, output and return value are never conflated.
- **`-ConnectionCounts 1,10,50` array parameters got corrupted crossing a process
  boundary** (`-File` invocation) — .NET's numeric conversion silently read the comma as
  a thousands separator, turning `1,5` into `15`. Bash just passes the comma-separated
  string through as one token (`"1,5,10,25"`), split manually via
  `IFS=',' read -ra COUNTS <<< "$value"` — no implicit type coercion to fight.
- **`$ErrorActionPreference = "Stop"` plus a Windows-only cmdlet not resolving** (e.g.
  `Get-NetTCPConnection` under PowerShell Core on Linux) needed an explicit
  `Get-Command ... -ErrorAction SilentlyContinue` guard, since a *missing* cmdlet's
  resolution failure wasn't suppressed the same way a *failing* cmdlet's would be. `set
  -e` in Bash has no equivalent asymmetry.

None of this means Bash is bug-free in general — just that this specific, recurring
class of friction (separate-runspace semantics, in-process `exit` propagation, stdout/
return-value conflation, cross-process array marshalling) doesn't apply to a plain Bash
script calling another plain Bash script as a real child process. See `TODO.md`'s
addenda under #3 for the full migration writeup, including a Windows-Git-Bash-specific
`docker` argument path-mangling issue found *during* verification of the rewritten
scripts (documented in README.md's "Testing on Windows" section) — unrelated to the
PowerShell-vs-Bash choice itself, since it's a Git-Bash/MSYS artifact that doesn't occur
on the real Linux target either way.
