#!/bin/bash
# head ノード (ジョブマネージャ) の起動スクリプト。
# compose から /opt/mjs/entrypoint.sh に読み取り専用でマウントされ、`bash` で実行される。
#
# 役割:
#   1. .env 由来の値を検証する (mjs_def.sh はシェルスクリプトとして source されるため)
#   2. mjs_def.sh の末尾に、管理ブロックとしてセキュリティ設定を書き込む (再起動しても重複しない)
#   3. LDAPS 用の CA 証明書があれば MATLAB 同梱 JRE の信頼ストアに取り込む
#   4. 管理者パスワードをログに出さずに startjobmanager に渡す (feed-admin-password.py)
#   5. mjs サービスを PID 1 として起動する
set -euo pipefail

SECRETS_DIR="${MJS_SECRETS_DIR:-/run/secrets}"
SHARED_SECRET="${SECRETS_DIR}/mjs_shared_secret"
ADMIN_PASS_FILE="${SECRETS_DIR}/mjs_admin_pass"
CERTS_DIR="${MJS_CERTS_DIR:-/opt/mjs/certs}"
LDAP_CA_FILE="${CERTS_DIR}/ldap-ca.pem"
FEEDER="${MJS_FEEDER:-/opt/mjs/feed-admin-password.py}"

