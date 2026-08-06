#!/usr/bin/env bash
# run.sh — two modes:
#
# 1) LOCAL DEV (source it, no args): brings up the `infra` profile and exports
#    the BlocksSecret__* connection strings composed from .env so `dotnet run`
#    on the host picks up MongoDB / Redis / RabbitMQ.
#
#       source run.sh            # infra up + connection strings exported
#       dotnet run               # picks up the exported settings
#       bash run.sh dotnet run   # or run a command with the env in place
#
# 2) DEPLOYMENT (run it with a deploy verb/flag): interactive or flag-driven
#    "1-shot" deploy of the Blocks stack via Docker Compose profiles.
#
#       bash run.sh deploy       # interactive — asks domain, infra, edge, services
#       bash run.sh -all         # infra + edge (nginx/TLS) + every service
#       bash run.sh -infra       # mongo + redis + rabbitmq only
#       bash run.sh -nginx       # nginx-proxy + acme-companion (TLS) only
#       bash run.sh -os          # os-api + os-worker only
#       bash run.sh -iam         # iam-api + iam-worker only
#
# .env is the single source of truth — change MONGO_USER/MONGO_PASS/ports/DOMAIN
# there and both Docker Compose and every derived connection string follow.

# Services available to deploy. Each maps to a Compose profile that brings up the
# matching <svc>-api + <svc>-worker pair. Append new service names here as the
# platform grows; `-all` and the interactive "all" answer expand to this list.
AVAILABLE_SERVICES=(os iam logic localization monitor utilities release data)

# ---------------------------------------------------------------------------
# Resolve this script's directory (works whether sourced or executed).
# ---------------------------------------------------------------------------
if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
  _src="${BASH_SOURCE[0]}"
else
  _src="$0"
fi
_script_dir="$(cd -- "$(dirname -- "$_src")" && pwd)"

# Was this script sourced (`source run.sh`) or executed (`bash run.sh`)?
# Sourced + no args = local-dev shim; executed + no args = interactive deploy.
_sourced=0
[[ -n "${BASH_SOURCE[0]:-}" && "${BASH_SOURCE[0]}" != "$0" ]] && _sourced=1

# .env: prefer the one in the current directory, else the one beside this script.
if [[ -f ".env" ]]; then
  _env_file="$(pwd)/.env"
else
  _env_file="$_script_dir/.env"
fi

if [[ ! -f "$_env_file" ]]; then
  echo "run.sh: no .env in CWD or at $_script_dir/.env" >&2
  return 1 2>/dev/null || exit 1
fi

# ---------------------------------------------------------------------------
# Helpers (defined before mode dispatch so both modes can use them).
# ---------------------------------------------------------------------------

# _load_env — source .env, exporting every variable for Compose interpolation.
_load_env() {
  set -a
  # shellcheck disable=SC1090
  source "$_env_file"
  set +a
}

# _set_env_var KEY VALUE — upsert KEY=VALUE in .env (in place), keeping it as the
# single source of truth so a re-run remembers the answer.
_set_env_var() {
  local key="$1" value="$2"
  if grep -qE "^${key}=" "$_env_file"; then
    local tmp
    tmp="$(mktemp)"
    awk -v k="$key" -v v="$value" \
      'BEGIN{FS=OFS="="} $1==k{print k"="v; next} {print}' \
      "$_env_file" >"$tmp" && mv "$tmp" "$_env_file"
  else
    printf '%s=%s\n' "$key" "$value" >>"$_env_file"
  fi
}

# _compose CMD... — run docker compose against this stack's file + env.
_compose() {
  docker compose -f "$_script_dir/docker-compose.yml" --env-file "$_env_file" "$@"
}

