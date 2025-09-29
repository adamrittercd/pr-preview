#!/usr/bin/env bash
set -euo pipefail

service="${SERVICE_NAME:?SERVICE_NAME env required}"
base_domain="${BASE_DOMAIN:?BASE_DOMAIN env required}"
workspace="${GITHUB_WORKSPACE:-$PWD}"

log() {
  echo "[pr-preview] $*" >&2
}

require_command() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    log "missing dependency: $cmd"
    exit 1
  fi
}

require_command docker
require_command sudo
require_command jq
require_command curl

github_api() {
  if [[ -z "${GITHUB_TOKEN:-}" ]]; then
    return 1
  fi
  local method="$1"
  local url="$2"
  shift 2

  local response
  response=$(curl -sS \
    -X "$method" \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    -H "User-Agent: pr-preview-action" \
    -w '\n%{http_code}' \
    "$url" "$@") || return 1

  local status
  status=${response##*$'\n'}
  GITHUB_API_LAST_STATUS="$status"

  local body
  body=${response%$'\n'$status}

  printf '%s' "$body"

  if [[ "$status" =~ ^[45] ]]; then
    return 1
  fi
}

get_pr_number() {
  if [[ -n "${PR_NUMBER:-}" ]]; then
    printf '%s' "$PR_NUMBER"
    return 0
  fi
  if [[ -n "${GITHUB_EVENT_PATH:-}" && -f "${GITHUB_EVENT_PATH}" ]]; then
    if command -v jq >/dev/null 2>&1; then
      local number
      number=$(jq -r '.pull_request.number // empty' "$GITHUB_EVENT_PATH")
      if [[ -n "$number" && "$number" != "null" ]]; then
        printf '%s' "$number"
        return 0
      fi
    else
      log "jq is required to parse pull request metadata"
      exit 1
    fi
  fi
  if [[ -n "${GITHUB_REF_NAME:-}" ]]; then
    if [[ ${GITHUB_REF_NAME} =~ ^pr/([0-9]+)$ ]]; then
      printf '%s' "${BASH_REMATCH[1]}"
      return 0
    fi
  fi
  return 1
}

start_container() {
  local container="$1"
  local image="$2"

  log "building image $image"
  docker build -t "$image" "$workspace" >&2

  if docker ps -a --format '{{.Names}}' | grep -Fqx "$container"; then
    log "removing existing container $container"
    docker rm -f "$container" >/dev/null
  fi

  log "starting container $container with dynamic port"
  docker run -d --name "$container" -p 0:80 "$image" >/dev/null

  local port=""
  for attempt in {1..10}; do
    port=$(docker inspect "$container" | jq -r '.[0].NetworkSettings.Ports["80/tcp"][0].HostPort // empty')
    if [[ -n "$port" ]]; then
      break
    fi
    sleep 1
  done

  if [[ -z "$port" ]]; then
    log "failed to discover host port for $container"
    exit 1
  fi

  echo "$port"
}

write_caddy() {
  local domain="$1"
  local port="$2"
  local config_dir="/etc/caddy/conf.d"
  local config_file="${config_dir}/${domain}.caddy"

  sudo mkdir -p "$config_dir"
  cat <<CADDY | sudo tee "$config_file" >/dev/null
${domain} {
  reverse_proxy 127.0.0.1:${port}
}
CADDY
  log "wrote caddy config for ${domain}"
  sudo systemctl reload caddy
}

remove_caddy() {
  local domain="$1"
  local config_dir="/etc/caddy/conf.d"
  local config_file="${config_dir}/${domain}.caddy"

  if sudo test -f "$config_file"; then
    sudo rm -f "$config_file"
    log "removed caddy config for ${domain}"
    sudo systemctl reload caddy
    return 0
  fi
  return 1
}

emit_outputs() {
  local container="$1"
  local domain="$2"
  local port="$3"
  local url="https://${domain}"

  printf 'container=%s\n' "$container"
  printf 'domain=%s\n' "$domain"
  printf 'port=%s\n' "$port"
  printf 'url=%s\n' "$url"

  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
      printf 'container=%s\n' "$container"
      printf 'domain=%s\n' "$domain"
      printf 'port=%s\n' "$port"
      printf 'url=%s\n' "$url"
    } >> "$GITHUB_OUTPUT"
  fi
}

