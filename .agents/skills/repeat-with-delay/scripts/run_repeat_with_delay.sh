#!/usr/bin/env bash
set -euo pipefail

iterations=10
delay_seconds=2
start=1
command='echo "$LOOP_COUNTER"'

usage() {
  cat <<'EOF'
Usage:
  run_repeat_with_delay.sh [--iterations N] [--delay-seconds S] [--start N] [--command CMD]

Options:
  --iterations N      Number of loop iterations (default: 10)
  --delay-seconds S   Sleep duration between iterations in seconds (default: 2)
  --start N           Starting counter value (default: 1)
  --command CMD       Bash command to run each iteration. Access counter via $LOOP_COUNTER.
  -h, --help          Show this help message
EOF
}

is_non_negative_int() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --iterations)
      [[ $# -lt 2 ]] && { echo "Missing value for --iterations" >&2; exit 1; }
      iterations="$2"
      shift 2
      ;;
    --delay-seconds)
      [[ $# -lt 2 ]] && { echo "Missing value for --delay-seconds" >&2; exit 1; }
      delay_seconds="$2"
      shift 2
      ;;
    --start)
      [[ $# -lt 2 ]] && { echo "Missing value for --start" >&2; exit 1; }
      start="$2"
      shift 2
      ;;
    --command)
      [[ $# -lt 2 ]] && { echo "Missing value for --command" >&2; exit 1; }
      command="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if ! is_non_negative_int "$iterations" || [[ "$iterations" -lt 1 ]]; then
  echo "--iterations must be an integer >= 1" >&2
  exit 1
fi

if ! is_non_negative_int "$delay_seconds"; then
  echo "--delay-seconds must be an integer >= 0" >&2
  exit 1
fi

if ! [[ "$start" =~ ^-?[0-9]+$ ]]; then
  echo "--start must be an integer" >&2
  exit 1
fi

counter="$start"
for ((iteration = 1; iteration <= iterations; iteration++)); do
  LOOP_COUNTER="$counter" bash -lc "$command"

  if (( iteration < iterations )) && (( delay_seconds > 0 )); then
    sleep "$delay_seconds"
  fi

  ((counter++))
done
