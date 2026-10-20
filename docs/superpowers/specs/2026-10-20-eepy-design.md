# eepy: design

Date: 2026-10-20
Status: revised after two adversarial reviews (safety; logic and simplicity)

## Intent

Keep a MacBook awake with the lid closed, on battery, in a backpack or on a desk, for as long as Claude Code is doing work, and then let it sleep. The owner runs one or several Claude Code sessions (terminal or VS Code), closes the lid and walks off. Today the Mac sleeps on lid close and the work stops.

Keeping a closed Mac awake on battery means switching off a system-wide safety behaviour (`pmset disablesleep`). So eepy must be cautious: **better asleep than damaged**. Any doubt, including doubt caused by eepy's own bugs, ends in sleep. Logging must make it obvious afterwards whether a sleep came from a real trigger or from a failure in eepy, so failures can be fixed instead of silently costing work.

## Goals

- Main use cases reachable with one short command (`eepy`, `eepy 2h`).
- Lid closed, on battery: stays awake while any Claude session is truly working, including background shell commands, sub-agents and scheduled loops.
- Can run all day: idle gaps between Claude sessions never switch it off.
- Works with or without a time limit, and with or without Claude (plain keep-awake).
- Safety stops for heat, battery temperature, battery level, and optionally unplugging and Low Power Mode.
- Never leaves the Mac unable to sleep: not on Ctrl-C, closed terminal, hang, crash, kill, reboot or power loss.
- Clear, honest log of every decision.

## Non-goals

- No GUI, menu bar item or notifications. Terminal only.
- No config file. Defaults live at the top of the script.
- Safety thresholds are not configurable (for now).
- No work signal other than Claude Code (for now).
- No log rotation.

## Anti-goals (failure even if it "works")

- The Mac stays awake in a bag because eepy crashed, hung, was killed or misread a sensor.
- eepy puts the Mac to sleep while the owner is using it (lid open, or closed with a monitor attached).
- eepy switches itself off during the day because Claude was idle for a while, so it isn't there when the lid closes at 3pm.
- A sleep happens and the log can't say exactly why.
- Setup breaks something system-wide (sudo, Claude Code settings) or hands out more privilege than eepy needs.
- Over-engineering: more code, files or commands than the features need.

## Constraints and facts

Verified on this Mac (MacBook Pro Mac15,6, macOS 26.6, Apple Silicon, FileVault on, `powernap 1`) unless marked otherwise.

### Power

- `caffeinate` cannot prevent clamshell (lid-closed) sleep on battery. Only `pmset -a disablesleep 1` does, and it needs root. It is global and outlives the process that set it.
- While `disablesleep 1` is set, macOS also refuses its own sleeps: thermal emergency sleep, low-battery sleep, Apple menu Sleep and the power button (xnu `IOPMrootDomain.cpp`: `userDisabledAllSleep` is checked first in `checkSystemSleepAllowed`; to be confirmed on the device). **So whenever eepy holds, eepy is the only thing that can sleep the Mac for heat or battery.**
- Setting `disablesleep 0` with the lid closed does not by itself make the Mac sleep (xnu: clamshell sleep is only evaluated on a lid event). Idle sleep won't rescue it either, because Claude Code and other tools hold `caffeinate` assertions. **Every release with the lid closed must be followed by `pmset sleepnow`.**
- The real state is read with `ioreg -rn IOPMrootDomain -d 1` → `"SleepDisabled" = No|Yes`. `pmset -g` omits the line when it is 0, so it is not used for read-back.

### Sensors (no sudo needed)

- Lid: `ioreg -r -k AppleClamshellState -d 1` (Yes/No).
- OS thermal pressure: `osascript -l JavaScript -e 'ObjC.import("Foundation"); $.NSProcessInfo.processInfo.thermalState'` gives 0 nominal, 1 fair, 2 serious, 3 critical. `isLowPowerModeEnabled` is on the same object.
- Battery temperature: `ioreg -rn AppleSmartBattery`, the exact key `"Temperature" =` (read 3023 and 3038, taken to be hundredths of °C). Do not match `AverageTemperature` or `MaximumTemperature` inside `BatteryData`. This battery's lifetime maximum is 40°C.
- Battery % and power source: `pmset -g batt`.
- Chip temperature in degrees is not available from built-in tools on Apple Silicon, even with sudo. The OS thermal pressure level is the heat signal.

