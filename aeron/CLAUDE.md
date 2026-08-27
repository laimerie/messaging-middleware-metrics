# aeron

Aeron performance verification environment. This is one of several messaging middleware
benchmark environments in this repo (see the repo-root `CLAUDE.md` for the overall
structure); everything in this file is scoped to `aeron/` only. See `README.md` (this
directory) for setup/usage.

Structured to mirror `nats/` and `fast-dds/` wherever the middleware allows it — same result
schema, same script names, same Bash-only toolchain, same C++ / CentOS 7 / gcc 11 / C++17
client runtime — so the three can be compared directly. Where the structure diverges, it is
because Aeron is genuinely different, not because it was convenient; each such divergence is
called out below.

## Where Aeron sits relative to the other two

Worth internalising before touching anything here, because most of the design decisions
follow from it:

| | nats/ | fast-dds/ | aeron/ |
| --- | --- | --- | --- |
| Server process | one central broker | none (daemonless) | **one media driver per HOST** |
| Data path | client → broker → client | peer → peer | driver → driver (or app ↔ app for `ipc`) |
| Finding peers | broker address | discovery (multicast / server) | **nothing — the channel URI IS the address** |
| Slow subscriber | broker buffers, then drops | BEST_EFFORT drops | **back-pressures the publisher; never drops** |
| Delivery to app | callback | callback | **the application polls** |

Aeron is not daemonless and it is not brokered. It is the third case, and the media driver
is the thing that makes it so.

## Conventions

- **Aeron 1.52.x, pinned, and using the C++ WRAPPER API.** Aeron shipped two C++ APIs: the
  classic native client (`aeron-client/src/main/cpp`, `libaeron_client`, headers in
  `include/`) and a header-only wrapper over the C client
  (`aeron-client/src/main/cpp_wrapper`, headers in `include/wrapper`, symbols from
  `libaeron`). Building against 1.48 prints *"The C++ API will be removed in 1.50.0!"*, and
  it is indeed gone from 1.50 onward. This project deliberately targets the wrapper, i.e. the
  supported path — moving the pin BACKWARD past 1.50 would break the build, not fix it.
- **There IS a server process, and it must not be described as a broker.** `aeronmd` runs in
  every bench container. It owns the sockets, the term buffers and the flow-control state,
  and applications reach it through memory-mapped files. It never sits between two hosts —
  each host has its own, and data goes driver-to-driver. Do not call it a broker anywhere;
  do not call this project daemonless either.
- **The driver's lifecycle lives in ONE file: `lib/aeron-driver.sh`.** Both
  `docker/aeron-bench/entrypoint.sh` and `scripts/common-native.sh` source it. Do not
  reimplement the startup sequence in either caller: the three idle strategies it sets move
  measured p50 by 8-14x, so a second copy that drifts would silently invalidate every number
  measured under it. It is POSIX `sh` because `entrypoint.sh` is `#!/bin/sh`. It sits at the
  project's top level rather than under `scripts/` because `.dockerignore` excludes
  `scripts/` from the build context and the image has to `COPY` this file — moving it under
  `scripts/` without dealing with that breaks the image build.
- **The driver runs inside the bench container, one per container.** Started by
  `docker/aeron-bench/entrypoint.sh`, not by a compose service. "One driver per container"
  is the accurate model of "one driver per host", and it makes `bench-crosshost.sh` a
  genuine two-driver measurement. The rejected alternative — one shared driver, `AERON_DIR`
  on a Docker volume — has a silent failure mode: Aeron's files are mmap'd, and if the
  volume is not one shared tmpfs (which depends on the volume driver and is invisible to the
  caller) the two sides map different memory, connect to nothing, and report zero messages
  with no error.
