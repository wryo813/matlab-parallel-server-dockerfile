#!/bin/bash
# compute ノード (ワーカー) の起動スクリプト。
# docker-compose.yml / docker-compose-wNFS.yml から /opt/mjs/entrypoint.sh に
# 読み取り専用でマウントされ、`bash` で実行される。
set -euo pipefail

SECRETS_DIR="${MJS_SECRETS_DIR:-/run/secrets}"
SHARED_SECRET="${SECRETS_DIR}/mjs_shared_secret"

log() { printf '[entrypoint] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

# ---------------------------------------------------------------------------
# 1. 入力検証 (mjs_def.sh はシェルスクリプトとして source される)
# ---------------------------------------------------------------------------
validate() { [[ "$2" =~ $3 ]] || die "$1='$2' に使用できない文字が含まれています"; }
HOST_RE='^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$'
NAME_RE='^[A-Za-z0-9_-]+$'

validate FQDN            "${FQDN:-}"               "$HOST_RE"
validate JM_HOST         "${JM_HOST:-}"            "$HOST_RE"
validate JM_NAME         "${JM_NAME:-}"            "$NAME_RE"
validate NUM_WORKERS     "${NUM_WORKERS:-}"        '^[1-9][0-9]*$'
validate SECURITY_LEVEL  "${SECURITY_LEVEL:-}"     '^[0-3]$'
validate MJS_START_DELAY "${MJS_START_DELAY:-10}"  '^[0-9]+$'

if (( SECURITY_LEVEL < 2 )) && [ "${ALLOW_INSECURE_SECURITY_LEVEL:-0}" != "1" ]; then
    die "SECURITY_LEVEL=${SECURITY_LEVEL} では認証なしで root としてコードを実行できます。意図的に下げる場合は ALLOW_INSECURE_SECURITY_LEVEL=1 を設定してください"
fi
[ -r "${SHARED_SECRET}" ] || die "共有シークレット ${SHARED_SECRET} が読めません (compute/secrets/mjs_shared_secret に head と同じファイルを置いてください)"
[ -s "${SHARED_SECRET}" ] || die "共有シークレット ${SHARED_SECRET} が空です"

# ---------------------------------------------------------------------------
# 2. MATLAB の場所と mjs_def.sh の管理ブロック
# ---------------------------------------------------------------------------
MATLAB_ROOT="$(dirname "$(dirname "$(readlink -f "$(command -v matlab)")")")"
MJS_BIN_DIR="${MATLAB_ROOT}/toolbox/parallel/bin"
MJS_DEF_FILE="${MJS_BIN_DIR}/mjs_def.sh"
[ -f "${MJS_DEF_FILE}" ] || die "${MJS_DEF_FILE} がありません (MATLAB_Parallel_Server が入っていません)"

BLOCK_BEGIN='# --- BEGIN managed by compose entrypoint (compute) ---'
BLOCK_END='# --- END managed by compose entrypoint (compute) ---'
sed -i "/^${BLOCK_BEGIN}\$/,/^${BLOCK_END}\$/d" "${MJS_DEF_FILE}"
{
    printf '\n%s\n' "${BLOCK_BEGIN}"
    printf "%s='%s'\n" HOSTNAME                      "${FQDN}"
    # 以下は head ノードと同じ値でなければワーカーが登録できない
    printf "%s='%s'\n" SECURITY_LEVEL                "${SECURITY_LEVEL}"
    printf "%s='%s'\n" USE_SECURE_COMMUNICATION      "true"
    printf "%s='%s'\n" ALL_SERVER_SOCKETS_IN_CLUSTER "true"
    printf "%s='%s'\n" REQUIRE_SCRIPT_VERIFICATION   "true"
    printf "%s='%s'\n" SHARED_SECRET_FILE            "${SHARED_SECRET}"
    printf '%s\n' "${BLOCK_END}"
} >> "${MJS_DEF_FILE}"
log "mjs_def.sh に設定を書き込みました (${MJS_DEF_FILE})"

# ---------------------------------------------------------------------------
# 3. ワーカーをバックグラウンドで起動する (特権コマンドなので共有シークレットで署名する)
# ---------------------------------------------------------------------------
(
    set +e
    sleep "${MJS_START_DELAY:-10}"   # ローカルの mjs サービスがポートを開くまでの待ち時間
    "${MJS_BIN_DIR}/startworker" \
        -jobmanagerhost "${JM_HOST}" -jobmanager "${JM_NAME}" -num "${NUM_WORKERS}" \
        -secretfile "${SHARED_SECRET}" -clean -v
    rc=$?
    if [ "${rc}" -eq 0 ]; then
        log "startworker が完了しました (${NUM_WORKERS} ワーカー -> ${JM_NAME}@${JM_HOST})"
    else
        log "startworker が失敗しました (exit ${rc})。head のジョブマネージャが起動済みか確認してください"
    fi
) &

# ---------------------------------------------------------------------------
# 4. mjs サービスをフォアグラウンドで起動し PID 1 にする
# ---------------------------------------------------------------------------
exec "${MJS_BIN_DIR}/mjs" console -clean
