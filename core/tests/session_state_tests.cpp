#include <array>
#include <cassert>
#include <span>

#include "hearport/session_state.h"

int main() {
  hearport::SessionState session;
  assert(!session.BeginStream(7));
  assert(session.ReceiveConnect(hearport::AuthMode::one_time,
                               std::span<const std::byte>{}));
  assert(session.phase() == hearport::SessionPhase::authenticating);
  assert(session.MarkAuthenticated());
  assert(session.BeginStream(7));

  hearport::wire::AudioDatagram packet{};
  packet.stream_id = 7;
  assert(session.AcceptAudio(packet) ==
         hearport::AudioDisposition::pending_audio_discarded);
  assert(session.AckWritten(7) == hearport::AudioDisposition::accepted);
  assert(session.AcceptAudio(packet) == hearport::AudioDisposition::accepted);

  assert(session.ResetStream(8));
  assert(session.AcceptAudio(packet) ==
         hearport::AudioDisposition::pending_audio_discarded);
  assert(session.AckWritten(8) == hearport::AudioDisposition::accepted);
  assert(session.AcceptAudio(packet) ==
         hearport::AudioDisposition::old_stream_discarded);
  return 0;
}