### Shell

- `jq` ships with macOS (`/usr/bin/jq`). `~/.local/bin` exists and is on PATH.
- zsh has `zsystem flock` (module `zsh/system`) and `$EPOCHSECONDS` (module `zsh/datetime`).
- macOS has no `timeout` command.
- zsh runs a TERM/HUP trap only after a foreground `sleep` returns. `sleep N & wait $!` lets the trap run at once.
- An EXIT trap set inside a zsh function fires when that function returns, so traps go at the top level.
- macOS `pgrep` hides its own ancestors by default, so use `ps`.

### Claude Code

- Claude Code runs `caffeinate -i -t 300` as a child while it works (observed, undocumented, not relied on). Several sessions can sit open and idle for days (7 seen here), so an open session does not mean work.
- Hook facts, from the official hooks docs and hooks guide (2026-10-20):
  - `Stop` fires when Claude finishes a turn, not on an Esc interrupt. Its input has `background_tasks` (each with `type` and `status`) and `session_crons`, "present when the task registry is reachable". API errors fire `StopFailure`.
  - `UserPromptSubmit` fires on typed prompts and on self-started turns: a cron or `/loop` firing, a background sub-agent reporting back, a cross-session message. Not on approving a permission prompt.
  - `PostToolUse` fires after each tool call succeeds, including after an approved tool and inside sub-agents (with `agent_id`).
  - `Notification` matchers include `permission_prompt`, `idle_prompt` and `elicitation_dialog`. `idle_prompt` comes about 60 seconds after Claude finishes, and only if the owner hasn't typed since and no background agent is still running.
  - AskUserQuestion and ExitPlanMode have no Notification of their own.
  - `SessionEnd` fires on exit, `/clear` and `/resume` (1.5 s budget); not on SIGKILL or a crash.
  - Every hook gets `session_id`. No hook gets the Claude process ID, but a hook in exec form (`args` instead of a shell command) is spawned directly by Claude, so its parent process is the Claude process.
  - A `Stop` hook that prints JSON can block Claude from stopping. eepy's hook must print nothing to stdout.
  - Hooks in `~/.claude/settings.json` apply to the terminal CLI and the VS Code extension, are reloaded by running sessions, and also fire in the Claude Desktop app.
  - A foreground Bash call is limited to 10 minutes by default.
- This Mac is company-managed (Intune, SentinelOne). The owner is an admin. `/etc/sudoers.d` is empty. No managed setting seen touches power or sudo.

## Concepts

- **Holding:** eepy has set `disablesleep 1`. Closing the lid will not sleep the Mac, and macOS's own heat and battery sleeps are blocked.
- **Released:** `disablesleep 0`, the normal Mac behaviour.
- **Attended / unattended:** attended means the lid reads open or at least one external display is detected. Anything else is unattended, including a lid reading that fails with no monitor detected. A lid that reads open is attended even if the display check fails, so eepy never sleeps a Mac that is in use.
- **Session states** (one per Claude Code session, written by hooks):
  - *working*: mid-turn;
  - *waiting*: turn ended with background work or scheduled loops pending;
  - *finished*: turn ended with nothing pending, or waiting for the owner (permission, question, plan approval, form), interrupted, errored.
- **Activity:** the time of the last prompt, tool call or `Stop`-with-pending-work in that session.
- **Active session:** its Claude process is alive (PID and start time match), its state is working or waiting, and its last activity was under **1 hour** ago. The 1-hour cap catches anything stuck: background work that never ends, a missed hook, an interrupt that `idle_prompt` didn't report. Work in progress refreshes activity on every tool call (foreground commands are capped at 10 minutes by Claude Code), so it is not cut off.
- **Trigger:** a reason to stop holding: heat, battery temperature, battery floor, `--unplug`, `--low-power`, or a reading that failed.
- **Stop:** eepy releases, sleeps the Mac if unattended, logs one reason and exits.

