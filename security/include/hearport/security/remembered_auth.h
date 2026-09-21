#pragma once

#include <optional>
#include <span>

#include "hearport/security/pairing.h"

namespace hearport::security {

struct RememberedCredential {
  Bytes16 peer_id{};
  Bytes32 pair_secret{};
  Bytes32 windows_spki_sha256{};
};

std::optional<Bytes32> ComputeRememberedAuthMac(
    const RememberedCredential& credential,
    std::span<const std::byte> nonce) noexcept;

class RememberedAuthVerifier {
 public:
  explicit RememberedAuthVerifier(const RememberedCredential& credential) noexcept
      : credential_(credential) {}

  std::optional<Bytes32> IssueChallenge() noexcept;
  bool Verify(std::span<const std::byte> peer_id,
              std::span<const std::byte> mac) noexcept;
  void ClearChallenge() noexcept;

 private:
  RememberedCredential credential_;
  std::optional<Bytes32> pending_nonce_;
};

class PairingTrustStore {
 public:
  void Stage(const RememberedCredential& credential) noexcept;
  bool Commit(bool pairing_succeeded, bool remember) noexcept;
  void Clear() noexcept;

  const std::optional<RememberedCredential>& remembered() const noexcept {
    return remembered_;
  }

 private:
  std::optional<RememberedCredential> staged_;
  std::optional<RememberedCredential> remembered_;
};

}  // namespace hearport::security
