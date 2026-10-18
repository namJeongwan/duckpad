# Duckpad 사용 통계 운영

Mac mini의 `/Volumes/mtdev/dp-telemetry`에서 Aptabase, PostgreSQL,
ClickHouse, nginx를 Docker Compose로 실행한다. 공개 주소는
<https://dp-stats.hongyoungjun.com>이다. 앱 배포와 서버 배포는 별개다.

## 접속 및 실행

```sh
ssh macmini
cd /Volumes/mtdev/dp-telemetry
/opt/homebrew/bin/docker compose ps
curl --fail http://127.0.0.1:4318/healthz
```

관리자 로그인은 비밀번호 없이 일회성 링크를 사용한다. 현재 네이버 SMTP가 설정되어
실제 로그인 메일 수신까지 확인했다. 다음 수동 링크 절차는 SMTP 없는 초기 배포에만 해당한다.
아래 네이버 SMTP 설정 전에는 메일이 도착하지 않으므로 Mac mini에서 다음 명령으로
로그인 링크를 생성한다. 기존 계정에는 `--bootstrap`을 붙이지 않는다.

```sh
python3 admin-login.py --email YOUR_ADMIN_EMAIL
open .private/login.html
```

다른 Mac에서 접속하려면 `.private/login.html`을 SSH/SCP로 가져와 연다.
이 파일은 로그인 자격 증명이므로 공유하지 않는다. 만료되면 다시 생성한다.
`.env`, `.private`, 데이터 디렉터리는 Git에서 제외된다. 컨테이너 로그에도
로그인 링크가 기록되므로 로그 전체를 공개하거나 지원 문서에 붙이지 않는다.

Cloudflare의 기존 `komga` Tunnel에서 이 호스트만 `http://127.0.0.1:4317`로 연결했다.
nginx는 공개 회원 가입을 차단하고 수집 요청을 IP별 초당 5회, burst 20으로 제한한다.
로그인 메일 요청은 IP별 분당 2회(burst 2), 전체 분당 5회(burst 4)로 제한하며
초과 요청에는 429를 반환한다. 잠시 후 다시 시도한다.
원본 앱 포트 4318은 로컬 초기 설정용이다. DB 포트는 외부에 공개하지 않는다.
기존 Tunnel 설정의 변경 전 백업은 `~/.cloudflared/config.yml.before-dp-telemetry-*`에 있다.

### 네이버 SMTP 활성화

네이버 메일에서 POP3/SMTP 사용 및 2단계 인증을 켜고 애플리케이션 비밀번호를 발급한다.
Mac mini에서 다음 명령을 실행해 비밀번호를 숨김 입력한다. 일반 로그인 비밀번호나
명령행 인자로 비밀번호를 전달하지 않는다. Docker Compose 2.30 이상이 필요하다.

```sh
python3 configure-naver-smtp.py --username YOUR_NAVER_ID
```

스크립트는 `smtp.naver.com:465` SSL 인증을 확인한 뒤 `.private/smtp.env`에
권한 600으로 설정을 저장하고 Aptabase만 재생성한다. 테스트 메일은 발송하지 않는다.
완료 후 공개 대시보드에서 기존 관리자 이메일로 로그인하면 메일로 링크를 받는다.
발송 네이버 계정과 관리자 수신 계정은 달라도 된다. SMTP 설정 후에는
`admin-login.py` 대신 대시보드 로그인을 사용한다. `.private/smtp.env`도 백업에 포함한다.
이 배포에서는 사용자 입력 후 SMTP 인증과 실제 로그인 메일 수신을 확인했다.

`SMTPAuthenticationError`는 네이버의 SMTP 인증 거절이다. POP3/SMTP가 '사용함'인지,
명령의 네이버 ID와 앱 비밀번호를 발급한 계정이 같은지 확인한다. 일반 계정 비밀번호
대신 해당 계정에서 새 앱 비밀번호를 발급해 다시 입력한다. 인증 거절 시 기존 설정과
컨테이너는 변경하지 않는다. 스크립트는 오류 종류와 SMTP 숫자 코드만 표시하며
비밀번호나 서버 응답 원문은 출력하지 않는다.

