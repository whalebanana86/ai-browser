# TASK-007 MLX 기반 페이지 번역 (Hy-MT2 1.8B 4bit)

- 상태: COMPLETED (2026-11-12)
- 요청: "mlx기반 번역 기능 구현으로 넘어가" (TASK-006 측정 근거)

## 요구사항
1. (추가 요청) 툴바 번역 버튼(왼쪽 클릭)과 페이지 오른쪽 클릭 메뉴에서도 번역할 수 있다. 페이지 안의 그냥 왼쪽 클릭은 링크와 부딪혀 쓰지 않는다.
1-2. (추가 요청) 한 번 켜면 그 탭은 끌 때까지 계속 번역한다: 나중에 생기는 글과 이동한 다음 페이지까지.
1-3. 보기 › 이 페이지 번역(⌥⌘T)으로 지금 페이지를 번역하고, 다시 누르면 원문으로 돌아간다.
2. 번역은 Mac 안에서만 한다: Hy-MT2-1.8B MLX 4bit. 모델 위치는 `~/Library/Application Support/Feather/Models/hy-mt2-1.8b-4bit`, 없으면 AITranslate가 받아 둔 `~/Library/Application Support/AITranslate/Models/hy-mt2-1.8b-4bit`를 읽기만. 설정 `translationModelPath`로 바꿀 수 있음. 모델이 없으면 안내만 하고 내려받지 않는다.
3. 모델은 Feather 밖의 별도 도우미 프로세스(`FeatherTranslator`)에서 돌린다. 번역할 때만 띄우고, 2분 동안 안 쓰면 끝낸다. 앱이 끝나면 함께 끝낸다.
4. 모델 메모리는 탭 메모리 예산(1GB)에 넣지 않고 따로 잰다. 메모리 감시가 도우미를 탭 메모리로 세지 않는다. 툴바 상태 설명에 "번역 모델 … (탭 메모리와 별도)"로 보인다.
5. 화면에 보이는 문단부터 번역해 차례로 바꿔 넣는다. 진행 상황을 상태 표시에 보인다. 다른 페이지로 가거나 원문으로 되돌리면 멈춘다.
6. 문단 구조(링크 등 안쪽 요소)는 원문으로 되돌릴 때 원래 노드 그대로 돌아온다(이벤트 처리기 유지).
7. 페이지 스크립트와 분리된 콘텐츠 월드에서 글을 모으고 바꾼다. 입력 칸·코드·편집 영역·비밀번호는 번역하지 않는다.
8. 프롬프트·특수 토큰 무력화·길이 상한·시간 제한·출력 정리는 AITranslate(MIT, 같은 저자) 방식을 따른다. 번역 결과에 원문·대상 언어에 없는 문자 체계(예: 아랍 문자)가 섞이면 한 번 다시 번역한다.
9. 페이지 언어는 macOS NaturalLanguage로 판단한다. 대상 언어는 시스템 첫 언어(한국어면 Korean). 이미 대상 언어인 페이지는 번역하지 않는다.
10. 브라우저 본체는 지금처럼 `swift build`로 빌드한다. 도우미만 Metal이 필요한 MLX 때문에 `xcodebuild`로 빌드해 앱 번들(`Contents/Helpers`)에 넣는다.

## 완료 조건
- [x] AC1. 도우미가 빌드되고, 앱 번들에 들어가며, 실제 모델로 문단을 번역한다(통합 확인).
- [x] AC2. 프롬프트·무력화·길이·정리·문자 체계 검사 단위 테스트.
- [x] AC3. 실제 WebKit에서 글 모으기(제외 대상, 보이는 순서), 바꿔 넣기, 원문 복원(같은 노드) 테스트 — 가짜 번역기로.
- [x] AC4. 도우미 프로세스 관리 테스트 — 가짜 도우미로: 요청·응답, 시간 제한, 도우미가 죽었을 때 복구, 유휴 종료, 메모리 측정에서 제외.
- [x] AC5. (메뉴 ⌥⌘T·검증·토글 연결. 다른 페이지로 가면 중단은 PageTranslator 테스트로 확인) 창 연결: 메뉴 ⌥⌘T, 토글, 다른 페이지로 가면 중단.
- [x] AC6. 새 테스트는 일부러 깨뜨리면 실패 — 확인 후 되돌림.
- [x] AC7. auto-fix-loop 통과, README 반영(모델 메모리 별도 표기).

## 진행 기록
- 2026-11-12: `Translator/`(도우미 패키지, MLX) 소스 작성. `xcodebuild`로 패키지를 받아 빌드하려던 실행이 자동 승인 검사("Code from External")로 차단 — 실행 안 됨. 도우미는 아직 빌드·실행되지 않음(AC1 미충족).
- 2026-11-12: Feather 쪽 구현 — `Translation.swift`: HyMTPrompt(AITranslate 방식), ScriptCheck(측정된 "파이어ف렌" 실수 검사·1회 재시도), TranslationLanguage(NaturalLanguage), TranslatorProcess(별도 프로세스, 줄 단위 JSON, 요청별 시간 제한·멈추면 종료, 죽으면 다음 요청에서 재시작, 2분 유휴 종료), PageText(별도 콘텐츠 월드, 보이는 문단 먼저, 원래 노드 그대로 복원), PageTranslator. `MemoryMeter.sample(excluding:)`·`MemoryGovernor.measure`가 도우미를 탭 메모리에서 뺌, 상태 설명에 "번역 모델 … (탭 메모리와 별도)". 보기 › 이 페이지 번역 ⌥⌘T, 앱 종료 시 도우미 종료.
- 2026-11-12: 테스트 97개 처음부터 통과 → 일부러 깨뜨리기 시작했는데 모두 Lint에서 먼저 실패: 새 코드에 한 줄 여러 `case`(OneCasePerLine) 위반. 고친 뒤 다시 실행.
- 2026-11-12: 가짜 도우미는 테스트가 임시 폴더에 쓰는 Python 스크립트(같은 통신 규칙)로, 정상/멈춤/죽음/모델 불러오기 실패를 흉내.
- 2026-11-12: auto-fix-loop 통과(시도 1).
- 남은 빈틈(테스트 없음): `MemoryGovernor.measure`가 `TranslatorProcess.shared.pid`를 넘기는 한 줄. 메뉴 제목 "원문 보기" 전환은 활성 탭이 네트워크 페이지라 테스트에서 확인 못 함.

