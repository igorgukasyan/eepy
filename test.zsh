#!/bin/zsh
# eepy self-check. `zsh test.zsh [t_name ...]` runs groups; `zsh test.zsh child <args>` runs eepy under the stubs.
TEST_FILE=${0:A}
EEPY_SRC=${TEST_FILE:h}/eepy
typeset -gA PS_PPID PS_COMM PS_LSTART

is() {
  if [[ "$1" != "$2" ]]; then
    print -r -- "FAIL $GROUP $3: got '$1', want '$2'"
    (( FAILS++ ))
  fi
}

# Stubs. Defined after sourcing eepy so they override its functions. Nothing here can reach real sudo or pmset.
define_stubs() {
  sudo() {
    [[ " $* " == *" -l "* ]] && return ${SUDO_L_RC:-0}
    CALLS+=("$*")
    print -r -- "$*" >> $EEPY_HOME/calls
    if (( ${SUDO_RC:-0} == 0 )); then
      [[ "$*" == *"disablesleep 1"* ]] && ROOT_OUT='"SleepDisabled" = Yes'
      [[ "$*" == *"disablesleep 0"* ]] && ROOT_OUT='"SleepDisabled" = No'
    fi
    return ${SUDO_RC:-0}
  }
  ioreg() {
    case "$*" in
      *AppleClamshellState*) print -r -- "$LID_OUT" ;;
      *AppleSmartBattery*) print -r -- "$BATT_OUT" ;;
      *IOPMrootDomain*) print -r -- "$ROOT_OUT" ;;
    esac
  }
  pmset() { [[ "$*" == *"-g batt"* ]] && print -r -- "$PMSET_BATT"; return 0 }
  osascript() { print -r -- "$OS_OUT" }
  ps() {
    local f=${2%=} pid=$4
    case $f in
      ppid) (( $+PS_PPID[$pid] )) || return 1; printf '%5s\n' $PS_PPID[$pid] ;;
      comm) (( $+PS_COMM[$pid] )) || return 1; print -r -- "$PS_COMM[$pid]" ;;
      lstart) (( $+PS_LSTART[$pid] )) || return 1; print -r -- "$PS_LSTART[$pid]" ;;
      *) return 1 ;;
    esac
  }
  launchctl() { return ${AGENT_RC:-0} }
  read_displays() { print -r -- "${DISPLAYS:-0}" }
}

default_state() {
  LID_OUT='"AppleClamshellState" = No'
  DISPLAYS=0
  ROOT_OUT='"SleepDisabled" = No'
  OS_OUT='0 0'
  BATT_OUT='"Temperature" = 3038'
  PMSET_BATT="Now drawing from 'Battery Power'
 -InternalBattery-0 (id=1234567)	57%; discharging; 5:00 remaining present: true"
  CALLS=()
}

load_eepy() {
  source $EEPY_SRC
  define_stubs
  now() { print -r -- $NOW }
  (( $+functions[sudo] )) || { print -u2 "test.zsh: sudo stub missing, aborting"; exit 99 }
  default_state
}

if [[ $1 == child ]]; then
  shift
  source $EEPY_SRC
  define_stubs
  (( $+functions[sudo] )) || { print -u2 "test.zsh: sudo stub missing, aborting"; exit 99 }
  default_state
  main "$@"
  exit $?
fi

