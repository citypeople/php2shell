#!/usr/bin/env bash
# php2shell.sh — проверка и патч PHP от PHP2Shell (CVE-2026-109618, CVE-2026-109619)
# для Debian/Ubuntu с PHP из репозитория Ondřej Surý (deb.sury.org / ppa:ondrej/php),
# в том числе на серверах HestiaCP. Запускается прямо на сервере под root.
#
#   ./php2shell.sh check          проверка, ничего не меняет
#   ./php2shell.sh patch          обновить PHP, перезапустить php-fpm, проверить результат
#   ./php2shell.sh patch --yes    то же без вопроса-подтверждения (для автоматизации)
#   ./php2shell.sh sites          только снимок HTTP-ответов сайтов (HestiaCP)
#
# Коды выхода: 0 — всё пропатчено, 1 — есть уязвимые версии, 2 — ошибка/остановка.
set -u
SCRIPT_VERSION="1.0 (2026-10-23)"
CVES="CVE-2026-109618|CVE-2026-109619"
MODE="${1:-check}"; YES="${2:-}"
LOGDIR=/var/log/php2shell; TS=$(date +%F_%H%M%S)
LOG="$LOGDIR/$MODE-$TS.log"
LOCK=/run/php2shell.lock

die()  { echo "ОШИБКА: $*" >&2; exit 2; }
say()  { echo "$*"; }
hr()   { echo "------------------------------------------------------------"; }

case "$MODE" in check|patch|sites) ;; -h|--help|help) sed -n '2,13p' "$0"; exit 0 ;; *) die "неизвестный режим '$MODE' (check | patch | sites)";; esac
[ "$(id -u)" -eq 0 ] || die "нужен root (sudo $0 $MODE)"
command -v dpkg-query >/dev/null || die "поддерживаются только Debian/Ubuntu (dpkg/apt). Для RHEL/CentOS скрипт не подходит."

mkdir -p "$LOGDIR"; exec > >(tee -a "$LOG") 2>&1
exec 9>"$LOCK"; flock -n 9 || die "скрипт уже запущен (lock $LOCK)"

. /etc/os-release
say "php2shell.sh $SCRIPT_VERSION | $(hostname -f) | $PRETTY_NAME | $(dpkg --print-architecture) | режим: $MODE"
say "лог: $LOG"; hr

php_versions() { ls -1 /etc/php 2>/dev/null | grep -E '^[0-9]+\.[0-9]+$' | sort -V; }

# --- проверка: исправление CVE есть в changelog пакета phpX.Y-common
check() {
  local bad=0 v ver cl
  [ -z "$(php_versions)" ] && { say "PHP в /etc/php не найден"; return 0; }
  for v in $(php_versions); do
    ver=$(dpkg-query -W -f='${Version}' "php$v-common" 2>/dev/null || echo "?")
    cl="/usr/share/doc/php$v-common/changelog.Debian.gz"
    if [ -f "$cl" ] && zgrep -qE "$CVES" "$cl"; then
      printf "  PHP %-4s %-44s OK\n" "$v" "$ver"
    else
      printf "  PHP %-4s %-44s УЯЗВИМ (исправление не найдено)\n" "$v" "$ver"; bad=1
    fi
  done
  if dpkg -s hestia-php >/dev/null 2>&1; then
    printf "  hestia-php %-43s %s\n" "$(dpkg-query -W -f='${Version}' hestia-php)" \
      "$(/usr/local/hestia/php/bin/php -v 2>/dev/null | head -1 | cut -c1-40)"
  fi
  return $bad
}

# --- снимок HTTP-ответов сайтов HestiaCP (обращение к своему nginx по IP из конфига домена)
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
if [ "$MODE" = check ]; then check; rc=$?; hr; [ $rc -eq 0 ] && say "ИТОГ: всё пропатчено" || say "ИТОГ: есть уязвимые версии"; exit $rc; fi

# ===================== patch =====================
check; [ $? -eq 0 ] && { hr; say "ИТОГ: всё уже пропатчено, обновлять нечего"; exit 0; }
hr
free=$(df -Pm /var | awk 'NR==2{print $4}')
[ "$free" -lt 1024 ] && die "в /var свободно ${free} МБ, нужно хотя бы 1 ГБ (apt-get clean освободит кэш пакетов)"

if [ "$YES" != "--yes" ]; then
  say "Будут обновлены установленные пакеты php*, перезапущены все phpX.Y-fpm (пауза у сайтов 1–2 с)."
  read -r -p "Продолжить? [y/N] " a; [[ "$a" =~ ^[YyДд]$ ]] || die "отменено"
fi

HESTIA=no; [ -d /usr/local/hestia ] && HESTIA=yes
[ $HESTIA = yes ] && { say "снимок сайтов до патча..."; sites > "$LOGDIR/sites-before-$TS.txt"; say "  сайтов: $(wc -l < "$LOGDIR/sites-before-$TS.txt")"; }

say "apt-get update..."
# --allow-releaseinfo-change-label: PPA ondrej переименованы; без флага apt молча перестаёт обновлять их индекс
UPD=$(apt-get update -q --allow-releaseinfo-change-label 2>&1)
echo "$UPD" | grep -E '^(E|W|Err):' | sed 's/^/  /'
if echo "$UPD" | grep -E '^E:|^Err:|^W:.*(GPG|NO_PUBKEY)' | grep -qiE 'ondrej|sury'; then
  die "репозиторий PHP (ondrej/sury) не обновился — патч остановлен, ничего не изменено"
fi
grep -rqsE 'ondrej|sury' /etc/apt/sources.list /etc/apt/sources.list.d/ || say "  ВНИМАНИЕ: репозиторий ondrej/sury не найден в sources — PHP может быть из другого источника"

PKGS=$(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 'php*' 2>/dev/null | awk '$1=="ii"{print $2}')
dpkg -s hestia-php >/dev/null 2>&1 && PKGS="$PKGS hestia-php"
say "обновляю пакетов: $(echo $PKGS | wc -w) (только уже установленные, новые не ставятся)"
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
apt-get install -y -q --only-upgrade -o Dpkg::Options::=--force-confold $PKGS > "$LOGDIR/apt-$TS.log" 2>&1 \
  || { tail -20 "$LOGDIR/apt-$TS.log"; die "apt-get завершился с ошибкой, подробности: $LOGDIR/apt-$TS.log"; }
say "  готово, лог apt: $LOGDIR/apt-$TS.log"

say "перезапуск php-fpm:"
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
    say "сайты: ответы такие же, как до патча"
  else
    say "сайты: ЕСТЬ ИЗМЕНЕНИЯ (было → стало):"; diff "$LOGDIR/sites-before-$TS.txt" "$LOGDIR/sites-after-$TS.txt" | grep '^[<>]' | sed 's/^/  /'
  fi
fi
hr
if [ $rc -eq 0 ]; then say "ИТОГ: всё пропатчено"; else
  say "ИТОГ: есть уязвимые версии — для них в репозитории нет исправленной сборки под эту ОС/архитектуру."
  say "      Варианты: перевести сайты на PHP 8.2+ и удалить старую версию, либо собрать PHP с бэкпортом."
fi
exit $rc
