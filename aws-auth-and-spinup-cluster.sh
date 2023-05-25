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
  SERVER_TIME_OFFSET="-2H"                                                            # TODO: fix this depending on server time ?
  CURRENT_ROLE="none"
  TEAM_NAME="none"
  CREATE_CLUSTER_SCRIPT_PATH="$HOME/awsEmrClusterConfigs/emr-create-cluster.sh"
  INSTANCE_GROUP_CONFIG_PATH="$HOME/awsEmrClusterConfigs/emr-default-instance-group-config.json"
}

authenticateToAWS() {
  msg_title "Authenticating to AWS"
  msg_debug "[authenticateToAWS]"

  if command_exists gimme-aws-creds; then
    msg_debug "Executing 'gimme-aws-creds'"
    msg_status "Start authentication"
    gimme-aws-creds
  else
    msg_error "Cannot run command 'gimme-aws-creds' (not installed)"
  fi
}

checkIfAuthenticatedWithCurrentRole() {
  msg_title "Checking your Authenticated Role"
  msg_debug "[checkIfAuthenticatedWithCurrentRole]"

  msg_debug "Executing 'aws s3 ls --profile $CURRENT_ROLE"
  msg_status "Checking your role on aws"

  result=$(aws s3 ls --profile $CURRENT_ROLE 2>/dev/null)

  if [ $? -ne 0 ]; then
    msg_debug "Execution of 'aws s3 ls --profile $CURRENT_ROLE': Error: not correct profile"
    msg_error "You are not authenticated with role '$CURRENT_ROLE' on aws"
    return 1 # false
  else
    msg_debug "Execution of 'aws s3 ls --profile $CURRENT_ROLE': Success"
    msg_success "You are authenticated with role '$CURRENT_ROLE' on aws"
    return 0 # true
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

  msg_status "Reading file"
  msg_debug "Start reading credential file"

  # Overwrite the output file if it exists
  if [[ -f "$output_file" ]]; then
    rm "$output_file"
    msg_debug "Remove output file"
  fi

  # Process the file and write filtered lines to the output file
  while IFS= read -r line; do
    if [[ $line =~ ^\[[^\]]*Role\]$ || -z $line ]]; then
      # Extract the role name
      role_name=$(sed -n 's/^\[\([^]]*\)\]$/\1/p' <<<"$line")
    elif [[ $line =~ ^\[NIKE\. ]]; then
      # Write the line to the output file
      msg_debug "Write the line to the output file"
      msg_status "Writing to file"
      echo "$line" >>"$output_file"
    elif [[ $line =~ ^x_security_token_expires ]]; then
      # Extract the x_security_token_expires value
      expires_line=$(awk -F "=" '{gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2}' <<<"$line")

      # Strip the timezone offset from the timestamp
      expires_stripped=${expires_line%+*}

      # Calculate the time difference in seconds
      # time_diff=$(($(date -j -f "%Y-%m-%dT%H:%M:%S" "$expires_stripped" +"%s") - $(date +"%s")))
      time_diff=$(($(date -j -f "%Y-%m-%dT%H:%M:%S" "$expires_stripped" +"%s") - $(date -v$SERVER_TIME_OFFSET +"%s")))

      if [[ $time_diff -gt 0 ]]; then
        # Format the time difference in days, hours, and minutes
        days=$((time_diff / 86400))
        hours=$((time_diff % 86400 / 3600))
        minutes=$((time_diff % 3600 / 60))

        echo "$role_name - $days days, $hours hours, $minutes minutes" >>"$output_file"
        msg_debug "Write role that isn't expired"
      else
        echo "$role_name - expired" >>"$output_file"
        msg_debug "Write role that's expired"
      fi
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
        msg_strikethrough "[$option_index] ${option%% -*}${txt_reset} - ${txt_red}${option#* - }${txt_reset}"
      else
        local option_index=$((i + 1))
        echo "[$option_index] ${option%% -*}"
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
          msg_debug "Is NOT the correct role -> authenticate again"
          msg_status "Restart authentication"
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
