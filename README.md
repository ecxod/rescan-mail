# rescan-mail

SpamAssassin cannot simply re-process already delivered emails with full scanning (all plugins, RBL checks, etc.) and update headers or move messages — that only happens during the original delivery phase (Postfix → spamc → LDA/LMTP).

What this script **can** realistically do:

- Re-run `spamc --check` on every message in the user's INBOX (`Maildir/cur` + `Maildir/new`)
- Calculate and log the current SpamAssassin score
- Optionally move messages above a chosen threshold to the Junk folder
- Optionally feed messages to Bayes training (`--spam` or `--ham`), but **only** when you explicitly allow it — mass-learning the entire INBOX usually destroys Bayes quality!

The script is deliberately **safe and conservative**:

- It only calculates and logs scores by default
- Moving messages is **opt-in** (`--move`) and should be tested with `--dry-run` first
- Bayes training is **opt-in** and rate-limited to high-scoring messages only

## Usage

```bash
chmod +x rescan-spam.sh

# Just scan & log scores (recommended first step)
./rescan-spam.sh -u user@example.com

# Scan + learn as spam messages with score ≥ 7.0
./rescan-spam.sh -u user@example.com --learn-spam-threshold=7.0

# Dry-run: simulate moving spam messages
./rescan-spam.sh -u user@example.com --move --dry-run

# Actually move messages with score ≥ 5.0 to Junk (use with care!)
./rescan-spam.sh -u user@example.com --move
```

How the script finds the mail storage path
The script uses `doveconf` to read the effective value of `mail_home` (preferred) or `mail_location` and derives the base path from it.
It strips everything after the first `%` variable placeholder, which works well for common patterns like:

 - `/var/vmail/%d/%n`
 - `/mnt/storage/vmail/%d/%u`
 - `/home/vmail/%u@%d`

If your setup uses very custom `mail_location` formats (e.g. `:LAYOUT=...` modifiers or non-standard variables), auto-detection may fail — in that case hard-code the `MAIL_BASE` variable inside the script.
### Recommendations

Always start with no flags or `--dry-run` to see what would happen.
Never run `--learn-ham` on a normal INBOX unless you are 100 % sure every message is ham.
Make a backup of the user's Maildir before using `--move`.
Check `/var/log/rescan-spam.log` (or change `LOGFILE` in the script) after each run.

Have fun — and stay careful with production mailboxes! :-)