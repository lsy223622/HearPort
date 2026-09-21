#include "hearport/windows/credential_store.h"

#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>

#if defined(_WIN32)
#include <windows.h>
#include <wincred.h>

#include <dpapi.h>

#pragma comment(lib, "advapi32.lib")
#pragma comment(lib, "crypt32.lib")
#endif

namespace hearport::windows {
namespace {

constexpr wchar_t kCredentialTarget[] = L"HearPort/v1/remembered";
constexpr std::size_t kSerializedBytes =
    security::kPeerIdBytes + security::kPairSecretBytes +
    security::kSha256Bytes;

using SerializedCredential = std::array<std::byte, kSerializedBytes>;

SerializedCredential Serialize(
    const security::RememberedCredential& credential) noexcept {
  SerializedCredential serialized{};
  std::size_t offset = 0;
  std::memcpy(serialized.data() + offset, credential.peer_id.data(),
              credential.peer_id.size());
  offset += credential.peer_id.size();
  std::memcpy(serialized.data() + offset, credential.pair_secret.data(),
              credential.pair_secret.size());
  offset += credential.pair_secret.size();
  std::memcpy(serialized.data() + offset,
              credential.windows_spki_sha256.data(),
              credential.windows_spki_sha256.size());
  return serialized;
}

security::RememberedCredential Deserialize(
    const SerializedCredential& serialized) noexcept {
  security::RememberedCredential credential;
  std::size_t offset = 0;
  std::memcpy(credential.peer_id.data(), serialized.data() + offset,
              credential.peer_id.size());
  offset += credential.peer_id.size();
  std::memcpy(credential.pair_secret.data(), serialized.data() + offset,
              credential.pair_secret.size());
  offset += credential.pair_secret.size();
  std::memcpy(credential.windows_spki_sha256.data(), serialized.data() + offset,
              credential.windows_spki_sha256.size());
  return credential;
}

}  // namespace

bool ProtectedCredentialStore::Save(
    const security::RememberedCredential& credential) const noexcept {
#if defined(_WIN32)
  auto serialized = Serialize(credential);
  DATA_BLOB input{};
  input.cbData = static_cast<DWORD>(serialized.size());
  input.pbData = reinterpret_cast<BYTE*>(
      const_cast<std::byte*>(serialized.data()));
  DATA_BLOB protected_blob{};
  if (!CryptProtectData(&input, L"HearPort v1 remembered credential", nullptr,
                        nullptr, nullptr, CRYPTPROTECT_UI_FORBIDDEN,
                        &protected_blob)) {
    SecureZeroMemory(serialized.data(), serialized.size());
    return false;
  }

  CREDENTIALW stored{};
  stored.Type = CRED_TYPE_GENERIC;
  stored.TargetName = const_cast<LPWSTR>(kCredentialTarget);
  stored.CredentialBlobSize = protected_blob.cbData;
  stored.CredentialBlob = protected_blob.pbData;
  stored.Persist = CRED_PERSIST_LOCAL_MACHINE;
  const bool success = CredWriteW(&stored, 0) == TRUE;
  SecureZeroMemory(serialized.data(), serialized.size());
  SecureZeroMemory(protected_blob.pbData, protected_blob.cbData);
  LocalFree(protected_blob.pbData);
  return success;
#else
  (void)credential;
  return false;
#endif
}

std::optional<security::RememberedCredential> ProtectedCredentialStore::Load()
    const noexcept {
#if defined(_WIN32)
  PCREDENTIALW stored = nullptr;
  if (!CredReadW(kCredentialTarget, CRED_TYPE_GENERIC, 0, &stored)) {
    return std::nullopt;
  }
  std::optional<security::RememberedCredential> result;
  if (stored->CredentialBlob != nullptr &&
      stored->CredentialBlobSize > 0) {
    DATA_BLOB protected_blob{};
    protected_blob.cbData = stored->CredentialBlobSize;
    protected_blob.pbData = stored->CredentialBlob;
    DATA_BLOB unprotected_blob{};
    SerializedCredential serialized{};
    if (CryptUnprotectData(&protected_blob, nullptr, nullptr, nullptr, nullptr,
                           CRYPTPROTECT_UI_FORBIDDEN, &unprotected_blob) &&
        unprotected_blob.cbData == kSerializedBytes) {
      std::memcpy(serialized.data(), unprotected_blob.pbData,
                  serialized.size());
      result = Deserialize(serialized);
      SecureZeroMemory(serialized.data(), serialized.size());
    }
    SecureZeroMemory(serialized.data(), serialized.size());
    if (unprotected_blob.pbData != nullptr) {
      SecureZeroMemory(unprotected_blob.pbData, unprotected_blob.cbData);
      LocalFree(unprotected_blob.pbData);
    }
  }
  CredFree(stored);
  return result;
#else
  return std::nullopt;
#endif
}

bool ProtectedCredentialStore::Remove() const noexcept {
#if defined(_WIN32)
  return CredDeleteW(kCredentialTarget, CRED_TYPE_GENERIC, 0) == TRUE ||
         GetLastError() == ERROR_NOT_FOUND;
#else
  return false;
#endif
}

}  // namespace hearport::windows
