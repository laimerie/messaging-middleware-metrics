// dds_bench — Fast DDS performance measurement tool (throughput / one-way latency / RTT).
//
// This is the Fast DDS counterpart of nats/tools/latency_oneway/. Unlike the NATS side —
// where `nats bench` (the official CLI) covered throughput/scalability and only the
// one-way latency measurement needed a custom C++ tool — Fast DDS ships no equivalent
// benchmark CLI, so ONE binary covers every category here. That is also what makes the two
// projects comparable: both measure with a native C++ client on CentOS 7 / gcc 11 / C++17,
// so neither number carries a client-runtime overhead the other doesn't.
//
// Two orthogonal axes:
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
//                          steady-state transport latency. (Same conclusion as
//                          nats/TODO.md #4; it applies identically here.)
//   --measure rtt          round-trip via an echo peer — the analogue of `nats bench
//                          service serve/request` and of eProsima's own LatencyTest. Also
//                          rate-paced, for the same reason.
//
//   --mode both            publisher and subscriber in ONE process, as separate
//                          DomainParticipants. Same-host measurement.
//   --mode pub / --mode sub
//                          publisher-only / subscriber-only, each its own process (and, in
//                          this project, its own container — bench-crosshost.sh), so the
//                          two roles sit in separate network namespaces.
//                          For --measure rtt: `pub` is the measuring ping side, `sub` is
//                          the echo side.
//
// std::chrono::steady_clock is a HOST-wide monotonic clock, so pub/sub timestamps stay
// directly comparable across separate containers on one Docker host (they share a kernel).
// Genuinely separate physical hosts would need real clock sync — out of scope, exactly as
// on the NATS side.
//
// Three things this tool does deliberately, each of which would otherwise silently corrupt
// the measurement (see CLAUDE.md in this directory for the full list):
//   * Intra-process delivery is OFF by default (--intraprocess off). Fast DDS
//     short-circuits same-process endpoints past the transport entirely; leaving it on
//     under --mode both would measure a memcpy, not DDS.
//   * The transport stack is always set explicitly (use_builtin_transports = false). The
//     builtin default enables SHM *and* UDP, and two containers on one host can match an
//     SHM locator while owning separate /dev/shm mounts — the samples then vanish.
//   * The publisher waits for real publication-matched events before sending. DDS
//     discovery is asynchronous, and BEST_EFFORT + VOLATILE drops anything written before
//     a reader is matched.

#include <fastdds/dds/core/policy/QosPolicies.hpp>
#include <fastdds/dds/core/status/PublicationMatchedStatus.hpp>
#include <fastdds/dds/core/status/SubscriptionMatchedStatus.hpp>
#include <fastdds/dds/domain/DomainParticipant.hpp>
#include <fastdds/dds/domain/DomainParticipantFactory.hpp>
#include <fastdds/dds/domain/qos/DomainParticipantQos.hpp>
#include <fastdds/dds/publisher/DataWriter.hpp>
#include <fastdds/dds/publisher/DataWriterListener.hpp>
#include <fastdds/dds/publisher/Publisher.hpp>
#include <fastdds/dds/publisher/qos/DataWriterQos.hpp>
#include <fastdds/dds/subscriber/DataReader.hpp>
#include <fastdds/dds/subscriber/DataReaderListener.hpp>
#include <fastdds/dds/subscriber/SampleInfo.hpp>
#include <fastdds/dds/subscriber/Subscriber.hpp>
#include <fastdds/dds/subscriber/qos/DataReaderQos.hpp>
#include <fastdds/dds/topic/Topic.hpp>
#include <fastdds/dds/topic/TopicDataType.hpp>
#include <fastdds/dds/topic/TypeSupport.hpp>
#include <fastdds/rtps/attributes/RTPSParticipantAttributes.h>
#include <fastdds/rtps/attributes/ServerAttributes.h>
#include <fastdds/rtps/common/Locator.h>
#include <fastdds/rtps/common/Time_t.h>
#include <fastdds/rtps/transport/UDPv4TransportDescriptor.h>
#include <fastdds/rtps/transport/shared_mem/SharedMemTransportDescriptor.h>
#include <fastrtps/attributes/LibrarySettingsAttributes.h>
#include <fastrtps/config.h>
#include <fastrtps/utils/IPLocator.h>
#include <fastrtps/xmlparser/XMLProfileManager.h>

#include <sched.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <functional>
#include <iostream>
#include <memory>
#include <mutex>
#include <sstream>
#include <string>
#include <ctime>
#include <thread>
#include <vector>

namespace {

using namespace eprosima::fastdds::dds;

// Two distinct rtps namespaces, and mixing them up is a compile error at best and the
// wrong type at worst: transports live under fastdds::rtps, while Locator_t /
// SerializedPayload_t / discovery attributes are still under fastrtps::rtps in Fast DDS 2.x.
namespace frtps = eprosima::fastrtps::rtps;
namespace fdrtps = eprosima::fastdds::rtps;

using Clock = std::chrono::steady_clock;

constexpr const char* kToolVersion = "dds_bench 0.1.0";

// seq (8 bytes) + send_time_ns (8 bytes). Everything after this is filler, so --size is
// the exact on-the-wire user payload size, directly comparable with NATS's --size.
constexpr uint32_t kHeaderSize = 16;

// Above this, a sample no longer fits in one UDP datagram and Fast DDS must fragment it —
// which it only does in ASYNCHRONOUS publish mode. parseArgs auto-switches so a large
// --size doesn't silently deliver nothing.
constexpr int kFragmentationThreshold = 60000;

// How much of each pacing interval `--pacing auto` hands to a busy spin instead of the OS.
// Sized from measurement, not taste: on this project's Docker Desktop/WSL2 environment a
// std::this_thread::sleep_for(100us) overshot by 83us at the median and 300us at p99, so
// anything under a couple of hundred microseconds cannot be delivered by sleeping at all.
// Sleeping up to (target - this) and spinning the remainder keeps the wake-up error inside
// the spin window while still yielding the CPU for the bulk of a long interval.
constexpr auto kPacingSpinGuard = std::chrono::microseconds(200);

int64_t nowNs() {
    return std::chrono::duration_cast<std::chrono::nanoseconds>(Clock::now().time_since_epoch())
        .count();
}

int64_t realtimeNs() {
    timespec ts{};
    clock_gettime(CLOCK_REALTIME, &ts);
    return static_cast<int64_t>(ts.tv_sec) * 1000000000LL + ts.tv_nsec;
}

[[noreturn]] void fail(const std::string& what) {
    std::cerr << "ERROR: " << what << std::endl;
    std::exit(1);
}

// ---------------------------------------------------------------------------------------
// Options
// ---------------------------------------------------------------------------------------

struct Options {
    std::string measure = "throughput";  // throughput | latency | rtt
    std::string mode = "both";           // both | pub | sub
    std::string topic = "BENCH_TOPIC";
    uint32_t topicCount = 1;
    uint32_t domain = 0;
    int size = 128;

    // throughput: --msgs is the total across all publishers; --rate optionally caps it.
    // latency/rtt: --rate and --duration-sec are the axis and --msgs is rejected (the
    // total is derived). See the file header for why there is no unthrottled latency mode.
    uint64_t msgs = 200000;
    bool msgsGiven = false;
    double rate = 0.0;  // aggregate msgs/sec across all publishers; 0 = unthrottled
    double durationSec = 10.0;

    uint32_t pubCount = 1;  // publisher participants
    uint32_t subCount = 1;  // subscriber participants (the DDS analogue of NATS connections)

