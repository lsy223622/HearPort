#pragma once

#include <array>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>
#include <vector>

namespace hearport::security {

inline constexpr std::size_t kSha256Bytes = 32;
inline constexpr std::size_t kSpake2PointBytes = 65;
inline constexpr std::size_t kSpake2SessionKeyBytes = 16;
inline constexpr std::size_t kPairingPinBytes = 6;
inline constexpr std::size_t kPeerIdBytes = 16;
inline constexpr std::size_t kPairSecretBytes = 32;
inline constexpr std::size_t kAuthNonceBytes = 32;

using Bytes16 = std::array<std::byte, 16>;
using Bytes32 = std::array<std::byte, 32>;
using Bytes65 = std::array<std::byte, 65>;

enum class Spake2Role : std::uint8_t {
  windows_party_a = 1,
  receiver_party_b = 2,
};

bool IsValidPin(std::span<const std::byte> pin) noexcept;
std::optional<Bytes32> PinToScalar(std::span<const std::byte> pin) noexcept;
std::optional<Bytes32> Sha256Spki(
    std::span<const std::byte> der_subject_public_key_info) noexcept;
std::vector<std::byte> BuildWindowsIdentity(const Bytes32& spki_sha256);
std::vector<std::byte> BuildReceiverIdentity();
std::optional<Bytes32> HmacSha256(std::span<const std::byte> key,
                                  std::span<const std::byte> message) noexcept;
bool RandomBytes(std::span<std::byte> output) noexcept;
bool ConstantTimeEqual(std::span<const std::byte> left,
                       std::span<const std::byte> right) noexcept;

class Spake2Result;

class Spake2Session {
 public:
  Spake2Session() = default;
  ~Spake2Session();

  Spake2Session(const Spake2Session&) = delete;
  Spake2Session& operator=(const Spake2Session&) = delete;
  Spake2Session(Spake2Session&& other) noexcept;
  Spake2Session& operator=(Spake2Session&& other) noexcept;

  static std::optional<Spake2Session> Begin(
      Spake2Role role, const Bytes32& scalar,
      std::span<const std::byte> identity_a,
      std::span<const std::byte> identity_b) noexcept;

  static bool ProviderAvailable() noexcept;

  const Bytes65& public_point() const noexcept { return public_point_; }
  std::optional<Spake2Result> Finish(
      std::span<const std::byte> peer_point) && noexcept;

 private:
  struct Opaque;
  explicit Spake2Session(Opaque* session, const Bytes65& public_point) noexcept
      : session_(session), public_point_(public_point) {}

  Opaque* session_ = nullptr;
  Bytes65 public_point_{};
};

class Spake2Result {
 public:
  ~Spake2Result();

  Spake2Result(const Spake2Result&) = delete;
  Spake2Result& operator=(const Spake2Result&) = delete;
  Spake2Result(Spake2Result&& other) noexcept;
  Spake2Result& operator=(Spake2Result&& other) noexcept;

  const Bytes32& confirmation() const noexcept { return confirmation_; }
  const std::array<std::byte, kSpake2SessionKeyBytes>& session_key()
      const noexcept {
    return session_key_;
  }
  bool VerifyPeerConfirmation(
      std::span<const std::byte> confirmation) const noexcept;

 private:
  friend class Spake2Session;
  struct Opaque;
  explicit Spake2Result(Opaque* output, const Bytes32& confirmation,
                        const std::array<std::byte, kSpake2SessionKeyBytes>&
                            session_key) noexcept
      : output_(output), confirmation_(confirmation), session_key_(session_key) {}

  Opaque* output_ = nullptr;
  Bytes32 confirmation_{};
  std::array<std::byte, kSpake2SessionKeyBytes> session_key_{};
};

class PairingWindow {
 public:
  using Clock = std::chrono::steady_clock;
  using TimePoint = Clock::time_point;

  explicit PairingWindow(std::chrono::seconds duration = std::chrono::minutes(2),
                         std::uint32_t maximum_failures = 5) noexcept;

  void Open(TimePoint now) noexcept;
  void Close() noexcept;
  bool IsOpen(TimePoint now) noexcept;
  // Returns whether the window remains open after recording this failure.
  bool RecordFailure(TimePoint now) noexcept;

  std::uint32_t failure_count() const noexcept { return failure_count_; }

 private:
  std::chrono::seconds duration_;
  std::uint32_t maximum_failures_;
  TimePoint opened_at_{};
  std::uint32_t failure_count_ = 0;
  bool open_ = false;
};

}  // namespace hearport::security
