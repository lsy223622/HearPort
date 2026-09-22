#include "hearport/windows/wasapi_capture.h"

#if defined(_WIN32)

#include <audioclient.h>
#include <avrt.h>
#include <ksmedia.h>
#include <mmdeviceapi.h>
#include <windows.h>
#include <wrl/client.h>

#include <algorithm>
#include <atomic>
#include <cstring>
#include <stdexcept>
#include <thread>
#include <utility>
#include <vector>

namespace hearport::windows {
namespace {

using Microsoft::WRL::ComPtr;

PcmFormat ReadPcmFormat(const WAVEFORMATEX& wave_format) {
  PcmFormat format{};
  format.sample_rate_hz = wave_format.nSamplesPerSec;
  format.channels = wave_format.nChannels;
  if (wave_format.wFormatTag == WAVE_FORMAT_IEEE_FLOAT) {
    format.sample_format = SampleFormat::float32_le;
  } else if (wave_format.wFormatTag == WAVE_FORMAT_PCM) {
    switch (wave_format.wBitsPerSample) {
      case 16:
        format.sample_format = SampleFormat::int16_le;
        break;
      case 24:
        format.sample_format = SampleFormat::int24_le;
        break;
      case 32:
        format.sample_format = SampleFormat::int32_le;
        break;
      default:
        throw std::runtime_error("unsupported WASAPI PCM bit depth");
    }
  } else if (wave_format.wFormatTag == WAVE_FORMAT_EXTENSIBLE) {
    const auto& extensible =
        reinterpret_cast<const WAVEFORMATEXTENSIBLE&>(wave_format);
    if (IsEqualGUID(extensible.SubFormat, KSDATAFORMAT_SUBTYPE_IEEE_FLOAT)) {
      format.sample_format = SampleFormat::float32_le;
    } else if (IsEqualGUID(extensible.SubFormat, KSDATAFORMAT_SUBTYPE_PCM)) {
      switch (wave_format.wBitsPerSample) {
        case 16:
          format.sample_format = SampleFormat::int16_le;
          break;
        case 24:
          format.sample_format = SampleFormat::int24_le;
          break;
        case 32:
          format.sample_format = SampleFormat::int32_le;
          break;
        default:
          throw std::runtime_error("unsupported WASAPI extensible bit depth");
      }
    } else {
      throw std::runtime_error("unsupported WASAPI extensible subformat");
    }
  } else {
    throw std::runtime_error("unsupported WASAPI format tag");
  }
  return format;
}

}  // namespace

struct WasapiLoopbackCapture::Impl {
  PacketHandler on_packet;
  ResetHandler on_reset;
  std::atomic_bool running{false};
  HANDLE wake_event = nullptr;
  std::thread thread;

