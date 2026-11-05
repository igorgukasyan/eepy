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
    if [[ "$*" == *"launchctl bootstrap"* ]]; then   # the watchdog job "runs" at once unless NO_STAMP
      (( ${AGENT_RC:-0} )) && return $AGENT_RC
      (( ${NO_STAMP:-0} )) || touch $EEPY_HOME/watchdog
    fi
    if (( ${SUDO_RC:-0} == 0 )); then
      [[ "$*" == *"disablesleep 1"* ]] && ROOT_OUT='"SleepDisabled" = Yes'
      [[ "$*" == *"disablesleep 0"* ]] && ROOT_OUT='"SleepDisabled" = No'
    else print -u2 "sudo: stub error"
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
  pmset() {
    [[ "$*" == *"-g batt"* ]] && print -r -- "$PMSET_BATT"
    [[ $1 == displaysleepnow ]] && CALLS+=("pmset $*")
    return 0
  }
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
  PS_LSTART=(4000 L1)   # a live Claude process for child runs
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
  DEFAULT_CLAUDE=0; parse_args;                                is "$NOCLAUDE" 1 default-claude-off
  DEFAULT_CLAUDE=0; parse_args --claude;                       is "$NOCLAUDE" 0 claude-flag
  DEFAULT_CLAUDE=1; parse_args --no-claude;                    is "$NOCLAUDE" 1 no-claude-flag
  parse_args --no-claude --claude;                             is "$NOCLAUDE" 0 last-flag-wins
  parse_args 140m;                                             is "$LIMIT" 8400 140m
}
t_log() {
  log hello > $EEPY_HOME/out; is "$(<$EEPY_HOME/out)" "" file-only-by-default
  grep -q '^[0-9-]\{10\} [0-9:]\{8\} hello$' $EEPY_LOG || is missing present log-format
}
t_proc_start() {
  PS_LSTART=(4000 'Tue Oct 20 13:33:01 2026    ' 4001 'Tue  Oct 20 13:33:01 2026')
  is "$(proc_start 4000)" 'Tue Oct 20 13:33:01 2026' trims-trailing
  is "$(proc_start 4001)" 'Tue Oct 20 13:33:01 2026' squeezes
  is "$(proc_start 4999)" '' unknown-pid
  ps() { print -r -- "$TZ $LC_ALL" }; TZ=Europe/London; is "$(proc_start 1)" "UTC C" fixed-tz-and-locale
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
  ROOT_OUT='      "SleepDisabled" = Nope'; is "$(read_held)" 1 only-literal-no-is-released
  is "$(read_sd)" Nope raw-value; ROOT_OUT=''; is "$(read_sd)" '?' raw-unreadable
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
  is "$REPORT" "a working 8m, b waiting 8m, c finished 8m" report
  scan_sessions 4599; is $ACTIVE 2 uc4-just-under-cap
  scan_sessions 4600; is $ACTIVE 0 uc4-cap-reached
  is "$REPORT" "+3 idle >1h" report-old-collapsed
  is "$(dur 45) $(dur 600) $(dur 7200) $(dur 8400) $(dur 3659)" "45s 10m 2h 2h20m 1h" dur
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

t_hold_release() {
  local open='"AppleClamshellState" = No' closed='"AppleClamshellState" = Yes'
  CALLS=(); hold; is "${(j:|:)CALLS}" "-n /usr/bin/pmset -a disablesleep 1" hold-call
  CALLS=(); LID_OUT=$open; release
  is "${(j:|:)CALLS}" "-n /usr/bin/pmset -a disablesleep 0" uc13-release-attended-never-sleeps
  CALLS=(); LID_OUT=$closed; release
  is "${(j:|:)CALLS}" "-n /usr/bin/pmset -a disablesleep 0|-n /usr/bin/pmset sleepnow" uc1-release-unattended-sleeps
  CALLS=(); SUDO_RC=1; ROOT_OUT='"SleepDisabled" = Yes'; release; is $? 1 uc27-release-fails
  is "${(j:|:)CALLS}" "-n /usr/bin/pmset -a disablesleep 0|-n /usr/bin/pmset sleepnow" uc27-still-tries-sleepnow
  grep -qF 'FAILURE release failed: read back Yes, sudo: stub error' $EEPY_LOG || is missing logged uc27-logged
  grep -qF 'FAILURE sleepnow failed: sudo: stub error' $EEPY_LOG || is missing logged sleepnow-failure-logged
  is "$(grep -c 'sleepnow (unattended)' $EEPY_LOG)" 1 sleepnow-success-only-logged-on-success
  CALLS=(); held Maybe; release; grep -qF 'FAILURE release failed: read back Maybe' $EEPY_LOG || is missing logged actual-read-back
  CALLS=(); LID_OUT=$open; ROOT_OUT='"SleepDisabled" = No'; hold; is $? 1 hold-fails
  is "${(j:|:)CALLS}" "-n /usr/bin/pmset -a disablesleep 1|-n /usr/bin/pmset -a disablesleep 0" hold-failure-releases
  grep -qF 'FAILURE hold failed: read back No, sudo: stub error' $EEPY_LOG || is missing logged hold-failure-read-back
  SUDO_RC=0; rm -f $EEPY_HOME/err; mkdir $EEPY_HOME/err   # err cannot be opened: pmset must still run
  CALLS=(); hold; is "${CALLS[1]}" "-n /usr/bin/pmset -a disablesleep 1" unopenable-err-still-holds
  CALLS=(); LID_OUT=$closed; release
  is "${(j:|:)CALLS}" "-n /usr/bin/pmset -a disablesleep 0|-n /usr/bin/pmset sleepnow" unopenable-err-still-releases
}

loop_reset() { HOLDING=0 LAST_CHECK=0 LAST_ACTIVE=0 END=0 NOCLAUDE=0 STOPPING= SUDO_RC=0 CALLS=()
  ROOT_OUT='"SleepDisabled" = No'; OS_OUT='0 0'; DISPLAYS=0; PS_LSTART=(4000 'L1  ')
  mkdir -p $EEPY_HOME/sessions; rm -f $EEPY_HOME/sessions/*(N) }
lid() { LID_OUT="\"AppleClamshellState\" = $1" }   # lid Yes = closed
sess() { print -rl -- $1 ${2:-$NOW} 4000 L1 > $EEPY_HOME/sessions/a }
held() { ROOT_OUT="\"SleepDisabled\" = $1" }
t_all_day() {   # uc8, uc10, uc1, uc26
  loop_reset; lid No
  NOW=1000; check_once; is $HOLDING 0 morning-idle
  NOW=1030; sess working; check_once; is $HOLDING 1 working-at-desk-holds
  is "$(tail -1 $EEPY_LOG | cut -d' ' -f3-)" \
    "holding: attended, heat nominal, battery 57% at 30.3°C, on battery, low power off; sessions: a working 0s" holding-line
  NOW=1060; lid Yes; check_once; is $HOLDING 1 lid-closed-keeps-holding
  NOW=1090; sess finished 1060; check_once; is $HOLDING 1 grace
  NOW=1170; check_once; is $HOLDING 1 still-grace       # grace counts from the last check that saw it active (1060)
  NOW=1180; check_once; is $HOLDING 0 released-after-grace
  is "${CALLS[-1]}" "-n /usr/bin/pmset sleepnow" sleeps-when-unattended
  NOW=1240; sess working; check_once; is $HOLDING 0 uc26-dark-wake-never-arms
  NOW=1270; lid No; check_once; is $HOLDING 1 lid-open-arms-again
}
t_lock() {   # holding stops a closed lid from sleeping the Mac, so it would never lock
  loop_reset; lid No; SEEN=
  NOW=1000; sess working; check_once; is $HOLDING 1 holds
  CALLS=(); lid Yes; watch_lid; is "${CALLS[*]}" "pmset displaysleepnow" lid-closed-locks-within-a-second
  grep -q 'lock: lid closed, unattended, while holding' $EEPY_LOG || is missing logged lock-logged
  CALLS=(); watch_lid; NOW=1030; check_once; is "${CALLS[*]}" "" locks-once
  CALLS=(); lid No; watch_lid; lid Yes; watch_lid; is "${CALLS[*]}" "pmset displaysleepnow" reopen-and-close-locks-again
  CALLS=(); lid No; watch_lid; DISPLAYS=1; lid Yes; watch_lid; is "${CALLS[*]}" "pmset displaysleepnow" lid-closed-with-monitor-locks
  CALLS=(); NOW=1060; check_once; is "${CALLS[*]}" "" monitor-locks-once
  CALLS=(); DISPLAYS=0; NOW=1090; check_once; is "${CALLS[*]}" "pmset displaysleepnow" monitor-unplugged-locks-at-next-check
  loop_reset; lid Yes; DISPLAYS=1; NOCLAUDE=1; SEEN=
  NOW=1000; check_once; is "$HOLDING ${CALLS[*]}" "1 -n /usr/bin/pmset -a disablesleep 1" start-lid-closed-at-monitor-no-lock
  loop_reset; lid No; SEEN=
  NOW=1000; check_once; is $HOLDING 0 not-holding
  CALLS=(); lid Yes; watch_lid; NOW=1030; check_once; is "${CALLS[*]}" "" not-holding-macos-sleeps-and-locks-itself
}
t_not_holding() { loop_reset; lid No; NOW=1000; OS_OUT='2 0'
  check_once; is "$(tail -1 $EEPY_LOG | cut -d' ' -f3-)" "not holding: attended, active sessions 0" no-reason-when-not-wanted
  sess working; check_once; NOW=1030; sess working; check_once; is $HOLDING 0 tripped-not-held
  is "$(grep -cF 'not holding: attended, active sessions 1; TRIGGER heat: thermal pressure 2 (limit 2)' $EEPY_LOG)" 1 reason-logged-once }
t_panel() { loop_reset; load_kitty; lid No; NOW=1000; END=8200; FLOOR=20; sess working; check_once
  is "$PANEL[1]" " eepy · Claude mode · 2h left" panel-header
  is "$PANEL[2]" $' \e[32m● AWAKE\e[0m · lid open or monitor · on battery' panel-state
  is "$PANEL[4]" " heat     █░░░        nominal  limit serious" panel-heat
  is "$PANEL[5]" " battery  ██████░░░░  57%      limit 20%" panel-battery
  is "$PANEL[6]" " temp     ███████░░░  30.3°C   limit 40°C" panel-temp
  is "$PANEL[8]" " a         ▶ working   0s" panel-session
  SHOW=panel LOG_N=$(wc -l < $EEPY_LOG); log "holding: x"; log "hook a none -> working (X)"; log "hold: y"
  show > $EEPY_HOME/o; local o=$(<$EEPY_HOME/o); is "${o%%$'\n'*}" "${$(tail -1 $EEPY_LOG)#* }" show-skips-routine-lines
  [[ $MOOD == working && -n $THOUGHT && $o == *"$THOUGHT"* ]] || is missing drawn kitty-drawn-with-thought
  is $PANEL_H $(( 18 + $#PANEL )) height-counts-kitty
  is ${#PANEL[3]} $(( 1 + ${#KITTY[1]} )) dividers-as-wide-as-kitty
  [[ $o == *"$PANEL[1]"* ]] || is missing drawn show-draws-panel
  LOG_N=$(wc -l < $EEPY_LOG) PANEL_H=9; is "$(show last)" $'\e[9A\e[J' show-last-erases-panel
  OS_OUT='2 0'; NOW=1030; check_once; is "$PANEL[3]" " TRIGGER heat: thermal pressure 2 (limit 2)" panel-paused-reason }
t_kitty() { load_kitty; is "$KITTY_H $#KITTY $KITTY_ROW" "18 108 4" loads-six-frames
  THOUGHTS=(idle hi) MOOD=idle; kitty; [[ $KLINES[KITTY_ROW+1] == *⠀hi⠀* ]] || is "$KLINES[KITTY_ROW+1]" "hi in the cloud" thought-in-cloud
  local first="${(F)KLINES}" i; for i in {1..5}; do kitty; done
  [[ "${(F)KLINES}" == $first ]] && is same different frames-move
  kitty; is "${(F)KLINES}" "$first" six-frame-cycle
  THOUGHTS=(idle ${(l:40::x:)}) THOUGHT_MOOD=; kitty; local l=${${KLINES[KITTY_ROW+1]#*$'\e[38;5;173m'}%$'\e[0m'}
  [[ $l == *x… ]] || [[ $l == *x…⠀* ]] || is "$l" "cut with …" long-thought-cut
  is $#l ${#KITTY[1]} long-thought-keeps-width
  EEPY_PATH=$EEPY_HOME/none/eepy KITTY=() KITTY_H=0; load_kitty; kitty; is "$KITTY_H $#KLINES" "0 0" missing-file-no-kitty
  mkdir -p $EEPY_HOME/bad; print -l '18 x 1 2' a > $EEPY_HOME/bad/kitty.txt; EEPY_PATH=$EEPY_HOME/bad/eepy
  load_kitty; is $KITTY_H 0 bad-header-no-kitty }
t_thoughts() { load_kitty
  local -A n; local i prev
  for (( i = 1; i < $#THOUGHTS; i += 2 )); do
    (( n[$THOUGHTS[i]]++ ))
    (( ${#THOUGHTS[i+1]} <= KITTY_B - KITTY_A + 1 )) || is "$THOUGHTS[i+1]" "fits the cloud" default-fits
  done
  is $(( $#THOUGHTS % 2 )) 0 defaults-in-pairs
  is "${(j: :)${(@o)${(@k)n}}}" "battery failure grace hot idle lowpower plain unplug working" every-state-has-thoughts
  loop_reset; lid No; NOW=1000; check_once;                          is $MOOD idle mood-idle
  sess working; NOW=1030; check_once;                                is $MOOD working mood-working
  sess finished 1030; NOW=1060; check_once;                          is $MOOD grace mood-grace
  loop_reset; lid No; NOCLAUDE=1; NOW=1000; check_once;              is $MOOD plain mood-plain
  loop_reset; lid No; NOW=1000; sess working; HOLDING=1; held Yes; OS_OUT='2 0'; check_once
                                                                     is $MOOD hot mood-hot
  loop_reset; lid No; NOW=1000; FLOOR=60; sess working; check_once;  is $MOOD battery mood-battery
  loop_reset; lid No; NOW=1000; FLOOR=20; OS_OUT=junk; sess working; check_once
                                                                     is $MOOD failure mood-failure
  loop_reset; lid No; NOW=1000; PMSET_BATT="Now drawing from 'AC Power'
 -InternalBattery-0 (id=1)	80%; charged; present: true"; check_once
  [[ $PANEL[2] == *'on AC' ]] || is "$PANEL[2]" "ends with on AC" on-AC
  THOUGHTS=(a one a two b three) MOOD=a THOUGHT=
  think; [[ $THOUGHT == (one|two) ]] || is "$THOUGHT" "one or two" think-picks-from-mood
  prev=$THOUGHT; for i in {1..20}; do think; [[ $THOUGHT == $prev ]] && is same different never-twice-in-a-row; prev=$THOUGHT; done
  MOOD=b; think; think; is "$THOUGHT" three only-choice-repeats
  MOOD=none; think; is "$THOUGHT" "" no-thoughts-no-text
  THOUGHTS=(a 'w*[x]?' a 'w*[x]?') MOOD=a THOUGHT='w*[x]?'; think; is "$THOUGHT" 'w*[x]?' duplicates-and-pattern-chars
  THOUGHTS=(a one a two) MOOD=a TICK=0 THOUGHT_MOOD=; kitty; local t1=$THOUGHT
  for i in {1..5}; do kitty; done; is "$THOUGHT" "$t1" same-thought-for-a-cycle
  kitty; [[ $THOUGHT != $t1 ]] || is same different new-thought-each-cycle
  THOUGHTS+=(b three) MOOD=b; kitty; is "$THOUGHT" three new-mood-at-once }
t_noclaude()     { loop_reset; lid No; NOCLAUDE=1; NOW=1000; check_once; is $HOLDING 1 uc12-holds-without-sessions
  sess finished 1000; NOW=1300; check_once; is $HOLDING 1 plain-ignores-finished-sessions
  is "$PANEL[-2]" $' \e[38;5;244mplain mode: sessions are shown, not counted\e[0m' plain-panel-note
  is "$PANEL[-1]" " a         ✓ finished  5m" plain-panel-lists-sessions }
t_time_limit()   { loop_reset; lid Yes; NOCLAUDE=1; HOLDING=1; held Yes; END=2000; NOW=2000
  check_once; is $? 1 uc11-stops; grep -q 'TRIGGER time limit reached' $EEPY_LOG || is missing logged uc11-logged }
t_stop_trigger() { loop_reset; lid Yes; NOW=1000; sess working; HOLDING=1; held Yes; OS_OUT='2 0'
  check_once; is $? 1 uc17-stops
  is "${(j:|:)CALLS}" "-n /usr/bin/pmset -a disablesleep 0|-n /usr/bin/pmset sleepnow" uc17-release-and-sleep }
t_stop_retry()   { loop_reset; lid Yes; NOW=1000; sess working; HOLDING=1; held Yes; OS_OUT='2 0'; SUDO_RC=1
  check_once; is $? 0 uc27-failed-stop-keeps-running
  SUDO_RC=0; OS_OUT='0 0'; NOW=1030; check_once; is "$? $HOLDING" "1 0" uc27-stop-retried }
t_stop_retry_gap() { loop_reset; lid Yes; sess working 1000; HOLDING=1; held Yes; LAST_CHECK=1000; NOW=1091; SUDO_RC=1
  check_once; is "$? $HOLDING" "0 1" uc27-failed-gap-stop-keeps-running
  SUDO_RC=0; NOW=1121; check_once; is "$? $HOLDING" "1 0" uc27-gap-stop-retried }
t_pause()        { loop_reset; lid No; NOW=1000; sess working; HOLDING=1; held Yes; OS_OUT='2 0'
  check_once; is "$? $HOLDING" "0 0" uc18-pauses
  [[ "$CALLS" == *sleepnow* ]] && is slept "not slept" uc18-never-sleeps-attended
  NOW=1030; sess working; OS_OUT='0 0'; check_once; is $HOLDING 1 uc18-resumes-when-cool }
t_release_retry() { loop_reset; lid Yes; HOLDING=1; held Yes; NOW=1000; SUDO_RC=1   # no sessions, not wanted
  check_once; is $HOLDING 1 uc27-still-held-after-failure
  SUDO_RC=0; NOW=1030; check_once; is $HOLDING 0 uc27-retried
  is "${#${(@M)CALLS:#*disablesleep 0}}" 2 uc27-two-release-attempts }
t_reconcile()    { loop_reset; lid Yes; NOW=1000; sess working; HOLDING=1; held No
  check_once; is $HOLDING 0 reconciled-down
  [[ "$CALLS" == *'disablesleep 1'* ]] && is held "not held" uc26-no-rehold-in-bag
  grep -q 'FAILURE expected holding=1' $EEPY_LOG || is missing logged reconcile-logged }
t_reconcile_up() { loop_reset; lid No; NOW=1000; HOLDING=0; held Yes   # uc28 stray hold, nothing wanted
  check_once; is $HOLDING 0 stray-hold-released
  [[ "$CALLS" == *'disablesleep 0'* ]] || is missing released stray-hold-release-call }
t_reconcile_up_unattended() { loop_reset; lid Yes; NOW=1000; sess working; HOLDING=0; held Yes   # stray hold in the bag
  check_once; is $HOLDING 0 stray-hold-released-unattended
  is "${(j:|:)CALLS}" "-n /usr/bin/pmset -a disablesleep 0|-n /usr/bin/pmset sleepnow" stray-hold-release-and-sleep }
t_gap()          { loop_reset; lid Yes; sess working 1000; HOLDING=1; held Yes; LAST_CHECK=1000; NOW=1091
  check_once; is $? 1 uc25-gap-stops; grep -q 'FAILURE gap' $EEPY_LOG || is missing logged uc25-logged }
t_gap_after_watchdog() { loop_reset; lid Yes; sess working 1000; HOLDING=1; held No; LAST_CHECK=1000; NOW=1200
  check_once; is $? 1 uc25-stops-even-if-watchdog-released }
t_gap_boundary() { loop_reset; lid Yes; sess working 1000; HOLDING=1; held Yes; LAST_CHECK=1000; NOW=1090
  check_once; is "$? $HOLDING" "0 1" exactly-3-intervals-is-not-a-gap }
t_heartbeat()    { loop_reset; lid No; NOW=1000; check_once; [[ -e $EEPY_HOME/heartbeat ]] || is missing written heartbeat
  touch -t 200001010000 $EEPY_HOME/heartbeat; NOW=1030; check_once
  (( $(stat -f %m $EEPY_HOME/heartbeat) > EPOCHSECONDS - 60 )) || is stale refreshed heartbeat-refreshed }
wait_for() { local i; for i in {1..50}; do grep -q "$1" $2 2>/dev/null && return 0; sleep 0.1; done; return 1 }
t_single_instance() {   # Review Focus 5
  zsh $TEST_FILE child --no-claude >/dev/null 2>&1 &; local p=$!
  wait_for 'disablesleep 1' $EEPY_HOME/calls || is no first-held first-instance-holds
  zsh $TEST_FILE child --no-claude >/dev/null 2>$EEPY_HOME/err2; is $? 1 second-refused
  grep -q 'already running' $EEPY_HOME/err2 || is missing said already-running-message
  kill -TERM $p; wait $p 2>/dev/null
}
t_prompt_wakes() {   # a prompt just before the lid closes is seen within seconds, not at the next 30 s check
  zsh $TEST_FILE child >/dev/null 2>&1 &; local p=$!
  wait_for 'not holding: attended, active sessions 0' $EEPY_LOG || is no checked first-check
  print -rl -- working $EPOCHSECONDS 4000 L1 > $EEPY_HOME/s; mv $EEPY_HOME/s $EEPY_HOME/sessions/a
  wait_for 'disablesleep 1' $EEPY_HOME/calls || is no held holds-within-seconds
  kill -TERM $p; wait $p 2>/dev/null
}
t_signal_release() {   # Review Focus 1
  zsh $TEST_FILE child --no-claude | true &
  wait_for 'disablesleep 1' $EEPY_HOME/calls || is no held child-holds
  pkill -HUP -f "$TEST_FILE child"; wait_for 'stopped by signal' $EEPY_LOG || is missing logged hup-logged
  grep -q 'disablesleep 0' $EEPY_HOME/calls || is missing released hup-releases
  pkill -KILL -f "$TEST_FILE child"
}
t_signal_exits() {   # a stopped eepy must not linger in `wait` (holding the lock) until the sleep ends
  zsh $TEST_FILE child --no-claude >/dev/null 2>&1 &; local p=$! i
  wait_for 'disablesleep 1' $EEPY_HOME/calls || is no held child-holds
  grep -q "start: eepy $VERSION, no time limit, plain mode, battery floor 20%, sleep on unplug off" $EEPY_LOG ||
    is missing logged start-line
  grep -q "safety: heat max serious, battery temp max 40°C, grace 2m, check every 30s, session cap 1h" $EEPY_LOG ||
    is missing logged safety-line
  kill -QUIT $p
  for i in {1..20}; do kill -0 $p 2>/dev/null || break; sleep 0.1; done
  kill -0 $p 2>/dev/null && { is lingering exited exits-promptly; kill -KILL $p }
  wait $p 2>/dev/null
  grep -q 'stopped by signal' $EEPY_LOG || is missing logged quit-trapped
  grep -q 'disablesleep 0' $EEPY_HOME/calls || is missing released quit-releases
}
t_signal_without_lock() {   # a second eepy signalled before it has the lock must not release the first one's hold
  loop_reset; held Yes; LOCK_FD=
  ( on_signal ); is $? 0 exits-0
  [[ -s $EEPY_HOME/calls ]] && is called "nothing called" no-release
  grep -q 'stopped by signal' $EEPY_LOG 2>/dev/null && is logged "not logged" no-log
}
t_start_checks() {
  SUDO_L_RC=1 zsh $TEST_FILE child --no-claude >/dev/null 2>$EEPY_HOME/err2; is $? 1 refuses-without-sudo-rule
  grep -q 'eepy setup' $EEPY_HOME/err2 || is missing said sudo-message
  rm -f $EEPY_HOME/watchdog
  zsh $TEST_FILE child --no-claude >/dev/null 2>$EEPY_HOME/err2; is $? 1 refuses-without-watchdog-stamp
  is "$(<$EEPY_HOME/err2)" 'the eepy watchdog has not run in the last 2.5 minutes; run "eepy setup"' watchdog-message
  touch -t 200001010000 $EEPY_HOME/watchdog
  zsh $TEST_FILE child --no-claude >/dev/null 2>$EEPY_HOME/err2; is $? 1 refuses-with-old-watchdog-stamp
  : > $EEPY_HOME/file
  EEPY_HOME=$EEPY_HOME/file/h zsh $TEST_FILE child --no-claude >/dev/null 2>$EEPY_HOME/err2; is $? 1 refuses-without-home
  is "$(<$EEPY_HOME/err2)" "cannot create $EEPY_HOME/file/h/sessions" home-message
  mkdir -p $EEPY_HOME/h2/sessions $EEPY_HOME/h2/lock
  EEPY_HOME=$EEPY_HOME/h2 zsh $TEST_FILE child --no-claude >/dev/null 2>$EEPY_HOME/err2; is $? 1 refuses-without-lock-file
  is "$(<$EEPY_HOME/err2)" "cannot create $EEPY_HOME/h2/lock" lock-message
  [[ -s $EEPY_HOME/calls ]] && is called "nothing called" refusals-touch-nothing
}
t_watchdog() {
  local hb=$EEPY_HOME/heartbeat; NOW=$EPOCHSECONDS
  age() { touch -t $(date -r $((NOW - ($1))) +%Y%m%d%H%M.%S) $hb }
  CALLS=(); ROOT_OUT='"SleepDisabled" = Yes'; age 10;  watchdog; is "${#CALLS}" 0 fresh-heartbeat
  CALLS=(); ROOT_OUT='"SleepDisabled" = No';  age 100; watchdog; is "${#CALLS}" 0 stale-but-released
  CALLS=(); ROOT_OUT='"SleepDisabled" = Yes'; LID_OUT='"AppleClamshellState" = Yes'; age 100; watchdog
  is "${(j:|:)CALLS}" "-n /usr/bin/pmset -a disablesleep 0|-n /usr/bin/pmset sleepnow" uc23-stale-unattended
  CALLS=(); ROOT_OUT='"SleepDisabled" = Yes'; rm -f $hb; LID_OUT='"AppleClamshellState" = No'; watchdog
  is "${(j:|:)CALLS}" "-n /usr/bin/pmset -a disablesleep 0" uc24-missing-heartbeat
  CALLS=(); ROOT_OUT=''; age 100; watchdog; is "${CALLS[1]}" "-n /usr/bin/pmset -a disablesleep 0" unreadable-counts-as-held
  grep -q 'FAILURE watchdog' $EEPY_LOG || is missing logged watchdog-logged
  CALLS=(); held Yes; age -100; watchdog; is "${CALLS[1]}" "-n /usr/bin/pmset -a disablesleep 0" clock-jumped-back-is-stale
  rm -f $EEPY_HOME/watchdog; watchdog; [[ -e $EEPY_HOME/watchdog ]] || is missing stamped watchdog-stamps
  EEPY_HOME=$EEPY_HOME/new; watchdog 2>/dev/null; [[ -e $EEPY_HOME/watchdog ]] || is missing stamped stamp-creates-home
}
t_setup_text() {
  is "$(sudoers_text igor)" "igor ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset sleepnow" sudoers-exact
  sudoers_text igor > $EEPY_HOME/s; /usr/sbin/visudo -cf $EEPY_HOME/s >/dev/null 2>&1 || is invalid valid visudo-syntax
  agent_plist /x/eepy | plutil -lint - >/dev/null || is invalid valid plist-lint
  is "$(agent_plist /x/eepy | plutil -extract StartInterval raw -)" 60 interval
  is "$(agent_plist /x/eepy | plutil -extract ProgramArguments.1 raw -)" watchdog runs-watchdog
  is "$(agent_plist /x/eepy | plutil -extract UserName raw -)" $USER runs-as-owner
  is "$(agent_plist /x/eepy | plutil -extract EnvironmentVariables.HOME raw -)" $HOME has-home
  is "$(agent_plist /x/eepy | plutil -extract StandardErrorPath raw -)" /dev/null no-stderr-file
}
t_merge_hooks() {   # Review Focus 4
  local E=/Users/x/.local/bin/eepy m other='{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}}'
  m=$(print '{}' | merge_hooks $E); is "$(print -r $m | jq '.hooks | keys | length')" 7 seven-events
  is "$(print -r $m | jq -r '.hooks.PreToolUse[0].matcher')" 'AskUserQuestion|ExitPlanMode' pretooluse-matcher
  m=$(print -r $other | merge_hooks $E)
  is "$(print -r $m | jq -r .model)" opus keeps-settings
  is "$(print -r $m | jq '[.hooks.Stop[].hooks[].command] | index("say done") != null')" true keeps-other-hooks
  is "$(print -r $m | merge_hooks $E | jq -S .)" "$(print -r $m | jq -S .)" idempotent
  is "$(print -r $m | unmerge_hooks $E | jq -S .)" "$(print -r $other | jq -S .)" unmerge-restores
  is "$(print '{}' | merge_hooks $E | unmerge_hooks $E | jq -c .)" '{}' unmerge-to-empty
  local out; out=$(print 'not json' | merge_hooks $E); is "$? $out" "1 " invalid-json-aborts-silently
}
t_uninstall_refuses() {   # Review Focus 5
  zsh $TEST_FILE child --no-claude >/dev/null 2>&1 &; local p=$!
  wait_for 'disablesleep 1' $EEPY_HOME/calls || is no held child-holds
  zsh $TEST_FILE child uninstall >/dev/null 2>$EEPY_HOME/err2; is $? 1 refuses-while-running
  grep -q 'stop it first' $EEPY_HOME/err2 || is missing said refusal-message
  zsh $TEST_FILE child setup >/dev/null 2>$EEPY_HOME/err2; is $? 1 setup-refuses-while-running
  grep -q 'stop it first' $EEPY_HOME/err2 || is missing said setup-refusal-message
  kill -KILL $p; wait $p 2>/dev/null
}
t_setup_fixes() {   # settings.json mode, failed release, foreign link, bad merge output
  HOME=$(mktemp -d); mkdir -p $HOME/.claude; print -r '{"model":"opus"}' > $HOME/.claude/settings.json; chmod 600 $HOME/.claude/settings.json
  setup >/dev/null 2>&1; is $? 0 setup-ok
  is "$(stat -f %Lp $HOME/.claude/settings.json)" 600 setup-keeps-mode
  local D=/Library/LaunchDaemons/local.eepy.watchdog.plist
  grep -q "^install -m 644 -o root -g wheel .* $D\$" $EEPY_HOME/calls || is missing called daemon-installed
  grep -qx "launchctl bootstrap system $D" $EEPY_HOME/calls || is missing called daemon-bootstrapped
  [[ -e $EEPY_LOG ]] || is missing created log-created
  is "$(jq -r .model $HOME/.claude/settings.json)" opus setup-keeps-settings
  AGENT_RC=1 setup >/dev/null 2>$EEPY_HOME/err2; is $? 1 step3-fails
  grep -q "sudoers rule .* is installed; run \"$EEPY_PATH uninstall\"" $EEPY_HOME/err2 || is missing said step3-uninstall-hint
  NO_STAMP=1 setup >/dev/null 2>$EEPY_HOME/err2; is $? 1 not-run-fails
  grep -qF 'the watchdog job did not run; macOS may have blocked it (check System Settings > General > Login Items)' $EEPY_HOME/err2 || is missing said not-run-message
  mkdir -p $HOME/Library/LaunchAgents; : > $HOME/Library/LaunchAgents/local.eepy.watchdog.plist
  setup >/dev/null 2>&1; is $? 0 setup-again-ok
  [[ -e $HOME/Library/LaunchAgents/local.eepy.watchdog.plist ]] && is present removed old-agent-plist-removed
  rm $HOME/.claude/settings.json; setup >/dev/null 2>&1
  is "$(stat -f %Lp $HOME/.claude/settings.json)" 600 setup-new-file-600
  CALLS=()
  uninstall >/dev/null 2>&1; is $? 0 uninstall-ok
  (( ${CALLS[(I)launchctl bootout system/local.eepy.watchdog]} )) || is missing called daemon-booted-out
  (( ${CALLS[(I)rm -f /Library/LaunchDaemons/local.eepy.watchdog.plist]} )) || is missing called daemon-removed
  is "$(stat -f %Lp $HOME/.claude/settings.json)" 600 uninstall-keeps-mode
  [[ -e $HOME/.local/bin/eepy ]] && is present removed own-link-removed
  mkdir -p $HOME/.local/bin $EEPY_HOME; : > $HOME/.local/bin/eepy
  uninstall 2>&1 | grep -q 'left ~/.local/bin/eepy alone' || is missing said foreign-link-kept
  [[ -e $HOME/.local/bin/eepy ]] || is gone kept foreign-link-kept-file
  mkdir -p $EEPY_HOME; held Yes; release() { return 1 }
  uninstall 2>$EEPY_HOME/err2; is $? 1 failed-release-stops
  grep -q 'could not re-enable sleep' $EEPY_HOME/err2 || is missing said release-message
  local out; out=$(print '   ' | merge_hooks /x); is "$? $out" "1 " blank-output-fails
  out=$(print '[]' | unmerge_hooks /x); is "$? $out" "1 " non-object-fails
}
t_runner_unknown_group() { zsh $TEST_FILE t_no_such_group >/dev/null 2>&1 && is passed failed unknown-group-fails }

# ---- runner ----
# Abort before any group if the stubs cannot be loaded (never fall through to real sudo).
( export EEPY_HOME=$(mktemp -d) EEPY_LOG=/dev/null; load_eepy ) >/dev/null 2>&1
rc=$?
(( rc == 0 )) || { print -u2 "test.zsh: stub load failed (status $rc), aborting"; exit 1 }

groups=("$@")
(( $#groups )) || groups=(${(ok)functions[(I)t_*]})
failed=0
for GROUP in $groups; do
  (( $+functions[$GROUP] )) || { failed=1; print -r -- "FAIL $GROUP (no such group)"; continue }
  (
    export EEPY_HOME=$(mktemp -d) EEPY_LOG
    EEPY_LOG=$EEPY_HOME/log
    export HOME=$EEPY_HOME
    load_eepy
    touch $EEPY_HOME/watchdog   # child runs refuse without a recent watchdog stamp
    FAILS=0
    $GROUP
    exit $FAILS
  ) || { failed=1; print -r -- "FAIL $GROUP (non-zero exit)" }
done
(( failed )) && exit 1
print ok
