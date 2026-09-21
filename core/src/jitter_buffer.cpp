#include "hearport/jitter_buffer.h"

#include <algorithm>
#include <stdexcept>

#include "hearport/sequence.h"

namespace hearport {

JitterBuffer::JitterBuffer(std::uint32_t stream_id,
                           std::size_t capacity_packets,
                           std::size_t target_packets)
    : stream_id_(stream_id),
      capacity_packets_(capacity_packets),
      target_packets_(target_packets) {
  if (stream_id_ == 0 || capacity_packets_ == 0 || target_packets_ == 0 ||
      target_packets_ > capacity_packets_) {
    throw std::invalid_argument("invalid jitter buffer configuration");
  }
}

PacketDisposition JitterBuffer::Insert(const wire::AudioDatagram& packet) {
  if (packet.stream_id != stream_id_) {
    ++stats_.wrong_stream;
    return PacketDisposition::wrong_stream;
  }
  if (expected_.has_value() && packet.sequence != expected_.value() &&
      !IsSequenceNewer(packet.sequence, expected_.value())) {
    ++stats_.late;
    return PacketDisposition::late;
  }
  if (packets_.contains(packet.sequence)) {
    ++stats_.duplicate;
    return PacketDisposition::duplicate;
  }
  if (packets_.size() >= capacity_packets_) {
    ++stats_.overflow;
    return PacketDisposition::overflow;
  }

  packets_.emplace(packet.sequence, packet);
  if (!expected_.has_value()) {
    expected_ = packet.sequence;
  }
  if (packets_.size() >= target_packets_) {
    mode_ = PlaybackMode::playing;
  }
  return PacketDisposition::accepted;
}

std::optional<wire::AudioDatagram> JitterBuffer::ConsumeNext() {
  if (mode_ != PlaybackMode::playing || !expected_.has_value()) {
    return std::nullopt;
  }
  const auto iterator = packets_.find(expected_.value());
  if (iterator == packets_.end()) {
    return std::nullopt;
  }
  auto packet = iterator->second;
  packets_.erase(iterator);
  expected_ = expected_.value() + 1;
  return packet;
}

std::array<std::byte, wire::kAudioPcmBytes> JitterBuffer::ConcealMissing() {
  std::array<std::byte, wire::kAudioPcmBytes> silence{};
  if (mode_ != PlaybackMode::playing || !expected_.has_value()) {
    return silence;
  }
  packets_.erase(expected_.value());
  expected_ = expected_.value() + 1;
  ++stats_.loss;
  return silence;
}

void JitterBuffer::EnterSilentRebuffer() {
  packets_.clear();
  expected_.reset();
  mode_ = PlaybackMode::silent_rebuffer;
}

void JitterBuffer::Reset(std::uint32_t stream_id) {
  if (stream_id == 0) {
    throw std::invalid_argument("stream_id must be non-zero");
  }
  stream_id_ = stream_id;
  packets_.clear();
  expected_.reset();
  mode_ = PlaybackMode::buffering;
  stats_ = {};
}

}  // namespace hearport
