# DMG 설치 화면

왼쪽 노란색 패널에 오리 그림과 영어 설치 안내를 표시한다.
오른쪽 흰색 영역에는 앱 번들, 이동 화살표, `/Applications` 바로가기를 배치한다.
배경은 680 × 384pt, Finder의 실제 아이콘은 96pt이며
배경 TIFF는 1×·2× 해상도를 함께 포함한다.

원본 배경은 `Packaging/DMG/background.png`에 보관한다. 제공받은 디자인에서
앱·폴더 아이콘과 이름, 한국어 안내 문구, 바깥 테두리를 제거한 이미지다.
아이콘과 이름은 배경에 그리지 않고 Finder가 실제 항목으로 표시한다.

배경 TIFF만 생성하려면 다음 명령을 실행한다.

```sh
mkdir -p build
swift scripts/render_dmg_background.swift Packaging/DMG build/dmg-background.tiff
```

## 생성

서명된 `.app`을 준비한 뒤 저장소 루트에서 실행한다.

```sh
scripts/build_macos_dmg.sh \
  --app /path/to/Duckpad.app \
  --output build/Duckpad-installer.dmg
```

기존 `scripts/build_macos_app.sh`로 생성한 앱을 그대로 사용할 수 있다.
DMG 생성은 앱 코드·서명·버전을 변경하지 않으며, 태그나 릴리즈를 만들지 않는다.
출력 파일이 이미 있으면 덮어쓰지 않고 실패한다.

macOS GUI 로그인 세션과 Command Line Tools가 필요하다. Finder의
AppleScript 인터페이스로 이미지 안의 창 설정만 저장하므로 처음 실행할 때
실행 터미널의 Finder 자동화 권한이 필요할 수 있다. 새 패키지 의존성은 없다.

## 확인

스크립트는 원본과 이미지 내부 앱의 코드 서명, Applications 링크,
Finder 설정 파일, 최종 디스크 이미지 체크섬을 검사한다.
생성한 DMG를 열어 아이콘·설명·화살표 위치를 확인한다.

```sh
hdiutil verify build/Duckpad-installer.dmg
open build/Duckpad-installer.dmg
```

실제 배포 시의 Developer ID 서명·공증은 기존 배포 절차에서 처리한다.
이 스크립트는 DMG의 외형과 압축 패키징만 담당한다.
