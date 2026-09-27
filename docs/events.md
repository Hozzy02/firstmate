# Task transition ledger

`state/events.ndjson` is the append-only source for task status transitions and PR cycle timing in a firstmate home.
Each line is one JSON object, written when a complete, nonblank line appears in `state/<task-id>.status` or a PR is registered or merged.
The status files retain their existing line format and remain the input for live supervision.
The ledger is always enabled for new writes, and a worker's status command records its line immediately while the watcher recovers lines written through other paths.

Every record has `v` (currently `1`), `id`, `event`, `task`, `ts`, and `time_source`.
For `task.status`, `id` is a stable SHA-256 identity for the task id, status-file identity, byte position, and full line, so replay after a retry or restart does not create another record for the same line.
For `task.pr_ready` and `task.merged`, `id` identifies the task id, event type, and full PR URL, so recording the same PR event again does not create a duplicate.
`task` is the stable firstmate task id.
`ts` is UTC Unix seconds from a well-formed `[at=<epoch>]` tag in a status line, and `time_source` is `status` in that case.
For an older or malformed line without a usable tag, `ts` is the time the line was captured and `time_source` is `capture`; that time is only an upper bound for when the transition occurred.
For PR events, `ts` is the time firstmate recorded the event and `time_source` is `recorded`.
The `task.status` members are `state`, the leading status verb or `null`; `key`, its `[key=...]` value or `null`; and `line`, the complete status line without its terminating newline.
The PR event member `pr` is the full URL.
Consumers measuring durations should use `time_source=status` for both endpoints and treat captured times as uncertain.
PR cycle time is the interval between the matching `task.pr_ready` and `task.merged` records.

```json
{"v":1,"id":"e2f98049b450af72e7649941323cb0d9cc30f47c2c9bb9c953d16d959479bd99","event":"task.status","task":"fix-login","ts":1790132870,"time_source":"status","state":"working","key":null,"line":"working [at=1790132870]: bug reproduced"}
```

The writer captures only newline-terminated lines and saves a cursor after appending the records.
It checks existing event ids before replaying after an interrupted write, so repeated capture and watcher restarts converge without duplicates.
Records are appended in capture order, which can differ from `ts` order when an older line is recovered later.
The ledger contains status text with the same access sensitivity as the status files, is never rotated automatically, and does not backfill logs removed before this writer ran.
`bin/fm-events.sh` owns capture mechanics and its command interface.
