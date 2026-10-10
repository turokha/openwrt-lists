#!/bin/sh
set -eu

REPO='turokha/openwrt-lists'
BRANCH='main'
BASE_URL="https://raw.githubusercontent.com/$REPO/$BRANCH"
DIR='/etc/pbr'
DOMAIN_DEST="$DIR/vpn-domains.txt"
NETWORK_DEST="$DIR/vpn-networks.txt"
TARGET_INTERFACE='awg0'
TARGET_NFTSET_4="pbr_${TARGET_INTERFACE}_4_dst_ip_user"
PBR_LOG='/tmp/openwrt-lists-pbr.log'
MIN_PREFIX=12

DOMAIN_RAW="$(mktemp /tmp/openwrt-lists-domains.raw.XXXXXX)"
NETWORK_RAW="$(mktemp /tmp/openwrt-lists-networks.raw.XXXXXX)"
DOMAIN_NEW="$(mktemp /tmp/openwrt-lists-domains.new.XXXXXX)"
NETWORK_NEW="$(mktemp /tmp/openwrt-lists-networks.new.XXXXXX)"
DOMAIN_OLD="$(mktemp /tmp/openwrt-lists-domains.old.XXXXXX)"
NETWORK_OLD="$(mktemp /tmp/openwrt-lists-networks.old.XXXXXX)"

cleanup() {
    rm -f "$DOMAIN_RAW" "$NETWORK_RAW" "$DOMAIN_NEW" "$NETWORK_NEW" \
        "$DOMAIN_OLD" "$NETWORK_OLD"
}
trap cleanup EXIT INT TERM

log() {
    logger -t openwrt-lists "$*"
    echo "$*"
}

fetch() {
    url="$1"
    out="$2"
    curl -fsSL --proto '=https' --tlsv1.2 \
        --connect-timeout 15 --max-time 60 --retry 2 \
        "$url" -o "$out"
}

mkdir -p "$DIR"

fetch "$BASE_URL/vpn-domains.txt" "$DOMAIN_RAW" || {
    log 'ERROR: cannot download vpn-domains.txt; nothing changed'
    exit 1
}

fetch "$BASE_URL/vpn-networks.txt" "$NETWORK_RAW" || {
    log 'ERROR: cannot download vpn-networks.txt; nothing changed'
    exit 1
}

awk '
{
    gsub(/\r/, "")
    sub(/#.*/, "")
    gsub(/^[ \t]+|[ \t]+$/, "")
    if ($0 == "") next

    d=tolower($0)
    if (d !~ /^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$/ ||
        d !~ /\./ || d ~ /\.\./ || d ~ /^\./ || d ~ /\.$/) {
        print "Invalid domain: " $0 > "/dev/stderr"
        bad=1
        next
    }
    print d
}
END { if (bad) exit 1 }
' "$DOMAIN_RAW" | sort -u > "$DOMAIN_NEW" || {
    log 'ERROR: invalid domain list; nothing changed'
    exit 1
}

awk -v min_prefix="$MIN_PREFIX" '
{
    gsub(/\r/, "")
    sub(/#.*/, "")
    gsub(/^[ \t]+|[ \t]+$/, "")
    if ($0 == "") next

    value=$0
    n=split(value, p, "/")
    if (n == 1) {
        p[2]=32
        n=2
    }
    if (n != 2) {
        print "Invalid network: " value > "/dev/stderr"
        bad=1
        next
    }

    m=split(p[1], a, ".")
    if (m != 4) {
        print "Invalid IPv4 address: " value > "/dev/stderr"
        bad=1
        next
    }

    ok=1
    for (i=1; i<=4; i++) {
        if (a[i] !~ /^[0-9]+$/ || a[i] < 0 || a[i] > 255) ok=0
    }
    if (!ok || p[2] !~ /^[0-9]+$/ || p[2] < min_prefix || p[2] > 32) {
        print "Invalid/too-wide IPv4 network: " value > "/dev/stderr"
        bad=1
        next
    }

    if (a[1] == 0 || a[1] == 10 || a[1] == 127 || a[1] >= 224 ||
        (a[1] == 100 && a[2] >= 64 && a[2] <= 127) ||
        (a[1] == 169 && a[2] == 254) ||
        (a[1] == 172 && a[2] >= 16 && a[2] <= 31) ||
        (a[1] == 192 && a[2] == 168)) {
        print "Forbidden IPv4 network: " value > "/dev/stderr"
        bad=1
        next
    }

    printf "%d.%d.%d.%d/%d\n", a[1], a[2], a[3], a[4], p[2]
}
END { if (bad) exit 1 }
' "$NETWORK_RAW" | sort -u > "$NETWORK_NEW" || {
    log 'ERROR: invalid network list; nothing changed'
    exit 1
}

