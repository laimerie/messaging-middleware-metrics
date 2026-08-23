// latency_oneway — measures true one-way (publisher -> subscriber) latency on NATS Core.
//
// Unlike `nats bench service serve/request` (round-trip time via request/reply), this
// tool embeds a monotonic send timestamp in each message payload and computes the
// delivery delta on receipt, giving an accurate one-way latency distribution.
//
// --rate (msgs/sec) and --duration-sec are the primary, both-required parameters; total
// message count is derived (round(rate * duration)), not settable directly via --msgs
// (which no longer exists). There is deliberately no "send N messages as fast as
// possible" mode: measured, an unthrottled burst doesn't report NATS's actual one-way
// transport latency - it reports the queueing delay that builds up while the subscriber
// works through a backlog the publisher created faster than it could be drained. Latency
// climbs steadily through such a run (confirmed: ~1.7ms at msg 0 rising past 2.1ms by
// msg 999 in one unthrottled 1000-msg test) rather than reflecting steady-state
// transport cost. Always specify the rate you actually want measured.
//
// Three modes:
//   --mode both (default): publisher and subscriber as two independent NATS connections
//     within this single process. Used for same-host measurement (bench-latency-oneway.ps1).
//   --mode pub / --mode sub: publisher-only / subscriber-only, each its own process (and,
//     in this project, its own Docker container - bench-crosshost.ps1, TODO.md #3), so
//     the two roles can run on separate network namespaces ("separate Linux hosts").
//     std::chrono::steady_clock is a host-wide (not process-wide) monotonic clock, so
//     timestamps from pub and sub processes are directly comparable as long as both
//     containers run on the SAME underlying Docker host/kernel - true here, since
//     separate *containers* still share one kernel clock. This would need real clock
//     sync (e.g. NTP) only if pub/sub ran on genuinely separate physical/cloud hosts,
//     which is out of scope for this project's Docker-based cross-host simulation.
//
// See TODO.md #4 for why this is C++ (matching the production runtime) rather than a
// scripting language: interpreter/GC/scheduler overhead in a non-native client would
// otherwise get measured as if it were NATS latency.

#include <nats/nats.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <iostream>
#include <mutex>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

using Clock = std::chrono::steady_clock;