# _public_ip — this host's public IPv4, via whichever resolver is available.
_public_ip() {
  local ip=""
  if command -v curl >/dev/null 2>&1; then
    ip="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null)" \
      || ip="$(curl -fsS --max-time 5 https://ifconfig.me 2>/dev/null)"
  fi
  [[ -z "$ip" ]] && command -v dig >/dev/null 2>&1 && \
    ip="$(dig -4 +short myip.opendns.com @resolver1.opendns.com 2>/dev/null)"
  echo "$ip"
}

# _resolve HOST — first A record for HOST, via dig/host/getent (whichever exists).
_resolve() {
  local host="$1" out=""
  if command -v dig >/dev/null 2>&1; then
    out="$(dig +short A "$host" 2>/dev/null | grep -Em1 '^[0-9.]+$')"
  elif command -v host >/dev/null 2>&1; then
    out="$(host -t A "$host" 2>/dev/null | awk '/has address/{print $NF; exit}')"
  elif command -v getent >/dev/null 2>&1; then
    out="$(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1; exit}')"
  fi
  echo "$out"
}

# _check_dns SERVICE... — verify each <svc>.${DOMAIN} resolves to this host's
# public IP before Let's Encrypt is asked to issue a cert. Warns (does not hard
# fail) since DNS can be slow to propagate; returns 1 if any record is wrong.
_check_dns() {
  local ip host got bad=0
  ip="$(_public_ip)"
  echo "Pre-flight DNS check (this host public IP: ${ip:-unknown})"
  if ! command -v dig >/dev/null 2>&1 && ! command -v host >/dev/null 2>&1 \
     && ! command -v getent >/dev/null 2>&1; then
    echo "  ! no DNS lookup tool (dig/host/getent) found — skipping check"
    return 0
  fi
  for svc in "$@"; do
    host="${svc}.${DOMAIN}"
    got="$(_resolve "$host")"
    if [[ -z "$got" ]]; then
      echo "  ✗ $host does not resolve (no A record)"
      bad=1
    elif [[ -n "$ip" && "$got" != "$ip" ]]; then
      echo "  ✗ $host -> $got (expected this host $ip)"
      bad=1
    else
      echo "  ✓ $host -> $got"
    fi
  done
  return $bad
}

# Images live at blocksos/blocks-<svc>-<api|worker>:<tag> in public Docker Hub.
# There is no `latest` tag upstream — tags are commit SHAs and the -api/-worker
# of a service share one tag — so "deploy the newest build" means resolving the
# most recently pushed tag. The <SVC>_TAG variable (e.g. OS_TAG) drives the
# image refs in docker-compose.yml.

# _latest_tag REPO — most recently pushed tag name for a public Hub repo, or
# empty if it can't be determined (network down, repo missing, etc.).
_latest_tag() {
  local repo="$1" url
  command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || return 0
  url="https://hub.docker.com/v2/repositories/${repo}/tags?page_size=1&ordering=last_updated"
  curl -fsS "$url" 2>/dev/null | jq -r '.results[0].name // empty'
}

# _resolve_tags SERVICE... — set & export <SVC>_TAG for each service.
#   * A real value in <SVC>_TAG (a SHA you typed) is an explicit PIN — kept as-is.
#   * Blank, or the literals latest/newest/auto, means "always pull the newest
#     pushed tag": it is re-resolved from Docker Hub on EVERY run and only
#     exported for this run — never written back as <SVC>_TAG, so it can't pin
#     itself. The resolved value is recorded in <SVC>_TAG_LAST (informational).
# Never fatal — if resolution fails the compose `:-latest` default applies.
_resolve_tags() {
  local svc var cur tag
  for svc in "$@"; do
    var="${svc^^}_TAG"; var="${var//-/_}"
    cur="${!var:-}"
    case "$cur" in
      ""|latest|newest|auto)
        tag="$(_latest_tag "blocksos/blocks-${svc}-api")"
        if [[ -n "$tag" ]]; then
          printf -v "$var" '%s' "$tag"
          export "$var"
          _set_env_var "${var}_LAST" "$tag"   # record only; not read back as a pin
          echo "  ${svc}: newest -> $tag"
        else
          echo "  ${svc}: could not resolve a tag (offline or repo missing?) — using compose default"
        fi
        ;;
      *)
        export "$var"
        echo "  ${svc}: pinned ${var}=${cur}"
        ;;
    esac
  done
}

