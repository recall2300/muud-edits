// muud_media_plugin.cpp
// muud-edits — Windows 미디어 채널 구현.
//
// 빌드 요구사항:
//   * Flutter Windows embedder (flutter/plugin_registrar_windows.h)
//   * nlohmann/json (single header) — CMakeLists.snippet.txt 참고
//   * ffmpeg / ffprobe 실행 파일 (앱 옆 또는 PATH)
//
// 스레드 규칙:
//   * FFmpeg 프로세스와 파싱은 워커 스레드에서 한다.
//   * Flutter EventSink는 반드시 플랫폼(UI) 스레드에서 호출해야 하므로,
//     이벤트를 큐에 넣고 PostMessage(WM_APP+41)로 UI 스레드에 깨운 뒤 보낸다.

#include "muud_media_plugin.h"

#include <windows.h>

#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <cctype>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <sstream>

#include <nlohmann/json.hpp>

using nlohmann::json;

// MuudMediaPlugin 은 muud 네임스페이스 밖(전역)에 선언되어 있다.
// 멤버 정의에서 쓰는 muud 별칭을 전역으로 끌어온다.
using EncodableMap = flutter::EncodableMap;
using EncodableValue = flutter::EncodableValue;

namespace muud {
namespace {

constexpr UINT kMuudEventMessage = WM_APP + 41;

// ------------------------------------------------------------------ 문자열

std::wstring Utf8ToWide(const std::string& text) {
  if (text.empty()) return std::wstring();
  int size = MultiByteToWideChar(CP_UTF8, 0, text.c_str(), -1, nullptr, 0);
  if (size <= 0) return std::wstring();
  std::wstring wide(static_cast<size_t>(size - 1), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, text.c_str(), -1, &wide[0], size);
  return wide;
}

std::string WideToUtf8(const std::wstring& text) {
  if (text.empty()) return std::string();
  int size = WideCharToMultiByte(CP_UTF8, 0, text.c_str(), -1, nullptr, 0,
                                 nullptr, nullptr);
  if (size <= 0) return std::string();
  std::string out(static_cast<size_t>(size - 1), '\0');
  WideCharToMultiByte(CP_UTF8, 0, text.c_str(), -1, &out[0], size, nullptr,
                      nullptr);
  return out;
}

/// CreateProcessW용 명령줄 인용.
std::wstring Quote(const std::wstring& value) {
  if (value.find_first_of(L" \t\n\v\"") == std::wstring::npos) {
    return value;
  }
  std::wstring out = L"\"";
  for (wchar_t ch : value) {
    if (ch == L'"') {
      out += L"\\\"";
    } else {
      out += ch;
    }
  }
  out += L"\"";
  return out;
}

std::string GetEnvOr(const char* name, const char* fallback) {
  char buffer[MAX_PATH];
  DWORD length = GetEnvironmentVariableA(name, buffer, MAX_PATH);
  if (length > 0 && length < MAX_PATH) {
    return std::string(buffer, length);
  }
  return fallback;
}

/// 앱 실행 파일 옆의 도구를 우선 쓰고, 없으면 PATH 이름을 쓴다.
std::wstring ToolPath(const std::string& tool) {
  wchar_t module[MAX_PATH];
  DWORD length = GetModuleFileNameW(nullptr, module, MAX_PATH);
  if (length > 0) {
    std::wstring dir(module, length);
    size_t slash = dir.find_last_of(L"\\/");
    if (slash != std::wstring::npos) {
      dir = dir.substr(0, slash + 1);
      std::wstring local = dir + std::wstring(tool.begin(), tool.end()) + L".exe";
      if (GetFileAttributesW(local.c_str()) != INVALID_FILE_ATTRIBUTES) {
        return local;
      }
    }
  }
  return std::wstring(tool.begin(), tool.end());
}

// ------------------------------------------------------------------ 프로세스

struct CaptureResult {
  bool ok = false;
  DWORD exit_code = 1;
  std::string output;
  std::string error;
};

/// 명령을 실행하고 stdout+stderr를 모아 돌려준다(프로브용).
CaptureResult RunCapture(const std::wstring& command) {
  CaptureResult result;
  SECURITY_ATTRIBUTES attributes{};
  attributes.nLength = sizeof(attributes);
  attributes.bInheritHandle = TRUE;

  HANDLE read_pipe = nullptr;
  HANDLE write_pipe = nullptr;
  if (!CreatePipe(&read_pipe, &write_pipe, &attributes, 0)) {
    result.error = "파이프를 만들지 못했습니다";
    return result;
  }
  SetHandleInformation(read_pipe, HANDLE_FLAG_INHERIT, 0);

  STARTUPINFOW startup{};
  startup.cb = sizeof(startup);
  startup.dwFlags = STARTF_USESTDHANDLES | STARTF_USESHOWWINDOW;
  startup.wShowWindow = SW_HIDE;
  startup.hStdOutput = write_pipe;
  startup.hStdError = write_pipe;
  startup.hStdInput = GetStdHandle(STD_INPUT_HANDLE);

  PROCESS_INFORMATION process{};
  std::wstring mutable_command = command;
  BOOL created = CreateProcessW(nullptr, mutable_command.data(), nullptr,
                                nullptr, TRUE, CREATE_NO_WINDOW, nullptr,
                                nullptr, &startup, &process);
  CloseHandle(write_pipe);
  if (!created) {
    CloseHandle(read_pipe);
    result.error = "프로세스를 시작하지 못했습니다";
    return result;
  }

  char buffer[4096];
  DWORD read = 0;
  while (ReadFile(read_pipe, buffer, sizeof(buffer), &read, nullptr) && read > 0) {
    result.output.append(buffer, read);
  }
  WaitForSingleObject(process.hProcess, INFINITE);
  GetExitCodeProcess(process.hProcess, &result.exit_code);
  CloseHandle(process.hProcess);
  CloseHandle(process.hThread);
  CloseHandle(read_pipe);
  result.ok = result.exit_code == 0;
  if (!result.ok && result.error.empty()) {
    result.error = result.output.substr(0, 800);
  }
  return result;
}

// ------------------------------------------------------------------ 숫자/변환

int64_t JsonInt(const json& node, const char* key, int64_t fallback) {
  if (!node.contains(key)) return fallback;
  const auto& value = node.at(key);
  if (value.is_number()) return value.get<int64_t>();
  if (value.is_number_float()) return static_cast<int64_t>(value.get<double>());
  if (value.is_string()) {
    try {
      return std::stoll(value.get<std::string>());
    } catch (...) {
      return fallback;
    }
  }
  return fallback;
}

double JsonDouble(const json& node, const char* key, double fallback) {
  if (!node.contains(key)) return fallback;
  const auto& value = node.at(key);
  if (value.is_number()) return value.get<double>();
  if (value.is_string()) {
    try {
      return std::stod(value.get<std::string>());
    } catch (...) {
      return fallback;
    }
  }
  return fallback;
}

std::string JsonString(const json& node, const char* key,
                       const std::string& fallback = std::string()) {
  if (!node.contains(key) || !node.at(key).is_string()) return fallback;
  return node.at(key).get<std::string>();
}

bool JsonBool(const json& node, const char* key, bool fallback) {
  if (!node.contains(key) || !node.at(key).is_boolean()) return fallback;
  return node.at(key).get<bool>();
}

/// "30000/1001" → 29.97
double ParseFrameRate(const std::string& text) {
  size_t slash = text.find('/');
  try {
    if (slash == std::string::npos) {
      return std::stod(text);
    }
    double numerator = std::stod(text.substr(0, slash));
    double denominator = std::stod(text.substr(slash + 1));
    if (denominator <= 0) return 0.0;
    return numerator / denominator;
  } catch (...) {
    return 0.0;
  }
}

std::string FormatSeconds(int64_t ms) {
  char buffer[64];
  std::snprintf(buffer, sizeof(buffer), "%.3f",
                static_cast<double>(ms) / 1000.0);
  return buffer;
}

/// SRT 사이드카를 임시 파일로 쓴다(자막 번인용).
std::string WriteSrt(const json& subtitles, std::string* error) {
  wchar_t temp_path[MAX_PATH];
  wchar_t temp_file[MAX_PATH];
  if (GetTempPathW(MAX_PATH, temp_path) == 0 ||
      GetTempFileNameW(temp_path, L"muud", 0, temp_file) == 0) {
    *error = "임시 파일을 만들지 못했습니다";
    return std::string();
  }
  std::ofstream out(temp_file, std::ios::binary | std::ios::trunc);
  if (!out) {
    *error = "자막 파일을 쓰지 못했습니다";
    return std::string();
  }
  const auto& items = subtitles.contains("items") && subtitles["items"].is_array()
                          ? subtitles["items"]
                          : json::array();
  int index = 1;
  for (const auto& item : items) {
    int64_t start = JsonInt(item, "render_start_ms", 0);
    int64_t end = JsonInt(item, "render_end_ms", 0);
    auto stamp = [](int64_t ms) {
      char buffer[32];
      int64_t total = std::max<int64_t>(0, ms);
      std::snprintf(buffer, sizeof(buffer), "%02lld:%02lld:%02lld,%03lld",
                    static_cast<long long>(total / 3600000),
                    static_cast<long long>((total / 60000) % 60),
                    static_cast<long long>((total / 1000) % 60),
                    static_cast<long long>(total % 1000));
      return std::string(buffer);
    };
    std::string text = JsonString(item, "display_text");
    if (text.empty()) text = JsonString(item, "text");
    out << index++ << "\r\n" << stamp(start) << " --> " << stamp(end)
        << "\r\n" << text << "\r\n\r\n";
  }
  out.close();
  return WideToUtf8(temp_file);
}

/// ffmpeg 필터에서 경로를 안전하게 쓴다(Windows 드라이브 콜론/역슬래시).
std::string EscapeFilterPath(const std::string& path) {
  std::string escaped;
  for (char ch : path) {
    if (ch == '\\' || ch == ':' || ch == '\'') {
      escaped += '\\';
    }
    escaped += ch;
  }
  return escaped;
}

}  // namespace

// ================================================================== pipeline

FfmpegPipeline::FfmpegPipeline() = default;
FfmpegPipeline::~FfmpegPipeline() {
  Cancel();
  if (worker_.joinable()) {
    worker_.join();
  }
}

void FfmpegPipeline::Emit(const EncodableMap& payload) {
  if (on_event_) on_event_(payload);
}

void FfmpegPipeline::EmitState(const std::string& event, const std::string& state,
                               int64_t completed, int64_t total,
                               const std::string& message,
                               const std::string& error) {
  EncodableMap payload;
  payload[EncodableValue("event")] = EncodableValue(event);
  if (!state.empty()) payload[EncodableValue("state")] = EncodableValue(state);
  if (completed >= 0) {
    payload[EncodableValue("completed_frames")] =
        EncodableValue(static_cast<int64_t>(completed));
  }
  if (total >= 0) {
    payload[EncodableValue("total_frames")] =
        EncodableValue(static_cast<int64_t>(total));
  }
  if (!message.empty()) payload[EncodableValue("message")] = EncodableValue(message);
  if (!error.empty()) payload[EncodableValue("error")] = EncodableValue(error);
  Emit(payload);
}

std::optional<EncodableMap> FfmpegPipeline::Probe(const std::string& path,
                                                  std::string* error) {
  std::wstring command = Quote(ToolPath("ffprobe"));
  command += L" -v quiet -print_format json -show_format -show_streams ";
  command += Quote(Utf8ToWide(path));
  CaptureResult captured = RunCapture(command);
  if (!captured.ok) {
    *error = captured.error.empty() ? "ffprobe 실행 실패" : captured.error;
    return std::nullopt;
  }

  json parsed;
  try {
    parsed = json::parse(captured.output);
  } catch (const std::exception& exception) {
    *error = std::string("ffprobe JSON 해석 실패: ") + exception.what();
    return std::nullopt;
  }

  EncodableMap result;
  result[EncodableValue("path")] = EncodableValue(path);
  result[EncodableValue("source")] = EncodableValue("ffprobe");

  int64_t duration_ms = 0;
  if (parsed.contains("format")) {
    duration_ms = static_cast<int64_t>(
        std::llround(JsonDouble(parsed["format"], "duration", 0.0) * 1000.0));
    std::string container = JsonString(parsed["format"], "format_name");
    if (!container.empty()) {
      result[EncodableValue("container")] = EncodableValue(container);
    }
  }

  bool has_video = false;
  bool has_audio = false;
  if (parsed.contains("streams") && parsed["streams"].is_array()) {
    for (const auto& stream : parsed["streams"]) {
      const std::string type = JsonString(stream, "codec_type");
      if (type == "video" && !has_video) {
        has_video = true;
        int width = static_cast<int>(JsonInt(stream, "width", 0));
        int height = static_cast<int>(JsonInt(stream, "height", 0));
        int rotation = 0;
        if (stream.contains("side_data_list") && stream["side_data_list"].is_array()) {
          for (const auto& side : stream["side_data_list"]) {
            rotation = static_cast<int>(JsonInt(side, "rotation", rotation));
          }
        }
        if (stream.contains("tags") && stream["tags"].is_object()) {
          rotation = static_cast<int>(
              JsonInt(stream["tags"], "rotate", rotation));
        }
        if (std::abs(rotation) % 180 == 90) {
          std::swap(width, height);
        }
        result[EncodableValue("width")] = EncodableValue(width);
        result[EncodableValue("height")] = EncodableValue(height);
        result[EncodableValue("fps")] = EncodableValue(ParseFrameRate(
            JsonString(stream, "avg_frame_rate", "0/1")));
        const std::string codec = JsonString(stream, "codec_name");
        if (!codec.empty()) {
          result[EncodableValue("video_codec")] = EncodableValue(codec);
        }
        result[EncodableValue("rotation_degrees")] = EncodableValue(rotation);
        if (duration_ms == 0) {
          duration_ms = static_cast<int64_t>(
              std::llround(JsonDouble(stream, "duration", 0.0) * 1000.0));
        }
      } else if (type == "audio" && !has_audio) {
        has_audio = true;
        result[EncodableValue("audio_channels")] =
            EncodableValue(JsonInt(stream, "channels", 2));
        result[EncodableValue("audio_sample_rate")] =
            EncodableValue(JsonInt(stream, "sample_rate", 48000));
        const std::string codec = JsonString(stream, "codec_name");
        if (!codec.empty()) {
          result[EncodableValue("audio_codec")] = EncodableValue(codec);
        }
      }
    }
  }

  result[EncodableValue("has_video")] = EncodableValue(has_video);
  result[EncodableValue("has_audio")] = EncodableValue(has_audio);
  result[EncodableValue("duration_ms")] = EncodableValue(duration_ms);
  result[EncodableValue("probed_at_ms")] =
      EncodableValue(static_cast<int64_t>(
          std::chrono::duration_cast<std::chrono::milliseconds>(
              std::chrono::system_clock::now().time_since_epoch())
              .count()));
  return result;
}

bool FfmpegPipeline::StartExport(const std::string& graph_json,
                                 const std::string& output_path,
                                 std::string* error) {
  if (running_.load()) {
    *error = "이미 내보내기가 진행 중입니다";
    return false;
  }
  json parsed;
  try {
    parsed = json::parse(graph_json);
  } catch (const std::exception& exception) {
    *error = std::string("렌더 그래프 JSON 해석 실패: ") + exception.what();
    return false;
  }
  if (JsonBool(parsed, "watermark", false)) {
    *error = "워터마크가 있는 그래프는 렌더하지 않습니다";
    return false;
  }

  running_.store(true);
  cancel_requested_.store(false);
  if (worker_.joinable()) {
    worker_.join();
  }
  worker_ = std::thread(&FfmpegPipeline::RunExport, this, graph_json, output_path);
  return true;
}

bool FfmpegPipeline::Cancel() {
  if (!running_.load()) return false;
  cancel_requested_.store(true);
  std::lock_guard<std::mutex> guard(process_mutex_);
  if (process_handle_ != nullptr) {
    TerminateProcess(static_cast<HANDLE>(process_handle_), 1);
  }
  return true;
}

void FfmpegPipeline::RunExport(std::string graph_json, std::string output_path) {
  const json graph = json::parse(graph_json, nullptr, false);
  if (graph.is_discarded()) {
    EmitState("failed", "failed", -1, -1, "렌더 그래프를 해석하지 못했습니다",
              "렌더 그래프를 해석하지 못했습니다");
    running_.store(false);
    return;
  }

  const int64_t frame_count = JsonInt(graph, "frame_count", 0);
  const int fps = static_cast<int>(std::max<int64_t>(1, JsonInt(graph, "fps", 30)));
  int out_width = 1080;
  int out_height = 1920;
  if (graph.contains("resolution") && graph["resolution"].is_object()) {
    out_width = static_cast<int>(JsonInt(graph["resolution"], "width", 1080));
    out_height = static_cast<int>(JsonInt(graph["resolution"], "height", 1920));
  }

  EmitState("stage", "preparing", -1, frame_count, "ffmpeg 파이프라인 준비");

  // ---- 입력 파일 목록과 인자 -------------------------------------------------
  std::vector<std::string> inputs;
  std::map<std::string, int> input_index;
  auto add_input = [&](const std::string& path) {
    auto found = input_index.find(path);
    if (found != input_index.end()) return found->second;
    int index = static_cast<int>(inputs.size());
    inputs.push_back(path);
    input_index[path] = index;
    return index;
  };

  const json& segments = graph.contains("segments") && graph["segments"].is_array()
                             ? graph["segments"]
                             : json::array();
  const json& audio_segments =
      graph.contains("audio_segments") && graph["audio_segments"].is_array()
          ? graph["audio_segments"]
          : json::array();

  // v1: 가장 아래 비디오 레이어만 순차 concat한다(다중 레이어는 후속).
  int base_layer = -1;
  for (const auto& segment : segments) {
    if (JsonString(segment, "kind") == "video") {
      int layer = static_cast<int>(JsonInt(segment, "layer", 0));
      if (base_layer < 0 || layer < base_layer) base_layer = layer;
    }
  }

  std::ostringstream filters;
  std::vector<std::string> video_labels;
  int segment_number = 0;
  for (const auto& segment : segments) {
    if (JsonString(segment, "kind") != "video") continue;
    if (static_cast<int>(JsonInt(segment, "layer", 0)) != base_layer) continue;
    const std::string path = JsonString(segment, "source_path");
    if (path.empty()) continue;
    int index = add_input(path);

    int64_t in_ms = JsonInt(segment, "source_in_ms", 0);
    int64_t out_ms = JsonInt(segment, "source_out_ms", 0);
    int64_t render_ms = JsonInt(segment, "render_end_ms", 0) -
                        JsonInt(segment, "render_start_ms", 0);
    double speed = JsonDouble(segment, "speed", 1.0);
    if (speed <= 0) speed = 1.0;

    std::ostringstream chain;
    chain << "[" << index << ":v]trim=start=" << FormatSeconds(in_ms)
          << ":end=" << FormatSeconds(out_ms) << ",setpts=(PTS-STARTPTS)/"
          << speed;
    // 배속이 바뀌면 출력 길이도 바뀐다. concat 전에 다시 맞춰 준다.
    if (render_ms > 0) {
      chain << ",setpts=PTS*(" << FormatSeconds(render_ms) << "/"
            << FormatSeconds(std::max<int64_t>(1, out_ms - in_ms)) << ")";
    }
    chain << ",scale=" << out_width << ":" << out_height
          << ":force_original_aspect_ratio=decrease,"
          << "pad=" << out_width << ":" << out_height
          << ":(ow-iw)/2:(oh-ih)/2:black,setsar=1";
    const int64_t fade_in = JsonInt(segment, "fade_in_ms", 0);
    const int64_t fade_out = JsonInt(segment, "fade_out_ms", 0);
    if (fade_in > 0) {
      chain << ",fade=t=in:st=0:d=" << FormatSeconds(fade_in);
    }
    if (fade_out > 0) {
      chain << ",fade=t=out:st=" << FormatSeconds(std::max<int64_t>(0, render_ms - fade_out))
            << ":d=" << FormatSeconds(fade_out);
    }
    std::string label = "v" + std::to_string(segment_number++);
    filters << chain.str() << "[" << label << "];";
    video_labels.push_back(label);
  }

  if (video_labels.empty()) {
    EmitState("failed", "failed", -1, frame_count, "렌더할 영상 세그먼트가 없습니다",
              "렌더할 영상 세그먼트가 없습니다");
    running_.store(false);
    return;
  }

  std::string video_out = "vout";
  filters << "[";
  for (size_t i = 0; i < video_labels.size(); ++i) {
    if (i > 0) filters << "]";
    filters << video_labels[i];
    if (i + 1 < video_labels.size()) filters << "[";
  }
  filters << "]concat=n=" << video_labels.size() << ":v=1:a=0[" << video_out << "];";

  // 오디오: 겹치지 않으면 concat, 겹치면 amix.
  std::vector<std::string> audio_labels;
  bool audio_overlap = false;
  int64_t last_end = -1;
  for (const auto& segment : audio_segments) {
    if (JsonBool(segment, "muted", false)) continue;
    const std::string path = JsonString(segment, "source_path");
    if (path.empty()) continue;
    int index = add_input(path);
    int64_t start = JsonInt(segment, "render_start_ms", 0);
    if (last_end >= 0 && start < last_end) audio_overlap = true;
    last_end = std::max(last_end, JsonInt(segment, "render_end_ms", 0));

    double speed = JsonDouble(segment, "speed", 1.0);
    double gain = JsonDouble(segment, "gain", 1.0);
    int64_t in_ms = JsonInt(segment, "source_in_ms", 0);
    int64_t out_ms = JsonInt(segment, "source_out_ms", 0);
    std::ostringstream chain;
    chain << "[" << index << ":a]atrim=start=" << FormatSeconds(in_ms)
          << ":end=" << FormatSeconds(out_ms) << ",asetpts=PTS-STARTPTS";
    if (speed > 0 && std::abs(speed - 1.0) > 0.01) {
      chain << ",atempo=" << speed;
    }
    chain << ",volume=" << gain;
    // 게인 커브의 첫/끝점으로 페이드 근사.
    const auto& curve =
        segment.contains("gain_curve") && segment["gain_curve"].is_array()
            ? segment["gain_curve"]
            : json::array();
    if (curve.size() >= 2) {
      double first = JsonDouble(curve.front(), "value", gain);
      double last = JsonDouble(curve.back(), "value", gain);
      int64_t duration = JsonInt(segment, "render_end_ms", 0) - start;
      if (first < 0.01 && duration > 0) {
        chain << ",afade=t=in:st=0:d=" << FormatSeconds(std::min<int64_t>(duration, 1000));
      }
      if (last < 0.01 && duration > 0) {
        chain << ",afade=t=out:st=" << FormatSeconds(std::max<int64_t>(0, duration - 1000))
              << ":d=" << FormatSeconds(std::min<int64_t>(duration, 1000));
      }
    }
    std::string label = "a" + std::to_string(audio_labels.size());
    filters << chain.str() << "[" << label << "];";
    audio_labels.push_back(label);
  }

  std::string audio_out;
  if (!audio_labels.empty()) {
    audio_out = "aout";
    if (audio_overlap) {
      filters << "[";
      for (size_t i = 0; i < audio_labels.size(); ++i) {
        filters << audio_labels[i];
        if (i + 1 < audio_labels.size()) filters << "[";
      }
      filters << "]amix=inputs=" << audio_labels.size()
              << ":duration=longest:normalize=0[" << audio_out << "];";
    } else {
      filters << "[";
      for (size_t i = 0; i < audio_labels.size(); ++i) {
        filters << audio_labels[i];
        if (i + 1 < audio_labels.size()) filters << "[";
      }
      filters << "]concat=n=" << audio_labels.size() << ":v=0:a=1[" << audio_out
              << "];";
    }
  }

  // 자막 번인: 그래프의 자막을 SRT로 쓰고 subtitles 필터로 굽는다.
  std::string final_video = video_out;
  std::string temp_srt;
  if (graph.contains("subtitles") && JsonBool(graph["subtitles"], "enabled", false) &&
      graph["subtitles"].contains("items") &&
      graph["subtitles"]["items"].is_array() &&
      !graph["subtitles"]["items"].empty()) {
    std::string srt_error;
    temp_srt = WriteSrt(graph["subtitles"], &srt_error);
    if (!temp_srt.empty()) {
      final_video = "vsub";
      filters << "[" << video_out << "]subtitles="
              << EscapeFilterPath(temp_srt) << "[" << final_video << "];";
    } else {
      EmitState("progress", "rendering", 0, frame_count,
                "자막 파일을 쓰지 못해 자막 없이 내보냅니다: " + srt_error);
    }
  }

  std::string filter_complex = filters.str();
  if (!filter_complex.empty() && filter_complex.back() == ';') {
    filter_complex.pop_back();
  }

  // ---- ffmpeg 명령 -----------------------------------------------------------
  std::wstring command = Quote(ToolPath("ffmpeg"));
  command += L" -hide_banner -y -nostdin";
  for (const auto& input : inputs) {
    command += L" -i " + Quote(Utf8ToWide(input));
  }
  command += L" -filter_complex " + Quote(Utf8ToWide(filter_complex));
  command += L" -map ";
  command += Quote(Utf8ToWide("[" + final_video + "]"));
  if (!audio_out.empty()) {
    command += L" -map ";
    command += Quote(Utf8ToWide("[" + audio_out + "]"));
  }

  const std::string encoder = graph.contains("encoder") && graph["encoder"].is_object()
                                  ? JsonString(graph["encoder"], "name", "h264_mf")
                                  : "h264_mf";
  int64_t bitrate = JsonInt(graph, "video_bitrate_kbps", 8000);
  int64_t gop = JsonInt(graph, "gop_frames", fps * 2);
  const std::string container = JsonString(graph, "container", "mp4");

  command += L" -c:v " + Quote(Utf8ToWide(encoder));
  command += L" -b:v " + Utf8ToWide(std::to_string(bitrate) + "k");
  command += L" -r " + Utf8ToWide(std::to_string(fps));
  command += L" -g " + Utf8ToWide(std::to_string(gop));
  command += L" -pix_fmt yuv420p";
  if (!audio_out.empty()) {
    command += L" -c:a aac -b:a 192k -ar 48000";
  }
  if (container == "mp4") {
    command += L" -movflags +faststart";
  }
  command += L" -progress pipe:1 -nostats -loglevel error ";
  command += Quote(Utf8ToWide(output_path));

  // ---- 실행 ------------------------------------------------------------------
  SECURITY_ATTRIBUTES attributes{};
  attributes.nLength = sizeof(attributes);
  attributes.bInheritHandle = TRUE;
  HANDLE stdout_read = nullptr;
  HANDLE stdout_write = nullptr;
  if (!CreatePipe(&stdout_read, &stdout_write, &attributes, 0)) {
    EmitState("failed", "failed", -1, frame_count, "파이프를 만들지 못했습니다",
              "파이프를 만들지 못했습니다");
    running_.store(false);
    return;
  }
  SetHandleInformation(stdout_read, HANDLE_FLAG_INHERIT, 0);

  STARTUPINFOW startup{};
  startup.cb = sizeof(startup);
  startup.dwFlags = STARTF_USESTDHANDLES | STARTF_USESHOWWINDOW;
  startup.wShowWindow = SW_HIDE;
  startup.hStdOutput = stdout_write;
  startup.hStdError = stdout_write;
  startup.hStdInput = GetStdHandle(STD_INPUT_HANDLE);

  PROCESS_INFORMATION process{};
  std::wstring mutable_command = command;
  BOOL created = CreateProcessW(nullptr, mutable_command.data(), nullptr, nullptr,
                                TRUE, CREATE_NO_WINDOW, nullptr, nullptr, &startup,
                                &process);
  CloseHandle(stdout_write);
  if (!created) {
    CloseHandle(stdout_read);
    EmitState("failed", "failed", -1, frame_count,
              "ffmpeg를 시작하지 못했습니다(ffmpeg.exe 경로 확인)",
              "ffmpeg를 시작하지 못했습니다");
    running_.store(false);
    return;
  }

  {
    std::lock_guard<std::mutex> guard(process_mutex_);
    process_handle_ = process.hProcess;
  }
  EmitState("stage", "rendering", 0, frame_count, "ffmpeg 인코딩 중");

  std::string tail;  // 에러 메시지용 마지막 로그
  char buffer[4096];
  DWORD read = 0;
  std::string pending;
  int64_t last_frame = -1;
  while (ReadFile(stdout_read, buffer, sizeof(buffer), &read, nullptr) && read > 0) {
    tail.append(buffer, read);
    if (tail.size() > 4000) tail = tail.substr(tail.size() - 4000);
    pending.append(buffer, read);
    size_t newline;
    while ((newline = pending.find('\n')) != std::string::npos) {
      std::string line = pending.substr(0, newline);
      pending.erase(0, newline + 1);
      if (line.rfind("frame=", 0) == 0) {
        try {
          int64_t frame = std::stoll(line.substr(6));
          if (frame != last_frame) {
            last_frame = frame;
            EmitState("progress", "rendering", frame, frame_count);
          }
        } catch (...) {
        }
      }
    }
  }

  WaitForSingleObject(process.hProcess, INFINITE);
  DWORD exit_code = 1;
  GetExitCodeProcess(process.hProcess, &exit_code);
  {
    std::lock_guard<std::mutex> guard(process_mutex_);
    process_handle_ = nullptr;
  }
  CloseHandle(process.hProcess);
  CloseHandle(process.hThread);
  CloseHandle(stdout_read);
  running_.store(false);

  if (!temp_srt.empty()) {
    std::wstring wide = Utf8ToWide(temp_srt);
    DeleteFileW(wide.c_str());
  }

  if (cancel_requested_.load()) {
    DeleteFileW(Utf8ToWide(output_path).c_str());
    EmitState("canceled", "canceled", last_frame, frame_count, "취소됨");
    return;
  }
  if (exit_code != 0) {
    EmitState("failed", "failed", last_frame, frame_count, tail,
              tail.empty() ? "ffmpeg가 실패했습니다" : tail);
    return;
  }
  EmitState("completed", "completed", frame_count, frame_count, output_path);
}

}  // namespace muud

