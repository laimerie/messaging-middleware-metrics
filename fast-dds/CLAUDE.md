# fast-dds

Fast DDS performance verification environment. This is one of several messaging middleware
benchmark environments in this repo (see the repo-root `CLAUDE.md` for the overall
structure); everything in this file is scoped to `fast-dds/` only. See `README.md` (this
directory) for setup/usage.

Structured to mirror `nats/` wherever the middleware allows it — same result schema, same
script names, same Bash-only toolchain — so the two can be compared directly. Where the
structure diverges, it is because DDS is genuinely different, not because it was
convenient; each such divergence is called out below.

## Conventions

- **Fast DDS 2.14.x, pinned.** Fast DDS 3.x renames the exported CMake package
  (`fastrtps` → `fastdds`) **and** changes the `TopicDataType` virtual interface
  (`serialize(const void* const, SerializedPayload_t&, DataRepresentationId_t)`,
  `calculate_serialized_size`, `compute_key`, namespaces moved to `eprosima::fastdds::rtps`).
  `tools/dds_bench/main.cpp` implements that interface by hand, so a 3.x bump is a code
  change, not a version bump. If you do it, do it deliberately.
- **There is no broker service, and there must not be one.** Fast DDS is daemonless; that
  is the property being measured. `docker-compose.yml` has no server, only clients. The
  `discovery-server` service is a discovery rendezvous point, NOT a data-path broker — it
  never sees a sample. Do not describe it as "the Fast DDS server" anywhere.