## 새 서버를 만들 때만

이미 실행 중인 서버의 `.env`를 다시 생성하면 DB 비밀번호와 인증이 깨질 수 있다.
아래 작업은 빈 설치 디렉터리에서만 실행한다.

```sh
python3 - <<'PY'
import os, secrets
from pathlib import Path
os.umask(0o077)
template = Path('.env.example').read_text()
for key in ('POSTGRES_PASSWORD', 'CLICKHOUSE_PASSWORD', 'AUTH_SECRET'):
    template = template.replace(key + '=\n', key + '=' + secrets.token_hex(32) + '\n')
with Path('.env').open('x') as output:
    output.write(template)
PY
/opt/homebrew/bin/docker compose up -d
python3 admin-login.py --bootstrap --email YOUR_ADMIN_EMAIL
```

생성된 `app-config.json`의 공개 App Key와 URL을 `Packaging/Info.plist`의
`DuckpadUsageAppKey`, `DuckpadUsageHost`에 설정한다. App Key는 이벤트 수집용 공개
식별자이며 관리자 인증 정보가 아니다. 앱에 포함되어도 되지만 이벤트 위조를 막는
비밀키로 사용할 수는 없다. 현재 이미지는 digest로 고정했다. 업그레이드 전에는
DB 호환성과 마이그레이션을 확인하고 백업한다.

## 앱 동작과 수집 범위

설정 → 개인정보 보호 → 사용 통계 공유는 신규 설치 및 해당 설정이 없는 기존 설치에서
기본 켜짐이다. 명시적으로 꺼둔 설정은 유지한다. 처음 활성화된 실행에서 편집을 막지 않는
안내 배너와 개인정보 보호 설정 버튼을 표시한다. 설정에서 언제든 끌 수 있다.
Release `.app`에 올바른 HTTPS 설정이 있고 공유가 켜져 있을 때만 전송한다.
Debug, `swift run`, `DUCKPAD_*` 테스트 환경에서는 전송하지 않는다.

| 이벤트 | 의미 / dimension |
| --- | --- |
| `app_first_observed` | 통계를 처음 켠 로컬 설정에서 처음 관측한 실행 |
| `app_version_changed` | 통계를 켠 상태에서 이전 관측 버전과 달라짐 / 이전 버전 |
| `app_active_day` | 로컬 설정 기준 UTC 날짜별 첫 활동 |
| `editor_active_minute` | 앱이 활성화된 동안 실제 편집이 발생한 언어별 분 / 언어 ID |
| `feature_used` | 찾기·바꾸기·폴더 검색·터미널·Markdown 미리보기 열기 / 기능 ID |
| `plugin_installed`, `plugin_updated`, `plugin_removed` | 설치·업데이트·제거 결과 / 공개 플러그인 ID |
| `plugin_invoked` | 문서 명령 실행 결과 / 공개 플러그인 ID |
| `plugin_panel_opened` | 서비스 패널 열기 결과 / 공개 플러그인 ID |
| `format_completed` | 실제 포맷 처리 결과 |

같은 UTC 날짜·종류·dimension·결과·소요 시간 구간은 `count`로 합산한다. 편집 횟수나 키 입력
수를 보내지 않는다. 한 분에 여러 언어를 편집하면 각각 한 분으로 세므로 합계가
실제 경과 시간과 같지는 않다. 플러그인 자동 폴링·클립보드 내용은 수집하지 않는다.
개인 플러그인과 등록되지 않은 언어는 `other`로 보낸다. 공개 플러그인 허용 목록은
`UsageStatistics.swift`의 Text Tools, Clipboard History, PlantUML 세 ID다.

