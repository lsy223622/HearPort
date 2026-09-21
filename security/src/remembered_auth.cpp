#include "hearport/security/remembered_auth.h"

#include <string_view>

namespace hearport::security {
namespace {

constexpr std::string_view kAuthDomain = "HearPort-Auth-v1";

template <std::size_t N>
std::span<const std::byte> AsSpan(const std::array<std::byte, N>& bytes) {
  return std::span<const std::byte>(bytes.data(), bytes.size());
}

}  // namespace

std::optional<Bytes32> ComputeRememberedAuthMac(
    const RememberedCredential& credential,
    std::span<const std::byte> nonce) noexcept {
  if (nonce.size() != kAuthNonceBytes) {
    return std::nullopt;
  }
  std::vector<std::byte> message;
  message.reserve(kAuthDomain.size() + nonce.size() +
                  credential.windows_spki_sha256.size());
  for (const char value : kAuthDomain) {
    message.push_back(static_cast<std::byte>(value));
  }
  message.insert(message.end(), nonce.begin(), nonce.end());
  message.insert(message.end(), credential.windows_spki_sha256.begin(),
                 credential.windows_spki_sha256.end());
  return HmacSha256(AsSpan(credential.pair_secret),
                    std::span<const std::byte>(message.data(), message.size()));
}

std::optional<Bytes32> RememberedAuthVerifier::IssueChallenge() noexcept {
  Bytes32 nonce{};
  if (!RandomBytes(std::span<std::byte>(nonce.data(), nonce.size()))) {
    pending_nonce_.reset();
    return std::nullopt;
  }
  pending_nonce_ = nonce;
  return nonce;
}

bool RememberedAuthVerifier::Verify(std::span<const std::byte> peer_id,
                                    std::span<const std::byte> mac) noexcept {
  const auto nonce = pending_nonce_;
  pending_nonce_.reset();
  if (!nonce.has_value() || peer_id.size() != kPeerIdBytes ||
      mac.size() != kSha256Bytes ||
      !ConstantTimeEqual(peer_id, AsSpan(credential_.peer_id))) {
    return false;
  }
  const auto expected = ComputeRememberedAuthMac(credential_, AsSpan(*nonce));
  return expected.has_value() &&
         ConstantTimeEqual(mac, AsSpan(*expected));
}

void RememberedAuthVerifier::ClearChallenge() noexcept {
  pending_nonce_.reset();
}

void PairingTrustStore::Stage(const RememberedCredential& credential) noexcept {
  staged_ = credential;
}

bool PairingTrustStore::Commit(bool pairing_succeeded, bool remember) noexcept {
  if (!pairing_succeeded || !remember || !staged_.has_value()) {
    staged_.reset();
    return false;
  }
  remembered_ = staged_;
  staged_.reset();
  return true;
}

void PairingTrustStore::Clear() noexcept {
  staged_.reset();
  remembered_.reset();
}

}  // namespace hearport::security