namespace {

#pragma pack(push, 1)
struct LatencyHeader {
    uint64_t seq;
    int64_t send_time_ns;
};
#pragma pack(pop)

struct Options {
    std::string subject = "BENCH.LATENCY.ONEWAY";
    std::string server = "nats://nats:4222";
    std::string out = ".";
    std::string mode = "both";
    int size = 128;
    // --rate and --duration-sec are the primary knobs (both required conceptually - see
    // parseArgs). An earlier version took --msgs directly with an optional --rate that
    // defaulted to 0 ("send everything as fast as possible"). That measured queueing
    // delay from an unthrottled burst, not NATS's actual steady-state one-way latency
    // (confirmed by measurement - see TODO.md #4) - so unthrottled/count-only sends are
    // no longer expressible at all. msgs is derived, not settable directly.
    double rate = -1.0;        // target msgs/sec; must be set and > 0
    double durationSec = 10.0; // how long to sustain that rate
    uint64_t msgs = 0;         // computed: round(rate * durationSec)
    int timeoutSec = -1;       // how long `sub`/`both` wait for the expected message
                                // count; -1 = derive from durationSec (see parseArgs)
};

struct Sample {
    uint64_t seq;
    double latency_us;
};

std::mutex g_mutex;
std::vector<Sample> g_samples;
std::atomic<uint64_t> g_received{0};

int64_t nowNs() {
    return std::chrono::duration_cast<std::chrono::nanoseconds>(
               Clock::now().time_since_epoch())
        .count();
}

void onMsg(natsConnection*, natsSubscription*, natsMsg* msg, void*) {
    const int64_t recvNs = nowNs();
    const char* data = natsMsg_GetData(msg);
    const int dataLen = natsMsg_GetDataLength(msg);

    if (data != nullptr && dataLen >= static_cast<int>(sizeof(LatencyHeader))) {
        LatencyHeader hdr;
        std::memcpy(&hdr, data, sizeof(hdr));
        const double latencyUs = static_cast<double>(recvNs - hdr.send_time_ns) / 1000.0;
        std::lock_guard<std::mutex> lock(g_mutex);
        g_samples.push_back({hdr.seq, latencyUs});
    }

    natsMsg_Destroy(msg);
    ++g_received;
}

[[noreturn]] void fail(const std::string& what, natsStatus s = NATS_OK) {
    if (s != NATS_OK) {
        std::cerr << "ERROR: " << what << ": " << natsStatus_GetText(s) << std::endl;
    } else {
        std::cerr << "ERROR: " << what << std::endl;
    }
    std::exit(1);
}

void check(natsStatus s, const std::string& what) {
    if (s != NATS_OK) fail(what, s);
}

Options parseArgs(int argc, char** argv) {
    Options opt;
    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        auto next = [&](const char* flag) -> std::string {
            if (i + 1 >= argc) fail(std::string("missing value for ") + flag);
            return argv[++i];
        };
        if (arg == "--subject") opt.subject = next("--subject");
        else if (arg == "--server") opt.server = next("--server");
        else if (arg == "--out") opt.out = next("--out");
        else if (arg == "--mode") opt.mode = next("--mode");
        else if (arg == "--size") opt.size = std::stoi(next("--size"));
        else if (arg == "--rate") opt.rate = std::stod(next("--rate"));
        else if (arg == "--duration-sec") opt.durationSec = std::stod(next("--duration-sec"));
        else if (arg == "--timeout-sec") opt.timeoutSec = std::stoi(next("--timeout-sec"));
        else fail("unknown argument: " + arg +
                  " (note: --msgs was removed - use --rate and --duration-sec instead; "
                  "total message count is derived from rate * duration)");
    }
    if (opt.mode != "both" && opt.mode != "pub" && opt.mode != "sub") {
        fail("--mode must be one of: both, pub, sub (got '" + opt.mode + "')");
    }
    if (opt.size < static_cast<int>(sizeof(LatencyHeader))) {
        fail("--size must be >= " + std::to_string(sizeof(LatencyHeader)) +
             " bytes (needs room for the seq+timestamp header)");
    }
    if (opt.rate <= 0.0) {
        fail("--rate is required and must be > 0 (target msgs/sec). This tool always "
             "measures steady-state one-way latency at a specified sustained send rate - "
             "there is no 'burst as fast as possible' mode, because an unthrottled send "
             "measures queueing delay building up during the burst, not NATS's actual "
             "one-way transport latency (confirmed by measurement - see TODO.md #4).");
    }
    if (opt.durationSec <= 0.0) {
        fail("--duration-sec must be > 0");
    }
    // pub and sub run in separate processes/containers (--mode pub / --mode sub) and must
    // be given the SAME --rate/--duration-sec so both sides compute the same expected
    // message count - the calling script (bench-latency-oneway.ps1, bench-crosshost.ps1)
    // is responsible for passing matching values to both invocations.
    opt.msgs = static_cast<uint64_t>(std::llround(opt.rate * opt.durationSec));
    if (opt.msgs == 0) opt.msgs = 1;
    if (opt.timeoutSec < 0) {
        // Grace period beyond the nominal send duration, so a real loss/stall scenario
        // still terminates the tool (and the caller's Receive-JobSafely) instead of
        // hanging indefinitely, without being so tight that a slow-but-healthy run gets
        // mistaken for a failure.
        opt.timeoutSec = static_cast<int>(std::ceil(opt.durationSec)) + 20;
    }
    return opt;
}

double percentile(const std::vector<double>& sorted, double p) {
    if (sorted.empty()) return 0.0;
    size_t idx = static_cast<size_t>(std::ceil(p / 100.0 * sorted.size())) - 1;
    idx = std::min(idx, sorted.size() - 1);
    return sorted[idx];
}