# _svc_tag SVC — current effective tag for a service (for display), or "latest".
_svc_tag() {
  local var="${1^^}_TAG"; var="${var//-/_}"
  echo "${!var:-latest}"
}

# _gen_guid — a random lowercase UUID via whatever tool is available.
_gen_guid() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr 'A-Z' 'a-z'
  elif [[ -r /proc/sys/kernel/random/uuid ]]; then
    cat /proc/sys/kernel/random/uuid
  else
    python3 -c 'import uuid; print(uuid.uuid4())'
  fi
}

# _gen_secret — 32 random hex chars.
_gen_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 16
  else
    head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n'
  fi
}

# _ensure_url SVC — set & persist <SVC>_URL=https://<svc>.<DOMAIN> in .env.
# Always refreshed to the current DOMAIN.
_ensure_url() {
  local svc="$1" var="${1^^}_URL"; var="${var//-/_}"
  printf -v "$var" 'https://%s.%s' "$svc" "$DOMAIN"
  export "$var"
  _set_env_var "$var" "${!var}"
  echo "  ${svc}: ${var}=${!var}"
}

# _ensure_creds SVC — generate-once OIDC client id + secret for a service and
# persist to .env (blk- prefix). Stable across runs: only generated when blank,
# so OS and IAM keep distinct, unchanging credentials.
_ensure_creds() {
  local svc="$1" up id_var sec_var
  up="${1^^}"; up="${up//-/_}"
  id_var="${up}_CLIENT_ID"; sec_var="${up}_CLIENT_SECRET"
  if [[ -z "${!id_var:-}" ]]; then
    printf -v "$id_var" 'blk-%s' "$(_gen_guid)"
    _set_env_var "$id_var" "${!id_var}"
  fi
  export "$id_var"
  if [[ -z "${!sec_var:-}" ]]; then
    printf -v "$sec_var" '%s' "$(_gen_secret)"
    _set_env_var "$sec_var" "${!sec_var}"
  fi
  export "$sec_var"
  echo "  ${svc}: ${id_var}=${!id_var}"
  echo "  ${svc}: ${sec_var}=${!sec_var}"
}

# _host_ip — this machine's primary LAN/private IPv4 (the one other hosts and
# containers reach it on). Stable across container restarts (unlike a container
# IP), so it is safe to persist into connection strings stored in the database.
_host_ip() {
  local ip
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null \
        | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
  [[ -z "$ip" ]] && ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  echo "$ip"
}

