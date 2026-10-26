#include "hearport/security/pairing.h"
#include "hearport/security/remembered_auth.h"

#include <cassert>
#include <array>
#include <chrono>
#include <cstddef>
#include <string_view>
#include <utility>

namespace {

std::vector<std::byte> Bytes(std::string_view text) {
  std::vector<std::byte> output;
  output.reserve(text.size());
  for (const char value : text) {
    output.push_back(static_cast<std::byte>(value));
  }
  return output;
}

template <std::size_t N>
std::array<std::byte, N> Hex(std::string_view text) {
  assert(text.size() == N * 2);
  std::array<std::byte, N> output{};
  auto value = [](char digit) -> unsigned int {
    if (digit >= '0' && digit <= '9') return digit - '0';
    if (digit >= 'a' && digit <= 'f') return digit - 'a' + 10;
    return digit - 'A' + 10;
  };
  for (std::size_t index = 0; index < N; ++index) {
    output[index] = std::byte{static_cast<unsigned char>(
        (value(text[index * 2]) << 4) | value(text[index * 2 + 1]))};
  }
  return output;
}

}  // namespace

int main() {
  using namespace hearport::security;
  const auto pin = Bytes("000001");
  assert(IsValidPin(pin));
  assert(!IsValidPin(Bytes("12345")));
  assert(!IsValidPin(Bytes("12x456")));

  const auto identity_b = BuildReceiverIdentity();
  assert(identity_b.size() == 20);
  Bytes32 spki{};
  spki.fill(std::byte{0x11});
  const auto identity_a = BuildWindowsIdentity(spki);
  assert(identity_a.size() == 52);
  if (!Spake2Session::ProviderAvailable()) {
    assert(!PinToScalar(pin).has_value());
    assert(!Sha256Spki(spki).has_value());
    return 0;
  }

  const auto scalar = PinToScalar(pin);
  assert(scalar.has_value());
  assert(*scalar == Hex<32>(
                         "953b4ede8ce205547f1e941484ea9c4171029c3b305327f36ee8837a7ba70884"));

  for (const bool matching_pin : {true, false}) {
    const auto receiver_scalar = matching_pin ? scalar : PinToScalar(Bytes("000002"));
    assert(receiver_scalar.has_value());
    auto party_a = Spake2Session::Begin(Spake2Role::windows_party_a, *scalar,
                                      identity_a, identity_b);
    auto party_b = Spake2Session::Begin(Spake2Role::receiver_party_b, *receiver_scalar,
                                      identity_a, identity_b);
    assert(party_a.has_value() && party_b.has_value());
    const auto point_a = party_a->public_point();
    const auto point_b = party_b->public_point();
    auto result_a = std::move(*party_a).Finish(point_b);
    auto result_b = std::move(*party_b).Finish(point_a);
    assert(result_a.has_value() && result_b.has_value());
    assert(result_a->VerifyPeerConfirmation(result_b->confirmation()) == matching_pin);
    assert(result_b->VerifyPeerConfirmation(result_a->confirmation()) == matching_pin);
    assert((result_a->session_key() == result_b->session_key()) == matching_pin);
    auto bad_confirmation = result_b->confirmation();
    bad_confirmation[0] ^= std::byte{1};
    assert(!result_a->VerifyPeerConfirmation(bad_confirmation));
  }
  const auto spki_der = Hex<8>("3006020100020101");
  const auto spki_hash = Sha256Spki(spki_der);
  assert(spki_hash.has_value());
  assert(*spki_hash ==
         Hex<32>("8173a3931015a47eecca3be51c063ef6c715eb0dd72447a182551ec099986e99"));

  PairingWindow window;
  const auto start = PairingWindow::TimePoint{};
  window.Open(start);
  for (int attempt = 0; attempt < 4; ++attempt) {
    assert(window.RecordFailure(start + std::chrono::seconds(attempt + 1)));
  }
  assert(!window.RecordFailure(start + std::chrono::seconds(5)));
  assert(!window.IsOpen(start + std::chrono::seconds(5)));

  RememberedCredential credential;
  credential.peer_id.fill(std::byte{0x22});
  credential.pair_secret.fill(std::byte{0x33});
  credential.windows_spki_sha256 = spki;
  const auto nonce = Hex<32>(
      "ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100");
  credential.pair_secret = Hex<32>(
      "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f");
  credential.windows_spki_sha256 = Hex<32>(
      "8173a3931015a47eecca3be51c063ef6c715eb0dd72447a182551ec099986e99");
  const auto mac = ComputeRememberedAuthMac(credential, nonce);
  assert(mac.has_value());
  assert(*mac == Hex<32>(
                     "d5b46316593d5739bf0fc756270a58c5c99039d9ab1c89a22eb57ae4fba105f8"));

  PairingTrustStore trust;
  trust.Stage(credential);
  assert(!trust.Commit(false, true));
  assert(!trust.remembered().has_value());
  trust.Stage(credential);
  assert(trust.Commit(true, true));
  assert(trust.remembered().has_value());
  return 0;
}