# ---- groups ----
t_durations() {
  is "$(parse_duration 30m)" 1800 30m
  is "$(parse_duration 2h)" 7200 2h
  is "$(parse_duration 1h30m)" 5400 1h30m
  local bad; for bad in 90 0m 2H 1h30 '' h m 0h0m; do
    parse_duration "$bad" >/dev/null && is accepted rejected "duration '$bad'"
  done
}
t_args() {
  parse_args;                                                  is "$CMD $LIMIT $NOCLAUDE $FLOOR $UNPLUG $LOWPOWER" "run 0 0 20 0 0" defaults
  parse_args 2h --no-claude --battery 10 --unplug --low-power; is "$CMD $LIMIT $NOCLAUDE $FLOOR $UNPLUG $LOWPOWER" "run 7200 1 10 1 1" all-flags
  parse_args;                                                  is "$LIMIT $FLOOR $UNPLUG" "0 20 0" resets-between-calls
  DEFAULT_FLOOR=30; parse_args;                                is "$FLOOR" 30 owner-edited-default
  parse_args setup;                                            is "$CMD" setup setup
  parse_args --nope 2>/dev/null      && is accepted rejected unknown-flag
  parse_args --battery 0 2>/dev/null && is accepted rejected battery-0
  parse_args 90 2>/dev/null          && is accepted rejected duration-without-unit
}
t_log() {
  log hello > $EEPY_HOME/out; is "$(<$EEPY_HOME/out)" "" file-only-by-default
  grep -q '^[0-9-]\{10\} [0-9:]\{8\} hello$' $EEPY_LOG || is missing present log-format
  LOG_TTY=1; is "$(log hi)" "$(tail -1 $EEPY_LOG)" tty-copy
}
t_proc_start() {
  PS_LSTART=(4000 'Tue Oct 20 13:33:01 2026    ' 4001 'Tue  Oct 20 13:33:01 2026')
  is "$(proc_start 4000)" 'Tue Oct 20 13:33:01 2026' trims-trailing
  is "$(proc_start 4001)" 'Tue Oct 20 13:33:01 2026' squeezes
  is "$(proc_start 4999)" '' unknown-pid
}
t_now_real() {
  local n; n=$(zsh -fc "source $EEPY_SRC; now")
  [[ $n == <1000000000-9999999999> ]] || is "$n" "a 10-digit epoch" real-now
}
t_readers() {
  local closed='    "AppleClamshellState" = Yes' open='    "AppleClamshellState" = No'
  LID_OUT=$open;   DISPLAYS=0;   is "$(read_attended)" 1 lid-open
  LID_OUT=$closed; DISPLAYS=0;   is "$(read_attended)" 0 lid-closed
  LID_OUT=$closed; DISPLAYS=1;   is "$(read_attended)" 1 uc14-closed-with-monitor
  LID_OUT='';      DISPLAYS=0;   is "$(read_attended)" 0 uc22-lid-unreadable
  LID_OUT='';      DISPLAYS=1;   is "$(read_attended)" 1 lid-unreadable-with-monitor
  LID_OUT=$closed; DISPLAYS='?'; is "$(read_attended)" 0 display-unreadable-lid-closed
  LID_OUT=$open;   DISPLAYS='?'; is "$(read_attended)" 1 uc13-open-mac-never-unattended
  ROOT_OUT='      "SleepDisabled" = No';  is "$(read_held)" 0 released
  ROOT_OUT='      "SleepDisabled" = Yes'; is "$(read_held)" 1 held
  ROOT_OUT='';                            is "$(read_held)" 1 unreadable-counts-as-held
  BATT_OUT=$'      "Temperature" = 3038\n      "BatteryData" = {"AverageTemperature"=2900,"MaximumTemperature"=40}'
  is "$(read_temp)" 3038 exact-temperature-key
  BATT_OUT='      "VirtualTemperature" = 2909'; is "$(read_temp)" '?' temperature-missing
  PMSET_BATT=$'Now drawing from \'Battery Power\'\n -InternalBattery-0 (id=1)\t57%; discharging; 3:53 remaining present: true'
  is "$(read_batt)" "57 battery" on-battery
  PMSET_BATT=$'Now drawing from \'AC Power\'\n -InternalBattery-0 (id=1)\t80%; charging; 0:40 remaining present: true'
  is "$(read_batt)" "80 ac" on-mains
  PMSET_BATT='';  is "$(read_batt)" "? ?" battery-unreadable
  OS_OUT='2 1';   is "$(read_os)" "2 1" os
  OS_OUT='';      is "$(read_os)" "? ?" os-unreadable
}

