---
name: repeat-with-delay
description: Execute repeated shell commands as separate tool calls with a delay between each iteration. Use when a user asks to run something N times, wait between runs, increment a counter each cycle, and see each iteration result before the next run.
---

# Repeat With Delay

Run one command at a time as individual tool calls so each iteration is visible in the transcript.

## Required Execution Model

1. Determine loop parameters from the request:
- `iterations` (default `10`)
- `delay-seconds` (default `2`)
- `start` (default `1`)
- `command` (default `echo "$LOOP_COUNTER"`)

2. Execute iterations sequentially using separate tool calls:
- For each iteration, run one command tool call.
- Export the loop counter to that single call:
```bash
LOOP_COUNTER=<value> bash -lc '<command using $LOOP_COUNTER>'
```
- Show that tool call result before continuing.

3. If not on the final iteration and delay is greater than zero, run a separate sleep tool call:
```bash
sleep <delay-seconds>
```

4. Continue until iteration `N` is done. Do not batch iterations into one shell loop when the user wants per-iteration visibility.

## Example Mapping

For "run 10 times and delay for 2 seconds between each", execute:
- 10 separate command tool calls (`LOOP_COUNTER=1` to `LOOP_COUNTER=10`)
- 9 separate sleep tool calls (`sleep 2`) between runs

For "echo a number starting at 1 and increment each time":
```bash
LOOP_COUNTER=1 bash -lc 'echo "$LOOP_COUNTER"'
LOOP_COUNTER=2 bash -lc 'echo "$LOOP_COUNTER"'
...
```

## Notes

- Keep loop execution sequential; do not parallelize iterations unless explicitly requested.
- Preserve command failures; if one iteration fails, stop and report the failing iteration.
- Optional fallback script exists at `scripts/run_repeat_with_delay.sh`, but use it only if the user explicitly asks for one single wrapper command.