앱 버전·빌드 번호, macOS major/minor, 무작위 실행 세션 ID, 시각을 함께 보낸다.
문서 내용·파일명·경로·검색어·터미널 명령·원문 오류·기기 고유 ID는 포함하지 않는다.
nginx는 접근 로그를 저장하지 않으며, 수집 경로에서 IP를 메모리상의 요청 제한에만
사용한다. Aptabase로는 허용한 헤더만 전달하고 IP는 127.0.0.1로 대체한다.
원래 IP·쿠키·위치 헤더는 전달하지 않는다. 국가/지역 통계는 제공하지 않는다.
Cloudflare는 네트워크 연결 IP를 처리한다. 계정의 Cloudflare 로그·보관 설정은 아직
확인하지 못했으며, 자체 호스팅만으로 전체 연결이 익명화된다고 단정하지 않는다.
관리자 로그인 경로는 수집 경로와 별개이며 기존 인증 헤더를 유지한다.

전송은 5분마다 최대 25개 합산 항목, 128 KiB이며 대기 항목은 최대 128개다.
실패 시 다음 주기에 최대 총 3회 시도하고, 23시간이 지난 항목은 버린다.
요청/전체 타임아웃은 5/10초다. 비싼 네트워크 및 저데이터 모드에서는 전송하지 않는다.
HTTP·JSON 작업은 UI 스레드 밖에서 실행하며 입력마다 디스크나 네트워크 작업을 하지 않는다.
통계를 끄면 대기 큐와 최근 로그를 지우고 진행 중 전송을 취소한다. 이미 서버가 받은
이벤트를 삭제하는 기능은 아니다. 앱 종료 시 전송을 기다리지 않고 메모리 큐를 버린다.

첫 관측·버전 변경·활동 날짜의 로컬 완료 표시는 서버의 성공 응답 후에만 저장한다.
전송 전에 종료하거나 실패하면 다음 실행에서 다시 기록할 수 있다. 날짜 경계를 넘긴
활동은 서로 다른 항목으로 합산한다. 로컬 표시는 기기 ID나 서버로 전송하는 식별자가 아니다.

따라서 이것은 공유가 켜진 사용자의 **대략적인 사용 경향**이다. DMG 다운로드/설치 수,
정확한 사용자 수, 월간 재방문율을 의미하지 않는다. 짧은 실행·오프라인·종료·재시도로
누락이나 중복이 생길 수 있다. 새 버전을 관측한 시점은 실제 업데이트 설치 시점과 다르다.
로컬 패키지 파일 가져오기는 설치로 집계하며 카탈로그 업데이트만 별도 업데이트로 구분한다.

## 대시보드에서 읽는 방법

Duckpad 앱을 선택하고 Release 모드에서 이벤트를 선택한다.
언어별 편집량은 `editor_active_minute` → `dimension` → **Sum (count)**,
기능·플러그인 사용량도 해당 이벤트 → `dimension` → **Sum (count)**로 본다.
기본 Events 수는 합산 항목 수이므로 실제 활동량과 다르다.
IP를 대체하므로 Aptabase의 Users/고유 사용자 위젯은 서로 다른 사용자를 합칠 수 있다.
사용자 수로 해석하지 않는다. 일별 활동 경향은 `app_active_day`의 **Sum (count)**로 본다.
Aptabase 내부의 IP별 수집 제한도 전체 앱에 공유되므로, 이용량이 늘면 별도 부하 검증이 필요하다.
`outcome`과 `durationBucket`으로 성공/실패 및 소요 시간 구간을 나눠 볼 수 있다.
여러 속성의 합계를 다시 더하면 같은 이벤트가 중복 계산되므로 한 속성씩 읽는다.

설치 검증용 `deployment_check`, `deployment_swift_check`, `deployment_privacy_check`
이벤트는 Debug 모드에만 있다.
Swift 전송 코드의 테스트 항목 `count=7`이 대시보드의 Sum으로 7인 것까지 검증했다.
앱의 전송 로그 창은 최근 5개 시도만 메모리에 표시하며 다시 열면 갱신한다.

## 보관 및 복구

데이터는 `data/postgres`, `data/clickhouse`에 저장된다. 현재 별도 자동 백업이나
사용자 정의 보관 기간/삭제 스케줄은 설정하지 않았다. 디스크 사용량을 확인한다.
정합성 있는 파일 백업은 서비스가 정지된 상태에서 `.env`, 설정 파일, `data/`를
권한 제한 저장소에 함께 복사한다. 백업에 DB 비밀번호와 관리자 정보가 포함된다.