- **Native Bash (`.sh`), targeting a real Linux host**, same as the siblings. Every path uses
  `/`, never `\`.
- **Every benchmark run writes to a fresh timestamped folder** under `results/<category>/`
  via `new_run_dir` in `scripts/common.sh` — never overwrite a prior run's output.
- **`results/run-index.csv`'s columns are identical to `nats/`'s and `fast-dds/`'s**, on
  purpose: the three files are meant to be concatenated for a cross-middleware comparison.
  Do not add a column here without adding it to both siblings.
- **`jq` is a hard prerequisite** for all JSON handling.
- See `TODO.md` for the active backlog and priority order of follow-up work.
- All `bench-*.sh` scripts accept `--label`, plus the shared transport/consumption/driver
  flags via `parse_common_arg`/`aeron_common_args`/`driver_env_args` in `common.sh`. Add new
  shared knobs there, not per script. Note the split: tool flags go through
  `aeron_common_args`, but the DRIVER is configured by environment variable, so those go
  through `driver_env_args` as `docker compose run -e` arguments.

- **There is a NATIVE (no-Docker) execution path, and it is not the default one.**
  `scripts/common-native.sh` + `scripts/bench-oneway-2host.sh` run the binaries directly,
  because the PTP-synchronised server pair cannot run Docker. Everything else in the project
  still goes through `docker compose`. `scripts/package-native.sh` builds the tarball that
  feeds it. Keep the native path to the minimum that needs it — `bench-rtt-2host.sh` and the
  rest deliberately stay Docker-only rather than being ported.

## Clocks — two of them, and swapping the wrong one is the trap

`aeron_bench` reads two different clocks and they are not interchangeable. Getting this
backwards produces measurements that look fine.

- **`Clock` (`std::chrono::steady_clock`, `CLOCK_MONOTONIC`) measures INTERVALS** — pacing,
  timeouts, `--linger-sec`, `--sub-work-us`, the per-second receive buckets, run duration.
  **It must stay monotonic.** NTP and PTP can step a realtime clock backwards mid-run.
- **`wireNowNs()` produces the timestamp that travels inside the message** and is subtracted
  by the receiving process. That one needs to be comparable across two processes, which is a
  different requirement, and `--clock` selects it.

**Do not "simplify" this by changing `using Clock` to `system_clock`.** That is the obvious
wrong fix: it hands every interval measurement a steppable clock while still leaving the wire
timestamp unsynchronised wherever PTP is not actually running. The split is the point.

- **PTP disciplines `CLOCK_REALTIME`, not `CLOCK_MONOTONIC`.** This is the whole reason
  `--clock` exists. A perfectly synchronised PTP pair does nothing at all for a tool that
  timestamps with `CLOCK_MONOTONIC`.
- **`--clock realtime` is rejected for `--measure rtt`, and that is a correctness rule rather
  than a restriction.** The ping side stamps and subtracts with its own clock, so RTT needs no
  synchronisation — using a disciplined clock would only add the failure mode of a PTP step
  landing mid-run. It is rejected for `--measure throughput` too, where it would do nothing.
  Rejecting rather than ignoring is deliberate: a flag that silently does nothing is how a run
  ends up labelled "PTP one-way" having measured something else.
- **A negative latency sample is proof the two clocks are not the same clock**, and
  `warnIfClockLooksUnsynchronised` exists because that failure is otherwise SILENT — an
  unsynchronised pair produces a plausible distribution shifted by the offset, and only the
  samples where the offset exceeds the true latency come out negative. Confirmed working by
  deliberately running pub with `--clock realtime` against sub with `--clock monotonic`:
  2000/2000 samples negative, correctly diagnosed. Do not downgrade it to a silent metric.
- **The PTP residual offset IS the error bar**, so `bench-oneway-2host.sh` records
  `master_offset` before and after into `meta.json`, and the error bar is bounded by the SUM
  of the two hosts' offsets, not either one. It lives in `meta.json` rather than `result.json`
  because it is a property of the hosts, not a metric the tool computed — consistent with
  `save_meta` already owning reproducibility info.
- **Hardware timestamping is close to a prerequisite, not an optimisation.** One-way latency
  here is tens of microseconds; software-timestamped PTP carries tens of microseconds of
  error, i.e. the error bar swallows the result. `bench-oneway-2host.sh` checks `ethtool -T`
  and says so. When it is unavailable the right answer is `bench-rtt-2host.sh`, not a
  caveated one-way number.
- **The measurement lands on the SUB side** in `bench-oneway-2host.sh`, the opposite of
  `bench-rtt-2host.sh` where the PING side measures. It follows from the definition: the
  publisher stamps, the subscriber subtracts, so only the subscriber holds both halves.

## The native (no-Docker) path — what the container was silently doing

Each of these was free under `docker compose run` and is not free natively.

- **An orphaned `aeronmd` busy-spins THREE cores forever.** With the default
  `--driver-idle noop` this is not a background process idling quietly; it pins three cores at
  100% on a real server until somebody notices. `docker compose run` tore the container down
  for us. `native_driver_up` traps EXIT/INT/TERM for exactly this, and that trap is the single
  most important line in `common-native.sh`. Verified: after a mid-run failure on both roles,
  no `aeronmd` survived.
- **`AERON_DIR_DELETE_ON_START=true` is safe in the container and NOT safe natively.**
  `entrypoint.sh` sets it unconditionally, justified by "every run gets a fresh container, so
  there is never a driver worth preserving" — that justification is false on a shared server,
  where a live driver may own `AERON_DIR` right now, and deleting mmap'd files out from under
  it corrupts silently rather than erroring. `aeron_driver_assert_free` refuses instead, and
  detection is deliberately conservative: the CnC file existing at all is enough to stop, and
  `fuser`/`pgrep` only make the message more specific, never decide it is safe to proceed.
  `--force-clean` is the explicit override.
- **`meta.json` must not claim the run was containerised.** `common.sh`'s `save_meta`
  hardcodes `image: "aeron-bench:local"` and `"aeronmd in-container"`. `save_meta_native` is a
  separate function rather than a flag because every field that matters differs, and a native
  result recorded the container way is a file that lies about how it was produced.
- **No `docker cp`, so `docker_run_and_copy_out` is unused here.** `native_run_bench` takes
  the same shape (destination first, then the whole command) so the call sites read alike, but
  the tool writes straight into the run directory.
- **A blocked UDP port looks like "received 0 messages", never like a connection error**,
  because Aeron has no discovery. `native_warn_about_firewall` says so up front.

## Packaging for hosts that cannot run Docker

- **Build in the image, ship the binaries — never build on the target.** Partly because gcc 11
  and CMake 3.31 will not be installable there, but mainly for comparability: all three
  projects' numbers were measured under the CentOS 7 / gcc 11 / C++17 client runtime, and
  rebuilding with the target's toolchain would change the client runtime out from under the
  comparison while looking like a packaging detail.
- **Portability was verified, not assumed.** Measured on the image: `aeron_bench` required at
  most `GLIBCXX_3.4.19` / `GLIBC_2.14` even before the static flags, because devtoolset-11
  already links the newer libstdc++ pieces statically; `aeronmd` is pure C and needed no
  libstdc++ at all. The direction here is old-build-to-new-host, which is the SAFE one — the
  notorious `GLIBCXX_3.4.xx not found` is the opposite direction. After
  `-static-libstdc++ -static-libgcc` the package's only floor is glibc 2.17.
  End-to-end confirmation: unpacked on clean Ubuntu 22.04 (glibc 2.35) with no toolchain and
  no Aeron installed, two containers ran `bench-oneway-2host.sh` pub/sub against each other,
  5000/5000 messages, zero loss.
- **`-static-libstdc++` is safe HERE for a specific reason.** It is dangerous when C++ objects
  or exceptions cross a shared-library boundary, and none do: `libaeron` and
  `libaeron_driver` are pure C (verified — neither requires a single GLIBCXX symbol) and the
  C++ wrapper API is header-only. Do not copy the flags to a target that links a C++ `.so`.
- **Do not ship glibc.** `BUNDLED_LIBS` is a deny-list-by-omission on purpose: libc, libm,
  libpthread, libdl and the loader MUST come from the target host. Shipping CentOS 7's glibc
  next to binaries on a newer kernel gets a mismatched loader and a segfault before `main()`.
- **`package-native.sh` assembles and tars INSIDE the container**, and this is not tidiness.
  Run from Windows, the staging directory has no POSIX permissions, `chmod +x` is a no-op, and
  the tarball lands on the target with non-executable binaries — whose symptom is
  `preflight.sh` reporting "aeron_bench not found" for a file that is plainly there (hit
  during development). Doing it in Linux also lets `cp -L` dereference `libuuid.so.1`, which
  `docker cp` would otherwise ship as a dangling symlink.
- **`$ORIGIN/../lib` RPATH on both binaries, no `LD_LIBRARY_PATH` wrapper.** Aeron already
  sets it on `aeronmd`; `tools/aeron_bench/CMakeLists.txt` now matches it. Keeping `bin/` and
  `lib/` together is therefore the package's only layout requirement.
- **Git Bash mangles more paths here than elsewhere.** `package-native.sh` needs
  `MSYS2_ARG_CONV_EXCL` to cover `/usr`, `/lib` (which is what `/lib64` matches) and `/bin`
  (for `--entrypoint /bin/sh`) on top of `common.sh`'s two. It still cannot be `'*'`, because
  `docker cp`'s destination is a real path on this machine and does need converting. Every
  omission showed up as "cannot find" a file that was plainly there.

## Aeron-specific traps this project already fell into or designed around

Every item here silently produces a *plausible but wrong* measurement, or a failure whose
message points somewhere other than the cause. That is what makes them worth writing down.

- **The media driver's idle strategy is the single highest-impact setting in this project,
  and Aeron's default is the slow one.** `BackoffIdleStrategy` (the default) parks an idle
  driver thread for up to a millisecond, so a message arriving into an idle sender waits out
  that park. Measured here, same host, 1000 msgs/s over UDP loopback, changing nothing else:
  **p50 245-331µs with `backoff` vs 21-41µs with `noop` — a consistent 8-14x across several
  runs.** `entrypoint.sh` therefore sets
  `AERON_{CONDUCTOR,SENDER,RECEIVER}_IDLE_STRATEGY=noop` by default, the same call
  `fast-dds/` made when it overrode Fast DDS's 3-second heartbeat period. Do NOT quietly
  change this default in either direction: with `backoff` every number describes the idle
  policy rather than the transport, and with `noop` three cores busy-spin. `--driver-idle`
  exposes both, `scenarios.json` measures both, and `result.json` records which was used.
  All three variables must be set together — leaving one on the default puts the park back.
- **`aeron:ipc` must never be the default.** Measured here: p50 **2.4-7.5µs** (ipc) vs
  21-41µs (UDP loopback, `noop`) vs 245-331µs (UDP loopback, stock driver). IPC writes straight into the
  driver's term buffers and the subscriber reads the same memory — the sender and receiver
  threads and the kernel UDP stack are not involved at all. That is a real and important
  Aeron capability, but it is not a network measurement, and NATS Core has no counterpart.
  Same reasoning as `fast-dds/`'s `--transport shm` being opt-in.
- **Docker's default `/dev/shm` is 64MB and Aeron needs far more.** Three term buffers are
  mapped per publication, at tens of megabytes each, plus the CnC and loss-report files. The
  failure is an opaque mmap error deep in the driver that never mentions `/dev/shm`.
  `docker-compose.yml` sets `shm_size: 1gb` on every service; `entrypoint.sh` warns if it
  sees a small one anyway (for callers using plain `docker run`); `smoke-test.sh` checks it
  as step 2, before anything that would fail confusingly.
- **The C++ wrapper's `Context` does NOT read the `AERON_DIR` environment variable.**
  Confirmed: `entrypoint.sh` starts `aeronmd` with `AERON_DIR=/dev/shm/aeron`, the driver
  honours it, and the client still went looking in `/dev/shm/aeron-root` (its own built-in
  `aeron-<user>` default) and died with "(-1000) driver timeout / CnC file not created".
  `resolveAeronDir()` in `main.cpp` reads the variable explicitly so the two agree. Do not
  remove it on the assumption that the environment is enough.
- **The wrapper's own headers `#include <aeronc.h>`.** It is a thin C++ layer over the C
  API, so `/usr/local/include/aeron` has to be on the include path alongside
  `/usr/local/include/wrapper`. Omitting it fails inside `wrapper/util/Exceptions.h`, which
  reads like a broken Aeron installation rather than a missing include directory.
