import 'package:flutter/material.dart';

import 'editor/editor_screen.dart';
import 'theme.dart';

void main() {
  runApp(const MuudEditsApp());
}

class MuudEditsApp extends StatelessWidget {
  const MuudEditsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'muud-edits',
      debugShowCheckedModeBanner: false,
      theme: buildEditorTheme(),
      home: const EditorScreen(),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 코드 생성 후 해야 할 일 (docs/LOCAL_SETUP.md 3단계)
//
//   import 'src/rust/frb_generated.dart';
//
//   void main() async {
//     WidgetsFlutterBinding.ensureInitialized();
//     await RustLib.init();          // ← 네이티브 라이브러리 로드
//     runApp(const MuudEditsApp());
//   }
//
// 지금은 스텁(src/rust/api.dart)만 있어 코어 호출이 UnimplementedError로 끝나고,
// 화면 상단에 "브리지 미생성" 안내가 뜬다.
// ─────────────────────────────────────────────────────────────────────────────
