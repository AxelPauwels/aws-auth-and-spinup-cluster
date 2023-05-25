#!/bin/bash

# variables
export txt_black='\033[0;30m'
export txt_red='\033[0;31m'
export txt_green='\033[0;32m'
export txt_yellow='\033[0;33m'
export txt_blue='\033[0;34m'
export txt_magenta='\033[0;35m'
export txt_cyan='\033[0;36m'
export txt_white='\033[0;37m'

export txt_bold='\033[1m'
export txt_dimmed='\033[2m'
export txt_dimmed_half='\033[2;3m'
export txt_italic='\033[3m'
export txt_underline='\033[4m'
export txt_blink_slow='\033[5m'
export txt_blink_rapid='\033[6m'
export txt_reverse='\033[7m'
export txt_hidden='\033[8m'
export txt_strikethrough='\033[9m'

export txt_reset='\033[0m'

export icon_check="✔"
export icon_exclamation="⚠"
export icon_times="✘"
export icon_arrow_right="→"

#############
# functions #
#############
new_line() {
  echo
}

msg() {
  echo "$*" >&2
}

msg_yellow() {
  echo -e "${txt_yellow}$*${txt_reset}" >&2
}

msg_yellow_inline() {
  echo -en "${txt_yellow}$*${txt_reset}" >&2
}

msg_green() {
  echo -e "${txt_green}$*${txt_reset}" >&2
}

msg_red() {
  echo -e "${txt_red}$*${txt_reset}" >&2
}

msg_title() {
  echo
  msg_yellow "$@"
}

msg_status() {
  msg "${icon_arrow_right}" "$*" "..."
}

msg_error() {
  msg_red "${icon_times}" "$*"
  echo
}

msg_success() {
  msg_green "${icon_check}" "$*"
  echo
}

msg_user_input() {
  echo -en "${txt_white}$*${txt_reset}" >&2
}

msg_debug() {
  if [ "$DEBUG_MODE" = 1 ]; then
    echo -e "${txt_magenta}[Debug] $*${txt_reset}" >&2
  fi
}

msg_dimmed() {
  echo -e "${txt_dimmed}$*${txt_reset}" >&2
}

msg_strikethrough() {
  echo -e "${txt_strikethrough}$*${txt_reset}" >&2
}

#params string substring
string_contains_substring() {
  if [[ $1 == *"$2"* ]]; then
    return 0
  else
    return 1
  fi
}

command_exists() {
  if command -v "$@" >/dev/null 2>&1; then
    return 0 # exist
  else
    return 1 # does not exist
  fi
}
