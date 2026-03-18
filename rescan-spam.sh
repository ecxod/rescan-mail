#!/usr/bin/env bash
#
# rescan-spam.sh
# ==============
#   Rescan INBOX eines Dovecot-Maildir-Users mit spamc (SpamAssassin)
#   - Ermittelt Mail-Base-Pfad automatisch aus dovecot-Konfiguration
#   - Berechnet neuen Spam-Score
#   - Loggt Ergebnisse
#   - Optional: verschiebt Spam in Junk (auskommentiert / mit --move)
#
# Aufruf-Beispiele:
#   ./rescan-spam.sh -u benutzer@domain.de
#   ./rescan-spam.sh -u benutzer@domain.de --move --dry-run
#   ./rescan-spam.sh -u benutzer@domain.de --learn-spam-threshold=7.0

set -u
set -e

# ==================== Konfiguration ====================

SPAMC="spamc"                             # ggf. spamc -d 127.0.0.1 -p 783
DEFAULT_THRESHOLD=5.0
LOGFILE="/var/log/rescan-spam.log"
JUNK_FOLDER=".Junk"                       # .Junk / .Spam / Spam – anpassen falls nötig

# =========================================================

usage() {
  cat <<EOF
Usage: $0 -u <benutzer@domain.de> [Optionen]

Optionen:
  --move                     Spam-Mails wirklich in Junk verschieben
  --learn-spam-threshold=N   Ab Score >= N als Spam lernen (--spam)
  --learn-ham                Alle Mails als Ham lernen (sehr vorsichtig!)
  --dry-run                  Nur simulieren, nichts ändern
  --help                     Diese Hilfe

Beispiele:
  $0 -u benutzer@domain.de
  $0 -u benutzer@domain.de --move --dry-run
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

# ────────────────────────────────────────────────
#    Mail-Base-Pfad aus Dovecot-Konfiguration holen
# ────────────────────────────────────────────────

# Versuchen, mail_home zu bekommen (meist /path/%d/%n oder ähnlich)
MAIL_HOME_TEMPLATE=$(doveconf -n mail_home 2>/dev/null || true)

if [[ -z "$MAIL_HOME_TEMPLATE" ]]; then
  # Fallback: mail_location auswerten (oft komplizierter: maildir:/path/%d/%n/Maildir)
  MAIL_LOCATION=$(doveconf -n mail_location 2>/dev/null || true)
  if [[ "$MAIL_LOCATION" =~ ^maildir:(.+)/Maildir(:.*)?$ ]]; then
    MAIL_HOME_TEMPLATE="${BASH_REMATCH[1]}"
  else
    echo "Fehler: Weder mail_home noch mail_location mit Maildir konnte ermittelt werden."
    echo "Bitte setze MAIL_BASE manuell im Skript."
    exit 3
  fi
fi

# Variablen ersetzen: %{domain} → domain, %{username} → localpart, %{user} → user@domain
# Wir brauchen nur den statischen Teil vor den Variablen
# Einfache Variante: alles bis zum ersten % abschneiden
MAIL_BASE="${MAIL_HOME_TEMPLATE%%\%*}"

# Sicherstellen, dass kein abschließender / fehlt
MAIL_BASE="${MAIL_BASE%/}"

[[ -z "$MAIL_BASE" || ! -d "$MAIL_BASE" ]] && {
  echo "Fehler: Konnte plausiblen Mail-Base-Pfad nicht ermitteln."
  echo "Gefunden: '$MAIL_BASE'"
  echo "Template war: '$MAIL_HOME_TEMPLATE'"
  exit 4
}

echo "Automatisch ermittelter Mail-Base-Pfad: $MAIL_BASE" | tee -a "$LOGFILE"

# ────────────────────────────────────────────────
#    User → Maildir-Pfad
# ────────────────────────────────────────────────

DOMAIN="${USER##*@}"
USERNAME="${USER%@*}"
MAILDIR="$MAIL_BASE/$DOMAIN/$USERNAME/Maildir"

[[ ! -d "$MAILDIR" ]] && {
  echo "Fehler: Maildir nicht gefunden: $MAILDIR"
  exit 2
}

INBOX_CUR="$MAILDIR/cur"
INBOX_NEW="$MAILDIR/new"
JUNK_DIR="$MAILDIR/$JUNK_FOLDER"

echo "=== Rescan für $USER ===" | tee -a "$LOGFILE"
echo "Maildir: $MAILDIR" | tee -a "$LOGFILE"
echo "Spamc:   $(spamc -V 2>/dev/null || echo 'nicht gefunden')" | tee -a "$LOGFILE"
echo "" | tee -a "$LOGFILE"

# Funktion zum Verarbeiten einer Mail
process_mail() {
  local file="$1"
  local base=$(basename "$file")

  local output
  output=$(cat "$file" | $SPAMC --check 2>/dev/null)

  local score_line=$(echo "$output" | grep -m1 '^X-Spam-Status:')
  local score=$(echo "$score_line" | grep -oP 'score=\K-?\d+\.?\d*' || echo "?.??")

  echo "$base → Score = $score" | tee -a "$LOGFILE"

  # Bayes lernen – Spam
  if [[ -n "$LEARN_SPAM_THRESHOLD" ]] && command -v bc >/dev/null && (( $(echo "$score >= $LEARN_SPAM_THRESHOLD" | bc -l) )); then
    echo "   → LERNE SPAM (>$LEARN_SPAM_THRESHOLD)" | tee -a "$LOGFILE"
    [[ $DRY_RUN -eq 0 ]] && cat "$file" | $SPAMC --spam --learntype=bulk >/dev/null
  fi

  # Bayes lernen – Ham (alle)
  if [[ $LEARN_HAM -eq 1 ]]; then
    echo "   → LERNE HAM (Vorsicht!)" | tee -a "$LOGFILE"
    [[ $DRY_RUN -eq 0 ]] && cat "$file" | $SPAMC --ham --learntype=bulk >/dev/null
  fi

  # Verschieben
  if [[ $DO_MOVE -eq 1 ]] && command -v bc >/dev/null && (( $(echo "$score >= $DEFAULT_THRESHOLD" | bc -l) )); then
    echo "   → verschiebe nach $JUNK_FOLDER" | tee -a "$LOGFILE"
    if [[ $DRY_RUN -eq 0 ]]; then
      mkdir -p "$JUNK_DIR/cur" "$JUNK_DIR/tmp" "$JUNK_DIR/new" 2>/dev/null || true
      mv -f "$file" "$JUNK_DIR/cur/$base"
    fi
  fi
}

# =============================================
# MAIN – Mails verarbeiten
# =============================================

count=0

for dir in "$INBOX_NEW" "$INBOX_CUR"; do
  [[ ! -d "$dir" ]] && continue
  for f in "$dir"/*; do
    [[ -f "$f" ]] || continue
    process_mail "$f"
    ((count++))
  done
done

echo "" | tee -a "$LOGFILE"
echo "Fertig: $count Mails verarbeitet." | tee -a "$LOGFILE"

if [[ $DRY_RUN -eq 1 ]]; then
  echo "(Dry-Run – keine Änderungen vorgenommen)" | tee -a "$LOGFILE"
fi