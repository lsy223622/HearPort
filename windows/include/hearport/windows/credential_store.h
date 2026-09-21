#pragma once

#include <optional>

#include "hearport/security/remembered_auth.h"

namespace hearport::windows {

class ProtectedCredentialStore {
 public:
  ProtectedCredentialStore() = default;

  ProtectedCredentialStore(const ProtectedCredentialStore&) = delete;
  ProtectedCredentialStore& operator=(const ProtectedCredentialStore&) = delete;
  ProtectedCredentialStore(ProtectedCredentialStore&&) noexcept = default;
  ProtectedCredentialStore& operator=(ProtectedCredentialStore&&) noexcept = default;

  bool Save(const security::RememberedCredential& credential) const noexcept;
  std::optional<security::RememberedCredential> Load() const noexcept;
  bool Remove() const noexcept;
};

}  // namespace hearport::windows
