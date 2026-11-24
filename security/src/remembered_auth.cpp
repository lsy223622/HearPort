#include "hearport/security/remembered_auth.h"

#include <algorithm>
#include <array>
#include <string_view>

namespace hearport::security {
namespace {

constexpr std::string_view kAuthDomain = "HearPort-Auth-v1";

template <std::size_t N>
std::span<const std::byte> AsSpan(const std::array<std::byte, N>& bytes) {
  return std::span<const std::byte>(bytes.data(), bytes.size());
}

}  // namespace

RememberedCredential::RememberedCredential(
    RememberedCredential&& other) noexcept
    : peer_id(other.peer_id),
      pair_secret(other.pair_secret),
      windows_spki_sha256(other.windows_spki_sha256) {
  SecureZero(other.pair_secret);
}

RememberedCredential& RememberedCredential::operator=(
    RememberedCredential&& other) noexcept {
  if (this != &other) {
    SecureZero(pair_secret);
    peer_id = other.peer_id;
    pair_secret = other.pair_secret;
    windows_spki_sha256 = other.windows_spki_sha256;
    SecureZero(other.pair_secret);
  }
  return *this;
}

RememberedCredential::~RememberedCredential() noexcept {
  SecureZero(pair_secret);
}

RememberedAuthVerifier::RememberedAuthVerifier(
    RememberedAuthVerifier&& other) noexcept
    : credential_(std::move(other.credential_)),
      pending_nonce_(other.pending_nonce_) {
  other.ClearChallenge();
}

RememberedAuthVerifier& RememberedAuthVerifier::operator=(
    RememberedAuthVerifier&& other) noexcept {
  if (this != &other) {
    ClearChallenge();
    credential_ = std::move(other.credential_);
    pending_nonce_ = other.pending_nonce_;
    other.ClearChallenge();
  }
  return *this;
}

RememberedAuthVerifier::~RememberedAuthVerifier() noexcept {
  ClearChallenge();
}

std::optional<Bytes32> ComputeRememberedAuthMac(
    const RememberedCredential& credential,
    std::span<const std::byte> nonce) noexcept {
  if (nonce.size() != kAuthNonceBytes) {
    return std::nullopt;
  }
  std::array<std::byte, kAuthDomain.size() + kAuthNonceBytes + kSha256Bytes>
      message{};
  auto out = message.begin();
  for (const char value : kAuthDomain) {
    *out++ = static_cast<std::byte>(value);
  }
  out = std::copy(nonce.begin(), nonce.end(), out);
  std::copy(credential.windows_spki_sha256.begin(),
            credential.windows_spki_sha256.end(), out);
  const auto mac = HmacSha256(AsSpan(credential.pair_secret), message);
  SecureZero(message);
  return mac;
}

std::optional<Bytes32> RememberedAuthVerifier::IssueChallenge() noexcept {
  Bytes32 nonce{};
  if (!RandomBytes(std::span<std::byte>(nonce.data(), nonce.size()))) {
    ClearChallenge();
    return std::nullopt;
  }
  ClearChallenge();
  pending_nonce_ = nonce;
  SecureZero(nonce);
  return pending_nonce_;
}

bool RememberedAuthVerifier::Verify(std::span<const std::byte> peer_id,
                                    std::span<const std::byte> mac) noexcept {
  auto nonce = pending_nonce_;
  ClearChallenge();
  if (!nonce.has_value() || peer_id.size() != kPeerIdBytes ||
      mac.size() != kSha256Bytes ||
      !ConstantTimeEqual(peer_id, AsSpan(credential_.peer_id))) {
    if (nonce.has_value()) {
      SecureZero(*nonce);
    }
    return false;
  }
  auto expected = ComputeRememberedAuthMac(credential_, AsSpan(*nonce));
  SecureZero(*nonce);
  const bool matched =
      expected.has_value() && ConstantTimeEqual(mac, AsSpan(*expected));
  if (expected.has_value()) {
    SecureZero(*expected);
  }
  return matched;
}

void RememberedAuthVerifier::ClearChallenge() noexcept {
  if (pending_nonce_.has_value()) {
    SecureZero(*pending_nonce_);
    pending_nonce_.reset();
  }
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