- **`offer()` returning a negative value is normal operation, not an error.**
  `BACK_PRESSURED` means the subscriber has not consumed enough; `NOT_CONNECTED` means no
  subscriber exists yet; `ADMIN_ACTION` means a term rotation. All three are retried in
  `offerWithRetry`. Two things there are deliberate and easy to "fix" wrongly:
  - **The seq/timestamp header is rewritten before EVERY attempt.** A message delayed by
    back-pressure therefore carries the timestamp of the attempt that got through, so the
    reported latency is transport latency and not transport-plus-publisher-wait — the same
    distinction `dds_bench` draws by timing `wait_for_acknowledgments` separately. The wait
    is not hidden: it is reported as `back_pressure_events` / `back_pressure_sec`, and the
    tool prints a NOTE when a latency run back-pressured at all.
  - **`NOT_CONNECTED` is not counted as a send.** Nothing left the process, so counting it
    would inflate `msgs_sent` and manufacture "loss" out of messages that were never sent.
- **A slow subscriber does not cause loss under Aeron — it causes back-pressure.** Flow
  control is always on and receiver-driven, which makes "unthrottled throughput" a different
  quantity here than under Fast DDS BEST_EFFORT: it is the rate the SLOWEST SUBSCRIBER could
  sustain, not the rate the publisher could emit while the rest was dropped. A throughput
  figure without the back-pressure count cannot distinguish "Aeron's ceiling" from "this
  subscriber's ceiling", so `report_back_pressure` prints it and `result.json` records it.
