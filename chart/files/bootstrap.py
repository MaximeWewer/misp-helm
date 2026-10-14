#!/usr/bin/env python3
"""Reconcile declarative MISP configuration through the REST API.

Reads a JSON config (BOOTSTRAP_CONFIG, default /config/config.json) rendered by
the chart from `bootstrap.*` and applies it idempotently: only differences are
written, so re-running the Job is safe.

Env:
  MISP_URL           base URL of misp-core (in-cluster Service)
  MISP_KEY           admin API key (chart Secret, key admin-key)
  MISP_VERIFY_TLS    "true" to verify the certificate (default false: self-signed core)
  WAIT_TIMEOUT       seconds to wait for MISP to answer (default 1800)
  DRY_RUN            "true" = GETs only, log the writes that would happen
  MODE               "sync" (default) or "fetch" (fetch + cache feeds only, for the CronJob)

Stdlib only.
"""

import json
import os
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

URL = os.environ.get("MISP_URL", "").rstrip("/")
KEY = os.environ.get("MISP_KEY", "")
VERIFY = os.environ.get("MISP_VERIFY_TLS", "false").lower() == "true"
WAIT_TIMEOUT = int(os.environ.get("WAIT_TIMEOUT", "1800"))
DRY_RUN = os.environ.get("DRY_RUN", "false").lower() == "true"
MODE = os.environ.get("MODE", "sync")
CONFIG_PATH = os.environ.get("BOOTSTRAP_CONFIG", "/config/config.json")

CTX = None if VERIFY else ssl._create_unverified_context()

# Feed fields compared/written. Values are normalised to strings for comparison
# (MISP returns ints as strings and booleans as bools).
# (the fields FeedsController::edit accepts).
FEED_FIELDS = (
    "name", "provider", "url", "source_format", "enabled", "caching_enabled",
    "distribution", "sharing_group_id", "tag_id", "tag_collection_id", "event_id",
    "input_source", "lookup_visible", "publish", "override_ids", "delta_merge",
    "fixed_event", "lock_events", "delete_local_file", "headers", "rules",
    "pull_rules", "settings", "orgc_id",
)

changes = []
errors = []


def log(msg):
    print(msg, flush=True)


class ApiError(Exception):
    pass


def call(method, path, body=None, write=False):
    """Call the API. Writes are skipped (and logged) in dry-run."""
    if write and DRY_RUN:
        log(f"  [dry-run] {method} /{path} {json.dumps(body) if body is not None else ''}")
        return None
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        f"{URL}/{path}",
        data=data,
        method=method,
        headers={
            "Authorization": KEY,
            "Accept": "application/json",
            "Content-Type": "application/json",
            "User-Agent": "misp-helm-bootstrap",
        },
    )
    try:
        with urllib.request.urlopen(req, context=CTX, timeout=300) as r:
            raw = r.read()
    except urllib.error.HTTPError as e:
        detail = e.read()[:500].decode(errors="replace")
        raise ApiError(f"{method} /{path} -> HTTP {e.code}: {detail}") from None
    if not raw:
        return None
    try:
        return json.loads(raw)
    except ValueError:
        raise ApiError(f"{method} /{path} -> non-JSON answer: {raw[:200]!r}") from None


def write(method, path, body=None, what=""):
    changes.append(what or f"{method} /{path}")
    return call(method, path, body, write=True)


def norm(v):
    if isinstance(v, bool):
        return "1" if v else "0"
    if v is None:
        return ""
    if isinstance(v, (dict, list)):
        return json.dumps(v, sort_keys=True)
    return str(v)


def wait_ready():
    deadline = time.time() + WAIT_TIMEOUT
    while True:
        try:
            v = call("GET", "servers/getVersion")
            log(f"MISP {v.get('version')} reachable at {URL}")
            return
        except (ApiError, urllib.error.URLError, OSError) as e:
            if time.time() > deadline:
                raise SystemExit(f"MISP not ready after {WAIT_TIMEOUT}s: {e}")
            log(f"waiting for MISP: {e}")
            time.sleep(10)


def sync_feeds(feeds):
    if not feeds:
        return
    log(f"feeds: {len(feeds)} declared")
    current = [f["Feed"] for f in call("GET", "feeds") or []]
    by_url = {f["url"]: f for f in current}
    by_name = {f["name"]: f for f in current}
    for want in feeds:
        name = want.get("name")
        if not name or not want.get("url"):
            errors.append(f"feed without name/url: {want}")
            continue
        have = by_url.get(want["url"]) or by_name.get(name)
        body = {k: v for k, v in want.items() if k in FEED_FIELDS}
        if have is None:
            body.setdefault("source_format", "misp")
            body.setdefault("input_source", "network")
            body.setdefault("distribution", 3)
            write("POST", "feeds/add", {"Feed": body}, f"feed add: {name}")
            continue
        diff = {k: v for k, v in body.items() if norm(have.get(k)) != norm(v)}
        if diff:
            write("POST", f"feeds/edit/{have['id']}", {"Feed": diff},
                  f"feed edit: {name} {sorted(diff)}")
        else:
            log(f"  feed ok: {name}")


