// ⚠️ 임시 스텁 — `flutter_rust_bridge_codegen generate`가 실제 바인딩으로 덮어쓴다.
//
// 목적: 코드 생성 전에도 `flutter analyze`/`flutter run`이 실패하지 않게 한다.
// 호출하면 UnimplementedError를 던지므로, 앱은 "브리지 미생성" 안내를 띄운다.
//
// 실제 시그니처는 rust_core/src/bridge.rs의 함수와 1:1 대응한다.

Future<String> coreVersion() async => throw _notGenerated();

Future<String> createProject({
  required String name,
  required int width,
  required int height,
  required int fps,
}) async =>
    throw _notGenerated();

Future<String> applyCommand({
  required String stateJson,
  required String commandJson,
}) async =>
    throw _notGenerated();

Future<String> addMediaClip({
  required String stateJson,
  required String trackId,
  required String kind,
  required String sourcePath,
  required int startMs,
  required int endMs,
  int? atMs,
  int? sourceDurationMs,
}) async =>
    throw _notGenerated();

Future<String> addTextClip({
  required String stateJson,
  required String trackId,
  required String content,
  required int durationMs,
  required int atMs,
  double? sizePx,
}) async =>
    throw _notGenerated();

Future<String> addSubtitle({
  required String stateJson,
  int? startMs,
  int? endMs,
  required String text,
}) async =>
    throw _notGenerated();

Future<String> splitClip({
  required String stateJson,
  required String trackId,
  required String clipId,
  required int atTimelineMs,
}) async =>
    throw _notGenerated();

Future<String> undo({required String stateJson}) async => throw _notGenerated();

Future<String> redo({required String stateJson}) async => throw _notGenerated();

Future<String> projectSummary({required String stateJson}) async =>
    throw _notGenerated();

Future<String> exportPlan({
  required String stateJson,
  required String settingsJson,
  required String platformId,
}) async =>
    throw _notGenerated();

Future<String> renderGraph({
  required String stateJson,
  required String settingsJson,
  required String platformId,
}) async =>
    throw _notGenerated();

Future<String> probeMediaInfo({required String probeJson}) async =>
    throw _notGenerated();

Future<String> exportJobCreate({
  required String jobId,
  required int totalFrames,
  int? atMs,
}) async =>
    throw _notGenerated();

Future<String> exportJobEvent({
  required String jobJson,
  required String eventJson,
}) async =>
    throw _notGenerated();

Future<String> exportJobCancel({
  required String jobJson,
  int? atMs,
}) async =>
    throw _notGenerated();

Future<String> saveProject({
  required String stateJson,
  required String path,
}) async =>
    throw _notGenerated();

Future<String> loadProject({required String path}) async => throw _notGenerated();

Future<String> saveSubtitlesSrt({
  required String stateJson,
  required String path,
}) async =>
    throw _notGenerated();

Future<String> platformCapabilities({required String platformId}) async =>
    throw _notGenerated();

Future<String> projectJson({required String stateJson}) async =>
    throw _notGenerated();

Future<String> trackKinds() async => throw _notGenerated();

UnimplementedError _notGenerated() =>
    UnimplementedError('flutter_rust_bridge_codegen generate 를 먼저 실행하세요');
