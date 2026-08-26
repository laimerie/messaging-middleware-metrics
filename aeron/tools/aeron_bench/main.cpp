// aeron_bench — Aeron performance measurement tool (throughput / one-way latency / RTT).
//
// The Aeron counterpart of nats/tools/latency_oneway/ and fast-dds/tools/dds_bench/. Like
// Fast DDS, Aeron ships no general-purpose benchmark CLI usable from a script, so ONE
// binary covers every category here. That is also what keeps the three projects
// comparable: all measure with a native C++ client on CentOS 7 / gcc 11 / C++17, so no
// number carries a client-runtime overhead the others don't.
//
// Two orthogonal axes, deliberately identical to dds_bench's:
//
//   --measure throughput   msgs/sec + MB/sec over a fixed message count (--msgs), with an
//                          optional --rate cap. Per-second receive buckets go to
//                          throughput.csv.
//   --measure latency      true one-way publisher->subscriber latency. --rate and
//                          --duration-sec are BOTH required; the total count is derived
//                          (round(rate*duration)) and --msgs is rejected. There is
//                          deliberately no unthrottled-burst latency mode: an unthrottled
//                          send measures the queueing delay of a backlog the publisher
//                          created faster than the subscriber could drain it, not
//                          steady-state transport latency. (Confirmed empirically on the
//                          NATS side — nats/TODO.md #4 — and middleware-independent.)
//   --measure rtt          round-trip via an echo peer, on a separate response channel.
//
//   --mode both            publisher and subscriber in ONE process, as separate Aeron
//                          client connections to the same media driver.
//   --mode pub / --mode sub
//                          publisher-only / subscriber-only, each its own process and, in
//                          this project, its own container WITH ITS OWN MEDIA DRIVER
//                          (bench-crosshost.sh). For --measure rtt: `pub` is the measuring
//                          ping side, `sub` is the echo side.
//
// WHAT IS STRUCTURALLY DIFFERENT ABOUT AERON, and therefore about this tool:
//
//  * There is no discovery, at all. A channel is a URI naming a literal endpoint
//    (aeron:udp?endpoint=10.0.0.5:40456). Nothing is searched for, so there is no
//    match-wait equivalent to DDS's on_publication_matched — only Publication::isConnected
//    / Subscription::isConnected, which this tool polls before sending.
//
//  * Flow control is ALWAYS ON and receiver-driven. A publisher that outruns its slowest
//    subscriber does not lose messages; offer() returns BACK_PRESSURED and the caller must
//    retry. That makes "unthrottled throughput" mean something different here than under
//    Fast DDS BEST_EFFORT: it is the rate the SLOWEST SUBSCRIBER can sustain, not the rate
//    the publisher can emit while dropping the rest. Back-pressure events and the time
//    spent in them are counted and reported for exactly this reason — a throughput number
//    without them hides which side was the limit.
//
//  * The subscriber is POLLED, not called back. There is no Aeron-owned delivery thread:
//    this tool runs the poll loop, so the loop's idle strategy is part of the measurement
//    and is recorded in result.json. A sleeping poll loop makes Aeron look slow; that is
//    the measurement's fault, not Aeron's.
//
//  * std::chrono::steady_clock is a HOST-wide monotonic clock, so pub/sub timestamps stay
//    directly comparable across separate containers on one Docker host (they share a
//    kernel). Genuinely separate physical hosts have unrelated epochs — the subtraction
//    would fail SILENTLY, producing plausible or negative values. Use --measure rtt there
//    (scripts/bench-rtt-2host.sh), exactly as on the Fast DDS side.

#include <Aeron.h>
#include <FragmentAssembler.h>

#include <sched.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <functional>
#include <iostream>
#include <memory>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

namespace {

using Clock = std::chrono::steady_clock;

constexpr const char* kToolVersion = "aeron_bench 0.1.0";

// seq (8 bytes) + send_time_ns (8 bytes). Everything after this is filler, so --size is the
// exact user payload size, directly comparable with NATS's and dds_bench's --size.
constexpr std::int32_t kHeaderSize = 16;

// How much of each pacing interval `--pacing auto` hands to a busy spin instead of the OS.
// Sized from measurement on the Fast DDS side of this repo, not taste: a
// std::this_thread::sleep_for(100us) overshot by 83us at the median and 300us at p99 on
// this project's Docker Desktop/WSL2 environment, so anything under a couple of hundred
// microseconds cannot be delivered by sleeping at all.
constexpr auto kPacingSpinGuard = std::chrono::microseconds(200);

std::int64_t nowNs() {
    return std::chrono::duration_cast<std::chrono::nanoseconds>(Clock::now().time_since_epoch())
        .count();
}

[[noreturn]] void fail(const std::string& what) {
    std::cerr << "ERROR: " << what << std::endl;
    std::exit(1);
}

// ---------------------------------------------------------------------------------------
// Idle strategies
//
// Hand-rolled rather than using aeron::concurrent::{BusySpin,Yielding,Sleeping}IdleStrategy.
// Aeron's own strategies are stateful objects whose constructor signatures have changed
// between releases (SleepingIdleStrategy in particular does not take a
// std::chrono::microseconds on the version pinned in the Dockerfile), which makes them a
// version-coupling for no benefit: the semantics below are the whole of what those classes
// do for this tool's purposes, and keeping them here means the idle behaviour being
// measured is visible in this file rather than in a dependency.
// ---------------------------------------------------------------------------------------

enum class IdleKind { Busy, Yield, Sleep };

IdleKind parseIdleKind(const std::string& name, const char* flag) {
    if (name == "busy") return IdleKind::Busy;
    if (name == "yield") return IdleKind::Yield;
    if (name == "sleep") return IdleKind::Sleep;
    fail(std::string(flag) + " must be 'busy', 'yield' or 'sleep' (got '" + name + "')");
}

inline void idleFor(IdleKind kind, int workCount, int sleepUs) {
    if (workCount > 0) return;  // made progress - do not back off
    switch (kind) {
        case IdleKind::Busy:
            break;  // deliberate: return immediately and poll again
        case IdleKind::Yield:
            std::this_thread::yield();
            break;
        case IdleKind::Sleep:
            std::this_thread::sleep_for(std::chrono::microseconds(sleepUs));
            break;
    }
}

// ---------------------------------------------------------------------------------------
// Options
// ---------------------------------------------------------------------------------------

struct Options {
    std::string measure = "throughput";  // throughput | latency | rtt
    std::string mode = "both";           // both | pub | sub

    // Channel construction. --channel overrides all of the transport/endpoint/mtu knobs and
    // is passed through verbatim, for URI features this tool does not model (multicast with
    // a specific control mode, MDC, session-id pinning, ...).
    std::string channel;
    std::string transport = "udp";  // udp | ipc | multicast
    std::string endpoint = "127.0.0.1:40456";
    std::string responseEndpoint = "127.0.0.1:40457";  // --measure rtt only
    std::string multicastInterface;                    // --transport multicast only
    std::string termLength;  // e.g. "16m"; empty = Aeron's default
    std::string mtu;         // e.g. "1408"; empty = Aeron's default
    bool reliable = true;    // false appends |reliable=false to SUBSCRIPTION channels

    std::int32_t streamId = 1001;
    std::uint32_t streamCount = 1;  // the analogue of dds_bench's --topic-count
    std::int32_t size = 128;

    // throughput: --msgs is the total across all publishers; --rate optionally caps it.
    // latency/rtt: --rate and --duration-sec are the axis and --msgs is rejected.
    std::uint64_t msgs = 200000;
    bool msgsGiven = false;
    double rate = 0.0;  // aggregate msgs/sec across all publishers; 0 = unthrottled
    double durationSec = 10.0;

    std::uint32_t pubCount = 1;  // publisher Aeron clients
    std::uint32_t subCount = 1;  // subscriber Aeron clients (the scalability axis)

    std::string publication = "exclusive";  // exclusive | concurrent
    std::string pollIdle = "busy";          // busy | yield | sleep
    int pollIdleSleepUs = 50;
    int fragmentLimit = 10;

    // How the publisher waits out each send interval - see dds_bench's identical knob.
    std::string pacing = "auto";  // auto | sleep | busy

    // Simulated per-message application work on the subscriber side. 0 = consume as fast as
    // possible. Under Aeron this does not cause loss (flow control holds the publisher
    // back); it converts into back-pressure on the publisher instead, which is precisely
    // the thing worth demonstrating.
    int subWorkUs = 0;

    std::string aeronDir;  // empty = Aeron's own default / $AERON_DIR
    std::string out = ".";