## Commands

```
eepy                  hold while any Claude session is active, until stopped
eepy 2h               same, for the next 2 hours only
eepy --no-claude      hold until stopped, ignoring Claude
eepy 2h --no-claude   hold for the next 2 hours, ignoring Claude
eepy --battery 10     battery floor 10% (default 20%)
eepy --unplug         also treat "on battery" as a trigger
eepy --low-power      also treat Low Power Mode as a trigger
eepy setup            one-time install
eepy uninstall        undo everything setup did
eepy hook             internal: called by Claude Code hooks
eepy watchdog         internal: called by the LaunchAgent every minute
```

Flags combine. The time limit always means "for the next N", counted from when eepy starts. eepy runs in the foreground of the terminal it was started in and prints its log lines there. Ctrl-Z is ignored.

Defaults at the top of the script (editable by the owner): battery floor 20%, unplug off, Low Power Mode off, grace period 2 minutes, check interval 30 seconds.

Hardcoded safety: thermal pressure "serious" (2) or worse, battery temperature 40°C or more, the 1-hour activity cap, fail closed on unreadable sensors, unattended when the lid can't be read, the watchdog and its 90-second heartbeat limit, read-back of every change.

## Behaviour

Every check (interval 30 s, slept with `sleep & wait`), eepy:

1. Reads lid, external display, real `SleepDisabled`, thermal pressure, battery %, battery temperature, power source, Low Power Mode and session states. Then it writes the heartbeat file.
2. **Time limit reached:** stop.
3. **Gap:** if it was holding and more than 3 check intervals passed since the last check (it hung, was suspended, or the Mac slept) and the Mac is now unattended: stop.
4. **Triggers while holding:**
   - unattended: stop. It does not re-arm, because macOS briefly wakes sleeping Macs in the background and re-arming then could leave the Mac awake in a bag;
   - attended: release, and don't hold again while the trigger lasts. This hands heat and battery protection back to macOS. eepy keeps running and never sleeps an attended Mac.
5. **Want to hold:** with `--no-claude`, always; otherwise, while any session is active, plus the 2-minute grace after the last one stops being active. Never while a trigger is true.
6. **Start holding** only when wanted, not already holding, and attended. eepy never starts holding while unattended, so a background wake in a bag can't re-arm it.
7. **Stop holding** when no longer wanted: release, and if unattended, `sleepnow`. This is the normal "Claude finished" path. eepy keeps running.

All release paths (stop, step 7, signal traps, watchdog) use one release routine: `sudo -n /usr/bin/pmset -a disablesleep 0`, read back through `ioreg` (anything other than a literal `No` counts as still held), then, if unattended, `sudo -n /usr/bin/pmset sleepnow` whatever the read-back said.

The real `SleepDisabled` is the truth about holding. Every check reads it first and takes it as eepy's holding state in both directions, logging FAILURE when it differs from what eepy expected. At start eepy adopts it the same way. So a failed release is retried on the next check, and a hold left behind by a crash or another tool is cleaned up. A stop whose release fails does not exit: eepy retries the release every check and exits once it succeeds.

On Ctrl-C, terminal close (HUP) or TERM: ignore further signals, release, then log, then exit. The traps are the first thing eepy sets up, before any output. Printing to a closed terminal must not kill eepy before it has released.

Only one eepy runs at a time (`zsystem flock` on a lock file, freed automatically when the process dies). A second one refuses and says why. eepy also refuses to start unless the sudo rule works without cached credentials (`sudo -k -n -l` for each of the three commands) and the watchdog LaunchAgent is loaded.

## Use cases

"Holds" means lid closing won't sleep the Mac. "Stops" means release, sleep if unattended, exit. "Lid closed" means unattended (no monitor).

### Everyday

