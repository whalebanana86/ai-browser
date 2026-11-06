# TASK-002 광고 제거를 기본 기능으로 넣기

- 상태: COMPLETED (2026-11-06)
- 요청: "기본기능으로 광고제거 넣어줘"

## 요구사항

1. 광고 차단이 기본으로 켜져 있다 (`Settings.blocksAds`, 기본 켬). 추적기 차단과 따로 끌 수 있다 (`defaults write local.feather.browser blockAds -bool NO`).
2. 광고 서버 요청을 WebKit 콘텐츠 규칙으로 막는다.
   - 광고 네트워크(다른 사이트에 광고를 붙이는 회사)는 제3자 요청만 막아, 그 회사 자체 사이트는 그대로 쓸 수 있게 한다.
   - 사이트가 자기 도메인에서 직접 내보내는 광고 서버(예: 포털 광고 호스트)는 출처 구분 없이 막는다. 확실한 광고 전용 호스트만 넣는다.
3. 광고가 빠진 빈 자리를 흔한 광고 틀 선택자로 숨긴다 (보수적인 선택자만).
4. 광고 차단 때문에 페이지가 깨지지 않는다: 조사한 사이트들이 계속 열리고 제목·첫 화면이 나온다.
5. 외부로 새 요청을 보내지 않는다 (필터 목록을 내려받지 않고 앱에 내장).

## 완료 조건 (Acceptance Criteria)

- [x] AC1. 기본 설정에서 광고 규칙이 컴파일되어 적용되고, `blockAds NO`면 광고 규칙만 빠진다 (추적기 규칙은 그대로).
- [x] AC2. 테스트: 광고 호스트와 그 하위 도메인은 막히고, 비슷한 이름의 다른 도메인은 막히지 않는다. 광고 네트워크 규칙은 제3자 전용이다. 숨김 선택자 규칙이 있고 WebKit이 전체 규칙을 받아들인다.
- [x] AC3. 새 테스트는 일부러 깨뜨리면 실패한다 (광고 목록 항목 삭제, 정규식 변경, 잘못된 선택자, 기본값 변경) — 확인 후 되돌림.
- [x] AC4. 조사한 사이트에서 광고 차단 전후를 측정해 광고 요청·광고 틀이 줄고 페이지가 정상으로 열림을 확인한다.
- [x] AC5. `./scripts/auto-fix-loop.sh` 통과.
- [x] AC6. README에 광고 차단 설명과 끄는 방법, 측정 결과를 적는다.

## 계획

1. 국내외 주요 사이트에서 광고 요청 호스트와 광고 틀 조사
2. `AdBlockList.swift` (광고 네트워크, 자사 광고 호스트, 숨김 선택자) 추가, `ContentBlocker`가 설정에 따라 규칙을 합치도록 변경, `Settings.blocksAds` 추가
3. 테스트 추가, 일부러 깨뜨려 확인
4. 차단 전후 측정
5. README, 자동 검증, 완료 처리

수정 대상 파일: `Sources/Feather/AdBlockList.swift`(새 파일), `Tests/FeatherTests/AdBlockTests.swift`(새 파일), `ContentBlocker.swift`, `Settings.swift`, `WebKitEnvironment.swift`(규칙 준비 조건), `Benchmark.swift`(설정 표시), `Tests/FeatherTests/*`, `README.md`, `.agent/*`

## 진행 기록

- 2026-11-06: 국내외 12개 사이트(네이버, 네이버 뉴스, 다음, 다음 뉴스, 인벤, 조선일보, 연합뉴스, 나무위키, 디시인사이드, 루리웹, 한국경제, CNN)에서 리소스·iframe 호스트를 조사. 기존 TrackerList로 이미 막히는 것을 빼고 광고 호스트를 골라냄.
  - 자사 도메인 광고 서버: 네이버 `veta.naver.com`(siape, nam), `ader.naver.com`(GFA), 다음 `ads-api.daum.net`, `display.ad.daum.net`(기존 목록은 제3자만 막아 다음 자체에서는 안 막혔음), 카카오 `serv.ds.kakao.com`, 인벤·연합뉴스 `/RealMedia/ads/` 경로(Open AdStream).
  - 광고 네트워크: Venatus(`vntsm.com`, 나무위키), OpenX(`openxcdn.net`), RTB House(`creativecdn.com`), Innity(루리웹), contentsfeed 등.
  - `shopping-phinf.pstatic.net`은 다음 쇼핑 광고 위젯 이미지지만 네이버 쇼핑 본 콘텐츠도 같은 호스트라 넣지 않음. 위젯 API(`ads-api.daum.net`)를 막는 쪽을 택함.