    std::string reliability = "best_effort";  // best_effort | reliable
    std::string durability = "volatile";      // volatile | transient_local
    std::string history = "keep_last";        // keep_last | keep_all
    int32_t historyDepth = 100;
    // NOT the Fast DDS default, which is 3 SECONDS (WriterAttributes.h: "Periodic HB
    // period, default value 3s"). At that setting a RELIABLE writer's retransmission round
    // trip dominates any benchmark shorter than a few minutes - the first measured run
    // here spent 2.5s of a 3.0s publish waiting on one heartbeat for 1000 messages. eProsima's
    // own performance tests shorten it for the same reason. Set --heartbeat-period-ms 3000
    // to measure the out-of-the-box behaviour instead.
    int heartbeatPeriodMs = 100;

    // RELIABLE retransmission path timings. Both keep Fast DDS's own defaults (5ms each),
    // because changing them silently would misrepresent out-of-the-box behaviour — but
    // note what those defaults imply: a sample that has to be retransmitted costs at least
    // heartbeatResponseDelay (reader waits before ACKNACK) + nackResponseDelay (writer
    // waits before resending) ≈ 10ms. Any latency budget under 10ms is therefore only
    // meetable if retransmission NEVER happens, unless these are lowered. Exposed so a
    // sub-millisecond target can actually be tested. (Two more, startup-only, are left
    // hardcoded at Fast DDS defaults: writer initialHeartbeatDelay 12ms and reader
    // initialAcknackDelay 70ms — they affect the first exchange after matching, not the
    // steady state.)
    int nackResponseDelayUs = 5000;       // writer: delay before answering an ACKNACK
    int heartbeatResponseDelayUs = 5000;  // reader: delay before answering a HEARTBEAT
    std::string publishMode = "auto";  // sync | async | auto (async once size >= 60000)

    std::string transport = "udp";     // udp | shm
    std::string discovery = "simple";  // simple | server
    std::string dsAddress = "127.0.0.1";
    uint32_t dsPort = 11811;
    std::string dsGuid = "44.53.00.5f.45.50.52.4f.53.49.4d.41";  // fast-discovery-server -i 0

    std::string intraprocess = "off";  // off | on
    std::string out = ".";

    // How the publisher waits out each send interval.
    //   sleep : hand the whole wait to the OS. Costs no CPU, but the OS timer is far
    //           coarser than a high send rate needs — measured here, a requested 10000/s
    //           actually achieved ~4900/s, so the run silently measured a different
    //           condition than it reported, and the uneven wake-ups made the sending
    //           bursty, inflating the receiver's queueing tail.
    //   busy  : spin on the clock. Nanosecond-accurate, but occupies a full CPU core per
    //           publisher thread for the whole run.
    //   auto  : sleep down to kPacingSpinGuard before the target, then spin. Accurate at
    //           any rate, and only pays the full core cost when the interval is too short
    //           to sleep through at all (roughly above 5000 msgs/sec).
    std::string pacing = "auto";  // auto | sleep | busy
    std::string clock = "monotonic";  // monotonic | realtime

    // Simulated per-sample application work on the subscriber side. 0 = consume as fast as
    // possible. Exists to quantify how much application-side processing a given send rate
    // tolerates before BEST_EFFORT starts dropping.
    int subWorkUs = 0;

    int matchTimeoutSec = 30;
    int idleTimeoutSec = 5;  // subscriber gives up this long after the LAST message
    int timeoutSec = -1;     // hard cap; -1 = derived in parseArgs
};

struct Sample {
    uint64_t seq;
    double latency_us;
};

// ---------------------------------------------------------------------------------------
// Topic data type
//
// Hand-written rather than fastddsgen-generated, for three reasons: it keeps Java and
// Fast-DDS-Gen out of the CentOS 7 image, it makes --size a pure runtime parameter instead
// of something baked into an IDL, and — by serialising as an opaque memcpy'd byte blob
// rather than through FastCDR — it leaves the tool independent of the FastCDR 1.x/2.x API
// split. Both endpoints are this same binary, so cross-vendor interoperability of the
// encoding is not a goal.
// ---------------------------------------------------------------------------------------

struct BenchSample {
    std::vector<uint8_t> bytes;
};

class BenchType : public TopicDataType {
public:
    explicit BenchType(uint32_t payloadSize) : payloadSize_(payloadSize) {
        setName("BenchSample");
        m_typeSize = payloadSize + 4;  // Fast DDS convention: max serialized size + 4
        m_isGetKeyDefined = false;
    }

    bool serialize(void* data, frtps::SerializedPayload_t* payload) override {
        auto* s = static_cast<BenchSample*>(data);
        const auto len = static_cast<uint32_t>(s->bytes.size());
        if (payload->max_size < len) return false;
        std::memcpy(payload->data, s->bytes.data(), len);
        payload->length = len;
        payload->encapsulation = CDR_LE;
        return true;
    }

    bool deserialize(frtps::SerializedPayload_t* payload, void* data) override {
        auto* s = static_cast<BenchSample*>(data);
        s->bytes.resize(payload->length);  // no-op in the steady state: createData presizes
        std::memcpy(s->bytes.data(), payload->data, payload->length);
        return true;
    }

    std::function<uint32_t()> getSerializedSizeProvider(void* data) override {
        return [data]() {
            return static_cast<uint32_t>(static_cast<BenchSample*>(data)->bytes.size());
        };
    }

    void* createData() override { return new BenchSample{std::vector<uint8_t>(payloadSize_, 0)}; }

    void deleteData(void* data) override { delete static_cast<BenchSample*>(data); }

    bool getKey(void*, frtps::InstanceHandle_t*, bool) override { return false; }

private:
    uint32_t payloadSize_;
};

// ---------------------------------------------------------------------------------------
// Endpoint-match tracking
//
// DDS discovery is asynchronous. Publishing before a reader is matched throws the sample
// away under BEST_EFFORT + VOLATILE, so every publisher here waits on a real
// on_publication_matched event rather than the fixed `sleep 2` the NATS scripts use.
// ---------------------------------------------------------------------------------------

class MatchCounter {
public:
    void add(int delta) {
        {
            std::lock_guard<std::mutex> lock(mtx_);
            count_ += delta;
        }
        cv_.notify_all();
    }

    bool waitFor(int expected, int timeoutSec) {
        std::unique_lock<std::mutex> lock(mtx_);
        return cv_.wait_for(lock, std::chrono::seconds(timeoutSec),
                            [&] { return count_ >= expected; });
    }

    int current() {
        std::lock_guard<std::mutex> lock(mtx_);
        return count_;
    }

private:
    std::mutex mtx_;
    std::condition_variable cv_;
    int count_ = 0;
};

class WriterListener : public DataWriterListener {
public:
    explicit WriterListener(MatchCounter* counter) : counter_(counter) {}

    void on_publication_matched(DataWriter*, const PublicationMatchedStatus& info) override {
        if (counter_ != nullptr) counter_->add(info.current_count_change);
    }

private:
    MatchCounter* counter_;
};

// ---------------------------------------------------------------------------------------
// Receive side
//
// Each ReaderListener owns its counters and sample buffer and takes no lock in the
// callback: Fast DDS serialises on_data_available per DataReader, so per-listener state is
// safe, and the merge happens once at the end. A shared mutex-protected collector would
// have put a lock on the hot path of the very thing a throughput test measures.
// ---------------------------------------------------------------------------------------

class ReaderListener : public DataReaderListener {
public:
    ReaderListener(uint32_t payloadSize, bool keepSamples, MatchCounter* matches,
                   uint64_t expectedSamples, int workUs, const std::string& clock)
        : keepSamples_(keepSamples), matches_(matches), workUs_(workUs), clock_(clock) {
        scratch_.bytes.resize(payloadSize);
        // Reserve up front. Fast DDS calls on_data_available on its RECEPTION thread, so
        // anything slow in here stops the transport being drained — and a vector growing
        // to 100k entries reallocates ~17 times, each copying the whole buffer, right on
        // that thread. Cheap to avoid, so avoid it.
        if (keepSamples && expectedSamples > 0) {
            samples_.reserve(static_cast<size_t>(expectedSamples));
        }
    }