// ================================================================== plugin

class MuudMediaPlugin::EventStreamHandler
    : public flutter::StreamHandler<flutter::EncodableValue> {
 public:
  explicit EventStreamHandler(MuudMediaPlugin* owner) : owner_(owner) {}

 protected:
  std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>>
  OnListenInternal(
      const flutter::EncodableValue* arguments,
      std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&& events)
      override {
    owner_->sink_ = std::move(events);
    return nullptr;
  }

  std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>>
  OnCancelInternal(const flutter::EncodableValue* arguments) override {
    owner_->sink_ = nullptr;
    return nullptr;
  }

 private:
  MuudMediaPlugin* owner_;
};

void MuudMediaPlugin::RegisterWithRegistrar(flutter::PluginRegistry* registry) {
  if (registry == nullptr) {
    return;
  }
  RegisterWithRegistrar(registry->GetRegistrarForPlugin("MuudMedia"));
}

void MuudMediaPlugin::RegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef raw_registrar) {
  auto* registrar = flutter::PluginRegistrarManager::GetInstance()
                        ->GetRegistrar<flutter::PluginRegistrarWindows>(
                            raw_registrar);
  if (registrar == nullptr) {
    return;
  }
  RegisterWithRegistrar(registrar);
}

void MuudMediaPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  auto plugin = std::make_unique<MuudMediaPlugin>();
  plugin->registrar_ = registrar;

  auto methods = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      registrar->messenger(), "muud_edits/media",
      &flutter::StandardMethodCodec::GetInstance());
  methods->SetMethodCallHandler(
      [plugin = plugin.get()](const flutter::MethodCall<flutter::EncodableValue>& call,
                              std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                                  result) { plugin->HandleMethodCall(call, std::move(result)); });

  auto events = std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
      registrar->messenger(), "muud_edits/export_progress",
      &flutter::StandardMethodCodec::GetInstance());
  events->SetStreamHandler(std::make_unique<EventStreamHandler>(plugin.get()));

  // 반드시 registrar가 살아 있는 동안 등록한다.
  plugin->window_proc_id_ = registrar->RegisterTopLevelWindowProcDelegate(
      [plugin = plugin.get()](HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
        return plugin->OnWindowProc(hwnd, message, wparam, lparam);
      });

  registrar->AddPlugin(std::move(plugin));
}

