#!/bin/bash
# 검증 게이트. 빌드 → 타입 검사 → Lint → 테스트를 한 번 실행하고, 결과를
# .agent/attempts/TASK-ID.jsonl에 한 줄로 남긴다. 한 번 실행이 한 번의 시도다.
# 실패하면 원인을 고친 뒤 다시 실행하고, 제한에 걸려 중단되면 더 실행하지 않는다.
#
# 사용법: ./scripts/auto-fix-loop.sh [TASK-ID]   (생략하면 .agent/PROGRESS.md의 현재 작업)
#
# 종료 코드
#   0  모든 단계 통과
#   1  검증 실패 — 고친 뒤 다시 실행
#   2  사용법 오류 (TASK를 찾을 수 없음 등)
#   3  중단 — 최대 재시도 횟수나 시간 제한 초과, 또는 이미 중단된 TASK
#   4  중단 — 직전 실패와 같은 오류가 반복됨
#
# 설정 (환경 변수)
#   MAX_ATTEMPTS=5           TASK 하나에서 허용하는 실패 횟수
#   TIME_LIMIT_MIN=60        TASK의 첫 시도부터 이 시간이 지나면 중단
#   STEP_TIMEOUT_SEC=900     단계 하나의 실행 시간 제한
#   AUTOFIX_APPROVED_RETRY=1 중단된 TASK를 사용자 승인 뒤 다시 시작할 때만 설정
#   AGENT_DIR=.agent         기록 위치 (이 스크립트 자체를 시험할 때만 바꾼다)
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)

MAX_ATTEMPTS=${MAX_ATTEMPTS:-5}
TIME_LIMIT_MIN=${TIME_LIMIT_MIN:-60}
STEP_TIMEOUT_SEC=${STEP_TIMEOUT_SEC:-900}
AGENT_DIR=${AGENT_DIR:-.agent}
VERIFY_BUILD=.build/verify   # 플래그가 다른 빌드와 캐시를 섞지 않도록 전용 경로
LOG_DIR=.build/verify-logs

# 줄 배치·들여쓰기 항목. 기존 코드가 Xcode식 정렬 들여쓰기를 써서 swift-format 배치와 맞지 않으므로
# 이것들만 빼고, 나머지 코드 규칙은 모두 검사한다.
LINT_LAYOUT='\[(Indentation|AddLines|RemoveLine|LineLength|Spacing|TrailingComma|TrailingWhitespace)\]'

die() { echo "auto-fix-loop: $*" >&2; exit 2; }

# ---------- TASK 확인 ----------
TASK=${1:-}
if [[ -z "$TASK" ]]; then
    [[ -f "$AGENT_DIR/PROGRESS.md" ]] || die "$AGENT_DIR/PROGRESS.md가 없습니다. TASK-ID를 인자로 주세요."
    TASK=$(grep -m1 '현재 작업' "$AGENT_DIR/PROGRESS.md" | grep -oE 'TASK-[A-Za-z0-9_-]+' | head -1)
    [[ -n "$TASK" ]] || die "PROGRESS.md에서 현재 작업 ID를 찾지 못했습니다."
fi
[[ "$TASK" =~ ^TASK-[A-Za-z0-9_-]+$ ]] || die "TASK-ID 형식이 아닙니다: $TASK"
[[ -f "$AGENT_DIR/tasks/$TASK.md" ]] || die "$AGENT_DIR/tasks/$TASK.md가 없습니다."
mkdir -p "$AGENT_DIR/attempts" "$LOG_DIR"
RECORDS="$AGENT_DIR/attempts/$TASK.jsonl"
touch "$RECORDS"

