#include <cassert>
#include <array>
#include <span>

#include "hearport/sequence.h"
#include "hearport/jitter_buffer.h"
#include "hearport/render_ring_buffer.h"
#include "hearport/drift_controller.h"

int main() {
  assert(hearport::IsSequenceNewer(0u, 0xffffffffu));
  assert(!hearport::IsSequenceNewer(0xffffffffu, 0u));

  hearport::DriftController controller(480);
  const double first = controller.Update(600, true, 1.0);
  const double last = controller.Update(600, true, 1.0);
  assert(first >= 1.0);
  assert(last > first);
  assert(last < 1.002);

  hearport::JitterBuffer jitter(5, 8, 2);
  hearport::wire::AudioDatagram first_packet{};
  first_packet.stream_id = 5;
  first_packet.sequence = 100;
  hearport::wire::AudioDatagram second_packet = first_packet;
  second_packet.sequence = 101;
  assert(jitter.Insert(first_packet) == hearport::PacketDisposition::accepted);
  assert(jitter.mode() == hearport::PlaybackMode::buffering);
  assert(jitter.Insert(second_packet) == hearport::PacketDisposition::accepted);
  assert(jitter.mode() == hearport::PlaybackMode::playing);
  assert(jitter.ConsumeNext()->sequence == 100);
  assert(jitter.ConsumeNext()->sequence == 101);

  hearport::RenderRingBuffer ring(4);
  const std::array<float, 5> input{1, 2, 3, 4, 5};
  assert(ring.Write(input) == 4);
  std::array<float, 3> output{};
  assert(ring.Read(output) == 3);
  assert(output[0] == 1);
  assert(output[2] == 3);
  assert(ring.stats().overflow_frames == 1);
  return 0;
}