void runPublisher(natsConnection* pubConn, const Options& opt) {
    // opt.rate is guaranteed > 0 by parseArgs, so pacing is always active - this tool has
    // no "unthrottled burst" mode (see the Options struct comment for why).
    std::vector<char> payload(opt.size, 0);
    const auto interval = std::chrono::duration<double>(1.0 / opt.rate);

    for (uint64_t seq = 0; seq < opt.msgs; ++seq) {
        const auto sendStart = Clock::now();
        LatencyHeader hdr{seq, nowNs()};
        std::memcpy(payload.data(), &hdr, sizeof(hdr));
        check(natsConnection_Publish(pubConn, opt.subject.c_str(), payload.data(),
                                      opt.size),
              "publish");
        const auto target = sendStart + std::chrono::duration_cast<Clock::duration>(interval);
        std::this_thread::sleep_until(target);
    }
    check(natsConnection_Flush(pubConn), "flush publisher");
}

void waitForReceipt(uint64_t expected, int timeoutSec) {
    // Bounded grace period so a real message-loss scenario doesn't hang the tool forever
    // (and doesn't hang the PowerShell wrapper's Receive-JobSafely waiting on it either).
    const auto waitDeadline = Clock::now() + std::chrono::seconds(timeoutSec);
    while (g_received.load() < expected && Clock::now() < waitDeadline) {
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
    }
}

void writeLatencyResult(const Options& opt, uint64_t sent, uint64_t received) {
    // Raw per-message samples, sorted by sequence for readability.
    std::vector<Sample> bySeq;
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        bySeq = g_samples;
    }
    std::sort(bySeq.begin(), bySeq.end(),
              [](const Sample& a, const Sample& b) { return a.seq < b.seq; });

    std::ofstream csv(opt.out + "/oneway.csv");
    csv << "Seq,LatencyMicros\n";
    for (const auto& s : bySeq) {
        csv << s.seq << "," << s.latency_us << "\n";
    }
    csv.close();

    // Stats, from the same samples sorted by latency for percentiles.
    std::vector<double> latencies;
    latencies.reserve(bySeq.size());
    for (const auto& s : bySeq) latencies.push_back(s.latency_us);
    std::sort(latencies.begin(), latencies.end());

    double sum = 0.0, minV = 0.0, maxV = 0.0, avg = 0.0, stddev = 0.0;
    double p50 = 0.0, p90 = 0.0, p95 = 0.0, p99 = 0.0, p999 = 0.0;
    if (!latencies.empty()) {
        minV = latencies.front();
        maxV = latencies.back();
        for (double v : latencies) sum += v;
        avg = sum / latencies.size();
        double sq = 0.0;
        for (double v : latencies) sq += (v - avg) * (v - avg);
        stddev = std::sqrt(sq / latencies.size());
        p50 = percentile(latencies, 50);
        p90 = percentile(latencies, 90);
        p95 = percentile(latencies, 95);
        p99 = percentile(latencies, 99);
        p999 = percentile(latencies, 99.9);
    }

    const uint64_t msgLoss = (sent > received) ? (sent - received) : 0;

    std::ostringstream json;
    json << "{\n"
         << "  \"mode\": \"" << opt.mode << "\",\n"
         << "  \"params\": {\n"
         << "    \"subject\": \"" << opt.subject << "\",\n"
         << "    \"rate\": " << opt.rate << ",\n"
         << "    \"duration_sec\": " << opt.durationSec << ",\n"
         << "    \"msgs\": " << opt.msgs << ",\n"
         << "    \"size\": " << opt.size << "\n"
         << "  },\n"
         << "  \"environment\": {\n"
         << "    \"latency_tool_version\": \"latency_oneway 0.3.0\",\n"
         << "    \"nats_c_version\": \"" << nats_GetVersion() << "\"\n"
         << "  },\n"
         << "  \"metrics\": {\n"
         << "    \"latency_us\": {\n"
         << "      \"min\": " << minV << ",\n"
         << "      \"avg\": " << avg << ",\n"
         << "      \"p50\": " << p50 << ",\n"
         << "      \"p90\": " << p90 << ",\n"
         << "      \"p95\": " << p95 << ",\n"
         << "      \"p99\": " << p99 << ",\n"
         << "      \"p99_9\": " << p999 << ",\n"
         << "      \"max\": " << maxV << ",\n"
         << "      \"stddev\": " << stddev << "\n"
         << "    }\n"
         << "  },\n"
         << "  \"msgs_sent\": " << sent << ",\n"
         << "  \"msgs_received\": " << received << ",\n"
         << "  \"msg_loss\": " << msgLoss << "\n"
         << "}\n";

    std::ofstream resultFile(opt.out + "/result.json");
    resultFile << json.str();
    resultFile.close();

    std::cout << "msgs_sent=" << sent << " msgs_received=" << received
              << " msg_loss=" << msgLoss << " p50_us=" << p50 << " p99_us=" << p99
              << std::endl;
}

