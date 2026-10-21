#!/usr/bin/env bash
# Postgres 기동 — **공식 postgres 이미지의 엔트리포인트를 대신한다** (2026-10-21).
#
# ## 왜 직접 쓰나
#
# `postgres:16-trixie` 는 **gosu**(Go 로 만든 권한 내림 도구)를 품는다. 그 안의
# Go stdlib 1.24.6 이 **치명 4 · 고위험 30** 을 올리는데, 우리 코드와 무관하고
# 우리가 고칠 수 없다 — 2026-10-16 실측에서 **새 Go 로 gosu 를 다시 빌드해
# 덮어도 숫자가 그대로였다**. 검사기가 **아래 레이어의 블롭**까지 읽기 때문이다.
# 태그를 바꿔도 같다(postgres 16·17·18 × trixie·bookworm **전부 4C 33H**).
#
# 그래서 **처음부터 gosu 가 없는 베이스**(`debian:trixie-slim`)에 PGDG 의
# postgresql-16 을 얹고, 권한 내림은 **컨테이너를 postgres 로 띄우는 것**으로
# 대신한다(`USER postgres`). 내릴 권한이 없으면 내릴 도구도 필요 없다.
#
# ## 공식과 같게 지킨 것
#
#   · uid/gid **999** — 기존 볼륨의 파일 주인과 같아야 한다. 다르면 못 읽는다
#   · `PGDATA` 가 **비어 있을 때만** initdb 하고 `docker-entrypoint-initdb.d` 를 돈다
#   · `POSTGRES_USER` · `POSTGRES_PASSWORD` · `POSTGRES_DB` 의 뜻
#   · 초기화 중에는 **TCP 를 안 연다** — 반쯤 준비된 DB 에 앱이 붙는 것을 막는다
#
# ⚠ 공식 엔트리포인트의 **모든** 기능을 옮기지 않았다. 여기서 쓰는 것만 옮겼다 —
#   `POSTGRES_INITDB_ARGS` · `POSTGRES_HOST_AUTH_METHOD` · 루트로 띄웠을 때의
#   권한 내림은 없다. 쓰게 되면 그때 더한다.
set -euo pipefail

: "${PGDATA:=/var/lib/postgresql/data}"
: "${POSTGRES_USER:=postgres}"
: "${POSTGRES_DB:=$POSTGRES_USER}"

say() { printf '[entrypoint] %s\n' "$1"; }

mkdir -p "$PGDATA"
chmod 0700 "$PGDATA" 2>/dev/null || true
mkdir -p /var/run/postgresql
chmod 0775 /var/run/postgresql 2>/dev/null || true

if [ ! -s "$PGDATA/PG_VERSION" ]; then
    if [ -z "${POSTGRES_PASSWORD:-}" ]; then
        say "POSTGRES_PASSWORD 가 비어 있다 — 빈 암호로 DB 를 만들지 않는다"
        exit 1
    fi

    say "PGDATA 가 비었다 — initdb"
    pwfile="$(mktemp)"
    printf '%s' "$POSTGRES_PASSWORD" > "$pwfile"
    initdb --pgdata="$PGDATA" --username="$POSTGRES_USER" --pwfile="$pwfile" \
           --encoding=UTF8 --locale=en_US.utf8 --auth-local=trust --auth-host=scram-sha-256
    rm -f "$pwfile"

    # 초기화 동안에는 **소켓만** 연다. 이때 TCP 를 열면 앱이 확장도 graph 도
    # 없는 DB 에 붙어 "연결은 되는데 조회에서 터지는" 그 모양이 된다.
    pg_ctl --pgdata="$PGDATA" --wait \
           --options="-c listen_addresses='' -c unix_socket_directories=/var/run/postgresql" start

    if [ "$POSTGRES_DB" != "postgres" ]; then
        say "데이터베이스 생성 — $POSTGRES_DB"
        psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres \
             -c "CREATE DATABASE \"$POSTGRES_DB\""
    fi

    if [ -d /docker-entrypoint-initdb.d ]; then
        for f in /docker-entrypoint-initdb.d/*; do
            [ -e "$f" ] || continue
            case "$f" in
                *.sh)   say "초기화 스크립트 — $f"; bash "$f" ;;
                *.sql)  say "초기화 SQL — $f"
                        psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" \
                             --dbname "$POSTGRES_DB" -f "$f" ;;
                *)      say "건너뜀 — $f" ;;
            esac
        done
    fi

    pg_ctl --pgdata="$PGDATA" --mode=fast --wait stop

    # 바깥에서 붙을 수 있게 한다 — 공식 이미지와 같은 scram-sha-256.
    printf 'host all all all scram-sha-256\n' >> "$PGDATA/pg_hba.conf"
    say "초기화 끝"
fi

exec postgres -D "$PGDATA" -c listen_addresses='*'