# _ensure_connections — build the infra connection strings the app containers use
# (and persist into the DB) from the host IP + published ports, and write them to
# .env as APP_*. Using the host IP (not the docker service name `mongodb`) means
# the connection string stays reachable when other apps / machines read it from
# the database. HOST_IP can be pinned in .env to override auto-detection.
# Refreshed every run so the IP stays current.
_ensure_connections() {
  local host="${HOST_IP:-$(_host_ip)}"
  if [[ -z "$host" ]]; then
    echo "  ! could not detect host IP — set HOST_IP=<ip> in .env" >&2
    return 0
  fi
  HOST_IP="$host"; export HOST_IP; _set_env_var HOST_IP "$host"

  APP_DB_CONNECTION="mongodb://${MONGO_USER}:${MONGO_PASS}@${host}:${MONGO_HOST_PORT}/?authSource=admin"
  APP_CACHE_CONNECTION="${host}:${REDIS_HOST_PORT},abortConnect=false"
  APP_MESSAGE_CONNECTION="amqp://${RABBITMQ_USER}:${RABBITMQ_PASS}@${host}:${RABBITMQ_HOST_PORT}"
  APP_LMT_CONNECTION="amqp://<username>:<password>@${host}:${RABBITMQ_HOST_PORT}/"
  # Tenant DB connection string is persisted into the DB and read everywhere by
  # other apps — same host-IP value as APP_DB_CONNECTION.
  TENANT_DB_CONNECTION_STRING="$APP_DB_CONNECTION"
  export APP_DB_CONNECTION APP_CACHE_CONNECTION APP_MESSAGE_CONNECTION APP_LMT_CONNECTION TENANT_DB_CONNECTION_STRING
  _set_env_var APP_DB_CONNECTION          "$APP_DB_CONNECTION"
  _set_env_var APP_CACHE_CONNECTION       "$APP_CACHE_CONNECTION"
  _set_env_var APP_MESSAGE_CONNECTION     "$APP_MESSAGE_CONNECTION"
  _set_env_var APP_LMT_CONNECTION         "$APP_LMT_CONNECTION"
  _set_env_var TENANT_DB_CONNECTION_STRING "$TENANT_DB_CONNECTION_STRING"

  echo "  host IP   : ${host}"
  echo "  mongo     : ${host}:${MONGO_HOST_PORT}"
  echo "  redis     : ${host}:${REDIS_HOST_PORT}"
  echo "  rabbitmq  : ${host}:${RABBITMQ_HOST_PORT}"
  echo "  tenant DB : ${TENANT_DB_CONNECTION_STRING}"
}

