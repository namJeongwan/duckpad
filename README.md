# Duckpad

Windows에서 사랑받아 온 [Notepad++](https://notepad-plus-plus.org/)의 익숙함을 Mac에서도 이어가고 싶어 만들었습니다.

Duckpad는 Notepad++에서 영감을 받은 독립적인 macOS 텍스트·코드 편집기입니다. 익숙한 편집 경험을 유지하면서, Mac에 맞는 사용성과 필요한 개선을 더합니다.

- 여러 줄 탭, 탭 고정, 드래그로 최대 4개 패널 분리
- 구문 강조, 찾기·바꾸기, 인코딩·줄바꿈 형식 선택
- 앱을 종료해도 저장하지 않은 문서와 작업 상태 복원
- 시스템·Light·Dark 테마

## 다운로드

**macOS 13 이상 · Apple Silicon 및 Intel Mac**

[Duckpad 0.1.0 다운로드](https://github.com/namJeongwan/duckpad/releases/tag/v0.1.0)

0.1.0은 Apple 공증을 받지 않은 초기 릴리스입니다. 설치 안내는 릴리스 노트를 참고해 주세요.

## 직접 실행

Swift 툴체인이 설치된 Mac에서:

```sh
git clone https://github.com/namJeongwan/duckpad.git
cd duckpad
swift run DuckpadApp
```

[빌드·배포 안내](docs/wiki/30-macos-distribution.md) · [이슈 제보](https://github.com/namJeongwan/duckpad/issues)

편집 엔진은 [Scintilla](https://www.scintilla.org/)와 [Lexilla](https://www.scintilla.org/Lexilla.html)를 사용합니다.
