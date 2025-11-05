#!/bin/bash

# --- Logger Configuration ---

# Set the global log level for the script.
# Messages with a level lower than this will not be printed.
# Available levels: DEBUG, INFO, WARN, ERROR
GLOBAL_LOG_LEVEL="DEBUG"

# Define log level integers
declare -rA LOG_LEVELS=([DEBUG]=0 [INFO]=1 [WARN]=2 [ERROR]=3)

# Define color codes for log levels
declare -rA LOG_COLORS=([DEBUG]='\e[0;34m' [INFO]='\e[0;32m' [WARN]='\e[0;33m' [ERROR]='\e[0;31m')
declare -rA COLOR_RESET='\e[0m'

# --- Logger Function ---

# Logs a message if the log level is high enough.
# Usage: logger <LEVEL> <LOG ID> "Your message here"

logger() {
  local level_name="$1"
  local component="$2"
  local message="$3"
  
  # Check if the provided log level is valid
  if [[ -z "${LOG_LEVELS[$level_name]}" ]]; then
    echo "Error: Invalid log level '$level_name'. Use DEBUG, INFO, WARN, or ERROR." >&2
    return 1
  fi
  
  local current_level="${LOG_LEVELS[$level_name]}"
  local script_level="${LOG_LEVELS[$GLOBAL_LOG_LEVEL]}"
  
  # Only log if the message's level is >= the script's global level
  if (( current_level >= script_level )); then
    local color="${LOG_COLORS[$level_name]}"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    # Print formatted log message to standard error
    printf "${color}[%s] [%s] [%s] [%s] %s${COLOR_RESET}\n" "$timestamp" "$level_name" "$NODE_NAME" "$component" "$message" >&2
  fi
}