# ===========================================================================
# DEPLOYMENT MODE
# ===========================================================================
_run_deploy() {
  local interactive=0 dry_run=0
  local want_infra=0 want_edge=0
  local -a want_services=()
  local known svc ok arg matched

  # ---- pull dry-run markers out of the args (may appear anywhere) ----
  local -a rest=()
  for arg in "$@"; do
    case "$arg" in
      plan|--plan|--dry-run|-n) dry_run=1 ;;
      *) rest+=("$arg") ;;
    esac
  done
  set -- "${rest[@]}"

  # ---- parse flags ----
  case "${1:-}" in
    deploy|"") interactive=1 ;;
    -all|--all)
      want_infra=1; want_edge=1; want_services=("${AVAILABLE_SERVICES[@]}") ;;
    -infra|--infra) want_infra=1 ;;
    -nginx|--nginx|-edge|--edge) want_edge=1 ;;
    *)
      # One or more service flags, e.g. -os -iam
      for arg in "$@"; do
        svc="${arg#-}"; svc="${svc#-}"   # strip leading - / --
        matched=0
        for known in "${AVAILABLE_SERVICES[@]}"; do
          [[ "$svc" == "$known" ]] && { want_services+=("$svc"); matched=1; break; }
        done
        if [[ $matched -eq 0 ]]; then
          echo "run.sh: unknown deploy target '$arg'" >&2
          echo "  valid: deploy, -all, -infra, -nginx, $(printf -- '-%s ' "${AVAILABLE_SERVICES[@]}")" >&2
          exit 1
        fi
      done
      ;;
  esac

  _load_env

  # ---- interactive questionnaire ----
  if [[ $interactive -eq 1 ]]; then
    echo "=== Blocks 1-shot deployment ==="
    echo

    # 1. Domain
    read -r -p "What is your domain? [${DOMAIN}] " _ans
    if [[ -n "$_ans" ]]; then
      DOMAIN="$_ans"
      _set_env_var DOMAIN "$DOMAIN"
    fi

    # 2. Confirm env
    echo
    echo "Current environment (.env):"
    echo "  DOMAIN             = $DOMAIN"
    echo "  LETSENCRYPT_EMAIL  = $LETSENCRYPT_EMAIL"
    echo "  BLOCKS_VERSION     = $BLOCKS_VERSION"
    echo "  MONGO_USER/PASS    = $MONGO_USER / $MONGO_PASS"
    echo "  RABBITMQ_USER/PASS = $RABBITMQ_USER / $RABBITMQ_PASS"
    echo
    read -r -p "Is your env information right? [y/N] " _ans
    if [[ ! "$_ans" =~ ^[Yy] ]]; then
      echo "Edit $_env_file and re-run. Aborting."
      exit 1
    fi

    # 3. Infra in Docker?
    read -r -p "Do you need mongo, redis, rabbitmq in Docker? [Y/n] " _ans
    [[ ! "$_ans" =~ ^[Nn] ]] && want_infra=1

    # 4. Edge (nginx + Let's Encrypt)?
    read -r -p "Do you want the nginx reverse proxy + TLS certs? [Y/n] " _ans
    if [[ ! "$_ans" =~ ^[Nn] ]]; then
      want_edge=1
      read -r -p "  Let's Encrypt contact email? [${LETSENCRYPT_EMAIL}] " _email
      if [[ -n "$_email" ]]; then
        LETSENCRYPT_EMAIL="$_email"
        _set_env_var LETSENCRYPT_EMAIL "$LETSENCRYPT_EMAIL"
      fi
    fi

    # 5. Which services?
    read -r -p "Do you want to start ALL services (${AVAILABLE_SERVICES[*]})? [Y/n] " _ans
    if [[ ! "$_ans" =~ ^[Nn] ]]; then
      want_services=("${AVAILABLE_SERVICES[@]}")
    else
      read -r -p "  Which services? (space-separated from: ${AVAILABLE_SERVICES[*]}) " -a _picked
      for svc in "${_picked[@]}"; do
        ok=0
        for known in "${AVAILABLE_SERVICES[@]}"; do
          [[ "$svc" == "$known" ]] && { want_services+=("$svc"); ok=1; break; }
        done
        [[ $ok -eq 0 ]] && echo "  (ignoring unknown service '$svc')"
      done
    fi

    # 6. Action — dry run (plan) or deploy. Skip if a flag already forced plan.
    if [[ $dry_run -eq 0 ]]; then
      echo
      echo "Action:"
      echo "  1) Dry run  — show what would be deployed, change nothing (like 'terraform plan')"
      echo "  2) Deploy   — actually bring the stack up"
      read -r -p "Choose [1/2]: " _ans
      [[ "$_ans" != "2" ]] && dry_run=1
    fi
    echo
  fi

  # ---- infra connection strings (host-IP based, written to .env) ----
  if [[ ${#want_services[@]} -gt 0 ]]; then
    echo "Infra connection strings (host IP — reachable by other apps/containers):"
    _ensure_connections
    echo
  fi

  # ---- per-service public URLs + OIDC client credentials (written to .env) ----
  if [[ ${#want_services[@]} -gt 0 ]]; then
    echo "Service URLs (https://<svc>.${DOMAIN}):"
    for svc in "${want_services[@]}"; do _ensure_url "$svc"; done
    echo "OIDC client credentials (generated once, kept stable in .env):"
    for svc in "${want_services[@]}"; do _ensure_creds "$svc"; done
    echo
  fi

  # ---- build the profile list ----
  # App services depend on the infra services (mongodb/seed), so the infra
  # profile must be in scope whenever any service is selected — otherwise
  # compose rejects the project ("depends on undefined service mongodb").
  [[ ${#want_services[@]} -gt 0 ]] && want_infra=1
  local -a profiles=()
  [[ $want_infra -eq 1 ]] && profiles+=(--profile infra)
  [[ $want_edge -eq 1 ]]  && profiles+=(--profile edge)
  for svc in "${want_services[@]}"; do
    profiles+=(--profile "$svc")
  done

  if [[ ${#profiles[@]} -eq 0 ]]; then
    echo "run.sh: nothing selected to deploy." >&2
    exit 1
  fi

  if [[ $dry_run -eq 1 ]]; then
    echo "Mode: DRY RUN (plan only — nothing will be created)"
  else
    echo "Mode: DEPLOY"
  fi
  echo "Profiles:${profiles[*]//--profile/}"
  echo

  # ---- resolve the image tag for each selected service ----
  # (newest pushed tag from Docker Hub unless pinned in .env). Done for both plan
  # and deploy so the plan shows the exact tags that would be pulled.
  if [[ ${#want_services[@]} -gt 0 ]]; then
    echo "Resolving image tags (blocksos/blocks-<svc>-<api|worker>):"
    _resolve_tags "${want_services[@]}"
    echo
  fi

  # ---- pre-flight DNS check before Let's Encrypt issues certs ----
  if [[ $want_edge -eq 1 && ${#want_services[@]} -gt 0 ]]; then
    if ! _check_dns "${want_services[@]}"; then
      echo
      echo "Some subdomains are not pointing at this host. Let's Encrypt will fail"
      echo "for those until DNS propagates (subdomain records: {service}.${DOMAIN})."
      if [[ $dry_run -eq 1 ]]; then
        echo "(dry run — reporting only)"
      elif [[ -t 0 ]]; then
        read -r -p "Continue anyway? [y/N] " _ans
        if [[ ! "$_ans" =~ ^[Yy] ]]; then
          echo "Aborting. Fix the DNS A records and re-run."
          exit 1
        fi
      else
        echo "(no TTY — continuing; certs will retry as DNS propagates)"
      fi
    fi
    echo
  fi

  # ---- DRY RUN: print the plan and stop ----
  if [[ $dry_run -eq 1 ]]; then
    echo "Execution plan — the following containers would be created:"
    echo
    if [[ $want_infra -eq 1 ]]; then
      echo "  Infra:"
      echo "    + mongodb       mongo:8                 host :${MONGO_HOST_PORT} -> 27017"
      echo "    + mongodb-seed  mongo:8                 one-shot DB restore, then exits"
      echo "    + redis         redis:8-alpine          host :${REDIS_HOST_PORT} -> 6379"
      echo "    + rabbitmq      rabbitmq:3-management   host :${RABBITMQ_HOST_PORT} -> 5672, :${RABBITMQ_MGMT_PORT} -> 15672"
    fi
    if [[ $want_edge -eq 1 ]]; then
      echo "  Edge:"
      echo "    + nginx-proxy     nginxproxy/nginx-proxy:latest      host :80, :443"
      echo "    + acme-companion  nginxproxy/acme-companion:latest   Let's Encrypt (${LETSENCRYPT_EMAIL})"
    fi
    if [[ ${#want_services[@]} -gt 0 ]]; then
      echo "  Apps:"
      for svc in "${want_services[@]}"; do
        _tag="$(_svc_tag "$svc")"
        echo "    + ${svc}-api     blocksos/blocks-${svc}-api:${_tag}"
        if [[ $want_edge -eq 1 ]]; then
          echo "        URL: https://${svc}.${DOMAIN}"
        else
          echo "        (no edge — reachable only inside the Compose network)"
        fi
        echo "    + ${svc}-worker  blocksos/blocks-${svc}-worker:${_tag}  (consumes RabbitMQ, not exposed)"
      done
    fi
    echo
    echo "Commands that would run:"
    [[ ${#want_services[@]} -gt 0 ]] && echo "  docker compose ${profiles[*]} pull"
    echo "  docker compose ${profiles[*]} up -d"
    echo
    echo "Plan only — no changes made. Re-run and choose Deploy (or pass no plan/--dry-run flag) to apply."
    return 0
  fi

  # ---- generate configure.js from .env before bringing up infra ----
  if [[ $want_infra -eq 1 ]]; then
    echo "Generating configure.js from .env..."
    bash "$_script_dir/configure.sh" --env "$_env_file"
    echo
  fi

  # ---- pull app images first (infra/edge images pull on up) ----
  if [[ ${#want_services[@]} -gt 0 ]]; then
    _compose "${profiles[@]}" pull
  fi

  # ---- bring everything up ----
  _compose "${profiles[@]}" up -d

  # ---- summary ----
  echo
  echo "=== Deployment complete ==="
  [[ $want_infra -eq 1 ]] && echo "Infra:  mongodb:${MONGO_HOST_PORT}  redis:${REDIS_HOST_PORT}  rabbitmq:${RABBITMQ_HOST_PORT} (mgmt :${RABBITMQ_MGMT_PORT})"
  for svc in "${want_services[@]}"; do
    if [[ $want_edge -eq 1 ]]; then
      echo "App:    https://${svc}.${DOMAIN}   (+ ${svc}-worker)"
    else
      echo "App:    ${svc}-api + ${svc}-worker (no edge — not exposed via TLS)"
    fi
  done
  if [[ $want_edge -eq 1 && ${#want_services[@]} -gt 0 ]]; then
    echo
    echo "NOTE: ensure DNS A records for ${want_services[*]/%/.${DOMAIN}} point at this host"
    echo "      and ports 80/443 are open so Let's Encrypt can issue certs."
  fi
}

# ===========================================================================
# MODE DISPATCH
# ===========================================================================
case "${1:-}" in
  deploy|plan|--plan|--dry-run|-all|--all|-infra|--infra|-nginx|--nginx|-edge|--edge|-*)
    _run_deploy "$@"
    unset _src _script_dir _env_file
    return 0 2>/dev/null || exit 0
    ;;
esac

# Executed with no args (`bash run.sh`) → interactive deployment.
# Sourced with no args (`source run.sh`) → fall through to local-dev shim.
if [[ $# -eq 0 && $_sourced -eq 0 ]]; then
  _run_deploy deploy
  unset _src _script_dir _env_file _sourced
  exit 0
fi

# ---------------------------------------------------------------------------
# LOCAL DEV MODE (default) — export connection strings + bring up infra.
# ---------------------------------------------------------------------------
_load_env

# Require the base variables the connection strings are built from.
for _v in MONGO_USER MONGO_PASS MONGO_HOST_PORT REDIS_HOST_PORT \
          RABBITMQ_USER RABBITMQ_PASS RABBITMQ_HOST_PORT; do
  if [[ -z "${!_v:-}" ]]; then
    echo "run.sh: $_v not set in $_env_file" >&2
    return 1 2>/dev/null || exit 1
  fi
done

# Compose the .NET connection strings from the base variables.
_mongo="mongodb://${MONGO_USER}:${MONGO_PASS}@localhost:${MONGO_HOST_PORT}/?authSource=admin"

export BlocksSecret__CacheConnectionString="localhost:${REDIS_HOST_PORT},abortConnect=false"
export BlocksSecret__MessageConnectionString="amqp://${RABBITMQ_USER}:${RABBITMQ_PASS}@localhost:${RABBITMQ_HOST_PORT}"
export BlocksSecret__LmtMessageConnectionString="amqp://<username>:<password>@localhost:${RABBITMQ_HOST_PORT}/"
export BlocksSecret__DatabaseConnectionString="$_mongo"
export BlocksSecret__LogConnectionString="$_mongo"
export BlocksSecret__MetricConnectionString="$_mongo"
export BlocksSecret__TraceConnectionString="$_mongo"

# Generate configure.js so mongodb-seed has the correct client config.
bash "$_script_dir/configure.sh" --env "$_env_file"

# Bring up the local infrastructure (idempotent — no-op if already running).
_compose --profile infra up -d

echo "run.sh: infrastructure up; BlocksSecret__* connection strings exported."

# Clean up temp vars so a sourced shell stays tidy.
unset _src _script_dir _env_file _v _mongo _sourced

# If a command was passed, run it with the environment in place.
if [[ $# -gt 0 ]]; then
  "$@"
fi