# ---------- 기록 ----------
# 인자: key=value(문자열) 또는 key:=value(숫자). errors는 ERRORS 변수(줄바꿈 구분)에서 읽는다.
record() {
    ERRORS=${ERRORS:-} python3 -I -c '
import json, os, sys, time
entry = {"ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "epoch": int(time.time())}
for arg in sys.argv[1:]:
    if ":=" in arg:
        key, value = arg.split(":=", 1); entry[key] = int(value)
    else:
        key, value = arg.split("=", 1); entry[key] = value
raw = os.environ["ERRORS"].encode("utf-8", "surrogateescape").decode("utf-8", "replace")
errors = [line[:300] + ("…" if len(line) > 300 else "") for line in raw.splitlines() if line.strip()]
if errors:
    entry["errors"] = errors
print(json.dumps(entry, ensure_ascii=False))' "$@" >>"$RECORDS"
}

# 마지막 재개(resumed) 이후의 기록만 센다.
current_records() {
    awk '/"result": "resumed"/ { n = NR } { line[NR] = $0 } END { for (i = n + 1; i <= NR; i++) print line[i] }' "$RECORDS"
}
field() { sed -nE "s/.*\"$1\": \"?([^\",}]*)\"?.*/\1/p"; }

# ---------- 중단 상태와 제한 ----------
last_result=$(tail -n 1 "$RECORDS" | field result)
if [[ "$last_result" == "stopped" ]]; then
    if [[ "${AUTOFIX_APPROVED_RETRY:-}" == "1" ]]; then
        record task="$TASK" result=resumed reason=user_approved
        echo "중단됐던 ${TASK}를 사용자 승인으로 다시 시작합니다. 실패 횟수와 시간 제한을 새로 셉니다."
    else
        reason=$(tail -n 1 "$RECORDS" | field reason)
        echo "중단: ${TASK}는 이미 중단된 작업입니다 (사유: $reason). 임의로 재시도하지 않습니다."
        echo "      사용자 승인을 받은 경우에만 AUTOFIX_APPROVED_RETRY=1로 다시 실행하세요."
        exit 3
    fi
fi

now=$(date +%s)
failures=$(current_records | grep -c '"result": "fail"')
attempt=$(( $(current_records | grep -cE '"result": "(pass|fail)"') + 1 ))
first_epoch=$(current_records | grep -E '"result": "(pass|fail)"' | head -n 1 | field epoch)
if [[ -n "$first_epoch" ]] && (( now - first_epoch > TIME_LIMIT_MIN * 60 )); then
    record task="$TASK" result=stopped reason=time_limit limit_min:="$TIME_LIMIT_MIN"
    echo "중단: ${TASK}의 첫 시도부터 ${TIME_LIMIT_MIN}분이 지났습니다. 원인과 현재 상태를 TASK 파일에 적고 보고하세요."
    exit 3
fi
if (( failures >= MAX_ATTEMPTS )); then
    record task="$TASK" result=stopped reason=max_attempts limit:="$MAX_ATTEMPTS"
    echo "중단: ${TASK}의 실패가 이미 ${MAX_ATTEMPTS}회입니다."
    exit 3
fi

# ---------- 단계 실행 ----------
# swift build는 컴파일러를 별도 프로세스 그룹으로 띄우므로, 시간이 다 되면 하위 프로세스 트리를
# 먼저 모은 뒤 함께 끝낸다. INT로 정리할 기회를 주고, 남은 것은 KILL.
descendants() {
    local child
    for child in $(pgrep -P "$1"); do
        echo "$child"
        descendants "$child"
    done
}

run_with_timeout() {
    local log=$1; shift
    rm -f "$log.timeout"
    "$@" >"$log" 2>&1 &
    local pid=$!
    (
        sleep "$STEP_TIMEOUT_SEC"
        touch "$log.timeout"
        tree="$pid $(descendants "$pid")"
        kill -INT $tree 2>/dev/null
        sleep 3
        kill -KILL $tree 2>/dev/null
    ) &
    local watchdog=$!
    wait "$pid" 2>/dev/null
    local status=$?
    if [[ -f "$log.timeout" ]]; then
        wait "$watchdog" 2>/dev/null   # 남은 프로세스를 KILL할 때까지 기다린다
        rm -f "$log.timeout"
        return 124
    fi
    # 제때 끝났으면 감시 프로세스와 그 sleep을 거둔다.
    kill $(descendants "$watchdog") "$watchdog" 2>/dev/null
    wait "$watchdog" 2>/dev/null
    return "$status"
}

lint() {
    local output status
    output=$(swift format lint --configuration .swift-format --recursive Sources Tests Package.swift 2>&1)
    status=$?
    printf '%s\n' "$output" | grep -vE "$LINT_LAYOUT" | grep -E 'warning:|error:'
    # swift-format 자체 오류(파싱 실패 등)이거나 배치 외 위반이 하나라도 있으면 실패
    [[ $status -eq 0 ]] && ! printf '%s\n' "$output" | grep -vE "$LINT_LAYOUT" | grep -qE 'warning:|error:'
}

# 실패 로그에서 오류 줄을 뽑아, 줄·열 번호와 경로를 지워 같은 오류를 알아볼 수 있게 한다.
error_lines() {
    local log=$1
    { grep -E 'error:|warning: \[|✘|recorded an issue|failed' "$log" || tail -n 20 "$log"; } |
        grep -vE '^[[:space:]]*\||^[[:space:]]*[0-9]+ \|' |
        sed -E "s#$ROOT/##g; s#$HOME#~#g" |
        sed -E 's/(\.swift):[0-9]+(:[0-9]+)?/\1/g; s/ after [0-9.]+ seconds//; s/\(?[0-9.]+s\)?$//; s/0x[0-9a-fA-F]+/0x?/g' |
        sed -E 's/((token|password|passwd|secret|api[_-]?key)[^[:space:]]*[[:space:]]*[:=][[:space:]]*)[^[:space:]]+/\1***/Ig' |
        awk '!seen[$0]++'
}

STEPS="build typecheck lint test"
started=$(date +%s)
failed_step="" status=0
for step in $STEPS; do
    log="$LOG_DIR/$step.log"
    echo "▶ $step"
    case $step in
        build) run_with_timeout "$log" ./build.sh ;;
        typecheck) run_with_timeout "$log" swift build --scratch-path "$VERIFY_BUILD" -Xswiftc -warnings-as-errors ;;
        lint) run_with_timeout "$log" lint ;;
        test) run_with_timeout "$log" swift test --scratch-path "$VERIFY_BUILD" -Xswiftc -warnings-as-errors ;;
    esac
    status=$?
    if (( status != 0 )); then
        failed_step=$step
        break
    fi