void writePubOnlyResult(const Options& opt, uint64_t sent) {
    // Publisher-only mode has no receipt-side data of its own (that lives in the sub
    // process's result.json - see TODO.md #3's bench-crosshost.ps1), so this is
    // deliberately minimal: just a record that the send side completed as expected.
    std::ostringstream json;
    json << "{\n"
         << "  \"mode\": \"pub\",\n"
         << "  \"params\": {\n"
         << "    \"subject\": \"" << opt.subject << "\",\n"
         << "    \"rate\": " << opt.rate << ",\n"
         << "    \"duration_sec\": " << opt.durationSec << ",\n"
         << "    \"msgs\": " << opt.msgs << ",\n"
         << "    \"size\": " << opt.size << "\n"
         << "  },\n"
         << "  \"environment\": {\n"
         << "    \"latency_tool_version\": \"latency_oneway 0.3.0\",\n"
         << "    \"nats_c_version\": \"" << nats_GetVersion() << "\"\n"
         << "  },\n"
         << "  \"msgs_sent\": " << sent << "\n"
         << "}\n";

    std::ofstream resultFile(opt.out + "/result.json");
    resultFile << json.str();
    resultFile.close();

    std::cout << "msgs_sent=" << sent << std::endl;
}

int runBoth(const Options& opt) {
    natsConnection* subConn = nullptr;
    natsConnection* pubConn = nullptr;
    natsSubscription* sub = nullptr;

    check(natsConnection_ConnectTo(&subConn, opt.server.c_str()), "connect (subscriber)");
    check(natsConnection_ConnectTo(&pubConn, opt.server.c_str()), "connect (publisher)");
    check(natsConnection_Subscribe(&sub, subConn, opt.subject.c_str(), onMsg, nullptr),
          "subscribe");
    // Flush ensures the SUB has round-tripped to the server before we start publishing,
    // avoiding the "published before subscriber attached" message-loss trap noted
    // throughout this project's other bench scripts.
    check(natsConnection_Flush(subConn), "flush subscriber");

    runPublisher(pubConn, opt);
    waitForReceipt(opt.msgs, opt.timeoutSec);
    writeLatencyResult(opt, opt.msgs, g_received.load());

    natsSubscription_Destroy(sub);
    natsConnection_Destroy(subConn);
    natsConnection_Destroy(pubConn);
    return (g_received.load() == opt.msgs) ? 0 : 1;
}

int runSubOnly(const Options& opt) {
    natsConnection* subConn = nullptr;
    natsSubscription* sub = nullptr;

    check(natsConnection_ConnectTo(&subConn, opt.server.c_str()), "connect (subscriber)");
    check(natsConnection_Subscribe(&sub, subConn, opt.subject.c_str(), onMsg, nullptr),
          "subscribe");
    check(natsConnection_Flush(subConn), "flush subscriber");

    waitForReceipt(opt.msgs, opt.timeoutSec);
    writeLatencyResult(opt, opt.msgs, g_received.load());

    natsSubscription_Destroy(sub);
    natsConnection_Destroy(subConn);
    return (g_received.load() == opt.msgs) ? 0 : 1;
}

int runPubOnly(const Options& opt) {
    natsConnection* pubConn = nullptr;
    check(natsConnection_ConnectTo(&pubConn, opt.server.c_str()), "connect (publisher)");

    runPublisher(pubConn, opt);
    writePubOnlyResult(opt, opt.msgs);

    natsConnection_Destroy(pubConn);
    return 0;
}

}  // namespace

int main(int argc, char** argv) {
    Options opt = parseArgs(argc, argv);

    int exitCode = 1;
    if (opt.mode == "both") {
        exitCode = runBoth(opt);
    } else if (opt.mode == "sub") {
        exitCode = runSubOnly(opt);
    } else {  // "pub"
        exitCode = runPubOnly(opt);
    }

    nats_Close();
    return exitCode;
}
