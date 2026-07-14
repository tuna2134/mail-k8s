# Kubernetes mail + SOGo groupware stack

`docker-mailserver`などのメールサーバ統合イメージを使わず、Debianから直接構築する構成です。

- Postfix Deployment: SMTP、submission、LDAP宛先検索、Rspamd milter
- Dovecot Deployment: IMAPS、LDAP bind認証、TCP LMTP/Maildir配送
- Rspamd + Redis: SPF/DKIM/DMARC、DNSBL、greylisting、スコア拒否
- OpenLDAP: メールユーザーとパスワードの一元管理
- Certbot: HTTP-01による初回証明書取得と自動更新
- SOGo + PostgreSQL: HTTPS Webメール、カレンダー、CalDAV、CardDAV、共有アドレス帳

## 前提

固定グローバルIPv4、変更可能なPTR、受信/送信TCP 25、受信TCP 80/443/465/587/993、
信頼できるクラスタDNS、StorageClassが必要です。HTTP Ingressは使用しません。

## 1. Helmリポジトリと設定ファイルを準備

```sh
helm repo add mailserver https://tuna2134.dev/mail-k8s
helm repo update
helm search repo mailserver/mailserver --versions
helm show values mailserver/mailserver > my-values.yaml
```

`https://tuna2134.dev/mail-k8s/`をブラウザで開くと404になりますが、静的なトップページを
置いていないためです。Helmが利用する`index.yaml`とChart packageは同じURL以下で公開されて
いるため、`helm repo add`には上記URLをそのまま指定します。

Chartは次の公開イメージを既定で使用するため、通常のセットアップではイメージのbuildやpushは
不要です。

```text
ghcr.io/tuna2134/mail-k8s-postfix
ghcr.io/tuna2134/mail-k8s-dovecot
ghcr.io/tuna2134/mail-k8s-rspamd
ghcr.io/tuna2134/mail-k8s-ldap
ghcr.io/tuna2134/mail-k8s-sogo
```

SOGoイメージは公式の署名付きpublic nightly Debian repositoryから構築します。production package
repositoryはAlintoのサポート契約が必要なためです。upstream repositoryの制約によりSOGoイメージ
だけは現在`linux/amd64`です。他のプロジェクトイメージはamd64/arm64に対応します。

`my-values.yaml`のドメイン、DN、固定IP、StorageClassを環境に合わせて変更します。この
リポジトリをclone済みなら、より本番向けの容量例を含む`examples/production-values.yaml`を
代わりにコピーできます。独自ビルドを使う場合だけ、`images.postfix.repository`などの
repositoryとtagを`my-values.yaml`で上書きしてください。

受信するドメインは`mail.domains`へ列挙します。先頭要素はPostfixのprimary domainにもなります。

```yaml
mail:
  hostname: mail.example.com
  domains:
    - example.com
    - example.net
  postmaster: postmaster@example.com
```

## 2. LDAP資格情報

```sh
kubectl create namespace mail
kubectl -n mail create secret generic mailserver-ldap-credentials \
  --from-literal=admin-password='長くランダムな管理パスワード' \
  --from-literal=bind-password='別の長くランダムな読み取り用パスワード'

kubectl -n mail create secret generic mailserver-sogo-credentials \
  --from-literal=postgres-password='長くランダムなDBパスワード'
```

Secret作成後に値を変えても、既存LDAP DBのroot/bindパスワードは自動変更されません。
ローテーションはLDAP上の`userPassword`とSecretを同時に更新してください。

## 3. DNSとインストール

certbot開始前にメールサーバのAレコードをLoadBalancerの固定IPへ向け、TCP 80を到達可能に
します。MX、SPF、DMARCは`mail.domains`の全ドメインに設定します。

```dns
mail.example.com.    3600 IN A   203.0.113.10
example.com.         3600 IN MX  10 mail.example.com.
example.com.         3600 IN TXT "v=spf1 mx -all"
_dmarc.example.com.  3600 IN TXT "v=DMARC1; p=quarantine; rua=mailto:dmarc@example.com"
example.net.         3600 IN MX  10 mail.example.com.
example.net.         3600 IN TXT "v=spf1 mx -all"
_dmarc.example.net.  3600 IN TXT "v=DMARC1; p=quarantine; rua=mailto:dmarc@example.net"
```

IP提供者側でPTRを`mail.example.com`に設定します。

```sh
helm upgrade --install mailserver mailserver/mailserver \
  --namespace mail \
  --values my-values.yaml
kubectl -n mail logs deploy/mailserver-postfix -c obtain-certificate -f
```

HTTP-01成功後にPostfix/Dovecotが起動します。更新は12時間ごとに確認され、証明書変更を
メールコンテナが検出すると両サービスをreloadします。まず`certbot.staging: true`で
疎通確認し、本番へ切り替える場合は証明書PVC内のstaging証明書を整理して再取得します。

