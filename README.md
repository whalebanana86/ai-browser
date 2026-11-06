# Feather

가볍고 빠르고 추적하지 않는 macOS 브라우저. 앱 크기 약 600KB.

macOS에 내장된 WebKit(Safari와 같은 엔진)을 Swift/AppKit으로 감싼 네이티브 앱입니다.
Chromium을 통째로 싣는 Electron이나 크롬 계열로는 탭 20개를 2GB 안에 넣기 어렵기 때문에
이 방식을 택했습니다.

## 빌드와 실행

```bash
./build.sh        # build/Feather.app 생성
./build.sh run    # 생성 후 실행
```

macOS 13 이상, Xcode(또는 Command Line Tools) 필요. `/Applications`로 옮기면
시스템 설정 › 데스크탑 및 Dock › 기본 웹 브라우저에서 기본 브라우저로 지정할 수 있습니다.

## 목표와 측정 결과

`Feather --bench`는 인기 사이트 20곳을 탭 20개로 하나씩 열고 로드 시간과 메모리를 출력합니다.
메모리는 활동 상태 보기의 "메모리" 열과 같은 값(physical footprint)을
**앱 + WebContent·Networking·GPU 등 WebKit 프로세스 전부**에 대해 합산한 값입니다.

```bash
./build/Feather.app/Contents/MacOS/Feather --bench
./build/Feather.app/Contents/MacOS/Feather --bench https://example.com https://naver.com   # 원하는 주소로
./build/Feather.app/Contents/MacOS/Feather --bench --browse 4 https://www.inven.co.kr   # 탭마다 링크 4번 따라가기
```

2026-10-28, M 시리즈 Mac, macOS 26.3에서 측정한 값입니다.

| 항목 | 결과 |
|---|---|
| 탭 20개 열었을 때 메모리 (최고 / 안정 후) | **1.36GB / 1.00GB** |
| 같은 조건, 탭 일시 중단을 끄면 | 3.56GB / 3.43GB |
| 탭 3개(GeekNews, 인벤 2개)에서 링크를 4번씩 따라간 뒤 | 최고 1.00GB / 안정 후 807MB |
| 첫 화면 표시(FCP) 중앙값 | **0.56초** (전날 측정 0.38초) |
| 1초 이내에 첫 화면이 뜬 사이트 | 16/18 (2곳은 측정 안 됨) |
| 빈 새 탭만 있을 때 | 37MB |

**1초 목표에 대해 솔직하게:** 첫 화면 시간은 네트워크와 사이트 서버에 크게 좌우됩니다.
캐시가 빈 첫 방문에서는 조선일보·11번가·뉴욕타임스·다음 같은 무거운 사이트가 1.2~2.7초 걸린 적이 있고,
같은 사이트도 실행할 때마다 차이가 납니다. 브라우저 쪽 지연은 최소화했지만 모든 사이트의 1초 이내를
보장할 수는 없습니다. 지금 탭의 측정값은 툴바 오른쪽(예: `0.38초 · 812 MB`)에 항상 표시되고,
마우스를 올리면 자세한 내역이 나옵니다.

## 어떻게 가볍게 유지하나

- **탭 일시 중단** — 탭은 최대 6개까지만 실제로 실행됩니다. 더 오래 안 본 탭부터 웹 프로세스를 해제하고
  주소·제목·뒤로가기 기록·스크롤 위치(몇 KB)만 남깁니다. 다시 누르면 그 자리로 복원됩니다.
  중단된 탭은 탭 바에서 흐리게 보입니다.
- **메모리 예산** — 5초마다(그리고 탭 로드가 끝날 때마다) 실제 총 메모리를 재서 1GB를 넘으면
  메모리를 가장 많이 쓰는 백그라운드 탭부터 중단해, 다시 불러와야 하는 탭 수를 줄입니다.
  소리가 나는 탭과 카메라·마이크를 쓰는 탭은 남기지만, 1.25GB를 넘거나 macOS가 메모리 부족을
  알리면 그런 탭도 중단합니다.
- 15분 동안 안 본 백그라운드 탭도 중단합니다.
- **뒤로 가기 캐시 비우기** — WebKit은 즉시 뒤로 가기를 위해 지나온 페이지를 메모리에 남겨 둡니다
  (다른 사이트로 넘어갔다면 프로세스 하나를 통째로). 다른 탭으로 넘어가면 그 탭의 이 캐시를 비웁니다.
  지금 보고 있는 탭은 그대로 두므로 뒤로 가기는 여전히 즉시 됩니다.
- 새 탭은 주소를 입력하기 전까지 웹 프로세스를 만들지 않고, 지난 세션의 탭도 누를 때만 불러옵니다.
- 화면에 보이는 탭 하나만 뷰 계층에 있어 나머지는 WebKit이 타이머·렌더링을 멈춰 둡니다.

