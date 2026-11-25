import 'dart:io' show File, Platform;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;

import 'src/rust/frb_generated.dart';

/// Rust 코어(`libmuud_core.so` / `muud_core.dll` / `libmuud_core.dylib`)를
/// 찾아 로드한다.
///
/// ## 왜 플랫폼별로 경로를 직접 정하는가
/// flutter_rust_bridge의 기본 로더는 `Directory.current` 기준 경로만 시도하고,
/// macOS 처럼 `.app` 번들 안에 넣은 라이브러리는 찾지 못한다. 그래서
/// "이 플랫폼에서 라이브러리가 실제로 놓이는 자리"를 여기서 명시한다.
///
/// | 플랫폼 | 라이브러리 | 놓이는 자리 |
/// |---|---|---|
/// | Android | `libmuud_core.so` | APK `lib/<abi>/` (jniLibs) |
/// | Windows | `muud_core.dll` | 실행 파일 옆 |
/// | macOS | `libmuud_core.dylib` | `<App>.app/Contents/Frameworks/` |
/// | iOS | (정적 링크) | Runner 실행 파일 안 → `ExternalLibrary.process()` |
///
/// 로드에 실패하면 [RustCoreLoadResult.error]에 사용자에게 보여 줄 문구가 담긴다.
class RustCoreLoadResult {
  const RustCoreLoadResult({this.library, this.error, this.loadedFrom});

  final ExternalLibrary? library;
  final String? error;
  final String? loadedFrom;

  bool get ok => error == null;

  static const RustCoreLoadResult failure = RustCoreLoadResult(
    error: 'Rust 코어를 불러오지 못했습니다',
  );
}

/// 코어 로딩 결과(앱 시작 시 한 번 채워진다).
RustCoreLoadResult rustCore = RustCoreLoadResult.failure;

/// 라이브러리 파일 이름. 코어 크레이트의 `[lib] name = "muud_core"`와 같아야 한다.
const String kCoreLibraryStem = 'muud_core';

/// `RustLib.init()`까지 마친 코어 로딩. 예외를 던지지 않는다.
///
/// 여러 번 불러도 안전하다(이미 성공했으면 그 결과를 그대로 돌려준다).
Future<RustCoreLoadResult> loadRustCore() async {
  if (rustCore.ok) {
    return rustCore;
  }
  final ExternalLibrary? library;
  final String? loadedFrom;
  try {
    final ({ExternalLibrary library, String from})? resolved =
        _resolveExternalLibrary();
    library = resolved?.library;
    loadedFrom = resolved?.from;
    await RustLib.init(externalLibrary: library);
    rustCore = RustCoreLoadResult(
      library: library,
      loadedFrom: loadedFrom ?? '기본 로더',
    );
    debugPrint('muud: Rust 코어 로드 완료 ($loadedFrom)');
    return rustCore;
  } on Object catch (error, stackTrace) {
    debugPrint('muud: Rust 코어 로드 실패 — $error\n$stackTrace');
    rustCore = RustCoreLoadResult(error: _describeFailure(error));
    return rustCore;
  }
}

String _describeFailure(Object error) {
  final String detail = '$error';
  if (detail.contains("Couldn't resolve native function") ||
      detail.contains('Failed to load dynamic library') ||
      detail.contains('not found')) {
    return 'Rust 코어 라이브러리(${_libraryFileName})를 찾지 못했습니다.\n'
        '앱을 다시 설치하거나, 빌드에 libmuud_core 가 포함됐는지 확인해 주세요.\n\n'
        '$detail';
  }
  return 'Rust 코어를 불러오지 못했습니다.\n\n$detail';
}

String get _libraryFileName {
  if (Platform.isAndroid) {
    return 'lib$kCoreLibraryStem.so';
  }
  if (Platform.isWindows) {
    return '$kCoreLibraryStem.dll';
  }
  if (Platform.isMacOS) {
    return 'lib$kCoreLibraryStem.dylib';
  }
  if (Platform.isIOS) {
    return '$kCoreLibraryStem (정적 링크)';
  }
  return 'lib$kCoreLibraryStem.so';
}

/// 플랫폼별 라이브러리 위치. 확실한 경로가 없으면 null(기본 로더 사용).
({ExternalLibrary library, String from})? _resolveExternalLibrary() {
  // Android: DynamicLibrary.open('libmuud_core.so')가 APK의 nativeLibraryDir를
  // 찾는다. jniLibs에 넣은 .so가 그대로 로드된다.
  if (Platform.isAndroid) {
    return (
      library: ExternalLibrary.open('lib$kCoreLibraryStem.so'),
      from: 'Android jniLibs',
    );
  }

  // iOS: 정적 라이브러리로 Runner 실행 파일에 링크되므로 프로세스에서 심볼을 찾는다.
  if (Platform.isIOS) {
    return (
      library: ExternalLibrary.process(iKnowHowToUseIt: true),
      from: 'iOS 정적 링크(process)',
    );
  }

  // 데스크톱/개발 환경: 존재하는 첫 경로를 쓴다.
  for (final String candidate in _candidatePaths()) {
    if (File(candidate).existsSync()) {
      return (library: ExternalLibrary.open(candidate), from: candidate);
    }
  }
  return null;
}

/// 실행 파일 위치를 기준으로 한 후보 경로들(먼저 오는 것이 우선).
Iterable<String> _candidatePaths() sync* {
  final String exe = Platform.resolvedExecutable;
  final String exeDir = exe.substring(
    0,
    exe.lastIndexOf(Platform.pathSeparator),
  );

  if (Platform.isMacOS) {
    // <App>.app/Contents/MacOS/<exe> → <App>.app/Contents/Frameworks/
    yield '$exeDir/../Frameworks/lib$kCoreLibraryStem.dylib';
    yield '$exeDir/lib$kCoreLibraryStem.dylib';
  } else if (Platform.isWindows) {
    yield '$exeDir\\$kCoreLibraryStem.dll';
    yield '$exeDir\\lib\\$kCoreLibraryStem.dll';
  } else {
    yield '$exeDir/lib$kCoreLibraryStem.so';
    yield '$exeDir/lib/lib$kCoreLibraryStem.so';
  }

  // `flutter run` / 개발 빌드: app/ 에서 실행하면 코어의 cargo 산출물을 쓴다.
  yield '../rust_core/target/release/lib$kCoreLibraryStem.so';
  yield '../rust_core/target/debug/lib$kCoreLibraryStem.so';
  yield '../rust_core/target/release/lib$kCoreLibraryStem.dylib';
  yield '../rust_core/target/release/$kCoreLibraryStem.dll';
}