MuudMediaPlugin::MuudMediaPlugin() {
  pipeline_.set_event_callback([this](const EncodableMap& payload) {
    OnEvent(payload);
  });
}

MuudMediaPlugin::~MuudMediaPlugin() {
  pipeline_.Cancel();
  if (registrar_ != nullptr && window_proc_id_ >= 0) {
    registrar_->UnregisterTopLevelWindowProcDelegate(window_proc_id_);
  }
  sink_ = nullptr;
}

void MuudMediaPlugin::OnEvent(const EncodableMap& payload) {
  {
    std::lock_guard<std::mutex> guard(pending_mutex_);
    pending_.push_back(payload);
    has_pending_.store(true);
  }
  if (hwnd_ == nullptr) {
    // 아직 창 핸들을 못 얻었으면 다음 메서드 호출 때 flush된다.
    return;
  }
  PostMessage(hwnd_, muud::kMuudEventMessage, 0, 0);
}

void MuudMediaPlugin::FlushPendingEvents() {
  std::vector<EncodableMap> pending;
  {
    std::lock_guard<std::mutex> guard(pending_mutex_);
    pending.swap(pending_);
  }
  has_pending_.store(false);
  if (sink_ == nullptr) return;
  for (const auto& payload : pending) {
    sink_->Success(flutter::EncodableValue(payload));
  }
}

