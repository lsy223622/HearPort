#include "hearport/windows/wasapi_capture.h"

#if defined(_WIN32)

#include <audioclient.h>
#include <audioclientactivationparams.h>
#include <avrt.h>
#include <ksmedia.h>
#include <initguid.h>
#include <mmdeviceapi.h>
#undef INITGUID
#include <windows.h>
#include <wrl/client.h>
#include <wrl/implements.h>

#include <algorithm>
#include <atomic>
#include <cstring>
#include <stdexcept>
#include <string>
#include <thread>
#include <utility>
#include <vector>

namespace hearport::windows {
namespace {

using Microsoft::WRL::ComPtr;

class ProcessLoopbackActivation final : public Microsoft::WRL::RuntimeClass<
    Microsoft::WRL::RuntimeClassFlags<Microsoft::WRL::ClassicCom>,
    IActivateAudioInterfaceCompletionHandler, Microsoft::WRL::FtmBase> {
 public:
  ProcessLoopbackActivation() {
    params_.ActivationType = AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK;
    params_.ProcessLoopbackParams.TargetProcessId = GetCurrentProcessId();
    params_.ProcessLoopbackParams.ProcessLoopbackMode =
        PROCESS_LOOPBACK_MODE_EXCLUDE_TARGET_PROCESS_TREE;
    activation_.vt = VT_BLOB;
    activation_.blob.cbSize = sizeof(params_);
    activation_.blob.pBlobData = reinterpret_cast<BYTE*>(&params_);
  }

  ~ProcessLoopbackActivation() override { if (completed_) CloseHandle(completed_); }

  HRESULT Open(HANDLE stop_event, ComPtr<IAudioClient>& client) {
    if (!completed_) return E_OUTOFMEMORY;
    ComPtr<IActivateAudioInterfaceAsyncOperation> operation;
    const auto hr = ActivateAudioInterfaceAsync(
        VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK, __uuidof(IAudioClient),
        &activation_, this, &operation);
    if (FAILED(hr)) return hr;
    const HANDLE events[]{completed_, stop_event};
    const auto wait = WaitForMultipleObjects(2, events, FALSE, 3000);
    if (wait == WAIT_OBJECT_0 + 1) return HRESULT_FROM_WIN32(ERROR_CANCELLED);
    if (wait != WAIT_OBJECT_0) return HRESULT_FROM_WIN32(ERROR_TIMEOUT);
    if (SUCCEEDED(result_)) client = std::move(client_);
    return result_;
  }

  HRESULT STDMETHODCALLTYPE ActivateCompleted(IActivateAudioInterfaceAsyncOperation* operation) override {
    HRESULT activation_result = E_FAIL;
    ComPtr<IUnknown> object;
    result_ = operation->GetActivateResult(&activation_result, &object);
    if (SUCCEEDED(result_)) result_ = activation_result;
    if (SUCCEEDED(result_)) result_ = object.As(&client_);
    SetEvent(completed_);
    return S_OK;
  }

 private:
  AUDIOCLIENT_ACTIVATION_PARAMS params_{};
  PROPVARIANT activation_{};
  HANDLE completed_ = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  HRESULT result_ = E_FAIL;
  ComPtr<IAudioClient> client_;
};

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

std::optional<PcmResolution> ReadSystemPcmResolution() {
  const auto initialized = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  if (FAILED(initialized) && initialized != RPC_E_CHANGED_MODE) return std::nullopt;
  std::optional<PcmResolution> result;
  {
    ComPtr<IMMDeviceEnumerator> enumerator;
    ComPtr<IMMDevice> device;
    ComPtr<IPropertyStore> properties;
    PROPVARIANT value{};
    if (SUCCEEDED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                                  IID_PPV_ARGS(&enumerator))) &&
        SUCCEEDED(enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &device)) &&
        SUCCEEDED(device->OpenPropertyStore(STGM_READ, &properties)) &&
        SUCCEEDED(properties->GetValue(PKEY_AudioEngine_DeviceFormat, &value)) &&
        value.vt == VT_BLOB && value.blob.cbSize >= sizeof(PCMWAVEFORMAT)) {
      WAVEFORMATEXTENSIBLE wave{};
      std::memcpy(&wave, value.blob.pBlobData,
                  std::min<std::size_t>(value.blob.cbSize, sizeof(wave)));
      unsigned bits = wave.Format.wBitsPerSample;
      if (wave.Format.wFormatTag == WAVE_FORMAT_EXTENSIBLE &&
          value.blob.cbSize >= sizeof(wave) && wave.Samples.wValidBitsPerSample != 0) {
        bits = wave.Samples.wValidBitsPerSample;
      }
      if (wave.Format.nSamplesPerSec != 0 && bits != 0)
        result = PcmResolution{wave.Format.nSamplesPerSec, bits};
    }
    PropVariantClear(&value);
  }
  if (SUCCEEDED(initialized)) CoUninitialize();
  return result;
}

struct WasapiLoopbackCapture::Impl {
  PacketHandler on_packet;
  ResetHandler on_reset;
  LogHandler log;
  std::atomic<CaptureSource> actual_source{CaptureSource::process};
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