- 2026-11-06: **설계 결정** — 광고 전용 호스트를 출처 구분 없이 막으면 광고를 클릭해 그 주소로 이동하는 것(예: `ader.naver.com` 클릭 경유)까지 막힌다. 규칙에 `unless-top-url`(같은 패턴)을 붙여 페이지 안 요청만 막기로 함.
  - 로컬 서버로 WebKit 동작 확인: 127.0.0.1 페이지 안의 `localhost` 이미지·스크립트·iframe과 `/RealMedia/ads/` 스크립트는 서버에 요청이 도달하지 않음(차단). `localhost` 광고 페이지와 `/RealMedia/ads/` 주소로 직접 이동하면 정상으로 열림.
  - WebKit 콘텐츠 규칙 정규식은 `|`(선택)를 지원하지 않아 Prebid 경로는 `gh/`, `npm/` 두 규칙으로 나눔.
- 2026-11-06: **발견(범위 밖, 기록만)** — 조사 중 GA4 수집 주소 `analytics.google.com/g/collect`, Google 전환 추적 `www.google.com/measurement/conversion`, `/ccm/collect`가 기존 TrackerList에 없어 안 막히는 것을 봄. 추적기 목록 작업이라 TASK-002 범위 밖. 별도 TASK로 제안.
- 2026-11-06: 구현 — `AdBlockList.swift`(광고 네트워크 25, 광고 전용 호스트 7, 광고 경로 7, 숨김 선택자 13), `ContentBlocker.rulesJSON(trackers:ads:)`, `Settings.blocksAds`(기본 켬), `WebKitEnvironment.prepare`는 둘 중 하나라도 켜져 있으면 규칙 준비, 벤치마크 머리말에 광고 차단 표시.
- 2026-11-06: 기존 테스트 `blockingIsThirdPartyOnly`는 "모든 차단 규칙이 제3자 전용"을 검사했는데, 광고 전용 호스트 규칙은 의도적으로 자사 요청도 막으므로 실패하게 됨. 검사 대상을 추적기 규칙으로 한정해 `trackerBlockingIsThirdPartyOnly`로 이름을 바꿈(추적기 규칙에 대한 기준은 그대로). 광고 규칙은 `AdBlockTests`에서 따로 검사. WebKit 컴파일 테스트는 (추적기+광고, 추적기만, 광고만) 세 조합 모두 컴파일하도록 넓힘.
- 2026-11-06: `swift test` 28개 통과. 차단 전후 실측 진행 중 세션이 끊김 → 재개 후 같은 측정을 이어서 기다림.
- 2026-11-06: 재개 후 1차 실측(11개 페이지): 모든 페이지 정상 로드. 루리웹(iframe 9 → 9)이 그대로여서 확인해 보니 자체 `/banneriframe`과 `ad_main_…`·`ad_aside_…`·`ad_board_…`·`.ad` 틀을 씀. `.ad`, `[id^="ad_"]`는 다른 사이트에선 광고가 아닐 수 있어 `if-domain`으로 루리웹에만 적용하는 `siteHiddenSelectors`를 추가하고, `ruliweb\.com/banneriframe` 경로를 광고 경로에 추가. 한국경제의 iframe 10개는 유튜브·한경TV 본문 영상이라 그대로 둠.
- 2026-11-06: **문제** — 잘못된 CSS 선택자를 넣어도 WebKit 규칙 컴파일이 성공해 테스트가 못 잡음. 선택자 하나가 잘못되면 쉼표로 묶인 숨김 규칙 전체를 브라우저가 버리므로 실제 위험. WebKit의 CSS 파서(`document.querySelector`)로 모든 선택자와 묶음 문자열을 검사하는 `hidingSelectorsAreValidCSS` 추가.
- 2026-11-06: **검토** — 광고 네트워크 규칙을 `load-type: third-party`에서 `unless-top-url`로 바꾸는 변경은 테스트가 못 잡음. 네트워크는 등록 도메인 단위라 "제3자"와 "그 도메인을 직접 연 경우 제외"가 같은 결과를 내는 동등 변경으로 판단. 결과가 실제로 달라지는 변경(어디서나 차단)은 `adNetworksAreBlockedOnlyAsThirdParty`가 잡는 것을 확인.
- 2026-11-06: 최종 실측(12개 페이지, 각 조건 1회) — 아래 표. 모두 정상 로드. 웹 프로세스 메모리는 페이지마다 늘거나 줄어(예: 다음 286 → 247MB, 한국경제 256 → 386MB) 1회 측정으로는 일관된 차이 없음. 메모리 감소는 주장하지 않음.
- 2026-11-06: `./scripts/auto-fix-loop.sh` 통과(시도 1). `--bench`로 앱이 광고 차단 켬 상태에서 네이버·루리웹을 정상으로 여는 것 확인.

