# MATLAB Parallel Server on Docker Compose（フォーク独自ドキュメント）

このリポジトリは [mathworks-ref-arch/matlab-dockerfile](https://github.com/mathworks-ref-arch/matlab-dockerfile) のフォークです。
upstream の内容はそのまま残したうえで、**MATLAB Parallel Server (MJS) のクラスタを Docker Compose で構築する**ための構成を追加しています。

このドキュメントはフォーク独自の追加部分のみを扱います。ベースイメージのビルド方法など upstream 共通の内容は、[ルートの README.md](README.md) および
[alternates/building-on-matlab-docker-image/README.md](alternates/building-on-matlab-docker-image/README.md) を参照してください。

## 目次

- [使用するファイル](#使用するファイル)
- [upstream からの変更点](#upstream-からの変更点)
- [構成](#構成)
- [前提条件](#前提条件)
- [1. イメージのビルド](#1-イメージのビルド)
- [2. head ノードの起動](#2-head-ノードの起動)
- [3. compute ノードの起動](#3-compute-ノードの起動)
- [4. 動作確認](#4-動作確認)
- [環境変数リファレンス](#環境変数リファレンス)
- [既知の問題・注意点](#既知の問題注意点)
- [upstream への追従](#upstream-への追従)

## 使用するファイル

このフォークで実際に使うのは `alternates/building-on-matlab-docker-image/` 配下だけです。

```
alternates/building-on-matlab-docker-image/
├── Dockerfile                        # head/compute 共通のイメージ定義
├── head/
│   └── docker-compose.yml            # head ノード（ジョブマネージャ）+ プロキシ
└── compute/
    ├── docker-compose.yml            # compute ノード（ワーカー）
    └── docker-compose-wNFS.yml       # compute ノード + NFS 共有マウント
```

リポジトリ内のそれ以外（`windows/`、`tests/`、`mpm-input-files/`、`alternates/` の他サブディレクトリ、
ルートの `Dockerfile` など）は **upstream 由来のもので、このフォークでは使用していません**。
upstream の更新をそのまま受け取るために意図的に残してあります（[upstream への追従](#upstream-への追従)参照）。

## upstream からの変更点

upstream との差分は以下の 5 ファイルのみです（このドキュメントとバナー行を除く）。

| ファイル | 種別 | 内容 |
| --- | --- | --- |
| `alternates/building-on-matlab-docker-image/Dockerfile` | upstream ファイルを改変 | 製品リストの大幅追加、parallel ツールボックスへの `PATH` 追加、`mjs_def.sh` のオンラインライセンス有効化、実行ユーザーを `root` に変更 |
| `alternates/building-on-matlab-docker-image/head/docker-compose.yml` | 新規 | head ノードとプロキシの定義 |
| `alternates/building-on-matlab-docker-image/compute/docker-compose.yml` | 新規 | compute ノードの定義 |
| `alternates/building-on-matlab-docker-image/compute/docker-compose-wNFS.yml` | 新規 | compute ノード + NFS 版 |
| `.gitignore` | upstream ファイルを改変 | `.env` / `certs/` / `secrets/` を追加 |

### Dockerfile の変更内容

- **製品リスト** — `ARG ADDITIONAL_PRODUCTS` に約 120 製品を指定。MJS に必須の `MATLAB_Parallel_Server` と
  `Parallel_Computing_Toolbox` を含みます。ファイル後半には support package や事前学習済みモデルの一覧が
  **コメントアウトされた状態**で列挙されており、必要なものだけ有効化して使う想定です。
- **PATH** — `ENV PATH="/opt/matlab/${MATLAB_RELEASE}/toolbox/parallel/bin:${PATH}"` を追加。
  これにより `mjs`、`startjobmanager`、`startworker`、`nodestatus`、`mjsadmin` が直接呼べます。
- **apt パッケージ** — `bzip2`、`xz-utils` を追加（大きな製品パッケージの展開に必要）。
- **ライセンス** — `mjs_def.sh` の `USE_ONLINE_LICENSING` を `"true"` に書き換え。
  MathWorks のオンラインライセンスを使う設定で、ネットワークライセンスマネージャ（`LICENSE_SERVER`）は
  upstream と同様コメントアウトのままです。
- **実行ユーザー** — `mjs` サービスの起動に必要なため、最終的に `USER root` としています。
  upstream のイメージは `matlab` ユーザーで終わるため、ここが挙動の違いになります。
- **WORKDIR** — `/home/matlab` をコメントアウトし `/tmp` に変更。

なお Dockerfile 末尾に `entrypoint.sh` を `COPY` / `ENTRYPOINT` する記述がありますが**すべてコメントアウト**されており、
`entrypoint.sh` というファイルもリポジトリに存在しません。起動処理は compose 側の `entrypoint:` に移動済みです。

## 構成

```
  ┌─ head ホスト ────────────────────────────────┐
  │  matlab-head-node                            │
  │    mjs console        （PID 1、常駐）        │
  │    startjobmanager    （起動 10 秒後に実行） │
  │                                              │
  │  matlab-mjs-proxy                            │
  │    ghcr.io/mathworks/parallel-server-proxy   │
  │    :1080 で待ち受け ← 外部の MATLAB クライアント
  └──────────────────────────────────────────────┘
                    ▲ ワーカー登録
  ┌─ compute ホスト（複数台）─────────────────────┐
  │  matlab-compute-node                         │
  │    mjs console        （PID 1、常駐）        │
  │    startworker -num N （起動 10 秒後に実行） │
  │    （wNFS 版のみ）NFS 共有を /mnt/nfs にマウント
  └──────────────────────────────────────────────┘
```

- head / compute とも同じ Dockerfile から作った 1 つのイメージを使い、compose の `entrypoint:` で役割を切り替えます。
- 両方とも `network_mode: host` / `ipc: host` です。MJS が動的なポート範囲を使うことと、
  ローカルの並列プールが共有メモリを使うことへの対応です。
- `matlab-mjs-proxy` は MathWorks 公式のプロキシコンテナで、クラスタ外の MATLAB クライアントが
  単一ポート経由で MJS に接続するためのものです。

## 前提条件

- **DNS** — `FQDN` / `JM_HOST` に指定した名前が、head・compute の双方から解決できること。
  MJS はホスト名に敏感で、`mjs_def.sh` の `HOSTNAME` にこの値が書き込まれます。
- **ライセンス** — MathWorks アカウントによるオンラインライセンス。ネットワークライセンスマネージャは未対応です
  （使う場合は Dockerfile の `LICENSE_SERVER` / `MLM_LICENSE_FILE` のコメントを外す必要があります）。
- **LDAP** — authentik の LDAP アウトポストに到達できること。`SECURITY_LEVEL=2`（認証あり）が既定です。
  ユーザー・グループ単位のアクセス制御は authentik の Application / Group binding 側で行う想定で、MJS 側では行っていません。
- **ホストの割り当て** — `network_mode: host` のため、**1 台のホストに head と compute を同居させることはできません**。
- **ポート** — MJS のポート範囲は `mjs_def.sh` の既定値（`BASE_PORT` 以降。通常 27350〜）をそのまま使っており、
  このフォークでは変更していません。ホストネットワークを使うので compose での公開設定はなく、
  head ⇄ compute 間でこの範囲とプロキシの 1080 番が通る必要があります。

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

以下の 2 つは `.gitignore` 対象でリポジトリには含まれていません。head ホスト上で作成してください。

| パス | 内容 |
| --- | --- |
| `head/certs/proxy-certificate.json` | `matlab-mjs-proxy` に渡す証明書。MathWorks が提供する手順で生成したものをそのまま配置します（compose は `-certificate` に渡すだけです） |
| `head/secrets/mjs_admin_pass.txt` | `MJS_ADMIN_USER`（既定 `mjsadmin`）の LDAP パスワード。1 行のプレーンテキスト。末尾の改行は除去されます |

```bash
cd alternates/building-on-matlab-docker-image/head
mkdir -p certs secrets
cp /path/to/proxy-certificate.json certs/
printf '%s' 'MJSADMIN_PASSWORD' > secrets/mjs_admin_pass.txt
chmod 600 secrets/mjs_admin_pass.txt
```

### 2-2. `.env` の作成

`LDAP_HOST` だけは既定値がなく、**未設定だと compose が起動を拒否します**。

```bash
cat > .env <<'EOF'
FQDN=head.example.internal
LDAP_HOST=ldap.example.internal
JM_NAME=MyMJS
SECURITY_LEVEL=2
EOF
```

authentik 以外のディレクトリサービスを使う場合は `LDAP_PRINCIPAL_FORMAT` も上書きしてください
（既定は authentik の `cn=[username],ou=users,dc=ldap,dc=goauthentik,dc=io`。`[username]` が短いユーザー名に置換されます）。

### 2-3. 起動

```bash
docker compose up -d
docker compose logs -f matlab-head-node
```

コンテナ起動時にエントリポイントが自動で以下を実行します。

1. `readlink -f $(which matlab)` から MATLAB のインストール先を動的に取得
2. `mjs_def.sh` の `HOSTNAME` を `FQDN` の値に書き換え
3. `mjs_def.sh` の末尾に LDAP 認証設定（`SECURITY_LEVEL` / `ADMIN_USER` / `USE_LDAP_SERVER_AUTHENTICATION` /
   `LDAP_URL` / `LDAP_SECURITY_PRINCIPAL_FORMAT` / `LDAP_SYNCHRONIZATION_INTERVAL_SECS`）を追記
4. バックグラウンドで 10 秒待機した後、`startjobmanager -name $JM_NAME -clean -v` を実行
5. `mjs console -clean` を `exec` して PID 1 にする

`SECURITY_LEVEL` が 2 以上の場合、`startjobmanager` は管理者パスワードを **stdin ではなく `/dev/tty` から**読もうとします。
そのため単純なパイプでは渡せず、`script(1)` で擬似端末を作ってパスワードを流し込んでいます。
ここを書き換えるときはこの制約に注意してください。

## 3. compute ノードの起動

各 compute ホストで実行します。**head のジョブマネージャが起動してから**行ってください。

```bash
cd alternates/building-on-matlab-docker-image/compute
cat > .env <<'EOF'
FQDN=compute01.example.internal
JM_HOST=head.example.internal
JM_NAME=MyMJS
NUM_WORKERS=8
SECURITY_LEVEL=2
EOF

docker compose up -d
```

> **Important**
> `SECURITY_LEVEL` と `JM_NAME` は head ノードと必ず同じ値にしてください。
> 不一致だとワーカーがジョブマネージャに登録できません。

### NFS 共有を使う場合

`docker-compose-wNFS.yml` を指定します。`NFS_ADDR` と `NFS_EXPORT` には既定値がありません。

```bash
cat >> .env <<'EOF'
NFS_ADDR=10.0.0.10
NFS_EXPORT=/export/matlab
NFS_MOUNT_PATH=/mnt/nfs
EOF

docker compose -f docker-compose-wNFS.yml up -d
```

このファイルには AMD の AOCL BLAS を使う設定（`BLAS_VERSION=libaocl.so` / `LAPACK_VERSION=libaocl.so`）が
**リテラル値でハードコードされています**。環境変数では上書きできないため、Intel CPU などで使う場合は
該当行を直接削除・変更してください。

なお head 側の compose には NFS マウントの定義がないため、この共有は compute 側にのみマウントされます。

## 4. 動作確認

```bash
# head ノードでクラスタの状態を確認
docker exec matlab-head-node nodestatus

# ワーカーが登録されているか（compute ホスト側）
docker exec matlab-compute-node nodestatus -remotehost head.example.internal
```

クライアント側の MATLAB からは、プロキシの待ち受けポート（既定 1080）に対して
`parallel.cluster.Generic` / MJS クラスタプロファイルを設定して接続します。

## 環境変数リファレンス

すべて `.env` またはシェルの環境変数で上書きできます（ハードコード値を除く）。

### head（`head/docker-compose.yml`）

| 変数 | 既定値 | 説明 |
| --- | --- | --- |
| `FQDN` | `head.matlab.internal` | `mjs_def.sh` の `HOSTNAME` に書き込まれる |
| `JM_NAME` | `MyMJS` | ジョブマネージャ名。compute と一致必須 |
| `SECURITY_LEVEL` | `2` | MJS のセキュリティレベル。compute と一致必須 |
| `LDAP_HOST` | **なし（必須）** | authentik LDAP アウトポストのホスト名。未設定だと compose がエラー終了する |
| `LDAP_PORT` | `389` | 平文 LDAP |
| `LDAP_PRINCIPAL_FORMAT` | `cn=[username],ou=users,dc=ldap,dc=goauthentik,dc=io` | `[username]` が短いユーザー名に置換される（角括弧が正式なトークン） |
| `MJS_ADMIN_USER` | `mjsadmin` | MJS 管理者ユーザー |
| `LDAP_SYNC_INTERVAL` | `1800` | LDAP 同期間隔（秒）。`0` は毎アクセス時に同期 |
| `PROXY_PORT` | `1080` | `matlab-mjs-proxy` の待ち受けポート |

### compute（`compute/docker-compose.yml`、`compute/docker-compose-wNFS.yml` 共通）

| 変数 | 既定値 | 説明 |
| --- | --- | --- |
| `FQDN` | `compute.matlab.internal` | `mjs_def.sh` の `HOSTNAME` に書き込まれる |
| `JM_HOST` | `head.matlab.internal` | 接続先ジョブマネージャのホスト |
| `JM_NAME` | `MyMJS` | head と一致必須 |
| `NUM_WORKERS` | `4` | このホストで起動するワーカー数 |
| `SECURITY_LEVEL` | `2` | head と一致必須 |

### NFS（`compute/docker-compose-wNFS.yml` のみ）

| 変数 | 既定値 | 説明 |
| --- | --- | --- |
| `NFS_ADDR` | **なし（必須）** | NFS サーバーのアドレス |
| `NFS_EXPORT` | **なし（必須）** | エクスポートパス |
| `NFS_MOUNT_PATH` | `/mnt/nfs` | コンテナ内のマウント先 |
| `NFS_VERS` | `4.1` | NFS バージョン |
| `NFS_OPTS` | `rw` | 追加のマウントオプション |

`NFS_ADDR` / `NFS_EXPORT` は `${VAR}` 形式のため、未設定でも compose のパースは通り、
**実行時のマウントで失敗します**。設定漏れに注意してください。

### ハードコードされている値（環境変数では変更不可）

| 項目 | 値 | 場所 |
| --- | --- | --- |
| AOCL BLAS/LAPACK | `libaocl.so` | `compute/docker-compose-wNFS.yml` |
| プロキシイメージ | `ghcr.io/mathworks/parallel-server-proxy:v1.0.1` | `head/docker-compose.yml` |
| 証明書のパス | `./certs/proxy-certificate.json` | `head/docker-compose.yml` の `secrets:` |
| パスワードのパス | `./secrets/mjs_admin_pass.txt` | `head/docker-compose.yml` の `secrets:` |

## 既知の問題・注意点

- **起動待ちが固定 10 秒** — head・compute とも、`mjs` サービスの準備完了を待たずに `sleep 10` してから
  ジョブマネージャ／ワーカーを起動しています。head が未起動のまま compute を上げると `startworker` は失敗しますが、
  `mjs console` が PID 1 として生き続けるためコンテナは `up` のまま残り、`restart: always` でも復旧しません。
  ワーカーが見えないときはまず `docker compose logs` を確認し、compute を `down` してから起動し直してください。
- **`mjs_def.sh` への設定は追記式** — LDAP 設定や `SECURITY_LEVEL` は毎回ファイル末尾に追記されます。
  同じコンテナを `docker compose restart` すると同じ行が重複して蓄積します。設定を変えるときは
  `docker compose down` でコンテナを破棄してから `up` し直すのが安全です。
- **コンテナが root で動作** — Dockerfile の最後が `USER root` です（`mjs` の起動に必要）。
  upstream のイメージは `matlab` ユーザーで終わる点と異なります。
- **AOCL は AMD CPU 前提** — `docker-compose-wNFS.yml` の `BLAS_VERSION` / `LAPACK_VERSION` は AMD 向けです。
  スレッド数を固定する `OMP_NUM_THREADS` / `BLIS_NUM_THREADS` は現在コメントアウトされています
  （MJS ではワーカー 1 つあたり 1 スレッドにするのが一般的です）。
- **`cap_add` / `ulimits` は無効** — 各 compose にある `SYS_NICE` とファイルディスクリプタ上限などの設定は
  コメントアウトされたままです。必要に応じて有効化してください。
- **プリビルドイメージのバージョン差** — 各 compose にコメントアウトで残っている
  `ghcr.io/wryo813/matlab-parallel-server-full:r2025b` は、Dockerfile の既定 `MATLAB_RELEASE=R2026a` とずれています。
- **LDAP は平文** — `ldap://` の 389 番を使っており、TLS（`ldaps://`）は未設定です。
- **UID/GID を固定していない** — NFS 共有と LDAP ユーザーを併用する構成では、ファイル所有権がずれる可能性があります。

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
（`.gitignore` は追記のみ、compose 3 本と本ドキュメントはフォーク独自の新規ファイルなので衝突しません）。
Dockerfile は upstream の改善（対応リリースの追加など）を受け取りたいファイルなので、
別ファイルに分離せず直接編集を続け、衝突はその都度解消する方針です。

### GitHub Actions について

`.github/workflows/` には upstream の CI が 6 本入っており、フォークではライセンスや secrets がないため失敗します。
ただし**これらのファイルは削除しないでください**。削除すると upstream が CI を更新するたびに
modify/delete コンフリクトが発生します。

代わりに、リポジトリの **Settings → Actions → General → Disable actions** でワークフロー自体を無効化してください。
ファイルを一切変更せずに済み、追従コストが増えません。
