#!/usr/bin/env bash
set -u
set -o pipefail

INBOX="${HOME}/Inbox_Genius"
VAULT="${HOME}/Case_Vault"
ARCHIVE="${VAULT}/archive"
DUP_DIR="${ARCHIVE}/duplicates"
TEXT_DIR="${VAULT}/text"
LOG_DIR="${VAULT}/logs"
QUAR_DIR="${VAULT}/quarantine"

TIMELINE="${LOG_DIR}/Master_Timeline.csv"
MASTER_MD="${LOG_DIR}/Master_File.md"

PROCESS_LOG="${LOG_DIR}/processing.log"
WARN_LOG="${LOG_DIR}/warnings.log"
DUP_LOG="${LOG_DIR}/duplicates.log"
FAIL_LOG="${LOG_DIR}/extraction_failures.log"
MIN_TEXT_YIELD=120

log_line() {
  printf '[%s] [%s] %s
' "$(date -Iseconds)" "$2" "$3" >> "$1"
}

csv_escape() {
  local s="$1"
  s="${s//\"/\"\"}"
  printf '"%s"' "$s"
}

sanitize_ascii_snake() {
  local s="$1"
  s="$(printf '%s' "$s" | tr '[:upper:]' '[:lower:]')"
  s="$(printf '%s' "$s" | iconv -f utf-8 -t ascii//TRANSLIT 2>/dev/null || printf '%s' "$s")"
  s="$(printf '%s' "$s" | sed -E 's/[^a-z0-9]+/_/g; s/^_+//; s/_+$//; s/_{2,}/_/g')"
  [[ -n "$s" ]] || s="file"
  printf '%s' "$s"
}

char_count() { wc -m < "$1" | tr -d ' '; }

ensure_dirs() {
  mkdir -p "$INBOX" "$ARCHIVE" "$DUP_DIR" "$TEXT_DIR" "$LOG_DIR" "$QUAR_DIR"
}

ensure_files() {
  [[ -f "$TIMELINE" ]] || cat > "$TIMELINE" <<'CSVEOF'
Intake_Timestamp,Document_Date,Filename_Original,Filename_Normalized,Full_Path,Doc_Type,Source_Entity,Target_Entity,Case_Area,Status_CNESST,Pressure_Flag,Medical_Flag,Language_Guess,OCR_Char_Count,Summary_Short,Notes,Processing_Flag,SHA256
CSVEOF
  [[ -f "$MASTER_MD" ]] || printf '# Master File — CASE SHIELD (E4C / CNESTT)
' > "$MASTER_MD"
  touch "$PROCESS_LOG" "$WARN_LOG" "$DUP_LOG" "$FAIL_LOG"
}

make_scan_text() {
  if iconv -f utf-8 -t ascii//TRANSLIT "$1" 2>/dev/null | tr '[:upper:]' '[:lower:]' > "$2"; then
    :
  else
    LC_ALL=C tr '[:upper:]' '[:lower:]' < "$1" > "$2" 2>/dev/null || cp -f "$1" "$2"
  fi
}

guess_document_date() {
  rg -o -m1 '\b20[0-9]{2}[-/.][01][0-9][-/.][0-3][0-9]\b|\b[0-3][0-9][-/.][01][0-9][-/.]20[0-9]{2}\b' "$1" 2>/dev/null | head -n 1 | tr '/.' '-'
}

guess_language() {
  if grep -Eiq '(bonjour|rendez|vous|clinique|medicale|travail|accident|physio|osteo|hopital|dossier)' "$1"; then
    printf 'FRA'
  elif grep -Eiq '(appointment|clinic|hospital|worker|employer|injury|report|claim)' "$1"; then
    printf 'ENG'
  else
    printf 'UNKNOWN'
  fi
}

