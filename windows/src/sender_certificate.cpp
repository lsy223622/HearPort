#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <bcrypt.h>
#include <ncrypt.h>
#include <wincrypt.h>

#include <array>
#include <string>
#include <string_view>
#include <vector>

#include "hearport/windows/sender_certificate.h"

namespace hearport::windows {
namespace {

constexpr wchar_t kSubject[] = L"HearPort Local";
constexpr wchar_t kKeyName[] = L"HearPort Local TLS";

bool ReadIdentity(PCCERT_CONTEXT certificate, QuicServerOptions& options) {
  if (CertVerifyTimeValidity(nullptr, certificate->pCertInfo) != 0) return false;

  if (!CertFindExtension(szOID_ENHANCED_KEY_USAGE,
                         certificate->pCertInfo->cExtension,
                         certificate->pCertInfo->rgExtension)) {
    return false;
  }
  DWORD usage_size = 0;
  if (!CertGetEnhancedKeyUsage(certificate, CERT_FIND_EXT_ONLY_ENHKEY_USAGE_FLAG,
                               nullptr, &usage_size)) return false;
  std::vector<BYTE> usage_bytes(usage_size);
  auto* usage = reinterpret_cast<PCERT_ENHKEY_USAGE>(usage_bytes.data());
  if (!CertGetEnhancedKeyUsage(certificate, CERT_FIND_EXT_ONLY_ENHKEY_USAGE_FLAG,
                               usage, &usage_size)) return false;
  bool server_auth = false;
  for (DWORD i = 0; i < usage->cUsageIdentifier; ++i) {
    if (std::string_view(usage->rgpszUsageIdentifier[i]) ==
        szOID_PKIX_KP_SERVER_AUTH) {
      server_auth = true;
      break;
    }
  }
  if (!server_auth) return false;
  if (!CertFindExtension(szOID_KEY_USAGE,
                         certificate->pCertInfo->cExtension,
                         certificate->pCertInfo->rgExtension)) return false;

  wchar_t subject[128]{};
  if (CertGetNameStringW(certificate, CERT_NAME_SIMPLE_DISPLAY_TYPE, 0,
                         nullptr, subject, std::size(subject)) == 0 ||
      std::wstring_view(subject) != kSubject) {
    return false;
  }

  DWORD key_info_size = 0;
  if (!CertGetCertificateContextProperty(certificate,
                                         CERT_KEY_PROV_INFO_PROP_ID, nullptr,
                                         &key_info_size)) {
    return false;
  }
  std::vector<BYTE> key_info_bytes(key_info_size);
  if (!CertGetCertificateContextProperty(certificate,
                                         CERT_KEY_PROV_INFO_PROP_ID,
                                         key_info_bytes.data(),
                                         &key_info_size) ||
      reinterpret_cast<PCRYPT_KEY_PROV_INFO>(key_info_bytes.data())
              ->dwKeySpec != 0) {
    return false;
  }
  HCRYPTPROV_OR_NCRYPT_KEY_HANDLE private_key = 0;
  DWORD key_spec = 0;
  BOOL release_key = FALSE;
  if (!CryptAcquireCertificatePrivateKey(
          certificate, CRYPT_ACQUIRE_SILENT_FLAG |
                           CRYPT_ACQUIRE_ONLY_NCRYPT_KEY_FLAG |
                           CRYPT_ACQUIRE_COMPARE_KEY_FLAG,
          nullptr, &private_key, &key_spec, &release_key)) {
    return false;
  }
  DWORD key_usage = 0;
  DWORD key_usage_size = sizeof(key_usage);
  const bool suitable_key = NCryptGetProperty(
      private_key, NCRYPT_KEY_USAGE_PROPERTY,
      reinterpret_cast<PBYTE>(&key_usage), key_usage_size,
      &key_usage_size, 0) == 0 &&
      key_usage == (NCRYPT_ALLOW_DECRYPT_FLAG | NCRYPT_ALLOW_SIGNING_FLAG);
  if (release_key) NCryptFreeObject(private_key);
  if (!suitable_key) return false;

  DWORD sha1_size = static_cast<DWORD>(options.certificate_sha1.size());
  if (!CertGetCertificateContextProperty(
          certificate, CERT_SHA1_HASH_PROP_ID, options.certificate_sha1.data(),
          &sha1_size) || sha1_size != options.certificate_sha1.size()) {
    return false;
  }

  BYTE* encoded = nullptr;
  DWORD encoded_size = 0;
  if (!CryptEncodeObjectEx(X509_ASN_ENCODING, X509_PUBLIC_KEY_INFO,
                           &certificate->pCertInfo->SubjectPublicKeyInfo,
                           CRYPT_ENCODE_ALLOC_FLAG, nullptr, &encoded,
                           &encoded_size)) {
    return false;
  }

  DWORD hash_size = static_cast<DWORD>(options.certificate_spki_sha256.size());
  const bool hashed = CryptHashCertificate2(
                          BCRYPT_SHA256_ALGORITHM, 0, nullptr, encoded,
                          encoded_size,
                          reinterpret_cast<BYTE*>(
                              options.certificate_spki_sha256.data()),
                          &hash_size) &&
                      hash_size == options.certificate_spki_sha256.size();
  LocalFree(encoded);
  options.has_certificate_sha1 = hashed;
  options.has_certificate_spki_sha256 = hashed;
  return hashed;
}

PCCERT_CONTEXT CreateCertificate() {
  NCRYPT_PROV_HANDLE provider = 0;
  NCRYPT_KEY_HANDLE key = 0;
  if (NCryptOpenStorageProvider(&provider, MS_KEY_STORAGE_PROVIDER, 0) != 0) {
    return nullptr;
  }
  if (NCryptCreatePersistedKey(provider, &key, NCRYPT_RSA_ALGORITHM, kKeyName,
                               0, NCRYPT_OVERWRITE_KEY_FLAG) != 0) {
    NCryptFreeObject(provider);
    return nullptr;
  }
  DWORD key_bits = 2048;
  DWORD key_usage = NCRYPT_ALLOW_DECRYPT_FLAG | NCRYPT_ALLOW_SIGNING_FLAG;
  bool ready = NCryptSetProperty(
                   key, NCRYPT_LENGTH_PROPERTY,
                   reinterpret_cast<PBYTE>(&key_bits), sizeof(key_bits), 0) == 0 &&
               NCryptSetProperty(
                   key, NCRYPT_KEY_USAGE_PROPERTY,
                   reinterpret_cast<PBYTE>(&key_usage), sizeof(key_usage), 0) == 0 &&
               NCryptFinalizeKey(key, 0) == 0;

  PCCERT_CONTEXT certificate = nullptr;
  if (ready) {
    DWORD subject_size = 0;
    const wchar_t distinguished_name[] = L"CN=HearPort Local";
    if (CertStrToNameW(X509_ASN_ENCODING, distinguished_name,
                       CERT_X500_NAME_STR, nullptr, nullptr, &subject_size,
                       nullptr)) {
      std::vector<BYTE> subject_bytes(subject_size);
      if (CertStrToNameW(X509_ASN_ENCODING, distinguished_name,
                         CERT_X500_NAME_STR, nullptr, subject_bytes.data(),
                         &subject_size, nullptr)) {
        CERT_NAME_BLOB subject{subject_size, subject_bytes.data()};
        CRYPT_KEY_PROV_INFO key_info{};
        key_info.pwszContainerName = const_cast<wchar_t*>(kKeyName);
        key_info.pwszProvName = const_cast<wchar_t*>(MS_KEY_STORAGE_PROVIDER);
        key_info.dwKeySpec = 0;
        CRYPT_ALGORITHM_IDENTIFIER signature{};
        signature.pszObjId = const_cast<char*>(szOID_RSA_SHA256RSA);
        SYSTEMTIME start{};
        GetSystemTime(&start);
        SYSTEMTIME end = start;
        end.wYear += 5;

        char* server_auth = const_cast<char*>(szOID_PKIX_KP_SERVER_AUTH);
        CERT_ENHKEY_USAGE server_usage{1, &server_auth};
        BYTE* encoded_usage = nullptr;
        DWORD encoded_usage_size = 0;
        if (!CryptEncodeObjectEx(X509_ASN_ENCODING, X509_ENHANCED_KEY_USAGE,
                                 &server_usage, CRYPT_ENCODE_ALLOC_FLAG,
                                 nullptr, &encoded_usage, &encoded_usage_size)) {
          NCryptFreeObject(key);
          NCryptFreeObject(provider);
          return nullptr;
        }
        CERT_EXTENSION usage_extension{};
        usage_extension.pszObjId = const_cast<char*>(szOID_ENHANCED_KEY_USAGE);
        usage_extension.Value = {encoded_usage_size, encoded_usage};
        BYTE key_usage_bits = CERT_DIGITAL_SIGNATURE_KEY_USAGE |
                              CERT_KEY_ENCIPHERMENT_KEY_USAGE;
        CRYPT_BIT_BLOB key_usage{1, &key_usage_bits, 5};
        BYTE* encoded_key_usage = nullptr;
        DWORD encoded_key_usage_size = 0;
        if (!CryptEncodeObjectEx(X509_ASN_ENCODING, X509_KEY_USAGE,
                                 &key_usage, CRYPT_ENCODE_ALLOC_FLAG,
                                 nullptr, &encoded_key_usage,
                                 &encoded_key_usage_size)) {
          LocalFree(encoded_usage);
          NCryptFreeObject(key);
          NCryptFreeObject(provider);
          return nullptr;
        }
        CERT_EXTENSION key_usage_extension{};
        key_usage_extension.pszObjId = const_cast<char*>(szOID_KEY_USAGE);
        key_usage_extension.Value = {encoded_key_usage_size,
                                     encoded_key_usage};
        CERT_EXTENSION extension_list[]{usage_extension, key_usage_extension};
        CERT_EXTENSIONS extensions{2, extension_list};
        certificate = CertCreateSelfSignCertificate(
            key, &subject, 0, &key_info, &signature, &start, &end,
            &extensions);
        LocalFree(encoded_key_usage);
        LocalFree(encoded_usage);
      }
    }
  }
  NCryptFreeObject(key);
  NCryptFreeObject(provider);
  return certificate;
}

}  // namespace

std::optional<QuicServerOptions> LoadOrCreateSenderIdentity() {
  HCERTSTORE store = CertOpenSystemStoreW(0, L"MY");
  if (!store) return std::nullopt;

  QuicServerOptions options;
  PCCERT_CONTEXT certificate = nullptr;
  while ((certificate = CertFindCertificateInStore(
              store, X509_ASN_ENCODING, 0, CERT_FIND_SUBJECT_STR_W, kSubject,
              certificate)) != nullptr) {
    if (ReadIdentity(certificate, options)) {
      CertFreeCertificateContext(certificate);
      CertCloseStore(store, 0);
      return options;
    }
  }

  certificate = CreateCertificate();
  if (!certificate) {
    CertCloseStore(store, 0);
    return std::nullopt;
  }
  const bool added = CertAddCertificateContextToStore(
      store, certificate, CERT_STORE_ADD_REPLACE_EXISTING, nullptr);
  const bool loaded = added && ReadIdentity(certificate, options);
  CertFreeCertificateContext(certificate);
  CertCloseStore(store, 0);
  if (!loaded) return std::nullopt;
  return options;
}

}  // namespace hearport::windows
