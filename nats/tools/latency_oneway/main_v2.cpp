// latency_oneway — measures true one-way (publisher -> subscriber) latency on NATS Core with high-precision pacing.
//
// Modified version with high-precision pacing (busy spinning & hybrid mode) 
// to mitigate OS scheduling / thread-sleeping latency jitter.

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
#include <sched.h>

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
    double rate = -1.0;        // target msgs/sec; must be set and > 0
    double durationSec = 10.0; // how long to sustain that rate
    uint64_t msgs = 0;         // computed: round(rate * durationSec)
    int timeoutSec = -1;       // how long sub/both wait for the expected message count; -1 = derive from durationSec
    std::string pacing = "auto"; // pacing strategy: auto | busy | sleep
};

struct Sample {
    uint64_t seq;
    double latency_us;
};

std::mutex g_mutex;
std::vector<Sample> g_samples;
std::atomic<uint64_t> g_received{0};

// OS sleep scheduling guard window (200µs).
// Under Docker Desktop / WSL2, sleeping for small durations like 100µs can overshoot by 80-300µs.
// Sleeping up to (target - 200µs) and spinning the remainder keeps the timing error minimal.
constexpr auto kPacingSpinGuard = std::chrono::microseconds(200);

int64_t nowNs() {
    return std::chrono::duration_cast<std::chrono::nanoseconds>(
               Clock::now().time_since_epoch())
        .count();
}