t_trigger() {
  FLOOR=20 UNPLUG=0 LOWPOWER=0
  is "$(trigger 0 3038 57 battery 0)" "" calm
  is "$(trigger 2 3038 57 battery 0)" "TRIGGER heat: thermal pressure 2 (limit 2)" uc17-serious
  is "$(trigger 3 3038 57 battery 0)" "TRIGGER heat: thermal pressure 3 (limit 2)" critical
  is "$(trigger 1 4000 57 battery 0)" "TRIGGER battery temperature 40.00°C (limit 40.00°C)" uc17-hot-battery
  is "$(trigger 1 3999 57 battery 0)" "" just-under-40
  is "$(trigger 0 3038 20 battery 0)" "TRIGGER battery 20% (floor 20%)" uc19-floor
  is "$(trigger 0 3038 15 ac 0)" "" uc19-floor-ignored-on-mains
  is "$(trigger 0 3038 57 battery 1)" "" uc21-lpm-off-by-default
  UNPLUG=1;   is "$(trigger 0 3038 57 battery 0)" "TRIGGER on battery (--unplug)" uc20-unplug
              is "$(trigger 0 3038 57 ac 0)" "" uc20-on-mains
  UNPLUG=0 LOWPOWER=1
              is "$(trigger 0 3038 57 ac 1)" "TRIGGER Low Power Mode on (--low-power)" uc21-lpm
              is "$(trigger 0 3038 57 ac '?')" "FAILURE Low Power Mode unreadable" lpm-unreadable
  LOWPOWER=0; is "$(trigger 0 3038 57 ac '?')" "" lpm-unread-ignored-when-off
  is "$(trigger '?' 3038 57 battery 0)" "FAILURE thermal pressure unreadable" uc22-thermal
  is "$(trigger 0 '?' 57 battery 0)"    "FAILURE battery temperature unreadable" uc22-temp
  is "$(trigger 0 3038 '?' '?' 0)"      "FAILURE battery level unreadable" uc22-batt
}
t_decide() {
  #            holding attended want tripped gap timeup
  is "$(decide 0 1 1 0 0 0)" hold    uc1-start-attended
  is "$(decide 0 0 1 0 0 0)" stay    uc26-never-arm-unattended
  is "$(decide 1 0 1 0 0 0)" stay    uc1-lid-closed-working
  is "$(decide 1 0 0 0 0 0)" release uc1-finished
  is "$(decide 1 1 0 0 0 0)" release uc10-idle-at-desk
  is "$(decide 1 0 1 1 0 0)" stop    uc17-heat-in-bag
  is "$(decide 1 1 1 1 0 0)" pause   uc18-heat-at-desk
  is "$(decide 0 1 1 1 0 0)" stay    uc18-no-rehold-while-tripped
  is "$(decide 0 0 0 1 0 0)" stay    trigger-while-released-is-ignored
  is "$(decide 1 0 1 0 1 0)" stop    uc25-gap-in-bag
  is "$(decide 0 0 1 0 1 0)" stop    uc25-gap-after-watchdog-released
  is "$(decide 1 1 1 0 1 0)" stay    gap-attended-carries-on
  is "$(decide 0 1 0 0 0 1)" stop    uc11-time-limit
}

t_hook_next() {
  local s='{"hook_event_name":"Stop","session_crons":[],"background_tasks":'
  is "$(hook_next '{"hook_event_name":"UserPromptSubmit"}' finished)"                        "working 1"  prompt
  is "$(hook_next '{"hook_event_name":"PostToolUse","tool_name":"Bash"}' finished)"          "working 1"  uc7-after-approval
  is "$(hook_next '{"hook_event_name":"PostToolUse","tool_name":"Read","agent_id":"a"}' waiting)" "working 1" uc3-subagent-tool
  is "$(hook_next '{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion"}' working)" "finished 0" uc6-question
  is "$(hook_next '{"hook_event_name":"PreToolUse","tool_name":"ExitPlanMode"}' working)"    "finished 0" uc6-plan
  is "$(hook_next '{"hook_event_name":"PreToolUse","tool_name":"Bash"}' working)"            "keep 0"     other-pretooluse
  is "$(hook_next "$s"'[]}' working)"                                                        "finished 0" uc1-stop
  is "$(hook_next "$s"'[{"id":"t","type":"shell","status":"running"}]}' working)"           "waiting 1"  uc3-stop-background
  is "$(hook_next "$s"'[{"id":"t","type":"subagent","status":"running"}]}' working)"        "waiting 1"  uc3-stop-subagent
  is "$(hook_next "$s"'[{"id":"t","type":"shell","status":"completed"}]}' working)"         "finished 0" stop-background-done
  is "$(hook_next '{"hook_event_name":"Stop","background_tasks":[],"session_crons":[{"id":"c"}]}' working)" "waiting 1" uc3-stop-cron
  is "$(hook_next '{"hook_event_name":"Stop"}' working)"                                     "finished 0" stop-no-task-info
  is "$(hook_next '{"hook_event_name":"StopFailure"}' working)"                              "finished 0" uc32-api-error
  is "$(hook_next '{"hook_event_name":"Notification","notification_type":"permission_prompt"}' working)"  "finished 0" uc6-permission
  is "$(hook_next '{"hook_event_name":"Notification","notification_type":"elicitation_dialog"}' working)" "finished 0" uc6-form
  is "$(hook_next '{"hook_event_name":"Notification","notification_type":"idle_prompt"}' working)"        "finished 0" uc30-esc
  is "$(hook_next '{"hook_event_name":"Notification","notification_type":"idle_prompt"}' waiting)"        "keep 0"     idle-never-overwrites-waiting
  is "$(hook_next '{"hook_event_name":"SessionEnd"}' working)"                               "rm 0"       uc33-end
}
t_claude_pid() {
  PS_PPID=(4242 4100 4100 4000 4000 1); PS_COMM=(4242 /bin/zsh 4100 zsh 4000 claude)
  is "$(claude_pid 4242)" 4000 walks-up-through-padded-ppids
  is "$(claude_pid 4000)" 4000 direct-parent
  PS_COMM=(4242 /bin/zsh 4100 zsh 4000 launchd)
  is "$(claude_pid 4242)" "" uc35-stops-at-pid-1
  PS_PPID=(5 6 6 5); PS_COMM=(5 zsh 6 zsh)
  is "$(claude_pid 5)" "" cycle-capped
}
t_hook() {
  claude_pid() { print 4000 }; PS_LSTART=(4000 'Tue Oct 20 13:33:01 2026    '); NOW=1000
  local f=$EEPY_HOME/sessions/s1 out
  out=$(print -r '{"hook_event_name":"UserPromptSubmit","session_id":"s1"}' | hook); is "$out" "" no-stdout
  is "$(<$f)" $'working\n1000\n4000\nTue Oct 20 13:33:01 2026' state-written
  NOW=2000; print -r '{"hook_event_name":"Notification","notification_type":"permission_prompt","session_id":"s1"}' | hook
  is "$(head -2 $f)" $'finished\n1000' notification-keeps-activity
  is "$(ls -A $EEPY_HOME/sessions)" s1 no-temp-files-in-sessions
  print -r '{"hook_event_name":"SessionEnd","session_id":"s1"}' | hook; [[ -e $f ]] && is present removed session-end
  print -r 'not json' | hook; is $? 0 garbage-returns-0
  print -r '{"hook_event_name":"UserPromptSubmit"}' | hook; is "$(ls -A $EEPY_HOME/sessions)" "" no-session-id
  claude_pid() { }; print -r '{"hook_event_name":"UserPromptSubmit","session_id":"s2"}' | hook
  [[ -e $EEPY_HOME/sessions/s2 ]] && is written ignored uc35-no-claude
  grep -q 'no claude process found' $EEPY_LOG || is missing logged no-claude-logged
}

