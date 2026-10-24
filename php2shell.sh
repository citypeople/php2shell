#!/usr/bin/env bash
# php2shell.sh — check and patch PHP against PHP2Shell (CVE-2026-109618, CVE-2026-109619)
# on Debian/Ubuntu with PHP from the Ondřej Surý repository (deb.sury.org / ppa:ondrej/php),
# including HestiaCP servers. Run it directly on the server as root.
#
#   ./php2shell.sh check          check only, changes nothing
#   ./php2shell.sh patch          update PHP, restart php-fpm, verify the result
#   ./php2shell.sh patch --yes    same, without the confirmation prompt (for automation)
#   ./php2shell.sh sites          only take a snapshot of site HTTP responses (HestiaCP)
#
# Exit codes: 0 — everything patched, 1 — vulnerable versions remain, 2 — error/aborted.
set -u
SCRIPT_VERSION="1.0 (2026-10-23)"
CVES="CVE-2026-109618|CVE-2026-109619"
MODE="${1:-check}"; YES="${2:-}"
LOGDIR=/var/log/php2shell; TS=$(date +%F_%H%M%S)
LOG="$LOGDIR/$MODE-$TS.log"
LOCK=/run/php2shell.lock

die()  { echo "ERROR: $*" >&2; exit 2; }
say()  { echo "$*"; }
hr()   { echo "------------------------------------------------------------"; }

case "$MODE" in check|patch|sites) ;; -h|--help|help) sed -n '2,13p' "$0"; exit 0 ;; *) die "unknown mode '$MODE' (check | patch | sites)";; esac
[ "$(id -u)" -eq 0 ] || die "root required (sudo $0 $MODE)"
command -v dpkg-query >/dev/null || die "only Debian/Ubuntu (dpkg/apt) are supported. This script does not work on RHEL/CentOS."

mkdir -p "$LOGDIR"; exec > >(tee -a "$LOG") 2>&1
exec 9>"$LOCK"; flock -n 9 || die "the script is already running (lock $LOCK)"

. /etc/os-release
say "php2shell.sh $SCRIPT_VERSION | $(hostname -f) | $PRETTY_NAME | $(dpkg --print-architecture) | mode: $MODE"
say "log: $LOG"; hr

php_versions() { ls -1 /etc/php 2>/dev/null | grep -E '^[0-9]+\.[0-9]+$' | sort -V; }

# --- check: the CVE fix is present in the changelog of the phpX.Y-common package
check() {
  local bad=0 v ver cl
  [ -z "$(php_versions)" ] && { say "no PHP found in /etc/php"; return 0; }
  for v in $(php_versions); do
    ver=$(dpkg-query -W -f='${Version}' "php$v-common" 2>/dev/null || echo "?")
    cl="/usr/share/doc/php$v-common/changelog.Debian.gz"
    if [ -f "$cl" ] && zgrep -qE "$CVES" "$cl"; then
      printf "  PHP %-4s %-44s OK\n" "$v" "$ver"
    else
      printf "  PHP %-4s %-44s VULNERABLE (fix not found)\n" "$v" "$ver"; bad=1
    fi
  done
  if dpkg -s hestia-php >/dev/null 2>&1; then
    printf "  hestia-php %-43s %s\n" "$(dpkg-query -W -f='${Version}' hestia-php)" \
      "$(/usr/local/hestia/php/bin/php -v 2>/dev/null | head -1 | cut -c1-40)"
  fi
  return $bad
}

# --- snapshot of HestiaCP site HTTP responses (requests to the local nginx on the IP from the domain config)
sites() {
  local f d ip
  for f in /home/*/conf/web/*/nginx.conf; do
    [ -f "$f" ] || continue
    d=$(basename "$(dirname "$f")"); ip=$(grep -m1 -oE 'listen +[0-9.]+' "$f" | awk '{print $2}')
    [ -z "$ip" ] && continue
    echo "$(curl -s -o /dev/null -w '%{http_code}' --resolve "$d:80:$ip" "http://$d/" -m 15) $d"
  done | sort -k2
}

if [ "$MODE" = sites ]; then sites | tee "$LOGDIR/sites-$TS.txt"; exit 0; fi
if [ "$MODE" = check ]; then check; rc=$?; hr; [ $rc -eq 0 ] && say "RESULT: everything is patched" || say "RESULT: vulnerable versions found"; exit $rc; fi