全コンポーネントは独立Deploymentです。PostfixからDovecotへの配送はTCP LMTP 24、
SMTP AUTHはDovecot TCP 12345、Rspamdはmilter TCP 11332です。外部接続はHAProxy
DeploymentがPROXY protocol v2付きで各バックエンドへ中継し、元クライアントIPを維持します。
RWO PVCを使うDeploymentは`replicas: 1`かつ`strategy: Recreate`です。証明書PVCは
Postfix、Dovecot、SOGoが共有するため、ReadWriteMany対応StorageClassが必須です。

SOGoは既存OpenLDAPで認証し、専用の内部IMAP 1143、ManageSieve 4190、認証付きSMTP 2587を
使います。これらはNetworkPolicyでSOGo Podからだけ接続可能です。予定、連絡先、設定は専用の
PostgreSQL PVCに保存され、短期キャッシュには同一Podのmemcachedを使います。Web UIは既存
メールホスト名の証明書を使い、次で開けます。

```text
https://mail.example.com/SOGo
```

## 4. LDAPユーザー管理

```sh
chmod +x scripts/ldap-user.sh
NAMESPACE=mail RELEASE=mailserver ./scripts/ldap-user.sh
```

作成されるユーザーDNは`uid=alice@example.com,ou=users,dc=example,dc=com`です。
LDAPの`mail`が主アドレス、複数値の`mail-alias`が別名です。作成時の`Aliases`へカンマ区切りで
`info@example.com,alice@example.net`のように指定できます。主アドレスと全aliasは同じLDAP
`homeDirectory`を使用するため、どのアドレスで受信・IMAPログインしても同じMaildirになります。
aliasのドメインは`mail.domains`に含め、主アドレスとaliasはLDAP全体で重複させないでください。
ユーザー作成スクリプトは登録前に重複を検査します。

作成時の`Forward address`も任意です。空のままならローカルMaildirへ配送し、値を指定すると
補助objectClass `mailForwardingUser`と`mail-forward`属性が追加され、Postfixがその宛先へ
転送します。alias宛メールも主アドレスへ正規化された後、主アドレスの転送設定が適用されます。

既存ユーザーへaliasを追加する例です。

```sh
LDAP_POD=$(kubectl -n mail get pod -l app.kubernetes.io/component=ldap -o jsonpath='{.items[0].metadata.name}')
kubectl -n mail exec -i "$LDAP_POD" -- bash -c \
  'ldapmodify -x -H ldap://127.0.0.1 -D "$LDAP_ADMIN_DN" -w "$LDAP_ADMIN_PASSWORD"' <<'LDIF'
dn: uid=alice@example.com,ou=users,dc=example,dc=com
changetype: modify
add: objectClass
objectClass: mailAliasUser
-
add: mail-alias
mail-alias: info@example.com
mail-alias: alice@example.net
LDIF
```

追加済みユーザーへさらにaliasを足す場合は、`objectClass`を再追加せず`add: mail-alias`だけを
実行します。aliasをすべて削除するときは`mail-alias`と`mailAliasUser`を同じmodifyで削除します。

既存ユーザーに転送を追加する例です。`mail-forward`は複数値を持てるため、同じ属性行を追加すれば
複数宛先へ転送できます。設定中はローカルMaildir配送を転送先への配送で置き換えます。

```sh
LDAP_POD=$(kubectl -n mail get pod -l app.kubernetes.io/component=ldap -o jsonpath='{.items[0].metadata.name}')
kubectl -n mail exec -i "$LDAP_POD" -- bash -c \
  'ldapmodify -x -H ldap://127.0.0.1 -D "$LDAP_ADMIN_DN" -w "$LDAP_ADMIN_PASSWORD"' <<'LDIF'
dn: uid=alice@example.com,ou=users,dc=example,dc=com
changetype: modify
add: objectClass
objectClass: mailForwardingUser
-
add: mail-forward
mail-forward: alice@forward.example
LDIF
```

転送を解除してローカル配送へ戻す例です。LDAPの検索結果は配送ごとに参照されるため、Postfixの
再起動は不要です。

```sh
kubectl -n mail exec -i "$LDAP_POD" -- bash -c \
  'ldapmodify -x -H ldap://127.0.0.1 -D "$LDAP_ADMIN_DN" -w "$LDAP_ADMIN_PASSWORD"' <<'LDIF'
dn: uid=alice@example.com,ou=users,dc=example,dc=com
changetype: modify
delete: mail-forward
-
delete: objectClass
objectClass: mailForwardingUser
LDIF
```

その他の削除や変更も`ldapmodify`、`ldapdelete`をLDAP Pod内で管理DNにbindして実施できます。

```sh
LDAP_POD=$(kubectl -n mail get pod -l app.kubernetes.io/component=ldap -o jsonpath='{.items[0].metadata.name}')
kubectl -n mail exec "$LDAP_POD" -- ldapsearch -x \
  -H ldap://127.0.0.1 -D 'cn=admin,dc=example,dc=com' -W \
  -b 'ou=users,dc=example,dc=com' '(objectClass=inetOrgPerson)' mail mail-alias mail-forward homeDirectory
```

## 5. DKIM

初回起動時にRspamdが`mail.domains`のドメインごとにRSA-2048鍵を生成し、Rspamd PVCへ保存します。
各ドメインのDNS値を確認します。

