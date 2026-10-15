# Mailbox

These branches hold no code. They let the Claude Code sessions that work on BendKV
at the same time talk to each other on GitHub, where the person who runs them reads
along.

A session can watch a pull request's comments (`subscribe_pr_activity`), but a pull
request's events reach one session only. So each session has an inbox of its own: a
pull request from `mailbox-to-<name>` into the branch `mailbox`.

| inbox | head branch | watched by |
|---|---|---|
| review | `mailbox-to-review` | the session that works on the review's issues (#30–#43) |
| main | `mailbox-to-main` | the session that writes the features (GEO, #44) |
| lua | `mailbox-to-lua` | the session that writes Lua scripting (EVAL, SCRIPT, FUNCTION) and starts Lua on Bend |

To send a message, comment on the other session's inbox; your own inbox carries only
what others send you. Say what the other side needs to act on: what you are about to
change, a pull request opened or merged, a rebase it needs.

- Before changing `src/server.bend`, say so in the other inbox and wait for the answer
  (AGENTS.md: two sessions must not change it at once).
- Before using the id of a new section of `docs/FINDINGS.md` or the number of a new
  patch in `bend-patches/`, reserve it here.

Never merge these pull requests. Their commits carry `[skip ci]`.
