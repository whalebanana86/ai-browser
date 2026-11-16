# TASK-023 문서 뷰어: 문서 링크를 다운로드 대신 탭에서 보기

- 상태: COMPLETED (2026-11-16)
- 요청: "문서뷰어도 추가해줘" → 질문 답: "웹 문서를 탭에서 바로 보기", 형식은 PDF, Word·Excel·PowerPoint, HWP, 이미지·텍스트·기타 모두. HWP는 별도 TASK-024.

## 요구사항
- 본 화면 이동이 다운로드가 될 상황(첨부 지정이거나 WebKit이 못 보여 주는 형식)이고 파일이 문서 형식이면 다운로드 대신 탭 안 뷰어로 연다. 숨은 프레임 다운로드(Gmail 버튼)와 zip·dmg 같은 비문서는 지금처럼 다운로드.
- 뷰어: macOS 미리보기(Quick Look) 사용, 외부 전송 없음. 상단 막대에 파일 이름, "다운로드"(다운로드 폴더에 저장·기록), "다른 앱에서 열기"(저장 후 열기), "닫기". 뒤로(⌘[)도 닫기. 주소창에 문서 주소, 탭 제목은 파일 이름.
- 문서는 앱 캐시 폴더(`~/Library/Caches/Feather/Documents`)에만 두고, 닫거나 탭이 잠들면 지우고, 앱 시작 때 남은 것 정리.

## 완료 조건
- [x] AC1. 첨부 Word 문서·형식 모를 Excel 링크는 뷰어로 열리고 다운로드 폴더엔 안 생김, zip 첨부는 다운로드 — 미리보기 분기를 빼면 실패
- [x] AC2. 뷰어에 Quick Look이 그 파일로 뜨고 주소·제목이 문서 기준, 뒤로/닫기로 페이지 복귀·캐시 파일 삭제 — 각각 깨뜨리면 실패
- [x] AC3. "다운로드" 버튼은 다운로드 폴더에 복사·기록 — 빼면 실패
- [x] AC4. auto-fix-loop 통과

## 진행 기록
- 2026-11-16: 확인 — 이 Mac은 Office(docx·xlsx·pptx·csv 등)를 Quick Look(Office.qlgenerator)으로 미리 볼 수 있고 HWP용은 없음 → HWP는 TASK-024에서 직접 읽기.
- 2026-11-16: 구현 — `DocumentViewer.swift`(형식 판정·캐시 폴더·`PreviewDownload`·`DocumentViewerView`(막대+QLPreviewView)). Tab: 본 화면 응답이 미리보기 대상이면 `.download`로 받아 캐시에 저장 후 `document` 설정, `goBack`/`closeDocument`, 잠들면 닫음, 주소·제목은 문서 기준. 창: 뷰어를 페이지 위에, 다운로드 버튼은 `Downloads.saveCopy`(기록·격리 속성), 앱 시작 때 캐시 정리.
- 2026-11-16: 깨뜨리기 M1 분기 없음, M2 Quick Look 미설정, M3 뒤로가 안 닫음, M4 캐시 남김, M5 다운로드 버튼 무동작, M6 뷰어가 페이지 아래(층 순서 검사 추가 후), M7 프레임도 미리보기, M8 탭 변경 때 갱신 안 함 — 모두 잡힘, 되돌림.
- 2026-11-16: auto-fix-loop 시도 1 실패 — 전체 테스트에서 DocumentViewerTests와 FrameDownloadTests가 동시에 전역 `Downloads.shared`를 바꿔 끼워 서로의 파일이 섞임. 전역 교체를 없애고 탭이 창의 `downloads`(TabDelegate)를 쓰게 바꿈(`shared`는 상수로). 관련 깨뜨리기(TASK-021 M1~M4, 이번 M1·M5) 재확인 잡힘. 시도 2 통과.
