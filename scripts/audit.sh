#!/usr/bin/env bash
set -uo pipefail

PASS=0
FAIL=0

check() {
    local desc="$1" expected="$2" actual="$3"

    if [[ "$actual" == "$expected" ]]; then
        echo " [OK]    $desc"
        ((PASS+=1))
    else
        echo " [FAIL] $desc (ожидалось: '$expected', получено: '$actual')"
        ((FAIL+=1))
    fi
}

echo "Аудит конфигурации: $(hostname -f), $(date '+%Y-%m-%d %H:%M')"

echo "[1] Служба SSH"
check "Вход от имени root запрещён" \
    "no" "$(sudo sshd -T | awk '/^permitrootlogin/{print $2}')"

check "Парольная аутентификация отключена" \
    "no" "$(sudo sshd -T | awk '/^passwordauthentication/{print $2}')"

check "SSH использует нестандартный порт" \
    "true" "$(sudo sshd -T | awk '/^port/{print ($2 != 22) ? "true" : "false"; exit}')"

check "Число попыток аутентификации равно 3" \
    "3" "$(sudo sshd -T | awk '/^maxauthtries/{print $2}')"

echo "[2] Межсетевой экран"
check "Межсетевой экран активен" \
    "active" "$(sudo ufw status | awk '/^Status:/{print $2}')"

UFW_DEFAULT=$(sudo ufw status verbose | awk -F': ' '/^Default:/{split($2,a,/[, ]+/); print a[1]}')
check "Входящая политика по умолчанию deny" "deny" "$UFW_DEFAULT"

echo "[3] Учётные записи"
awk -F: '$3>=1000 && $3<65534 {
    printf "              %s (uid=%s)\n", $1, $3
}' /etc/passwd

echo
echo "[4] Веб-сервер"

check "Служба Nginx активна" \
    "active" "$(systemctl is-active nginx 2>/dev/null || true)"

NGINX_CONFIG="invalid"
if sudo nginx -t >/dev/null 2>&1; then
    NGINX_CONFIG="valid"
fi
check "Конфигурация Nginx корректна" "valid" "$NGINX_CONFIG"

CERT_MIN_VALIDITY_DAYS="${CERT_MIN_VALIDITY_DAYS:-30}"
CERT_STATUS="invalid"

if openssl x509 \
    -in /etc/ssl/certs/devops.crt \
    -checkend "$((CERT_MIN_VALIDITY_DAYS * 86400))" \
    -noout >/dev/null 2>&1; then
    CERT_STATUS="valid"
fi

check "Сертификат действует ещё минимум ${CERT_MIN_VALIDITY_DAYS} дней" \
    "valid" "$CERT_STATUS"

WRITABLE_PATH=$(find /var/www/devops-site -perm -o+w -print -quit 2>/dev/null || true)
KEY_MODE=$(sudo stat -c '%a' /etc/ssl/private/devops.key 2>/dev/null || true)

SECURITY_STATUS="ok"
SECURITY_PROBLEMS=()

if [[ -n "$WRITABLE_PATH" ]]; then
    SECURITY_PROBLEMS+=("запись для всех: $WRITABLE_PATH")
fi

if [[ "$KEY_MODE" != "600" ]]; then
    SECURITY_PROBLEMS+=("права ключа: ${KEY_MODE:-не найден}")
fi

if ((${#SECURITY_PROBLEMS[@]} > 0)); then
    SECURITY_STATUS="${SECURITY_PROBLEMS[*]}"
fi

check "Нет объектов с записью для всех; ключ TLS имеет права 600" \
    "ok" "$SECURITY_STATUS"

echo
echo "Итог: PASS=$PASS FAIL=$FAIL"

if (( FAIL > 0 )); then
    exit 1
fi

exit 0
