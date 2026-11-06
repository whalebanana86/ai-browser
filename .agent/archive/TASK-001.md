# TASK-001 검증 장치 만들기 (자동 검증 스크립트 · 테스트 · .agent 구조)

- 상태: COMPLETED (2026-11-06)
- 요청: AGENTS.md 규칙이 전제하는 것들(검증 스크립트, 테스트, `.agent/` 폴더)을 만든다.

## 요구사항

1. `.agent/` 아래 `tasks/`, `attempts/`, `archive/`, `PROGRESS.md`를 둔다.
2. `./scripts/auto-fix-loop.sh`는 빌드 → 타입 검사 → Lint → 테스트를 차례로 실행하고, 시도마다 결과를 `.agent/attempts/TASK-ID.jsonl`에 한 줄씩 남긴다.
   - 빌드: `./build.sh` (배포용 release 빌드와 앱 번들)
   - 타입 검사: 경고를 오류로 다루는 엄격 컴파일 (`-warnings-as-errors`)
   - Lint: `swift format lint` (툴체인 내장). 기존 코드가 Xcode식 정렬 들여쓰기를 써서, 줄 배치·들여쓰기 같은 배치 항목은 검사하지 않고 코드 규칙만 검사한다.
   - 테스트: `swift test`
3. 제한: 최대 재시도 횟수(`MAX_ATTEMPTS`, 기본 5), TASK 전체 시간 제한(`TIME_LIMIT_MIN`, 기본 60분), 단계별 실행 시간 제한(`STEP_TIMEOUT_SEC`, 기본 900초).
4. 같은 오류가 연달아 나오거나 제한을 넘으면 중단하고, 중단된 TASK는 사용자 승인(`AUTOFIX_APPROVED_RETRY=1`) 없이는 다시 실행하지 않는다.
5. 기록에 민감정보가 남지 않게 한다 (홈 경로 축약, 토큰·비밀번호 형태 가림).
6. 순수 로직에 테스트를 둔다: URLTools(주소 해석, 추적 파라미터 제거, 주소 표시), ContentBlocker(규칙 내용, 정규식 의미, WebKit 컴파일), MemoryMeter, Settings 기본값.

## 완료 조건 (Acceptance Criteria)

- [x] AC1. `.agent/` 구조와 `PROGRESS.md`가 있다.
- [x] AC2. 정상 코드에서 스크립트가 네 단계를 모두 통과하고 종료 코드 0, `result: pass` 기록을 남긴다.
- [x] AC3. 일부러 깨뜨리면 각 단계가 잡는다 (확인 후 되돌림):
  - 빌드: 문법 오류 → build 단계 실패
  - 타입 검사: 경고만 생기는 코드 → build는 통과, typecheck 단계 실패
  - Lint: 컴파일 경고 없는 규칙 위반 → lint 단계 실패
  - 테스트: 로직을 바꾸면 해당 테스트가 실패 (URLTools, ContentBlocker, Settings 각각)
- [x] AC4. 실패하면 단계, 종료 코드, 오류 요약, 오류 서명이 jsonl에 기록된다.
- [x] AC5. 일부러 깨뜨리면 루프 제어가 작동한다:
  - 같은 오류 두 번 연속 → 종료 코드 4로 중단
  - 실패 횟수가 최대 재시도에 닿음 → 종료 코드 3으로 중단
  - TASK 시간 제한 초과 → 단계를 실행하지 않고 종료 코드 3
  - 단계 시간 제한 초과 → 해당 단계 실패로 기록, 남은 프로세스 없음
  - 중단된 뒤 다시 실행 → 거부, 승인 변수가 있을 때만 재개
- [x] AC6. 작업 뒤 앱 빌드와 동작에 변화가 없다 (Lint 기준을 맞추려고 고친 1줄 외에 앱 코드 변경 없음).

## 계획

1. `.agent/` 구조, 이 TASK 파일, PROGRESS.md 작성
2. `Package.swift`에 테스트 타깃 추가, `Tests/FeatherTests/` 작성
3. `.swift-format` 설정 (기존 스타일에 맞춤) 및 `AppDelegate.swift` 1줄 정리 (`return pendingURLs += urls` → 대입과 return 분리)
4. `scripts/auto-fix-loop.sh` 작성
5. 정상 통과 확인 → 단계별·제어별로 일부러 깨뜨려 확인 → 되돌림
6. README에 검증 방법 추가
7. 실제 TASK-001로 스크립트 실행, 완료 조건 확인

수정 대상 파일: `Package.swift`, `Tests/FeatherTests/*`, `.swift-format`, `scripts/auto-fix-loop.sh`, `Sources/Feather/AppDelegate.swift`(1줄), `README.md`, `.agent/*`

## 진행 기록