log() { printf '[entrypoint] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

# ---------------------------------------------------------------------------
# 1. 入力検証
# ---------------------------------------------------------------------------
validate() { # validate <変数名> <値> <許可する正規表現>
    [[ "$2" =~ $3 ]] || die "$1='$2' に使用できない文字が含まれています"
}
HOST_RE='^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$'
NAME_RE='^[A-Za-z0-9_-]+$'
# DN や UPN で使う文字だけを許可する (空白・引用符・シェルのメタ文字は不可)
PRINCIPAL_RE='^[]A-Za-z0-9=,.@_[-]+$'

validate FQDN                  "${FQDN:-}"                  "$HOST_RE"
validate JM_NAME               "${JM_NAME:-}"               "$NAME_RE"
validate SECURITY_LEVEL        "${SECURITY_LEVEL:-}"        '^[0-3]$'
validate LDAP_HOST             "${LDAP_HOST:-}"             "$HOST_RE"
validate LDAP_SCHEME           "${LDAP_SCHEME:-}"           '^ldaps?$'
validate LDAP_PORT             "${LDAP_PORT:-}"             '^[0-9]{1,5}$'
validate LDAP_PRINCIPAL_FORMAT "${LDAP_PRINCIPAL_FORMAT:-}" "$PRINCIPAL_RE"
validate MJS_ADMIN_USER        "${MJS_ADMIN_USER:-}"        '^[A-Za-z0-9._@-]+$'
validate LDAP_SYNC_INTERVAL    "${LDAP_SYNC_INTERVAL:-}"    '^[0-9]+$'
validate MJS_START_DELAY       "${MJS_START_DELAY:-10}"     '^[0-9]+$'

if (( SECURITY_LEVEL < 2 )) && [ "${ALLOW_INSECURE_SECURITY_LEVEL:-0}" != "1" ]; then
    die "SECURITY_LEVEL=${SECURITY_LEVEL} では認証なしで root としてコードを実行できます。意図的に下げる場合は ALLOW_INSECURE_SECURITY_LEVEL=1 を設定してください"
fi
if [ "${LDAP_SCHEME}" = "ldap" ]; then
    log "警告: LDAP_SCHEME=ldap のため、全ユーザーのパスワードが head と LDAP サーバの間を平文で流れます"
fi

[ -r "${SHARED_SECRET}" ]   || die "共有シークレット ${SHARED_SECRET} が読めません (head/secrets/mjs_shared_secret を用意してください)"
[ -s "${SHARED_SECRET}" ]   || die "共有シークレット ${SHARED_SECRET} が空です"
[ -r "${ADMIN_PASS_FILE}" ] || die "管理者パスワード ${ADMIN_PASS_FILE} が読めません (head/secrets/mjs_admin_pass.txt を用意してください)"
[ -r "${FEEDER}" ]          || die "${FEEDER} がありません (compose の volumes を確認してください)"
command -v python3 >/dev/null 2>&1 || die "python3 がイメージにありません (Dockerfile を再ビルドするか python3 を追加してください)"

# ---------------------------------------------------------------------------
# 2. MATLAB の場所と mjs_def.sh の管理ブロック
# ---------------------------------------------------------------------------
MATLAB_ROOT="$(dirname "$(dirname "$(readlink -f "$(command -v matlab)")")")"
MJS_BIN_DIR="${MATLAB_ROOT}/toolbox/parallel/bin"
MJS_DEF_FILE="${MJS_BIN_DIR}/mjs_def.sh"
[ -f "${MJS_DEF_FILE}" ] || die "${MJS_DEF_FILE} がありません (MATLAB_Parallel_Server が入っていません)"

BLOCK_BEGIN='# --- BEGIN managed by compose entrypoint (head) ---'
BLOCK_END='# --- END managed by compose entrypoint (head) ---'
# 前回起動時のブロックを削除してから書き直す (docker compose restart で重複しない)
sed -i "/^${BLOCK_BEGIN}\$/,/^${BLOCK_END}\$/d" "${MJS_DEF_FILE}"
{
    printf '\n%s\n' "${BLOCK_BEGIN}"
    # 後に書かれた代入が優先されるため、同名の既定値をここで上書きする
    printf "%s='%s'\n" HOSTNAME                           "${FQDN}"
    printf "%s='%s'\n" SECURITY_LEVEL                     "${SECURITY_LEVEL}"
    printf "%s='%s'\n" ADMIN_USER                         "${MJS_ADMIN_USER}"
    printf "%s='%s'\n" USE_LDAP_SERVER_AUTHENTICATION     "true"
    printf "%s='%s'\n" LDAP_URL                           "${LDAP_SCHEME}://${LDAP_HOST}:${LDAP_PORT}"
    printf "%s='%s'\n" LDAP_SECURITY_PRINCIPAL_FORMAT     "${LDAP_PRINCIPAL_FORMAT}"
    printf "%s='%s'\n" LDAP_SYNCHRONIZATION_INTERVAL_SECS "${LDAP_SYNC_INTERVAL}"
    # 共有シークレットによる保護:
    #   USE_SECURE_COMMUNICATION   クライアント・ジョブマネージャ・ワーカー間を TLS 1.3 で暗号化
    #   ALL_SERVER_SOCKETS_IN_CLUSTER  接続をすべてクライアント発にする (SOCKS5 プロキシ経由に必要)
    #   REQUIRE_SCRIPT_VERIFICATION    start/stop 系の特権コマンドにシークレットでの署名を要求
    #   REQUIRE_CLIENT_CERTIFICATE     プロキシを迂回した直接接続にも証明書付きプロファイルを要求
    printf "%s='%s'\n" USE_SECURE_COMMUNICATION           "true"
    printf "%s='%s'\n" ALL_SERVER_SOCKETS_IN_CLUSTER      "true"
    printf "%s='%s'\n" REQUIRE_SCRIPT_VERIFICATION        "true"
    printf "%s='%s'\n" REQUIRE_CLIENT_CERTIFICATE         "true"
    printf "%s='%s'\n" SHARED_SECRET_FILE                 "${SHARED_SECRET}"
    printf '%s\n' "${BLOCK_END}"
} >> "${MJS_DEF_FILE}"
log "mjs_def.sh に設定を書き込みました (${MJS_DEF_FILE})"

# ---------------------------------------------------------------------------
# 3. LDAPS 用 CA 証明書を MATLAB 同梱 JRE の信頼ストアに取り込む
#    手順は MathWorks "Configure LDAP Server Authentication" の記載に従う
# ---------------------------------------------------------------------------
if [ -s "${LDAP_CA_FILE}" ]; then
    CACERTS="$(find -L "${MATLAB_ROOT}/sys/java" -type f -path '*/lib/security/cacerts' 2>/dev/null | head -n 1)"
    KEYTOOL="$(find -L "${MATLAB_ROOT}/sys/java" -type f -name keytool 2>/dev/null | head -n 1)"
    [ -n "${CACERTS}" ] && [ -n "${KEYTOOL}" ] || die "MATLAB 同梱 JRE の cacerts / keytool が見つかりません"
    chmod u+w "${CACERTS}"
    if "${KEYTOOL}" -list -keystore "${CACERTS}" -storepass changeit -alias mjs-ldap-ca >/dev/null 2>&1; then
        "${KEYTOOL}" -delete -keystore "${CACERTS}" -storepass changeit -alias mjs-ldap-ca >/dev/null
    fi
    "${KEYTOOL}" -importcert -noprompt -trustcacerts -keystore "${CACERTS}" -storepass changeit \
        -alias mjs-ldap-ca -file "${LDAP_CA_FILE}" >/dev/null
    log "LDAPS 用 CA 証明書を ${CACERTS} に取り込みました"
elif [ "${LDAP_SCHEME}" = "ldaps" ]; then
    log "注意: ${LDAP_CA_FILE} が無いため、LDAPS の証明書は JRE 既定の信頼ストアで検証されます"
fi

# ---------------------------------------------------------------------------
# 4. ジョブマネージャをバックグラウンドで起動する
#    startjobmanager は管理者 (ADMIN_USER) の LDAP パスワードを端末から対話で要求し、
#    非対話で渡すオプションは無い。feed-admin-password.py が PTY を作り、
#    プロンプトを検出してからエコーを切って投入し、出力にパスワードを残さない。
# ---------------------------------------------------------------------------
(
    set +e
    sleep "${MJS_START_DELAY:-10}"   # mjs サービスがポートを開くまでの待ち時間
    python3 "${FEEDER}" \
        --password-file "${ADMIN_PASS_FILE}" \
        --prompt-timeout "${MJS_PROMPT_TIMEOUT:-180}" \
        -- "${MJS_BIN_DIR}/startjobmanager" -name "${JM_NAME}" -secretfile "${SHARED_SECRET}" -clean -v
    rc=$?
    if [ "${rc}" -eq 0 ]; then
        log "startjobmanager が完了しました (ジョブマネージャ: ${JM_NAME})"
    else
        log "startjobmanager が失敗しました (exit ${rc})。docker compose logs を確認してください"
    fi
) &

# ---------------------------------------------------------------------------
# 5. mjs サービスをフォアグラウンドで起動し PID 1 にする
# ---------------------------------------------------------------------------
exec "${MJS_BIN_DIR}/mjs" console -clean
