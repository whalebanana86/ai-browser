# TASK-004 계정(아이디·비밀번호) 저장 기능

- 상태: COMPLETED (2026-11-06)
- 요청: "계정저장 기능도 추가해줘" — 브라우저의 사이트 계정(아이디·비밀번호) 저장·채우기로 해석

## 요구사항

1. 로그인 폼을 제출하면 "이 계정을 저장할까요?"를 묻는다(저장 / 이 사이트는 저장 안 함 / 나중에). 같은 계정의 비밀번호가 바뀌었으면 업데이트를 묻는다.
2. 비밀번호는 macOS 키체인(인터넷 암호 항목)에만 저장한다. 파일·로그·기록에 남기지 않는다.
3. 채우기는 사용자가 요청할 때만 한다(메뉴 계정 채우기 ⌘\, 툴바 열쇠 버튼). 페이지가 열릴 때 자동으로 채우지 않는다(악성 스크립트가 몰래 읽어 가는 것 방지).
4. 저장·채우기는 https 최상위 페이지에서만, 저장한 호스트와 정확히 같은 호스트에서만 한다. 출처는 페이지가 보낸 값이 아니라 WebKit이 알려 주는 프레임 출처로 판단한다.
5. 폼 감지 스크립트는 페이지 스크립트와 분리된 WebKit 콘텐츠 월드에서 돈다.
6. 저장한 계정 목록을 볼 수 있고 지울 수 있다.

7. 저장 안 함으로 정한 사이트 목록(호스트 이름만, 비밀 아님)은 설정에 저장하고 비울 수 있다.

## 완료 조건 (Acceptance Criteria)

- [x] AC1. 키체인 저장소 테스트: 저장·읽기·비밀번호 변경·호스트별 계정 목록·전체 목록·삭제. Feather 항목만 다룬다(다른 생성자 코드 항목은 목록·삭제 대상 아님). **변경(사용자 결정):** 테스트는 사용자 로그인 키체인이 아니라 테스트마다 만드는 임시 키체인 파일을 쓰고 끝나면 지운다.
- [x] AC2. 실제 WebKit에서 폼 감지 테스트: 폼 제출·버튼 클릭·Enter로 아이디와 비밀번호가 잡힌다. 가입 폼(비밀번호 2개)은 새 비밀번호를 잡는다. http 페이지, iframe 안 폼, 저장 안 함 사이트는 묻지 않는다. 같은 비밀번호면 묻지 않고, 바뀌었으면 업데이트를 묻는다. 페이지 스크립트에서는 메시지 처리기가 보이지 않는다.
- [x] AC3. 실제 WebKit에서 채우기 테스트: 아이디·비밀번호가 채워지고 페이지가 input 이벤트를 받는다. 호스트가 다르거나 http면 채우지 않는다. 비밀번호 칸이 없는 아이디 단계 페이지는 아이디만 채운다.
- [x] AC4. 창 연결 테스트: 계정 메뉴(⌘\ 채우기, 저장된 계정 목록, ⌥ 삭제, 저장 안 함 목록 비우기), 툴바 열쇠 버튼, 채우기 명령이 실제 창 컨트롤러와 메인 메뉴에 연결된다. 사용자의 키체인 항목이나 파일은 건드리지 않는다.
- [x] AC5. (22개 모두 확인 — P08은 사용자 결정에 따라 임시 키체인으로 바꾼 뒤 확인) 새 테스트는 일부러 깨뜨리면 실패한다(출처 검사, https 검사, 최상위 프레임 검사, 저장 안 함, 업데이트 판단, 채우기 호스트 검사, 생성자 코드 격리 등) — 확인 후 되돌림.
- [x] AC6. 비밀번호가 로그·기록 파일·NSLog에 남지 않는다(코드 검색으로 확인).
- [x] AC7. `./scripts/auto-fix-loop.sh` 통과, README 반영.

## 계획

1. `Sources/Feather/Passwords.swift`: `Credential`(출력 시 비밀번호 가림), `CredentialStore`, `KeychainCredentialStore`(생성자 코드 `Fthr`), `PasswordManager`(콘텐츠 월드 스크립트·메시지 처리·저장 판단·채우기), `AccountsMenu`
2. `WebKitEnvironment`에 스크립트 설치, `BrowserWindowController`에 저장 질문 시트·채우기·계정 열기·삭제·툴바 열쇠, `MainMenu`에 계정 메뉴
3. 테스트(키체인, 실제 WebKit 폼 감지·채우기, 창 연결) → 일부러 깨뜨려 확인 → README → auto-fix-loop