- 2026-11-06: `-strict-concurrency=complete`는 기존 코드에서 오류가 많이 나 범위 밖으로 판단, 타입 검사는 현재 언어 모드에서 `-warnings-as-errors`로 정함.
- 2026-11-06: 같은 `.build`에서 컴파일 플래그를 바꿔 가며 빌드하면 이전 플래그의 진단이 남는 현상을 봄. 검증 단계는 전용 경로 `.build/verify`를 쓰기로 함.
- 2026-11-06: swift-format 기본 규칙 중 기존 스타일과 충돌하는 규칙(ReplaceForEachWithForLoop, OneVariableDeclarationPerLine, NoAccessLevelOnExtensionDeclaration)은 끄고, NoAssignmentInExpressions는 켜 둔 채 해당 1줄을 고치기로 함.

- 2026-11-06: **문제** — `.swift-format`에 규칙을 일부만 적으면 적지 않은 규칙이 모두 꺼져 Lint가 사실상 아무것도 검사하지 않았다. 일부러 넣은 블록 주석이 통과해서 발견. 전체 규칙 목록(`swift format dump-configuration`)에 세 규칙만 끄는 설정으로 바꿈.
- 2026-11-06: **문제** — macOS 기본 bash 3.2에서 `$TASK는`처럼 변수 뒤에 한글이 붙으면 한글 일부를 변수 이름으로 읽어 `unbound variable`로 죽었다. 중단 거부 경로가 종료 코드 3 대신 1을 냄. `${TASK}`로 고침.
- 2026-11-06: **문제** — 중단 기록에 오류 요약이 중복으로 들어감. 중단 기록은 오류 없이 남기도록 고침.
- 2026-11-06: **문제** — 테스트 실패 메시지에 메모리 주소(`0x…`)가 들어가 같은 오류도 서명이 매번 달라질 수 있었다. 서명 계산 전에 주소를 지움.
- 2026-11-06: **문제** — 단계 시간 제한에 걸리면 `swift build`만 끝나고 컴파일러(swift-driver, swift-frontend)가 남았다. `swift build`가 컴파일러를 별도 프로세스 그룹으로 띄우기 때문. 프로세스 그룹 대신 하위 프로세스 트리를 모아 INT 뒤 KILL로 바꿈.
- 2026-11-06: 위 수정 뒤 모든 확인을 최종 스크립트로 다시 실행 (아래 표). 깨뜨린 파일은 매번 백업으로 되돌리고 `cmp`로 원본과 같음을 확인, 마지막에 깨뜨린 흔적을 grep으로 다시 확인.
- 2026-11-06: 실제 TASK-001로 실행 2회 모두 통과 (두 번째는 `.build/verify`를 지운 빈 캐시에서 11초). `--bench https://example.com`으로 앱이 뜨고 페이지를 여는 것 확인.

## 일부러 깨뜨려 확인한 결과

스크립트 자체 시험은 기록이 실제 작업 기록과 섞이지 않도록 임시 `AGENT_DIR`에서 했다.

| 확인 | 깨뜨린 내용 | 결과 |
|---|---|---|
| 빌드 | `URLTools.swift`에 닫는 괄호 삭제 | 종료 1, `step: build`, `expected ')'` 기록 |
| 타입 검사 | 쓰지 않는 변수 추가 (경고만 생김) | build 통과, 종료 1, `step: typecheck` |
| Lint (소스) | 블록 주석 추가 | 종료 1, `[NoBlockComments]` — **수정 전에는 못 잡음** |
| Lint (테스트) | `Array<Int>` 표기 | 종료 1, `[UseShorthandTypeNames]` |
| Lint (남겨 둔 규칙) | `AppDelegate`를 원래 `return pendingURLs += urls`로 | 종료 1, `[NoAssignmentInExpressions]` |
| 테스트: URLTools | 추적 파라미터 목록에서 `fbclid` 삭제 | `stripsTrackingParameters` 실패 |
| 테스트: 정규식 | 호스트 접두 정규식에서 `\.` 삭제 (비슷한 도메인까지 차단) | `leavesLookalikeHostsAlone` 실패 |
| 테스트: WebKit 컴파일 | 지원하지 않는 `(a\|b)` 규칙 추가 | `webKitCompilesTheRules` 실패 (WKErrorDomain 6) |
| 테스트: 기본값 | 메모리 예산 1024 → 1536 | `defaults` 실패 |
| 같은 오류 반복 | 같은 빌드 오류로 2회 / 메모리 주소가 든 테스트 오류로 2회 | 1회째 종료 1, 2회째 종료 4 `same_error` |
| 중단 뒤 재실행 | 정상 코드로 다시 실행 | 종료 3, 실행 거부 — **수정 전에는 종료 1로 죽음** |
| 승인 뒤 재개 | `AUTOFIX_APPROVED_RETRY=1` | `resumed` 기록 후 통과, 종료 0 |
| 최대 재시도 | `MAX_ATTEMPTS=2`, 서로 다른 오류 2회 | 2회째 종료 3 `max_attempts` |
| TASK 시간 제한 | 2시간 전 시도 기록을 넣고 실행 | 단계 실행 없이 종료 3 `time_limit` |
| 단계 시간 제한 | `STEP_TIMEOUT_SEC=2`, 재컴파일 유도 | 종료 코드 124로 실패 기록, 남은 프로세스 없음 — **수정 전에는 컴파일러가 남음** |
