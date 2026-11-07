#!/bin/sh

set -eux

# Dockerコンテナのエントリポイントとして、root権限で起動されることを前提とする。
# ネットワークの許可リストを設定してからsleepし続ける。
# claude自体は`docker exec -u claude_user`で個別に起動する（sandbox.shが実行する）。


# 必須の環境変数が未設定ならエラー終了する
if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  echo "entrypoint.sh: CLAUDE_CODE_OAUTH_TOKEN is not set" >&2
  exit 1
fi


# 任意の環境変数の形式が不正ならエラー終了する。
# ALLOWED_DOCKER_DNS: 空白区切りのホスト名（英数字・ハイフン・ドットのみ。先頭は英数字）
if printf '%s\n' "${ALLOWED_DOCKER_DNS:-}" | grep -Eqv '^ *([A-Za-z0-9][A-Za-z0-9.-]*( +|$))*$'; then
  echo "entrypoint.sh: invalid ALLOWED_DOCKER_DNS (space-separated hosts): ${ALLOWED_DOCKER_DNS}" >&2
  exit 1
fi
# ALLOWED_ENDPOINTS: 空白区切りの`ホスト名:ポート`（ホスト名は英数字・ハイフン・ドットのみで先頭は英数字、ポートは数字5桁まで。ポートは省略できない）
if printf '%s\n' "${ALLOWED_ENDPOINTS:-}" | grep -Eqv '^ *([A-Za-z0-9][A-Za-z0-9.-]*:[0-9]{1,5}( +|$))*$'; then
  echo "entrypoint.sh: invalid ALLOWED_ENDPOINTS (space-separated host:port): ${ALLOWED_ENDPOINTS}" >&2
  exit 1
fi
# ホスト名の長さ（ipset名の上限31文字から、先頭の`ep-`の3文字を除いた28文字まで）とポートの範囲（1〜65535）
for endpoint in ${ALLOWED_ENDPOINTS:-}; do
  endpoint_host="${endpoint%%:*}"
  if [ "${#endpoint_host}" -gt 28 ]; then
    echo "entrypoint.sh: host too long (max 28 characters) in ALLOWED_ENDPOINTS: ${endpoint}" >&2
    exit 1
  fi
  if [ "${endpoint#*:}" -lt 1 ] || [ "${endpoint#*:}" -gt 65535 ]; then
    echo "entrypoint.sh: port out of range in ALLOWED_ENDPOINTS: ${endpoint}" >&2
    exit 1
  fi
done


# コンテナ内のdnsmasqをDNSとして使用するため、/etc/resolv.confを書き換える（Dockerが生成した/etc/resolv.confでは、nameserverはDocker組み込みDNS(127.0.0.11)となる）。
# /etc/resolv.confは参照するべきDNSが記載されるファイルで、コンテナ内のアプリが名前解決する際に参照する。
# dnsmasqは、dnsmasq.confで設定され、127.0.0.1:53でlistenする。
cat > /etc/resolv.conf <<'EOF'
nameserver 127.0.0.1
options ndots:0
EOF


# コンテナ外部IPに対するアクセス制御ルールを設定するためのipsetを作成。
# dnsmasqは解決した許可ドメインのIPをipsetに追加する。
#
# https用のipset
ipset create -exist allowed-https hash:ip timeout 900 maxelem 4096


# lo（コンテナのループバック用ネットワークインターフェース）に対する送受信を許可
# アプリ／dnsmasq間、dnsmasq／Docker組み込みDNS間の名前解決問い合わせパケットの送受信はここで許可される
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A INPUT -i lo -j ACCEPT

# パケットの属する通信のconntrackが通信確立済みと見なせる状態なら後続の送受信を許可
# カーネルはパケットの送受信の状況を追跡して通信状態をconntrackとして管理している。
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# dnsmasqからプロキシ先の外部DNSへのパケット送信を許可
# プロキシ先の外部DNS(1.1.1.1、8.8.8.8)はdnsmasq.confで設定される。
iptables -A OUTPUT -p udp --dport 53 -d 1.1.1.1 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -d 1.1.1.1 -j ACCEPT
iptables -A OUTPUT -p udp --dport 53 -d 8.8.8.8 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -d 8.8.8.8 -j ACCEPT