수정 대상 파일: `Sources/Feather/Passwords.swift`(새 파일), `WebKitEnvironment.swift`, `BrowserWindowController.swift`, `MainMenu.swift`, `Tests/FeatherTests/PasswordTests.swift`·`BrowserPasswordTests.swift`(새 파일), `README.md`, `.agent/*`

## 진행 기록

- 2026-11-06: 구현. 저장 질문은 시트(저장/나중에/이 사이트는 저장 안 함, 업데이트/나중에). 비밀번호는 답할 때까지만 메모리에 둠. 툴바가 페이지 갱신마다 계정을 묻지 않도록 호스트별 계정 목록을 캐시(저장·삭제 때 비움). 계정 메뉴는 이름 정보만 읽고 비밀번호는 읽지 않음.
- 2026-11-06: 감지 규칙 보완 — '비밀번호 보기' 같은 버튼 클릭에도 저장을 묻는 문제를 막으려고, 제출 버튼 또는 로그인·다음 등의 이름을 가진 버튼만 인정. 아이디만 있는 단계에서는 `autocomplete=username`이나 `type=email` 칸에만 채움(검색창 제외).
- 2026-11-06: 처음 58개 테스트가 한 번에 통과해, 깨뜨려도 못 잡을 빈틈을 먼저 찾음: (1) 다른 호스트 채우기 거부는 Swift 검사와 스크립트 검사 두 겹이라 한 겹만 깨뜨리면 테스트가 통과 → 다른 호스트에서 비밀번호를 읽지도 않는지 세는 검사 추가, 스크립트 검사는 별도 테스트. (2) iframe 거부도 두 겹(최상위 전용 스크립트 + 출처 검사) → 스크립트 설정을 직접 확인하는 테스트 추가. (3) 가입 폼 테스트는 두 비밀번호가 같아 "새 비밀번호 선택"을 구별 못 함 → 비밀번호 변경 폼(기존·새·확인) 추가.
- 2026-11-06: 테스트 실수 — 페이지 스크립트의 `name`이 입력 칸이 아니라 `window.name`이라 아이디가 비어 실패. `getElementById`로 수정(코드 결함 아님).
- 2026-11-06: **안전 문제 발견·수정** — 일부러 깨뜨리기 P08(키체인 조회에서 생성자 코드 필터 제거)을 포함한 실행이 자동 승인 검사에서 "되돌릴 수 없는 로컬 파괴"로 차단됨. 확인 결과 실제 위험: 키체인 테스트의 남은 항목 정리 코드가 생성자 필터만 믿고 `allAccounts()` 결과를 전부 지웠으므로, 필터가 깨지면(일부러든 실제 버그든) 테스트 실행만으로 **사용자 로그인 키체인의 https 암호가 지워질 수 있었음**. 차단된 명령은 실행되지 않았음을 확인(소스 그대로, 키체인 변화 없음). 정리 코드가 `feather-test-…​.invalid` 이름의 호스트만 지우도록 이중 안전장치를 넣고 테스트(`cleanupOnlyTouchesTestHosts`)로 고정.
- 2026-11-06: 출력 시 비밀번호 가림 — 앞선 테스트 실패 메시지에 `password: "new-pass"`가 그대로 찍힘. `Credential`의 문자열 표현에서 비밀번호를 가리고 테스트로 고정. 코드 검색으로 Passwords.swift에 로그 출력이 없고, 비밀번호·자격 증명을 출력하는 곳이 없음을 확인.
- 2026-11-06: 검증 스크립트 기록의 비밀값 가리기가 `PasswordTests.swift: Expectation` 같은 파일 이름 뒤 단어까지 `***`로 가림(지나치게 가리는 쪽이라 안전에는 문제없음). TASK-001 범위의 스크립트라 수정하지 않고 기록만 함.
- 2026-11-06: `./scripts/auto-fix-loop.sh` 통과(시도 1, 테스트 68개). `--bench`로 네이버·GitHub 로그인 페이지를 정상으로 여는 것 확인. 테스트 후 키체인에 테스트 항목이 없음을 `security find-internet-password -c FtTs`로 확인.

## 일부러 깨뜨려 확인한 결과