done
duration=$(( $(date +%s) - started ))

if [[ -z "$failed_step" ]]; then
    ERRORS="" record task="$TASK" attempt:="$attempt" result=pass duration_sec:="$duration"
    echo "✓ 통과: 빌드, 타입 검사, Lint, 테스트 (${duration}초, 시도 $attempt)"
    exit 0
fi

log="$LOG_DIR/$failed_step.log"
if (( status == 124 )); then
    all_errors="${failed_step} 단계가 ${STEP_TIMEOUT_SEC}초 안에 끝나지 않음"
else
    all_errors=$(error_lines "$log")
fi
# 서명은 오류 전체로(병렬 테스트는 출력 순서가 바뀌므로 정렬), 기록에는 앞의 8줄만 남긴다.
signature="$failed_step:$(printf '%s\n' "$all_errors" | sort | shasum -a 1 | cut -c1-12)"
ERRORS=$(printf '%s\n' "$all_errors" | head -n 8)
previous=$(current_records | grep '"result": "fail"' | tail -n 1 | field signature)
failures=$((failures + 1))
ERRORS="$ERRORS" record task="$TASK" attempt:="$attempt" result=fail step="$failed_step" exit_code:="$status" \
    duration_sec:="$duration" signature="$signature"

echo "✗ 실패: $failed_step 단계 (종료 코드 $status, 시도 $attempt, 실패 $failures/$MAX_ATTEMPTS)"
printf '%s\n' "$ERRORS" | sed 's/^/    /'
echo "  전체 로그: $log"

if [[ "$signature" == "$previous" ]]; then
    ERRORS="" record task="$TASK" result=stopped reason=same_error signature="$signature"
    echo "중단: 직전 실패와 같은 오류가 반복됐습니다. 원인과 시도한 방법을 TASK 파일에 적고 보고하세요."
    exit 4
fi
if (( failures >= MAX_ATTEMPTS )); then
    ERRORS="" record task="$TASK" result=stopped reason=max_attempts limit:="$MAX_ATTEMPTS"
    echo "중단: 실패가 최대 재시도 횟수(${MAX_ATTEMPTS}회)에 닿았습니다. 원인과 현재 상태를 TASK 파일에 적고 보고하세요."
    exit 3
fi
exit 1
