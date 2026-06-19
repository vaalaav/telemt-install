#!/usr/bin/env bash
# telemt-vless-refresh — генератор xray-конфига из vless:// ссылки или 3x-ui подписки
# Часть проекта vaalaav/telemt-install
set -uo pipefail

LINK_FILE="/etc/telemt-vless/link.txt"
TYPE_FILE="/etc/telemt-vless/type.txt"
STRATEGY_FILE="/etc/telemt-vless/strategy.txt"
CONFIG_FILE="/etc/telemt-vless/config.json"
NODES_FILE="/etc/telemt-vless/nodes.txt"

[[ ! -f "$LINK_FILE" ]] && { echo "ERROR: $LINK_FILE не существует"; exit 1; }
[[ ! -f "$TYPE_FILE" ]] && echo "single" > "$TYPE_FILE"
LINK=$(cat "$LINK_FILE")
TYPE=$(cat "$TYPE_FILE")
STRATEGY=$(cat "$STRATEGY_FILE" 2>/dev/null || echo "leastPing")

LINK="$LINK" TYPE="$TYPE" STRATEGY="$STRATEGY" CONFIG_FILE="$CONFIG_FILE" NODES_FILE="$NODES_FILE" python3 << 'PYGEN'
import os, json, sys, urllib.request, urllib.parse as up, base64, ssl

link = os.environ["LINK"].strip()
typ = os.environ["TYPE"].strip()
strategy = os.environ["STRATEGY"].strip() or "leastPing"
cfg_path = os.environ["CONFIG_FILE"]
nodes_path = os.environ["NODES_FILE"]

def parse_vless(url):
    p = up.urlparse(url)
    q = {k: v[0] for k, v in up.parse_qs(p.query).items()}
    if not (p.username and p.hostname and p.port and "pbk" in q and "sni" in q):
        return None
    name = up.unquote(p.fragment) if p.fragment else f"{p.hostname}:{p.port}"
    return {
        "name": name,
        "host": p.hostname, "port": p.port or 443,
        "uuid": p.username,
        "flow": q.get("flow", ""),
        "network": q.get("type", "tcp"),
        "fp": q.get("fp", "chrome"),
        "sni": q.get("sni", ""),
        "pbk": q.get("pbk", ""),
        "sid": q.get("sid", ""),
        "spx": q.get("spx", "/"),
    }

nodes = []
if typ == "subscription":
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    try:
        req = urllib.request.Request(link, headers={"User-Agent": "v2rayN/6.0"})
        with urllib.request.urlopen(req, context=ctx, timeout=20) as r:
            data = r.read().decode("utf-8", errors="ignore").strip()
    except Exception as e:
        print(f"ERROR: подписка недоступна: {e}", file=sys.stderr)
        sys.exit(2)
    decoded = data
    try:
        pad = "=" * (-len(data) % 4)
        decoded = base64.b64decode(data + pad).decode("utf-8", errors="ignore")
    except Exception:
        pass
    for ln in decoded.split("\n"):
        ln = ln.strip()
        if not ln.startswith("vless://") or "security=reality" not in ln:
            continue
        n = parse_vless(ln)
        if n:
            nodes.append(n)
    if not nodes:
        print("ERROR: VLESS Reality узлы не найдены", file=sys.stderr)
        sys.exit(3)
else:
    n = parse_vless(link)
    if not n:
        print("ERROR: не удалось распарсить ссылку", file=sys.stderr)
        sys.exit(4)
    nodes.append(n)

def make_outbound(idx, n):
    out = {
        "tag": f"node-{idx}",
        "protocol": "vless",
        "settings": {
            "vnext": [{
                "address": n["host"], "port": n["port"],
                "users": [{"id": n["uuid"], "encryption": "none"}]
            }]
        },
        "streamSettings": {
            "network": n["network"],
            "security": "reality",
            "realitySettings": {
                "show": False,
                "fingerprint": n["fp"] or "chrome",
                "serverName": n["sni"],
                "publicKey": n["pbk"],
                "shortId": n["sid"],
                "spiderX": n["spx"]
            }
        }
    }
    if n["flow"]:
        out["settings"]["vnext"][0]["users"][0]["flow"] = n["flow"]
    return out

cfg = {
    "log": {"loglevel": "warning"},
    "inbounds": [{
        "tag": "socks-in",
        "listen": "127.0.0.1",
        "port": 40000,
        "protocol": "socks",
        "settings": {"auth": "noauth", "udp": True, "ip": "127.0.0.1"},
        "sniffing": {"enabled": False}
    }],
    "outbounds": [make_outbound(i+1, n) for i, n in enumerate(nodes)] + [{"tag": "direct", "protocol": "freedom"}],
    "routing": {"domainStrategy": "AsIs", "rules": []}
}

if len(nodes) > 1:
    cfg["routing"]["balancers"] = [{
        "tag": "balancer-vless",
        "selector": ["node-"],
        "strategy": {"type": strategy}
    }]
    cfg["routing"]["rules"].append({
        "type": "field", "inboundTag": ["socks-in"], "balancerTag": "balancer-vless"
    })
    if strategy == "leastPing":
        cfg["observatory"] = {
            "subjectSelector": ["node-"],
            "probeUrl": "https://www.google.com/gen_204",
            "probeInterval": "300s"
        }
else:
    cfg["routing"]["rules"].append({
        "type": "field", "inboundTag": ["socks-in"], "outboundTag": "node-1"
    })

with open(cfg_path, "w") as f:
    json.dump(cfg, f, indent=2)
with open(nodes_path, "w") as f:
    for n in nodes:
        f.write(f"{n['name']}\t{n['host']}:{n['port']}\n")

if len(nodes) > 1:
    print(f"OK: {len(nodes)} узлов, стратегия={strategy}", file=sys.stderr)
else:
    print(f"OK: 1 узел (балансировка не активна)", file=sys.stderr)
PYGEN
GEN_RC=$?
[[ $GEN_RC -ne 0 ]] && exit $GEN_RC

# Применяем права
if ! id xray &>/dev/null; then
    useradd --system --shell /usr/sbin/nologin --no-create-home --user-group xray 2>/dev/null \
    || useradd --system --shell /usr/sbin/nologin --no-create-home xray 2>/dev/null || true
fi
chown -R xray:xray /etc/telemt-vless 2>/dev/null || chown -R root:root /etc/telemt-vless
chmod 750 /etc/telemt-vless
chmod 640 "$CONFIG_FILE" "$LINK_FILE" 2>/dev/null || true
chmod 644 "$TYPE_FILE" "$STRATEGY_FILE" "$NODES_FILE" 2>/dev/null || true

# Валидация
if [[ -x /usr/local/bin/xray ]]; then
    if ! /usr/local/bin/xray -test -config "$CONFIG_FILE" 2>&1 | grep -q "Configuration OK"; then
        echo "WARN: xray -test не прошёл"
    fi
fi

# Рестарт сервиса если активен
if systemctl is-active --quiet telemt-vless 2>/dev/null; then
    systemctl restart telemt-vless
fi

echo "OK: конфиг обновлён" >&2
exit 0
