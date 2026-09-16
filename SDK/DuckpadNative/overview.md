# Duckpad Native SDK v1

- C ABI: `include/DuckpadNative.h`
- Clang/Swift import module: `DuckpadNativeABI`
- Swift source wrapper: `Swift/DuckpadHost.swift`
- Full contract and example: [native SDK guide](../../docs/plugins/native-sdk.md)

Compile the wrapper into your plugin rather than linking Duckpad’s internal Swift modules. The initial API supports a plugin-owned AppKit view, lifecycle and locale callbacks, menu/shortcut declarations, and validated insertion tokens. Native plugins share the host process and App Sandbox authority.
