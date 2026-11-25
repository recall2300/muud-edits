import 'package:flutter/material.dart';

import 'editor/editor_screen.dart';
import 'rust_core_loader.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Rust 코어를 먼저 깨운다. 실패해도 앱은 뜨고, 화면이 사유와 함께 안내한다.
  await loadRustCore();

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
