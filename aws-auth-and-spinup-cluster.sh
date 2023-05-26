#!/bin/bash

#
# Script for authenticating to AWS and spinning up an EMR Cluster on EC2.
#

init() {
  # load script utilities (variables and functions)
  source "$(dirname "$0")/script-utils.sh" # assuming that this script is in the same directory

  # set script settings
  DEBUG_MODE=0 # set to 1 to see logging in terminal
  AWS_CREDENTIALS_PATH="$HOME/.aws/credentials"
  AWS_FILTERED_CREDENTIALS_PATH="${AWS_CREDENTIALS_PATH%/*}/filtered_credentials.txt" # based on previous variable, never change this
  TIMEZONE="Europe/Brussels"
  CURRENT_ROLE="none"
  TEAM_NAME="none"
  CREATE_CLUSTER_SCRIPT_PATH="$HOME/awsEmrClusterConfigs/emr-create-cluster.sh"
  INSTANCE_GROUP_CONFIG_PATH="$HOME/awsEmrClusterConfigs/emr-default-instance-group-config.json"
}

authenticateToAWS() {
  msg_title "Authenticating to AWS"
  msg_debug "[authenticateToAWS]"

  if command_exists gimme-aws-creds; then
    msg_status "Start authentication"
    msg_debug "Executing 'gimme-aws-creds'"
    gimme-aws-creds
  else
    msg_error "Cannot run command 'gimme-aws-creds' (not installed)"
  fi
}

checkIfAuthenticatedWithCurrentRole() {
  msg_title "Checking your Authenticated Role"
  msg_debug "[checkIfAuthenticatedWithCurrentRole]"

  msg_status "Checking your role on aws"
  msg_debug "Executing 'aws s3 ls --profile $CURRENT_ROLE"

  result=$(aws s3 ls --profile $CURRENT_ROLE 2>/dev/null)

  if [ $? -ne 0 ]; then
    msg_error "You are not authenticated with role '$CURRENT_ROLE' on aws"
    msg_debug "Execution of 'aws s3 ls --profile $CURRENT_ROLE': Error: not correct profile"
    return 1 # false
  else
    msg_success "You are authenticated with role '$CURRENT_ROLE' on aws"
    msg_debug "Execution of 'aws s3 ls --profile $CURRENT_ROLE': Success"
    return 0 # true
  fi
}

# params: timestamp-string
# returns: a human readable string like or 'expired' when it's in the past
getTimeDifferenceOrExpired() {
  msg_debug "[getTimeDifferenceFromToken]"

  local expiration_timestamp="$1"

  # Current timestamp in your local timezone
  current_timestamp=$(TZ="$TIMEZONE" date +"%Y-%m-%dT%H:%M:%S")

  # Convert the token timestamp to UTC by stripping the timezone offset
  token_timestamp=${expiration_timestamp%+*}

  # Convert timestamps to Unix timestamps
  current_unix_timestamp=$(date -u -j -f "%Y-%m-%dT%H:%M:%S" "$current_timestamp" +"%s")
  token_unix_timestamp=$(date -u -j -f "%Y-%m-%dT%H:%M:%S" "$token_timestamp" +"%s")

  # Calculate time difference in seconds
  time_difference=$((token_unix_timestamp - current_unix_timestamp))

  # Check if the time difference is in the past
  if [[ $time_difference -lt 0 ]]; then
    echo "expired"
    exit 0
  fi

  # Calculate the number of years, days, hours, and minutes in the time difference
  years=$((time_difference / 31536000))
  days=$((time_difference / 86400))
  hours=$(((time_difference % 86400) / 3600))
  minutes=$(((time_difference % 3600) / 60))

  # Prepare the time difference string
  time_difference_string=""

  # Add years to the time difference string if it is nonzero
  if [[ $years -gt 0 ]]; then
    time_difference_string+=" $years years,"
  fi

  # Add days to the time difference string if it is nonzero
  if [[ $days -gt 0 ]]; then
    time_difference_string+=" $days days,"
  fi

  # Add hours to the time difference string if it is nonzero
  if [[ $hours -gt 0 ]]; then
    time_difference_string+=" $hours hours,"
  fi

  # Add minutes to the time difference string
  time_difference_string+=" $minutes minutes"

  # Trim leading whitespace from the time difference string
  time_difference_string="${time_difference_string#"${time_difference_string%%[![:space:]]*}"}"

  # Display the time difference or "IN THE PAST" if applicable
  if [[ -z $time_difference_string ]]; then
    echo "expired"
  else
    echo "$time_difference_string"
  fi
}