- **Native Bash (`.sh`), targeting a real Linux host**, same as `nats/`. Every path uses
  `/`, never `\`.
- **Every benchmark run writes to a fresh timestamped folder** under `results/<category>/`
  via `new_run_dir` in `scripts/common.sh` — never overwrite a prior run's output.
- **`results/run-index.csv`'s columns are identical to `nats/results/run-index.csv`'s**, on
  purpose: the two files are meant to be concatenated for a cross-middleware comparison.
  Do not add a column here without adding it there.
- **`jq` is a hard prerequisite** for all JSON handling.
- See `TODO.md` for the active backlog and priority order of follow-up work.
- All `bench-*.sh` scripts accept `--label`, plus the shared QoS/transport/discovery flags
  via `parse_common_arg`/`dds_common_args` in `common.sh`. Add new shared knobs there, not
  per script.

## DDS-specific traps this project already fell into or designed around

Every item here silently produces a *plausible but wrong* measurement rather than an error.
That is what makes them worth writing down.

- **Intra-process delivery must stay OFF.** Fast DDS routes samples between endpoints in
  the same process through a shortcut that bypasses RTPS and the transport entirely
  (`LibrarySettingsAttributes::intraprocess_delivery`, default `INTRAPROCESS_FULL`). Under
  `--mode both` — which is what every same-host bench script uses — leaving it on measures
  a memcpy and reports sub-microsecond "network latency". `applyLibrarySettings()` sets
  `INTRAPROCESS_OFF` before any participant exists (it has no effect afterwards).
  `--intraprocess on` exists only for deliberately measuring that path.
- **Never rely on the builtin transport set.** `use_builtin_transports = true` (the
  default) enables shared memory *and* UDP. Two containers on the same Docker host can
  match an SHM locator — same physical machine — while owning **separate `/dev/shm`
  mounts**, so samples get written into a segment the peer never reads. The result is 100%
  message loss with no error anywhere. `configureTransport()` therefore always sets
  `use_builtin_transports = false` and names the transport explicitly.
- **`--transport shm` cannot work across containers** for the same reason. `bench-crosshost.sh`
  rejects it up front rather than letting it silently lose everything.
- **Wait for `on_publication_matched`, never `sleep N`.** DDS discovery is asynchronous and
  BEST_EFFORT + VOLATILE discards anything written before a reader is matched. The NATS
  scripts' `sleep 2` idiom is a guess; here it would be a guess in the exact place a wrong
  guess costs the whole run. `MatchCounter` + `WriterListener` do this properly.
- **A `--size` at or above ~64000 needs ASYNCHRONOUS publish mode.** A sample larger than
  one UDP datagram must be fragmented, and Fast DDS only fragments asynchronously — in
  SYNCHRONOUS mode the write just never arrives. `parseArgs` auto-switches at 60000
  (`--publish-mode auto`, the default) so a large-message scenario doesn't read as total
  loss.
- **RELIABLE needs unlimited `resource_limits`.** The default `max_samples` (5000) turns
  `write()` into a stall long before a benchmark finishes, since RELIABLE has to retain
  unacknowledged samples. `createWriters`/`createReaders` set `max_samples = 0`.
- **Under RELIABLE, `write()` only queues** — `publishAll` calls `wait_for_acknowledgments`
  so "sent" means "delivered", not "handed to the middleware".
- **Discovery Server locators are IP addresses, not hostnames.** `IPLocator::setIPv4`
  cannot take `discovery-server` as a Docker DNS name. That is why `docker-compose.yml`
  pins a subnet and a static `ipv4_address`, and why `DS_ADDRESS` in `common.sh` is a
  literal. The two must stay in sync.
- **Separate containers are NOT a stand-in for separate servers, and the data says so.**
  Crossing the container boundary cost nothing measurable (p50 70µs same-process vs 68µs
  cross-container) because veth + a Linux bridge is an in-kernel memcpy — no NIC, no wire,
  no switch. Never present a `bench-crosshost.sh` number as a host-to-host figure.
- **One-way latency across two REAL servers is not measurable with `steady_clock`.** It is
  `CLOCK_MONOTONIC`, whose epoch is arbitrary per host, so the subtraction is meaningless
  across machines — and it fails silently, producing plausible or negative latencies
  (negative values were actually observed on real hardware). Same-host containers are fine
  because they share one kernel clock. `scripts/bench-rtt-2host.sh` sidesteps this by
  measuring round-trip with the ping side's own clock only. A true cross-host one-way
  figure needs PTP **and** a tool change: PTP disciplines `CLOCK_REALTIME`, not
  `CLOCK_MONOTONIC`, so the current tool would not benefit even from perfect PTP sync
  (TODO.md #6).
- **Cross-server runs require `network_mode: host`** (compose services `dds-bench-host` /
  `discovery-server-host`). RTPS advertises LOCATORS — literal IPs the peer is told to send
  to — so on a bridge a container advertises its private address (confirmed: 172.28.0.2)
  and the peer cannot route to it. The failure mode is the nasty one: discovery succeeds,
  endpoints match, and then no data ever arrives. Publishing ports is not a workaround;
  RTPS allocates ports dynamically per participant.
- **`--profile` is a `docker compose` global flag, not a `run` flag.** `docker compose run
  --profile X svc` fails; it must be `docker compose --profile X run svc`. In practice
  `docker compose run <svc>` auto-enables that service's own profiles, so `run` needs no
  profile flag at all — only `up` does (see `ensure_discovery_server`).
- **UDP multicast over a Docker bridge is unreliable** (IGMP snooping, `br_netfilter`, host
  kernel config), so cross-container SIMPLE discovery may or may not work on a given
  machine. This is a Docker property, not a Fast DDS one. `smoke-test.sh` tests it
  explicitly and treats failure as a WARNING that steers you to `--discovery server`;
  `bench-crosshost.sh` defaults to `--discovery server` for exactly this reason.
- **`tc netem` does not work on Docker Desktop for Windows** — the bundled WSL2/Hyper-V
  kernel lacks `sch_netem` (confirmed in `nats/`: plain `tc qdisc add ... pfifo` succeeds,
  `... netem` fails with `RTNETLINK answers: No such file or directory`, regardless of
  `cap_add: NET_ADMIN`). Host-kernel limitation, not fixable from inside a container.
  `entrypoint.sh`'s injection is non-fatal on failure — do not make it `set -e`-fatal.
- **Never retrieve results via a `-v <local>:/out` bind mount — always use
  `docker_run_and_copy_out`** (`common.sh`), which uses `docker cp`. A bind-mount path is
  resolved by the *Docker daemon*, not by whoever runs `docker`, so it silently returns
  nothing the moment `docker` points at a remote host via `docker context`. Because a bind
  mount used to be what created `/out` automatically, `entrypoint.sh` does `mkdir -p /out`
  itself — don't remove it: C++ `std::ofstream` fails to open silently (no exception), so
  the tool prints a normal-looking summary while writing no files at all.
- **`parse_common_arg` reports through a global, not stdout.** A `$(...)` call would run it
  in a subshell and throw away every QoS assignment it made.
- **Fast DDS's default heartbeat period is 3 SECONDS** (`WriterAttributes.h`: "Periodic HB
  period, default value 3s"). Under RELIABLE that gates `wait_for_acknowledgments`, and it
  dominates any short run — measured here, a 1000-message publish at 2000 msgs/s spent 2.5s
  of its 3.0s total waiting on one heartbeat, reporting 332 msgs/s for a publisher that had
  actually finished sending in 0.5s. `dds_bench` sets 100ms (`--heartbeat-period-ms`) and,
  separately, times the ack wait outside the send loop, reporting it as
  `metrics.pub.ack_wait_sec`. Pass `--heartbeat-period-ms 3000` to measure the
  out-of-the-box behaviour.
- **Sleeping cannot pace a high send rate, and getting this wrong silently changes what the
  run measured.** `sleep_for(100us)` overshot by 83us at the median here (300us at p99), so
  a requested 10000/s delivered only ~5500/s — the run reported one rate and measured
  another, and the uneven wake-ups made sending bursty, inflating the receiver's queueing
  tail. `--pacing auto` (the default) sleeps to within `kPacingSpinGuard` (200us) of the
  target and busy-spins the rest: measured 9437/s achieved, with p50 74→62us and p99
  407→298us as a side effect. `--pacing sleep` restores the old behaviour for low-rate or
  CPU-constrained runs. `publishAll` warns whenever the achieved rate falls below 90% of
  the requested one — do not remove that; it is the guard against this recurring silently.
- **`std::thread::hardware_concurrency()` is useless inside a container.** libstdc++
  implements it with `sysconf(_SC_NPROCESSORS_ONLN)`, which reports the HOST's online CPUs
  and ignores container limits — confirmed: under `docker run --cpuset-cpus=0,1` it still
  returned 12. Since this tool only ever runs in a container, a check built on it is dead
  code in exactly the case it exists for. `availableCores()` uses `sched_getaffinity`
  (honours `--cpuset-cpus`/taskset) and the cgroup CPU quota (`cpu.max` on v2,
  `cpu.cfs_quota_us` on v1, honouring `--cpus`), taking the smaller. Verified to fire under
  both limit mechanisms and stay silent unrestricted.
- **A busy-spinning publisher must not outnumber the cores.** It occupies one core per
  publisher thread; if the Fast DDS reception threads cannot also get a core, the spin
  starves the very receive path being measured (confirmed: restricted to 2 cores, p99 went
  575us → 637us). `warnIfPacingWillStarveReceiver` warns rather than refusing — a caller
  with pinned/isolated cores may legitimately know better.
- **Git Bash on Windows mangles `--out /out`** into something like
  `C:/Program Files/Git/out` via its MSYS path conversion, because it cannot know the path
  is container-internal. The tool then writes nowhere, silently (C++ `ofstream` does not
  throw), and `docker cp` finds nothing — a run that prints a perfectly normal summary and
  produces no `result.json`. `common.sh` exports `MSYS2_ARG_CONV_EXCL="/out"`, which is
  inert on the real Linux target. Do NOT use `MSYS_NO_PATHCONV=1` instead: that would also
  stop converting `docker cp`'s destination, which is a genuine Windows path that must be
  converted. Same issue was hit in `nats/` (TODO.md #3).

## Environment-specific findings so far (Windows / Docker Desktop only — re-measure on Linux)

These came out of verifying the implementation, not from a real benchmark run. They are
recorded because they were surprising, not because the numbers mean anything.

- Cross-container SIMPLE discovery (multicast over the Docker bridge) **does** work on this
  Docker Desktop setup. That is not guaranteed elsewhere, which is why `smoke-test.sh`
  tests it and `bench-crosshost.sh` still defaults to `--discovery server`.
- `--transport shm` beats UDPv4 on one-way latency, but only visibly over a long enough
  sample: 20s at 1000/s gave p50 196µs (SHM) vs 247µs (UDP). A first 4-second spot check
  had shown the opposite ordering — short runs here are too noisy to rank transports, so
  compare only runs of comparable length.
- **Publisher throughput collapses as participant count rises**: 110k → 13.3k → 3.6k →
  1.1k msgs/s at 1 / 5 / 10 / 25 subscriber participants (`default-sweep`, unthrottled,
  128B). Loss stayed at zero, so this is back-pressure from per-peer fan-out, not drops —
  the publisher is writing to N independent RTPS peers. This is the qualitative difference
  from a broker topology that `bench-scalability.sh` exists to expose, and it is the single
  most important number to re-measure on real hardware.
- `tc netem` is still expected to fail here (`sch_netem` missing from the WSL2 kernel);
  that was confirmed in `nats/` and nothing about this project changes it.

## Measurement semantics that differ from nats/ (not bugs — read before "fixing")

- **RELIABLE + KEEP_LAST is not lossless, and that is correct DDS behaviour.** RELIABLE
  guarantees delivery of samples the writer still *holds*; KEEP_LAST(depth) caps what it
  holds, so a reader falling further behind than `depth` loses the overwritten samples.
  Measured here: `--reliability reliable` at the default `keep_last`/depth 100 lost 679 of
  100000 unthrottled messages, while the same run with `--history keep_all` lost zero, as
  did a rate-paced RELIABLE run. **The keep_last loss is intermittent** — a rerun of the
  identical command lost zero, since it is a race between the reader's drain rate and the
  writer's history depth. Do not read a passing run as proof the configuration is safe;
  intermittent loss is the worse failure mode. Only RELIABLE + KEEP_ALL is genuinely
  lossless by construction. The tool
  prints an explanation when it hits this combination rather than just failing, and the
  `reliable-baseline` scenario carries `"history": "keep_all"` for this reason. Do NOT
  "fix" this by making `--reliability reliable` silently imply KEEP_ALL — the two QoS
  policies are orthogonal in DDS and hiding that would teach the wrong model.
- **`msg_loss > 0` is NOT a failure under BEST_EFFORT.** Dropping samples a subscriber
  cannot keep up with is what BEST_EFFORT is defined to do, and an unthrottled saturation
  test is *expected* to lose. Failing on it would make every default run "fail" while
  telling you nothing. `loss_is_failure` (`common.sh`) and `dds_bench`'s exit code both
  apply the rule "loss is a failure only under `--reliability reliable`". NATS Core over
  TCP has no equivalent case, which is why `nats/` fails on any loss.
- **`bench-scalability.sh` sweeps `--participant-counts`, not connection counts.** There
  are no connections to count — no broker. Each subscriber participant is an independent
  RTPS peer that every publisher must discover, match and send to individually, so the
  sweep measures peer-to-peer fan-out and discovery cost. Expect a *lower* practical
  ceiling than a NATS connection sweep (participants are far heavier than TCP connections,
  and N participants discover each other pairwise), and expect `--discovery server` to
  raise it.
- **`--topic-count` is the analogue of NATS's `--multisubject`.** DDS has no subject
  wildcards, so many-destination fan-out means N distinct topics each with its own reader,
  not one wildcard subscription.
- **`dds_bench` writes `result.json` itself; the scripts do not recompute metrics.** On the
  NATS side the official CLI emitted CSV and bash re-derived everything, which meant the
  metric definitions lived in two languages. Here the tool is ours, so the computation
  lives in exactly one place and `index_from_result_json` only lifts summary columns out
  for `run-index.csv`. Keep it that way.
- **`bench-latency.sh` (RTT) is the secondary metric, `bench-latency-oneway.sh` is
  primary.** RTT is kept for comparability with published benchmarks (including eProsima's
  own LatencyTest, also a ping/pong), but it folds in the echo peer's receive-and-republish
  cost on top of two traversals.

## Tool design decisions

- **One binary covers every category.** Unlike `nats/`, where `nats bench` handled
  throughput/scalability and a custom C++ tool was only needed for one-way latency, Fast
  DDS ships no benchmark CLI. `dds_bench` therefore has two orthogonal axes: `--measure
  throughput|latency|rtt` and `--mode both|pub|sub`.
- **C++ / CentOS 7 / gcc 11 / C++17, matching production and matching `nats/`.** Do not
  port this to Python or another language, even for convenience: a non-native client's own
  overhead (GC, interpreter, event-loop scheduling) would get measured as if it were the
  middleware's latency, and it would also break comparability with the NATS numbers, which
  were measured under exactly this runtime. See `nats/TODO.md` #4 for the full reasoning.
- **The topic data type is hand-written, not fastddsgen-generated.** Three reasons: it
  keeps Java and Fast-DDS-Gen out of the CentOS 7 image; it makes `--size` a pure runtime
  parameter rather than something baked into an IDL; and serialising as an opaque memcpy'd
  byte blob (no FastCDR encoding) leaves the tool independent of the FastCDR 1.x/2.x API
  split. Both endpoints are the same binary, so encoding interoperability is not a goal.
- **`--measure latency`/`rtt` reject `--msgs` outright.** `--rate` + `--duration-sec` are
  the axis; total count is derived. An unthrottled burst measures the subscriber's queueing
  backlog, not steady-state latency — confirmed empirically on the NATS side
  (`nats/TODO.md` #4), and the reasoning is middleware-independent, so this tool was built
  this way from the start rather than being retrofitted.
- **`ReaderListener` takes no lock in `on_data_available`.** Fast DDS serialises that
  callback per DataReader, so per-listener counters are safe and are merged once at the
  end. A shared mutex-protected collector would have put a lock on the hot path of the very
  thing a throughput test measures.
- **The subscriber has an idle timeout, not just a hard one.** Under BEST_EFFORT, "wait for
  the full expected count" would always run to the hard timeout, because real loss is the
  expected outcome. `waitForReceipt` returns once the stream has been quiet for
  `--idle-timeout-sec`.
