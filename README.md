# npm-dashboard

A self-hosted traffic & analytics dashboard for **[Nginx Proxy Manager](https://nginxproxymanager.com/)**, built on **Grafana + Loki + Grafana Alloy**.

It tails NPM's per-proxy-host access logs, parses them, and gives you per-domain stats, request rates, status-code and HTTP-method breakdowns, top clients and paths, bandwidth, a bot-vs-human split, and a live log tail — all without touching your NPM install.

No Promtail (it's [EOL as of March 2026](https://grafana.com/docs/loki/latest/send-data/promtail/)); this uses its supported successor, **Grafana Alloy**.

![dashboard](docs/dashboard.png)

## Features

- **Per-domain statistics** — requests, error counts, and bytes for every proxied host
- **Throughput** — requests/sec over time, by status class and by domain
- **Breakdowns** — status codes, HTTP methods, top client IPs, top paths
- **Bandwidth** — egress bytes/sec and total
- **Bot vs Human** — classifies traffic by user-agent *and* request path (catches crawlers, AI scrapers, monitoring, and WebDAV/sync clients like Nextcloud)
- **Live access log** — searchable tail, filterable by domain
- **One template variable** to filter the whole board to one or more domains
- Everything runs in its own containers — your NPM stack is untouched (logs mounted read-only)

## How it works

```
NPM proxy-host-*_access.log ──(read-only)──> Alloy ──push──> Loki ──query──> Grafana
```

Alloy parses NPM's `proxy` log format and promotes `host`, `status`, `method`, and
`cache_status` to Loki labels; `client_ip`, `path`, and `bytes` are parsed at query
time to keep label cardinality low. The Loki datasource and dashboard are
auto-provisioned, so there's nothing to wire up by hand.

## Requirements

- A host running **Nginx Proxy Manager** (access logging is on by default)
- **Docker Engine** + the **`docker compose` v2** plugin
- ~200 MB RAM headroom for the three containers

## Quick start

```bash
git clone https://github.com/SyFry/npm-dashboard.git
cd npm-dashboard
./setup.sh
```

`setup.sh` autodetects your NPM log directory, generates a `.env` (with a random
Grafana admin password), pulls the images, and starts the stack. When it finishes
it prints the URL and login. Open `http://<host>:3000`, the dashboard is under
**NPM → "Nginx Proxy Manager — Traffic & Stats"**.

> By default Alloy ingests only **new** log lines from the moment it starts. To also
> load existing history, see [Backfilling](#backfilling-historical-logs).

## Configuration

All settings live in `.env` (created from [`.env.example`](.env.example)):

| Variable | Default | Purpose |
|---|---|---|
| `NPM_LOG_DIR` | autodetected | Absolute path to NPM's `data/logs` directory |
| `GRAFANA_PORT` | `3000` | Host port for the Grafana UI |
| `GRAFANA_ADMIN_USER` | `admin` | Grafana admin username |
| `GRAFANA_ADMIN_PASSWORD` | generated | Grafana admin password |
| `LOKI_VERSION` / `ALLOY_VERSION` / `GRAFANA_VERSION` | tested set | Image tags |

### Finding the NPM logs

`setup.sh` locates the access logs in this order, so it works even with unusual installs:

1. `--log-dir /path` flag, or `NPM_LOG_DIR` in your environment
2. A running NPM container's `/data` mount (read via `docker inspect`)
3. Common host paths (Docker, Synology `/volume1`, unRAID `/mnt/user/appdata`, named Docker volumes, …)
4. A filesystem search for `proxy-host-*_access.log`

If detection fails, point it at the directory that contains `proxy-host-*_access.log`:

```bash
./setup.sh --log-dir /your/path/to/nginx-proxy-manager/data/logs
```

### Securing Grafana

The Grafana port is published on all interfaces. On an internet-facing host you
should restrict it (firewall) or — fittingly — put it behind NPM itself as a proxy
host with an access list. Loki and Alloy are **not** exposed to the host; they're
reachable only on the internal compose network.

### Retention

Loki keeps 30 days by default. Change `retention_period` in
[`config/loki-config.yaml`](config/loki-config.yaml) and `docker compose restart loki`.

## Backfilling historical logs

Alloy ships with `tail_from_end = true` (new lines only). To load the logs already
on disk, either run:

```bash
./setup.sh --backfill
```

or do it manually — note that flipping the flag alone isn't enough, because Alloy
resumes from its saved file positions; you must clear them:

```bash
sed -i 's/tail_from_end = true/tail_from_end = false/' config/config.alloy
docker compose stop alloy && docker compose rm -f alloy
docker volume rm npm-dashboard_alloy-data      # clears saved positions only
docker compose up -d alloy
```

Loki is configured with `reject_old_samples: false`, so older timestamps are accepted.

## Using it with an existing Grafana

If you already run Grafana + Loki and just want the dashboard, import
[`dashboards/npm-traffic-stats.json`](dashboards/npm-traffic-stats.json)
(**Dashboards → New → Import**) and select your Loki datasource. You'll still need
Alloy (or your own shipper) feeding NPM logs into that Loki with the labels described
above; [`config/config.alloy`](config/config.alloy) is a drop-in.

## The dashboard

Stat row (total requests, avg req/s, error rate, egress, active domains, unique
clients) · requests/sec by status class · requests/sec by domain · status-code and
HTTP-method donuts · bot-vs-human donut · bandwidth · per-domain table · top client
IPs · top paths · live access log. A `$domain` multi-select filters everything.

## Customizing

- **Bot classification** — edit the two queries in the *Bot vs Human Traffic* panel.
  A request counts as automated if its user-agent matches the bot/tool/sync regex
  **or** its path is a sync/API endpoint (`/remote.php`, `/ocs/`, `/.well-known`, …).
- **Latency** — NPM doesn't log upstream response time by default. Add
  `$upstream_response_time` to NPM's `log-proxy.conf` and extend the Alloy regex to
  capture it for a latency panel.

## Troubleshooting

**No data on the dashboard.**
- Confirm the log filenames are `proxy-host-*_access.log` (hyphen). The Alloy glob
  matches exactly that; `_error.log`, `letsencrypt.log*`, and `fallback_*` are
  intentionally ignored.
- Check ingestion from inside the network (Loki/Alloy aren't published to the host):
  ```bash
  NET=$(docker network ls --format '{{.Name}}' | grep npm-dashboard)
  docker run --rm --network "$NET" curlimages/curl:latest \
    -sG 'http://loki:3100/loki/api/v1/label/host/values'
  ```
  Domains listed = data is flowing; empty = nothing ingested yet (try `--backfill`).
- Only seeing brand-new traffic? That's `tail_from_end`. Backfill as above.

**Rate panels show "No data" over very long ranges.** They use
`count_over_time(...)/interval` rather than `rate()`, which is robust to sparse data;
if a range still looks empty, narrow it (Last 6/24h) until more history accumulates.

**Can't reach `http://<host>:3000`** but `curl localhost:3000/api/health` returns 200:
- On a **multi-homed** host, browse the IP on your **default-route** interface, or
  return traffic leaves the wrong NIC and the page hangs.
- If your LAN is in `172.17.0.0/16`, Docker's default `docker0` bridge collides with
  it. Move Docker's pools via `/etc/docker/daemon.json` (`bip` + `default-address-pools`)
  and restart Docker.

**Cache Hit Ratio was removed / "No data" on caching panels** — NPM doesn't enable
proxy caching by default, so there's nothing to report unless you turn it on.

## Uninstall

```bash
./uninstall.sh            # stop, keep data
./uninstall.sh --purge    # stop and delete all stored data
```

## Credits & license

Built on [Grafana](https://github.com/grafana/grafana),
[Loki](https://github.com/grafana/loki), and
[Alloy](https://github.com/grafana/alloy). Dashboard and tooling are MIT-licensed —
see [LICENSE](LICENSE). Not affiliated with Nginx Proxy Manager or Grafana Labs.
