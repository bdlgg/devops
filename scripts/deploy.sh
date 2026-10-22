#!/usr/bin/env bash

# Доставка статического сайта на devops-vm
# Использование: scripts/deploy.sh [--dry-run]

set -euo pipefail

REMOTE="devops"
REMOTE_DIR="/var/www/devops-site"
SITE_URL="https://devops.local/"
CA_CERT="${HOME}/devops.crt"

# Локальный порт для проверки HTTPS через SSH-туннель.
LOCAL_HTTPS_PORT=18443

die() {
    printf 'Ошибка: %s\n' "$*" >&2
    exit 1
}

# Разбор аргументов.
MODE="deploy"

if [[ $# -gt 1 ]]; then
    printf 'Использование: %s [--dry-run]\n' "$0" >&2
    exit 2
fi

if [[ $# -eq 1 ]]; then
    if [[ "$1" != "--dry-run" ]]; then
        printf 'Использование: %s [--dry-run]\n' "$0" >&2
        exit 2
    fi

    MODE="dry-run"
fi

# Определяем корень репозитория независимо от текущего каталога.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

REPO_ROOT="$(
    git -C "$SCRIPT_DIR/.." rev-parse --show-toplevel 2>/dev/null
)" || die "Не удалось определить корень Git-репозитория."

LOCAL_DIR="${REPO_ROOT}/site/"

# Проверяем необходимые программы.
for command_name in git rsync ssh curl; do
    command -v "$command_name" >/dev/null 2>&1 \
        || die "Не найдена команда: ${command_name}"
done

# Проверка главной страницы.
if [[ ! -f "${LOCAL_DIR}index.html" ]]; then
    die "Отсутствует файл ${LOCAL_DIR}index.html. Доставка отменена."
fi

# Проверка сертификата на Mac.
if [[ ! -f "$CA_CERT" ]]; then
    die "Не найден доверенный сертификат: ${CA_CERT}"
fi

# Не допускаем доставку незакоммиченных изменений.
if [[ -n "$(git -C "$REPO_ROOT" status --porcelain)" ]]; then
    printf 'В репозитории есть незакоммиченные изменения:\n' >&2
    git -C "$REPO_ROOT" status --short >&2
    die "Сначала зафиксируйте изменения в Git."
fi

# Короткий хеш коммита, который будет доставлен.
DEPLOY_COMMIT="$(
    git -C "$REPO_ROOT" rev-parse --short HEAD
)"

# Создаём временный каталог для сокета SSH.
TMP_DIR="$(mktemp -d /tmp/devops-deploy.XXXXXX)" \
    || die "Не удалось создать временный каталог."

SSH_SOCKET="${TMP_DIR}/control"

cleanup() {
    # Закрываем мастер-соединение через управляющий сокет.
    ssh -S "$SSH_SOCKET" -O exit "$REMOTE" \
        >/dev/null 2>&1 || true

    rm -rf "$TMP_DIR"
}

trap cleanup EXIT

# Открываем одно SSH-соединение с локальным HTTPS-туннелем.
# rsync будет повторно использовать это соединение.
if ! ssh -M -S "$SSH_SOCKET" -fNT \
    -o BatchMode=yes \
    -o ConnectTimeout=5 \
    -o ExitOnForwardFailure=yes \
    -L "127.0.0.1:${LOCAL_HTTPS_PORT}:127.0.0.1:443" \
    "$REMOTE"; then
    die "Не удалось подключиться к серверу. Проверьте SSH-ключ и ssh-add."
fi

# SSH для rsync использует уже открытое мастер-соединение.
RSYNC_RSH="ssh -S ${SSH_SOCKET} -o ControlMaster=no -o BatchMode=yes -o ConnectTimeout=5"

# Символьная запись --chmod совместима с более старыми версиями rsync.
# Каталоги: 755; файлы: 644.
RSYNC_ARGS=(
    -avz
    --delete
    --chmod=Du=rwx,Dgo=rx,Fu=rw,Fgo=r
)

# Пробный запуск: серверные файлы не изменяются.
if [[ "$MODE" == "dry-run" ]]; then
    rsync "${RSYNC_ARGS[@]}" \
        --dry-run \
        -e "$RSYNC_RSH" \
        "$LOCAL_DIR" \
        "${REMOTE}:${REMOTE_DIR}/"

    printf 'Пробный запуск завершён. Сервер не изменён.\n'
    exit 0
fi

# Выполняем доставку.
rsync "${RSYNC_ARGS[@]}" \
    -e "$RSYNC_RSH" \
    "$LOCAL_DIR" \
    "${REMOTE}:${REMOTE_DIR}/"

# Проверяем HTTPS без отключения проверки сертификата.
HTTP_STATUS="$(
    curl \
        --silent \
        --show-error \
        --output /dev/null \
        --write-out '%{http_code}' \
        --connect-timeout 5 \
        --max-time 15 \
        --cacert "$CA_CERT" \
        --connect-to \
            "devops.local:443:127.0.0.1:${LOCAL_HTTPS_PORT}" \
        "$SITE_URL"
)" || die "HTTPS-проверка завершилась ошибкой."

if [[ "$HTTP_STATUS" != "200" ]]; then
    die "Сайт вернул HTTP ${HTTP_STATUS} вместо 200."
fi

printf 'Деплой успешно завершён.\n'
printf 'Коммит: %s\n' "$DEPLOY_COMMIT"
printf 'HTTP: %s\n' "$HTTP_STATUS"
