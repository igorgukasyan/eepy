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