| # | 깨뜨린 내용 | 결과 |
|---|---|---|
| P01 | 출처 검사에서 최상위 프레임 조건 제거 | `trustedHostNeedsTopLevelHTTPS` 실패 |
| P02 | 출처 검사에서 https 조건 제거 | `trustedHostNeedsTopLevelHTTPS` 실패 |
| P03 | 폼 스크립트를 iframe에도 넣음 | `formScriptRunsOnlyInTopLevelPages` 실패 |
| P04 | 저장 안 함 사이트 검사 제거 | `neverSaveSitesAreNotAsked` 실패 |
| P05 | 같은 비밀번호여도 업데이트를 물음 | `knownPasswordIsNotAskedAndChangedOneOffersUpdate` 실패 |
| P06 | 채우기의 Swift 쪽 호스트 검사 제거 | `refusesOtherHostsAndInsecurePages`(비밀번호 읽기 횟수) 실패 |
| P07 | 채우기 스크립트의 호스트 검사 제거 | `fillScriptChecksTheHostItself` 실패 |
| P08 | 키체인 조회에서 생성자 코드 필터 제거 | 처음엔 사용자 키체인 위험으로 보류 → 사용자 결정으로 임시 키체인 구조로 바꾼 뒤 실행, `onlySeesItsOwnItems` 실패 |
| P09 | 키체인 저장에서 기존 항목 갱신 경로 제거 | `savesReadsUpdatesAndDeletes` 실패(중복 항목 오류 -25299). 테스트 전용 항목만 다루므로 단독 실행 |
| P10 | 메시지 처리기를 페이지 월드에 설치 | `pageScriptsCannotReachTheHandler` 실패 |
| P11 | 모든 버튼 클릭을 로그인으로 봄 | `showPasswordToggleDoesNotCount` 실패 |
| P12 | 비밀번호가 여러 개면 첫 번째를 고름 | `signUpFormOffersTheNewPassword`(변경 폼) 실패 |
| P13 | 같은 로그인 중복 보고 막기 제거 | `loginButtonAndEnterKeyAlsoCount` 실패 |
| P14 | 아이디 단계에서 아무 입력 칸에나 채움 | `firstStepOfTwoStepLoginGetsOnlyTheUsername` 실패 |
| P15 | 채울 때 input 이벤트를 보내지 않음 | `fillsUsernameAndPasswordAndTellsThePage` 실패 |
| P16 | 계정 메뉴 ⌥ 삭제 대체 항목 해제 | `accountsMenuListsWithDeleteAlternates` 실패 |
| P17 | "이 사이트는 저장 안 함" 답이 아무것도 안 함 | 처음엔 빈 `case`로 빌드가 먼저 실패 → 컴파일되게 다시 깨뜨려 `savingAnswersDoWhatTheySay` 실패 확인 |
| P18 | 계정 메뉴가 비밀번호까지 읽음 | `accountsMenuDoesNotReadPasswords` 실패 |
| P19 | 채우기 메뉴가 늘 켜짐 | `menuCommandsAreEnabledOnlyWhenUseful` 실패 |
| P20 | 테스트 정리 안전장치를 아무 호스트나 통과하게 | `cleanupOnlyTouchesTestHosts` 실패 |
| P21 | 출력에 비밀번호를 넣음 | `printingNeverShowsThePassword` 실패 |
| P22 | 조회가 임시 키체인 대신 기본 검색 목록으로 가게 | `onlySeesItsOwnItems` 등 실패. (항목 추가까지 기본 키체인으로 보내는 변경은 사용자 로그인 키체인에 테스트 항목을 남길 수 있어 하지 않음) |

## 재개 후 (사용자 결정 반영)

- 2026-11-06: 사용자 결정 — "임시 키체인으로 바꿔서 확인". 실험: `SecKeychainCreate`로 만든 키체인은 사용자 검색 목록에 들어가지 않고, 그 안의 항목은 기본 검색에서 보이지 않으며, `SecKeychainDelete` 뒤 검색 목록이 원래대로임을 확인.
- `KeychainCredentialStore(creator:keychain:)` — 키체인을 지정하면 조회는 `kSecMatchSearchList`, 추가는 `kSecUseKeychain`로 그 키체인만 씀. 앱은 지정하지 않음(기존과 동일).
- 테스트의 `TemporaryKeychain`: deprecated된 `SecKeychainCreate`/`SecKeychainDelete` 두 함수만 런타임에 찾아 호출(경고를 오류로 다루는 검증 유지). 테스트마다 새 키체인 파일을 만들고 끝나면 지움. 이전의 사용자 키체인 정리 코드와 `cleanupOnlyTouchesTestHosts`는 필요 없어져 제거.
- 북마크 창 테스트도 메모리 계정 저장소를 쓰게 해, 테스트 전체가 사용자 키체인을 지우거나 읽지 않음(남은 접근은 존재할 수 없는 `.invalid` 호스트 조회 1건).
- P08, P22 실행 — 모두 잡힘. 실행 전후로 `security list-keychains` 같음, 로그인 키체인에 `FtTs` 항목 없음.
- `./scripts/auto-fix-loop.sh` 통과(시도 2, 테스트 68개).