# 許可ドメインのIPに対するパケット送信を許可
#
# allowed-https: 443ポート向けのパケット送信
iptables -A OUTPUT -p tcp --dport 443 -m set --match-set allowed-https dst -j ACCEPT

# 環境変数から、追加で許可する接続先のdnsmasq設定とiptablesのルールを生成する。dnsmasq.confのconf-fileから読み込まれる。いずれも任意で、未設定なら何も追加されない。
# api.anthropic.com・claude.aiは、dnsmasq.confで常に許可している（443）。
# - ALLOWED_DOCKER_DNS（空白区切りのホスト名。例: postgres redis）: 指定ホストの名前解決を、Docker組み込みDNS(127.0.0.11)で行う。
#   compose内のコンテナなど、1.1.1.1・8.8.8.8では解決できない名前に指定する。名前解決だけで、接続は許可しない。
# - ALLOWED_ENDPOINTS（空白区切りの`ホスト名:ポート`。例: postgres:5432 redis:6379）: 接続を許可する接続先。
#   ホストごとにipset(ep-<ホスト名>。ドットは`_`に置換)を作り、指定ホスト（とそのサブドメイン）の解決済みIPを追加する。
#   そのipset宛ての指定ポート(TCP)向けのパケット送信を許可するルールも、ここで追加する。
: > /etc/dnsmasq-allowed-domains.conf
for docker_dns_host in ${ALLOWED_DOCKER_DNS:-}; do
  echo "server=/${docker_dns_host}/127.0.0.11" >> /etc/dnsmasq-allowed-domains.conf
done
# ホストごとに、ipsetを作り、解決済みIPをそのipsetへ追加するdnsmasq設定を生成する。
for endpoint_host in $(printf '%s\n' ${ALLOWED_ENDPOINTS:-} | cut -d: -f1 | sort -u); do
  endpoint_ipset="ep-$(printf '%s' "$endpoint_host" | tr . _)"
  ipset create -exist "$endpoint_ipset" hash:ip timeout 900 maxelem 16
  echo "ipset=/${endpoint_host}/${endpoint_ipset}" >> /etc/dnsmasq-allowed-domains.conf
done
# エントリごとに、そのホストのipset宛ての指定ポート(TCP)向けのパケット送信を許可する。
for endpoint in ${ALLOWED_ENDPOINTS:-}; do
  endpoint_host="${endpoint%%:*}"
  endpoint_port="${endpoint#*:}"
  iptables -A OUTPUT -p tcp --dport "$endpoint_port" -m set --match-set "ep-$(printf '%s' "$endpoint_host" | tr . _)" dst -j ACCEPT
done

# 上記ルールに該当しない送信はREJECTで即座に拒否
# TCPにはRSTを返す（--reject-with tcp-resetは-p tcpのみ指定可能）
iptables -A OUTPUT -p tcp -j REJECT --reject-with tcp-reset
# TCP以外（UDP等）にはICMP port unreachableを返す
iptables -A OUTPUT -j REJECT --reject-with icmp-port-unreachable

# 上記ルールに該当しない送受信は拒否
iptables -P OUTPUT DROP
iptables -P INPUT DROP
# パケット転送は全て拒否
iptables -P FORWARD DROP


# dnsmasq（dnsmasq.confで設定される）をバックグラウンドで起動する。
# iptablesの設定完了後に起動することで、OUTPUTがACCEPTのまま名前解決できる区間を作らない。
# -kはデーモン化させないオプション。dnsmasq自身のforkに任せず&でシェルの子プロセスとして扱う。
dnsmasq -k -C /etc/dnsmasq.conf &


# ネットワーク設定完了後はコンテナを起動状態に保ち、docker execでclaudeを起動できるようにする
exec sleep infinity
