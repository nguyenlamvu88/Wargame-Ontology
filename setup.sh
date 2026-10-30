#!/usr/bin/env sh
set -eu
cd "$(dirname "$0")"
if [ -f .env ]; then
  echo '.env already exists; keeping current settings.'
else
  if ! command -v openssl >/dev/null 2>&1; then
    echo 'OpenSSL is required to generate passwords; alternatively copy .env.example to .env and replace both passwords.' >&2
    exit 1
  fi
  umask 077
  {
    echo 'COMPOSE_PROJECT_NAME=wargame'
    printf 'WARGAME_POSTGRES_PASSWORD=%s\n' "$(openssl rand -hex 24)"
    printf 'WARGAME_NEO4J_PASSWORD=%s\n' "$(openssl rand -hex 24)"
    echo 'WARGAME_POSTGRES_PORT=15432'
    echo 'WARGAME_NEO4J_HTTP_PORT=7474'
    echo 'WARGAME_NEO4J_BOLT_PORT=17687'
  } > .env
  echo 'Created .env with unique local passwords.'
fi
if ! command -v docker >/dev/null 2>&1; then
  echo 'Install/start Docker Desktop (Linux containers), then run docker compose up -d --build.' >&2
  exit 1
fi
docker compose version
docker compose config --quiet
echo 'Ready: docker compose up -d --build'