```sh
RSPAMD_POD=$(kubectl -n mail get pod -l app.kubernetes.io/component=rspamd -o jsonpath='{.items[0].metadata.name}')
for DOMAIN in example.com example.net; do
  echo "=== $DOMAIN ==="
  kubectl -n mail exec "$RSPAMD_POD" -- \
    cat "/var/lib/rspamd/dkim/${DOMAIN}.mail.dns.txt"
done
```

それぞれを`mail._domainkey.<domain>`のTXTとして公開します。`.key`は秘密鍵なので絶対に
公開せず、暗号化してバックアップしてください。RspamdはFromヘッダーのドメインに対応する鍵で
署名します。受信側のDKIM/SPF/DMARC検証はRspamdの標準モジュールで有効です。

## 接続設定

|用途|ポート|暗号化|認証|
|---|---:|---|---|
|サーバ間SMTP|25|opportunistic STARTTLS|なし|
|SMTP submission|465|implicit TLS|LDAP認証|
|SMTP submission|587|必須STARTTLS|LDAP認証|
|IMAP|993|implicit TLS|LDAP認証|
|SOGo Web/CalDAV/CardDAV|443|TLS|LDAP認証|

## 検証

```sh
openssl s_client -starttls smtp -connect mail.example.com:587 -servername mail.example.com
openssl s_client -connect mail.example.com:993 -servername mail.example.com
kubectl -n mail exec deploy/mailserver-postfix -c postfix -- postfix check
kubectl -n mail exec deploy/mailserver-dovecot -- doveconf -n
kubectl -n mail exec deploy/mailserver-rspamd -- rspamadm configtest
kubectl -n mail exec deploy/mailserver-postfix -c postfix -- postqueue -p
kubectl -n mail exec deploy/mailserver-sogo -c sogo -- curl -fsS http://127.0.0.1:20000/SOGo
curl -fsS https://mail.example.com/SOGo >/dev/null
```

メール系PVC、LDAP PVC、SOGo PostgreSQL PVCを整合性のある時点でバックアップしてください。
特にLDAP DB、Maildir、SOGo DB、Postfix queue、Certbotアカウント、DKIM秘密鍵を失うと復旧や
配送に影響します。

SOGoを新しい版へ上げる前にDBをバックアップし、イメージ内`/usr/share/doc/sogo/`のupgrade
scriptと[公式upgrade手順](https://www.sogo.nu/files/docs/SOGoInstallationGuide.html#_upgrading)を
確認してください。SOGo packageはDB schemaを自動upgradeしません。

## GitHub Actionsによる公開

`build-images.yaml`はPostfix、Dovecot、Rspamd、OpenLDAPをamd64/arm64向け、SOGoをamd64向けに
ビルドします。
Pull Requestではビルド検証のみ、`main`へのpushと`v*`タグでは次の名前でGHCRへpushします。

```text
ghcr.io/<owner>/<repository>-postfix
ghcr.io/<owner>/<repository>-dovecot
ghcr.io/<owner>/<repository>-rspamd
ghcr.io/<owner>/<repository>-ldap
ghcr.io/<owner>/<repository>-sogo
```

タグ`v0.5.0`では`0.5.0`、`0.5`、`sha-...`タグが生成されます。`latest`はmainだけです。

`publish-chart.yaml`は`v*`タグでChartをGitHub Pagesへ公開します。事前にGitHubの
Settings → Pages → Build and deployment → Sourceを「GitHub Actions」に設定してください。
組織ポリシーで制限されている場合は、イメージ公開用`GITHUB_TOKEN`にPackages writeを
許可します。Pages workflow自体はContents readのみです。リリース手順は次のとおりです。

```sh
# Chart.yamlのversionと、values.yamlの5つのプロジェクトイメージtagを同じ版へ更新する
helm lint .
git tag v0.5.0
git push origin v0.5.0
```

タグとChart versionが一致しない場合、公開workflowは失敗します。公開後は次のように利用できます。

```sh
helm repo add mailserver https://tuna2134.dev/mail-k8s
helm repo update
helm install mailserver mailserver/mailserver -n mail --create-namespace -f my-values.yaml
```

Pages workflowはGitHub公式の`pages/static.yml`と同じ単一deploy job・Pages artifact方式です。
書き込み可能な`gh-pages`ブランチは使用しません。実行のたびに全`v*`タグをcheckoutして
過去を含む`.tgz`と`index.yaml`を再生成します。Chartは`values.yaml`に記載した
`ghcr.io/tuna2134/mail-k8s-*`の既定値を変更せずにpackageします。

Actions画面の「Deploy Helm repository to Pages」から「Run workflow」を選ぶと、選択した
ブランチのHEADもタグ済みChart群へ追加して即時デプロイします。未タグ版を手動公開する場合も、
`Chart.yaml`のversionと5つのプロジェクト`images.*.tag`は一致している必要があります。同じversionが
既にタグに存在する場合は、手動実行で選択したHEADのChartがそのversionを上書きします。
