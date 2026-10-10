# openwrt-lists

User-maintained routing lists for OpenWrt PBR + AmneziaWG.

The repository is the source of truth. The router downloads the lists, validates them, normalizes them and only then reloads PBR.

## Files

- `vpn-domains.txt` — domains routed through `awg0`.
- `vpn-networks.txt` — IPv4 addresses/CIDR networks routed through `awg0`.
- `scripts/sync-vpn-lists.sh` — safe synchronizer for OpenWrt.
- `scripts/pbr.user.openwrt-lists` — PBR include that feeds domains to dnsmasq/nftset and networks directly to the PBR nft set.

## List format

Comments start with `#`. Empty lines are allowed.

Example domains:

```text
# Discord
discord.com
discord.gg
discordcdn.com
```

Example networks:

```text
# A single address
203.0.113.10

# A CIDR network
57.144.0.0/14
```

The synchronizer currently refuses IPv4 networks wider than `/12` and rejects private, loopback, link-local, multicast/reserved and default-route ranges.

## OpenWrt paths

The normalized working copies are stored as:

```text
/etc/pbr/vpn-domains.txt
/etc/pbr/vpn-networks.txt
```

The repository versions may contain comments; the router versions are normalized and deduplicated.

## Safety

The synchronizer:

1. downloads both lists over HTTPS;
2. validates every non-comment entry;
3. removes comments, blank lines and duplicates;
4. refuses unexpectedly large lists;
5. writes candidate files first;
6. atomically replaces the active files;
7. reloads PBR;
8. checks that PBR is running and the `awg0` nft set exists;
9. rolls back to the previous active files if validation after reload fails.

Use `DRY_RUN=1` to validate without changing PBR.