## 일부러 깨뜨려 확인한 결과

| # | 깨뜨린 내용 | 결과 |
|---|---|---|
| U01 | 특수 토큰 무력화 끔 | `pageTextCannotForgeChatTokens` 실패 |
| U02 | 아랍 문자 판별 제거 | `catchesTheMeasuredArabicSlip` 실패 |
| U03 | 문자 체계 섞이면 재시도 안 함 | `retriesOnceWhenAnUnrelatedScriptSlipsIn` 실패 |
| U04 | 편집 영역도 번역 | `collectsBlocks…` 실패 |
| U05 | 바깥 블록도 함께 번역(중복) | `collectsBlocks…` 실패 |
| U06 | 복원 때 복제 노드를 넣음 | `replacesTextAndRestoresTheVerySameNodes` 실패 |
| U07 | 페이지 월드에서 실행 | `pageScriptsCannotSeeTheTranslationState` 실패 |
| U08 | 시간 초과 때 도우미를 안 끝냄 | `stuckGenerationTimesOutAndRestarts` 실패 |
| U09 | 유휴 종료 안 함 | `idleHelperIsEndedToFreeTheModel` 실패 |
| U10 | 메모리 측정에서 도우미를 안 뺌 | `answersRequestsAndStaysOutOfTabMemory` 실패 |
| U11 | 번역 직후 페이지 바뀜 검사 제거 | 통과 — 동등 변경: 다음 문단 전에 같은 검사가 있고, 새 페이지엔 번역 대상 표시가 없어 넣을 곳을 못 찾음 |
| U12 | 이미 대상 언어인 페이지 판별 끔 | `leavesPagesAlreadyInTheTargetLanguage` 실패 |
(처음 T01·T03·T12는 타입 검사가 먼저 잡아 컴파일되게 다시 깨뜨림)

## 중단 상태 (재개용)
- 현재 상태: Feather 쪽 완료·검증. 도우미(Translator/) 소스만 있음, 빌드 안 됨
- 실패 원인: 외부 패키지 받기·빌드가 자동 승인 검사에서 차단(사용자 허락 필요)
- 다음 행동: 사용자가 `./build.sh translator` 실행(또는 권한 규칙 추가) 후 `cd Translator && xcodebuild -scheme FeatherTranslator -destination 'platform=macOS,arch=arm64' -configuration Release -derivedDataPath .build-xcode build` → build.sh에서 `Contents/Helpers/`에 도우미와 `mlx-swift_Cmlx.bundle` 복사 → 실제 모델로 페이지 번역 확인 → README → 완료
- 2026-11-12: 추가 요청 반영 — 툴바 번역 버튼(켜지면 채운 아이콘), 페이지 오른쪽 클릭 메뉴 항목, 탭 단위 계속 번역(1.5초마다 새 글 확인, 다음 페이지 포함, 모델이 실패하면 스스로 끄고 알림). 이미 대상 언어인 페이지·글 없는 페이지도 켜진 상태 유지. 테스트를 "페이지 바뀌면 멈춤"에서 "새 글·다음 페이지도 번역, 끄면 더 안 함"으로 바꿈. 깨뜨리기 V1(따라가기 안 함)·V4(실패해도 켜진 채)·V5(페이지 메뉴 없음)·V6(툴바 버튼 없음) 모두 잡힘.
- 2026-11-12: 사용자 "단계 진행해" 뒤 도우미 빌드 재시도 → 다시 자동 승인 검사에서 차단(사유 미공개). 대화 속 허락으로는 통과하지 않음 → 사용자가 직접 `./build.sh translator`를 실행하거나 권한 규칙을 추가해야 함.
- 2026-11-12: build.sh에 `translator` 단계 추가(xcodebuild 후 `Contents/Helpers/`에 도우미와 `*.bundle` 복사, 도우미 따로 서명). 도우미가 없으면 지금처럼 빌드. README 반영. auto-fix-loop 통과(테스트 99개).
- 2026-11-12: 사용자가 직접 `./build.sh translator` 실행 → 도우미 빌드 성공. build.sh는 종료 코드 1: 앱 서명 때 `Contents/Helpers/*.bundle`(리소스 번들)을 서명 안 된 하위 코드로 봄. 번들·도우미를 안쪽부터 서명하도록 고침 → `codesign --verify --strict --deep` 통과. 앱 크기 43MB.
- 2026-11-12: 실제 도우미 단독 확인 — 모델 적재 3.24초, 문단 1개 0.81초("웹 브라우저는 웹사이트에 접속하는 데 사용되는 애플리케이션입니다.").
- 2026-11-12: 실제 모델 통합 테스트(`RealModelTests`, `FEATHER_REAL_MODEL=1`일 때만) — 글 모으기→실제 도우미 번역→바꿔 넣기: 4문단 5.6초(적재 포함), 모델 메모리 1,117MB, 탭 메모리 측정에서 제외 확인. 깨뜨리기: 대상 언어를 영어로 바꾸면 "한글 없음"으로 실패 확인 후 되돌림. 평소 auto-fix-loop에서는 건너뜀(100개 통과, 1개 건너뜀).
