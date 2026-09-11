# 실행 중 언어 변경 검증

검증일: 2026-09-11. 환경: macOS 26.5.1 (25F80), AppKit, 영어/한국어.

## 결과

`scripts/LanguageReloadProbe.swift`를 별도 `.app`으로 컴파일해 실제
`NSOpenPanel`과 `NSSavePanel`을 표시하고 접근성 트리에서 문구를 확인했다.
파일 창은 매번 새 인스턴스로 만들었으며 파일을 열거나 저장하지 않았다.

| 상태 | 앱 자체 번역 문구 | 기본 열기 창 | 기본 저장 창 |
| --- | --- | --- | --- |
| 영어로 시작 | App-owned text: File | Open / Cancel | Save As: / Save / Cancel |
| 같은 프로세스에서 한국어로 변경 | 앱 자체 문구: 파일 | Open / Cancel 유지 | Save As: / Save / Cancel 유지 |
| 한국어로 재실행 | 앱 자체 문구: 파일 | 열기 / 취소 | 별도 저장: / 저장 / 취소 |

실행 중 `UserDefaults.standard`의 `AppleLanguages`를 변경하고, 앱 자체
문구는 명시적인 `ko.lproj` 번들에서 다시 조회했다. 앱 자체 문구는 즉시
바뀌었지만 기본 파일 창은 다시 만들어도 시작 언어를 유지했다.

## Duckpad 적용

언어 설정 저장이 성공하면 `DuckpadMain.apply`에서 `L10n` 카탈로그를
교체하고 기존 창·설정·패널에 `refreshLocalization`을 전달한다.
메뉴와 창 내부 명령 표시줄은 기존 문서 창을 대상으로 다시 구성한다.
문서·편집기·설정 입력 컨트롤은 유지하며 사용자 데이터는 번역하지 않는다.
설정 안내는 앱 자체 문구의 즉시 적용과 기본 파일 창의 재시작 필요를 구분한다.

수정 범위는 `DuckpadMain.swift`, `ScintillaEditorAdapter.swift`의 접근성
레이블, `DuckpadPresentation`의 설정·메뉴·상태·패널 갱신,
`L10n.swift`의 설명과 8개 언어의 안내 문구다. 새 외부 의존성은 없다.

### 검증

- `ChromeLanguageRefreshTests`, `SettingsLanguageRefreshTests`,
  `PanelLanguageRefreshTests`: 11개 통과. 기존 객체·문서 내용·선택 영역·
  UndoManager·미저장 상태·검색 입력·선택 결과·설정 저장 중 상태를 보존한다.
  한글과 이모지가 포함된 문서 내용도 자동 테스트에서 확인한다.
- 기존 설정·지역화·워크스페이스 관련 26개 테스트는 `swift test --no-parallel`로
  통과했다. 최초 병렬 실행에서 창 해제 대기 테스트 1개가 실패했으나,
  해당 테스트 단독 실행과 26개 순차 실행에서는 통과했다.
- `swift build --product DuckpadApp`: 통과.
- `python3 scripts/verify_localizations.py`: 8개 언어의 562개 문자열과
  4개 복수형, 포맷 인자, 리터럴 키 검사 통과.
- `git diff --check`: 통과.
- 별도 bundle ID와 임시 설정·복구·워크스페이스 경로를 사용하는 debug
  테스트 앱에서 영어 → 한국어 → 영어 전환을 확인했다. 설정, 앱 메뉴,
  창 내부 메뉴, 탭 접근성, 상태 표시줄이 재시작 없이 바뀌었다.
- 실제 네이티브 편집기에서 전환 전 입력의 Undo/Redo가 동작했다.
  두 번째 문서 창에서 설정을 열고 언어를 바꾼 뒤, 설정이 열린 상태의
  File → New가 두 번째 창에 탭을 추가하고 기존 내용을 보존했다.
- 독립 코드 리뷰에서 발견한 다중 창 메뉴 대상, 경고 상태 유지,
  워크스페이스 오류 툴팁 갱신 문제를 수정하고 재검토했다.

### 제한

- 기본 `NSOpenPanel`/`NSSavePanel`의 시스템 문구는 시작 언어를 유지한다.
  위 재시작 검증은 지원 언어를 선언한 `.app` 프로브에서 수행했다.
  `.build/.../DuckpadApp` 직접 실행은 패키징의 `Info.plist`를 사용하지
  않으므로 같은 결과를 보장하지 않는다. 개발 실행에서 일본어 설정이
  저장되어도 파일 창은 재시작 후 영어로 유지된다는 보고가 있으며,
  실행 파일 형태 차이가 원인 후보다. Duckpad 배포 패키지에서의
  설정 변경 → 종료 → 재실행 경로는 별도 검증이 필요하다.
- 이미 표시 중인 확인·오류 `NSAlert`는 기존 문구를 유지한다. 새로 여는
  알림은 새 카탈로그를 사용한다. 진행 중인 확인 작업을 다시 만들지 않는다.
- 실제 UI 검증은 위 macOS 버전의 영어·한국어 범위다. 다른 macOS와
  나머지 6개 언어의 시각적 배치, 전환 순간의 한글 IME 조합은 미검증이다.
- 검증 과정에서 설치된 `/Applications/Duckpad.app`은 교체하지 않았다.
  버전 변경과 릴리즈는 이 변경의 범위에 포함하지 않는다.

## 재현

저장소 루트에서 다음 명령으로 테스트 앱을 만든다. 생성된 경로를 보관한다.

```sh
python3 - <<'PY'
import pathlib, plistlib, subprocess, tempfile
app = pathlib.Path(tempfile.mkdtemp(prefix='duckpad-language-probe-')) / 'LanguageReloadProbe.app'
(app / 'Contents/MacOS').mkdir(parents=True)
for language, text in [('en', 'App-owned text: File'), ('ko', '앱 자체 문구: 파일')]:
    resource = app / 'Contents/Resources' / (language + '.lproj')
    resource.mkdir(parents=True)
    (resource / 'Localizable.strings').write_text('"Sample" = "' + text + '";\n')
(app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
    'CFBundleIdentifier': 'com.duckpad.language-probe',
    'CFBundleName': 'LanguageReloadProbe',
    'CFBundleExecutable': 'LanguageReloadProbe',
    'CFBundlePackageType': 'APPL',
    'CFBundleDevelopmentRegion': 'en',
    'CFBundleLocalizations': ['en', 'ko'],
}))
subprocess.run(['swiftc', 'scripts/LanguageReloadProbe.swift', '-o',
    str(app / 'Contents/MacOS/LanguageReloadProbe')], check=True)
print(app)
PY
```

1. `PROBE_LANGUAGE=en /생성된/경로/LanguageReloadProbe.app/Contents/MacOS/LanguageReloadProbe`로 실행한다.
2. Open panel과 Save panel을 각각 열어 문구를 확인하고 취소한다.
3. Switch language를 누른 뒤 두 파일 창을 다시 열어 비교하고 취소한다.
4. 앱을 닫고 동일한 명령의 `PROBE_LANGUAGE`를 `ko`로 바꿔 다시 실행한다.
5. 두 파일 창을 비교하고 취소한 뒤 앱을 닫는다.
6. `defaults delete com.duckpad.language-probe`로 테스트 앱의 설정을 정리한다.

## Apple 문서

[Testing Your Internationalized App](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPInternational/TestingYourInternationalApp/TestingYourInternationalApp.html)은
언어를 실행 옵션으로 지정해 테스트하는 방법을 안내한다. 이 문서만으로
실행 중 변경 가능 여부를 단정하지 않고, 위 표의 결과는 직접 검증했다.