void onMsg(natsConnection*, natsSubscription*, natsMsg* msg, void*) {
    const int64_t recvNs = nowNs();
    const char* data = natsMsg_GetData(msg);
    const int dataLen = natsMsg_GetDataLength(msg);

    if (dataLen >= static_cast<int>(sizeof(LatencyHeader))) {
        const LatencyHeader* hdr = reinterpret_cast<const LatencyHeader*>(data);
        double latencyUs = static_cast<double>(recvNs - hdr->send_time_ns) / 1000.0;
        {
            std::lock_guard<std::mutex> lock(g_mutex);
            g_samples.push_back({hdr->seq, latencyUs});
        }
        g_received++;
    }
    natsMsg_Destroy(msg);
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

// Publisher-only connect helper. natsConnection_Publish() does NOT hit the socket
// immediately by default: nats.c buffers outbound frames and only flushes them when the
// buffer fills or its background flusher timer fires (SendAsap OFF), which can add
// hundreds of microseconds between hdr->send_time_ns and the actual wire send -- latency
// this tool would otherwise misattribute to NATS/network transport. --rate + busy-spin
// pacing only guarantees *when publish() is called*; it cannot fix buffering that happens
// after that call. SendAsap forces an immediate flush on every publish so the timestamped
// send and the wire send happen together.
void connectPublisher(natsConnection** conn, const std::string& server) {
    natsOptions* opts = nullptr;
    check(natsOptions_Create(&opts), "create publisher options");
    check(natsOptions_SetURL(opts, server.c_str()), "set publisher URL");
    check(natsOptions_SetSendAsap(opts, true), "set publisher SendAsap");
    check(natsConnection_Connect(conn, opts), "connect (publisher)");
    natsOptions_Destroy(opts);
}

// Waits until target according to the selected pacing strategy.
void pacedWaitUntil(Clock::time_point target, const std::string& pacing) {
    if (pacing == "sleep") {
        std::this_thread::sleep_until(target);
        return;
    }
    if (pacing != "busy") {  // "auto": sleep up to the spin guard window, then spin the rest
        const auto spinFrom = target - kPacingSpinGuard;
        if (Clock::now() < spinFrom) {
            std::this_thread::sleep_until(spinFrom);
        }
    }
    while (Clock::now() < target) {
        // High-precision busy spin
    }
}

unsigned availableCores() {
    unsigned fromAffinity = 0;
    cpu_set_t set;
    CPU_ZERO(&set);
    if (sched_getaffinity(0, sizeof(set), &set) == 0) {
        fromAffinity = static_cast<unsigned>(CPU_COUNT(&set));
    }
    return fromAffinity;
}

// Spun loop will hog a full core. Warn if cores are constrained.
void warnIfPacingWillStarveReceiver(const Options& opt) {
    if (opt.rate <= 0.0 || opt.pacing == "sleep") return;
    const unsigned cores = availableCores();
    if (cores == 0) return;  
    const uint64_t needed = 3;  // publisher + subscriber + nats-server headroom
    if (needed > cores) {
        std::cerr << "WARNING: --pacing " << opt.pacing << " busy-spins one core, "
                  << "but only " << cores << " core(s) are available to this process. "
                  << "The spin will compete with NATS's internal client/server threads and "
                  << "inflate the measured latency. Use --pacing sleep or run with at least " 
                  << needed << " cores." << std::endl;
    }
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
        else if (arg == "--pacing") {
            opt.pacing = next("--pacing");
            if (opt.pacing != "auto" && opt.pacing != "busy" && opt.pacing != "sleep") {
                fail("--pacing must be one of: auto, busy, sleep (got '" + opt.pacing + "')");
            }
        }
        else {
            fail("unknown argument: " + arg + " (note: --msgs was removed - use --rate and --duration-sec instead; "
                 "total message count is derived from rate * duration)");
        }
    }
    if (opt.mode != "both" && opt.mode != "pub" && opt.mode != "sub") {
        fail("--mode must be one of: both, pub, sub (got '" + opt.mode + "')");
    }
    if (opt.size < static_cast<int>(sizeof(LatencyHeader))) {
        fail("--size must be >= " + std::to_string(sizeof(LatencyHeader)) + " bytes (needs room for the seq+timestamp header)");
    }
    if (opt.rate <= 0.0) {
        fail("--rate is required and must be > 0 (target msgs/sec). This tool always "
             "measures steady-state one-way latency at a specified sustained send rate.");
    }
    if (opt.durationSec <= 0.0) {
        fail("--duration-sec must be > 0");
    }

    opt.msgs = static_cast<uint64_t>(std::llround(opt.rate * opt.durationSec));
    if (opt.msgs == 0) opt.msgs = 1;

    if (opt.timeoutSec < 0) {
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

void writeLatencyResult(const Options& opt, uint64_t sent, uint64_t received) {
    std::vector<Sample> bySeq;
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        bySeq = g_samples;
    }
    std::sort(bySeq.begin(), bySeq.end(), [](const Sample& a, const Sample& b) { return a.seq < b.seq; });

    std::string csvPath = opt.out + "/latency.csv";
    std::ofstream csv(csvPath);
    if (!csv.is_open()) {
        fail("failed to open output CSV: " + csvPath);
    }
    csv << "Seq,LatencyUs\n";
    std::vector<double> latencies;
    latencies.reserve(bySeq.size());
    for (const auto& s : bySeq) {
        csv << s.seq << "," << s.latency_us << "\n";
        latencies.push_back(s.latency_us);
    }
    csv.close();

    double minVal = 0, maxVal = 0, avgVal = 0, stddevVal = 0;
    double p50 = 0, p90 = 0, p95 = 0, p99 = 0, p999 = 0;
    uint64_t msgLoss = (sent > received) ? (sent - received) : 0;

    if (!latencies.empty()) {
        std::sort(latencies.begin(), latencies.end());
        minVal = latencies.front();
        maxVal = latencies.back();
        double sum = 0.0;
        for (double v : latencies) sum += v;
        avgVal = sum / latencies.size();

        double sqSum = 0.0;
        for (double v : latencies) sqSum += (v - avgVal) * (v - avgVal);
        stddevVal = std::sqrt(sqSum / latencies.size());

        p50 = percentile(latencies, 50.0);
        p90 = percentile(latencies, 90.0);
        p95 = percentile(latencies, 95.0);
        p99 = percentile(latencies, 99.0);
        p999 = percentile(latencies, 99.9);
    }

    std::string jsonPath = opt.out + "/result.json";
    std::ofstream json(jsonPath);
    if (!json.is_open()) {
        fail("failed to open output JSON: " + jsonPath);
    }

    json << "{\n"
         << "  \"mode\": \"" << opt.mode << "\",\n"
         << "  \"measure\": \"latency\",\n"
         << "  \"params\": {\n"
         << "    \"subject\": \"" << opt.subject << "\",\n"
         << "    \"rate\": " << opt.rate << ",\n"
         << "    \"duration_sec\": " << opt.durationSec << ",\n"
         << "    \"msgs\": " << opt.msgs << ",\n"
         << "    \"size\": " << opt.size << ",\n"
         << "    \"pacing\": \"" << opt.pacing << "\"\n"
         << "  },\n"
         << "  \"environment\": {\n"
         << "    \"latency_tool_version\": \"latency_oneway 0.3.0_pacing\",\n"
         << "    \"nats_c_version\": \"" << nats_GetVersion() << "\"\n"
         << "  },\n"
         << "  \"metrics\": {\n"
         << "    \"msgs_sent\": " << sent << ",\n"
         << "    \"msgs_received\": " << received << ",\n"
         << "    \"msg_loss\": " << msgLoss << ",\n"
         << "    \"latency_us\": {\n"
         << "      \"min\": " << minVal << ",\n"
         << "      \"avg\": " << avgVal << ",\n"
         << "      \"p50\": " << p50 << ",\n"
         << "      \"p90\": " << p90 << ",\n"
         << "      \"p95\": " << p95 << ",\n"
         << "      \"p99\": " << p99 << ",\n"
         << "      \"p999\": " << p999 << ",\n"
         << "      \"max\": " << maxVal << ",\n"
         << "      \"stddev\": " << stddevVal << "\n"
         << "    }\n"
         << "  }\n"
         << "}\n";
    json.close();
}

void writePubOnlyResult(const Options& opt, uint64_t sent) {
    std::string jsonPath = opt.out + "/result.json";
    std::ofstream json(jsonPath);
    if (!json.is_open()) {
        fail("failed to open output JSON (pub-only): " + jsonPath);
    }
    json << "{\n"
         << "  \"mode\": \"pub\",\n"
         << "  \"params\": {\n"
         << "    \"subject\": \"" << opt.subject << "\",\n"
         << "    \"rate\": " << opt.rate << ",\n"
         << "    \"duration_sec\": " << opt.durationSec << ",\n"
         << "    \"msgs\": " << opt.msgs << ",\n"
         << "    \"size\": " << opt.size << ",\n"
         << "    \"pacing\": \"" << opt.pacing << "\"\n"
         << "  },\n"
         << "  \"environment\": {\n"
         << "    \"latency_tool_version\": \"latency_oneway 0.3.0_pacing\",\n"
         << "    \"nats_c_version\": \"" << nats_GetVersion() << "\"\n"
         << "  },\n"
         << "  \"msgs_sent\": " << sent << "\n"
         << "}\n";
    json.close();
}

void runPublisher(natsConnection* pubConn, const Options& opt) {
    warnIfPacingWillStarveReceiver(opt);
    std::vector<char> payload(opt.size, 0);
    const auto interval = std::chrono::duration<double>(1.0 / opt.rate);
    
    auto nextSend = Clock::now();
    uint64_t sent = 0;

    for (uint64_t i = 0; i < opt.msgs; ++i) {
        pacedWaitUntil(nextSend, opt.pacing);

        LatencyHeader* hdr = reinterpret_cast<LatencyHeader*>(payload.data());
        hdr->seq = i;
        hdr->send_time_ns = nowNs();

        natsStatus s = natsConnection_Publish(pubConn, opt.subject.c_str(), payload.data(), opt.size);
        if (s != NATS_OK) {
            fail("failed to publish message", s);
        }
        sent++;

        nextSend += std::chrono::duration_cast<Clock::duration>(interval);
    }

    natsConnection_Flush(pubConn);

    if (opt.mode == "pub") {
        writePubOnlyResult(opt, sent);
    }
}

void waitForReceipt(uint64_t expected, int timeoutSec) {
    const auto waitDeadline = Clock::now() + std::chrono::seconds(timeoutSec);
    while (g_received.load() < expected && Clock::now() < waitDeadline) {
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
    }
}

int runBoth(const Options& opt) {
    natsConnection* subConn = nullptr;
    natsConnection* pubConn = nullptr;
    natsSubscription* sub = nullptr;

    check(natsConnection_ConnectTo(&subConn, opt.server.c_str()), "connect (subscriber)");
    connectPublisher(&pubConn, opt.server);

    check(natsConnection_Subscribe(&sub, subConn, opt.subject.c_str(), onMsg, nullptr), "subscribe");

    std::thread pubThread(runPublisher, pubConn, opt);
    pubThread.join();

    waitForReceipt(opt.msgs, opt.timeoutSec);

    uint64_t received = g_received.load();
    writeLatencyResult(opt, opt.msgs, received);

    natsSubscription_Destroy(sub);
    natsConnection_Destroy(subConn);
    natsConnection_Destroy(pubConn);
    return 0;
}

int runSubOnly(const Options& opt) {
    natsConnection* subConn = nullptr;
    natsSubscription* sub = nullptr;

    check(natsConnection_ConnectTo(&subConn, opt.server.c_str()), "connect (subscriber-only)");
    check(natsConnection_Subscribe(&sub, subConn, opt.subject.c_str(), onMsg, nullptr), "subscribe");

    std::cout << "Subscriber listening. Waiting for " << opt.msgs << " messages..." << std::endl;
    waitForReceipt(opt.msgs, opt.timeoutSec);

    uint64_t received = g_received.load();
    writeLatencyResult(opt, opt.msgs, received);

    natsSubscription_Destroy(sub);
    natsConnection_Destroy(subConn);
    return 0;
}

int runPubOnly(const Options& opt) {
    natsConnection* pubConn = nullptr;
    connectPublisher(&pubConn, opt.server);

    std::cout << "Publisher starting. Sending " << opt.msgs << " messages at " << opt.rate << " msgs/sec with pacing=" << opt.pacing << "..." << std::endl;
    runPublisher(pubConn, opt);

    natsConnection_Destroy(pubConn);
    return 0;
}

}  // namespace

int main(int argc, char** argv) {
    Options opt = parseArgs(argc, argv);
    
    int ret = 0;
    if (opt.mode == "both") {
        ret = runBoth(opt);
    } else if (opt.mode == "sub") {
        ret = runSubOnly(opt);
    } else if (opt.mode == "pub") {
        ret = runPubOnly(opt);
    }
    
    return ret;
}