guess_doc_type() {
  if grep -Eiq '(emergency room|er report|urgence)' "$1"; then printf 'ER_Report'
  elif grep -Eiq '(physio|physiotherapy|action sport physio)' "$1"; then printf 'Physio_Record'
  elif grep -Eiq '(radiology|ct|mri|x-ray|xray|imaging|requisition|temporal bone)' "$1"; then printf 'Imaging_Record'
  elif grep -Eiq '(cnesst|csst|attestation medicale|reclamation)' "$1"; then printf 'CNESTT_Record'
  elif grep -Eiq '(clinique medicale 3000|appointment|confirmation|reminder|rvsq|clinicmaster)' "$1"; then printf 'Appointment_Record'
  elif grep -Eiq '(vincent|alain|dan|e4c|emballage 4 coins|call me|come at e4c|paid for 2 weeks)' "$1"; then printf 'Employer_Communication'
  elif grep -Eiq '(doctor|clinic|medical|concussion|tccl|cervical|knee|hospital)' "$1"; then printf 'Clinical_Record'
  else printf 'Unclassified'; fi
}

guess_source_entity() {
  if grep -Eiq 'clinique medicale 3000' "$1"; then printf 'Clinique_Medicale_3000'
  elif grep -Eiq 'action sport physio' "$1"; then printf 'Action_Sport_Physio_Villeray'
  elif grep -Eiq '(cnesst|csst)' "$1"; then printf 'CNESTT'
  elif grep -Eiq 'vincent' "$1"; then printf 'Vincent'
  elif grep -Eiq 'alain' "$1"; then printf 'Alain'
  elif grep -Eiq '\bdan\b' "$1"; then printf 'Dan'
  elif grep -Eiq '(e4c|emballage 4 coins)' "$1"; then printf 'E4C'
  elif grep -Eiq '(hospital|hopital|er|urgence)' "$1"; then printf 'Hospital_ER'
  else printf 'Unknown'; fi
}

guess_case_area() {
  if grep -Eiq '(cnesst|csst|claim|reclamation)' "$1"; then printf 'CNESTT'
  elif grep -Eiq '(vincent|alain|dan|e4c|emballage 4 coins|call me|come at e4c|paid for 2 weeks)' "$1"; then printf 'Employer'
  elif grep -Eiq '(appointment|rvsq|clinicmaster|reminder|confirmation)' "$1"; then printf 'Appointment'
  elif grep -Eiq '(concussion|tccl|cervical|knee|hospital|doctor|medical|physio|ct|mri|x-ray|xray|radiology|csf|beta 2 transferrin)' "$1"; then printf 'Medical'
  else printf 'General'; fi
}

guess_pressure_flag() {
  if grep -Eiq '(why are you not answering the phone|need to talk|you need to come|take your appointment fast|paid for 2 weeks|pay for physio|pay for osteo|not normal normal and securitary|documents must not be sent by text|documents must not be sent by email)' "$1"; then printf 'HIGH'
  elif grep -Eiq '(vincent|alain|dan|e4c|emballage 4 coins|appointment fast|call me|come in person|physio|osteo)' "$1"; then printf 'MEDIUM'
  else printf 'NONE'; fi
}

guess_medical_flag() {
  if grep -Eiq '(beta.?2.?transferrin|csf|leak|temporal bone)' "$1"; then printf 'POSSIBLE_CSF'
  elif grep -Eiq '(concussion|tccl|neurolog|head injury|brain|vertigo|dizziness)' "$1"; then printf 'NEURO'
  elif grep -Eiq '(ct|mri|x-ray|xray|radiology|imaging|requisition)' "$1"; then printf 'IMAGING_PENDING'
  elif grep -Eiq '(cervical|knee|physio|hospital|clinic|medical|injury)' "$1"; then printf 'ACTIVE_INJURY'
  else printf 'ROUTINE'; fi
}

summary_short() {
  tr '\n\r' '  ' < "$1" | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//' | cut -c1-180
}

