# rust_builder (생성 예정)

`dart run flutter_rust_bridge_codegen generate`를 실행하면 이 폴더가
**코어 크레이트를 빌드해 앱에 포함시키는 Flutter 패키지**로 생성된다.

- `flutter_rust_bridge.yaml`의 `rust_builder_output: rust_builder` 설정에 따른 결과물이다.
- 생성 후 `app/pubspec.yaml`의 `dependencies`에 아래 항목이 자동 추가된다.

```yaml
  rust_builder:
    path: rust_builder
```

- 이 폴더를 직접 손으로 만들 필요는 없다. 지금은 설명을 남겨 두기 위한 자리다.
