# MATLAB Parallel Server on Docker Compose

このリポジトリは [mathworks-ref-arch/matlab-dockerfile](https://github.com/mathworks-ref-arch/matlab-dockerfile) のフォークです。
upstream の内容はそのまま残したうえで、**MATLAB Parallel Server (MJS) のクラスタを Docker Compose で構築する**ための構成を追加しています。

このドキュメントはフォーク独自の追加部分のみを扱います。ベースイメージのビルド方法など upstream 共通の内容は、[ルートの README.md](README.md) および
[alternates/building-on-matlab-docker-image/README.md](alternates/building-on-matlab-docker-image/README.md) を参照してください。

## 目次

- [使用するファイル](#使用するファイル)
- [upstream からの変更点](#upstream-からの変更点)
- [構成](#構成)
- [セキュリティ設計](#セキュリティ設計)
- [前提条件](#前提条件)
- [1. イメージのビルド](#1-イメージのビルド)
- [2. head ノードの起動](#2-head-ノードの起動)
- [3. compute ノードの起動](#3-compute-ノードの起動)
- [4. 動作確認とクライアント接続](#4-動作確認とクライアント接続)
- [5. ホストのファイアウォール](#5-ホストのファイアウォール)
- [環境変数リファレンス](#環境変数リファレンス)
- [既知の問題・注意点](#既知の問題注意点)
- [upstream への追従](#upstream-への追従)

## 使用するファイル

このフォークで実際に使うのは `alternates/building-on-matlab-docker-image/` 配下だけです。

```
alternates/building-on-matlab-docker-image/
├── Dockerfile                        # head/compute 共通のイメージ定義
├── .dockerignore                     # secrets/ certs/ .env をビルドコンテキストから除外
├── head/
│   ├── docker-compose.yml            # head ノード（ジョブマネージャ）+ プロキシ
│   ├── entrypoint.sh                 # head の起動処理（compose が読み取り専用でマウント）
│   ├── feed-admin-password.py        # 管理者パスワードをログに出さずに startjobmanager に渡す
│   ├── .env.example
│   ├── certs/                        # (git 管理外) proxy-certificate.json, ldap-ca.pem
│   └── secrets/                      # (git 管理外) mjs_shared_secret, mjs_admin_pass.txt
└── compute/
    ├── docker-compose.yml            # compute ノード（ワーカー）
    ├── docker-compose-wNFS.yml       # compute ノード + NFS 共有マウント
    ├── entrypoint.sh                 # compute の起動処理（両 compose が共有）
    ├── .env.example
    └── secrets/                      # (git 管理外) mjs_shared_secret（head と同一ファイル）
```

リポジトリ内のそれ以外（`windows/`、`tests/`、`mpm-input-files/`、`alternates/` の他サブディレクトリ、
ルートの `Dockerfile` など）は **upstream 由来のもので、このフォークでは使用していません**。
upstream の更新をそのまま受け取るために意図的に残してあります（[upstream への追従](#upstream-への追従)参照）。

## upstream からの変更点

upstream との差分は以下のファイルのみです（このドキュメントとバナー行を除く）。

| ファイル | 種別 | 内容 |
| --- | --- | --- |
| `alternates/building-on-matlab-docker-image/Dockerfile` | upstream ファイルを改変 | 製品リストの大幅追加、parallel ツールボックスへの `PATH` 追加、`mjs_def.sh` のオンラインライセンス有効化、`python3` 追加、実行ユーザーを `root` に変更 |
| `alternates/building-on-matlab-docker-image/.dockerignore` | 新規 | 秘密ファイルをビルドコンテキストから除外 |
| `head/docker-compose.yml`, `head/entrypoint.sh`, `head/feed-admin-password.py` | 新規 | head ノードとプロキシの定義、起動処理 |
| `compute/docker-compose.yml`, `compute/docker-compose-wNFS.yml`, `compute/entrypoint.sh` | 新規 | compute ノードの定義、起動処理 |
| `.gitignore` | upstream ファイルを改変 | `.env` / `certs/` / `secrets/` を追加 |

### Dockerfile の変更内容

- **製品リスト** — `ARG ADDITIONAL_PRODUCTS` に約 120 製品を指定。MJS に必須の `MATLAB_Parallel_Server` と
  `Parallel_Computing_Toolbox` を含みます。ファイル後半には support package や事前学習済みモデルの一覧が
  **コメントアウトされた状態**で列挙されており、必要なものだけ有効化して使う想定です。
- **PATH** — `ENV PATH="/opt/matlab/${MATLAB_RELEASE}/toolbox/parallel/bin:${PATH}"` を追加。
  これにより `mjs`、`startjobmanager`、`startworker`、`nodestatus`、`mjsadmin` が直接呼べます。
- **apt パッケージ** — `bzip2`、`xz-utils`（大きな製品パッケージの展開に必要）、`python3`（`feed-admin-password.py` が使用）を追加。
- **ライセンス** — `mjs_def.sh` の `USE_ONLINE_LICENSING` を `"true"` に書き換え。
  MathWorks のオンラインライセンスを使う設定で、ネットワークライセンスマネージャ（`LICENSE_SERVER`）は
  upstream と同様コメントアウトのままです。
- **実行ユーザー** — `mjs` サービスの起動に必要なため、最終的に `USER root` としています。
  upstream のイメージは `matlab` ユーザーで終わるため、ここが挙動の違いになります。
- **WORKDIR** — `/home/matlab` をコメントアウトし `/tmp` に変更。

起動処理は Dockerfile には含めず、compose が `entrypoint.sh` を読み取り専用でマウントして `bash` で実行します。
プリビルドイメージを使う場合でも、イメージを作り直さずに起動処理を更新できます。

## 構成

```
  ┌─ head ホスト ──────────────────────────────────────────┐
  │  matlab-head-node  (entrypoint.sh)                     │
  │    mjs console            （PID 1、常駐）              │
  │    startjobmanager        （MJS_START_DELAY 秒後、    │
  │      -secretfile で署名、パスワードは PTY 経由で投入）│
  │                                                        │
  │  matlab-mjs-proxy                                      │
  │    ghcr.io/mathworks/parallel-server-proxy             │
  │    :1080 で mTLS 待ち受け ← 証明書付きプロファイルを持つ MATLAB クライアント
  └────────────────────────────────────────────────────────┘
                    ▲ ワーカー登録（TLS 1.3、共有シークレットで信頼）
  ┌─ compute ホスト（複数台）───────────────────────────────┐
  │  matlab-compute-node  (entrypoint.sh)                  │
  │    mjs console            （PID 1、常駐）              │
  │    startworker -num N     （MJS_START_DELAY 秒後、-secretfile で署名）
  │    （wNFS 版のみ）NFS 共有を /mnt/nfs にマウント       │
  └────────────────────────────────────────────────────────┘
```

- head / compute とも同じ Dockerfile から作った 1 つのイメージを使い、マウントする `entrypoint.sh` で役割を切り替えます。
- 両方とも `network_mode: host` / `ipc: host` です。MJS が動的なポート範囲を使うことと、
  ローカルの並列プールが共有メモリを使うことへの対応です。
- `matlab-mjs-proxy` は MathWorks 公式の SOCKS5 プロキシで、クラスタ外の MATLAB クライアントが
  単一ポート経由で MJS に接続するためのものです。クライアント認証は mTLS（共有シークレットから生成した証明書）で行います。

## セキュリティ設計

この構成は **「クラスタを使えるユーザー（LDAP で認証できる全員）は信頼できる」** ことを前提にしています。
MJS のセキュリティレベル 2 では、ワーカー上のタスクは mjs サービスを起動したユーザー（この構成では root）で実行されます。
したがって、ジョブを投入できるユーザーは compute コンテナ内で root 相当の操作ができます。
これは MJS の仕様で、レベル 3（投入ユーザーの権限で実行）に上げない限り変わりません。

その前提のもとで、起動処理と compose は次を強制します。

| 対策 | 内容 | 場所 |
| --- | --- | --- |
| 特権コマンドの署名 | `REQUIRE_SCRIPT_VERIFICATION=true`。`startworker`/`stopjobmanager` 等は共有シークレットで署名した呼び出ししか受け付けない。無認証でクラスタを停止・乗っ取りされることを防ぐ | `entrypoint.sh` |
| 通信の暗号化 | `USE_SECURE_COMMUNICATION=true` + `ALL_SERVER_SOCKETS_IN_CLUSTER=true`。クライアント・ジョブマネージャ・ワーカー間を TLS 1.3 で暗号化 | `entrypoint.sh` |
| 直接接続にも証明書 | `REQUIRE_CLIENT_CERTIFICATE=true`。プロキシを迂回して MJS ポートへ直接つないでも証明書付きプロファイルが必要 | `head/entrypoint.sh` |
| LDAPS | 既定で `ldaps://` 636 番。`certs/ldap-ca.pem` があれば起動時に MATLAB 同梱 JRE の信頼ストアへ取り込む | `head/entrypoint.sh` |
| 管理者パスワードの非表示 | `startjobmanager` のプロンプトを検出し、PTY のエコーを切ってから投入。`docker logs` に平文が残らない | `feed-admin-password.py` |
| 低いレベルの拒否 | `SECURITY_LEVEL` が 2 未満なら起動を拒否（`ALLOW_INSECURE_SECURITY_LEVEL=1` で明示的に解除） | `entrypoint.sh` |
| 入力検証 | `.env` の値は `mjs_def.sh`（シェルスクリプト）に書き込まれるため、ホスト名・名前・数値の形式を検査する | `entrypoint.sh` |
| ケーパビリティ削減 | `cap_drop: ALL` + 最小限の `cap_add`。`NET_RAW`（パケット取得）、`SETUID/SETGID`（UID 切り替え）、`NET_BIND_SERVICE` を落とす。`no-new-privileges` | compose |
| リソース上限 | `pids_limit`（既定 16384）と `mem_limit`（既定 無制限） | compose |
| 秘密ファイルの隔離 | `.dockerignore` でビルドコンテキストから除外。プロキシ証明書（秘密鍵を含む）はプロキシにだけ渡す | `.dockerignore`, compose |

**残る前提・制約**

- 投入ユーザーのタスクは root で動き、共有シークレット（`/run/secrets/mjs_shared_secret`）も読めます。
  したがって上記の署名・暗号化は **クラスタ外部の攻撃者** に対する防御であり、ログインできるユーザー同士の分離にはなりません。
- `ipc: host` のため、ホストの `/dev/shm` と SysV IPC はコンテナと共有されます。
- `network_mode: host` のため、ホストの localhost 限定サービスにもコンテナから到達できます。
  [5. ホストのファイアウォール](#5-ホストのファイアウォール) の設定を必ず行ってください。
- レベル 3 への移行、ホストネットワークの廃止、読み取り専用ルート FS は未対応です（実機での検証が必要なため）。

## 前提条件

- **DNS** — `FQDN` / `JM_HOST` に指定した名前が、head・compute の双方から解決できること。
  MJS はホスト名に敏感で、`mjs_def.sh` の `HOSTNAME` にこの値が書き込まれます。
- **ライセンス** — MathWorks アカウントによるオンラインライセンス。ネットワークライセンスマネージャは未対応です
  （使う場合は Dockerfile の `LICENSE_SERVER` / `MLM_LICENSE_FILE` のコメントを外す必要があります）。
- **LDAP** — authentik の LDAP アウトポストに **LDAPS（636 番）** で到達できること。
  アウトポストの証明書が私的 CA のものなら、その CA 証明書（PEM）を `head/certs/ldap-ca.pem` に置きます。
  `SECURITY_LEVEL=2`（認証あり）が既定です。
  ユーザー・グループ単位のアクセス制御は authentik の Application / Group binding 側で行う想定で、MJS 側では行っていません
  （MJS の `ALLOWED_USERS` は既定の `ALL` のままです）。**この LDAP プロバイダを他のアプリと共有すると、そのユーザー全員がクラスタを使えます。**
- **mjssetup** — 共有シークレット・証明書・クラスタプロファイルの生成に [mathworks/mjssetup](https://github.com/mathworks/mjssetup) を使います。MATLAB は不要です。
- **ホストの割り当て** — `network_mode: host` のため、**1 台のホストに head と compute を同居させることはできません**。
- **ポート** — MJS のポート範囲は `mjs_def.sh` の既定値（`BASE_PORT`=27350 以降。MPI は `BASE_PORT`+1000 以降）をそのまま使っています。
  ホストネットワークを使うので compose での公開設定はなく、**head ⇄ compute 間でこの範囲が、クライアント → head でプロキシの 1080 番が通る必要があります**。
  それ以外からの到達はホストのファイアウォールで遮断してください。
- **python3** — head ノードのイメージに `python3` が必要です（Dockerfile で追加済み。プリビルドイメージを使う場合は含まれているか確認してください）。

## 1. イメージのビルド

head / compute のどちらのディレクトリからでも同じイメージがビルドされます（`context: ..` で共通の Dockerfile を参照）。

```bash
cd alternates/building-on-matlab-docker-image/head
docker compose build
```

> **Warning**
> 既定の `ADDITIONAL_PRODUCTS` は約 120 製品のフルセットです。ビルドには非常に長い時間がかかり、
> イメージも数十 GB 規模になります。

必要な製品だけに絞る場合は `ADDITIONAL_PRODUCTS` を上書きしてください。

```bash
docker compose build \
  --build-arg MATLAB_RELEASE=R2026a \
  --build-arg ADDITIONAL_PRODUCTS="MATLAB_Parallel_Server Parallel_Computing_Toolbox Statistics_and_Machine_Learning_Toolbox"
```

ビルド済みイメージを使う場合は、各 compose ファイル 3 行目の `#image:` 行のコメントを外し、`build:` ブロックを削除します。

## 2. head ノードの起動

### 2-1. 手で用意するファイル

以下は `.gitignore` 対象でリポジトリには含まれていません。head ホスト上で作成してください。

| パス | 内容 |
| --- | --- |
| `head/secrets/mjs_shared_secret` | クラスタ全体の共有シークレット。通信の暗号化、特権コマンドの署名、クライアント証明書の検証に使う。**compute ノードにも同じファイルを配布する** |
| `head/certs/proxy-certificate.json` | `matlab-mjs-proxy` の mTLS 用証明書。**上の共有シークレットから** `mjssetup generate-certificate` で生成する。秘密鍵を含む |
| `head/secrets/mjs_admin_pass.txt` | `MJS_ADMIN_USER`（既定 `mjsadmin`）の LDAP パスワード。1 行のプレーンテキスト。末尾の改行は除去される |
| `head/certs/ldap-ca.pem`（任意） | LDAPS サーバ証明書を発行した CA の証明書（PEM）。公的 CA なら不要 |

```bash
cd alternates/building-on-matlab-docker-image/head
mkdir -p certs secrets
chmod 700 secrets

# 共有シークレット（クラスタで 1 回だけ作る）
mjssetup create-shared-secret -outfile secrets/mjs_shared_secret

# プロキシ証明書（同じシークレットから生成）
mjssetup generate-certificate -secretfile secrets/mjs_shared_secret -outfile certs/proxy-certificate.json

# 管理者パスワード（シェル履歴に残さないため read -s を使う）
read -rs -p 'mjsadmin password: ' p && printf '%s' "$p" > secrets/mjs_admin_pass.txt && unset p

# LDAPS の CA 証明書（私的 CA の場合）。authentik のアウトポストから取得する例:
echo | openssl s_client -connect ldap.example.internal:636 -showcerts 2>/dev/null \
  | awk '/BEGIN CERTIFICATE/,/END CERTIFICATE/' > certs/ldap-ca.pem

chmod 600 secrets/* certs/proxy-certificate.json
```

共有シークレットとプロキシ証明書は、クラスタに接続できる人を決める情報です。MathWorks の手順どおり、
安全に保管し、配布は安全な経路で行ってください。

### 2-2. `.env` の作成

`LDAP_HOST` だけは既定値がなく、**未設定だと compose が起動を拒否します**。

```bash
cat > .env <<'EOF2'
FQDN=head.example.internal
LDAP_HOST=ldap.example.internal
JM_NAME=MyMJS
SECURITY_LEVEL=2
EOF2
```

authentik 以外のディレクトリサービスを使う場合は `LDAP_PRINCIPAL_FORMAT` も上書きしてください
（既定は authentik の `cn=[username],ou=users,dc=ldap,dc=goauthentik,dc=io`。`[username]` が短いユーザー名に置換されます）。

LDAPS を使えない環境では `LDAP_SCHEME=ldap`、`LDAP_PORT=389` を設定します。この場合、全ユーザーのパスワードが
head と LDAP サーバの間を平文で流れます。起動時に警告が出ます。

### 2-3. 起動

```bash
docker compose up -d
docker compose logs -f matlab-head-node
```

`head/entrypoint.sh` が自動で以下を実行します。

1. `.env` 由来の値を検証し、`SECURITY_LEVEL` が 2 未満なら起動を拒否する
2. `readlink -f $(which matlab)` から MATLAB のインストール先を動的に取得する
3. `mjs_def.sh` 末尾の管理ブロック（`BEGIN/END managed by compose entrypoint`）を書き直す。
   `HOSTNAME`、`SECURITY_LEVEL`、LDAP 設定、`USE_SECURE_COMMUNICATION`、`ALL_SERVER_SOCKETS_IN_CLUSTER`、
   `REQUIRE_SCRIPT_VERIFICATION`、`REQUIRE_CLIENT_CERTIFICATE`、`SHARED_SECRET_FILE` を含む。再起動しても重複しない
4. `certs/ldap-ca.pem` があれば、MATLAB 同梱 JRE の `cacerts` に `keytool` で取り込む
5. `MJS_START_DELAY` 秒待った後、`feed-admin-password.py` 経由で `startjobmanager -name $JM_NAME -secretfile … -clean -v` を実行する
6. `mjs console -clean` を `exec` して PID 1 にする

`SECURITY_LEVEL` が 2 以上の場合、`startjobmanager` は管理者パスワードを **`/dev/tty` から対話入力で**要求し、
非対話で渡すオプションはありません。`feed-admin-password.py` は PTY を作ってプロンプトを待ち、
エコーを無効にしてから投入します。ログには `Enter the password …:` の行だけが残り、パスワードは残りません。

## 3. compute ノードの起動

各 compute ホストで実行します。**head のジョブマネージャが起動してから**行ってください。

```bash
cd alternates/building-on-matlab-docker-image/compute
mkdir -p secrets && chmod 700 secrets
# head/secrets/mjs_shared_secret と同一のファイルを安全な経路で配置する
scp head-host:/path/to/head/secrets/mjs_shared_secret secrets/mjs_shared_secret
chmod 600 secrets/mjs_shared_secret

cat > .env <<'EOF2'
FQDN=compute01.example.internal
JM_HOST=head.example.internal
JM_NAME=MyMJS
NUM_WORKERS=8
SECURITY_LEVEL=2
EOF2

docker compose up -d
```

> **Important**
> `SECURITY_LEVEL`、`JM_NAME`、共有シークレットは head ノードと必ず同じにしてください。
> 不一致だとワーカーがジョブマネージャに登録できません。

### NFS 共有を使う場合

`docker-compose-wNFS.yml` を指定します。`NFS_ADDR` と `NFS_EXPORT` には既定値がありません。

```bash
cat >> .env <<'EOF2'
NFS_ADDR=10.0.0.10
NFS_EXPORT=/export/matlab
NFS_MOUNT_PATH=/mnt/nfs
EOF2

docker compose -f docker-compose-wNFS.yml up -d
```

このファイルには AMD の AOCL BLAS を使う設定（`BLAS_VERSION=libaocl.so` / `LAPACK_VERSION=libaocl.so`）が
**リテラル値でハードコードされています**。環境変数では上書きできないため、Intel CPU などで使う場合は
該当行を直接削除・変更してください。

NFS の認証方式は既定で AUTH_SYS（クライアントが申告した UID をそのまま信用）です。コンテナ側は `SETUID` を落としているので
タスクが他の UID になりすますことはできませんが、サーバ側のエクスポートは `root_squash` と `secure`（いずれも既定値）を維持してください。
Kerberos が使える環境では `NFS_OPTS=rw,sec=krb5p` を推奨します。

なお head 側の compose には NFS マウントの定義がないため、この共有は compute 側にのみマウントされます。

## 4. 動作確認とクライアント接続

```bash
# head ノードでクラスタの状態を確認
docker exec matlab-head-node nodestatus

# ワーカーが登録されているか（compute ホスト側）
docker exec matlab-compute-node nodestatus -remotehost head.example.internal
```

クライアントは **証明書付きのクラスタプロファイル**で接続します（`REQUIRE_CLIENT_CERTIFICATE=true` のため必須）。
`mjssetup` でユーザーごとに証明書とプロファイルを作り、安全な経路で配布します。
手順は MathWorks の [Configure SOCKS5 Proxy for MATLAB Job Scheduler](https://www.mathworks.com/help/matlab-parallel-server/configure-socks5-proxy-for-matlab-job-scheduler.html) に従います。

```bash
cd alternates/building-on-matlab-docker-image/head
# ユーザー用の証明書（共有シークレットから生成）
mjssetup generate-certificate -secretfile secrets/mjs_shared_secret -outfile profileCert.json
# プロキシ経由のプロファイル。-host は「クラスタのホスト名?proxy=socks5s://プロキシのホスト名:ポート」
mjssetup create-profile -name MyMJS \
  -host 'head.example.internal?proxy=socks5s://head.example.internal:1080' \
  -certificate profileCert.json -outfile MyMJS.json
```

生成された `MyMJS.json` を MATLAB の Cluster Profile Manager からインポートし、接続時に LDAP のユーザー名とパスワードを入力します。
`parallel.cluster.Generic` は MJS 用ではないので使いません。

## 5. ホストのファイアウォール

ホストネットワークを使うため、MJS のポートはホストの全インタフェースで待ち受けます。
到達元を head ⇄ compute 間とクライアント → 1080 番に限定してください。nftables の例（head ホスト）:

```bash
# 変数は環境に合わせる。MJS は BASE_PORT から 7+2*nJ+4*nW 個、MPI は BASE_PORT+1000 以降を使う
CLUSTER_NET=10.0.0.0/24      # head / compute が属するネットワーク
CLIENT_NET=10.1.0.0/16       # MATLAB クライアント
nft add table inet mjs
nft add chain inet mjs input '{ type filter hook input priority 0; policy accept; }'
nft add rule inet mjs input ip saddr $CLUSTER_NET tcp dport 27350-27449 accept
nft add rule inet mjs input ip saddr $CLUSTER_NET tcp dport 28350-28449 accept
nft add rule inet mjs input ip saddr $CLIENT_NET  tcp dport 1080 accept
nft add rule inet mjs input tcp dport { 27350-27449, 28350-28449, 1080 } drop
```

compute ホストでは 1080 番の行を除き、同じ範囲を `CLUSTER_NET` からのみ許可します。
Docker はホストネットワークのコンテナに iptables ルールを追加しないため、上記はそのまま有効です。

## 環境変数リファレンス

すべて `.env` またはシェルの環境変数で上書きできます（ハードコード値を除く）。

### head（`head/docker-compose.yml`）

| 変数 | 既定値 | 説明 |
| --- | --- | --- |
| `FQDN` | `head.matlab.internal` | `mjs_def.sh` の `HOSTNAME` に書き込まれる |
| `JM_NAME` | `MyMJS` | ジョブマネージャ名。compute と一致必須 |
| `SECURITY_LEVEL` | `2` | MJS のセキュリティレベル。compute と一致必須。2 未満は起動拒否 |
| `ALLOW_INSECURE_SECURITY_LEVEL` | `0` | `1` で 2 未満の `SECURITY_LEVEL` を許可する |
| `LDAP_HOST` | **なし（必須）** | authentik LDAP アウトポストのホスト名。未設定だと compose がエラー終了する |
| `LDAP_SCHEME` | `ldaps` | `ldap` にすると平文。起動時に警告 |
| `LDAP_PORT` | `636` | |
| `LDAP_PRINCIPAL_FORMAT` | `cn=[username],ou=users,dc=ldap,dc=goauthentik,dc=io` | `[username]` が短いユーザー名に置換される（角括弧が正式なトークン） |
| `MJS_ADMIN_USER` | `mjsadmin` | MJS 管理者ユーザー（LDAP 上に存在すること） |
| `LDAP_SYNC_INTERVAL` | `1800` | LDAP 同期間隔（秒）。`0` は毎アクセス時に同期。短いほど無効化が早く反映される |
| `MJS_START_DELAY` | `10` | mjs サービス起動から `startjobmanager` までの待ち秒数 |
| `MJS_PROMPT_TIMEOUT` | `180` | パスワードプロンプトを待つ上限秒数 |
| `PIDS_LIMIT` | `16384` | コンテナのプロセス/スレッド数上限 |
| `MEM_LIMIT` | `0`（無制限） | コンテナのメモリ上限（例 `64g`） |
| `PROXY_PORT` | `1080` | `matlab-mjs-proxy` の待ち受けポート |

### compute（`compute/docker-compose.yml`、`compute/docker-compose-wNFS.yml` 共通）

| 変数 | 既定値 | 説明 |
| --- | --- | --- |
| `FQDN` | `compute.matlab.internal` | `mjs_def.sh` の `HOSTNAME` に書き込まれる |
| `JM_HOST` | `head.matlab.internal` | 接続先ジョブマネージャのホスト |
| `JM_NAME` | `MyMJS` | head と一致必須 |
| `NUM_WORKERS` | `4` | このホストで起動するワーカー数 |
| `SECURITY_LEVEL` | `2` | head と一致必須。2 未満は起動拒否 |
| `ALLOW_INSECURE_SECURITY_LEVEL` | `0` | `1` で 2 未満を許可する |
| `MJS_START_DELAY` | `10` | mjs サービス起動から `startworker` までの待ち秒数 |
| `PIDS_LIMIT` | `16384` | ワーカー数に応じて増やす |
| `MEM_LIMIT` | `0`（無制限） | |

### NFS（`compute/docker-compose-wNFS.yml` のみ）

| 変数 | 既定値 | 説明 |
| --- | --- | --- |
| `NFS_ADDR` | **なし（必須）** | NFS サーバーのアドレス |
| `NFS_EXPORT` | **なし（必須）** | エクスポートパス |
| `NFS_MOUNT_PATH` | `/mnt/nfs` | コンテナ内のマウント先 |
| `NFS_VERS` | `4.1` | NFS バージョン |
| `NFS_OPTS` | `rw` | 追加のマウントオプション（例 `rw,sec=krb5p`） |

`NFS_ADDR` / `NFS_EXPORT` は `${VAR}` 形式のため、未設定でも compose のパースは通り、
**実行時のマウントで失敗します**。設定漏れに注意してください。

### ハードコードされている値（環境変数では変更不可）

| 項目 | 値 | 場所 |
| --- | --- | --- |
| AOCL BLAS/LAPACK | `libaocl.so` | `compute/docker-compose-wNFS.yml` |
| プロキシイメージ | `ghcr.io/mathworks/parallel-server-proxy:v1.0.1` | `head/docker-compose.yml` |
| 残すケーパビリティ | `CHOWN DAC_OVERRIDE FOWNER FSETID KILL` | 各 compose の `cap_add` |
| 証明書・秘密ファイルのパス | `./certs/`, `./secrets/` | 各 compose の `secrets:` / `volumes:` |
| mjs_def.sh に書くセキュリティ設定 | `USE_SECURE_COMMUNICATION` ほか（上記 3.） | `entrypoint.sh` |

## 既知の問題・注意点

- **実機未検証の項目** — `cap_drop: ALL` で mjs / MATLAB ワーカーが問題なく動くか、プロキシの `read_only: true`、
  `mjssetup create-shared-secret` の出力を `SHARED_SECRET_FILE` にそのまま使えるか（MathWorks の SOCKS5 手順は
  クラスタ既存のシークレットを mjssetup に渡す方向の互換性を示している）は、実クラスタで確認してください。
  mjs が起動しない場合は `docker compose logs` で `EPERM` / `Operation not permitted` を探し、必要なケーパビリティだけ `cap_add` に足してください。
- **起動待ちが固定秒数** — head・compute とも、`mjs` サービスの準備完了を待たずに `MJS_START_DELAY` 秒（既定 10）待ってから
  ジョブマネージャ／ワーカーを起動しています。head が未起動のまま compute を上げると `startworker` は失敗しますが、
  `mjs console` が PID 1 として生き続けるためコンテナは `up` のまま残り、`restart: always` でも復旧しません。
  ワーカーが見えないときはまず `docker compose logs` を確認し、compute を `down` してから起動し直してください。
- **`-clean` でジョブが消える** — `startjobmanager -clean` / `mjs console -clean` は checkpoint とジョブ・タスクのデータを削除します。
  `restart: always` と組み合わさっているため、再起動のたびに全ジョブが消えます。残す場合は `-cleanPreserveJobs` に変更してください。
- **R2026b のオプション表記** — R2026b からコマンドのオプションは `--name` のような二重ダッシュ表記になりました
  （MathWorks ドキュメント: "Before R2026b: use a single dash"）。entrypoint は従来の単一ダッシュのままです。
  R2026b で受け付けられない場合は `entrypoint.sh` の `startjobmanager` / `startworker` の呼び出しを書き換えてください。
- **コンテナが root で動作** — Dockerfile の最後が `USER root` です（`mjs` の起動に必要）。
  upstream のイメージは `matlab` ユーザーで終わる点と異なります。[セキュリティ設計](#セキュリティ設計) を参照。
- **AOCL は AMD CPU 前提** — `docker-compose-wNFS.yml` の `BLAS_VERSION` / `LAPACK_VERSION` は AMD 向けです。
  スレッド数を固定する `OMP_NUM_THREADS` / `BLIS_NUM_THREADS` は現在コメントアウトされています
  （MJS ではワーカー 1 つあたり 1 スレッドにするのが一般的です）。
- **`ulimits` はコメントアウトのまま** — ファイルディスクリプタ上限などは必要に応じて有効化してください。
- **プリビルドイメージのバージョン差** — 各 compose にコメントアウトで残っている
  `ghcr.io/wryo813/matlab-parallel-server-full:r2025b` は、Dockerfile の既定 `MATLAB_RELEASE=R2026b` とずれています。
  また、このイメージには `python3` が入っていない可能性があります。
- **UID/GID を固定していない** — NFS 共有と LDAP ユーザーを併用する構成では、ファイル所有権がずれる可能性があります。
  レベル 2 では全タスクが root（NFS 上では `root_squash` により nobody）として書き込みます。

## upstream への追従

このフォークは upstream の更新を取り込み続ける方針です。そのため、
**upstream 由来のファイルは削除せず、独自の内容はできるだけ新規ファイルに置く**というルールで運用しています。

### 更新の取り込み

```bash
git remote add upstream https://github.com/mathworks-ref-arch/matlab-dockerfile
git fetch upstream
git merge upstream/main
```

コンフリクトが起きうるのは実質 `alternates/building-on-matlab-docker-image/Dockerfile` だけです
（`.gitignore` は追記のみ、compose・entrypoint・本ドキュメントはフォーク独自の新規ファイルなので衝突しません）。
Dockerfile は upstream の改善（対応リリースの追加など）を受け取りたいファイルなので、
別ファイルに分離せず直接編集を続け、衝突はその都度解消する方針です。

### GitHub Actions について

`.github/workflows/` には upstream の CI が入っており、フォークではライセンスや secrets がないため失敗します。
ただし**これらのファイルは削除しないでください**。削除すると upstream が CI を更新するたびに
modify/delete コンフリクトが発生します。

代わりに、リポジトリの **Settings → Actions → General → Disable actions** でワークフロー自体を無効化してください。
ファイルを一切変更せずに済み、追従コストが増えません。
