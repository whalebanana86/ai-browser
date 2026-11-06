# TASK-003 북마크 기능

- 상태: COMPLETED (2026-11-06) — 실제 화면 클릭 확인은 사용자 확인 필요(아래 AC4)
- 요청: "북마크 기능 … 추가해줘"

## 요구사항

1. 지금 보는 페이지를 북마크하거나 해제한다: 메뉴 북마크 › 이 페이지 북마크(⌘D), 툴바 별 버튼. 이미 북마크된 페이지면 메뉴 제목이 "북마크에서 제거"로, 별이 채워진 모양으로 바뀐다.
2. 북마크 메뉴에 저장한 북마크가 나열되고, 고르면 지금 탭에서 연다(⌘를 누른 채 고르면 새 백그라운드 탭). ⌥를 누르면 항목이 "삭제"로 바뀌어 지울 수 있다.
3. 북마크는 로컬 파일 하나(`~/Library/Application Support/Feather/bookmarks.json`)에만 저장한다. 동기화·전송 없음.
4. 같은 페이지는 한 번만 저장한다(주소 끝 `#…` 조각과 루트의 `/` 차이는 같은 페이지로 본다).
5. 파일이 깨져 있으면 덮어쓰지 않고 옆에 보관한 뒤 빈 목록으로 시작한다(사용자 데이터를 조용히 잃지 않음).
6. http, https, file 주소만 북마크한다(빈 탭, 오류 페이지의 내부 주소 제외 — 오류 페이지는 원래 주소로 저장).

## 완료 조건 (Acceptance Criteria)

- [x] AC1. `BookmarkStore` 테스트: 추가·제거·토글, 중복 방지(조각·루트 `/` 정규화), 다시 열어도 유지, 깨진 파일 보관 후 빈 목록, 허용 스킴.
- [x] AC2. 북마크 메뉴 항목 구성 테스트: 제목·주소·동작, ⌥ 삭제 대체 항목, 빈 목록 표시, 긴 제목 줄임.
- [x] AC3. 새 테스트는 일부러 깨뜨리면 실패한다(정규화, 저장, 깨진 파일 처리, 토글, 메뉴 대체 항목) — 확인 후 되돌림.
- [x] AC4. 앱에서 메뉴와 툴바가 연결되어 빌드되고, 북마크 추가·목록·열기·삭제가 동작함을 확인한다. **변경:** 이 환경에는 손쉬운 사용 권한이 없어(`osascript` -1719) 실제 메뉴·툴바 클릭은 못 했다. 대신 실제 `BrowserWindowController`(창은 띄우지 않음, 임시 북마크 파일, 세션 저장 끔)와 실제 `MainMenu.build()`, 툴바 항목으로 테스트하고, 앱이 새 메뉴로 실행되는 것을 `--bench`로 확인했다. 화면에서 직접 누르는 확인은 사용자에게 요청.
- [x] AC5. `./scripts/auto-fix-loop.sh` 통과.
- [x] AC6. README 단축키·기능·파일 구조에 반영.

## 계획

1. `Sources/Feather/Bookmarks.swift`: `Bookmark`, `BookmarkStore`, `BookmarksMenu`(메뉴 항목 구성, NSMenuDelegate)
2. `MainMenu.swift`에 북마크 메뉴, `BrowserWindowController.swift`에 ⌘D 동작·별 버튼·열기·삭제·메뉴 검증
3. 테스트 → 일부러 깨뜨려 확인 → 실제 실행 확인 → README → auto-fix-loop

수정 대상 파일: `Sources/Feather/Bookmarks.swift`(새 파일), `MainMenu.swift`, `BrowserWindowController.swift`, `Tests/FeatherTests/BookmarkTests.swift`·`BrowserBookmarkTests.swift`(새 파일), `README.md`, `.agent/*`

## 진행 기록

- 2026-11-06: `Bookmarks.swift` 구현 — `BookmarkStore`(JSON 파일, 원자적 저장, 변경 알림), `BookmarksMenu`(메뉴를 열 때마다 목록을 다시 만듦, ⌥ 대체 항목은 기본 항목의 수정키를 비워야 동작). 창: ⌘D·별 버튼·열기(⌘ 누르면 백그라운드 탭)·삭제·메뉴 제목 전환.
- 2026-11-06: 창 동작 테스트가 사용자 파일을 건드리지 않도록 `BrowserWindowController.bookmarks`를 바꿔 끼울 수 있게 함. 테스트 전후로 사용자 `session.json` 수정 시각이 같고 `bookmarks.json`이 생기지 않음을 확인.
- 2026-11-06: 손쉬운 사용 권한이 없어 실제 화면 클릭은 못 함 → AC4를 위처럼 바꾸고 사용자 확인으로 남김.
- 2026-11-06: `./scripts/auto-fix-loop.sh` 통과(시도 1, 테스트 43개).

## 일부러 깨뜨려 확인한 결과

| 깨뜨린 내용 | 결과 |
|---|---|
| 주소의 `#조각` 무시를 뺌 | `samePageIsSavedOnce` 실패 |
| 호스트 대소문자 무시를 뺌 | `samePageIsSavedOnce` 실패 |
| 파일에 쓰지 않게 | `keepsBookmarksAcrossLaunches` 실패 |
| 깨진 파일을 옮기지 않고 지우게 | `brokenFileIsKeptAside` 실패 |
| 토글이 제거 후에도 "북마크됨"을 돌려주게 | `addRemoveAndToggle` 실패 |
| `about:` 주소도 허용 | `onlyWebPagesCanBeBookmarked` 실패 |
| ⌥ 삭제 항목을 대체 항목에서 뺌 | `menuListsBookmarksWithDeleteAlternates` 실패 |
| 메뉴를 열 때 이전 목록을 지우지 않게 | `menuRebuildKeepsFixedCommands` 실패 |
| 메뉴 제목(추가/제거)을 뒤바꿈 | `commandBookmarksAndUnbookmarksTheCurrentPage` 실패 |
| 북마크 열기가 늘 새 탭으로 | `menuEntriesOpenAndDelete` 실패 |
| 삭제가 아무것도 안 하게 | 처음엔 타입 검사(안 쓰는 변수)가 먼저 잡아 테스트 확인이 안 됨 → 컴파일되게 다시 깨뜨려 `menuEntriesOpenAndDelete` 실패 확인 |
| 빈 탭도 북마크 가능하게 | `blankTabCannotBeBookmarked` 실패 |
| 메인 메뉴에서 북마크 메뉴를 뺌 | `mainMenuHasBookmarksMenu` 실패 |
| 툴바에서 별을 뺌 | `toolbarHasBookmarkStar` 실패 |