DOMAIN_COUNT="$(wc -l < "$DOMAIN_NEW" | tr -d ' ')"
NETWORK_COUNT="$(wc -l < "$NETWORK_NEW" | tr -d ' ')"

if [ "$DOMAIN_COUNT" -gt 5000 ]; then
    log "ERROR: domain count is unexpectedly high ($DOMAIN_COUNT); nothing changed"
    exit 1
fi

if [ "$NETWORK_COUNT" -gt 1000 ]; then
    log "ERROR: network count is unexpectedly high ($NETWORK_COUNT); nothing changed"
    exit 1
fi

if [ "${DRY_RUN:-0}" = '1' ]; then
    cp -f "$DOMAIN_NEW" /tmp/vpn-domains.candidate
    cp -f "$NETWORK_NEW" /tmp/vpn-networks.candidate
    log "DRY RUN OK ($DOMAIN_COUNT domains, $NETWORK_COUNT IPv4 networks)"
    exit 0
fi

DOMAIN_CHANGED=1
NETWORK_CHANGED=1
[ -f "$DOMAIN_DEST" ] && cmp -s "$DOMAIN_NEW" "$DOMAIN_DEST" && DOMAIN_CHANGED=0
[ -f "$NETWORK_DEST" ] && cmp -s "$NETWORK_NEW" "$NETWORK_DEST" && NETWORK_CHANGED=0

if [ "$DOMAIN_CHANGED" -eq 0 ] && [ "$NETWORK_CHANGED" -eq 0 ]; then
    log "No changes ($DOMAIN_COUNT domains, $NETWORK_COUNT IPv4 networks)"
    exit 0
fi

DOMAIN_HAD_OLD=0
NETWORK_HAD_OLD=0
if [ -f "$DOMAIN_DEST" ]; then
    cp -f "$DOMAIN_DEST" "$DOMAIN_OLD"
    DOMAIN_HAD_OLD=1
fi
if [ -f "$NETWORK_DEST" ]; then
    cp -f "$NETWORK_DEST" "$NETWORK_OLD"
    NETWORK_HAD_OLD=1
fi

cp -f "$DOMAIN_NEW" "$DOMAIN_DEST.new"
cp -f "$NETWORK_NEW" "$NETWORK_DEST.new"
chmod 0644 "$DOMAIN_DEST.new" "$NETWORK_DEST.new"
mv -f "$DOMAIN_DEST.new" "$DOMAIN_DEST"
mv -f "$NETWORK_DEST.new" "$NETWORK_DEST"

(/etc/init.d/pbr reload >"$PBR_LOG" 2>&1 || true)
sleep 2

VALID=1
/etc/init.d/pbr running >/dev/null 2>&1 || VALID=0
nft list set inet fw4 "$TARGET_NFTSET_4" >/dev/null 2>&1 || VALID=0
if [ "$DOMAIN_COUNT" -gt 0 ]; then
    grep -q "$TARGET_NFTSET_4" /var/run/pbr.dnsmasq 2>/dev/null || VALID=0
fi

if [ "$VALID" -eq 1 ]; then
    log "Updated successfully ($DOMAIN_COUNT domains, $NETWORK_COUNT IPv4 networks)"
    exit 0
fi

log 'ERROR: PBR validation failed; rolling back'

if [ "$DOMAIN_HAD_OLD" -eq 1 ]; then
    cp -f "$DOMAIN_OLD" "$DOMAIN_DEST"
else
    rm -f "$DOMAIN_DEST"
fi
if [ "$NETWORK_HAD_OLD" -eq 1 ]; then
    cp -f "$NETWORK_OLD" "$NETWORK_DEST"
else
    rm -f "$NETWORK_DEST"
fi

(/etc/init.d/pbr reload >/dev/null 2>&1 || true)
exit 1