1. **Main case.** Claude is working. The owner runs `eepy`, closes the lid and puts the Mac in a backpack on battery. It stays awake while Claude works. Two minutes after the last session stops being active, the Mac sleeps.
2. **Several sessions.** The Mac sleeps only once every session has stopped being active (plus grace).
3. **Background work.** Claude ends its turn with a background test run, background sub-agent or scheduled loop pending. The session is waiting, so it stays active. When the work completes, Claude picks up, finishes, and the Mac sleeps after grace.
4. **Background work that never ends** (dev server, file watcher, quiet monitor). After 1 hour with no activity from that session, it stops being active and the Mac sleeps after grace.
5. **A loop that wakes Claude often** (for example `/loop 10m`). Every run is activity, so the cap never fires. eepy holds until the time limit, a stop or Ctrl-C. Use `eepy 2h` to bound it.
6. **Claude needs the owner with the lid closed** (permission, a question, plan approval, an MCP form). The session is finished, so the Mac sleeps after grace. The prompt is waiting when the lid opens.
7. **Owner answers a prompt with the lid open.** The session becomes working again when Claude's next tool call completes.
8. **eepy started before any Claude session.** Nothing is held until a session is active with the Mac attended.
9. **eepy started, Claude never used.** eepy never holds. The Mac behaves normally. eepy runs until stopped or its time limit.
10. **All day.** `eepy` in the morning. Sessions come and go with gaps; with the lid open nothing visible happens. Lunch: the lid closes with nothing active, so the Mac sleeps normally and eepy carries on after it wakes. At 3pm the lid closes with Claude working, so it stays awake until Claude finishes, then sleeps. eepy is still running the next morning unless stopped.
11. **Time limit.** `eepy 2h`: as the main case, for the next 2 hours. At 2 hours eepy stops. If the lid is closed then, the Mac sleeps even if Claude is still working.
12. **Plain keep-awake.** `eepy 2h --no-claude`: closing the lid doesn't sleep the Mac for the next 2 hours, then eepy stops. `eepy --no-claude` holds until stopped or a stop.
13. **Lid open.** eepy never puts the Mac to sleep.
14. **Lid closed with an external monitor attached.** Treated as lid open. If the monitor is unplugged while the lid is closed, the Mac becomes unattended from the next check.
15. **Ctrl-C or closing the terminal.** Released at once (and slept if unattended). eepy exits.
16. **Sessions already open when setup ran.** They are picked up on their next prompt or tool call.

### Safety

