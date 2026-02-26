#!/bin/bash
set -e

EXISTING_MATLAB_LOCATION=$(dirname $(dirname $(readlink -f $(which matlab))))
MJS_DEF_FILE="${EXISTING_MATLAB_LOCATION}/toolbox/parallel/bin/mjs_def.sh"
MJS_BIN="${EXISTING_MATLAB_LOCATION}/toolbox/parallel/bin/mjs"
START_JOB_MANAGER_BIN="${EXISTING_MATLAB_LOCATION}/toolbox/parallel/bin/startjobmanager"
START_WORKER_BIN="${EXISTING_MATLAB_LOCATION}/toolbox/parallel/bin/startworker"

# FQDNの設定
if [ -n "${FQDN}" ] && [ -f "${MJS_DEF_FILE}" ]; then
    sed -i 's|^#HOSTNAME=`hostname -f`|HOSTNAME="'"${FQDN}"'"|' "${MJS_DEF_FILE}"
fi

# mjsサービスの起動 (Head/Compute共通)
${MJS_BIN} start

# NODE_TYPEに応じた分岐
if [ "${NODE_TYPE}" = "head" ]; then
    JM_NAME=${JM_NAME:-MyMJS}
    ${START_JOB_MANAGER_BIN} -name "${JM_NAME}" -v
    
    # ジョブマネージャーの起動完了を待機するための遅延
    sleep 10
    
    # COMPUTE_NODES_CONFIG環境変数が設定されている場合、ワーカーを起動
    if [ -n "${COMPUTE_NODES_CONFIG}" ]; then
        CONFIGS=$(echo "${COMPUTE_NODES_CONFIG}" | tr ',' ' ')
        for CONFIG in ${CONFIGS}; do
            NODE=$(echo "${CONFIG}" | cut -d':' -f1)
            NUM_WORKERS=$(echo "${CONFIG}" | cut -d':' -f2)
            
            if [ -z "${NUM_WORKERS}" ] || [ "${NODE}" = "${NUM_WORKERS}" ]; then
                echo "Warning: Invalid configuration format '${CONFIG}'. Skipping."
                continue
            fi
            
            ${START_WORKER_BIN} -jobmanagerhost "${FQDN}" -jobmanager "${JM_NAME}" -remotehost "${NODE}" -num "${NUM_WORKERS}" -v
        done
    fi
elif [ "${NODE_TYPE}" = "compute" ]; then
    # Computeノードはmjsサービスを起動した状態で待機
    :
else
    echo "Error: NODE_TYPE environment variable must be set to 'head' or 'compute'."
    exit 1
fi

# コンテナのメインプロセスを維持
tail -f /dev/null