# ===================== patch =====================
check; [ $? -eq 0 ] && { hr; say "RESULT: everything is already patched, nothing to update"; exit 0; }
hr
free=$(df -Pm /var | awk 'NR==2{print $4}')
[ "$free" -lt 1024 ] && die "only ${free} MB free in /var, at least 1 GB is needed (apt-get clean frees the package cache)"

if [ "$YES" != "--yes" ]; then
  say "Installed php* packages will be updated and every phpX.Y-fpm restarted (1–2 s pause for sites)."
  read -r -p "Continue? [y/N] " a; [[ "$a" =~ ^[Yy]$ ]] || die "cancelled"
fi

HESTIA=no; [ -d /usr/local/hestia ] && HESTIA=yes
[ $HESTIA = yes ] && { say "taking a site snapshot before the patch..."; sites > "$LOGDIR/sites-before-$TS.txt"; say "  sites: $(wc -l < "$LOGDIR/sites-before-$TS.txt")"; }

say "apt-get update..."
# --allow-releaseinfo-change-label: the ondrej PPAs were renamed; without this flag apt silently stops refreshing their index
UPD=$(apt-get update -q --allow-releaseinfo-change-label 2>&1)
echo "$UPD" | grep -E '^(E|W|Err):' | sed 's/^/  /'
if echo "$UPD" | grep -E '^E:|^Err:|^W:.*(GPG|NO_PUBKEY)' | grep -qiE 'ondrej|sury'; then
  die "the PHP repository (ondrej/sury) failed to update — patch aborted, nothing was changed"
fi
grep -rqsE 'ondrej|sury' /etc/apt/sources.list /etc/apt/sources.list.d/ || say "  WARNING: no ondrej/sury repository in sources — PHP may come from another source"

PKGS=$(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 'php*' 2>/dev/null | awk '$1=="ii"{print $2}')
dpkg -s hestia-php >/dev/null 2>&1 && PKGS="$PKGS hestia-php"
say "updating packages: $(echo $PKGS | wc -w) (installed ones only, nothing new is added)"
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
apt-get install -y -q --only-upgrade -o Dpkg::Options::=--force-confold $PKGS > "$LOGDIR/apt-$TS.log" 2>&1 \
  || { tail -20 "$LOGDIR/apt-$TS.log"; die "apt-get failed, see: $LOGDIR/apt-$TS.log"; }
say "  done, apt log: $LOGDIR/apt-$TS.log"

say "restarting php-fpm:"
for v in $(php_versions); do
  systemctl list-unit-files "php$v-fpm.service" 2>/dev/null | grep -q "php$v-fpm" || continue
  if systemctl is-enabled -q "php$v-fpm" 2>/dev/null || systemctl is-active -q "php$v-fpm"; then
    systemctl restart "php$v-fpm"; printf "  php%s-fpm: %s\n" "$v" "$(systemctl is-active php$v-fpm)"
  fi
done
systemctl is-active -q apache2 && { apachectl -M 2>/dev/null | grep -q php && systemctl restart apache2 || systemctl reload apache2; say "  apache2: $(systemctl is-active apache2)"; }
[ $HESTIA = yes ] && systemctl is-active -q hestia && { systemctl restart hestia; say "  hestia: $(systemctl is-active hestia)"; }
hr

check; rc=$?
if [ $HESTIA = yes ]; then
  sites > "$LOGDIR/sites-after-$TS.txt"
  if diff -q "$LOGDIR/sites-before-$TS.txt" "$LOGDIR/sites-after-$TS.txt" >/dev/null; then
    say "sites: responses are the same as before the patch"
  else
    say "sites: CHANGES FOUND (before → after):"; diff "$LOGDIR/sites-before-$TS.txt" "$LOGDIR/sites-after-$TS.txt" | grep '^[<>]' | sed 's/^/  /'
  fi
fi
hr
if [ $rc -eq 0 ]; then say "RESULT: everything is patched"; else
  say "RESULT: vulnerable versions remain — the repository has no fixed build for this OS/architecture."
  say "        Options: move the sites to PHP 8.2+ and remove the old version, or build PHP with a backport."
fi
exit $rc