- **A throughput run whose total bytes fit inside the publication window measures how fast a
  term buffer fills, not throughput — and nothing about it looks wrong.** Found here:
  `--msgs 50000 --size 128 --sub-work-us 20` reported **pub 1.61M msgs/s against sub 48k
  msgs/s, msg_loss 0, back_pressure 0**. The publisher "finished" in 31ms because all 6.4MB
  fit in the window and `offer()` never had to wait; the subscriber then spent a second
  draining it. Re-run with `--term-length 64k`: **773k–1.5M back-pressure events and pub
  46k/s converging on sub 46k/s** — the real number, a 35x correction. The scenario in
  `scenarios.json` therefore carries `"term-length": "64k"` and it is required, not tuning.
  `runPubSub` warns whenever a publisher outran its subscriber by more than 2x with zero
  back-pressure; do not remove that, it is the only thing standing between this artefact and
  a plausible-looking result file. Note that a healthy saturation run does NOT trip it —
  confirmed, `--msgs 100000` with a fast subscriber gives pub 1.32M vs sub 1.31M.
- **Consequently, msg_loss is a failure here in nearly every case.** Three different rules
  now live in this repo, and mixing them up will either hide a real bug or fail every run:
  `nats/` fails on any loss (TCP); `fast-dds/` fails only under `--reliability reliable`
  (BEST_EFFORT is *defined* to drop); `aeron/` fails unless `--reliable no`, because "the
  subscriber was slow" is not an available explanation. `loss_is_failure` in `common.sh` and
  `aeron_bench`'s exit code both apply that rule.
