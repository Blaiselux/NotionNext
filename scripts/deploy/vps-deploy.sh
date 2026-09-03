#!/usr/bin/env bash
set -Eeuo pipefail

readonly IMAGE_REPOSITORY='ghcr.io/blaiselux/notionnext'
readonly APP_ENV_FILE='/opt/notionnext/.env.local'
readonly STATE_DIR='/var/lib/notionnext-deploy'
readonly ACTIVE_SLOT_FILE="${STATE_DIR}/active-slot"
readonly NGINX_UPSTREAM_FILE='/etc/nginx/snippets/notionnext-upstream.conf'
readonly SITE_HOST='ashway.fun'

log() {
  printf '[notionnext-deploy] %s\n' "$*"
}

die() {
  log "ERROR: $*" >&2
  exit 1
}

healthcheck_port() {
  local port="$1"
  local attempt

  for attempt in $(seq 1 60); do
    if curl --fail --silent --show-error --max-time 8 \
      --header "Host: ${SITE_HOST}" \
      "http://127.0.0.1:${port}/" >/dev/null; then
      return 0
    fi
    sleep 2
  done

  return 1
}

write_nginx_upstream() {
  local port="$1"
  local temporary_file
  temporary_file=$(mktemp "${NGINX_UPSTREAM_FILE}.XXXXXX")
  printf 'proxy_pass http://127.0.0.1:%s;\n' "$port" >"$temporary_file"
  chmod 0644 "$temporary_file"
  mv "$temporary_file" "$NGINX_UPSTREAM_FILE"
}

rollback_switch() {
  local previous_port="$1"
  local candidate_container="$2"

  log "健康检查失败，恢复 Nginx 到端口 ${previous_port}"
  write_nginx_upstream "$previous_port"
  nginx -t
  systemctl reload nginx
  docker stop --time 10 "$candidate_container" >/dev/null 2>&1 || true
}

main() {
  local image_tag="${1:-}"
  local registry_user="${2:-}"
  [[ "$image_tag" =~ ^sha-[0-9a-f]{40}$ ]] || \
    die '镜像标签必须是 sha- 加 40 位小写 Git 提交哈希'
  [[ "$registry_user" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,38}$ ]] || \
    die '镜像仓库用户名格式无效'

  [[ -f "$APP_ENV_FILE" ]] || die "缺少运行配置 ${APP_ENV_FILE}"
  [[ -f "$ACTIVE_SLOT_FILE" ]] || die "缺少部署状态 ${ACTIVE_SLOT_FILE}"

  mkdir -p "$STATE_DIR"
  exec 9>"${STATE_DIR}/deploy.lock"
  flock -n 9 || die '已有另一个部署任务正在运行'

  local active_slot candidate_slot active_port candidate_port
  active_slot=$(<"$ACTIVE_SLOT_FILE")
  case "$active_slot" in
    blue)
      active_port=3000
      candidate_slot=green
      candidate_port=3001
      ;;
    green)
      active_port=3001
      candidate_slot=blue
      candidate_port=3000
      ;;
    *)
      die "未知的当前部署槽位：${active_slot}"
      ;;
  esac

  local active_container="notionnext-${active_slot}"
  local candidate_container="notionnext-${candidate_slot}"
  local image="${IMAGE_REPOSITORY}:${image_tag}"

  local registry_token docker_config
  IFS= read -r registry_token
  [[ -n "$registry_token" ]] || die '没有从标准输入收到临时 GHCR 令牌'
  docker_config=$(mktemp -d)
  chmod 0700 "$docker_config"
  trap 'rm -rf "$docker_config"' EXIT

  log "拉取候选镜像 ${image}"
  printf '%s' "$registry_token" | \
    DOCKER_CONFIG="$docker_config" docker login ghcr.io \
      --username "$registry_user" --password-stdin >/dev/null
  registry_token=''
  DOCKER_CONFIG="$docker_config" docker pull "$image"
  rm -rf "$docker_config"
  trap - EXIT

  if docker container inspect "$candidate_container" >/dev/null 2>&1; then
    docker rm --force "$candidate_container" >/dev/null
  fi

  log "在备用端口 ${candidate_port} 启动 ${candidate_container}"
  docker run --detach \
    --name "$candidate_container" \
    --restart unless-stopped \
    --env-file "$APP_ENV_FILE" \
    --label 'io.ashway.service=notionnext' \
    --label "io.ashway.git-sha=${image_tag#sha-}" \
    --publish "127.0.0.1:${candidate_port}:3000" \
    "$image" >/dev/null

  if ! healthcheck_port "$candidate_port"; then
    docker logs --tail 200 "$candidate_container" >&2 || true
    docker stop --time 10 "$candidate_container" >/dev/null 2>&1 || true
    die '候选容器未通过本地健康检查，线上容器未切换'
  fi

  log "候选容器通过检查，切换 Nginx 到端口 ${candidate_port}"
  write_nginx_upstream "$candidate_port"
  if ! nginx -t; then
    rollback_switch "$active_port" "$candidate_container"
    die 'Nginx 配置检查失败'
  fi
  systemctl reload nginx

  if ! curl --fail --silent --show-error --max-time 15 \
    --resolve "${SITE_HOST}:443:127.0.0.1" \
    "https://${SITE_HOST}/" >/dev/null; then
    rollback_switch "$active_port" "$candidate_container"
    die '切换后的 HTTPS 健康检查失败，已回滚'
  fi

  printf '%s\n' "$candidate_slot" >"${ACTIVE_SLOT_FILE}.tmp"
  mv "${ACTIVE_SLOT_FILE}.tmp" "$ACTIVE_SLOT_FILE"

  if docker container inspect "$active_container" >/dev/null 2>&1; then
    docker stop --time 30 "$active_container" >/dev/null || true
  fi

  log "部署成功：${image}，当前槽位 ${candidate_slot}"
}

main "$@"