def sync_taxonomies(cfg):
    wanted = cfg.get("taxonomies") or []
    if not wanted and not cfg.get("disableOtherTaxonomies"):
        return
    taxos = [t["Taxonomy"] for t in call("GET", "taxonomies") or []]
    if not taxos:
        write("POST", "taxonomies/update", None, "taxonomies update (empty)")
        if not DRY_RUN:
            taxos = [t["Taxonomy"] for t in call("GET", "taxonomies") or []]
    log(f"taxonomies: {len(wanted)} to enable, {len(taxos)} known")
    by_ns = {t["namespace"]: t for t in taxos}
    for ns in wanted:
        t = by_ns.get(ns)
        if t is None:
            errors.append(f"taxonomy not found: {ns}")
            continue
        if not t["enabled"]:
            write("POST", f"taxonomies/enable/{t['id']}", {}, f"taxonomy enable: {ns}")
            if cfg.get("taxonomiesAddTags", True):
                write("POST", f"taxonomies/addTag/{t['id']}", {}, f"taxonomy tags: {ns}")
        else:
            log(f"  taxonomy ok: {ns}")
    if cfg.get("disableOtherTaxonomies"):
        for t in taxos:
            if t["enabled"] and t["namespace"] not in wanted:
                write("POST", f"taxonomies/disable/{t['id']}", {},
                      f"taxonomy disable: {t['namespace']}")


def sync_warninglists(cfg):
    if cfg.get("updateWarninglists"):
        write("POST", "warninglists/update", {}, "warninglists update")
    wanted = cfg.get("warninglists") or []
    if not wanted:
        return
    lists = [w["Warninglist"] for w in (call("GET", "warninglists") or {}).get("Warninglists", [])]
    by_name = {w["name"]: w for w in lists}
    todo = []
    for name in wanted:
        w = by_name.get(name)
        if w is None:
            errors.append(f"warninglist not found: {name}")
        elif not w["enabled"]:
            todo.append(name)
        else:
            log(f"  warninglist ok: {name}")
    if todo:
        write("POST", "warninglists/toggleEnable", {"name": todo, "enabled": True},
              f"warninglists enable: {todo}")


def sync_noticelists(cfg):
    if cfg.get("updateNoticelists"):
        write("POST", "noticelists/update", {}, "noticelists update")
    wanted = cfg.get("noticelists") or []
    if not wanted:
        return
    lists = [n["Noticelist"] for n in call("GET", "noticelists") or []]
    by_name = {n["name"]: n for n in lists}
    for name in wanted:
        n = by_name.get(name)
        if n is None:
            errors.append(f"noticelist not found: {name}")
        elif not n["enabled"]:
            # toggleEnable flips the state; only called on a disabled list.
            write("POST", f"noticelists/toggleEnable/{n['id']}", {},
                  f"noticelist enable: {name}")
        else:
            log(f"  noticelist ok: {name}")


def sync_galaxies(cfg):
    if cfg.get("updateGalaxies"):
        write("POST", "galaxies/update", {}, "galaxies update")


def sync_settings(settings):
    for name, value in (settings or {}).items():
        cur = call("GET", f"servers/getSetting/{urllib.parse.quote(name)}") or {}
        if norm(cur.get("value")) == norm(value):
            log(f"  setting ok: {name}")
            continue
        write("POST", f"servers/serverSettingsEdit/{urllib.parse.quote(name)}",
              {"value": value}, f"setting: {name}")


def sync_organisations(orgs):
    if not orgs:
        return
    have = {o["Organisation"]["name"] for o in call("GET", "organisations/index/scope:all") or []}
    for org in orgs:
        if org.get("name") in have:
            log(f"  organisation ok: {org['name']}")
            continue
        write("POST", "admin/organisations/add", {"Organisation": org},
              f"organisation add: {org.get('name')}")


def fetch_feeds():
    write("POST", "feeds/fetchFromAllFeeds", {}, "feeds fetch (all)")
    write("POST", "feeds/cacheFeeds/all", {}, "feeds cache (all)")


def main():
    if not URL or not KEY:
        raise SystemExit("MISP_URL and MISP_KEY are required")
    with open(CONFIG_PATH) as fh:
        cfg = json.load(fh)
    log(f"mode={MODE} dry_run={DRY_RUN}")
    wait_ready()
    steps = (
        [("fetch", fetch_feeds)] if MODE == "fetch" else [
            ("organisations", lambda: sync_organisations(cfg.get("organisations"))),
            ("serverSettings", lambda: sync_settings(cfg.get("serverSettings"))),
            ("feeds", lambda: sync_feeds(cfg.get("feeds"))),
            ("taxonomies", lambda: sync_taxonomies(cfg)),
            ("warninglists", lambda: sync_warninglists(cfg)),
            ("noticelists", lambda: sync_noticelists(cfg)),
            ("galaxies", lambda: sync_galaxies(cfg)),
        ] + ([("fetch", fetch_feeds)] if cfg.get("fetchOnSync") else [])
    )
    for name, step in steps:
        try:
            step()
        except (ApiError, urllib.error.URLError, OSError, KeyError, TypeError) as e:
            errors.append(f"{name}: {e}")
    log(f"summary: {len(changes)} change(s){' planned' if DRY_RUN else ''}, {len(errors)} error(s)")
    for c in changes:
        log(f"  ~ {c}")
    for e in errors:
        log(f"  ! {e}")
    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()