    int connectTimeoutSec = 30;
    int idleTimeoutSec = 5;  // subscriber gives up this long after the LAST message
    int timeoutSec = -1;     // hard cap; -1 = derived in parseArgs
    // Publisher-only processes must not exit the instant the last offer() returns: offer()
    // means "written to the term buffer", and the media driver in this container is stopped
    // when this process ends (docker/aeron-bench/entrypoint.sh). Without a linger, whatever
    // the driver had not yet put on the wire is lost, and it shows up as subscriber-side
    // message loss that has nothing to do with Aeron.
    double lingerSec = 2.0;
};

struct Sample {
    std::uint64_t seq;
    double latency_us;
};

// ---------------------------------------------------------------------------------------
// Channel URIs
//
// Aeron has no discovery: these strings ARE the addressing. Publication-side and
// subscription-side parameters are deliberately NOT the same set, because in Aeron they
// belong to different ends:
//   mtu, term-length  -> the publication decides them; the subscriber learns them from the
//                        setup frame.
//   reliable          -> the SUBSCRIPTION decides whether to NAK for lost data. Putting it
//                        on a publication URI is meaningless.
// Building one string for both ends would therefore either drop a parameter or attach it
// where it does nothing.
// ---------------------------------------------------------------------------------------

std::string buildChannel(const Options& opt, const std::string& endpoint, bool forSubscription) {
    if (!opt.channel.empty()) return opt.channel;

    std::string uri;
    std::vector<std::string> params;

    if (opt.transport == "ipc") {
        uri = "aeron:ipc";
    } else if (opt.transport == "udp") {
        uri = "aeron:udp";
        params.push_back("endpoint=" + endpoint);
    } else if (opt.transport == "multicast") {
        uri = "aeron:udp";
        params.push_back("endpoint=" + endpoint);
        if (opt.multicastInterface.empty()) {
            fail("--transport multicast requires --multicast-interface (e.g. 172.29.0.0/24). "
                 "Aeron will not guess which NIC to join the group on.");
        }
        params.push_back("interface=" + opt.multicastInterface);
    } else {
        fail("--transport must be 'udp', 'ipc' or 'multicast' (got '" + opt.transport + "')");
    }

    if (forSubscription) {
        // Only meaningful for UDP: aeron:ipc has no packets to lose and rejects the param.
        if (!opt.reliable && opt.transport != "ipc") params.push_back("reliable=false");
    } else {
        if (!opt.termLength.empty()) params.push_back("term-length=" + opt.termLength);
        if (!opt.mtu.empty() && opt.transport != "ipc") params.push_back("mtu=" + opt.mtu);
    }

    for (std::size_t i = 0; i < params.size(); ++i) {
        uri += (i == 0 ? "?" : "|");
        uri += params[i];
    }
    return uri;
}

// ---------------------------------------------------------------------------------------
// Publication wrapper
//
// ExclusivePublication and Publication have the same offer() shape but no common base, so
// this picks one at construction and dispatches. They are genuinely different things, not
// an implementation detail: Publication is safe for concurrent writers and pays a
// multi-producer claim protocol for it, ExclusivePublication assumes a single writer and
// skips it. Every publisher thread here owns its own publication, so `exclusive` is both
// the correct default and the configuration Aeron's own published numbers use.
// ---------------------------------------------------------------------------------------

class Pub {
public:
    Pub(std::shared_ptr<aeron::ExclusivePublication> p) : exclusive_(std::move(p)) {}
    Pub(std::shared_ptr<aeron::Publication> p) : concurrent_(std::move(p)) {}

    std::int64_t offer(const aeron::AtomicBuffer& buffer, aeron::util::index_t offset,
                       aeron::util::index_t length) {
        return exclusive_ ? exclusive_->offer(buffer, offset, length)
                          : concurrent_->offer(buffer, offset, length);
    }

    bool isConnected() const {
        return exclusive_ ? exclusive_->isConnected() : concurrent_->isConnected();
    }

private:
    std::shared_ptr<aeron::ExclusivePublication> exclusive_;
    std::shared_ptr<aeron::Publication> concurrent_;
};

// ---------------------------------------------------------------------------------------
// Receive side
//
// One Receiver per subscriber group, written only by that group's single poll thread, so
// the hot path takes no lock. `count_` is atomic because the main thread reads it while
// waiting (waitForReceipt); everything else is merged after the poll thread is joined.
// ---------------------------------------------------------------------------------------

class Receiver {
public:
    Receiver(bool keepSamples, std::uint64_t expectedSamples, int workUs)
        : keepSamples_(keepSamples), workUs_(workUs) {
        // Reserve up front: a vector growing to 100k entries reallocates ~17 times, each
        // copying the whole buffer, on the poll thread - i.e. on the exact path whose
        // throughput is being measured.
        if (keepSamples && expectedSamples > 0) {
            samples_.reserve(static_cast<std::size_t>(expectedSamples));
        }
    }

    void onFragment(const aeron::AtomicBuffer& buffer, aeron::util::index_t offset,
                    aeron::util::index_t length) {
        const std::int64_t recvNs = nowNs();
        const std::uint64_t n = count_.load(std::memory_order_relaxed);
        if (n == 0) firstNs_ = recvNs;
        lastNs_ = recvNs;
        count_.store(n + 1, std::memory_order_relaxed);
        bytes_ += static_cast<std::uint64_t>(length);

        std::uint64_t seq = 0;
        std::int64_t sendNs = 0;
        if (length >= kHeaderSize) {
            const std::uint8_t* src = buffer.buffer() + offset;
            std::memcpy(&seq, src, sizeof(seq));
            std::memcpy(&sendNs, src + sizeof(seq), sizeof(sendNs));
        }
        if (keepSamples_) {
            samples_.push_back({seq, static_cast<double>(recvNs - sendNs) / 1000.0});
        }

        // Per-second receive buckets: cheap, and the only way to tell whether a throughput
        // figure is a steady rate or an early burst followed by a stall.
        const auto bucket = static_cast<std::size_t>((recvNs - firstNs_) / 1000000000LL);
        if (buckets_.size() <= bucket) buckets_.resize(bucket + 1, 0);
        ++buckets_[bucket];

        // Simulated application work (--sub-work-us). Busy-spins rather than sleeping, so
        // it models a subscriber that is CPU-busy rather than one that has yielded. Because
        // this runs on the poll thread, it is exactly the knob that answers "how slow can my
        // application be before it starts back-pressuring the publisher?" - which, under
        // Aeron's always-on flow control, is the question, since it will not simply drop.
        if (workUs_ > 0) {
            const auto until = Clock::now() + std::chrono::microseconds(workUs_);
            while (Clock::now() < until) {
            }
        }
    }

    // Optional hook, used by the RTT echo side to re-publish what it just received.
    void setOnFragment(std::function<void(const aeron::AtomicBuffer&, aeron::util::index_t,
                                          aeron::util::index_t)>
                           fn) {
        onFragment_ = std::move(fn);
    }

    void dispatch(const aeron::AtomicBuffer& buffer, aeron::util::index_t offset,
                  aeron::util::index_t length) {
        if (onFragment_) onFragment_(buffer, offset, length);
        onFragment(buffer, offset, length);
    }