17. **Heat in a backpack.** Thermal pressure reaches serious, or the battery reaches 40°C, while holding with the lid closed. Stop. Logged as TRIGGER with the reading and the limit.
18. **Heat at the desk** (for example a long compile with the lid open, or closed on a monitor). eepy releases and doesn't hold again until the heat drops, so macOS's own heat protection works. It never sleeps the Mac. If the lid closes meanwhile, the Mac sleeps normally.
19. **Battery floor.** On battery at or below 20% (or `--battery N`). Lid closed: stop. Lid open: release until charging or back above the floor. On mains power the floor is ignored.
20. **Unplugged.** Default: nothing happens. With `--unplug`, being on battery is a trigger: lid closed, stop; lid open, release while on battery.
21. **Low Power Mode.** Default: nothing happens. With `--low-power`, same pattern as unplugged.
22. **A sensor can't be read** while holding. Lid closed: stop, logged as FAILURE with the command and its error. Lid open: release until it reads again, logged as FAILURE. A failed lid read counts as lid closed unless a monitor is detected. A failed display read with the lid open counts as in use.
23. **eepy hangs, is suspended or is killed.** Its heartbeat stops. Within about 2.5 minutes at worst (90-second heartbeat limit plus the 60-second watchdog interval), the watchdog releases, sleeps the Mac if unattended, and logs FAILURE.
24. **Reboot or power loss while holding.** At login the watchdog releases and logs "found sleep still disabled", which means something went wrong last time.
25. **eepy resumes after a long gap** (it hung, the watchdog released and slept the Mac, and eepy runs again during a wake in the bag). Gap with the lid closed: stop.
26. **A background wake in the bag** after a "Claude finished" sleep, and a loop fires. eepy never starts holding while unattended, so the Mac goes back to sleep.
27. **Releasing fails** (`pmset` errors, or the read-back isn't `No`). Logged loudly as FAILURE, printed to the terminal. eepy keeps treating the Mac as held and retries every check, also trying `sleepnow` each time if unattended. The watchdog keeps trying too.
28. **Something else sets `disablesleep 1`** while eepy isn't running (another tool, or any process using the sudo rule). The watchdog undoes it within a minute and logs it.

### Claude session edge cases

29. **A session crashes, or its window is closed mid-turn.** Its process is gone, so it is dropped on the next check and its state file is deleted.
30. **Esc interrupt.** `idle_prompt` marks it finished about 60 seconds later. If that never comes (the owner started typing, or a background agent is running), the 1-hour cap catches it.
31. **Another plugin's Stop hook makes Claude carry on after `Stop`.** The session becomes working again at its next tool call. The grace period usually covers the gap.
32. **API error or usage limit.** `StopFailure` marks it finished. Claude's auto-continue resumes when the Mac next wakes.
33. **`/clear` or `/resume` inside a session.** The old state file is removed. The new session is picked up on its next event.
34. **Old idle sessions open for days.** Finished; they never keep the Mac awake.
35. **Claude Desktop app sessions.** Tracked only if a process named `claude` is found above the hook. Otherwise the hook writes nothing and logs it, so those sessions never keep the Mac awake.
36. **A second `eepy`** while one is running. Refuses and says one is already running.
37. **Known limit: approve and walk.** The owner approves a long command and closes the lid within 2 minutes. Until that command completes, the session looks finished, so the Mac may sleep mid-command. The work resumes when it wakes.

## Session tracking

Claude Code hooks call `eepy hook`, in exec form if Claude Code supports it. The hook reads the JSON on stdin and writes one small state file per session (keyed by `session_id`) holding: state, last activity (`$EPOCHSECONDS`), the Claude PID and that process's start time (`ps -o lstart=`). The Claude PID is the first process named `claude` found walking up from the hook's parent (one step in exec form).

| Hook | Writes |
|---|---|
| `UserPromptSubmit` | working, activity now |
| `PostToolUse` (all tools, sub-agents included) | working, activity now |
| `PreToolUse` (matcher `AskUserQuestion\|ExitPlanMode`) | finished |
| `Stop` | waiting with activity now if any `background_tasks` entry is running or pending, or `session_crons` is non-empty; finished if both are empty; finished and logged as "no task info" if either array is missing |
| `StopFailure` | finished |
| `Notification` (`permission_prompt`, `elicitation_dialog`) | finished |
| `Notification` (`idle_prompt`) | finished, **only if the current state is working** (never overwrites waiting) |
| `SessionEnd` | file removed |

Hook rules:

- Notification writes never refresh activity.
- Each file is written to a temp file outside the sessions folder and moved in, because hooks for parallel tool calls run at the same time and eepy deletes unparseable files in that folder.
- The hook always exits 0, prints nothing to stdout, never calls slow commands (`osascript`, `ioreg`), and finishes quickly. It must never be able to break or block Claude.
- If no Claude process is found above it, the hook writes nothing and logs it.

eepy reads the files every check. A file that can't be parsed counts as finished. A file whose process is dead (or whose start time no longer matches) is deleted.

## Watchdog

A **user** LaunchAgent (`RunAtLoad` plus every 60 seconds) runs `eepy watchdog`. If eepy's heartbeat file is missing or more than 90 seconds old, and `SleepDisabled` reads as anything other than a literal `No`, it runs the shared release routine (release, read back, `sleepnow` if unattended) and logs what it found as FAILURE. It uses only `ioreg`, `stat` and `sudo -n pmset`.

It runs as the owner, not root, so it can't be used to gain privilege, and it writes to the owner's log file. With FileVault on, nothing runs before the owner unlocks after a reboot anyway, and the agent's `RunAtLoad` covers the first moment after login.

## Logging

One plain-text log at `~/Library/Logs/eepy.log`. eepy also prints each line to its terminal, written separately rather than through a `tee` pipe. Every line has a timestamp. It records:

- **Start:** version, flags and every setting in force, including the hardcoded safety limits.
- **Each check while holding:** attended or not (lid, display), thermal pressure, battery %, battery temperature, power source, Low Power Mode, and each session's state and time since its last activity.
- **While released:** only changes in attended state or session states, to keep the log readable on all-day runs.
- **Every hold and release:** the `pmset` command, its result and the read-back value.
- **Hooks:** one line per session state change, so a wrong "finished" can be traced.
- **Stops and attended releases:** exactly one reason, labelled `TRIGGER` (reading and limit) or `FAILURE` (what failed and the error text). FAILURE covers unreadable sensors, failed releases, gaps, missing task info and every watchdog intervention. FAILURE means a bug or environment problem to fix.

## One-time setup (`eepy setup`) and `eepy uninstall`

`setup` first checks that a sudoers rule and a LaunchAgent can be installed on this managed Mac. If security tooling blocks either, it stops and says so. It asks for the password once, is safe to run again, and does four things:

1. Links `eepy` into `~/.local/bin`.
2. Writes a sudoers rule allowing the owner, without a password, exactly `/usr/bin/pmset -a disablesleep 0`, `/usr/bin/pmset -a disablesleep 1` and `/usr/bin/pmset sleepnow`. It checks a temp copy with `visudo -cf`, then installs it with `install -m 440 -o root -g wheel` to `/etc/sudoers.d/eepy`. A broken sudoers file can lock out sudo, so it never writes there directly.
3. Installs and loads the user LaunchAgent for the watchdog.
4. Merges the hooks into `~/.claude/settings.json`. It backs the file up first, aborts without writing on any `jq` error, keeps every existing setting and hook, and adds no duplicates.

eepy always calls `sudo -n`, so it never prompts mid-run. At start it checks the rule with `sudo -k -n -l` for all three commands, so cached credentials can't hide a missing rule, and refuses to run if not. Setup confirms the rule the same way.

`uninstall` refuses while eepy is running. Otherwise it releases if held, then removes exactly what setup added and nothing else, removing the watchdog last.

Known limit: the sudo rule lets any process running as the owner set `disablesleep 1`. The watchdog undoes that within a minute whenever eepy isn't running.

## Decided by the owner

- Terminal only. Least code, every feature, no over-engineering.
- Better asleep than damaged; cautious with `sudo pmset`.
- Stop triggers: heat, battery floor, time limit, Claude finished. Unplug and Low Power Mode are configurable, off by default.
- Claude Code is the work signal. Multiple sessions are supported. Background shell commands and sub-agents count as work.
- Waiting for permission counts as finished.
- Background work that never ends is capped at 1 hour with no activity.
- Lid closed with an external monitor attached counts as in use (the owner doesn't work that way today, but wants it handled).
- Must work with or without a time limit. `eepy 2h` means "for the next 2 hours".
- Must run all day without being switched off by gaps. eepy started before any session must work.
- Safety settings hardcoded for now. Other settings configurable.
- Main use cases easy to reach without many commands.
- Proper logging so that sleeps caused by bad code show up and can be fixed.
- Sudo for heat is acceptable (it turned out not to be needed).
- Adversarial review findings that don't need the owner are folded in without asking.

## Calls made by Claude (please check)

From the first draft:

- A single zsh script, using only built-in macOS commands (`pmset`, `ioreg`, `osascript`, `jq`).
- Thresholds: thermal pressure serious, battery 40°C, battery floor 20%, grace 2 minutes, checks every 30 seconds.
- Any stop ends eepy for good. "All sessions finished" does not.
- One eepy at a time.
- `--unplug` means "on battery is a trigger", not "the moment the cable is pulled".
- The battery floor applies only on battery.
- The sudoers rule is limited to the exact three `pmset` commands.
- No log rotation, and quiet logging while released.

Changed after the adversarial reviews:

- **The 1-hour cap now applies to working sessions too, not only waiting ones.** The owner had agreed that mid-turn work is never cut off. That intent still holds, because every tool call refreshes activity. This closes the paths where a session got stuck "working" forever (Esc then typing, another plugin's Stop hook, a missed event).
- **Triggers act whenever eepy holds, not only with the lid closed.** While eepy holds, macOS can't sleep itself for heat or low battery. With the lid open, a trigger now makes eepy release (never sleep) until it clears. With the lid closed, it still stops.
- **Every release with the lid closed is followed by `sleepnow`**, because releasing alone doesn't sleep a closed Mac.
- **eepy never starts holding while unattended**, so background wakes can't re-arm it.
- **The watchdog is a user LaunchAgent driven by a heartbeat**, not a root LaunchDaemon checking a PID. This catches hangs and suspends, removes a privilege-escalation path, and keeps the log owned by the owner.
- **Hooks added:** `PostToolUse` (working again after an approval, and a heartbeat during long turns), and `PreToolUse` for AskUserQuestion and ExitPlanMode (finished). `idle_prompt` no longer overwrites waiting.
- **The hook finds its Claude process** by walking up from its parent to the first `claude` process. In exec form that is one step; in shell form it still works.
- **The gap rule is now concrete:** more than 3 check intervals. It mainly guards against eepy coming back from a hang in a bag.
- **Lid or display unreadable counts as unattended**, except that a lid reading open is always attended.

Changed after the plan reviews:

- **Holding follows the real `SleepDisabled` in both directions**, every check and at start, so a failed release is retried and a stray hold is cleaned up. A failed stop keeps retrying instead of exiting.
- **`sleepnow` runs whenever unattended**, even if the release read-back failed.
- **eepy refuses to start** unless the sudo rule works without cached credentials and the watchdog is loaded.
- **Signal handling comes first** and ignores repeat signals while releasing.
- **`uninstall` refuses while eepy runs**, and removes the watchdog last.
- **Quieter logging while released:** only attended state and session states.

## Left to the builder

- Script layout, function names, duration parsing (`30m`, `2h`, `1h30m`).
- Where state, heartbeat and lock files live (under the owner's home).
- Exact log line format.
- External display detection method (cheap, no sudo).
- Smallest runnable self-check for the decision logic: hook JSON to session state, active-session rules, hold, release and stop decisions, triggers attended and unattended.

## Verify during build (unconfirmed)

Check these first, before building on them:

1. Security tooling allows the sudoers rule and the user LaunchAgent.
2. `sudo -n /usr/bin/pmset sleepnow` works with the lid closed and puts the Mac to sleep; releasing alone does not.
   - Result: deferred to the owner session (Task 11).
3. Hooks in exec form: the config syntax, that the parent is the Claude process, and its process name in the terminal and the VS Code extension.
   - Result: exec form `{"type":"command","command":"<abs path>","args":[]}` works. The hook's parent `comm` is `claude` (checked with `claude -p` only; interactive terminal and VS Code extension not yet checked).

Check these during the build:

4. `Stop` fires with `background_tasks` filled in when a turn ends while a background sub-agent runs, and which `status` values mean still running.
   - Result: confirmed for a background shell (`type` `shell`) and a background sub-agent (`type` `subagent`). Only `running` was seen while work was pending, and the final `Stop` had `background_tasks: []`, so a finished task simply drops out of the list. `session_crons` is present (`[]`). `SubagentStop` fires while the sub-agent is still listed as `running`, so rely on `Stop`, not `SubagentStop`.
5. `PostToolUse` fires after an approved tool and for sub-agent tool calls.
   - Result: confirmed. Sub-agent tool calls fire `PostToolUse` carrying `agent_id` and `agent_type`; the parent's own calls carry neither.
6. `idle_prompt` fires after an Esc interrupt.
7. Whether `permission_prompt` fires immediately or after a delay.
8. Whether `disablesleep` survives a reboot. Not tested on purpose; the watchdog covers it either way.
10. How long the `ioreg` read-back takes to show a change after `pmset`.
   - Result: deferred to the owner session (Task 11).
11. External display detection. The `IOMobileFramebufferShim` `external` flag is not usable: it reports 2 with no monitor attached. `system_profiler SPDisplaysDataType` takes about 0.2 s.
9. The battery `Temperature` unit (assumed hundredths of °C).
   - Result: deferred to the owner session (Task 11).

Pre-flight results (Task 1):

- HOOK_FORM: exec
- CLAUDE_NAME: claude
- RUNNING_STATUSES: `running` (the only status value seen). Finished work is absent from `background_tasks`, so treat any listed entry as still running and an empty list as finished.