## 광고 차단

기본으로 켜져 있습니다. 앱에 목록을 내장해서 필터 목록을 내려받는 요청도 보내지 않습니다
(`Sources/Feather/AdBlockList.swift`).

- **광고 네트워크** — Venatus, OpenX, RTB House, Innity 등. 다른 사이트에 붙을 때만 막아, 그 회사 사이트는 그대로 열립니다.
- **포털·언론사가 자기 도메인으로 내보내는 광고** — 네이버(`veta.naver.com`, GFA), 다음·카카오 애드핏,
  쿠팡 파트너스 배너, 인벤·연합뉴스의 Open AdStream(`/RealMedia/ads/`), 루리웹 배너.
  자기 사이트에서도 막지만, 광고를 눌러 그 주소로 이동하는 것은 막지 않습니다.
- **빈 광고 틀 숨김** — 막힌 광고가 남기는 빈 자리를 AdSense·애드핏·Taboola 등의 광고 틀 이름으로 숨깁니다.
  `.ad`처럼 다른 곳에선 광고가 아닐 수도 있는 이름은 그 이름을 광고에 쓰는 사이트에서만 적용합니다.

2026-11-06 측정 (추적기 차단만 켠 경우 → 광고 차단까지 켠 경우, 각 1회):

| 사이트 | 화면에 보이는 iframe | 불러온 리소스 수 |
|---|---|---|
| 네이버 | 6 → 2 | 111 → 73 |
| 다음 | 5 → 1 | 250 → 150 |
| 인벤 / 인벤 뉴스 | 3 → 0 / 2 → 0 | 250 → 250 / 172 → 165 |
| 나무위키 | 3 → 3 | 117 → 52 |
| 디시인사이드 | 2 → 0 | 72 → 66 |
| 루리웹 / 게시판 | 9 → 0 / 8 → 1 | 232 → 230 / 36 → 33 |

12개 페이지 모두 광고 차단을 켠 상태에서 정상으로 열렸습니다. 한국경제의 iframe 10개는 유튜브 등 본문 영상이라
그대로입니다. 웹 프로세스 메모리는 페이지마다 늘거나 줄어 일관된 차이가 없었습니다(1회 측정이라 오차 범위 안).

광고 목록은 직접 고른 것이라 EasyList 같은 공개 필터 목록보다 범위가 좁습니다. 처음 보는 사이트의 광고는
남아 있을 수 있습니다.

## 추적 방지

- **추적기 차단** — Google Analytics·태그 매니저, 메타 픽셀, Criteo, 세션 녹화 서비스 등과
  네이버·카카오 분석 스크립트, 국내 광고망을 포함해 약 160개 도메인을 WebKit 콘텐츠 규칙으로 차단합니다
  (`Sources/Feather/TrackerList.swift`). 차단은 WebKit 네트워크 계층에서 일어나 요청이 아예 나가지 않습니다.
- **제3자 쿠키 차단**, `<a ping>`·`sendBeacon` 차단.
- 링크의 추적 파라미터 제거: `utm_*`, `fbclid`, `gclid`, `msclkid` 등.
- User-Agent를 설치된 Safari와 똑같이 맞춰 핑거프린팅에서 튀지 않게 합니다.
- 기본 검색 엔진은 DuckDuckGo입니다. 검색어 자동완성처럼 입력 중에 외부로 보내는 기능은 없습니다.
  `!g 검색어`, `!naver 검색어`처럼 DuckDuckGo 뱅(!)을 쓰면 다른 엔진으로 바로 검색됩니다.
- **브라우저 자체가 아무것도 보내지 않습니다.** 텔레메트리·크래시 리포트·업데이트 확인이 없고,
  방문 기록도 저장하지 않습니다. 다음 실행 때 복원하려고 열린 탭의 주소와 제목만
  `~/Library/Application Support/Feather/session.json`에 로컬로 저장합니다.
- 메뉴 Feather › 쿠키 및 캐시 지우기로 모든 사이트 데이터를 지울 수 있습니다.
- 다운로드 파일에는 격리(quarantine) 속성을 붙여 Gatekeeper 검사를 받게 합니다.

## 단축키