    std::uint64_t count() const { return count_.load(std::memory_order_relaxed); }
    std::uint64_t bytes() const { return bytes_; }
    std::int64_t firstNs() const { return firstNs_; }
    std::int64_t lastNs() const { return lastNs_; }
    const std::vector<Sample>& samples() const { return samples_; }
    const std::vector<std::uint64_t>& buckets() const { return buckets_; }

private:
    bool keepSamples_;
    int workUs_ = 0;
    std::atomic<std::uint64_t> count_{0};
    std::uint64_t bytes_ = 0;
    std::int64_t firstNs_ = 0;
    std::int64_t lastNs_ = 0;
    std::vector<Sample> samples_;
    std::vector<std::uint64_t> buckets_;
    std::function<void(const aeron::AtomicBuffer&, aeron::util::index_t, aeron::util::index_t)>
        onFragment_;
};

// ---------------------------------------------------------------------------------------
// One measurement participant: an Aeron client connection to the media driver, plus the
// publications and/or subscriptions created from it.
//
// One Aeron client per group, not one client with N endpoints, because the sweep in
// bench-scalability.sh is meant to model N independent subscriber APPLICATIONS. Each client
// is a separate registration with the driver and runs its own conductor thread, which is
// part of what is being measured.
// ---------------------------------------------------------------------------------------

struct Group {
    std::shared_ptr<aeron::Aeron> client;
    std::vector<std::unique_ptr<Pub>> pubs;
    std::vector<std::shared_ptr<aeron::Subscription>> subs;
    std::unique_ptr<Receiver> receiver;
    std::thread poller;
};

// ---------------------------------------------------------------------------------------
// Core accounting
//
// Deliberately not std::thread::hardware_concurrency(): libstdc++ implements it with
// sysconf(_SC_NPROCESSORS_ONLN), which reports the HOST's online CPUs and ignores container
// limits (confirmed in fast-dds/ - under `docker run --cpuset-cpus=0,1` it still reported
// 12). Since this tool only ever runs inside a container, that made the warning useless in
// exactly the situation it exists for.
//
//   sched_getaffinity : honours --cpuset-cpus (and taskset)
//   cgroup cpu quota  : honours --cpus / compose `cpus:` (v2 cpu.max, v1 cfs_quota_us)
//
// Returns the smaller of the two, or 0 when nothing can be determined.
// ---------------------------------------------------------------------------------------

unsigned availableCores() {
    unsigned fromAffinity = 0;
    cpu_set_t set;
    CPU_ZERO(&set);
    if (sched_getaffinity(0, sizeof(set), &set) == 0) {
        fromAffinity = static_cast<unsigned>(CPU_COUNT(&set));
    }

    unsigned fromQuota = 0;
    if (std::ifstream v2("/sys/fs/cgroup/cpu.max"); v2) {  // cgroup v2: "<quota> <period>"
        std::string quota;
        long period = 0;
        if (v2 >> quota >> period && quota != "max" && period > 0) {
            fromQuota = static_cast<unsigned>((std::stol(quota) + period - 1) / period);
        }
    } else if (std::ifstream q("/sys/fs/cgroup/cpu/cpu.cfs_quota_us"); q) {
        long quota = 0, period = 0;
        std::ifstream p("/sys/fs/cgroup/cpu/cpu.cfs_period_us");
        if (q >> quota && p && p >> period && quota > 0 && period > 0) {
            fromQuota = static_cast<unsigned>((quota + period - 1) / period);
        }
    }

    if (fromAffinity == 0) return fromQuota;
    if (fromQuota == 0) return fromAffinity;
    return std::min(fromAffinity, fromQuota);
}

// Every spinning thread occupies a whole core. Aeron makes this easy to get wrong because
// the spinners are not all yours: the media driver in DEDICATED threading mode runs three
// of its own (conductor, sender, receiver), each of which can spin, plus one conductor
// thread per Aeron client connection. Oversubscribe and the driver's threads get starved by
// the benchmark's own poll loops - which does not merely slow the result down, it can make
// the client declare the driver unresponsive and abort the run outright.
void warnIfSpinnersExceedCores(const Options& opt, unsigned pollThreads, unsigned pubThreads) {
    const bool pollSpins = (opt.pollIdle == "busy") && pollThreads > 0;
    const bool pubSpins = (opt.rate > 0.0 && opt.pacing != "sleep") && pubThreads > 0;
    if (!pollSpins && !pubSpins) return;

    const unsigned cores = availableCores();
    if (cores == 0) return;  // unknown; nothing useful to say

    const unsigned spinners = (pollSpins ? pollThreads : 0) + (pubSpins ? pubThreads : 0);
    const unsigned needed = spinners + 3;  // + the media driver's own three threads
    if (needed > cores) {
        std::cerr << "WARNING: this run wants " << spinners << " busy-spinning thread(s)"
                  << (pollSpins ? " (--poll-idle busy)" : "")
                  << (pubSpins ? " (--pacing " + opt.pacing + ")" : "")
                  << " plus the media driver's 3, but only " << cores
                  << " core(s) are available to this process. The spinners will starve the "
                     "driver's sender/receiver threads and inflate the latency being "
                     "measured; badly oversubscribed, the client can also time out against "
                     "the driver and abort. Use --poll-idle yield, --pacing sleep, a lower "
                     "--sub-count, or a machine with at least "
                  << needed << " cores." << std::endl;
    }
}

// ---------------------------------------------------------------------------------------
// Construction
// ---------------------------------------------------------------------------------------

// The C++ wrapper's Context does NOT pick up the AERON_DIR environment variable.
//
// Confirmed the hard way: entrypoint.sh starts aeronmd with AERON_DIR=/dev/shm/aeron, and
// the client still went looking in /dev/shm/aeron-root (its own built-in default,
// "aeron-<user>") and timed out with "CnC file not created". The driver honours the
// variable; the wrapper's default does not. Reading it here makes the two agree, and keeps
// AERON_DIR the single place the directory is configured.
std::string resolveAeronDir(const Options& opt) {
    if (!opt.aeronDir.empty()) return opt.aeronDir;
    const char* fromEnv = std::getenv("AERON_DIR");
    return (fromEnv != nullptr) ? std::string(fromEnv) : std::string();
}

std::shared_ptr<aeron::Aeron> connectClient(const Options& opt) {
    aeron::Context context;
    const std::string dir = resolveAeronDir(opt);
    if (!dir.empty()) context.aeronDir(dir);
    try {
        return aeron::Aeron::connect(context);
    } catch (const std::exception& e) {
        fail(std::string("could not connect to the Aeron media driver: ") + e.what() +
             "\n       Aeron is NOT daemonless - a media driver (aeronmd) must be running "
             "and sharing this process's AERON_DIR. In this project the driver is started "
             "by docker/aeron-bench/entrypoint.sh; outside it, start aeronmd yourself.");
    }
}

std::vector<std::int32_t> allStreamIds(const Options& opt) {
    std::vector<std::int32_t> ids;
    for (std::uint32_t i = 0; i < opt.streamCount; ++i) {
        ids.push_back(opt.streamId + static_cast<std::int32_t>(i));
    }
    return ids;
}

// add* returns a registration id immediately; the driver creates the endpoint
// asynchronously and find* returns null until it exists. Spinning on find* is the
// documented Aeron idiom, but it must be bounded - an unreachable aeron.dir or a driver
// that died mid-run would otherwise hang here forever with no output.
template <typename FindFn>
auto awaitEndpoint(FindFn find, const Options& opt, const char* what) {
    const auto deadline = Clock::now() + std::chrono::seconds(opt.connectTimeoutSec);
    auto handle = find();
    while (!handle) {
        if (Clock::now() > deadline) {
            fail(std::string("the media driver did not create the ") + what + " within " +
                 std::to_string(opt.connectTimeoutSec) + "s");
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
        handle = find();
    }
    return handle;
}

void createPubs(Group& group, const Options& opt, const std::string& channel,
                const std::vector<std::int32_t>& streams) {
    for (std::int32_t stream : streams) {
        if (opt.publication == "exclusive") {
            const std::int64_t id = group.client->addExclusivePublication(channel, stream);
            group.pubs.push_back(std::make_unique<Pub>(awaitEndpoint(
                [&] { return group.client->findExclusivePublication(id); }, opt, "publication")));
        } else if (opt.publication == "concurrent") {
            const std::int64_t id = group.client->addPublication(channel, stream);
            group.pubs.push_back(std::make_unique<Pub>(awaitEndpoint(
                [&] { return group.client->findPublication(id); }, opt, "publication")));
        } else {
            fail("--publication must be 'exclusive' or 'concurrent' (got '" + opt.publication +
                 "')");
        }
    }
}

void createSubs(Group& group, const Options& opt, const std::string& channel,
                const std::vector<std::int32_t>& streams) {
    for (std::int32_t stream : streams) {
        const std::int64_t id = group.client->addSubscription(channel, stream);
        group.subs.push_back(awaitEndpoint([&] { return group.client->findSubscription(id); }, opt,
                                           "subscription"));
    }
}

// Waits for every publication to report a connected subscriber. Aeron's analogue of DDS's
// on_publication_matched, and it matters for the same reason: offer() before a subscriber
// exists returns NOT_CONNECTED and sends nothing. It is at least LOUD about it, unlike
// BEST_EFFORT DDS which discards silently - but waiting first keeps the measurement clean.
bool awaitConnected(const std::vector<Group*>& groups, const Options& opt, bool publications) {
    const auto deadline = Clock::now() + std::chrono::seconds(opt.connectTimeoutSec);
    while (Clock::now() < deadline) {
        bool all = true;
        for (const Group* g : groups) {
            if (publications) {
                for (const auto& p : g->pubs) all = all && p->isConnected();
            } else {
                for (const auto& s : g->subs) all = all && s->isConnected();
            }
        }
        if (all) return true;
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    return false;
}

// ---------------------------------------------------------------------------------------
// Poll loop
// ---------------------------------------------------------------------------------------

// One FragmentAssembler per subscription, not one per thread: reassembly is keyed on the
// session id, and two subscriptions on different streams can legitimately see the same
// session id, which would splice two half-messages together.
void pollLoop(Group* group, const Options& opt, std::atomic<bool>* running) {
    const IdleKind idle = parseIdleKind(opt.pollIdle, "--poll-idle");
    Receiver* receiver = group->receiver.get();

    aeron::fragment_handler_t handler = [receiver](const aeron::AtomicBuffer& buffer,
                                                   aeron::util::index_t offset,
                                                   aeron::util::index_t length,
                                                   const aeron::Header&) {
        receiver->dispatch(buffer, offset, length);
    };

    std::vector<std::unique_ptr<aeron::FragmentAssembler>> assemblers;
    std::vector<aeron::fragment_handler_t> handlers;
    assemblers.reserve(group->subs.size());
    handlers.reserve(group->subs.size());
    for (std::size_t i = 0; i < group->subs.size(); ++i) {
        assemblers.push_back(std::make_unique<aeron::FragmentAssembler>(handler));
        handlers.push_back(assemblers.back()->handler());
    }

    while (running->load(std::memory_order_relaxed)) {
        int work = 0;
        for (std::size_t i = 0; i < group->subs.size(); ++i) {
            work += group->subs[i]->poll(handlers[i], opt.fragmentLimit);
        }
        idleFor(idle, work, opt.pollIdleSleepUs);
    }

    // Final drain: `running` is cleared by the main thread once it has decided the run is
    // over, and there can still be fragments sitting in the term buffer at that instant.
    for (int pass = 0; pass < 10; ++pass) {
        int work = 0;
        for (std::size_t i = 0; i < group->subs.size(); ++i) {
            work += group->subs[i]->poll(handlers[i], opt.fragmentLimit);
        }
        if (work == 0) break;
    }
}

// ---------------------------------------------------------------------------------------
// Publishing
// ---------------------------------------------------------------------------------------

// Waits until `target` according to the selected pacing strategy. See Options::pacing.
void pacedWaitUntil(Clock::time_point target, const std::string& pacing) {
    if (pacing == "sleep") {
        std::this_thread::sleep_until(target);
        return;
    }
    if (pacing != "busy") {  // "auto": give the OS everything except the guard window
        const auto spinFrom = target - kPacingSpinGuard;
        if (Clock::now() < spinFrom) std::this_thread::sleep_until(spinFrom);
    }
    while (Clock::now() < target) {
        // Deliberate busy spin - see Options::pacing.
    }
}

struct PubResult {
    std::uint64_t sent = 0;
    double durationSec = 0.0;  // the send loop only
    double lingerSec = 0.0;    // publisher-only mode: drain time before stopping the driver
    std::uint64_t bytes = 0;
    std::uint64_t backPressured = 0;   // offer() returned BACK_PRESSURED and was retried
    std::uint64_t notConnected = 0;    // offer() returned NOT_CONNECTED and was retried
    std::uint64_t adminAction = 0;     // offer() hit a term rotation and was retried
    double backPressureSec = 0.0;      // wall time spent retrying, aggregated
};

struct PubCounters {
    std::atomic<std::uint64_t> backPressured{0};
    std::atomic<std::uint64_t> notConnected{0};
    std::atomic<std::uint64_t> adminAction{0};
    std::atomic<std::int64_t> retryNs{0};
};

// Offers one message, retrying the recoverable negative returns.
//
// This retry loop is not boilerplate - it is Aeron's flow control, and how it is written
// decides what the benchmark measures. Two decisions:
//
//  * The seq/timestamp header is rewritten before EVERY attempt, so a message delayed by
//    back-pressure carries the timestamp of the attempt that actually got through. The
//    reported latency is therefore transport latency, not transport latency plus the
//    publisher's own wait for a window - the same distinction dds_bench draws by timing
//    wait_for_acknowledgments separately from the send loop. The wait is not hidden: it is
//    counted and reported as back_pressure_events / back_pressure_sec, and a latency run
//    that back-pressured at all is one whose requested rate was not delivered.
//  * NOT_CONNECTED is retried rather than counted as a send. It means no subscriber exists,
//    so nothing left the process; counting it would inflate msgs_sent and manufacture
//    "message loss" out of messages that were never on the wire.
//
// Returns false if the deadline passed without the message getting through.
bool offerWithRetry(Pub& pub, aeron::AtomicBuffer& buffer, std::int32_t length,
                    std::uint64_t seq, PubCounters& counters, Clock::time_point deadline) {
    bool retried = false;
    const auto retryStart = Clock::now();
    while (true) {
        const std::int64_t ts = nowNs();
        std::memcpy(buffer.buffer(), &seq, sizeof(seq));
        std::memcpy(buffer.buffer() + sizeof(seq), &ts, sizeof(ts));

        const std::int64_t result = pub.offer(buffer, 0, length);
        if (result > 0) {
            if (retried) {
                counters.retryNs.fetch_add(
                    std::chrono::duration_cast<std::chrono::nanoseconds>(Clock::now() - retryStart)
                        .count(),
                    std::memory_order_relaxed);
            }
            return true;
        }

        if (result == aeron::BACK_PRESSURED) {
            counters.backPressured.fetch_add(1, std::memory_order_relaxed);
        } else if (result == aeron::NOT_CONNECTED) {
            counters.notConnected.fetch_add(1, std::memory_order_relaxed);
        } else if (result == aeron::ADMIN_ACTION) {
            // A term buffer rotation. Always transient, always safe to retry immediately.
            counters.adminAction.fetch_add(1, std::memory_order_relaxed);
        } else if (result == aeron::PUBLICATION_CLOSED) {
            fail("offer() returned PUBLICATION_CLOSED - the publication was closed mid-run");
        } else if (result == aeron::MAX_POSITION_EXCEEDED) {
            fail("offer() returned MAX_POSITION_EXCEEDED - the term buffer position wrapped. "
                 "Raise --term-length.");
        } else {
            fail("offer() returned an unexpected value: " + std::to_string(result));
        }

        retried = true;
        if (Clock::now() > deadline) return false;
        std::this_thread::yield();
    }
}

// Publishes `total` messages across `groups` (one group = one Aeron client with one
// publication per stream), round-robin over that group's streams, at an aggregate rate of
// opt.rate msgs/sec (0 = unthrottled). Sequence numbers come from a shared atomic so they
// stay globally unique across publisher threads.
PubResult publishAll(const std::vector<Group*>& groups, const Options& opt, std::uint64_t total) {
    std::atomic<std::uint64_t> nextSeq{0};
    std::atomic<std::uint64_t> delivered{0};
    PubCounters counters;
    const auto groupCount = static_cast<std::uint64_t>(groups.size());
    const auto start = Clock::now();
    const auto deadline = start + std::chrono::seconds(opt.timeoutSec);

    std::vector<std::thread> threads;
    threads.reserve(groups.size());
    for (std::uint64_t g = 0; g < groupCount; ++g) {
        // Each thread takes an equal share; the last absorbs the remainder so the total is
        // exactly `total` regardless of divisibility.
        const std::uint64_t share =
            total / groupCount + ((g == groupCount - 1) ? total % groupCount : 0);
        threads.emplace_back([&, g, share]() {
            Group* group = groups[g];
            std::vector<std::uint8_t> bytes(static_cast<std::size_t>(opt.size), 0);
            aeron::AtomicBuffer buffer(bytes.data(), bytes.size());

            // Per-thread interval for a target AGGREGATE rate: each of the N publisher
            // threads must therefore wait N times longer than 1/rate.
            const bool paced = opt.rate > 0.0;
            const auto interval = std::chrono::duration<double>(
                paced ? (static_cast<double>(groupCount) / opt.rate) : 0.0);

            std::uint64_t sent = 0;
            for (std::uint64_t i = 0; i < share; ++i) {
                const auto sendStart = Clock::now();
                const std::uint64_t seq = nextSeq.fetch_add(1);
                Pub& pub = *group->pubs[i % group->pubs.size()];
                if (!offerWithRetry(pub, buffer, opt.size, seq, counters, deadline)) {
                    std::cerr << "WARNING: publisher " << g << " gave up on message " << seq
                              << " after the run's hard timeout; " << (share - i)
                              << " message(s) not sent." << std::endl;
                    break;
                }
                ++sent;
                if (paced) {
                    pacedWaitUntil(
                        sendStart + std::chrono::duration_cast<Clock::duration>(interval),
                        opt.pacing);
                }
            }
            delivered.fetch_add(sent, std::memory_order_relaxed);
        });
    }
    for (auto& t : threads) t.join();
    const auto sendEnd = Clock::now();

    PubResult result;
    result.sent = delivered.load();
    result.durationSec = std::chrono::duration<double>(sendEnd - start).count();
    result.bytes = result.sent * static_cast<std::uint64_t>(opt.size);
    result.backPressured = counters.backPressured.load();
    result.notConnected = counters.notConnected.load();
    result.adminAction = counters.adminAction.load();
    result.backPressureSec = static_cast<double>(counters.retryNs.load()) / 1e9;

    // A run that asked for one rate and delivered another has measured a condition it does
    // not report. Confirmed to happen silently on the Fast DDS side of this repo (a
    // requested 10000/s achieved ~5500/s under sleep-based pacing), so say it out loud
    // rather than leaving it to be spotted in result.json.
    if (opt.rate > 0.0 && result.durationSec > 0.0) {
        const double achieved = static_cast<double>(result.sent) / result.durationSec;
        if (achieved < opt.rate * 0.9) {
            std::cerr << "WARNING: requested --rate " << opt.rate << " msgs/sec but only achieved "
                      << achieved << ". The measured latency belongs to the achieved rate, not "
                      << "the requested one.";
            if (result.backPressured > 0) {
                std::cerr << " " << result.backPressured
                          << " back-pressure event(s): the SUBSCRIBER could not keep up, so this "
                             "rate is not achievable end to end regardless of pacing.";
            } else if (opt.pacing == "sleep") {
                std::cerr << " --pacing sleep cannot hit short intervals; try --pacing auto.";
            } else {
                std::cerr << " The publisher cannot keep up at this rate on this machine.";
            }
            std::cerr << std::endl;
        }
    }
    if (opt.measure != "throughput" && result.backPressured > 0) {
        std::cerr << "NOTE: " << result.backPressured << " back-pressure event(s) during a "
                  << opt.measure
                  << " run (" << result.backPressureSec
                  << "s total). Reported latency is transport-only and EXCLUDES that wait - see "
                     "metrics.pub.back_pressure_sec, and treat the achieved rate, not the "
                     "requested one, as the condition measured."
                  << std::endl;
    }
    return result;
}

// ---------------------------------------------------------------------------------------
// Receive-side aggregation
// ---------------------------------------------------------------------------------------

struct SubResult {
    std::uint64_t received = 0;
    std::uint64_t bytes = 0;
    double durationSec = 0.0;
    std::vector<Sample> samples;
    std::vector<std::uint64_t> buckets;
};

std::uint64_t totalReceived(const std::vector<Group*>& groups) {
    std::uint64_t sum = 0;
    for (const Group* g : groups) {
        if (g->receiver) sum += g->receiver->count();
    }
    return sum;
}

SubResult collect(const std::vector<Group*>& groups) {
    SubResult result;
    std::int64_t first = 0;
    std::int64_t last = 0;
    for (const Group* g : groups) {
        const Receiver* r = g->receiver.get();
        if (r == nullptr || r->count() == 0) continue;
        result.received += r->count();
        result.bytes += r->bytes();
        if (first == 0 || r->firstNs() < first) first = r->firstNs();
        if (r->lastNs() > last) last = r->lastNs();

        result.samples.insert(result.samples.end(), r->samples().begin(), r->samples().end());
        const auto& buckets = r->buckets();
        if (result.buckets.size() < buckets.size()) result.buckets.resize(buckets.size(), 0);
        for (std::size_t i = 0; i < buckets.size(); ++i) result.buckets[i] += buckets[i];
    }
    if (last > first) result.durationSec = static_cast<double>(last - first) / 1e9;
    return result;
}

// Waits until `expected` messages have arrived, or until nothing new has arrived for
// idleTimeoutSec, or until the hard timeout.
//
// The idle check earns its keep less often here than it did under Fast DDS BEST_EFFORT,
// where loss was the expected outcome and "wait for the full count" would always run to the
// hard timeout. Aeron's flow control means a healthy run does reach the full count. It still
// matters for the cases where it does not: --reliable no, a publisher that gave up, or a
// cross-container run whose peer died.
void waitForReceipt(const std::vector<Group*>& groups, std::uint64_t expected,
                    const Options& opt) {
    const auto hardDeadline = Clock::now() + std::chrono::seconds(opt.timeoutSec);
    auto lastProgress = Clock::now();
    std::uint64_t lastCount = 0;

    while (Clock::now() < hardDeadline) {
        const std::uint64_t current = totalReceived(groups);
        if (current >= expected) return;
        if (current != lastCount) {
            lastCount = current;
            lastProgress = Clock::now();
        } else if (current > 0 &&
                   Clock::now() - lastProgress > std::chrono::seconds(opt.idleTimeoutSec)) {
            return;  // stream went quiet
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
    }
}

// ---------------------------------------------------------------------------------------
// Statistics / output
// ---------------------------------------------------------------------------------------

struct LatencyStats {
    double min = 0, avg = 0, p50 = 0, p90 = 0, p95 = 0, p99 = 0, p999 = 0, max = 0, stddev = 0;
    bool valid = false;
};

double percentile(const std::vector<double>& sorted, double p) {
    if (sorted.empty()) return 0.0;
    std::size_t idx = static_cast<std::size_t>(std::ceil(p / 100.0 * sorted.size()));
    idx = (idx == 0) ? 0 : idx - 1;
    return sorted[std::min(idx, sorted.size() - 1)];
}

LatencyStats computeStats(std::vector<double> latencies) {
    LatencyStats st;
    if (latencies.empty()) return st;
    std::sort(latencies.begin(), latencies.end());
    st.valid = true;
    st.min = latencies.front();
    st.max = latencies.back();
    double sum = 0.0;
    for (double v : latencies) sum += v;
    st.avg = sum / latencies.size();
    double sq = 0.0;
    for (double v : latencies) sq += (v - st.avg) * (v - st.avg);
    st.stddev = std::sqrt(sq / latencies.size());
    st.p50 = percentile(latencies, 50);
    st.p90 = percentile(latencies, 90);
    st.p95 = percentile(latencies, 95);
    st.p99 = percentile(latencies, 99);
    st.p999 = percentile(latencies, 99.9);
    return st;
}

void writeSampleCsv(const std::string& path, const std::string& valueColumn,
                    std::vector<Sample> samples) {
    std::sort(samples.begin(), samples.end(),
              [](const Sample& a, const Sample& b) { return a.seq < b.seq; });
    std::ofstream csv(path);
    csv << "Seq," << valueColumn << "\n";
    for (const auto& s : samples) csv << s.seq << "," << s.latency_us << "\n";
}

void writeBucketCsv(const std::string& path, const std::vector<std::uint64_t>& buckets,
                    std::int32_t size) {
    std::ofstream csv(path);
    csv << "Second,MsgsReceived,BytesReceived\n";
    for (std::size_t i = 0; i < buckets.size(); ++i) {
        csv << i << "," << buckets[i] << ","
            << (buckets[i] * static_cast<std::uint64_t>(size)) << "\n";
    }
}

std::string jsonEscape(const std::string& s) {
    std::string out;
    for (char c : s) {
        if (c == '"' || c == '\\') out += '\\';
        out += c;
    }
    return out;
}

std::string paramsJson(const Options& opt, std::uint64_t totalMsgs, const std::string& pubChannel,
                       const std::string& subChannel) {
    std::ostringstream j;
    j << "    \"channel_pub\": \"" << jsonEscape(pubChannel) << "\",\n"
      << "    \"channel_sub\": \"" << jsonEscape(subChannel) << "\",\n"
      << "    \"transport\": \"" << opt.transport << "\",\n"
      << "    \"stream_id\": " << opt.streamId << ",\n"
      << "    \"stream_count\": " << opt.streamCount << ",\n"
      << "    \"size\": " << opt.size << ",\n"
      << "    \"msgs\": " << totalMsgs << ",\n"
      << "    \"rate\": " << opt.rate << ",\n"
      << "    \"duration_sec\": " << opt.durationSec << ",\n"
      << "    \"pub_count\": " << opt.pubCount << ",\n"
      << "    \"sub_count\": " << opt.subCount << ",\n"
      << "    \"reliable\": " << (opt.reliable ? "true" : "false") << ",\n"
      << "    \"publication\": \"" << opt.publication << "\",\n"
      << "    \"poll_idle\": \"" << opt.pollIdle << "\",\n"
      << "    \"poll_idle_sleep_us\": " << opt.pollIdleSleepUs << ",\n"
      << "    \"fragment_limit\": " << opt.fragmentLimit << ",\n"
      << "    \"term_length\": \"" << opt.termLength << "\",\n"
      << "    \"mtu\": \"" << opt.mtu << "\",\n"
      << "    \"pacing\": \"" << opt.pacing << "\",\n"
      << "    \"sub_work_us\": " << opt.subWorkUs << ",\n"
      << "    \"linger_sec\": " << opt.lingerSec;
    return j.str();
}

std::string environmentJson() {
    std::ostringstream j;
    // The media driver's own configuration is set by environment variable, not through the
    // client, so it is read back from the environment rather than queried. Both of these
    // belong in a result file: the idle strategy alone moved measured p50 latency by 8-14x on
    // this project's first runs (245-331us backoff vs 21-41us noop), which makes a result.json
    // without it unreadable after the fact.
    const char* threading = std::getenv("AERON_THREADING_MODE");
    const char* idle = std::getenv("AERON_SENDER_IDLE_STRATEGY");
    j << "    \"aeron_bench_version\": \"" << kToolVersion << "\",\n"
      << "    \"aeron_version\": \"" << AERON_BENCH_AERON_VERSION << "\",\n"
      << "    \"driver_threading_mode\": \"" << (threading != nullptr ? threading : "default")
      << "\",\n"
      << "    \"driver_idle_strategy\": \"" << (idle != nullptr ? idle : "default") << "\",\n"
      << "    \"runtime\": \"CentOS 7 / gcc 11 / C++17\"";
    return j.str();
}

// result.json deliberately mirrors nats/'s and fast-dds/'s schema - same key names, same
// units (latency in microseconds, throughput in msgs/sec and MB/sec, msg_loss at the top
// level) - so results/run-index.csv rows from the three projects line up column for column.
// The Aeron-only fields live under metrics.pub, where extra keys cost nothing.
void writeResultJson(const Options& opt, std::uint64_t totalMsgs, const std::string& pubChannel,
                     const std::string& subChannel, const PubResult* pub, const SubResult* sub,
                     const LatencyStats* latency, std::uint64_t msgsSent,
                     std::uint64_t msgsReceived, std::uint64_t msgLoss) {
    std::ostringstream j;
    j << "{\n"
      << "  \"mode\": \"" << opt.mode << "\",\n"
      << "  \"measure\": \"" << opt.measure << "\",\n"
      << "  \"params\": {\n"
      << paramsJson(opt, totalMsgs, pubChannel, subChannel) << "\n"
      << "  },\n"
      << "  \"environment\": {\n"
      << environmentJson() << "\n"
      << "  },\n"
      << "  \"metrics\": {\n";

    bool needComma = false;
    if (latency != nullptr && latency->valid) {
        j << "    \"latency_us\": {\n"
          << "      \"min\": " << latency->min << ",\n"
          << "      \"avg\": " << latency->avg << ",\n"
          << "      \"p50\": " << latency->p50 << ",\n"
          << "      \"p90\": " << latency->p90 << ",\n"
          << "      \"p95\": " << latency->p95 << ",\n"
          << "      \"p99\": " << latency->p99 << ",\n"
          << "      \"p99_9\": " << latency->p999 << ",\n"
          << "      \"max\": " << latency->max << ",\n"
          << "      \"stddev\": " << latency->stddev << "\n"
          << "    }";
        needComma = true;
    }
    if (pub != nullptr) {
        if (needComma) j << ",\n";
        const double mps = pub->durationSec > 0 ? pub->sent / pub->durationSec : 0.0;
        const double mbps =
            pub->durationSec > 0 ? (pub->bytes / pub->durationSec) / 1048576.0 : 0.0;
        j << "    \"pub\": { \"msgs_per_sec\": " << mps << ", \"mb_per_sec\": " << mbps
          << ", \"duration_sec\": " << pub->durationSec
          << ", \"back_pressure_events\": " << pub->backPressured
          << ", \"back_pressure_sec\": " << pub->backPressureSec
          << ", \"not_connected_events\": " << pub->notConnected
          << ", \"admin_action_events\": " << pub->adminAction
          << ", \"linger_sec\": " << pub->lingerSec << " }";
        needComma = true;
    }
    if (sub != nullptr) {
        if (needComma) j << ",\n";
        const double mps = sub->durationSec > 0 ? sub->received / sub->durationSec : 0.0;
        const double mbps =
            sub->durationSec > 0 ? (sub->bytes / sub->durationSec) / 1048576.0 : 0.0;
        j << "    \"sub\": { \"msgs_per_sec\": " << mps << ", \"mb_per_sec\": " << mbps
          << ", \"duration_sec\": " << sub->durationSec << " }";
        needComma = true;
    }
    if (needComma) j << ",\n";
    j << "    \"msg_loss\": " << msgLoss << "\n"
      << "  },\n"
      << "  \"msgs_sent\": " << msgsSent << ",\n"
      << "  \"msgs_received\": " << msgsReceived << ",\n"
      << "  \"msg_loss\": " << msgLoss << "\n"
      << "}\n";

    std::ofstream out(opt.out + "/result.json");
    out << j.str();
}

// ---------------------------------------------------------------------------------------
// Argument parsing
// ---------------------------------------------------------------------------------------

Options parseArgs(int argc, char** argv) {
    Options opt;
    for (int i = 1; i < argc; ++i) {
        const std::string arg = argv[i];
        auto next = [&](const char* flag) -> std::string {
            if (i + 1 >= argc) fail(std::string("missing value for ") + flag);
            return argv[++i];
        };
        if (arg == "--measure") opt.measure = next("--measure");
        else if (arg == "--mode") opt.mode = next("--mode");
        else if (arg == "--channel") opt.channel = next("--channel");
        else if (arg == "--transport") opt.transport = next("--transport");
        else if (arg == "--endpoint") opt.endpoint = next("--endpoint");
        else if (arg == "--response-endpoint") opt.responseEndpoint = next("--response-endpoint");
        else if (arg == "--multicast-interface") opt.multicastInterface = next("--multicast-interface");
        else if (arg == "--term-length") opt.termLength = next("--term-length");
        else if (arg == "--mtu") opt.mtu = next("--mtu");
        else if (arg == "--reliable") {
            const std::string v = next("--reliable");
            if (v == "yes" || v == "true") opt.reliable = true;
            else if (v == "no" || v == "false") opt.reliable = false;
            else fail("--reliable must be 'yes' or 'no' (got '" + v + "')");
        }
        else if (arg == "--stream-id") opt.streamId = std::stoi(next("--stream-id"));
        else if (arg == "--stream-count") opt.streamCount = std::stoul(next("--stream-count"));
        else if (arg == "--size") opt.size = std::stoi(next("--size"));
        else if (arg == "--msgs") { opt.msgs = std::stoull(next("--msgs")); opt.msgsGiven = true; }
        else if (arg == "--rate") opt.rate = std::stod(next("--rate"));
        else if (arg == "--duration-sec") opt.durationSec = std::stod(next("--duration-sec"));
        else if (arg == "--pub-count") opt.pubCount = std::stoul(next("--pub-count"));
        else if (arg == "--sub-count") opt.subCount = std::stoul(next("--sub-count"));
        else if (arg == "--publication") opt.publication = next("--publication");
        else if (arg == "--poll-idle") opt.pollIdle = next("--poll-idle");
        else if (arg == "--poll-idle-sleep-us") opt.pollIdleSleepUs = std::stoi(next("--poll-idle-sleep-us"));
        else if (arg == "--fragment-limit") opt.fragmentLimit = std::stoi(next("--fragment-limit"));
        else if (arg == "--pacing") opt.pacing = next("--pacing");
        else if (arg == "--sub-work-us") opt.subWorkUs = std::stoi(next("--sub-work-us"));
        else if (arg == "--aeron-dir") opt.aeronDir = next("--aeron-dir");
        else if (arg == "--out") opt.out = next("--out");
        else if (arg == "--connect-timeout-sec") opt.connectTimeoutSec = std::stoi(next("--connect-timeout-sec"));
        else if (arg == "--idle-timeout-sec") opt.idleTimeoutSec = std::stoi(next("--idle-timeout-sec"));
        else if (arg == "--timeout-sec") opt.timeoutSec = std::stoi(next("--timeout-sec"));
        else if (arg == "--linger-sec") opt.lingerSec = std::stod(next("--linger-sec"));
        else fail("unknown argument: " + arg);
    }

    if (opt.measure != "throughput" && opt.measure != "latency" && opt.measure != "rtt") {
        fail("--measure must be one of: throughput, latency, rtt (got '" + opt.measure + "')");
    }
    if (opt.mode != "both" && opt.mode != "pub" && opt.mode != "sub") {
        fail("--mode must be one of: both, pub, sub (got '" + opt.mode + "')");
    }
    if (opt.size < kHeaderSize) {
        fail("--size must be >= " + std::to_string(kHeaderSize) +
             " bytes (room for the seq + timestamp header)");
    }
    if (opt.streamCount < 1) fail("--stream-count must be >= 1");
    if (opt.pubCount < 1) fail("--pub-count must be >= 1");
    if (opt.subCount < 1) fail("--sub-count must be >= 1");
    if (opt.fragmentLimit < 1) fail("--fragment-limit must be >= 1");
    parseIdleKind(opt.pollIdle, "--poll-idle");  // validate early, not on the poll thread
    if (opt.publication != "exclusive" && opt.publication != "concurrent") {
        fail("--publication must be 'exclusive' or 'concurrent' (got '" + opt.publication + "')");
    }
    if (opt.pacing != "auto" && opt.pacing != "sleep" && opt.pacing != "busy") {
        fail("--pacing must be 'auto', 'sleep' or 'busy' (got '" + opt.pacing + "')");
    }
    if (opt.measure == "rtt" && opt.transport == "multicast") {
        fail("--measure rtt needs a distinct response channel per side; use --transport udp "
             "(or --transport ipc for a same-container run).");
    }

    if (opt.measure == "latency" || opt.measure == "rtt") {
        // Same rule as nats/tools/latency_oneway and fast-dds/tools/dds_bench: rate and
        // duration are the axis, the message count is derived.
        if (opt.msgsGiven) {
            fail("--msgs is not accepted with --measure " + opt.measure +
                 " - use --rate and --duration-sec; the total count is derived as "
                 "round(rate * duration).");
        }
        if (opt.rate <= 0.0) {
            fail("--rate is required and must be > 0 (target msgs/sec) with --measure " +
                 opt.measure +
                 ". There is deliberately no 'burst as fast as possible' latency mode: an "
                 "unthrottled send measures the queueing delay of a backlog the publisher "
                 "built up, not the middleware's steady-state latency.");
        }
        if (opt.durationSec <= 0.0) fail("--duration-sec must be > 0");
        opt.msgs = static_cast<std::uint64_t>(std::llround(opt.rate * opt.durationSec));
        if (opt.msgs == 0) opt.msgs = 1;
    }

    if (opt.timeoutSec < 0) {
        const double nominal =
            (opt.rate > 0.0) ? (static_cast<double>(opt.msgs) / opt.rate) : opt.durationSec;
        opt.timeoutSec = static_cast<int>(std::ceil(nominal)) + opt.connectTimeoutSec + 30;
    }
    return opt;
}

// ---------------------------------------------------------------------------------------
// Runners
// ---------------------------------------------------------------------------------------

void startPolling(std::vector<Group*>& groups, const Options& opt, std::atomic<bool>& running) {
    for (Group* g : groups) g->poller = std::thread(pollLoop, g, std::cref(opt), &running);
}

void stopPolling(std::vector<Group*>& groups, std::atomic<bool>& running) {
    running.store(false, std::memory_order_relaxed);
    for (Group* g : groups) {
        if (g->poller.joinable()) g->poller.join();
    }
}

// throughput and latency share the whole pipeline; they differ only in pacing (enforced in
// parseArgs), whether per-message samples are retained, and which metrics get reported.
int runPubSub(const Options& opt) {
    const bool keepSamples = (opt.measure == "latency");
    const auto streams = allStreamIds(opt);
    const std::uint64_t totalMsgs = opt.msgs;
    const std::string pubChannel = buildChannel(opt, opt.endpoint, false);
    const std::string subChannel = buildChannel(opt, opt.endpoint, true);

    const bool runSub = (opt.mode == "both" || opt.mode == "sub");
    const bool runPub = (opt.mode == "both" || opt.mode == "pub");

    warnIfSpinnersExceedCores(opt, runSub ? opt.subCount : 0, runPub ? opt.pubCount : 0);

    std::vector<std::unique_ptr<Group>> owned;
    std::vector<Group*> pubGroups;
    std::vector<Group*> subGroups;

    // Subscribers first, always: a publication whose subscriber does not exist yet reports
    // NOT_CONNECTED, and while that is loud rather than silent, it is still a wait.
    if (runSub) {
        for (std::uint32_t s = 0; s < opt.subCount; ++s) {
            owned.push_back(std::make_unique<Group>());
            Group* g = owned.back().get();
            g->client = connectClient(opt);
            createSubs(*g, opt, subChannel, streams);
            g->receiver = std::make_unique<Receiver>(keepSamples, totalMsgs, opt.subWorkUs);
            subGroups.push_back(g);
        }
    }
    if (runPub) {
        for (std::uint32_t p = 0; p < opt.pubCount; ++p) {
            owned.push_back(std::make_unique<Group>());
            Group* g = owned.back().get();
            g->client = connectClient(opt);
            createPubs(*g, opt, pubChannel, streams);
            pubGroups.push_back(g);
        }
    }

    std::atomic<bool> running{true};
    startPolling(subGroups, opt, running);

    int exitCode = 0;
    if (!pubGroups.empty()) {
        std::cerr << "aeron_bench: waiting for publications to connect on " << pubChannel
                  << " ..." << std::endl;
        if (!awaitConnected(pubGroups, opt, true)) {
            std::cerr << "ERROR: no subscriber connected within " << opt.connectTimeoutSec
                      << "s. Aeron has no discovery: check that the subscriber side is running "
                         "and that its channel endpoint is exactly the address this publisher "
                         "is sending to ("
                      << pubChannel << ")." << std::endl;
            exitCode = 1;
        }
    }
    if (!subGroups.empty() && opt.mode == "sub") {
        std::cerr << "aeron_bench: waiting for subscriptions to connect on " << subChannel
                  << " ..." << std::endl;
        if (!awaitConnected(subGroups, opt, false)) {
            std::cerr << "ERROR: no publisher connected within " << opt.connectTimeoutSec
                      << "s." << std::endl;
            exitCode = 1;
        }
    }

    PubResult pub;
    SubResult sub;
    if (exitCode == 0 && !pubGroups.empty()) {
        pub = publishAll(pubGroups, opt, totalMsgs);
    }
    if (exitCode == 0 && !subGroups.empty()) {
        // Fan-out, exactly as on the NATS and Fast DDS sides: every subscriber client holds
        // its own subscription per stream, so each receives a full copy of the stream.
        waitForReceipt(subGroups, totalMsgs * opt.subCount, opt);
    } else if (exitCode == 0 && opt.lingerSec > 0.0) {
        // Publisher-only process: see Options::lingerSec. offer() returning success means
        // "in the term buffer", and this container's media driver dies with this process.
        const auto lingerStart = Clock::now();
        std::this_thread::sleep_for(std::chrono::duration<double>(opt.lingerSec));
        pub.lingerSec = std::chrono::duration<double>(Clock::now() - lingerStart).count();
    }

    stopPolling(subGroups, running);
    if (!subGroups.empty()) sub = collect(subGroups);

    const std::uint64_t expectedDeliveries = totalMsgs * opt.subCount;
    const std::uint64_t msgsReceived = sub.received;
    std::uint64_t msgLoss = 0;
    if (!subGroups.empty()) {
        msgLoss = (expectedDeliveries > msgsReceived) ? (expectedDeliveries - msgsReceived) : 0;
    }

    LatencyStats stats;
    if (keepSamples && !sub.samples.empty()) {
        std::vector<double> values;
        values.reserve(sub.samples.size());
        for (const auto& s : sub.samples) values.push_back(s.latency_us);
        stats = computeStats(std::move(values));
        writeSampleCsv(opt.out + "/oneway.csv", "LatencyMicros", sub.samples);
    }
    if (opt.measure == "throughput" && !subGroups.empty()) {
        writeBucketCsv(opt.out + "/throughput.csv", sub.buckets, opt.size);
    }

    writeResultJson(opt, totalMsgs, pubChannel, subChannel, pubGroups.empty() ? nullptr : &pub,
                    subGroups.empty() ? nullptr : &sub, keepSamples ? &stats : nullptr,
                    pubGroups.empty() ? 0 : pub.sent, msgsReceived, msgLoss);

    std::cout << "measure=" << opt.measure << " mode=" << opt.mode
              << " msgs_sent=" << (pubGroups.empty() ? 0 : pub.sent)
              << " msgs_received=" << msgsReceived << " expected=" << expectedDeliveries
              << " msg_loss=" << msgLoss;
    if (!pubGroups.empty()) std::cout << " back_pressure=" << pub.backPressured;
    if (stats.valid) std::cout << " p50_us=" << stats.p50 << " p99_us=" << stats.p99;
    if (!subGroups.empty() && sub.durationSec > 0) {
        std::cout << " sub_msgs_per_sec=" << (sub.received / sub.durationSec);
    }
    std::cout << std::endl;

    // A publisher that never back-pressured and finished far ahead of its subscriber did
    // not measure throughput - it measured how fast a term buffer can be filled.
    //
    // This is Aeron-specific and it bites at exactly the message counts a benchmark
    // naturally picks. Measured here: 50000 x 128B with a slow subscriber (--sub-work-us
    // 20) reported pub 1.61M msgs/s against sub 48k msgs/s with ZERO back-pressure, because
    // the whole 6.4MB fit inside the publication window and offer() never had to wait. The
    // same run with --term-length 64k produced 1.49M back-pressure events and a publisher
    // rate that converged on the subscriber's ~47k/s - the real number.
    //
    // Nothing about the first run is a bug; the figure is just not the figure it looks
    // like. Say so, rather than leaving a 30x discrepancy in result.json to be explained
    // later by whoever reads it.
    if (opt.measure == "throughput" && !pubGroups.empty() && !subGroups.empty() &&
        pub.backPressured == 0 && pub.durationSec > 0 && sub.durationSec > 0) {
        const double pubRate = static_cast<double>(pub.sent) / pub.durationSec;
        const double subRate = static_cast<double>(sub.received) / sub.durationSec;
        if (pubRate > subRate * 2.0) {
            std::cerr << "WARNING: the publisher finished " << (pubRate / subRate)
                      << "x faster than the subscriber drained, with no back-pressure at all. "
                         "The whole run fit inside the publication window, so pub.msgs_per_sec "
                         "("
                      << pubRate
                      << ") is the rate a term buffer can be FILLED, not a sustainable "
                         "throughput. Raise --msgs or lower --term-length until back-pressure "
                         "appears; sub.msgs_per_sec ("
                      << subRate << ") is the meaningful number as it stands." << std::endl;
        }
    }

    // Loss rules, and how they differ from the other two projects.
    //
    // NATS Core runs over TCP: any loss means something broke. Fast DDS under BEST_EFFORT is
    // DEFINED to drop what a subscriber cannot keep up with, so loss there is expected and
    // is not a failure. Aeron is a third case: flow control is always on and receiver-driven,
    // so a publisher outrunning its subscriber gets back-pressured rather than dropping.
    // Under the default (reliable, NAK-based retransmission) any loss at all is therefore a
    // real failure - there is no legitimate "the subscriber was slow" explanation for it.
    // Only --reliable no re-introduces legitimate loss, by telling the subscriber not to NAK.
    if (opt.reliable && msgLoss > 0) {
        exitCode = 1;
        std::cerr << "NOTE: " << msgLoss
                  << " message(s) lost with reliable delivery in effect. Unlike Fast DDS "
                     "BEST_EFFORT, a slow subscriber does NOT explain this under Aeron: it "
                     "back-pressures the publisher instead (back_pressure_events="
                  << pub.backPressured
                  << "). Look for a publisher-side linger that was too short (--linger-sec), a "
                     "term buffer that wrapped, or a genuinely dropped datagram that was never "
                     "retransmitted."
                  << std::endl;
    }
    if (!subGroups.empty() && msgsReceived == 0) exitCode = 1;
    return exitCode;
}

// RTT: the ping side (--mode pub) publishes on the request channel and subscribes to the
// response channel; the echo side (--mode sub) does the reverse, re-publishing each message
// byte-for-byte so the original send timestamp survives the round trip and the ping side can
// subtract it against its OWN clock. That is what makes RTT usable between two real servers
// where one-way latency is not (unrelated clock epochs) - see bench-rtt-2host.sh.
//
// Note the two DISTINCT endpoints. Aeron subscriptions bind their endpoint, so request and
// response cannot share one: the ping side would receive its own traffic.
int runRtt(const Options& opt) {
    const std::uint64_t totalMsgs = opt.msgs;
    const std::string reqPub = buildChannel(opt, opt.endpoint, false);
    const std::string reqSub = buildChannel(opt, opt.endpoint, true);
    const std::string respPub = buildChannel(opt, opt.responseEndpoint, false);
    const std::string respSub = buildChannel(opt, opt.responseEndpoint, true);
    const std::vector<std::int32_t> streams{opt.streamId};

    const bool runEcho = (opt.mode == "both" || opt.mode == "sub");
    const bool runPing = (opt.mode == "both" || opt.mode == "pub");

    warnIfSpinnersExceedCores(opt, (runEcho ? 1u : 0u) + (runPing ? 1u : 0u), runPing ? 1u : 0u);

    std::unique_ptr<Group> echo;
    std::unique_ptr<Group> ping;
    std::vector<Group*> echoGroups;
    std::vector<Group*> pingGroups;

    if (runEcho) {
        echo = std::make_unique<Group>();
        echo->client = connectClient(opt);
        createSubs(*echo, opt, reqSub, streams);
        createPubs(*echo, opt, respPub, streams);
        echo->receiver = std::make_unique<Receiver>(false, 0, 0);

        Pub* respWriter = echo->pubs[0].get();
        const int timeoutSec = opt.timeoutSec;
        echo->receiver->setOnFragment([respWriter, timeoutSec](const aeron::AtomicBuffer& buffer,
                                                              aeron::util::index_t offset,
                                                              aeron::util::index_t length) {
            // Re-publish the identical bytes: the ping side computes now - original
            // send_time_ns, so the echo must not rewrite the header. That rules out
            // offerWithRetry(), which restamps by design; back-pressure is handled inline
            // here instead.
            aeron::AtomicBuffer src(buffer.buffer() + offset, static_cast<std::size_t>(length));
            const auto deadline = Clock::now() + std::chrono::seconds(timeoutSec);
            while (true) {
                const std::int64_t r = respWriter->offer(src, 0, length);
                if (r > 0) return;
                if (r == aeron::PUBLICATION_CLOSED || r == aeron::MAX_POSITION_EXCEEDED) return;
                if (Clock::now() > deadline) {
                    std::cerr << "WARNING: echo side gave up re-publishing a message (offer="
                              << r << ")." << std::endl;
                    return;
                }
                std::this_thread::yield();
            }
        });
        echoGroups.push_back(echo.get());
    }

    if (runPing) {
        ping = std::make_unique<Group>();
        ping->client = connectClient(opt);
        createSubs(*ping, opt, respSub, streams);
        createPubs(*ping, opt, reqPub, streams);
        ping->receiver = std::make_unique<Receiver>(true, totalMsgs, 0);
        pingGroups.push_back(ping.get());
    }

    std::atomic<bool> running{true};
    std::vector<Group*> pollers;
    pollers.insert(pollers.end(), echoGroups.begin(), echoGroups.end());
    pollers.insert(pollers.end(), pingGroups.begin(), pingGroups.end());
    startPolling(pollers, opt, running);

    // Echo-only process: no measuring to do, just reflect until the ping side stops feeding
    // us (waitForReceipt's idle timeout ends the run).
    if (!runPing) {
        std::cerr << "aeron_bench: echo side listening on " << reqSub << ", replying to "
                  << respPub << std::endl;
        if (!awaitConnected(echoGroups, opt, false)) {
            std::cerr << "ERROR: no ping side connected within " << opt.connectTimeoutSec
                      << "s." << std::endl;
        }
        waitForReceipt(echoGroups, totalMsgs, opt);
        // The last replies are still in the term buffer when the count is reached; without
        // a linger this process exits, entrypoint.sh stops the driver, and the ping side
        // records them as lost.
        std::this_thread::sleep_for(std::chrono::duration<double>(opt.lingerSec));
        stopPolling(pollers, running);
        const std::uint64_t echoed = echo->receiver->count();
        std::cout << "measure=rtt mode=sub (echo) msgs_echoed=" << echoed << std::endl;
        return (echoed > 0) ? 0 : 1;
    }

    int exitCode = 0;
    std::cerr << "aeron_bench: waiting for the echo peer on " << reqPub << " ..." << std::endl;
    if (!awaitConnected(pingGroups, opt, true)) {
        std::cerr << "ERROR: no echo peer connected on " << reqPub << " within "
                  << opt.connectTimeoutSec
                  << "s. Start the echo side (--mode sub) first, and check that its endpoint "
                     "matches this one exactly - Aeron does not discover peers."
                  << std::endl;
        exitCode = 1;
    }

    PubResult pub;
    if (exitCode == 0) {
        pub = publishAll(pingGroups, opt, totalMsgs);
        waitForReceipt(pingGroups, totalMsgs, opt);
    }
    stopPolling(pollers, running);

    SubResult sub = collect(pingGroups);
    LatencyStats stats;
    if (!sub.samples.empty()) {
        std::vector<double> values;
        values.reserve(sub.samples.size());
        for (const auto& s : sub.samples) values.push_back(s.latency_us);
        stats = computeStats(std::move(values));
        writeSampleCsv(opt.out + "/rtt.csv", "RttMicros", sub.samples);
    }

    const std::uint64_t msgLoss = (totalMsgs > sub.received) ? (totalMsgs - sub.received) : 0;
    writeResultJson(opt, totalMsgs, reqPub, respSub, &pub, &sub, &stats, pub.sent, sub.received,
                    msgLoss);

    std::cout << "measure=rtt mode=" << opt.mode << " msgs_sent=" << pub.sent
              << " msgs_received=" << sub.received << " msg_loss=" << msgLoss
              << " back_pressure=" << pub.backPressured;
    if (stats.valid) std::cout << " p50_us=" << stats.p50 << " p99_us=" << stats.p99;
    std::cout << std::endl;

    if (sub.received == 0) exitCode = 1;
    if (opt.reliable && msgLoss > 0) exitCode = 1;
    return exitCode;
}

}  // namespace

int main(int argc, char** argv) {
    const Options opt = parseArgs(argc, argv);
    return (opt.measure == "rtt") ? runRtt(opt) : runPubSub(opt);
}