- **A publisher-only process must linger before exiting.** `offer()` returning success means
  "written to the term buffer", and this container's driver is stopped when the process ends
  (`entrypoint.sh` kills `aeronmd` after the command returns). Without `--linger-sec`
  (default 2s) whatever the driver had not yet put on the wire is lost, and it surfaces as
  subscriber-side message loss that has nothing to do with Aeron. The RTT echo side needs the
  same treatment for its last replies.
- **One `FragmentAssembler` per SUBSCRIPTION, not per poll thread.** Reassembly is keyed on
  the session id, and two subscriptions on different streams can legitimately see the same
  session id — sharing one assembler would splice two half-messages together. Only shows up
  above the MTU (default 1408 bytes), i.e. exactly in the large-message scenario.
- **Aeron has no discovery, so cross-container runs need addresses fixed in advance.** The
  `aeron-bench-a` / `aeron-bench-b` compose services carry static `ipv4_address` entries for
  this, and `CROSS_A_ADDRESS`/`CROSS_B_ADDRESS` in `common.sh` must stay in sync with them.
  Unlike `fast-dds/`, there is no multicast to try and no rendezvous server to fall back to,
  which is why `smoke-test.sh` treats a cross-container failure as fatal rather than as a
  warning.
- **RTT needs two DISTINCT endpoints.** An Aeron subscription binds its endpoint, so a shared
  request/response endpoint makes the ping side receive its own traffic. `bench-latency.sh`
  uses 40456/40457; `bench-rtt-2host.sh` rejects equal `--req-port`/`--resp-port`.
- **Busy-spinning threads are easy to oversubscribe here, and the failure is not just
  "slower".** The spinners are not all yours: `--poll-idle busy` costs one core per
  subscriber, `--pacing auto/busy` one per publisher, and `--driver-idle noop` three more for
  the driver. Past the core count they starve the driver's sender/receiver threads, and badly
  oversubscribed the client can decide the driver is unresponsive and abort the run outright.
  `warnIfSpinnersExceedCores` warns rather than refusing (a caller with pinned cores may know
  better), and `scenarios.json`'s scalability sweep uses `--poll-idle yield` for this reason.
