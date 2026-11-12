# TASK-008 자동완성 제거 + 앱 새로 설치

- 상태: COMPLETED (2026-11-12)
- 요청: "앱 새로설치해주고 자동완성 제거해"
- 해석: Feather에는 별도 자동완성 기능이 없음 → macOS의 인라인 자동완성(회색 예측 입력)과 텍스트 자동 완성을 주소창·찾기 칸·웹페이지 입력 칸에서 끈다. 설치는 `/Applications/Feather.app`.

## 완료 조건
- [x] AC1. 주소창·찾기 칸: 자동 텍스트 완성 끔, 인라인 예측은 창의 공용 편집기(field editor)에서 끔(`NSTextField`에는 그 속성이 없고 `NSTextView`에 있음). 웹뷰: `allowsInlinePredictions = false`.
- [x] AC2. 테스트로 고정, 일부러 깨뜨리면 실패.
- [x] AC3. auto-fix-loop 통과, `/Applications/Feather.app` 설치·서명 검증·실행 확인.

## 진행 기록
- 2026-11-12: 처음엔 `NSTextField.inlinePredictionType`을 썼다가 컴파일 오류 — SDK 헤더 확인 결과 그 속성은 `NSTextView`(공용 편집기)에 있음. 창 생성 때 공용 편집기에서 끄도록 변경. 웹뷰는 `WKWebViewConfiguration.allowsInlinePredictions = false`.
- 2026-11-12: 깨뜨리기 A1(공용 편집기 설정 제거)·A2(단어 완성 켬)·A3(웹 인라인 예측 켬) 모두 실패로 잡힘. auto-fix-loop 통과(테스트 102개).
- 2026-11-12: 실행 중이던 build/ Feather를 Apple Events로 정상 종료(세션 저장) → `ditto`로 `/Applications/Feather.app` 설치(43MB, 번역 도우미 포함) → `codesign --verify --strict --deep` 통과 → 실행 확인.
