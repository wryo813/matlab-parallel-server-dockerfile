#!/usr/bin/env bash
# MJS クラスタの起動テスト。ビルド済みのイメージで head と compute を本番の compose (entrypoint) のまま起動し、
# 次を確認する。ライセンスは不要 (MATLAB のジョブは投げない)。
#   1. head のジョブマネージャが起動する (SECURITY_LEVEL=2 + LDAP 認証、管理者パスワードは secret から)
#   2. compute のワーカーが NUM_WORKERS 台、head のジョブマネージャに登録される
#   3. 管理者パスワードが docker logs に出ない
#   4. head / compute のコンテナ内のプロセスがすべて matlab ユーザーで動いている (root のプロセスが無い)
#   5. docker restart 後も head のジョブマネージャが起動し、mjs_def.sh に追記した設定が重複しない
#
# 使い方: IMAGE_NAME=<イメージ> ./run-cluster-test.sh
# 前提: docker / docker compose が使え、sudo で apt と slapd を動かせる Ubuntu (GitHub の ubuntu-latest ランナー)。

set -euo pipefail

IMAGE_NAME="${IMAGE_NAME:?IMAGE_NAME is required}"
JM_NAME="${JM_NAME:-MyMJS}"
NUM_WORKERS="${NUM_WORKERS:-2}"
ADMIN_USER="${MJS_ADMIN_USER:-mjsadmin}"
# 各段階の待ち時間の上限 (秒)
WAIT_SECS="${WAIT_SECS:-300}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/../../../.." && pwd)"
ALT_DIR="${REPO_ROOT}/alternates/building-on-matlab-docker-image"
HEAD_CONTAINER="matlab-head-node"
COMPUTE_CONTAINER="matlab-compute-node"

# テストごとに作る管理者パスワード。ログに出ないことの確認にも使う
ADMIN_PASS="ci-$(head -c 18 /dev/urandom | base64 | tr -d '/+=')"

compose() {
    MJS_TEST_IMAGE="${IMAGE_NAME}" \
    LDAP_HOST="host.docker.internal" \
    JM_NAME="${JM_NAME}" \
    NUM_WORKERS="${NUM_WORKERS}" \
    SECURITY_LEVEL=2 \
    MJS_ADMIN_USER="${ADMIN_USER}" \
        docker compose -p mjs-ci \
            -f "${ALT_DIR}/head/docker-compose.yml" \
            -f "${ALT_DIR}/compute/docker-compose.yml" \
            -f "${HERE}/docker-compose.ci.yml" \
            "$@"
}

log() { printf '\n=== %s\n' "$*"; }
fail() { printf '\nFAIL: %s\n' "$*" >&2; exit 1; }

# 作成した secret / 証明書のダミーを後片付けで消すため、元から無かったものだけ記録する
CREATED_FILES=()
make_file() {
    local path="$1" content="$2"
    if [ -e "${path}" ]; then
        fail "${path} already exists; refusing to overwrite it (move it away before running this test)"
    fi
    mkdir -p "$(dirname "${path}")"
    printf '%s' "${content}" > "${path}"
    CREATED_FILES+=("${path}")
}

on_exit() {
    local rc=$?
    if [ "${rc}" -ne 0 ]; then
        log "Diagnostics (test failed with exit code ${rc})"
        for c in "${HEAD_CONTAINER}" "${COMPUTE_CONTAINER}"; do
            echo "--- docker logs ${c} (last 200 lines)"
            docker logs --tail 200 "${c}" 2>&1 | sed "s/${ADMIN_PASS}/********/g" || true
            echo "--- nodestatus in ${c}"
            docker exec "${c}" nodestatus -infolevel 2 2>&1 || true
        done
    fi
    log "Cleanup"
    compose down -v --remove-orphans > /dev/null 2>&1 || true
    if [ "${#CREATED_FILES[@]}" -gt 0 ]; then
        sudo rm -f "${CREATED_FILES[@]}"
    fi
    exit "${rc}"
}
trap on_exit EXIT

# $1 秒以内に条件 ($2...) が成立するまで 5 秒ごとに再試行する
wait_until() {
    local timeout="$1"; shift
    local waited=0
    until "$@"; do
        if [ "${waited}" -ge "${timeout}" ]; then
            return 1
        fi
        sleep 5
        waited=$((waited + 5))
    done
}

container_running() {
    [ "$(docker inspect -f '{{.State.Running}}' "$1" 2> /dev/null)" = "true" ]
}

# head の nodestatus の "Job manager:" 節を読み、JM_NAME の Status と Number of workers を "状態 台数" で出す。
# nodestatus (R2026b) の出力例:
#   Job manager:
#        Name                                     MyMJS
#        Number of workers                        0
#        Status                                   running
job_manager_info() {
    docker exec "${HEAD_CONTAINER}" nodestatus 2> /dev/null \
        | awk -v jm="${JM_NAME}" '
            /^[^ ]/ { injm = ($0 ~ /^Job manager:/); name = "" }
            injm && $1 == "Name" { name = $2 }
            injm && name == jm && $1 == "Number" && $2 == "of" && $3 == "workers" { nw = $4 }
            injm && name == jm && $1 == "Status" { st = $2 }
            END { if (st != "") print st, nw + 0 }'
}

