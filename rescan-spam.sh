#!/usr/bin/env bash
#
# rescan-spam.sh
# ==============
#   Rescan INBOX eines Dovecot-Maildir-Users mit spamc (SpamAssassin)
#   - Berechnet neuen Spam-Score
#   - Loggt Ergebnisse
#   - Optional: verschiebt Spam in Junk (auskommentiert!)
#   - Optional: Bayes-Training (sehr vorsichtig!)
#
# Aufruf:   ./rescan-spam.sh -u benutzer@domain.de
#           ./rescan-spam.sh -u benutzer@domain.de --move --learn-spam-threshold=7.0
#
# Voraussetzungen:
#   - spamc läuft (spamd muss aktiv sein)
#   - User hat Maildir unter deinem Pfad (aus dovecot.conf: /mnt/eichert2/vmail/%d/%n/Maildir)
#   - Script als root oder vmail laufen lassen (wegen Rechten)

set -u
set -e

# ==================== Konfiguration ====================

MAIL_BASE="/mnt/eichert2/vmail"           # aus deiner dovecot.conf
SPAMC="spamc"                             # oder spamc -d 127.0.0.1 -p 783
DEFAULT_THRESHOLD=5.0
LOGFILE="/var/log/rescan-spam.log"

# =========================================================

usage() {
  cat <<EOF
Usage: $0 -u <user@domain> [Optionen]

Optionen:
  --move                     Spam-Mails wirklich in Junk verschieben
  --learn-spam-threshold=N   Ab Score N als Spam lernen (--spam)
  --learn-ham                Alle Mails als Ham lernen (sehr gefährlich!)
  --dry-run                  Nur simulieren, nichts ändern
  --help                     Diese Hilfe

Beispiel:
  $0 -u benutzer@domain.de --move --learn-spam-threshold=7.0
EOF
  exit 1
}

# Parameter parsen
DRY_RUN=0
DO_MOVE=0
LEARN_SPAM_THRESHOLD=""
LEARN_HAM=0
USER=""

while [[ $# -gt 0 ]]; do
  case $1 in
    -u)          USER="$2"; shift 2 ;;
    --move)      DO_MOVE=1; shift ;;
    --dry-run)   DRY_RUN=1; shift ;;
    --learn-spam-threshold=*) LEARN_SPAM_THRESHOLD="${1#*=}"; shift ;;
    --learn-ham) LEARN_HAM=1; shift ;;
    --help|-h)   usage ;;
    *)           echo "Unbekannte Option: $1"; usage ;;
  esac
done

[[ -z "$USER" ]] && { echo "Fehler: -u <user@domain> fehlt"; usage; }

# User -> Maildir-Pfad umwandeln (dein Format: domain/username)
DOMAIN="${USER##*@}"
USERNAME="${USER%@*}"
MAILDIR="$MAIL_BASE/$DOMAIN/$USERNAME/Maildir"

[[ ! -d "$MAILDIR" ]] && { echo "Fehler: Maildir nicht gefunden: $MAILDIR"; exit 2; }

INBOX_CUR="$MAILDIR/cur"
INBOX_NEW="$MAILDIR/new"
JUNK_DIR="$MAILDIR/.Junk"   # oder .Spam / .Junk – passe ggf. an!

[[ ! -d "$INBOX_CUR" ]] && { echo "Warnung: cur/ fehlt"; }

echo "=== Rescan für $USER ===" | tee -a "$LOGFILE"
echo "Maildir: $MAILDIR" | tee -a "$LOGFILE"
echo "Spamc:   $(spamc -V 2>/dev/null || echo 'nicht gefunden')" | tee -a "$LOGFILE"
echo "" | tee -a "$LOGFILE"

# Funktion zum Verarbeiten einer einzelnen Mail
process_mail() {
  local file="$1"
  local base=$(basename "$file")

  # Mail durch spamc jagen (nur Check, kein Delivery)
  local output
  output=$(cat "$file" | $SPAMC --check 2>/dev/null)

  # Score extrahieren (Zeile: X-Spam-Status: No, score=2.1 ...)
  local score_line=$(echo "$output" | grep -m1 '^X-Spam-Status:')
  local score=$(echo "$score_line" | grep -oP 'score=\K-?\d+\.?\d*')

  if [[ -z "$score" ]]; then
    echo "WARN: Score nicht gefunden für $base" | tee -a "$LOGFILE"
    return
  fi

  echo "$base → Score = $score" | tee -a "$LOGFILE"

  # Optional: Bayes lernen
  if [[ -n "$LEARN_SPAM_THRESHOLD" && $(echo "$score >= $LEARN_SPAM_THRESHOLD" | bc -l) -eq 1 ]]; then
    echo "   → LERNE SPAM (>$LEARN_SPAM_THRESHOLD)" | tee -a "$LOGFILE"
    [[ $DRY_RUN -eq 0 ]] && cat "$file" | $SPAMC --spam --learntype=bulk >/dev/null
  fi

  if [[ $LEARN_HAM -eq 1 ]]; then
    echo "   → LERNE HAM (alle!)" | tee -a "$LOGFILE"
    [[ $DRY_RUN -eq 0 ]] && cat "$file" | $SPAMC --ham --learntype=bulk >/dev/null
  fi

  # Optional: Verschieben in Junk
  if [[ $DO_MOVE -eq 1 && $(echo "$score >= $DEFAULT_THRESHOLD" | bc -l) -eq 1 ]]; then
    echo "   → WÜRDE NACH Junk VERSCHIEBEN" | tee -a "$LOGFILE"
    if [[ $DRY_RUN -eq 0 ]]; then
      # Mail in Junk/cur verschieben (Dovecot-kompatibel)
      local target="$JUNK_DIR/cur/$base"
      mkdir -p "$JUNK_DIR/cur" "$JUNK_DIR/tmp" "$JUNK_DIR/new"
      mv "$file" "$target"
    fi
  fi
}

# =============================================
# MAIN
# =============================================

# Zähler
count=0
moved=0

# new/ zuerst (sehr junge Mails)
for f in "$INBOX_NEW"/*; do
  [[ -f "$f" ]] || continue
  process_mail "$f"
  ((count++))
done

# cur/ (gelesene Mails)
for f in "$INBOX_CUR"/*; do
  [[ -f "$f" ]] || continue
  process_mail "$f"
  ((count++))
done

echo "" | tee -a "$LOGFILE"
echo "Fertig: $count Mails verarbeitet." | tee -a "$LOGFILE"
[[ $moved -gt 0 ]] && echo "$moved Mails nach Junk verschoben." | tee -a "$LOGFILE"

if [[ $DRY_RUN -eq 1 ]]; then
  echo "(Dry-Run – nichts wurde geändert oder gelernt)" | tee -a "$LOGFILE"
fi