      constexpr DWORD stream_flags = AUDCLNT_STREAMFLAGS_LOOPBACK |
                                     AUDCLNT_STREAMFLAGS_EVENTCALLBACK;
      auto start = [&](const WAVEFORMATEX* wave, DWORD flags) {
        auto result = audio_client->Initialize(AUDCLNT_SHAREMODE_SHARED, flags,
                                               0, 0, wave, nullptr);
        if (SUCCEEDED(result)) result = audio_client->SetEventHandle(wake_event);
        if (SUCCEEDED(result)) result = audio_client->GetService(IID_PPV_ARGS(&capture_client));
        if (SUCCEEDED(result)) result = audio_client->Start();
        return result;
      };
      HRESULT result = E_FAIL;
      WAVEFORMATEX process_format{WAVE_FORMAT_IEEE_FLOAT, 2, 48000, 384000, 8, 32, 0};
      const WAVEFORMATEX* wave = &process_format;
      if (actual_source == CaptureSource::process) {
        auto activation = Microsoft::WRL::Make<ProcessLoopbackActivation>();
        result = activation ? activation->Open(wake_event, audio_client) : E_OUTOFMEMORY;
        if (!running) break;
        if (SUCCEEDED(result)) {
          result = start(wave, stream_flags | AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM);
        }
        if (FAILED(result)) {
          if (log) log("capture_process_loopback_unavailable hresult=" +
                       std::to_string(static_cast<std::uint32_t>(result)));
          cleanup();
          capture_client.Reset();
          audio_client.Reset();
          actual_source = CaptureSource::endpoint;
        }
      }
      if (actual_source == CaptureSource::endpoint) {
        result = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                                  IID_PPV_ARGS(&enumerator));
        if (SUCCEEDED(result)) result = enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &device);
        if (SUCCEEDED(result)) result = device->Activate(__uuidof(IAudioClient), CLSCTX_ALL,
                                                        nullptr, &audio_client);
        if (SUCCEEDED(result)) result = audio_client->GetMixFormat(&mix_format);
        wave = mix_format;
      }
      PcmFormat format;
      if (SUCCEEDED(result)) {
        try {
          format = ReadPcmFormat(*wave);
        } catch (...) {
          result = E_INVALIDARG;
        }
        if (SUCCEEDED(result) && actual_source == CaptureSource::endpoint) {
          result = start(wave, stream_flags);
        }
      }
      if (FAILED(result)) {
        cleanup();
        if (!reset_notified && on_reset) {
          on_reset();
          reset_notified = true;
        }
        WaitForSingleObject(wake_event, 250);
        continue;
      }

      reset_notified = false;
      if (log) log(actual_source == CaptureSource::process
                      ? "capture_started source=process_loopback"
                      : "capture_started source=endpoint_loopback");
      const auto block_bytes = static_cast<std::size_t>(wave->nBlockAlign);
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
          UINT64 capture_qpc = 0;
          const auto buffer_result = capture_client->GetBuffer(
              &data, &frames, &flags, nullptr, &capture_qpc);
          if (FAILED(buffer_result)) {
            reset = buffer_result == AUDCLNT_E_DEVICE_INVALIDATED ||
                    buffer_result == AUDCLNT_E_RESOURCES_INVALIDATED ||
                    buffer_result == AUDCLNT_E_SERVICE_NOT_RUNNING;
            break;
          }

          const auto byte_count = static_cast<std::size_t>(frames) * block_bytes;
          if ((flags & AUDCLNT_BUFFERFLAGS_TIMESTAMP_ERROR) != 0) {
            capture_client->ReleaseBuffer(frames);
            reset = true;
            break;
          }
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
                      format, capture_qpc * 100);
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
                                  ResetHandler on_reset, CaptureSource source,
                                  LogHandler log) {
  if (impl_->running.exchange(true)) {
    return false;
  }
  impl_->on_packet = std::move(on_packet);
  impl_->on_reset = std::move(on_reset);
  impl_->actual_source = source;
  impl_->log = std::move(log);
  impl_->wake_event = CreateEventW(nullptr, FALSE, FALSE, nullptr);
  if (impl_->wake_event == nullptr) {
    impl_->running = false;
    return false;
  }
  impl_->thread = std::thread([this] { impl_->Run(); });
  return true;
}

void WasapiLoopbackCapture::Stop() {
  impl_->running = false;
  if (impl_->wake_event != nullptr) {
    SetEvent(impl_->wake_event);
  }
  if (impl_->thread.joinable()) {
    impl_->thread.join();
  }
  if (impl_->wake_event != nullptr) {
    CloseHandle(impl_->wake_event);
    impl_->wake_event = nullptr;
  }
}

bool WasapiLoopbackCapture::running() const noexcept { return impl_->running; }
CaptureSource WasapiLoopbackCapture::source() const noexcept { return impl_->actual_source; }

}  // namespace hearport::windows

#else

namespace hearport::windows {

struct WasapiLoopbackCapture::Impl {};

WasapiLoopbackCapture::WasapiLoopbackCapture()
    : impl_(std::make_unique<Impl>()) {}
WasapiLoopbackCapture::~WasapiLoopbackCapture() = default;
bool WasapiLoopbackCapture::Start(PacketHandler, ResetHandler, CaptureSource, LogHandler) { return false; }
CaptureSource WasapiLoopbackCapture::source() const noexcept { return CaptureSource::endpoint; }
void WasapiLoopbackCapture::Stop() {}
bool WasapiLoopbackCapture::running() const noexcept { return false; }

}  // namespace hearport::windows

#endif
