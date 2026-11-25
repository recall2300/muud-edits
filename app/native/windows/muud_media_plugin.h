// muud_media_plugin.h
// muud-edits — Windows 미디어 채널 (Flutter Windows embedder, C++17)
//
// 계약은 macOS/iOS/Android와 같다.
//   MethodChannel  "muud_edits/media"           : probe / startExport / cancelExport / thumbnail / platformInfo
//   EventChannel   "muud_edits/export_progress" : {event, state, completed_frames, total_frames, message, error}
//
// 인코딩 경로는 두 가지를 모두 열어 둔다.
//   1) ffmpeg/ffprobe 프로세스 파이프라인 (이 파일, 기본값)
//   2) Media Foundation (후속: MF Sink Writer로 같은 그래프를 소비)
// v1은 ffmpeg 경로를 구현한다. `ffmpeg.exe`/`ffprobe.exe`를 앱 옆에 배포하거나
// PATH에 두면 된다(LOCAL_SETUP.md 참고).

#pragma once

#include <windows.h>

#include <flutter/encodable_value.h>
#include <flutter/event_channel.h>
#include <flutter/method_channel.h>
#include <flutter/method_result.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/plugin_registry.h>

#include <atomic>
#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <vector>

namespace muud {

using EncodableMap = flutter::EncodableMap;
using EncodableValue = flutter::EncodableValue;

/// ffmpeg/ffprobe 실행 + 렌더 그래프 → 인자 변환.
class FfmpegPipeline {
 public:
  using EventCallback = std::function<void(const EncodableMap&)>;

  FfmpegPipeline();
  ~FfmpegPipeline();

  void set_event_callback(EventCallback callback) { on_event_ = std::move(callback); }

  /// ffprobe JSON을 `MediaProbeInfo` 키로 변환해 돌려준다.
  std::optional<EncodableMap> Probe(const std::string& path, std::string* error);

  /// 그래프를 실행한다. 이벤트는 콜백으로(워커 스레드에서) 나간다.
  bool StartExport(const std::string& graph_json, const std::string& output_path,
                   std::string* error);

  /// 취소 요청. 프로세스를 종료하고 `canceled` 이벤트를 보낸다.
  bool Cancel();

  bool running() const { return running_.load(); }

 private:
  void RunExport(std::string graph_json, std::string output_path);
  void Emit(const EncodableMap& payload);
  void EmitState(const std::string& event, const std::string& state,
                 int64_t completed = -1, int64_t total = -1,
                 const std::string& message = std::string(),
                 const std::string& error = std::string());

  EventCallback on_event_;
  std::thread worker_;
  std::atomic<bool> running_{false};
  std::atomic<bool> cancel_requested_{false};
  mutable std::mutex process_mutex_;
  void* process_handle_ = nullptr;  // HANDLE
};

}  // namespace muud

/// Flutter Windows 플러그인 진입점.
///
/// 등록(`flutter_window.cpp` 또는 앱 플러그인 목록):
/// ```cpp
/// MuudMediaPlugin::RegisterWithRegistrar(registrar);
/// ```
class MuudMediaPlugin : public flutter::Plugin {
 public:
  /// `RegisterPlugins(flutter_controller_->engine())`와 같은 방식으로 등록할 때.
  static void RegisterWithRegistrar(flutter::PluginRegistry* registry);

  /// `generated_plugin_registrant`처럼 raw registrar를 받았을 때.
  static void RegisterWithRegistrar(FlutterDesktopPluginRegistrarRef registrar);

  /// 이미 얻은 Windows registrar로 직접 등록할 때.
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  MuudMediaPlugin();
  ~MuudMediaPlugin() override;

  // Flutter 3.50의 flutter::Plugin 은 빈 베이스 클래스라 HandleMethodCall 을
  // override 하지 않는다(채널 핸들러 람다에서 직접 호출한다).
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

 private:
  class EventStreamHandler;

  void FlushPendingEvents();
  void OnEvent(const flutter::EncodableMap& payload);
  std::optional<LRESULT> OnWindowProc(HWND hwnd, UINT message, WPARAM wparam,
                                      LPARAM lparam);

  muud::FfmpegPipeline pipeline_;
  flutter::PluginRegistrarWindows* registrar_ = nullptr;
  HWND hwnd_ = nullptr;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> sink_;
  std::mutex pending_mutex_;
  std::vector<flutter::EncodableMap> pending_;
  std::atomic<bool> has_pending_{false};
  int window_proc_id_ = -1;
};