update_preview_comment() {
  local pr_number="$1"
  local domain="$2"
  local port="$3"

  if [[ ${GITHUB_EVENT_NAME:-} != pull_request ]]; then
    return
  fi

  if [[ -z "${GITHUB_TOKEN:-}" || -z "${GITHUB_REPOSITORY:-}" ]]; then
    log "missing GITHUB_TOKEN or GITHUB_REPOSITORY; skipping PR comment"
    return
  fi

  local url="https://${domain}"
  local marker="<!-- pr-preview:${service} -->"
  local body
  body=$(printf '%s\nPreview URL: [%s](%s)\nHost port: %s\n' "$marker" "$url" "$url" "$port")

  local payload
  payload=$(jq -Rn --arg body "$body" '{body:$body}')

  local comments_endpoint="https://api.github.com/repos/${GITHUB_REPOSITORY}/issues/${pr_number}/comments"
  local comments_json
  if ! comments_json=$(github_api GET "${comments_endpoint}?per_page=100"); then
    if [[ "${GITHUB_API_LAST_STATUS:-}" == "403" ]]; then
      log "insufficient permission to read PR comments (need issues: write permission)"
    else
      log "failed to fetch existing comments"
    fi
    return
  fi

  local comment_id
  comment_id=$(echo "$comments_json" | jq -r --arg marker "$marker" 'map(select(.body | contains($marker))) | first?.id // empty')

  if [[ -n "$comment_id" ]]; then
    if ! github_api PATCH "https://api.github.com/repos/${GITHUB_REPOSITORY}/issues/comments/${comment_id}" -d "$payload" >/dev/null; then
      if [[ "${GITHUB_API_LAST_STATUS:-}" == "403" ]]; then
        log "insufficient permission to update preview comment"
      else
        log "failed to update preview comment"
      fi
    else
      log "updated preview comment for PR #${pr_number}"
    fi
  else
    if ! github_api POST "$comments_endpoint" -d "$payload" >/dev/null; then
      if [[ "${GITHUB_API_LAST_STATUS:-}" == "403" ]]; then
        log "insufficient permission to create preview comment"
      else
        log "failed to create preview comment"
      fi
    else
      log "posted preview comment for PR #${pr_number}"
    fi
  fi
}

delete_preview_comment() {
  local pr_number="$1"

  if [[ ${GITHUB_EVENT_NAME:-} != pull_request ]]; then
    return
  fi

  if [[ -z "${GITHUB_TOKEN:-}" || -z "${GITHUB_REPOSITORY:-}" ]]; then
    return
  fi

  local marker="<!-- pr-preview:${service} -->"
  local comments_endpoint="https://api.github.com/repos/${GITHUB_REPOSITORY}/issues/${pr_number}/comments"
  local comments_json
  if ! comments_json=$(github_api GET "${comments_endpoint}?per_page=100"); then
    return
  fi

  local comment_id
  comment_id=$(echo "$comments_json" | jq -r --arg marker "$marker" 'map(select(.body | contains($marker))) | first?.id // empty')

  if [[ -n "$comment_id" ]]; then
    if ! github_api DELETE "https://api.github.com/repos/${GITHUB_REPOSITORY}/issues/comments/${comment_id}" >/dev/null; then
      if [[ "${GITHUB_API_LAST_STATUS:-}" == "403" ]]; then
        log "insufficient permission to delete preview comment"
      else
        log "failed to delete preview comment"
      fi
    else
      log "deleted preview comment for PR #${pr_number}"
    fi
  fi
}

deploy_preview() {
  local pr_number="$1"
  local container="${service}-pr-${pr_number}"
  local image="${container}:latest"
  local domain="pr-${pr_number}.${service}.${base_domain}"

  local port
  port=$(start_container "$container" "$image")
  write_caddy "$domain" "$port"
  emit_outputs "$container" "$domain" "$port"
  update_preview_comment "$pr_number" "$domain" "$port"
}

remove_preview() {
  local pr_number="$1"
  local container="${service}-pr-${pr_number}"
  local domain="pr-${pr_number}.${service}.${base_domain}"

  if docker ps -a --format '{{.Names}}' | grep -Fqx "$container"; then
    log "removing container $container"
    docker rm -f "$container" >/dev/null
  else
    log "container $container not found"
  fi

  if ! remove_caddy "$domain"; then
    log "caddy config for ${domain} not found"
  fi

  delete_preview_comment "$pr_number"
}

deploy_main() {
  local container="${service}-main"
  local image="${container}:latest"
  local domain="${service}.${base_domain}"

  local port
  port=$(start_container "$container" "$image")
  write_caddy "$domain" "$port"
  emit_outputs "$container" "$domain" "$port"
}

handle_pull_request() {
  local action=""
  if [[ -n "${GITHUB_EVENT_PATH:-}" && -f "${GITHUB_EVENT_PATH}" ]]; then
    if command -v jq >/dev/null 2>&1; then
      action=$(jq -r '.action // ""' "$GITHUB_EVENT_PATH")
    else
      log "jq is required to parse pull request metadata"
      exit 1
    fi
  fi

  if ! pr_number=$(get_pr_number); then
    log "unable to determine pull request number"
    exit 1
  fi

  if [[ "$action" == "closed" ]]; then
    log "pull request #${pr_number} closed; tearing down preview"
    remove_preview "$pr_number"
  else
    log "deploying preview for pull request #${pr_number}"
    deploy_preview "$pr_number"
  fi
}

handle_push() {
  log "push detected; deploying main environment"
  deploy_main
}

case "${GITHUB_EVENT_NAME:-}" in
  pull_request)
    handle_pull_request
    ;;
  push)
    handle_push
    ;;
  *)
    log "event ${GITHUB_EVENT_NAME:-unknown} not supported; skipping"
    ;;
esac