append_timeline_row() {
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n'     "$(csv_escape "$1")" "$(csv_escape "$2")" "$(csv_escape "$3")" "$(csv_escape "$4")"     "$(csv_escape "$5")" "$(csv_escape "$6")" "$(csv_escape "$7")" "$(csv_escape "$8")"     "$(csv_escape "$9")" "$(csv_escape "${10}")" "$(csv_escape "${11}")" "$(csv_escape "${12}")"     "$(csv_escape "${13}")" "$(csv_escape "${14}")" "$(csv_escape "${15}")" "$(csv_escape "${16}")"     "$(csv_escape "${17}")" "$(csv_escape "${18}")" >> "$TIMELINE"
}

rebuild_master() {
  cat > "$MASTER_MD" <<EOF_MASTER
# Master File — CASE SHIELD (E4C / CNESTT)

## Case Overview
Local-first intake pipeline active.
Last rebuild: $(date -Iseconds)

## Parties Involved
- Shane Osante Turon
- E4C / Emballage 4 Coins
- Vincent Serravalle
- Alain
- Dan
- CNESTT
- Clinique Medicale 3000

## Chronology
\`\`\`csv
$(tail -n 20 "$TIMELINE")
\`\`\`

## Evidence Index
Indexed items: $(tail -n +2 "$TIMELINE" | wc -l | tr -d ' ')

## Pending Actions
- Review logs/Master_Timeline.csv
- Review extracted text in Case_Vault/text
- Review logs in Case_Vault/logs
EOF_MASTER
}

extract_pdf() {
  : > "$2"
  timeout 300 pdftotext -layout "$1" - > "$2" 2>> "$WARN_LOG" || true
  if [[ "$(char_count "$2")" -lt "$MIN_TEXT_YIELD" ]]; then
    rm -f "$3/ocr.txt" "$3/ocr.pdf"
    timeout 1800 ocrmypdf -q -l eng+fra --skip-text --sidecar "$3/ocr.txt" "$1" "$3/ocr.pdf" >> "$PROCESS_LOG" 2>> "$WARN_LOG" || true
    [[ -s "$3/ocr.txt" ]] && cp -f "$3/ocr.txt" "$2"
  fi
}

extract_image() {
  rm -f "$3/tess.txt"
  timeout 600 tesseract "$1" "$3/tess" -l eng+fra >/dev/null 2>> "$WARN_LOG" || true
  [[ -s "$3/tess.txt" ]] && cp -f "$3/tess.txt" "$2"
}

process_file() {
  local src="$1"
  [[ -f "$src" ]] || return 0
  local orig_name ext base_name base_norm sha ts stamp tmp raw scan mode archive_name archive_path text_path
  orig_name="$(basename "$src")"
  [[ "$orig_name" =~ ^\. ]] && return 0
  case "$orig_name" in *.tmp|*.part|*.partial|*.crdownload|*.swp) return 0 ;; esac
  ext="${orig_name##*.}"; [[ "$orig_name" == "$ext" ]] && ext=""; ext="$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')"
  base_name="${orig_name%.*}"; [[ "$orig_name" == "$base_name" ]] && base_name="$orig_name"
  sha="$(sha256sum "$src" | awk '{print $1}')"
  ts="$(date -Iseconds)"
  stamp="$(date +%Y%m%d_%H%M%S)"
  base_norm="$(sanitize_ascii_snake "$base_name")"
  if grep -Fq "$sha" "$TIMELINE" 2>/dev/null; then
    archive_name="${stamp}__${base_norm}__${sha:0:12}${ext:+.${ext}}"
    archive_path="${DUP_DIR}/${archive_name}"
    mv -f "$src" "$archive_path"
    log_line "$DUP_LOG" "DUPLICATE" "$orig_name -> $archive_path sha256=$sha"
    append_timeline_row "$ts" "" "$orig_name" "$archive_name" "$archive_path" "Unclassified" "Unknown" "Worker" "General" "NONE" "NONE" "ROUTINE" "UNKNOWN" "0" "duplicate file moved to duplicates" "duplicate hash" "DUPLICATE" "$sha"
    rebuild_master
    return 0
  fi
  tmp="$(mktemp -d)"; raw="$tmp/raw.txt"; scan="$tmp/scan.txt"; : > "$raw"
  case "$ext" in
    txt|md|csv|eml) cp -f "$src" "$raw"; mode="TEXT_FILE" ;;
    pdf) extract_pdf "$src" "$raw" "$tmp"; mode="PDF" ;;
    png|jpg|jpeg|tif|tiff|bmp|webp) extract_image "$src" "$raw" "$tmp"; mode="IMAGE_OCR" ;;
    *)
      archive_name="${stamp}__${base_norm}__${sha:0:12}${ext:+.${ext}}"
      archive_path="${QUAR_DIR}/${archive_name}"
      mv -f "$src" "$archive_path"
      log_line "$WARN_LOG" "UNSUPPORTED" "$orig_name -> $archive_path"
      append_timeline_row "$ts" "" "$orig_name" "$archive_name" "$archive_path" "Unclassified" "Unknown" "Worker" "General" "NONE" "NONE" "ROUTINE" "UNKNOWN" "0" "unsupported type" "UNSUPPORTED_TYPE" "UNSUPPORTED_TYPE" "$sha"
      rebuild_master
      rm -rf "$tmp"; return 0 ;;
  esac
  if [[ ! -s "$raw" ]]; then
    archive_name="${stamp}__${base_norm}__${sha:0:12}${ext:+.${ext}}"
    archive_path="${QUAR_DIR}/${archive_name}"
    mv -f "$src" "$archive_path"
    log_line "$FAIL_LOG" "EXTRACTION_FAILED" "$orig_name -> $archive_path mode=$mode"
    append_timeline_row "$ts" "" "$orig_name" "$archive_name" "$archive_path" "Unclassified" "Unknown" "Worker" "General" "NONE" "NONE" "ROUTINE" "UNKNOWN" "0" "extraction failed" "$mode" "EXTRACTION_FAILED" "$sha"
    rebuild_master
    rm -rf "$tmp"; return 0
  fi
  make_scan_text "$raw" "$scan"
  archive_name="${stamp}__${base_norm}__${sha:0:12}${ext:+.${ext}}"
  archive_path="${ARCHIVE}/${archive_name}"
  text_path="${TEXT_DIR}/${archive_name}.txt"
  mv -f "$src" "$archive_path"
  cp -f "$raw" "$text_path"
  append_timeline_row     "$ts" "$(guess_document_date "$raw")" "$orig_name" "$archive_name" "$archive_path"     "$(guess_doc_type "$scan")" "$(guess_source_entity "$scan")" "Shane" "$(guess_case_area "$scan")"     "$(grep -Eiq '(cnesst|csst)' "$scan" && printf 'MENTIONED' || printf 'NONE')"     "$(guess_pressure_flag "$scan")" "$(guess_medical_flag "$scan")" "$(guess_language "$scan")"     "$(char_count "$raw")" "$(summary_short "$raw")" "$mode" "PROCESSED" "$sha"
  log_line "$PROCESS_LOG" "PROCESSED" "$orig_name -> $archive_path text=$text_path sha256=$sha"
  rebuild_master
  rm -rf "$tmp"
}

process_backlog() {
  find "$INBOX" -type f -print0 | while IFS= read -r -d '' f; do process_file "$f"; done
}

watch_loop() {
  while true; do
    while IFS= read -r f; do process_file "$f"; done < <(inotifywait -q -m -r -e close_write,moved_to --format '%w%f' "$INBOX" 2>> "$WARN_LOG")
    log_line "$WARN_LOG" "WATCH" "inotify loop ended; restarting"
    sleep 2
  done
}

main() {
  ensure_dirs
  ensure_files
  mkdir -p "$INBOX/Google_Drive_Inbox" "$INBOX/Gmail_Inbox"
  log_line "$PROCESS_LOG" "INFO" "Case Shield pipeline started."
  echo "Case Shield initialized."
  echo "Inbox: $INBOX"
  echo "Vault: $VAULT"
  process_backlog
  watch_loop
}

main "$@"
