#define NOMINMAX
#include <windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <wrl/client.h>

#include <algorithm>
#include <sstream>
#include <stdexcept>

#include "hearport/windows/music_file.h"
#include "hearport/windows/pcm_normalizer.h"

namespace hearport::windows {
namespace {

void CheckDecode(HRESULT result) {
  if (FAILED(result)) {
    std::ostringstream text;
    text << "Audio decoder HRESULT=0x" << std::hex << static_cast<unsigned long>(result);
    throw std::runtime_error(text.str());
  }
}

struct DecoderRuntime {
  HRESULT com = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  DecoderRuntime() {
    if (FAILED(com) && com != RPC_E_CHANGED_MODE) CheckDecode(com);
    const auto result = MFStartup(MF_VERSION);
    if (FAILED(result)) {
      if (SUCCEEDED(com)) CoUninitialize();
      CheckDecode(result);
    }
  }
  ~DecoderRuntime() { MFShutdown(); if (SUCCEEDED(com)) CoUninitialize(); }
};

}  // namespace

MusicExcerpt LoadMusicExcerpt(const std::filesystem::path& source,
                             std::uint32_t start_seconds,
                             std::uint32_t duration_seconds) {
  if (source.empty() || duration_seconds == 0 || duration_seconds > 3600) {
    throw std::invalid_argument("Invalid audio excerpt duration");
  }
  DecoderRuntime runtime;
  using Microsoft::WRL::ComPtr;
  ComPtr<IMFSourceReader> reader;
  CheckDecode(MFCreateSourceReaderFromURL(source.c_str(), nullptr, &reader));
  CheckDecode(reader->SetStreamSelection(MF_SOURCE_READER_ALL_STREAMS, FALSE));
  CheckDecode(reader->SetStreamSelection(MF_SOURCE_READER_FIRST_AUDIO_STREAM, TRUE));
  ComPtr<IMFMediaType> type;
  CheckDecode(MFCreateMediaType(&type));
  CheckDecode(type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio));
  CheckDecode(type->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM));
  CheckDecode(reader->SetCurrentMediaType(MF_SOURCE_READER_FIRST_AUDIO_STREAM, nullptr, type.Get()));
  CheckDecode(reader->GetCurrentMediaType(MF_SOURCE_READER_FIRST_AUDIO_STREAM, &type));
  UINT32 rate = 0, channels = 0, bits = 0;
  CheckDecode(type->GetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, &rate));
  CheckDecode(type->GetUINT32(MF_MT_AUDIO_NUM_CHANNELS, &channels));
  CheckDecode(type->GetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, &bits));
  if (channels == 0 || channels > 8 || (bits != 16 && bits != 24 && bits != 32)) {
    throw std::runtime_error("Unsupported decoded audio format");
  }
  PcmNormalizer normalizer({rate, static_cast<std::uint16_t>(channels),
      bits == 16 ? SampleFormat::int16_le : bits == 24 ? SampleFormat::int24_le : SampleFormat::int32_le});
  MusicExcerpt clip{source, start_seconds, duration_seconds, {}};
  const auto skip_samples = std::uint64_t(start_seconds) * 48'000 * 2;
  const auto wanted_samples = std::size_t(duration_seconds) * 48'000 * 2;
  clip.samples.reserve(wanted_samples);
  std::uint64_t decoded_samples = 0;
  while (clip.samples.size() < wanted_samples) {
    DWORD flags = 0;
    ComPtr<IMFSample> sample;
    CheckDecode(reader->ReadSample(MF_SOURCE_READER_FIRST_AUDIO_STREAM, 0,
                                  nullptr, &flags, nullptr, &sample));
    if (flags & MF_SOURCE_READERF_CURRENTMEDIATYPECHANGED) {
      throw std::runtime_error("Audio format changed inside the excerpt");
    }
    if (sample) {
      ComPtr<IMFMediaBuffer> buffer;
      CheckDecode(sample->ConvertToContiguousBuffer(&buffer));
      BYTE* data = nullptr;
      DWORD size = 0;
      CheckDecode(buffer->Lock(&data, nullptr, &size));
      std::vector<float> normalized;
      try { normalized = normalizer.Convert({reinterpret_cast<const std::byte*>(data), size}); }
      catch (...) { buffer->Unlock(); throw; }
      CheckDecode(buffer->Unlock());
      const auto first = static_cast<std::size_t>(std::min<std::uint64_t>(normalized.size(),
          skip_samples > decoded_samples ? skip_samples - decoded_samples : 0));
      const auto count = std::min(normalized.size() - first, wanted_samples - clip.samples.size());
      clip.samples.insert(clip.samples.end(), normalized.begin() + first, normalized.begin() + first + count);
      decoded_samples += normalized.size();
    }
    if (flags & MF_SOURCE_READERF_ENDOFSTREAM) break;
  }
  if (clip.samples.size() != wanted_samples) {
    throw std::runtime_error("The selected excerpt extends beyond the end of the audio file");
  }
  return clip;
}

}  // namespace hearport::windows