    void on_subscription_matched(DataReader*, const SubscriptionMatchedStatus& info) override {
        if (matches_ != nullptr) matches_->add(info.current_count_change);
    }

    void on_data_available(DataReader* reader) override {
        SampleInfo info;
        while (reader->take_next_sample(&scratch_, &info) == ReturnCode_t::RETCODE_OK) {
            if (!info.valid_data) continue;
            const int64_t recvNs = clock_ == "realtime" ? realtimeNs() : nowNs();

            if (count_ == 0) firstNs_ = recvNs;
            lastNs_ = recvNs;
            ++count_;
            bytes_ += scratch_.bytes.size();

            uint64_t seq = 0;
            int64_t sendNs = 0;
            std::memcpy(&seq, scratch_.bytes.data(), sizeof(seq));
            std::memcpy(&sendNs, scratch_.bytes.data() + sizeof(seq), sizeof(sendNs));
            if (keepSamples_) {
                samples_.push_back({seq, static_cast<double>(recvNs - sendNs) / 1000.0});
            }

            // Per-second receive buckets: cheap, and the only way to tell whether a
            // throughput figure is a steady rate or an early burst followed by loss.
            const auto bucket = static_cast<size_t>((recvNs - firstNs_) / 1000000000LL);
            if (buckets_.size() <= bucket) buckets_.resize(bucket + 1, 0);
            ++buckets_[bucket];

            if (onSample_) onSample_(scratch_);

            // Simulated application work per sample (--sub-work-us). Busy-spins rather
            // than sleeping, so it models a subscriber that is CPU-busy rather than one
            // that has yielded the core. Because this callback runs on the reception
            // thread, this is exactly the knob that answers "how fast must my application
            // consume to avoid loss?" — see README.md.
            if (workUs_ > 0) {
                const auto until = Clock::now() + std::chrono::microseconds(workUs_);
                while (Clock::now() < until) {
                }
            }
        }
    }

    // Optional hook, used by the RTT echo side to re-publish what it just received.
    void setOnSample(std::function<void(const BenchSample&)> fn) { onSample_ = std::move(fn); }

