#!/usr/bin/env bash
set -euo pipefail
HOME_DIR="$HOME"
ENV_FILE="$HOME_DIR/.config/case-shield/gdrive.env"
LOG_DIR="$HOME_DIR/Case_Vault/logs"
mkdir -p "$LOG_DIR" "$HOME_DIR/Inbox_Genius/Google_Drive_Inbox"
LOG_FILE="$LOG_DIR/rclone_gdrive_sync.log"
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"
REMOTE_NAME="${GDRIVE_REMOTE:-${RCLONE_REMOTE:-case_shield_gdrive}}"
REMOTE_FOLDER="${GDRIVE_FOLDER:-CaseShieldInbox}"
TARGET="$HOME_DIR/Inbox_Genius/Google_Drive_Inbox"
if ! command -v rclone >/dev/null 2>&1; then
  printf '[%s] SKIP rclone missing
' "$(date -Iseconds)" >> "$LOG_FILE"
  exit 0
fi
if ! rclone lsd "${REMOTE_NAME}:" >/dev/null 2>&1; then
  printf '[%s] SKIP remote unavailable %s
' "$(date -Iseconds)" "$REMOTE_NAME" >> "$LOG_FILE"
  exit 0
fi
rclone move "${REMOTE_NAME}:${REMOTE_FOLDER}" "$TARGET" --create-empty-src-dirs --log-file "$LOG_FILE" --log-level INFO