t_sessions() {
  local d=$EEPY_HOME/sessions; mkdir -p $d
  mk() { print -rl -- $2 $3 $4 "$5" > $d/$1 }
  PS_LSTART=(4000 'L1    ' 4001 'L2 ')         # real ps output has trailing spaces
  scan_sessions 1500; is $ACTIVE 0 empty
  mk a working  1000 4000 L1      # active
  mk b waiting  1000 4001 L2      # uc3 active
  mk c finished 1000 4000 L1      # uc34 not active, kept
  mk d working  1000 4999 L9      # uc29 dead process
  mk e working  1000 4001 OTHER   # pid reused
  print garbage > $d/f            # unparseable
  scan_sessions 1500; is $ACTIVE 2 two-active
  is "$(ls $d | tr '\n' ' ')" "a b c " dead-reused-garbage-deleted
  is "$REPORT" "a working 500s, b waiting 500s, c finished 500s" report
  scan_sessions 4599; is $ACTIVE 2 uc4-just-under-cap
  scan_sessions 4600; is $ACTIVE 0 uc4-cap-reached
  rm -rf $d; scan_sessions 1500; is "$ACTIVE" 0 missing-dir
  mkdir -p $d
  mk g working 9999 4000 L1       # future activity: kept, not active
  mk h working abc  4000 L1       # non-numeric activity: deleted
  print -rl -- working 1000 4000 > $d/i   # 3 lines: deleted
  mk j sleeping 1000 4000 L1      # unknown state: deleted
  mk k working 1000 4999 ''       # empty start, dead pid: deleted
  scan_sessions 1500; is $ACTIVE 0 safety-none-active
  is "$(ls $d | tr '\n' ' ')" "g " safety-only-future-kept
}

# ---- runner ----
# Abort before any group if the stubs cannot be loaded (never fall through to real sudo).
( export EEPY_HOME=$(mktemp -d) EEPY_LOG=/dev/null; load_eepy ) >/dev/null 2>&1
rc=$?
(( rc == 0 )) || { print -u2 "test.zsh: stub load failed (status $rc), aborting"; exit 1 }

groups=("$@")
(( $#groups )) || groups=(${(ok)functions[(I)t_*]})
failed=0
for GROUP in $groups; do
  (
    export EEPY_HOME=$(mktemp -d) EEPY_LOG
    EEPY_LOG=$EEPY_HOME/log
    load_eepy
    FAILS=0
    $GROUP
    exit $FAILS
  ) || { failed=1; print -r -- "FAIL $GROUP (non-zero exit)" }
done
(( failed )) && exit 1
print ok