    uint64_t count() const { return count_; }
    uint64_t bytes() const { return bytes_; }
    int64_t firstNs() const { return firstNs_; }
    int64_t lastNs() const { return lastNs_; }
    const std::vector<Sample>& samples() const { return samples_; }
    const std::vector<uint64_t>& buckets() const { return buckets_; }

private:
    BenchSample scratch_;
    bool keepSamples_;
    MatchCounter* matches_;
    int workUs_ = 0;
    std::string clock_;
    uint64_t count_ = 0;
    uint64_t bytes_ = 0;
    int64_t firstNs_ = 0;
    int64_t lastNs_ = 0;
    std::vector<Sample> samples_;
    std::vector<uint64_t> buckets_;
    std::function<void(const BenchSample&)> onSample_;
};

// ---------------------------------------------------------------------------------------
// Participant / endpoint construction
// ---------------------------------------------------------------------------------------

void configureTransport(DomainParticipantQos& qos, const Options& opt) {
    // ALWAYS explicit — never the builtin default. The builtin stack enables shared memory
    // alongside UDP, and two containers on the same Docker host can match an SHM locator
    // while owning completely separate /dev/shm mounts; samples then go into a segment the
    // peer never reads and the run reports total loss with no error anywhere. Naming the
    // transport removes that failure mode entirely.
    qos.transport().use_builtin_transports = false;

    if (opt.transport == "udp") {
        auto udp = std::make_shared<fdrtps::UDPv4TransportDescriptor>();
        // Raise the socket buffers well above the default: an unthrottled best-effort
        // blast otherwise overruns the kernel socket buffer, and the loss measured is the
        // socket's, not the middleware's.
        udp->sendBufferSize = 8 * 1024 * 1024;
        udp->receiveBufferSize = 8 * 1024 * 1024;
        qos.transport().user_transports.push_back(udp);
    } else if (opt.transport == "shm") {
        auto shm = std::make_shared<fdrtps::SharedMemTransportDescriptor>();
        qos.transport().user_transports.push_back(shm);
    } else {
        fail("--transport must be 'udp' or 'shm' (got '" + opt.transport +
             "'). TCP is not implemented — see TODO.md #3.");
    }
}

void configureDiscovery(DomainParticipantQos& qos, const Options& opt) {
    auto& config = qos.wire_protocol().builtin.discovery_config;
    if (opt.discovery == "simple") {
        config.discoveryProtocol = frtps::DiscoveryProtocol_t::SIMPLE;
        return;
    }
    if (opt.discovery != "server") {
        fail("--discovery must be 'simple' or 'server' (got '" + opt.discovery + "')");
    }

    // Discovery Server mode: this participant is a CLIENT of an external
    // `fast-discovery-server` process (scripts/start-discovery-server.sh). Wired up in
    // code rather than through the ROS_DISCOVERY_SERVER environment variable, so the
    // configuration is explicit and version-controlled.
    config.discoveryProtocol = frtps::DiscoveryProtocol_t::CLIENT;

    frtps::RemoteServerAttributes server;
    if (!server.ReadguidPrefix(opt.dsGuid.c_str())) {
        fail("could not parse --discovery-server-guid '" + opt.dsGuid + "'");
    }
    frtps::Locator_t locator;
    locator.kind = LOCATOR_KIND_UDPv4;
    if (!frtps::IPLocator::setIPv4(locator, opt.dsAddress)) {
        fail("could not parse --discovery-server-address '" + opt.dsAddress + "'");
    }
    locator.port = opt.dsPort;
    server.metatrafficUnicastLocatorList.push_back(locator);
    config.m_DiscoveryServers.push_back(server);
}

DomainParticipant* makeParticipant(const Options& opt, const std::string& name) {
    DomainParticipantQos qos = PARTICIPANT_QOS_DEFAULT;
    qos.name(name.c_str());
    configureTransport(qos, opt);
    configureDiscovery(qos, opt);

    DomainParticipant* participant =
        DomainParticipantFactory::get_instance()->create_participant(opt.domain, qos);
    if (participant == nullptr) {
        fail("failed to create DomainParticipant '" + name + "' on domain " +
             std::to_string(opt.domain));
    }
    return participant;
}

void applyReliability(const Options& opt, ReliabilityQosPolicy& reliability,
                      DurabilityQosPolicy& durability, HistoryQosPolicy& historyQos) {
    if (opt.reliability == "best_effort") {
        reliability.kind = BEST_EFFORT_RELIABILITY_QOS;
    } else if (opt.reliability == "reliable") {
        reliability.kind = RELIABLE_RELIABILITY_QOS;
    } else {
        fail("--reliability must be 'best_effort' or 'reliable' (got '" + opt.reliability + "')");
    }

    if (opt.durability == "volatile") {
        durability.kind = VOLATILE_DURABILITY_QOS;
    } else if (opt.durability == "transient_local") {
        durability.kind = TRANSIENT_LOCAL_DURABILITY_QOS;
    } else {
        fail("--durability must be 'volatile' or 'transient_local' (got '" + opt.durability + "')");
    }

    if (opt.history == "keep_last") {
        historyQos.kind = KEEP_LAST_HISTORY_QOS;
        historyQos.depth = opt.historyDepth;
    } else if (opt.history == "keep_all") {
        historyQos.kind = KEEP_ALL_HISTORY_QOS;
    } else {
        fail("--history must be 'keep_last' or 'keep_all' (got '" + opt.history + "')");
    }
}

// WriterTimes/ReaderTimes field type: Duration_t lives in eprosima::fastrtps, NOT in
// eprosima::fastrtps::rtps, even though the structs holding it are in the rtps namespace.
void setDuration(eprosima::fastrtps::Duration_t& d, int microseconds) {
    d.seconds = microseconds / 1000000;
    d.nanosec = static_cast<uint32_t>(microseconds % 1000000) * 1000u;
}

std::string topicName(const Options& opt, uint32_t index) {
    if (opt.topicCount <= 1) return opt.topic;
    return opt.topic + "_" + std::to_string(index);
}

// A participant plus everything created from it, kept together so teardown stays ordered
// and no listener outlives a Fast DDS entity that could still call into it.
struct Endpoints {
    DomainParticipant* participant = nullptr;
    Publisher* publisher = nullptr;
    Subscriber* subscriber = nullptr;
    std::vector<Topic*> topics;
    std::vector<DataWriter*> writers;
    std::vector<DataReader*> readers;
    std::vector<std::unique_ptr<WriterListener>> writerListeners;
    std::vector<std::unique_ptr<ReaderListener>> readerListeners;
};

void createTopics(Endpoints& ep, const Options& opt, const std::vector<std::string>& names) {
    TypeSupport type(new BenchType(static_cast<uint32_t>(opt.size)));
    type.register_type(ep.participant);
    for (const auto& name : names) {
        Topic* topic = ep.participant->create_topic(name, type.get_type_name(), TOPIC_QOS_DEFAULT);
        if (topic == nullptr) fail("failed to create topic '" + name + "'");
        ep.topics.push_back(topic);
    }
}

// `topics` is passed explicitly rather than taken from ep.topics: the RTT roles put their
// writer and their reader on *different* topics of the same participant.
void createWriters(Endpoints& ep, const Options& opt, const std::vector<Topic*>& topics,
                   MatchCounter* matches) {
    if (ep.publisher == nullptr) {
        ep.publisher = ep.participant->create_publisher(PUBLISHER_QOS_DEFAULT);
        if (ep.publisher == nullptr) fail("failed to create Publisher");
    }

    DataWriterQos wqos = DATAWRITER_QOS_DEFAULT;
    applyReliability(opt, wqos.reliability(), wqos.durability(), wqos.history());
    wqos.publish_mode().kind =
        (opt.publishMode == "async") ? ASYNCHRONOUS_PUBLISH_MODE : SYNCHRONOUS_PUBLISH_MODE;
    // RELIABLE has to hold unacknowledged samples; the default max_samples (5000) turns
    // into a write() stall long before a benchmark run finishes. 0 = unlimited.
    wqos.resource_limits().max_samples = 0;
    wqos.resource_limits().max_instances = 1;
    wqos.resource_limits().max_samples_per_instance = 0;
    // See Options::heartbeatPeriodMs for why the 3-second default is not usable here.
    setDuration(wqos.reliable_writer_qos().times.heartbeatPeriod, opt.heartbeatPeriodMs * 1000);
    setDuration(wqos.reliable_writer_qos().times.nackResponseDelay, opt.nackResponseDelayUs);

    for (Topic* topic : topics) {
        ep.writerListeners.push_back(std::make_unique<WriterListener>(matches));
        DataWriter* writer =
            ep.publisher->create_datawriter(topic, wqos, ep.writerListeners.back().get());
        if (writer == nullptr) fail("failed to create DataWriter on '" + topic->get_name() + "'");
        ep.writers.push_back(writer);
    }
}

void createReaders(Endpoints& ep, const Options& opt, const std::vector<Topic*>& topics,
                   bool keepSamples, MatchCounter* matches) {
    // Per reader, so divide the run's total by however many topics this participant reads.
    const uint64_t expectedPerReader = topics.empty() ? 0 : opt.msgs / topics.size() + 1;
    if (ep.subscriber == nullptr) {
        ep.subscriber = ep.participant->create_subscriber(SUBSCRIBER_QOS_DEFAULT);
        if (ep.subscriber == nullptr) fail("failed to create Subscriber");
    }

    DataReaderQos rqos = DATAREADER_QOS_DEFAULT;
    applyReliability(opt, rqos.reliability(), rqos.durability(), rqos.history());
    rqos.resource_limits().max_samples = 0;
    rqos.resource_limits().max_instances = 1;
    rqos.resource_limits().max_samples_per_instance = 0;
    setDuration(rqos.reliable_reader_qos().times.heartbeatResponseDelay,
                opt.heartbeatResponseDelayUs);

    for (Topic* topic : topics) {
        ep.readerListeners.push_back(std::make_unique<ReaderListener>(
            static_cast<uint32_t>(opt.size), keepSamples, matches, expectedPerReader,
            opt.subWorkUs, opt.clock));
        DataReader* reader =
            ep.subscriber->create_datareader(topic, rqos, ep.readerListeners.back().get());
        if (reader == nullptr) fail("failed to create DataReader on '" + topic->get_name() + "'");
        ep.readers.push_back(reader);
    }
}

void destroyEndpoints(Endpoints& ep) {
    if (ep.participant == nullptr) return;
    ep.participant->delete_contained_entities();
    DomainParticipantFactory::get_instance()->delete_participant(ep.participant);
    ep.participant = nullptr;
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
        // Deliberate busy spin — see Options::pacing for why sleeping cannot hit these
        // intervals and what it costs when it tries.
    }
}

