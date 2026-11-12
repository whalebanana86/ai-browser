# TASK-006 Hy-MT2 1.8B 로컬 번역 실측 (조사)

- 상태: COMPLETED (2026-11-12) — 1.25비트는 사용자 결정으로 제외
- 요청: "번역기능은 로컬llm Hy-MT2 1.8B 이거 받아서 사용하는걸로 되는지 검토" → "로컬에 설치되어 있을거야 찾아보고 할일 진행해"

## 요구사항
1. 이미 받아 둔 모델(`~/Library/Application Support/AITranslate/Models/hy-mt2-1.8b-4bit`, MLX 4비트)을 그대로 쓴다. 모델 파일은 수정·이동하지 않는다.
2. 실제 웹페이지 본문을 문단 단위로 번역해, 페이지 전체 시간·첫 문단 시간·메모리를 잰다.
3. (추가 요청) LLM 모델 메모리는 Feather와 따로 계산한다: 모델을 별도 프로세스로 돌리고 그 프로세스의 physical footprint를 잰다.
4. (추가 요청) 1.25비트 버전(`tencent/Hy-MT2-1.8B-1.25Bit-GGUF`)을 받아 비교한다. 엔진 차이를 가르려고 같은 llama.cpp(PR #22836, STQ 커널)에서 공식 Q4_K_M GGUF와 함께 잰다. 모델은 `~/Library/Application Support/Feather/Models/`에 둔다.
5. Feather에 넣는 방식(빌드, 메모리 예산)을 판단할 근거를 남긴다. 앱 코드는 바꾸지 않는다.

## 완료 조건
- [x] AC1. 영어 페이지 2개 이상에서 영→한 번역 시간(전체·첫 문단)과 최대 메모리 측정
- [x] AC2. 한→영 1개 측정, 번역 결과 표본 기록
- [x] AC4. MLX 4bit·Q4_K_M 비교 완료. **변경(사용자 결정 2026-11-12):** 1.25bit는 "사용안할게" — 비교에서 제외 MLX 4bit / llama.cpp Q4_K_M / llama.cpp 1.25bit 세 가지를 같은 문단으로 비교: 모델 프로세스 메모리(적재 후·번역 중 최대), 속도, 번역 표본
- [x] AC3. Feather 통합 방식 권고(빌드 제약, 메모리 예산과의 관계) 기록

## 진행 기록
- 2026-11-12: 모델 발견 — AITranslate가 받아 둔 `mlx-community/Hy-MT2-1.8B-4bit`(970MB). LICENSE.txt: Apache-2.0, 지역 제한 없음. AITranslate 기록(TASK-017 등)에 문단 단위 실측 있음: MLX 초당 101~121토큰, 긴 문단 1.1초, 메모리 약 1~1.2GB.
- 2026-11-12: 시스템 Python 3.9의 transformers가 오래돼 MLX 토크나이저(TokenizersBackend)를 못 읽음 → Python 3.14 가상환경으로 다시.
- 2026-11-12: 측정 환경 — M5, 메모리 24GB. 문단은 위키백과 본문 `<p>`(40자 이상): en1 "Web browser" 21문단 9,400자, en2 "WebKit" 33문단 14,376자, ko1 "웹 브라우저" 19문단 4,759자. 문단마다 한 번씩 번역, 모델 카드 권장 샘플링(0.7/0.6/20/1.05). 모델 메모리는 모델을 돌리는 프로세스의 physical footprint(활동 상태 보기 "메모리"와 같은 값)를 50ms 간격으로 따로 측정.
- 2026-11-12: llama.cpp PR #22836 받아 빌드하려던 실행이 자동 승인 검사("Code from External")로 차단 — 정당. 확인 결과 그 PR은 **병합되지 않은 열린 PR**이고 "ggml-cpu: add STQ1_0 ternary quantization with ARM NEON vec_dot kernel", 즉 **CPU 전용** 커널. Homebrew llama.cpp 0.9.0에도 없음. 1.25비트 모델 파일(462MB, Apache-2.0)만 `~/Library/Application Support/Feather/Models/`에 받아 둠. 설치된 공식 Ollama로는 불러오지 못함("failed to validate GGUF").
- 2026-11-12: Ollama 첫 측정은 무효 — 이 GGUF의 채팅 템플릿이 Ollama에 없어(기능: completion만) 번역 대신 코드·JSON을 생성, 문맥 기본값 262K로 메모리 2.2~4.4GB. 모델 템플릿으로 만든 프롬프트를 raw로 보내고 문맥 4096으로 다시 측정.
- 2026-11-12: llama.cpp는 모델(1.1GB)을 메모리 매핑 파일로 올려 physical footprint에 안 잡힘(적재 후 footprint 339MB, RSS 1,427MB, vmmap mapped file 1.1G 상주). 실제 사용량은 footprint + 약 1.1GB로 계산.
- 2026-11-12: MLX에 GPU 캐시 상한(128MB)을 걸어도 최대 메모리 변화 없음(1.54~1.74GB) — 늘어나는 원인이 캐시가 아님.
- 2026-11-12: 품질 — 표본은 대체로 자연스러움. 결함 1건: MLX 결과에 "파이어폭스"가 "파이어ف렌"(아랍 문자 섞임)으로 나옴. 문자 체계 섞임 검사·재시도 필요.

## 측정 결과 (모델 메모리는 Feather와 별도, 모델 프로세스만)

| 엔진 | 적재 직후 | 번역 중 최대 | 속도 | 첫 문단 | 페이지 전체 (en1 / en2 / ko1) |
|---|---|---|---|---|---|
| MLX 4bit (`mlx-community/Hy-MT2-1.8B-4bit`, 970MB) | 1,197MB | 1,537~1,737MB | 초당 104토큰 | 0.75~1.2초 | 35.7 / 51.3 / 19.3초 |
| Ollama(llama.cpp) Q4_K_M (1.13GB) | 약 1,430MB (RSS) | footprint 691~1,585MB + 매핑 1.1GB ≈ 1.8~2.7GB | 초당 93토큰 | 0.96~1.6초 | 39.5 / 57.2 / 22.5초 |
| 1.25bit GGUF (462MB) | — | — | — | — | 실행 못 함 (CPU 전용 미병합 PR 필요) |

## Feather 통합 권고
- 엔진: MLX(`mlx-swift-lm`, AITranslate가 `hunyuan_v1_dense` 지원을 확인하고 3.32.3으로 고정). llama.cpp보다 약 10% 빠르고 메모리 계산이 정직(매핑 파일로 숨지 않음).
- 프로세스: 모델은 Feather 밖의 별도 도우미 프로세스에서, 번역할 때만 띄우고 쓰지 않으면 몇 분 뒤 종료. 모델 메모리(약 1.2~1.75GB)는 탭 메모리 예산(1GB)과 따로 표시·관리.
- 화면: 페이지 전체가 20~60초라, 보이는 문단부터 차례로 바꿔 넣음. 첫 문단은 약 1초.
- 빌드: Feather는 지금 `swift build`만 씀. MLX는 Metal 셰이더가 필요해 AITranslate처럼 Xcode 빌드(`xcodebuild`)와 Metal 툴체인이 필요할 것으로 보임 — 도우미를 별도 Xcode 타깃으로 두면 브라우저 본체는 그대로 유지 가능. 실제 빌드로 확인 필요.
- 2026-11-12: 사용자 결정 — 1.25비트 사용 안 함, MLX 기반 번역 구현으로 진행(TASK-007). 받아 둔 1.25비트 파일(462MB)은 지우지 않고 둠.