getExistingCredentials() {
  msg_title "Checking existing credentials"
  msg_debug "[getExistingCredentials]"

  local input_file="$AWS_CREDENTIALS_PATH"
  local output_file="$AWS_FILTERED_CREDENTIALS_PATH"

  if [[ ! -f "$output_file" ]]; then
    msg_status "Creating temp filtered_credentials file"
    touch $output_file
  fi

  msg_status "Extracting information out of your local aws credentials"

  # Check if the input file exists
  if [[ ! -f "$input_file" ]]; then
    msg_error "Input file not found: $input_file"
    return 1
  fi

  msg_status "Reading credentials"
  msg_debug "Start reading credential file"

  # Overwrite the output file if it exists
  if [[ -f "$output_file" ]]; then
    rm "$output_file"
    msg_debug "Remove output file"
  fi

  # Process the file and write filtered lines to the output file
  msg_status "Writing filtered credentials"

  while IFS= read -r line; do
    if [[ $line =~ \[[^]]+\] || -z $line ]]; then
      # Extract the role name
      role_name=$(sed -n 's/^\[\([^]]*\)\]$/\1/p' <<<"$line")
    elif [[ $line =~ ^x_security_token_expires ]]; then
      # Extract the x_security_token_expires value
      token_timestamp=$(awk -F "=" '{gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2}' <<<"$line")
      timediff_or_expired=$(getTimeDifferenceOrExpired "$token_timestamp")
      echo "$role_name - $timediff_or_expired" >>"$output_file"
    fi
  done <"$input_file"

  msg_debug "Filtered credentials have been written to $output_file."
  msg_success "Done"
}

showMenuToChooseRole() {
  msg_title "Selecting a role"
  msg_debug "[showMenuToChooseRole]"

  local menu_file="$AWS_FILTERED_CREDENTIALS_PATH"
  local extra_menu_option="Other role: Authenticate with aws" # when no role is good for the user or wants to authenticate

  while true; do
    # Read the menu options from the file
    local options=()
    local valid_options=()
    while IFS= read -r line; do
      options+=("$line")
    done <"$menu_file"

    # Add the 'other' option
    options+=("$extra_menu_option")

    # Display the menu
    for i in "${!options[@]}"; do
      local option="${options[$i]}"
      if [[ $option == *"expired"* ]]; then
        local option_index=$((i + 1))
        msg_strikethrough "[$option_index] ${option%% -*}${txt_reset} ${txt_red}Expired${txt_reset}"
      else
        local option_index=$((i + 1))
        msg "[$option_index] ${option%% -*} ${txt_green}Valid (${option#* - })${txt_reset}"
        valid_options+=("$option_index")
      fi
    done

    # Read user input
    msg_user_input "Enter a number: "
    read -r choice
    new_line

    # Validate the user input
    if [[ "${valid_options[*]}" =~ (^|[[:space:]])$choice($|[[:space:]]) ]]; then
      if [[ $choice -eq ${#valid_options[@]} ]]; then
        msg_debug "You selected: $extra_menu_option"
        CURRENT_ROLE="none"
        break
      else
        local selected_option="${options[$((choice - 1))]}"
        CURRENT_ROLE="${selected_option%% -*}"

        if [[ "$selected_option" == "$extra_menu_option" ]]; then
          CURRENT_ROLE="none"
          msg_debug "You selected: $extra_menu_option... need to authenticate again..."

          authenticateToAWS

          msg_status "Refreshing aws credential file"
          getExistingCredentials
        else
          msg_debug "You selected: $selected_option, not $extra_menu_option"
        fi
      fi

      if [ "$CURRENT_ROLE" != "none" ]; then
        msg_debug "Current Role is not 'none'"

        checkIfAuthenticatedWithCurrentRole

        if [ $? -ne 0 ]; then
          msg_status "Restart authentication"
          msg_debug "Is NOT the correct role -> authenticate again"
          authenticateToAWS
        else
          msg_debug "Is the correct role"
          break
        fi
      else
        msg_debug "Current Role is 'none'"
      fi

    else
      msg_error "Invalid option"
    fi
  done
}

askTeamName() {
  msg_title "Setting (team)name"
  msg_debug "[askTeamName]"

  msg_user_input "Enter your (team)name: "
  read -r userInputName
  TEAM_NAME=$userInputName
  msg_status "Saving name"
}

spinUpCluster() {
  msg_title "Spinning up cluster"
  msg_debug "[spinUpCluster]"

  msg_status "Spinning up"
  /bin/bash "$CREATE_CLUSTER_SCRIPT_PATH" "$TEAM_NAME" "$INSTANCE_GROUP_CONFIG_PATH" "$CURRENT_ROLE"
  msg_success "All set and done"
}

##########
# SCRIPT #
##########
init
getExistingCredentials
showMenuToChooseRole
askTeamName
spinUpCluster
exit