# head のジョブマネージャ JM_NAME が running か
job_manager_running() {
    container_running "${HEAD_CONTAINER}" || fail "${HEAD_CONTAINER} exited"
    local info
    info="$(job_manager_info)"
    echo "job manager '${JM_NAME}': ${info:-not found}"
    [ "${info%% *}" = "running" ]
}

# head のジョブマネージャ JM_NAME に NUM_WORKERS 台以上のワーカーが登録されているか
workers_registered() {
    container_running "${HEAD_CONTAINER}" || fail "${HEAD_CONTAINER} exited"
    container_running "${COMPUTE_CONTAINER}" || fail "${COMPUTE_CONTAINER} exited"
    local info n
    info="$(job_manager_info)"
    n="${info##* }"
    echo "registered workers: ${n:-0}/${NUM_WORKERS}"
    [ "${info%% *}" = "running" ] && [ "${n:-0}" -ge "${NUM_WORKERS}" ]
}

# コンテナ内の全プロセスのユーザーを列挙し、root のプロセスがあれば失敗にする
assert_no_root_processes() {
    local c="$1" users
    # docker top は PID 列が必須。1 行目の見出しを除いてユーザー列だけを取り出す
    users="$(docker top "${c}" -eo user,pid | awk 'NR > 1 { print $1 }' | sort -u)"
    echo "${c}: process users = $(echo "${users}" | tr '\n' ' ')"
    if echo "${users}" | grep -qx 'root\|0'; then
        docker top "${c}" -eo user,pid,args
        fail "${c} has processes running as root"
    fi
}

appended_security_lines() {
    docker exec "${HEAD_CONTAINER}" bash -c \
        'f=$(dirname $(dirname $(readlink -f $(which matlab))))/toolbox/parallel/bin/mjs_def.sh; grep -c "^SECURITY_LEVEL=" "$f"'
}

log "Image: ${IMAGE_NAME}, job manager: ${JM_NAME}, workers: ${NUM_WORKERS}"
MATLAB_UID="$(docker run --rm --entrypoint id "${IMAGE_NAME}" -u matlab)"
echo "matlab UID in the image: ${MATLAB_UID}"

log "Start test LDAP server on the runner"
sudo "${HERE}/setup-test-ldap.sh" "${ADMIN_USER}" "${ADMIN_PASS}"

log "Prepare secrets (dummy proxy certificate; the proxy service is not started)"
make_file "${ALT_DIR}/head/certs/proxy-certificate.json" '{}'
make_file "${ALT_DIR}/head/secrets/mjs_admin_pass.txt" "${ADMIN_PASS}"
chmod 600 "${ALT_DIR}/head/secrets/mjs_admin_pass.txt"
# compose の secret はホストのファイルをそのまま bind mount するため、コンテナ内の matlab が読める所有者にする
sudo chown "${MATLAB_UID}" "${ALT_DIR}/head/secrets/mjs_admin_pass.txt"

log "1. Start head node and wait for job manager '${JM_NAME}'"
compose up -d --no-build "${HEAD_CONTAINER}"
wait_until "${WAIT_SECS}" job_manager_running || fail "job manager '${JM_NAME}' did not start within ${WAIT_SECS} s"
echo "OK: job manager '${JM_NAME}' is running"

log "2. Start compute node and wait for ${NUM_WORKERS} workers to register"
compose up -d --no-build "${COMPUTE_CONTAINER}"
wait_until "${WAIT_SECS}" workers_registered || fail "${NUM_WORKERS} workers did not register with '${JM_NAME}' within ${WAIT_SECS} s"
echo "OK: ${NUM_WORKERS} workers are registered with '${JM_NAME}'"

log "3. Admin password must not appear in docker logs"
for c in "${HEAD_CONTAINER}" "${COMPUTE_CONTAINER}"; do
    if docker logs "${c}" 2>&1 | grep -qF "${ADMIN_PASS}"; then
        fail "admin password appears in docker logs ${c}"
    fi
done
echo "OK: admin password is not in the logs"

log "4. No process runs as root"
assert_no_root_processes "${HEAD_CONTAINER}"
assert_no_root_processes "${COMPUTE_CONTAINER}"
echo "OK: all processes run as non-root"

log "5. Restart head node"
before="$(appended_security_lines)"
docker restart "${HEAD_CONTAINER}" > /dev/null
wait_until "${WAIT_SECS}" job_manager_running || fail "job manager '${JM_NAME}' did not start again after docker restart"
after="$(appended_security_lines)"
echo "SECURITY_LEVEL lines in mjs_def.sh: before restart ${before}, after restart ${after}"
[ "${before}" = "${after}" ] || fail "mjs_def.sh settings were appended again on restart"
echo "OK: job manager restarted and mjs_def.sh was not duplicated"

log "All MJS cluster checks passed"
