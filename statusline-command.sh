#!/bin/bash

# Read JSON input from stdin
input=$(cat)

# Extract basic info
project_dir=$(echo "$input" | jq -r '.workspace.project_dir')
repo_name=$(basename "$project_dir")
model=$(echo "$input" | jq -r '.model.display_name')

# Fetch API usage from Anthropic (cached)
CACHE_FILE="/tmp/claude-usage-cache.json"
CACHE_MAX_AGE=60

fetch_usage() {
  # Get OAuth token from Keychain
  token=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
  if [ -n "$token" ]; then
    curl -s \
      -H "Authorization: Bearer $token" \
      -H "anthropic-beta: oauth-2025-04-20" \
      -H "User-Agent: claude-code/2.0.76" \
      "https://api.anthropic.com/api/oauth/usage" 2>/dev/null
  fi
}

# Check cache age
if [ -f "$CACHE_FILE" ]; then
  cache_age=$(($(date +%s) - $(stat -f %m "$CACHE_FILE" 2>/dev/null || echo 0)))
  if [ $cache_age -lt $CACHE_MAX_AGE ]; then
    api_usage=$(cat "$CACHE_FILE")
  fi
fi

# Fetch fresh if no cache
if [ -z "$api_usage" ]; then
  api_usage=$(fetch_usage)
  if [ -n "$api_usage" ] && echo "$api_usage" | jq -e '.five_hour' >/dev/null 2>&1; then
    echo "$api_usage" > "$CACHE_FILE"
  fi
fi

# Parse API usage
five_hour_pct=$(echo "$api_usage" | jq -r '.five_hour.utilization // 0' 2>/dev/null | cut -d. -f1)
seven_day_pct=$(echo "$api_usage" | jq -r '.seven_day.utilization // 0' 2>/dev/null | cut -d. -f1)
opus_pct=$(echo "$api_usage" | jq -r '.seven_day_opus.utilization // 0' 2>/dev/null | cut -d. -f1)

# Get git branch
cd "$project_dir" 2>/dev/null
branch=$(git -c core.useReplaceRefs=false branch --show-current 2>/dev/null || echo "no-git")

# Calculate context window usage percentage
usage=$(echo "$input" | jq '.context_window.current_usage')
if [ "$usage" != "null" ] && [ -n "$usage" ]; then
  current=$(echo "$usage" | jq '.input_tokens + .cache_creation_input_tokens + .cache_read_input_tokens')
  size=$(echo "$input" | jq '.context_window.context_window_size')
  if [ "$size" != "null" ] && [ "$size" -gt 0 ] 2>/dev/null; then
    pct=$((current * 100 / size))
  else
    pct=0
  fi

  # Create progress bar
  bar_width=10
  filled=$((pct * bar_width / 100))
  unfilled=$((bar_width - filled))
  filled_bar=""
  unfilled_bar=""
  for i in $(seq 1 $filled); do filled_bar="${filled_bar}█"; done
  for i in $(seq 1 $unfilled); do unfilled_bar="${unfilled_bar}░"; done

  context_display="\033[37m${filled_bar}\033[2m${unfilled_bar}\033[0m ${pct}%"
else
  context_display="░░░░░░░░░░ 0%"
fi

# Calculate session usage (total tokens)
total_input=$(echo "$input" | jq '.context_window.total_input_tokens // 0')
total_output=$(echo "$input" | jq '.context_window.total_output_tokens // 0')
session_total=$((total_input + total_output))

# Format with K/M suffix for readability
if [ $session_total -ge 1000000 ]; then
  session_display=$(awk "BEGIN {printf \"%.1fM\", $session_total/1000000}")
elif [ $session_total -ge 1000 ]; then
  session_display=$(awk "BEGIN {printf \"%.1fK\", $session_total/1000}")
else
  session_display="${session_total}"
fi

# Color code usage percentages (green < 60, yellow 60-89, red >= 90)
color_pct() {
  local pct=$1
  if [ "$pct" -ge 90 ]; then
    echo "\033[31m${pct}%\033[0m"  # red
  elif [ "$pct" -ge 60 ]; then
    echo "\033[33m${pct}%\033[0m"  # yellow
  else
    echo "\033[32m${pct}%\033[0m"  # green
  fi
}

five_hour_display=$(color_pct "$five_hour_pct")
seven_day_display=$(color_pct "$seven_day_pct")

# Output status line
printf "\033[33m%s\033[0m | %s | %b | \033[36m%s\033[0m | 5h %b 7d %b | (\033[33m%s\033[0m)" \
  "$repo_name" \
  "$model" \
  "$context_display" \
  "$session_display" \
  "$five_hour_display" \
  "$seven_day_display" \
  "$branch"