| | |
|---|---|
| ⌘T / ⌘W / ⇧⌘T | 새 탭 / 탭 닫기 / 닫은 탭 다시 열기 |
| ⌘L | 주소창 |
| ⌘R / ⇧⌘R | 새로고침 / 캐시 무시 새로고침 |
| ⌘[ / ⌘] | 뒤로 / 앞으로 |
| ⇧⌘] / ⇧⌘[ , ⌘1–9 | 다음·이전 탭, 탭 바로 가기 |
| ⌘F / ⌘G / ⇧⌘G | 찾기 / 다음 / 이전 |
| ⌘D | 이 페이지 북마크 / 북마크에서 제거 |
| ⌘= / ⌘- / ⌘0 | 확대 / 축소 / 실제 크기 |

⌘클릭이나 휠 클릭을 하면 링크가 백그라운드 탭에서 열립니다. 탭을 휠 클릭하면 닫힙니다.

## 북마크

툴바의 별이나 ⌘D로 지금 페이지를 북마크하고, 메뉴 북마크에서 엽니다(⌘를 누른 채 고르면 새 백그라운드 탭).
메뉴를 연 채로 ⌥를 누르면 항목이 "삭제"로 바뀝니다. 북마크는
`~/Library/Application Support/Feather/bookmarks.json`에만 저장되고 동기화·전송은 없습니다.
파일이 깨져 있으면 `bookmarks.broken.json`으로 옮겨 두고 빈 목록으로 시작합니다.

## 설정

설정 화면 대신 `defaults`로 바꿉니다(다음 실행부터 적용).

```bash
defaults write local.feather.browser maxLiveTabs -int 8          # 실행 탭 상한 (기본 6)
defaults write local.feather.browser memoryBudgetMB -int 1536    # 메모리 예산 MB (기본 1024)
defaults write local.feather.browser idleSuspendMinutes -int 30  # 유휴 중단 시간 (기본 15분)
defaults write local.feather.browser searchURL "https://www.google.com/search?q=%s"
defaults write local.feather.browser blockTrackers -bool NO      # 사이트가 깨질 때 원인 확인용
defaults write local.feather.browser blockAds -bool NO           # 광고 차단 끄기 (추적기 차단은 그대로)
```

## 알아둘 점

- 메모리 측정, 뒤로 가기 캐시 비우기, "소리 재생 중" 판별에 WebKit 비공개 API(`_webProcessIdentifier`,
  `_clearBackForwardCache`, `_isPlayingAudio` 등)를 씁니다. 모두 존재 여부를 확인하고 호출하므로,
  macOS 업데이트로 사라지면 해당 기능만 조용히 꺼집니다. 이 때문에 Mac App Store에는 올릴 수 없습니다.
- 일시 중단된 탭은 다시 열 때 새로 불러옵니다(디스크 캐시 덕에 보통 빠름). 작성 중이던 폼 입력은 남지 않을 수 있습니다.
- 확장 프로그램, 비밀번호 관리, 동기화는 아직 없습니다.

## 개발과 검증

```bash
swift test                     # 단위 테스트 (주소 해석, 추적기·광고 차단 규칙, 북마크, 메모리 측정, 기본 설정값)
./scripts/auto-fix-loop.sh     # 빌드 → 타입 검사 → Lint → 테스트, 결과를 .agent/attempts/에 기록
```

`auto-fix-loop.sh`는 한 번 실행이 한 번의 시도입니다. 같은 오류가 연달아 나오거나 실패가 5회에 닿거나
첫 시도부터 60분이 지나면 중단하고, 중단된 작업은 `AUTOFIX_APPROVED_RETRY=1` 없이는 다시 돌지 않습니다.
종료 코드와 설정은 스크립트 맨 위에 적혀 있습니다. 작업 규칙은 `AGENTS.md`, 작업 기록은 `.agent/`에 있습니다.

메모리·속도 목표는 네트워크에 좌우되어 자동 검증에 넣지 않았습니다. `--bench`로 따로 확인합니다.

## 구조

| 파일 | 역할 |
|---|---|
| `BrowserWindowController.swift` | 창, 툴바, 탭 목록, 세션 저장 |
| `Tab.swift` | 탭 하나: 내비게이션, 일시 중단·복원, 로드 시간 측정, 오류 페이지 |
| `MemoryGovernor.swift` | 메모리 예산에 맞춰 탭 중단 |
| `MemoryMeter.swift` | 앱 + WebKit 프로세스 전체 메모리 측정 |
| `ContentBlocker.swift`, `TrackerList.swift`, `AdBlockList.swift` | 추적기·광고 차단 규칙 |
| `WebKitEnvironment.swift` | 공유 WebKit 설정(데이터 저장소, 규칙, UA) |
| `URLTools.swift` | 주소창 해석, 추적 파라미터 제거 |
| `Views.swift` | 탭 바, 주소창, 찾기 막대 등 |
| `Bookmarks.swift` | 북마크 저장, 북마크 메뉴 |
| `Benchmark.swift` | `--bench` |
| `Tests/FeatherTests/` | 단위 테스트 |
| `scripts/auto-fix-loop.sh`, `.swift-format` | 자동 검증, Lint 설정 |