```sh
/opt/homebrew/bin/docker compose stop
# 이 상태에서 운영 디렉터리를 권한 제한 백업 저장소에 복사한다.
/opt/homebrew/bin/docker compose up -d
```

복구 시 같은 이미지 digest와 `.env`를 사용하고, 빈 운영 디렉터리에 백업을 복원한 뒤
`docker compose up -d` 및 `/healthz`를 확인한다. DB 데이터가 필요하면
`docker compose down -v`나 `data/` 삭제를 하지 않는다. Docker와 외장 볼륨이
준비되어 있어야 재시작 정책이 작동한다. 재부팅·복원 실험은 아직 하지 않았다.

## 구현 검증 (2026-10-18)

- Apple Silicon에서 `swift build -c release --product DuckpadApp` 통과.
- 통계·설정·플러그인·포맷·한글 입력·다중 선택·Undo/Redo 관련 테스트 91개 통과.
- 8개 언어 리소스 검사, 설정 저장 및 언어별 밝은/어두운 테마 레이아웃 검사 통과.
  8개 언어 설정 화면의 실제 창 캡처도 확인했다.
- 공개 HTTPS 수집 → ClickHouse 저장 → 인증된 대시보드의 `Sum (count)` 조회 검증.
- 공개 가입 차단, 컨테이너 상태, `/healthz`, 설정 파일 구문 검사 통과.
- 리뷰 후 최초 실행/버전 변경 전송 실패와 날짜 경계 회귀 3건을 실패→성공으로 확인했다.
- 기본 켜짐·기존 끄기 유지·전송 취소·안내 배너를 포함한 통계 테스트 11개 통과.
  변경 후 기존 설정·저장·이전 형식 호환성 관련 30개도 통과했다.
  최종 Apple Silicon Release 빌드를 다시 확인했다(기존 Ghostty 디버그 심볼 경고 있음).
  안내는 폭 640에서 8개 언어와 밝은/어두운 테마로 검사하고 실제 캡처를 확인했다.
- 로그인 요청 제한은 가짜 upstream 회귀 검사에서 실패→성공으로 확인했다.
  IP·쿠키·위치 헤더 제거도 검사했다. 운영 nginx에 적용 후 공개 health 200,
  가입 차단 403, Debug 이벤트 수집 200을 확인했다.
- 독립 리뷰의 Major 2건을 수정하고 재리뷰에서 추가 Blocker/Major 없음 확인.
  커밋 후보 서명·커밋·푸시는 수행하지 않았다.
- 전체 테스트·Intel 하드웨어·서명된 배포 패키지·서버 재부팅/백업 복원은 검증 범위에
  포함하지 않았다. 앱 릴리스는 게시하지 않았다.

관련 테스트 재실행:

```sh
swift test --filter 'usage|AppSettings|localSettings|legacyPreferences|ExtensionWorkspaceUseCaseTests|Formatting|typingUndoRedoAndMultiselectionEmitOwnedEdits|koreanMarkedTextCopyPasteAndLargeUTF8RemainValid|rejectedEditReplaysAcceptedDeltaJournalWithoutHotPathSnapshot'
```

설정 창 캡처가 필요하면 `DUCKPAD_USAGE_UI_OUTPUT=/tmp/duckpad-usage-ui`를 지정하고
`swift test --filter usagePreferencePersistsOptOutAndRendersAllLanguages`를 실행한다.
테스트 창만 캡처하며 macOS 화면 기록 권한이 필요하다.


## 프록시 회귀 검사

`python3 test-proxy.py`는 독립 Docker 네트워크와 가짜 upstream을 생성하고 정리한다.
실제 Aptabase나 SMTP에 접속하지 않는다. 가입 차단, 로그인 요청의 IP별/전체 제한,
통계 수집과 로그인 링크 경로, 수집 시 IP·쿠키·위치 헤더 제거를 검증한다.