// How many cores this PROCESS may actually use.
//
// Deliberately not std::thread::hardware_concurrency(): libstdc++ implements it with
// sysconf(_SC_NPROCESSORS_ONLN), which reports the host's online CPUs and ignores both
// container CPU limits. Confirmed here — under `docker run --cpuset-cpus=0,1` it still
// reported 12. Since this tool only ever runs inside a container, that made the warning
// below useless in exactly the situation it exists for.
//
//   sched_getaffinity : honours --cpuset-cpus (and taskset)
//   cgroup cpu quota  : honours --cpus / compose `cpus:` (v2 cpu.max, v1 cfs_quota_us)
//
// Returns the smaller of the two, or 0 when nothing can be determined.
unsigned availableCores() {
    unsigned fromAffinity = 0;
    cpu_set_t set;
    CPU_ZERO(&set);
    if (sched_getaffinity(0, sizeof(set), &set) == 0) {
        fromAffinity = static_cast<unsigned>(CPU_COUNT(&set));
    }

    unsigned fromQuota = 0;
    // cgroup v2: "<quota> <period>", or "max <period>" when unlimited.
    if (std::ifstream v2("/sys/fs/cgroup/cpu.max"); v2) {
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

// A spinning publisher occupies a whole core per thread. If the machine cannot also give
// the Fast DDS reception threads a core, the spin starves the very receive path the run is
// measuring and makes the result worse than reality — the opposite of the intent. Warn
// rather than refuse: the caller may know better (dedicated cores, pinned threads).
void warnIfPacingWillStarveReceiver(const Options& opt, uint64_t publisherThreads) {
    if (opt.rate <= 0.0 || opt.pacing == "sleep") return;
    const unsigned cores = availableCores();
    if (cores == 0) return;  // unknown; nothing useful to say
    const uint64_t needed = publisherThreads + 3;  // publishers + reception/app headroom
    if (needed > cores) {
        std::cerr << "WARNING: --pacing " << opt.pacing << " busy-spins one core per "
                  << "publisher thread (" << publisherThreads << " here), but only " << cores
                  << " core(s) are available to this process. The spin will compete with Fast DDS's reception "
                     "threads and inflate the latency being measured. Use --pacing sleep, "
                     "lower --pub-count, or run on a machine with at least "
                  << needed << " cores." << std::endl;
    }
}

struct PubResult {
    uint64_t sent = 0;
    double durationSec = 0.0;  // the send loop only - see ackWaitSec
    double ackWaitSec = 0.0;   // RELIABLE only: time spent in wait_for_acknowledgments
    uint64_t bytes = 0;
};

// Publishes `total` messages across `groups` (one group = one publisher participant with
// one writer per topic), round-robin over that group's topics, at an aggregate rate of
// opt.rate msgs/sec (0 = unthrottled). Sequence numbers come from a shared atomic so they
// stay globally unique across publisher threads.
PubResult publishAll(const std::vector<Endpoints*>& groups, const Options& opt, uint64_t total) {
    std::atomic<uint64_t> nextSeq{0};
    const auto groupCount = static_cast<uint64_t>(groups.size());
    warnIfPacingWillStarveReceiver(opt, groupCount);
    const auto start = Clock::now();

    std::vector<std::thread> threads;
    threads.reserve(groups.size());
    for (uint64_t g = 0; g < groupCount; ++g) {
        // Each thread takes an equal share; the last absorbs the remainder so the total is
        // exactly `total` regardless of divisibility.
        const uint64_t share = total / groupCount + ((g == groupCount - 1) ? total % groupCount : 0);
        threads.emplace_back([&, g, share]() {
            Endpoints* ep = groups[g];
            BenchSample sample;
            sample.bytes.assign(static_cast<size_t>(opt.size), 0);
            // Per-thread interval for a target AGGREGATE rate: each of the N publisher
            // threads must therefore wait N times longer than 1/rate.
            const bool paced = opt.rate > 0.0;
            const auto interval = std::chrono::duration<double>(
                paced ? (static_cast<double>(groupCount) / opt.rate) : 0.0);

            for (uint64_t i = 0; i < share; ++i) {
                const auto sendStart = Clock::now();
                const uint64_t seq = nextSeq.fetch_add(1);
                const int64_t ts = opt.clock == "realtime" ? realtimeNs() : nowNs();
                std::memcpy(sample.bytes.data(), &seq, sizeof(seq));
                std::memcpy(sample.bytes.data() + sizeof(seq), &ts, sizeof(ts));
                ep->writers[i % ep->writers.size()]->write(&sample);
                if (paced) {
                    pacedWaitUntil(
                        sendStart + std::chrono::duration_cast<Clock::duration>(interval),
                        opt.pacing);
                }
            }
        });
    }
    for (auto& t : threads) t.join();
    const auto sendEnd = Clock::now();

    // Under RELIABLE, write() only queues — wait for acknowledgements so a completed run
    // really means "delivered to the matched readers", not "handed to the middleware".
    //
    // This is timed SEPARATELY from the send loop and excluded from pub.msgs_per_sec. The
    // ack wait is gated by the writer's heartbeat period, which is a QoS setting, not a
    // throughput limit: folding it in made a 1000-message run at 2000 msgs/s report
    // 332 msgs/s, describing the heartbeat rather than the publisher. It is reported as
    // its own metrics.pub.ack_wait_sec field so it stays visible instead of vanishing.
    if (opt.reliability == "reliable") {
        const eprosima::fastrtps::Duration_t ackWait(opt.matchTimeoutSec, 0);
        for (Endpoints* ep : groups) {
            for (DataWriter* w : ep->writers) w->wait_for_acknowledgments(ackWait);
        }
    }

    PubResult result;
    result.sent = total;
    result.durationSec = std::chrono::duration<double>(sendEnd - start).count();
    result.ackWaitSec = std::chrono::duration<double>(Clock::now() - sendEnd).count();
    result.bytes = total * static_cast<uint64_t>(opt.size);

    // A run that asked for one rate and delivered another has measured a condition it does
    // not report. This went unnoticed once already (a requested 10000/s achieved ~4900/s
    // under --pacing sleep), so say it out loud rather than leaving it to be spotted in
    // result.json.
    if (opt.rate > 0.0 && result.durationSec > 0.0) {
        const double achieved = static_cast<double>(result.sent) / result.durationSec;
        if (achieved < opt.rate * 0.9) {
            std::cerr << "WARNING: requested --rate " << opt.rate << " msgs/sec but only achieved "
                      << achieved << ". The measured latency belongs to the achieved rate, not "
                      << "the requested one."
                      << (opt.pacing == "sleep"
                              ? " --pacing sleep cannot hit short intervals; try --pacing auto."
                              : " The publisher cannot keep up at this rate on this machine.")
                      << std::endl;
        }
    }
    return result;
}

// ---------------------------------------------------------------------------------------
// Receive-side aggregation
// ---------------------------------------------------------------------------------------

struct SubResult {
    uint64_t received = 0;
    uint64_t bytes = 0;
    double durationSec = 0.0;
    std::vector<Sample> samples;
    std::vector<uint64_t> buckets;
};

uint64_t totalReceived(const std::vector<Endpoints*>& groups) {
    uint64_t sum = 0;
    for (const Endpoints* ep : groups) {
        for (const auto& listener : ep->readerListeners) sum += listener->count();
    }
    return sum;
}

SubResult collect(const std::vector<Endpoints*>& groups) {
    SubResult result;
    int64_t first = 0;
    int64_t last = 0;
    for (const Endpoints* ep : groups) {
        for (const auto& listener : ep->readerListeners) {
            if (listener->count() == 0) continue;
            result.received += listener->count();
            result.bytes += listener->bytes();
            if (first == 0 || listener->firstNs() < first) first = listener->firstNs();
            if (listener->lastNs() > last) last = listener->lastNs();

            const auto& samples = listener->samples();
            result.samples.insert(result.samples.end(), samples.begin(), samples.end());

            const auto& buckets = listener->buckets();
            if (result.buckets.size() < buckets.size()) result.buckets.resize(buckets.size(), 0);
            for (size_t i = 0; i < buckets.size(); ++i) result.buckets[i] += buckets[i];
        }
    }
    if (last > first) result.durationSec = static_cast<double>(last - first) / 1e9;
    return result;
}

// Waits until `expected` messages have arrived, or until nothing new has arrived for
// idleTimeoutSec, or until the hard timeout. The idle check is what makes an unthrottled
// BEST_EFFORT throughput run terminate at all: real loss there is the expected outcome, so
// "wait for the full count" would always run to the hard timeout.
void waitForReceipt(const std::vector<Endpoints*>& groups, uint64_t expected, const Options& opt) {
    const auto hardDeadline = Clock::now() + std::chrono::seconds(opt.timeoutSec);
    auto lastProgress = Clock::now();
    uint64_t lastCount = 0;

    while (Clock::now() < hardDeadline) {
        const uint64_t current = totalReceived(groups);
        if (current >= expected) return;
        if (current != lastCount) {
            lastCount = current;
            lastProgress = Clock::now();
        } else if (current > 0 &&
                   Clock::now() - lastProgress > std::chrono::seconds(opt.idleTimeoutSec)) {
            return;  // stream went quiet — the rest was lost
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
    size_t idx = static_cast<size_t>(std::ceil(p / 100.0 * sorted.size()));
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

void writeBucketCsv(const std::string& path, const std::vector<uint64_t>& buckets, int size) {
    std::ofstream csv(path);
    csv << "Second,MsgsReceived,BytesReceived\n";
    for (size_t i = 0; i < buckets.size(); ++i) {
        csv << i << "," << buckets[i] << "," << (buckets[i] * static_cast<uint64_t>(size)) << "\n";
    }
}

std::string paramsJson(const Options& opt, uint64_t totalMsgs) {
    std::ostringstream j;
    j << "    \"topic\": \"" << opt.topic << "\",\n"
      << "    \"topic_count\": " << opt.topicCount << ",\n"
      << "    \"domain\": " << opt.domain << ",\n"
      << "    \"size\": " << opt.size << ",\n"
      << "    \"msgs\": " << totalMsgs << ",\n"
      << "    \"rate\": " << opt.rate << ",\n"
      << "    \"duration_sec\": " << opt.durationSec << ",\n"
      << "    \"pub_count\": " << opt.pubCount << ",\n"
      << "    \"sub_count\": " << opt.subCount << ",\n"
      << "    \"reliability\": \"" << opt.reliability << "\",\n"
      << "    \"durability\": \"" << opt.durability << "\",\n"
      << "    \"history\": \"" << opt.history << "\",\n"
      << "    \"history_depth\": " << opt.historyDepth << ",\n"
      << "    \"heartbeat_period_ms\": " << opt.heartbeatPeriodMs << ",\n"
      << "    \"publish_mode\": \"" << opt.publishMode << "\",\n"
      << "    \"transport\": \"" << opt.transport << "\",\n"
      << "    \"discovery\": \"" << opt.discovery << "\",\n"
      << "    \"intraprocess\": \"" << opt.intraprocess << "\",\n"
      << "    \"pacing\": \"" << opt.pacing << "\",\n"
      << "    \"sub_work_us\": " << opt.subWorkUs << ",\n"
      << "    \"nack_response_delay_us\": " << opt.nackResponseDelayUs << ",\n"
      << "    \"heartbeat_response_delay_us\": " << opt.heartbeatResponseDelayUs;
    j << ",\n"
      << "    \"clock\": \"" << opt.clock << "\"";
    return j.str();
}

std::string environmentJson() {
    std::ostringstream j;
    j << "    \"dds_bench_version\": \"" << kToolVersion << "\",\n"
#ifdef FASTRTPS_VERSION_STR
      << "    \"fastdds_version\": \"" << FASTRTPS_VERSION_STR << "\",\n"
#endif
      << "    \"runtime\": \"CentOS 7 / gcc 11 / C++17\"";
    return j.str();
}

// result.json deliberately mirrors nats/'s schema — same key names, same units (latency in
// microseconds, throughput in msgs/sec and MB/sec, msg_loss at the top level) — so
// results/run-index.csv rows from the two projects line up column for column.
void writeResultJson(const Options& opt, uint64_t totalMsgs, const PubResult* pub,
                     const SubResult* sub, const LatencyStats* latency, uint64_t msgsSent,
                     uint64_t msgsReceived, uint64_t msgLoss) {
    std::ostringstream j;
    j << "{\n"
      << "  \"mode\": \"" << opt.mode << "\",\n"
      << "  \"measure\": \"" << opt.measure << "\",\n"
      << "  \"params\": {\n"
      << paramsJson(opt, totalMsgs) << "\n"
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
        const double mbps = pub->durationSec > 0 ? (pub->bytes / pub->durationSec) / 1048576.0 : 0.0;
        j << "    \"pub\": { \"msgs_per_sec\": " << mps << ", \"mb_per_sec\": " << mbps
          << ", \"duration_sec\": " << pub->durationSec
          << ", \"ack_wait_sec\": " << pub->ackWaitSec << " }";
        needComma = true;
    }
    if (sub != nullptr) {
        if (needComma) j << ",\n";
        const double mps = sub->durationSec > 0 ? sub->received / sub->durationSec : 0.0;
        const double mbps = sub->durationSec > 0 ? (sub->bytes / sub->durationSec) / 1048576.0 : 0.0;
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
        else if (arg == "--topic") opt.topic = next("--topic");
        else if (arg == "--topic-count") opt.topicCount = std::stoul(next("--topic-count"));
        else if (arg == "--domain") opt.domain = std::stoul(next("--domain"));
        else if (arg == "--size") opt.size = std::stoi(next("--size"));
        else if (arg == "--msgs") { opt.msgs = std::stoull(next("--msgs")); opt.msgsGiven = true; }
        else if (arg == "--rate") opt.rate = std::stod(next("--rate"));
        else if (arg == "--duration-sec") opt.durationSec = std::stod(next("--duration-sec"));
        else if (arg == "--pub-count") opt.pubCount = std::stoul(next("--pub-count"));
        else if (arg == "--sub-count") opt.subCount = std::stoul(next("--sub-count"));
        else if (arg == "--reliability") opt.reliability = next("--reliability");
        else if (arg == "--durability") opt.durability = next("--durability");
        else if (arg == "--history") opt.history = next("--history");
        else if (arg == "--history-depth") opt.historyDepth = std::stoi(next("--history-depth"));
        else if (arg == "--heartbeat-period-ms") opt.heartbeatPeriodMs = std::stoi(next("--heartbeat-period-ms"));
        else if (arg == "--publish-mode") opt.publishMode = next("--publish-mode");
        else if (arg == "--transport") opt.transport = next("--transport");
        else if (arg == "--discovery") opt.discovery = next("--discovery");
        else if (arg == "--discovery-server-address") opt.dsAddress = next("--discovery-server-address");
        else if (arg == "--discovery-server-port") opt.dsPort = std::stoul(next("--discovery-server-port"));
        else if (arg == "--discovery-server-guid") opt.dsGuid = next("--discovery-server-guid");
        else if (arg == "--intraprocess") opt.intraprocess = next("--intraprocess");
        else if (arg == "--nack-response-delay-us") opt.nackResponseDelayUs = std::stoi(next("--nack-response-delay-us"));
        else if (arg == "--heartbeat-response-delay-us") opt.heartbeatResponseDelayUs = std::stoi(next("--heartbeat-response-delay-us"));
        else if (arg == "--pacing") opt.pacing = next("--pacing");
        else if (arg == "--clock") opt.clock = next("--clock");
        else if (arg == "--sub-work-us") opt.subWorkUs = std::stoi(next("--sub-work-us"));
        else if (arg == "--out") opt.out = next("--out");
        else if (arg == "--match-timeout-sec") opt.matchTimeoutSec = std::stoi(next("--match-timeout-sec"));
        else if (arg == "--idle-timeout-sec") opt.idleTimeoutSec = std::stoi(next("--idle-timeout-sec"));
        else if (arg == "--timeout-sec") opt.timeoutSec = std::stoi(next("--timeout-sec"));
        else fail("unknown argument: " + arg);
    }

    if (opt.measure != "throughput" && opt.measure != "latency" && opt.measure != "rtt") {
        fail("--measure must be one of: throughput, latency, rtt (got '" + opt.measure + "')");
    }
    if (opt.mode != "both" && opt.mode != "pub" && opt.mode != "sub") {
        fail("--mode must be one of: both, pub, sub (got '" + opt.mode + "')");
    }
    if (opt.size < static_cast<int>(kHeaderSize)) {
        fail("--size must be >= " + std::to_string(kHeaderSize) +
             " bytes (room for the seq + timestamp header)");
    }
    if (opt.topicCount < 1) fail("--topic-count must be >= 1");
    if (opt.pubCount < 1) fail("--pub-count must be >= 1");
    if (opt.subCount < 1) fail("--sub-count must be >= 1");

    if (opt.measure == "latency" || opt.measure == "rtt") {
        // Same rule as nats/tools/latency_oneway: rate and duration are the axis, the
        // message count is derived. An unthrottled burst measures subscriber backlog.
        if (opt.msgsGiven) {
            fail("--msgs is not accepted with --measure " + opt.measure +
                 " — use --rate and --duration-sec; the total count is derived as "
                 "round(rate * duration). See TODO.md #2.");
        }
        if (opt.rate <= 0.0) {
            fail("--rate is required and must be > 0 (target msgs/sec) with --measure " +
                 opt.measure +
                 ". There is deliberately no 'burst as fast as possible' latency mode: an "
                 "unthrottled send measures the queueing delay of a backlog the publisher "
                 "built up, not the middleware's steady-state latency.");
        }
        if (opt.durationSec <= 0.0) fail("--duration-sec must be > 0");
        opt.msgs = static_cast<uint64_t>(std::llround(opt.rate * opt.durationSec));
        if (opt.msgs == 0) opt.msgs = 1;
    }

    if (opt.publishMode == "auto") {
        // A sample larger than one UDP datagram must be fragmented, and Fast DDS only
        // fragments in ASYNCHRONOUS publish mode — in SYNCHRONOUS mode the write simply
        // never arrives. Switch automatically, so a large --size doesn't look like 100%
        // message loss.
        opt.publishMode = (opt.size >= kFragmentationThreshold) ? "async" : "sync";
    } else if (opt.publishMode != "sync" && opt.publishMode != "async") {
        fail("--publish-mode must be 'sync', 'async' or 'auto' (got '" + opt.publishMode + "')");
    }
    if (opt.pacing != "auto" && opt.pacing != "sleep" && opt.pacing != "busy") {
        fail("--pacing must be 'auto', 'sleep' or 'busy' (got '" + opt.pacing + "')");
    }
    if (opt.intraprocess != "on" && opt.intraprocess != "off") {
        fail("--intraprocess must be 'on' or 'off' (got '" + opt.intraprocess + "')");
    }
    if (opt.clock != "monotonic" && opt.clock != "realtime") {
        fail("--clock must be 'monotonic' or 'realtime' (got '" + opt.clock + "')");
    }

    if (opt.timeoutSec < 0) {
        const double nominal =
            (opt.rate > 0.0) ? (static_cast<double>(opt.msgs) / opt.rate) : opt.durationSec;
        opt.timeoutSec = static_cast<int>(std::ceil(nominal)) + opt.matchTimeoutSec + 30;
    }
    return opt;
}

void applyLibrarySettings(const Options& opt) {
    // Fast DDS routes samples between endpoints in the same PROCESS through an
    // intra-process shortcut that skips the RTPS transport entirely, and
    // LibrarySettingsAttributes.h shows the built-in default is INTRAPROCESS_FULL. Under
    // --mode both that would make this tool measure a memcpy and report sub-microsecond
    // "network" latency. Off by default here; --intraprocess on is there for deliberately
    // measuring that path. MUST run before any participant is created.
    //
    // In Fast DDS 2.x this lives on XMLProfileManager, NOT on DomainParticipantFactory —
    // the factory's get_library_settings/set_library_settings pair is a 3.x addition and
    // does not compile against 2.14 (confirmed against the installed headers).
    eprosima::fastrtps::LibrarySettingsAttributes settings =
        eprosima::fastrtps::xmlparser::XMLProfileManager::library_settings();
    settings.intraprocess_delivery = (opt.intraprocess == "on")
                                         ? eprosima::fastrtps::INTRAPROCESS_FULL
                                         : eprosima::fastrtps::INTRAPROCESS_OFF;
    eprosima::fastrtps::xmlparser::XMLProfileManager::library_settings(settings);
}

// ---------------------------------------------------------------------------------------
// Runners
// ---------------------------------------------------------------------------------------

std::vector<std::string> allTopicNames(const Options& opt) {
    std::vector<std::string> names;
    for (uint32_t t = 0; t < opt.topicCount; ++t) names.push_back(topicName(opt, t));
    return names;
}

// throughput and latency share the whole pipeline; they differ only in pacing (enforced in
// parseArgs), whether per-message samples are retained, and which metrics get reported.
int runPubSub(const Options& opt) {
    const bool keepSamples = (opt.measure == "latency");
    const auto names = allTopicNames(opt);
    const uint64_t totalMsgs = opt.msgs;

    MatchCounter pubMatches;
    MatchCounter subMatches;

    std::vector<std::unique_ptr<Endpoints>> owned;
    std::vector<Endpoints*> pubGroups;
    std::vector<Endpoints*> subGroups;

    if (opt.mode == "both" || opt.mode == "sub") {
        for (uint32_t s = 0; s < opt.subCount; ++s) {
            owned.push_back(std::make_unique<Endpoints>());
            Endpoints* ep = owned.back().get();
            ep->participant = makeParticipant(opt, "dds_bench_sub_" + std::to_string(s));
            createTopics(*ep, opt, names);
            createReaders(*ep, opt, ep->topics, keepSamples, &subMatches);
            subGroups.push_back(ep);
        }
    }
    if (opt.mode == "both" || opt.mode == "pub") {
        for (uint32_t p = 0; p < opt.pubCount; ++p) {
            owned.push_back(std::make_unique<Endpoints>());
            Endpoints* ep = owned.back().get();
            ep->participant = makeParticipant(opt, "dds_bench_pub_" + std::to_string(p));
            createTopics(*ep, opt, names);
            createWriters(*ep, opt, ep->topics, &pubMatches);
            pubGroups.push_back(ep);
        }
    }

    int exitCode = 0;
    PubResult pub;
    SubResult sub;

    if (!pubGroups.empty()) {
        // Every writer must see every subscriber participant's reader on its own topic:
        // pubCount * topicCount writers, each matching subCount readers.
        const int expected = static_cast<int>(opt.pubCount * opt.topicCount * opt.subCount);
        std::cerr << "dds_bench: waiting for " << expected << " publication match(es)..."
                  << std::endl;
        if (!pubMatches.waitFor(expected, opt.matchTimeoutSec)) {
            std::cerr << "ERROR: only " << pubMatches.current() << " of " << expected
                      << " publication matches within " << opt.matchTimeoutSec
                      << "s. With --discovery simple this usually means multicast discovery "
                         "is not getting through (common on a Docker bridge network) — retry "
                         "with --discovery server. See README.md."
                      << std::endl;
            exitCode = 1;
        }
    }
    if (!subGroups.empty() && opt.mode == "sub") {
        const int expected = static_cast<int>(opt.subCount * opt.topicCount * opt.pubCount);
        std::cerr << "dds_bench: waiting for " << expected << " subscription match(es)..."
                  << std::endl;
        if (!subMatches.waitFor(expected, opt.matchTimeoutSec)) {
            std::cerr << "ERROR: only " << subMatches.current() << " of " << expected
                      << " subscription matches within " << opt.matchTimeoutSec
                      << "s. See the --discovery note in README.md." << std::endl;
            exitCode = 1;
        }
    }

    if (exitCode == 0 && !pubGroups.empty()) {
        pub = publishAll(pubGroups, opt, totalMsgs);
    }
    if (exitCode == 0 && !subGroups.empty()) {
        // Fan-out, exactly as on the NATS side: every subscriber participant holds its own
        // reader per topic, so each receives a full copy of the published stream.
        waitForReceipt(subGroups, totalMsgs * opt.subCount, opt);
        sub = collect(subGroups);
    }

    const uint64_t expectedDeliveries = totalMsgs * opt.subCount;
    const uint64_t msgsReceived = sub.received;
    uint64_t msgLoss = 0;
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

    writeResultJson(opt, totalMsgs, pubGroups.empty() ? nullptr : &pub,
                    subGroups.empty() ? nullptr : &sub, keepSamples ? &stats : nullptr,
                    pubGroups.empty() ? 0 : pub.sent, msgsReceived, msgLoss);

    std::cout << "measure=" << opt.measure << " mode=" << opt.mode
              << " msgs_sent=" << (pubGroups.empty() ? 0 : pub.sent)
              << " msgs_received=" << msgsReceived << " expected=" << expectedDeliveries
              << " msg_loss=" << msgLoss;
    if (stats.valid) std::cout << " p50_us=" << stats.p50 << " p99_us=" << stats.p99;
    if (!subGroups.empty() && sub.durationSec > 0) {
        std::cout << " sub_msgs_per_sec=" << (sub.received / sub.durationSec);
    }
    std::cout << std::endl;

    for (auto& ep : owned) destroyEndpoints(*ep);

    // Message loss is NOT a failure under BEST_EFFORT: dropping samples the subscriber
    // cannot keep up with is what BEST_EFFORT is defined to do, and a saturation test is
    // expected to lose. It IS a failure under RELIABLE, where delivery was promised. The
    // scripts apply the same rule — see README.md's "msg_lossの読み方". This is a genuine
    // semantic difference from NATS Core over TCP, where any loss means something broke.
    if (opt.reliability == "reliable" && msgLoss > 0) {
        exitCode = 1;
        if (opt.history == "keep_last") {
            // Measured: 679 of 100000 lost at --reliability reliable --history keep_last
            // --history-depth 100, unthrottled. This is correct DDS behaviour, not a bug.
            // RELIABLE guarantees delivery of what the writer still HOLDS; KEEP_LAST(depth)
            // caps that at `depth` samples, so once a reader falls further behind than the
            // depth, older samples are overwritten and dropped legitimately. Only
            // RELIABLE + KEEP_ALL is actually lossless.
            std::cerr << "NOTE: --reliability reliable with --history keep_last --history-depth "
                      << opt.historyDepth
                      << " is NOT lossless. RELIABLE guarantees delivery of samples the writer "
                         "still holds, and KEEP_LAST caps that at "
                      << opt.historyDepth
                      << "; a reader falling further behind than that loses the overwritten "
                         "samples. For a genuinely lossless run add --history keep_all, or "
                         "raise --history-depth, or pace the publisher with --rate."
                      << std::endl;
        }
    }
    if (!subGroups.empty() && msgsReceived == 0) exitCode = 1;
    return exitCode;
}

// RTT: the ping side (--mode pub) writes on <topic>_req and reads <topic>_resp; the echo
// side (--mode sub) does the reverse, re-publishing each sample byte-for-byte so the
// original send timestamp survives the round trip and the ping side can subtract it
// directly. Analogue of `nats bench service serve/request` and of eProsima's LatencyTest.
int runRtt(const Options& opt) {
    const std::string reqTopic = opt.topic + "_req";
    const std::string respTopic = opt.topic + "_resp";
    const uint64_t totalMsgs = opt.msgs;

    MatchCounter pingWriterMatches;

    std::unique_ptr<Endpoints> echo;
    std::unique_ptr<Endpoints> ping;

    const bool runEcho = (opt.mode == "both" || opt.mode == "sub");
    const bool runPing = (opt.mode == "both" || opt.mode == "pub");

    if (runEcho) {
        echo = std::make_unique<Endpoints>();
        echo->participant = makeParticipant(opt, "dds_bench_echo");
        createTopics(*echo, opt, {reqTopic, respTopic});
        createWriters(*echo, opt, {echo->topics[1]}, nullptr);              // writes _resp
        createReaders(*echo, opt, {echo->topics[0]}, false, nullptr);       // reads  _req

        DataWriter* respWriter = echo->writers[0];
        echo->readerListeners[0]->setOnSample([respWriter](const BenchSample& sample) {
            // Re-publish the identical bytes: the ping side computes now - original
            // send_time_ns, so the echo must not rewrite the header.
            BenchSample copy = sample;
            respWriter->write(&copy);
        });
    }

    if (runPing) {
        ping = std::make_unique<Endpoints>();
        ping->participant = makeParticipant(opt, "dds_bench_ping");
        createTopics(*ping, opt, {reqTopic, respTopic});
        createWriters(*ping, opt, {ping->topics[0]}, &pingWriterMatches);   // writes _req
        createReaders(*ping, opt, {ping->topics[1]}, true, nullptr);        // reads  _resp
    }

    // Echo-only process: no measuring to do, just stay alive and reflect until the ping
    // side stops feeding us (waitForReceipt's idle timeout ends the run).
    if (!runPing) {
        std::vector<Endpoints*> echoGroups{echo.get()};
        waitForReceipt(echoGroups, totalMsgs, opt);
        const uint64_t echoed = echo->readerListeners[0]->count();
        std::cout << "measure=rtt mode=sub (echo) msgs_echoed=" << echoed << std::endl;
        destroyEndpoints(*echo);
        return (echoed > 0) ? 0 : 1;
    }

    int exitCode = 0;
    std::cerr << "dds_bench: waiting for the echo peer to match on '" << reqTopic << "'..."
              << std::endl;
    if (!pingWriterMatches.waitFor(1, opt.matchTimeoutSec)) {
        std::cerr << "ERROR: no echo peer matched on '" << reqTopic << "' within "
                  << opt.matchTimeoutSec
                  << "s. Start the echo side (--mode sub) first, and see the --discovery "
                     "note in README.md."
                  << std::endl;
        exitCode = 1;
    }

    std::vector<Endpoints*> pingGroups{ping.get()};
    PubResult pub;
    if (exitCode == 0) {
        pub = publishAll(pingGroups, opt, totalMsgs);
        waitForReceipt(pingGroups, totalMsgs, opt);
    }

    SubResult sub = collect(pingGroups);
    LatencyStats stats;
    if (!sub.samples.empty()) {
        std::vector<double> values;
        values.reserve(sub.samples.size());
        for (const auto& s : sub.samples) values.push_back(s.latency_us);
        stats = computeStats(std::move(values));
        writeSampleCsv(opt.out + "/rtt.csv", "RttMicros", sub.samples);
    }

    const uint64_t msgLoss = (totalMsgs > sub.received) ? (totalMsgs - sub.received) : 0;
    writeResultJson(opt, totalMsgs, &pub, &sub, &stats, pub.sent, sub.received, msgLoss);

    std::cout << "measure=rtt mode=" << opt.mode << " msgs_sent=" << pub.sent
              << " msgs_received=" << sub.received << " msg_loss=" << msgLoss;
    if (stats.valid) std::cout << " p50_us=" << stats.p50 << " p99_us=" << stats.p99;
    std::cout << std::endl;

    if (ping) destroyEndpoints(*ping);
    if (echo) destroyEndpoints(*echo);

    if (sub.received == 0) exitCode = 1;
    if (opt.reliability == "reliable" && msgLoss > 0) exitCode = 1;
    return exitCode;
}

}  // namespace

int main(int argc, char** argv) {
    const Options opt = parseArgs(argc, argv);
    applyLibrarySettings(opt);
    return (opt.measure == "rtt") ? runRtt(opt) : runPubSub(opt);
}