- **`std::thread::hardware_concurrency()` is useless inside a container.** libstdc++
  implements it with `sysconf(_SC_NPROCESSORS_ONLN)`, which reports the HOST's online CPUs
  and ignores container limits — confirmed in `fast-dds/`: under `docker run
  --cpuset-cpus=0,1` it still returned 12. `availableCores()` uses `sched_getaffinity` and
  the cgroup CPU quota, taking the smaller.
- **Aeron's `SleepingIdleStrategy` constructor signature is version-dependent.** Confirmed:
  `SleepingIdleStrategy(std::chrono::microseconds)` does not compile against the pinned
  version. The tool therefore hand-rolls its three idle behaviours (`IdleKind` / `idleFor`)
  rather than depending on Aeron's classes — which also puts the idle semantics being
  measured in this file rather than in a dependency.
- **`BUILD_AERON_ARCHIVE_API=OFF` is load-bearing, not tidiness.** The Archive API is a Java
  component; with it ON, CMake shells out to `gradlew` and needs a JDK. Likewise
  `AERON_TESTS`/`AERON_UNIT_TESTS`/`AERON_SYSTEM_TESTS=OFF`, without which the configure step
  downloads GoogleTest at build time.
- **This image needs a NEWER CMake than `fast-dds/`'s.** Aeron's top-level `CMakeLists.txt`
  declares `cmake_minimum_required(VERSION 3.30)` from the 1.48 line onward; the fast-dds
  image pins 3.27.9. Do not "unify" the two Dockerfiles' `CMAKE_VERSION` without checking.
  `libuuid-devel` is also Aeron-specific — the C driver links `uuid` *when it is found*, a
  silent feature detection rather than a hard error.
- **`--profile` is a `docker compose` global flag, not a `run` flag.** `docker compose run
  --profile X svc` fails; it must be `docker compose --profile X run svc`. In practice
  `docker compose run <svc>` auto-enables that service's own profiles, so `run` needs no
  profile flag at all. (Inherited from `fast-dds/`.)
- **`tc netem` does not work on Docker Desktop for Windows** — the bundled WSL2/Hyper-V
  kernel lacks `sch_netem` (confirmed in `nats/` and `fast-dds/`, regardless of `cap_add:
  NET_ADMIN`). Host-kernel limitation, not fixable from inside a container.
  `entrypoint.sh`'s injection is non-fatal on failure — do not make it `set -e`-fatal.
- **Never retrieve results via a `-v <local>:/out` bind mount — always use
  `docker_run_and_copy_out`** (`common.sh`), which uses `docker cp`. A bind-mount path is
  resolved by the *Docker daemon*, not by whoever runs `docker`, so it silently returns
  nothing the moment `docker` points at a remote host via `docker context`. Because a bind
  mount used to be what created `/out` automatically, `entrypoint.sh` does `mkdir -p /out`
  itself — don't remove it: C++ `std::ofstream` fails to open silently (no exception), so
  the tool prints a normal-looking summary while writing no files at all.
- **`parse_common_arg` reports through a global, not stdout.** A `$(...)` call would run it
  in a subshell and throw away every assignment it made. (Inherited from `fast-dds/`.)
- **Git Bash on Windows mangles container-internal absolute paths.** `common.sh` exports
  `MSYS2_ARG_CONV_EXCL="/out;/dev/shm"` — note that this project needs **two** prefixes where
  `fast-dds/` needed one, because `--aeron-dir /dev/shm/aeron` is a second container-internal
  path. Inert on the real Linux target. Do NOT use `MSYS_NO_PATHCONV=1` instead: that would
  also stop converting `docker cp`'s destination, which is a genuine Windows path that must
  be converted.

## Measurement semantics that differ from the siblings (not bugs — read before "fixing")

