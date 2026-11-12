# TASK-015 AITranslate 모델 연동 끊기, 실제 내려받기 시험

- 상태: COMPLETED (2026-11-12)
- 요청: "AITranslate가 받아둔 모델 연동한거 끊고 실제 내려받기 테스트해봐"
## 요구사항
1. 모델 찾는 곳에서 AITranslate 폴더를 뺀다(설정 `translationModelPath`와 Feather 폴더만).
2. 이 Mac에서 모델이 없는 상태를 확인하고, 앱 창의 실제 처리 경로(묻기→동의→내려받기→번역)로 실제 Feather 모델 폴더에 내려받아 번역까지 확인한다. 받은 모델은 남긴다.
## 완료 조건
- [x] AC1. 테스트: AITranslate 폴더에 모델이 있어도 찾지 않음(깨뜨리면 실패).
- [x] AC2. 실제 시험: 내려받기 전 모델 없음 → 묻기 1회 → 받기 → 해시 통과 → `Settings.translationModel`이 Feather 폴더 → 실제 페이지 번역.
- [x] AC3. auto-fix-loop, README, 재설치, 커밋.
## 진행 기록
- 2026-11-12: 모델 찾는 곳에서 AITranslate 폴더 제거(`Settings.translationModel(support:override:)`로 시험 가능하게). 깨뜨리기 L1(AITranslate 폴더 다시 추가) → `onlyFeathersOwnModelIsUsed` 실패로 잡힘.
- 2026-11-12: 실제 첫 사용 시험(`RealFirstUseTests`, 필요할 때만): 시작 전 Feather 모델 폴더에 모델 없음 확인 → 창의 번역 명령 → 묻기 1회 → 동의 → `~/Library/Application Support/Feather/Models/hy-mt2-1.8b-4bit`에 실제 내려받기(985MB) → 해시 8개 통과 → 그 페이지 번역 "첫 번째 번역에서는 모델을 다운로드한 다음 이 문장을 번역합니다." 명령부터 번역까지 26초. 받은 모델은 남김(앱이 쓰는 위치).
- 2026-11-12: auto-fix-loop 통과(125개, 필요할 때만 켜는 실제 테스트 3개는 건너뜀).
