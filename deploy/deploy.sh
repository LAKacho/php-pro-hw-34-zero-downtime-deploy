#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="${APP_NAME:-pspa-target}"
APP_REPO="${APP_REPO:-https://github.com/example/pspa-target.git}"
GIT_REF="${GIT_REF:-main}"
DEPLOY_ROOT="${DEPLOY_ROOT:-/srv/${APP_NAME}}"
RELEASES_DIR="${RELEASES_DIR:-${DEPLOY_ROOT}/releases}"
SHARED_DIR="${SHARED_DIR:-${DEPLOY_ROOT}/shared}"
CURRENT_LINK="${CURRENT_LINK:-${DEPLOY_ROOT}/current}"
CONFIG_FILE="${CONFIG_FILE:-${DEPLOY_ROOT}/config/.env.production}"
APP_PORT="${APP_PORT:-8000}"
PHP_BIN="${PHP_BIN:-php}"
COMPOSER_BIN="${COMPOSER_BIN:-composer}"

log() {
  echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $*"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    log "Ошибка: команда '$1' не найдена."
    exit 1
  }
}

require_file() {
  if [[ ! -f "$1" ]]; then
    log "Ошибка: не найден файл конфигурации '$1'."
    exit 1
  fi
}

wait_for_health() {
  local tries="${1:-20}"
  local delay="${2:-3}"

  for i in $(seq 1 "$tries"); do
    if curl -fsS "http://127.0.0.1:${APP_PORT}/api/doc" >/dev/null 2>&1; then
      return 0
    fi
    sleep "$delay"
  done

  log "HTTP healthcheck не прошёл за ${tries} попыток."
  return 1
}

require_cmd git
require_cmd rsync
require_cmd curl
require_cmd composer
require_file "$CONFIG_FILE"

set -a
source "$CONFIG_FILE"
set +a

mkdir -p "$RELEASES_DIR" "$SHARED_DIR" "$DEPLOY_ROOT/config"
mkdir -p "$SHARED_DIR/var/cache" "$SHARED_DIR/var/log" "$SHARED_DIR/public/uploads"

if [[ ! -d "$DEPLOY_ROOT/repo" ]]; then
  log "Клонируем репозиторий ${APP_REPO}"
  git clone --branch "$GIT_REF" "$APP_REPO" "$DEPLOY_ROOT/repo"
else
  log "Обновляем код из git"
  git -C "$DEPLOY_ROOT/repo" fetch --all --prune
  git -C "$DEPLOY_ROOT/repo" checkout "$GIT_REF"
  git -C "$DEPLOY_ROOT/repo" pull --ff-only origin "$GIT_REF"
fi

RELEASE_PATH="${RELEASES_DIR}/$(date +%Y%m%d%H%M%S)"
mkdir -p "$RELEASE_PATH"

log "Копируем релиз в ${RELEASE_PATH}"
rsync -a --delete \
  --exclude='.git' \
  --exclude='.github' \
  --exclude='deploy' \
  --exclude='var' \
  --exclude='vendor' \
  --exclude='.env' \
  --exclude='.env.*' \
  "$DEPLOY_ROOT/repo/" "$RELEASE_PATH/"

log "Создаём ссылки на общие директории"
ln -sfn "$SHARED_DIR/var" "$RELEASE_PATH/var"
ln -sfn "$SHARED_DIR/public/uploads" "$RELEASE_PATH/public/uploads"
cp "$CONFIG_FILE" "$RELEASE_PATH/.env.local"
chmod 600 "$RELEASE_PATH/.env.local"

log "Устанавливаем зависимости приложения"
cd "$RELEASE_PATH"
composer install --no-interaction --prefer-dist --no-progress --no-dev --optimize-autoloader

log "Готовим Symfony к продакшену"
"$PHP_BIN" bin/console cache:clear --env=prod
"$PHP_BIN" bin/console doctrine:migrations:migrate --no-interaction --allow-no-migration
"$PHP_BIN" bin/console asset:install --env=prod --symlink public

PREVIOUS_RELEASE=""
if [[ -L "$CURRENT_LINK" ]]; then
  PREVIOUS_RELEASE="$(readlink "$CURRENT_LINK")"
fi

log "Переключаем active release"
if [[ -L "$CURRENT_LINK" ]]; then
  CURRENT_TARGET="$(readlink "$CURRENT_LINK")"
  if [[ -n "$CURRENT_TARGET" && "$CURRENT_TARGET" != "$RELEASE_PATH" ]]; then
    ln -sfn "$RELEASE_PATH" "$CURRENT_LINK.new"
    mv -T "$CURRENT_LINK.new" "$CURRENT_LINK"
  else
    ln -sfn "$RELEASE_PATH" "$CURRENT_LINK"
  fi
else
  ln -sfn "$RELEASE_PATH" "$CURRENT_LINK"
fi

log "Проверяем, что новый релиз доступен"
if ! wait_for_health 20 3; then
  log "Сбой healthcheck: откатываемся к предыдущему релизу"
  if [[ -n "$PREVIOUS_RELEASE" ]]; then
    ln -sfn "$PREVIOUS_RELEASE" "$CURRENT_LINK.new"
    mv -T "$CURRENT_LINK.new" "$CURRENT_LINK"
    log "Возвращён релиз ${PREVIOUS_RELEASE}"
  fi
  exit 1
fi

log "Деплой завершён: ${RELEASE_PATH}"