- **`bench-scalability.sh` sweeps SUBSCRIBER CLIENTS, and the expected shape of the result is
  different.** NATS sweeps connections (the broker writes N copies); Fast DDS sweeps
  participants (the publisher unicasts to N independent RTPS peers, measured there as a
  110k → 1.1k msgs/s collapse from 1 to 25). Aeron's N subscribers on one host share a single
  media driver and therefore a single copy of the data: the driver receives each message once
  into a term buffer and every subscriber reads that same buffer at its own position. The
  prediction is that Aeron stays roughly flat and that the limit turns out to be CPU (one
  poll thread per subscriber) rather than network. Confirming or refuting that on real
  hardware is the most informative single result this project can produce — TODO.md #1.

  First measurement here (12-core WSL2 VM, `--poll-idle yield`, unthrottled, 128B),
  publisher msgs/s at 1 / 5 / 10 / 25 subscribers: **1.15M → 1.19M → 187k → 24k**. Flat to
  5, then a cliff — and the cliff lands exactly where the threads stop fitting: at 5
  subscribers the run wants 5 poll + 3 driver + 1 publisher = 9 threads on 12 cores, at 10
  it wants 14. So this is CPU exhaustion, consistent with the hypothesis but not a test of
  it. Contrast Fast DDS on the same machine, which fell 110k → 13.3k **by 5 participants**
  with cores to spare, because that cost is per-peer fan-out rather than per-thread. Do not
  cite the Aeron cliff as a fan-out result; re-measure with cores >= subscribers + 4.
- **`--stream-count` is the analogue of NATS's `--multisubject` and Fast DDS's
  `--topic-count`,** but note that N streams over one UDP endpoint still share ONE socket and
  one channel endpoint in the driver, unlike DDS's per-topic locators. It is a cheaper axis
  here than there, and that is a finding rather than an artefact.
- **`--poll-idle` has no counterpart in either sibling and is not a tuning detail.** Aeron
  does not call the application back; the application polls. How that loop waits is therefore
  part of the latency being measured, which is why it is recorded in `result.json` and why a
  run measured with `--poll-idle sleep` is not comparable to one measured with `busy`.
- **`aeron_bench` writes `result.json` itself; the scripts do not recompute metrics.** Same
  decision as `dds_bench`, for the same reason: the tool is ours, so the metric definitions
  live in exactly one place, and `index_from_result_json` only lifts summary columns out for
  `run-index.csv`. Keep it that way.
- **`bench-latency.sh` (RTT) is the secondary metric, `bench-latency-oneway.sh` is primary.**
  RTT is kept for comparability with published benchmarks (including Aeron's own
  `aeron-benchmarks` ping/pong harness), but it folds in the echo peer's receive-and-
  republish cost on top of two traversals.
- **One Aeron client per measurement group, not one client with N endpoints.** The
  scalability sweep models N independent subscriber *applications*; each client is a separate
  registration with the driver and runs its own conductor thread, which is part of what is
  being measured.

## Tool design decisions

- **One binary covers every category,** with two orthogonal axes: `--measure
  throughput|latency|rtt` and `--mode both|pub|sub`. Same shape as `dds_bench`. Aeron does
  ship a benchmark harness (`aeron-benchmarks`), but it is Java/Gradle-driven and would have
  measured a different client runtime than the other two projects.
- **C++ / CentOS 7 / gcc 11 / C++17, matching production and matching the siblings.** Do not
  port this to Java or Python, even for convenience: a non-native client's own overhead (GC,
  interpreter, event-loop scheduling) would get measured as if it were the middleware's
  latency, and it would break comparability with the NATS and Fast DDS numbers, which were
  measured under exactly this runtime. See `nats/TODO.md` #4 for the full reasoning.
- **`ExclusivePublication` is the default.** `Publication` is safe for concurrent writers and
  pays a multi-producer claim protocol for it; `ExclusivePublication` assumes a single writer
  and skips it. Every publisher thread here owns its own publication, so `exclusive` is both
  correct and what Aeron's published numbers use. `--publication concurrent` measures the
  difference deliberately.
- **`--measure latency`/`rtt` reject `--msgs` outright.** `--rate` + `--duration-sec` are the
  axis; total count is derived. An unthrottled burst measures the subscriber's queueing
  backlog, not steady-state latency — confirmed empirically on the NATS side
  (`nats/TODO.md` #4), and middleware-independent, so this tool was built this way from the
  start.
- **The subscriber has an idle timeout, not just a hard one.** It earns its keep less often
  than under Fast DDS BEST_EFFORT (where loss was the expected outcome), because Aeron's flow
  control means a healthy run does reach the full count. It still matters for `--reliable no`,
  for a publisher that gave up, and for a cross-container run whose peer died.
- **`AERON_VERSION` is baked in as a compile definition** rather than read back from the
  library at runtime: exact by construction, and the C++ version accessor has moved between
  releases, so reading it would be one more thing to re-verify on every version bump.
