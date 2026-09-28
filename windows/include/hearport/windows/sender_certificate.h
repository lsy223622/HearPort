#pragma once

#include <optional>

#include "hearport/windows/quic_server.h"

namespace hearport::windows {

// Returns a persistent certificate identity from the current user's My store.
std::optional<QuicServerOptions> LoadOrCreateSenderIdentity();

}  // namespace hearport::windows
