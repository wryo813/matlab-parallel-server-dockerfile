#!/usr/bin/env bash
# CI 用のテスト LDAP サーバー (OpenLDAP slapd) を、このスクリプトを実行するホスト (GitHub のランナー) 上に用意する。
# head の compose の既定値 LDAP_PRINCIPAL_FORMAT=cn=[username],ou=users,dc=ldap,dc=goauthentik,dc=io に合わせて
# dc=ldap,dc=goauthentik,dc=io の下に ou=users と MJS 管理者ユーザーを作る。
#
# 使い方: sudo ./setup-test-ldap.sh <管理者ユーザー名> <管理者パスワード>
# Ubuntu (apt) 前提。ホストの 389/tcp で全インターフェースに待ち受ける (コンテナからは host.docker.internal で届く)。

set -euo pipefail

ADMIN_USER="${1:?usage: setup-test-ldap.sh <admin user> <admin password>}"
ADMIN_PASS="${2:?usage: setup-test-ldap.sh <admin user> <admin password>}"

LDAP_DOMAIN="ldap.goauthentik.io"
LDAP_BASE="dc=ldap,dc=goauthentik,dc=io"
# slapd 自体の管理者 (cn=admin) のパスワード。テスト用で外部には公開しない
ROOT_PASS="$(head -c 18 /dev/urandom | base64 | tr -d '/+=')"

export DEBIAN_FRONTEND=noninteractive
debconf-set-selections <<EOF
slapd slapd/no_configuration boolean false
slapd slapd/domain string ${LDAP_DOMAIN}
slapd shared/organization string mjs-ci
slapd slapd/password1 password ${ROOT_PASS}
slapd slapd/password2 password ${ROOT_PASS}
slapd slapd/purge_database boolean true
slapd slapd/move_old_database boolean true
EOF

apt-get update -qq
apt-get install -y -qq --no-install-recommends slapd ldap-utils > /dev/null

# パッケージの postinst は既存の設定を使い回すことがあるため、debconf の値で作り直して確実にこのドメインにする
dpkg-reconfigure -f noninteractive slapd > /dev/null 2>&1

# systemd が無い環境 (コンテナ内など) でも動くよう、サービスが動いていなければ直接起動する
if ! ldapsearch -x -H ldap://127.0.0.1 -b "${LDAP_BASE}" -s base dn > /dev/null 2>&1; then
    (systemctl restart slapd 2> /dev/null || service slapd restart 2> /dev/null || /usr/sbin/slapd -h "ldap:/// ldapi:///" -u openldap -g openldap) > /dev/null
fi

for _ in $(seq 1 30); do
    if ldapsearch -x -H ldap://127.0.0.1 -b "${LDAP_BASE}" -s base dn > /dev/null 2>&1; then
        break
    fi
    sleep 1
done

# debconf のパスワードは再設定時に使われないことがあるため、cn=admin のパスワードを ldapi (root の EXTERNAL 認証) で設定し直す
ldapmodify -Q -Y EXTERNAL -H ldapi:/// > /dev/null <<EOF
dn: olcDatabase={1}mdb,cn=config
changetype: modify
replace: olcRootPW
olcRootPW: $(slappasswd -s "${ROOT_PASS}")
EOF

# 再実行できるよう、前回作ったユーザーを消してから作り直す
ldapdelete -x -r -H ldap://127.0.0.1 -D "cn=admin,${LDAP_BASE}" -w "${ROOT_PASS}" "ou=users,${LDAP_BASE}" 2> /dev/null || true

ldapadd -x -H ldap://127.0.0.1 -D "cn=admin,${LDAP_BASE}" -w "${ROOT_PASS}" > /dev/null <<EOF
dn: ou=users,${LDAP_BASE}
objectClass: organizationalUnit
ou: users

dn: cn=${ADMIN_USER},ou=users,${LDAP_BASE}
objectClass: inetOrgPerson
cn: ${ADMIN_USER}
sn: ${ADMIN_USER}
uid: ${ADMIN_USER}
userPassword: ${ADMIN_PASS}
EOF

# 管理者ユーザーで bind できることを確認する (MJS と同じ DN 形式)
ldapwhoami -x -H ldap://127.0.0.1 -D "cn=${ADMIN_USER},ou=users,${LDAP_BASE}" -w "${ADMIN_PASS}"
echo "Test LDAP is ready: base=${LDAP_BASE}, user=cn=${ADMIN_USER},ou=users,${LDAP_BASE}"