std::optional<LRESULT> MuudMediaPlugin::OnWindowProc(HWND hwnd, UINT message,
                                                     WPARAM wparam, LPARAM lparam) {
  hwnd_ = hwnd;
  if (message == muud::kMuudEventMessage) {
    FlushPendingEvents();
    return 0;
  }
  // 창 핸들을 얻기 전에 쌓인 이벤트가 있으면 첫 메시지에서 보낸다.
  if (has_pending_.load()) {
    FlushPendingEvents();
  }
  return std::nullopt;
}

void MuudMediaPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const auto* arguments = std::get_if<flutter::EncodableMap>(method_call.arguments());

  auto string_arg = [&](const char* key) -> std::string {
    if (arguments == nullptr) return std::string();
    auto found = arguments->find(flutter::EncodableValue(key));
    if (found == arguments->end()) return std::string();
    if (const auto* value = std::get_if<std::string>(&found->second)) return *value;
    return std::string();
  };

  if (method_call.method_name() == "probe") {
    std::string path = string_arg("path");
    if (path.empty()) {
      result->Error("bad_arguments", "path가 필요합니다");
      return;
    }
    std::string error;
    auto info = pipeline_.Probe(path, &error);
    if (!info.has_value()) {
      result->Error("probe_failed", error.empty() ? "미디어 정보를 읽지 못했습니다" : error);
      return;
    }
    result->Success(flutter::EncodableValue(*info));
    return;
  }

  if (method_call.method_name() == "startExport") {
    std::string graph = string_arg("graphJson");
    std::string output = string_arg("outputPath");
    if (graph.empty() || output.empty()) {
      result->Error("bad_arguments", "graphJson/outputPath가 필요합니다");
      return;
    }
    std::string error;
    if (!pipeline_.StartExport(graph, output, &error)) {
      result->Error("export_start_failed", error);
      return;
    }
    result->Success();
    return;
  }

  if (method_call.method_name() == "cancelExport") {
    result->Success(flutter::EncodableValue(pipeline_.Cancel()));
    return;
  }

  if (method_call.method_name() == "thumbnail") {
    // v1: 썸네일은 Flutter가 첫 프레임을 미리보기로 쓰지 않으므로 생략한다.
    result->Success();
    return;
  }

  if (method_call.method_name() == "platformInfo") {
    flutter::EncodableMap info;
    info[flutter::EncodableValue("api")] =
        flutter::EncodableValue("FFmpeg process pipeline");
    info[flutter::EncodableValue("engine")] =
        flutter::EncodableValue(muud::GetEnvOr("MUUD_FFMPEG_ENGINE", "ffmpeg"));
    info[flutter::EncodableValue("supports_export")] = flutter::EncodableValue(true);
    info[flutter::EncodableValue("supports_text_burn_in")] =
        flutter::EncodableValue(true);
    info[flutter::EncodableValue("platform")] = flutter::EncodableValue("windows");
    result->Success(flutter::EncodableValue(info));
    return;
  }

  result->NotImplemented();
}
