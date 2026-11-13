#pragma once

#include <windows.h>
#include <appmodel.h>
#include <winrt/base.h>

// Windows 11's package graph makes the installed, serviced WinUI runtime
// available to the portable executable without registering HearPort itself.
struct WinUiRuntime {
  PACKAGEDEPENDENCY_CONTEXT context{};
  PWSTR dependency = nullptr;

  void Load() {
    if (context) return;
    const auto kernel = GetModuleHandleW(L"kernelbase.dll");
    const auto create = reinterpret_cast<decltype(&TryCreatePackageDependency)>(
        GetProcAddress(kernel, "TryCreatePackageDependency"));
    const auto add = reinterpret_cast<decltype(&AddPackageDependency)>(
        GetProcAddress(kernel, "AddPackageDependency"));
    if (!create || !add) winrt::throw_hresult(E_NOTIMPL);
    PACKAGE_VERSION minimum{};
    minimum.Major = 2;
    minimum.Minor = 6;
    minimum.Build = 5;
    winrt::check_hresult(create(nullptr, L"Microsoft.WindowsAppRuntime.2_8wekyb3d8bbwe",
        minimum, PackageDependencyProcessorArchitectures_None, PackageDependencyLifetimeKind_Process,
        nullptr, CreatePackageDependencyOptions_None, &dependency));
    winrt::check_hresult(add(dependency, 0, AddPackageDependencyOptions_None, &context, nullptr));
  }

  ~WinUiRuntime() {
    const auto kernel = GetModuleHandleW(L"kernelbase.dll");
    if (context) {
      const auto remove = reinterpret_cast<decltype(&RemovePackageDependency)>(
          GetProcAddress(kernel, "RemovePackageDependency"));
      if (remove) remove(context);
    }
    if (dependency) {
      const auto erase = reinterpret_cast<decltype(&DeletePackageDependency)>(
          GetProcAddress(kernel, "DeletePackageDependency"));
      if (erase) erase(dependency);
      HeapFree(GetProcessHeap(), 0, dependency);
    }
  }
};