## 차단 전후 실측 (추적기만 → 추적기+광고)

| 페이지 | 보이는 iframe | 보이는 광고 틀 | 리소스 수 | 로드 |
|---|---|---|---|---|
| 네이버 | 6 → 2 | 3 → 0 | 111 → 73 | 0.28 → 0.17초 |
| 네이버 뉴스 | 1 → 1 | 0 → 0 | 146 → 132 | 0.47 → 0.47초 |
| 다음 | 5 → 1 | 7 → 0 | 250 → 150 | 0.60 → 0.66초 |
| 인벤 | 3 → 0 | 3 → 0 | 250 → 250 | 0.64 → 0.62초 |
| 인벤 뉴스 | 2 → 0 | 2 → 0 | 172 → 165 | 0.45 → 0.42초 |
| 조선일보 | 0 → 0 | 0 → 0 | 122 → 143 | 0.99 → 0.83초 |
| 연합뉴스 | 1 → 1 | 0 → 0 | 176 → 162 | 1.24 → 0.66초 |
| 나무위키 | 3 → 3 | 0 → 0 | 117 → 52 | 2.41 → 0.21초 |
| 디시인사이드 | 2 → 0 | 4 → 0 | 72 → 66 | 0.40 → 0.18초 |
| 루리웹 | 9 → 0 | 0 → 0 | 232 → 230 | 0.36 → 0.32초 |
| 루리웹 게시판 | 8 → 1 | 0 → 0 | 36 → 33 | 0.26 → 0.25초 |
| 한국경제 | 10 → 10 | 4 → 0 | 100 → 100 | 0.30 → 0.30초 |

"보이는 광고 틀"은 숨김 선택자에 걸리는 요소 수라 숨김 규칙이 작동하는지를 보여 줄 뿐이다. 광고가 줄었다는 독립된 근거는 iframe과 리소스 수다. 리소스 수는 페이지가 매번 다른 기사·광고를 불러와 오차가 크다(조선일보는 오히려 늘었음).

## 일부러 깨뜨려 확인한 결과

스크립트 자체 시험용 임시 `AGENT_DIR`에서 실행. 깨뜨린 파일은 매번 백업으로 되돌리고 `cmp`와 grep으로 확인.

| 깨뜨린 내용 | 결과 |
|---|---|
| 광고 전용 호스트에서 `veta.naver.com` 삭제 | `blocksAdsInsidePages` 실패 |
| 도메인 경계 `[:/]` 삭제 (비슷한 이름까지 차단) | `leavesContentAlone` 실패 |
| `unless-top-url` 삭제 (광고 주소로 이동도 차단) | `adAddressesStillOpenDirectly` 실패 |
| 전역 숨김 선택자에 `div:::broken` 추가 | **처음엔 못 잡음** → `hidingSelectorsAreValidCSS` 추가 후 실패 |
| 루리웹 선택자를 `.ad[`로 깨뜨림 | `hidingSelectorsAreValidCSS` 실패 |
| `blocksAds` 기본값을 끔으로 | `defaults` 실패 |
| 광고 네트워크를 어디서나 차단 | `adNetworksAreBlockedOnlyAsThirdParty` 실패 |
| 광고 네트워크를 `unless-top-url` 방식으로 | 통과 — 동등 변경(위 검토 참고) |
| 루리웹 전용 `[id^="ad_"]`를 전역 선택자에 추가 | `siteSpecificSlotsAreHiddenOnlyOnThatSite` 실패 |
| 광고 끔이어도 광고 규칙이 들어가게 | `adsAndTrackersAreSeparateSwitches` 실패 |
| 광고 네트워크에 TrackerList와 겹치는 `criteo.com` 추가 | `adListIsClean` 실패 |
