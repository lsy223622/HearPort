#include "hearport/security/pairing.h"

#include <algorithm>
#include <string_view>

#include "hearport_spake2_provider.h"

namespace hearport::security {
namespace {

template <typename T>
const std::uint8_t* AsU8(std::span<const T> bytes) noexcept {
  return reinterpret_cast<const std::uint8_t*>(bytes.data());
}

template <typename T>
std::uint8_t* AsU8(std::span<T> bytes) noexcept {
  return reinterpret_cast<std::uint8_t*>(bytes.data());
}

template <std::size_t N>
const std::uint8_t* AsU8(const std::array<std::byte, N>& bytes) noexcept {
  return reinterpret_cast<const std::uint8_t*>(bytes.data());
}

template <std::size_t N>
std::uint8_t* AsU8(std::array<std::byte, N>& bytes) noexcept {
  return reinterpret_cast<std::uint8_t*>(bytes.data());
}

constexpr std::string_view kWindowsIdentity = "HearPort-Windows-v1";
constexpr std::string_view kReceiverIdentity = "HearPort-Receiver-v1";

}  // namespace

bool IsValidPin(std::span<const std::byte> pin) noexcept {
  if (pin.size() != kPairingPinBytes) {
    return false;
  }
  return std::ranges::all_of(pin, [](std::byte value) {
    const auto digit = std::to_integer<unsigned int>(value);
    return digit >= static_cast<unsigned int>('0') &&
           digit <= static_cast<unsigned int>('9');
  });
}

std::optional<Bytes32> PinToScalar(
    std::span<const std::byte> pin) noexcept {
#if HEARPORT_HAS_SPAKE2_PROVIDER
  if (!IsValidPin(pin)) {
    return std::nullopt;
  }
  Bytes32 scalar{};
  if (hearport_spake2_pin_to_scalar(AsU8(pin), pin.size(), AsU8(scalar)) !=
      HEARPORT_SPAKE2_OK) {
    return std::nullopt;
  }
  return scalar;
#else
  (void)pin;
  return std::nullopt;
#endif
}

std::optional<Bytes32> Sha256Spki(
    std::span<const std::byte> der_subject_public_key_info) noexcept {
#if HEARPORT_HAS_SPAKE2_PROVIDER
  if (der_subject_public_key_info.empty()) {
    return std::nullopt;
  }
  Bytes32 digest{};
  if (hearport_spake2_sha256(AsU8(der_subject_public_key_info),
                             der_subject_public_key_info.size(),
                             AsU8(digest)) != HEARPORT_SPAKE2_OK) {
    return std::nullopt;
  }
  return digest;
#else
  (void)der_subject_public_key_info;
  return std::nullopt;
#endif
}

std::vector<std::byte> BuildWindowsIdentity(const Bytes32& spki_sha256) {
  std::vector<std::byte> identity;
  identity.reserve(kWindowsIdentity.size() + 1 + spki_sha256.size());
  for (const char value : kWindowsIdentity) {
    identity.push_back(static_cast<std::byte>(value));
  }
  identity.push_back(std::byte{0});
  identity.insert(identity.end(), spki_sha256.begin(), spki_sha256.end());
  return identity;
}

std::vector<std::byte> BuildReceiverIdentity() {
  std::vector<std::byte> identity;
  identity.reserve(kReceiverIdentity.size());
  for (const char value : kReceiverIdentity) {
    identity.push_back(static_cast<std::byte>(value));
  }
  return identity;
}

std::optional<Bytes32> HmacSha256(std::span<const std::byte> key,
                                  std::span<const std::byte> message) noexcept {
#if HEARPORT_HAS_SPAKE2_PROVIDER
  if (key.empty()) {
    return std::nullopt;
  }
  Bytes32 mac{};
  if (hearport_spake2_hmac_sha256(AsU8(key), key.size(), AsU8(message),
                                  message.size(), AsU8(mac)) !=
      HEARPORT_SPAKE2_OK) {
    return std::nullopt;
  }
  return mac;
#else
  (void)key;
  (void)message;
  return std::nullopt;
#endif
}

bool RandomBytes(std::span<std::byte> output) noexcept {
#if HEARPORT_HAS_SPAKE2_PROVIDER
  return hearport_spake2_random(AsU8(output), output.size()) ==
         HEARPORT_SPAKE2_OK;
#else
  (void)output;
  return false;
#endif
}

bool ConstantTimeEqual(std::span<const std::byte> left,
                       std::span<const std::byte> right) noexcept {
  if (left.size() != right.size()) {
    return false;
  }
  volatile std::uint8_t difference = 0;
  for (std::size_t index = 0; index < left.size(); ++index) {
    difference |= static_cast<std::uint8_t>(
        std::to_integer<unsigned int>(left[index]) ^
        std::to_integer<unsigned int>(right[index]));
  }
  return difference == 0;
}

struct Spake2Session::Opaque {};
struct Spake2Result::Opaque {};

Spake2Session::~Spake2Session() {
#if HEARPORT_HAS_SPAKE2_PROVIDER
  if (session_ != nullptr) {
    hearport_spake2_session_free(
        reinterpret_cast<hearport_spake2_session*>(session_));
  }
#endif
}

Spake2Session::Spake2Session(Spake2Session&& other) noexcept
    : session_(other.session_), public_point_(other.public_point_) {
  other.session_ = nullptr;
}

Spake2Session& Spake2Session::operator=(Spake2Session&& other) noexcept {
  if (this == &other) {
    return *this;
  }
#if HEARPORT_HAS_SPAKE2_PROVIDER
  if (session_ != nullptr) {
    hearport_spake2_session_free(
        reinterpret_cast<hearport_spake2_session*>(session_));
  }
#endif
  session_ = other.session_;
  public_point_ = other.public_point_;
  other.session_ = nullptr;
  return *this;
}

bool Spake2Session::ProviderAvailable() noexcept {
#if HEARPORT_HAS_SPAKE2_PROVIDER
  return true;
#else
  return false;
#endif
}

std::optional<Spake2Session> Spake2Session::Begin(
    Spake2Role role, const Bytes32& scalar,
    std::span<const std::byte> identity_a,
    std::span<const std::byte> identity_b) noexcept {
#if HEARPORT_HAS_SPAKE2_PROVIDER
  if (identity_a.size() > 65536 || identity_b.size() > 65536) {
    return std::nullopt;
  }
  Bytes65 public_point{};
  hearport_spake2_session* session = nullptr;
  const auto result = hearport_spake2_begin(
      static_cast<std::uint8_t>(role), AsU8(scalar), AsU8(identity_a),
      identity_a.size(), AsU8(identity_b), identity_b.size(),
      AsU8(public_point), &session);
  if (result != HEARPORT_SPAKE2_OK || session == nullptr) {
    return std::nullopt;
  }
  return Spake2Session(reinterpret_cast<Opaque*>(session), public_point);
#else
  (void)role;
  (void)scalar;
  (void)identity_a;
  (void)identity_b;
  return std::nullopt;
#endif
}

std::optional<Spake2Result> Spake2Session::Finish(
    std::span<const std::byte> peer_point) && noexcept {
#if HEARPORT_HAS_SPAKE2_PROVIDER
  if (session_ == nullptr || peer_point.size() != kSpake2PointBytes) {
    return std::nullopt;
  }
  auto* session = reinterpret_cast<hearport_spake2_session*>(session_);
  session_ = nullptr;
  hearport_spake2_output* output = nullptr;
  Bytes32 confirmation{};
  const auto result = hearport_spake2_finish(
      session, AsU8(peer_point), peer_point.size(), &output,
      AsU8(confirmation));
  if (result != HEARPORT_SPAKE2_OK || output == nullptr) {
    return std::nullopt;
  }
  std::array<std::byte, kSpake2SessionKeyBytes> session_key{};
  if (hearport_spake2_copy_session_key(output, AsU8(session_key)) !=
      HEARPORT_SPAKE2_OK) {
    hearport_spake2_output_free(output);
    return std::nullopt;
  }
  return Spake2Result(reinterpret_cast<Spake2Result::Opaque*>(output),
                      confirmation, session_key);
#else
  (void)peer_point;
  return std::nullopt;
#endif
}

Spake2Result::~Spake2Result() {
#if HEARPORT_HAS_SPAKE2_PROVIDER
  if (output_ != nullptr) {
    hearport_spake2_output_free(
        reinterpret_cast<hearport_spake2_output*>(output_));
  }
#endif
}

Spake2Result::Spake2Result(Spake2Result&& other) noexcept
    : output_(other.output_),
      confirmation_(other.confirmation_),
      session_key_(other.session_key_) {
  other.output_ = nullptr;
}

Spake2Result& Spake2Result::operator=(Spake2Result&& other) noexcept {
  if (this == &other) {
    return *this;
  }
#if HEARPORT_HAS_SPAKE2_PROVIDER
  if (output_ != nullptr) {
    hearport_spake2_output_free(
        reinterpret_cast<hearport_spake2_output*>(output_));
  }
#endif
  output_ = other.output_;
  confirmation_ = other.confirmation_;
  session_key_ = other.session_key_;
  other.output_ = nullptr;
  return *this;
}

bool Spake2Result::VerifyPeerConfirmation(
    std::span<const std::byte> confirmation) const noexcept {
#if HEARPORT_HAS_SPAKE2_PROVIDER
  if (output_ == nullptr || confirmation.size() != kSha256Bytes) {
    return false;
  }
  return hearport_spake2_verify_confirmation(
             reinterpret_cast<const hearport_spake2_output*>(output_),
             AsU8(confirmation)) == HEARPORT_SPAKE2_OK;
#else
  (void)confirmation;
  return false;
#endif
}

PairingWindow::PairingWindow(std::chrono::seconds duration,
                             std::uint32_t maximum_failures) noexcept
    : duration_(duration), maximum_failures_(maximum_failures) {}

void PairingWindow::Open(TimePoint now) noexcept {
  opened_at_ = now;
  failure_count_ = 0;
  open_ = duration_.count() > 0 && maximum_failures_ > 0;
}

void PairingWindow::Close() noexcept {
  open_ = false;
}

bool PairingWindow::IsOpen(TimePoint now) noexcept {
  if (!open_ || now - opened_at_ >= duration_) {
    open_ = false;
    return false;
  }
  return failure_count_ < maximum_failures_;
}

bool PairingWindow::RecordFailure(TimePoint now) noexcept {
  if (!IsOpen(now)) {
    return false;
  }
  ++failure_count_;
  if (failure_count_ >= maximum_failures_) {
    open_ = false;
    return false;
  }
  return true;
}

}  // namespace hearport::security
