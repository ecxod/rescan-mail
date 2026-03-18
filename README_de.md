# rescan-mail

SpamAssassin kann existierende Mails nicht einfach nochmal komplett neu durchlaufen (mit allen Plugins, RBLs, etc.) und dabei die Header updaten oder Mails verschieben – das passiert nur bei der Delivery-Phase (Postfix → spamc → LDA/LMTP).  

Was wir aber realistisch machen können:
 - Alle Mails im INBOX (Maildir/cur + Maildir/new) mit spamc durchlaufen lassen → neuer X-Spam-Status-Header + Score berechnen
 - Optional: Mails mit Score ≥ 5.0 (oder deinem Threshold) in Junk verschieben
 - Optional: Bayes-Training (--spam oder --ham) – aber nicht für alle Mails automatisch, weil das den Bayes-Filter schnell kaputt macht!

Hier ist ein sicheres, vorsichtiges Skript, das:

 - Nur den Score neu berechnet und loggt
 - Nicht automatisch verschiebt (das kannst du später aktivieren)
 - Bayes-Training nur optional und kontrolliert macht

## Wie nutzen?
```sh
chmod +x rescan-spam.sh

# Nur anschauen / loggen
./rescan-spam.sh -u benutzer@domain.de

# Schauen + Bayes lernen ab Score 7.0
./rescan-spam.sh -u benutzer@domain.de --learn-spam-threshold=7.0

# Dry-Run mit Move-Simulation
./rescan-spam.sh -u benutzer@domain.de --move --dry-run

# Wirklich verschieben (VORSICHT!)
./rescan-spam.sh -u benutzer@domain.de --move
```

Das Skript nutzt doveconf, um den effektiven Wert von mail_home oder mail_location zu ermitteln und daraus den Basis-Pfad abzuleiten. Es entfernt alles ab dem ersten % → funktioniert gut bei typischen Mustern wie /var/vmail/%d/%n oder /mnt/eichert2/vmail/%d/%u. Wenn dein Setup sehr exotisch ist (z. B. mail_location = maildir:/path:LAYOUT=...), kann es scheitern → dann musst du den Pfad doch hartcodieren.

Teste zuerst ohne --move und mit --dry-run.  
Have Fun :-)