# Plain Kubernetes mail stack

`docker-mailserver`などのメールサーバ統合イメージを使わず、Debianから直接構築する構成です。

- Postfix Deployment: SMTP、submission、LDAP宛先検索、Rspamd milter
- Dovecot Deployment: IMAPS、LDAP bind認証、TCP LMTP/Maildir配送
- Rspamd + Redis: SPF/DKIM/DMARC、DNSBL、greylisting、スコア拒否
- OpenLDAP: メールユーザーとパスワードの一元管理
- Certbot: HTTP-01による初回証明書取得と自動更新

## 前提

固定グローバルIPv4、変更可能なPTR、受信/送信TCP 25、受信TCP 80/465/587/993、
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
```

`my-values.yaml`のドメイン、DN、固定IP、StorageClassを環境に合わせて変更します。この
リポジトリをclone済みなら、より本番向けの容量例を含む`examples/production-values.yaml`を
代わりにコピーできます。独自ビルドを使う場合だけ、`images.postfix.repository`などの
repositoryとtagを`my-values.yaml`で上書きしてください。

## 2. LDAP資格情報

```sh
kubectl create namespace mail
kubectl -n mail create secret generic mailserver-ldap-credentials \
  --from-literal=admin-password='長くランダムな管理パスワード' \
  --from-literal=bind-password='別の長くランダムな読み取り用パスワード'
```

Secret作成後に値を変えても、既存LDAP DBのroot/bindパスワードは自動変更されません。
ローテーションはLDAP上の`userPassword`とSecretを同時に更新してください。

## 3. DNSとインストール

certbot開始前にAレコードをLoadBalancerの固定IPへ向け、TCP 80を到達可能にします。

```dns
mail.example.com.    3600 IN A   203.0.113.10
example.com.         3600 IN MX  10 mail.example.com.
example.com.         3600 IN TXT "v=spf1 mx -all"
_dmarc.example.com.  3600 IN TXT "v=DMARC1; p=quarantine; rua=mailto:dmarc@example.com"
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
RWO PVCを使うDeploymentは`replicas: 1`かつ`strategy: Recreate`です。証明書PVCのみ
PostfixとDovecotが共有するため、ReadWriteMany対応StorageClassが必須です。

## 4. LDAPユーザー管理

```sh
chmod +x scripts/ldap-user.sh
NAMESPACE=mail RELEASE=mailserver ./scripts/ldap-user.sh
```

作成されるユーザーDNは`uid=alice@example.com,ou=users,dc=example,dc=com`です。
メールアドレス全体をIMAP/SMTPログイン名として使用します。削除や変更は`ldapmodify`、
`ldapdelete`をLDAP Pod内で管理DNにbindして実施できます。

```sh
LDAP_POD=$(kubectl -n mail get pod -l app.kubernetes.io/component=ldap -o jsonpath='{.items[0].metadata.name}')
kubectl -n mail exec "$LDAP_POD" -- ldapsearch -x \
  -H ldap://127.0.0.1 -D 'cn=admin,dc=example,dc=com' -W \
  -b 'ou=users,dc=example,dc=com' '(objectClass=inetOrgPerson)' mail
```

## 5. DKIM

初回起動時にRspamdがRSA-2048鍵を生成し、Rspamd PVCへ保存します。DNS値を確認します。

```sh
RSPAMD_POD=$(kubectl -n mail get pod -l app.kubernetes.io/component=rspamd -o jsonpath='{.items[0].metadata.name}')
kubectl -n mail exec "$RSPAMD_POD" -- \
  cat /var/lib/rspamd/dkim/example.com.mail.dns.txt
```

公開値を`mail._domainkey.example.com`のTXTとして公開します。`.key`は秘密鍵なので絶対に
公開せず、暗号化してバックアップしてください。受信側のDKIM/SPF/DMARC検証はRspamdの
標準モジュールで有効です。

## 接続設定

|用途|ポート|暗号化|認証|
|---|---:|---|---|
|サーバ間SMTP|25|opportunistic STARTTLS|なし|
|SMTP submission|465|implicit TLS|LDAP認証|
|SMTP submission|587|必須STARTTLS|LDAP認証|
|IMAP|993|implicit TLS|LDAP認証|

## 検証

```sh
openssl s_client -starttls smtp -connect mail.example.com:587 -servername mail.example.com
openssl s_client -connect mail.example.com:993 -servername mail.example.com
kubectl -n mail exec deploy/mailserver-postfix -c postfix -- postfix check
kubectl -n mail exec deploy/mailserver-dovecot -- doveconf -n
kubectl -n mail exec deploy/mailserver-rspamd -- rspamadm configtest
kubectl -n mail exec deploy/mailserver-postfix -c postfix -- postqueue -p
```

4つのメール系PVCとLDAP PVCを整合性のある時点でバックアップしてください。特にLDAP DB、
Maildir、Postfix queue、Certbotアカウント、DKIM秘密鍵を失うと復旧や配送に影響します。

## GitHub Actionsによる公開

`build-images.yaml`はPostfix、Dovecot、Rspamd、OpenLDAPをamd64/arm64向けにビルドします。
Pull Requestではビルド検証のみ、`main`へのpushと`v*`タグでは次の名前でGHCRへpushします。

```text
ghcr.io/<owner>/<repository>-postfix
ghcr.io/<owner>/<repository>-dovecot
ghcr.io/<owner>/<repository>-rspamd
ghcr.io/<owner>/<repository>-ldap
```

タグ`v0.2.0`では`0.2.0`、`0.2`、`sha-...`タグが生成されます。`latest`はmainだけです。

`publish-chart.yaml`は`v*`タグでChartをGitHub Pagesへ公開します。事前にGitHubの
Settings → Pages → Build and deployment → Sourceを「GitHub Actions」に設定してください。
組織ポリシーで制限されている場合は、イメージ公開用`GITHUB_TOKEN`にPackages writeを
許可します。Pages workflow自体はContents readのみです。リリース手順は次のとおりです。

```sh
# Chart.yamlのversionと、values.yamlの4イメージtagを同じ版へ更新する
helm lint .
git tag v0.2.0
git push origin v0.2.0
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
`Chart.yaml`のversionと4つの`images.*.tag`は一致している必要があります。同じversionが
既にタグに存在する場合は、手動実行で選択したHEADのChartがそのversionを上書きします。