  void Run() {
    const auto com_result = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    const bool com_initialized = SUCCEEDED(com_result);

    if (!com_initialized) {
      running = false;
      if (on_reset) {
        on_reset();
      }
      return;
    }

    bool reset_notified = false;
    while (running) {
      ComPtr<IMMDeviceEnumerator> enumerator;
      ComPtr<IMMDevice> device;
      ComPtr<IAudioClient> audio_client;
      ComPtr<IAudioCaptureClient> capture_client;
      WAVEFORMATEX* mix_format = nullptr;
      const auto cleanup = [&] {
        if (audio_client) {
          audio_client->Stop();
        }
        if (mix_format != nullptr) {
          CoTaskMemFree(mix_format);
          mix_format = nullptr;
        }
      };

      HRESULT result = CoCreateInstance(
          __uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
          IID_PPV_ARGS(&enumerator));
      if (FAILED(result) ||
          FAILED(enumerator->GetDefaultAudioEndpoint(eRender, eConsole,
                                                      &device)) ||
          FAILED(device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                                  &audio_client)) ||
          FAILED(audio_client->GetMixFormat(&mix_format))) {
        cleanup();
        if (!reset_notified && on_reset) {
          on_reset();
          reset_notified = true;
        }
        WaitForSingleObject(wake_event, 250);
        continue;
      }

      PcmFormat format;
      try {
        format = ReadPcmFormat(*mix_format);
      } catch (...) {
        cleanup();
        if (!reset_notified && on_reset) {
          on_reset();
          reset_notified = true;
        }
        WaitForSingleObject(wake_event, 250);
        continue;
      }

      constexpr DWORD stream_flags = AUDCLNT_STREAMFLAGS_LOOPBACK |
                                     AUDCLNT_STREAMFLAGS_EVENTCALLBACK;
      if (FAILED(audio_client->Initialize(AUDCLNT_SHAREMODE_SHARED,
                                           stream_flags, 0, 0, mix_format,
                                           nullptr)) ||
          FAILED(audio_client->SetEventHandle(wake_event)) ||
          FAILED(audio_client->GetService(IID_PPV_ARGS(&capture_client))) ||
          FAILED(audio_client->Start())) {
        cleanup();
        if (!reset_notified && on_reset) {
          on_reset();
          reset_notified = true;
        }
        WaitForSingleObject(wake_event, 250);
        continue;
      }

      reset_notified = false;
      const auto block_bytes = static_cast<std::size_t>(mix_format->nBlockAlign);
      constexpr std::size_t kMaxCaptureFrames = 4096;
      std::vector<std::byte> scratch(kMaxCaptureFrames * block_bytes);
      HANDLE avrt_task = nullptr;
      DWORD avrt_task_index = 0;
      avrt_task = AvSetMmThreadCharacteristicsW(L"Pro Audio", &avrt_task_index);

      bool reset = false;
      while (running && !reset) {
        const auto wait_result = WaitForSingleObject(wake_event, 100);
        if (wait_result == WAIT_FAILED) {
          reset = true;
          break;
        }

        UINT32 packet_frames = 0;
        auto packet_result = capture_client->GetNextPacketSize(&packet_frames);
        if (FAILED(packet_result)) {
          reset = true;
          break;
        }
        while (packet_frames != 0) {
          BYTE* data = nullptr;
          UINT32 frames = 0;
          DWORD flags = 0;
          const auto buffer_result = capture_client->GetBuffer(
              &data, &frames, &flags, nullptr, nullptr);
          if (FAILED(buffer_result)) {
            reset = buffer_result == AUDCLNT_E_DEVICE_INVALIDATED ||
                    buffer_result == AUDCLNT_E_RESOURCES_INVALIDATED ||
                    buffer_result == AUDCLNT_E_SERVICE_NOT_RUNNING;
            break;
          }

          const auto byte_count = static_cast<std::size_t>(frames) * block_bytes;
          if (frames > kMaxCaptureFrames) {
            capture_client->ReleaseBuffer(frames);
            reset = true;
            break;
          }
          if ((flags & AUDCLNT_BUFFERFLAGS_SILENT) != 0) {
            std::fill(scratch.begin(), scratch.begin() +
                                        static_cast<std::ptrdiff_t>(byte_count),
                      std::byte{0});
          } else {
            std::memcpy(scratch.data(), data, byte_count);
          }
          if (on_packet) {
            on_packet(std::span<const std::byte>(scratch.data(), byte_count),
                      format);
          }
          capture_client->ReleaseBuffer(frames);
          packet_result = capture_client->GetNextPacketSize(&packet_frames);
          if (FAILED(packet_result)) {
            reset = true;
            break;
          }
        }
      }

      if (avrt_task != nullptr) {
        AvRevertMmThreadCharacteristics(avrt_task);
      }
      cleanup();
      if (reset && running) {
        if (!reset_notified && on_reset) {
          on_reset();
          reset_notified = true;
        }
        WaitForSingleObject(wake_event, 250);
      }
    }

    if (wake_event != nullptr) {
      CloseHandle(wake_event);
      wake_event = nullptr;
    }
    running = false;
    if (com_initialized) {
      CoUninitialize();
    }
  }
};

WasapiLoopbackCapture::WasapiLoopbackCapture()
    : impl_(std::make_unique<Impl>()) {}

WasapiLoopbackCapture::~WasapiLoopbackCapture() { Stop(); }

bool WasapiLoopbackCapture::Start(PacketHandler on_packet,
                                  ResetHandler on_reset) {
  if (impl_->running.exchange(true)) {
    return false;
  }
  impl_->on_packet = std::move(on_packet);
  impl_->on_reset = std::move(on_reset);
  impl_->wake_event = CreateEventW(nullptr, FALSE, FALSE, nullptr);
  if (impl_->wake_event == nullptr) {
    impl_->running = false;
    return false;
  }
  impl_->thread = std::thread([this] { impl_->Run(); });
  return true;
}

void WasapiLoopbackCapture::Stop() {
  if (!impl_->running.exchange(false)) {
    if (impl_->thread.joinable()) {
      impl_->thread.join();
    }
    return;
  }
  if (impl_->wake_event != nullptr) {
    SetEvent(impl_->wake_event);
  }
  if (impl_->thread.joinable()) {
    impl_->thread.join();
  }
}

bool WasapiLoopbackCapture::running() const noexcept { return impl_->running; }

}  // namespace hearport::windows

#else

namespace hearport::windows {

struct WasapiLoopbackCapture::Impl {};

WasapiLoopbackCapture::WasapiLoopbackCapture()
    : impl_(std::make_unique<Impl>()) {}
WasapiLoopbackCapture::~WasapiLoopbackCapture() = default;
bool WasapiLoopbackCapture::Start(PacketHandler, ResetHandler) { return false; }
void WasapiLoopbackCapture::Stop() {}
bool WasapiLoopbackCapture::running() const noexcept { return false; }

}  // namespace hearport::windows

#endif
