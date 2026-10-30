#!/usr/bin/env bash
set -uo pipefail
PASS=0; FAIL=0
check() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo " [OK] $desc"; ((PASS++)) || true
  else
    echo " [FAIL] $desc (ожидалось: '$expected', получено: '$actual')"
    ((FAIL++)) || true
  fi
}
echo "Аудит конфигурации: $(hostname -f), $(date '+%Y-%m-%d %H:%M')"
echo "[1] Служба SSH"
check "Вход от имени root запрещён" \
  "no" "$(sudo sshd -T | awk '/^permitrootlogin/{print $2; exit}')"
check "Парольная аутентификация отключена" \
  "no" "$(sudo sshd -T | awk '/^passwordauthentication/{print $2; exit}')"
# TODO 1: проверьте, что значение параметра port отлично от 22
ssh_port="$(sudo sshd -T | awk '/^port /{print $2; exit}')"
if [[ "$ssh_port" != "22" ]]; then
  check "Порт SSH отличен от 22" "yes" "yes"
else
  check "Порт SSH отличен от 22" "yes" "no"
fi
# TODO 2: проверьте, что значение параметра maxauthtries равно 3
check "MaxAuthTries равен 3" \
  "3" "$(sudo sshd -T | awk '/^maxauthtries/{print $2; exit}')"
echo "[2] Межсетевой экран"
check "Межсетевой экран активен" \
  "active" "$(sudo ufw status | awk '/^Status:/{print $2}')"
# TODO 3: проверьте, что политика по умолчанию для входящего трафика равна deny
#   источник данных: sudo ufw status verbose | grep Default
check "Политика incoming по умолчанию — deny" \
  "deny" "$(sudo ufw status verbose | awk '/^Default:/{print $2}')"
echo "[3] Учётные записи"
awk -F: '$3>=1000 && $3<65534 {printf "  %s (uid=%s)\n",$1,$3}' /etc/passwd
echo "[4] Веб-сервер"
check "служба nginx активна" \
  "active" "$(systemctl is-active nginx)"
nginx_t_rc=0
sudo nginx -t >/dev/null 2>&1 || nginx_t_rc=$?
check "конфигурация nginx синтаксически корректна" "0" "$nginx_t_rc"
CERT_MIN_SECONDS="${CERT_MIN_SECONDS:-2592000}"
cert_rc=0
sudo openssl x509 -in /etc/ssl/certs/devops.crt -checkend "$CERT_MIN_SECONDS" >/dev/null 2>&1 || cert_rc=$?
check "сертификат истекает не ранее чем через 30 дней" "0" "$cert_rc"
ww_count="$(find /var/www/devops-site -perm -o+w | wc -l | tr -d ' ')"
key_mode="$(sudo stat -c '%a' /etc/ssl/private/devops.key)"
if [[ "$ww_count" == "0" && "$key_mode" == "600" ]]; then
  check "нет world-writable файлов ресурса, ключ 600" "yes" "yes"
else
  check "нет world-writable файлов ресурса, ключ 600" "yes" "ww=${ww_count},key=${key_mode}"
fi
echo "Пройдено: $PASS, не пройдено: $FAIL"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
