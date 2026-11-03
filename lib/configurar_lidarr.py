#!/usr/bin/env python3
"""Deja Lidarr listo para Soularr: perfil «Solo FLAC», carpeta raíz /music y renombrado.

Uso: LIDARR_URL=http://127.0.0.1:8686 LIDARR_API_KEY=... configurar_lidarr.py

Es idempotente: si el perfil o la carpeta ya existen, los actualiza.
Solo usa la librería estándar.
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request

URL = os.environ["LIDARR_URL"].rstrip("/")
KEY = os.environ["LIDARR_API_KEY"]
PROFILE_NAME = "Solo FLAC"
ROOT_PATH = "/music"


def api(method: str, path: str, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        f"{URL}/api/v1{path}",
        data=data,
        method=method,
        headers={"X-Api-Key": KEY, "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        raw = resp.read()
        return json.loads(raw) if raw else None


def wait_ready(seconds: int = 240) -> None:
    deadline = time.time() + seconds
    last = None
    while time.time() < deadline:
        try:
            status = api("GET", "/system/status")
            print(f"Lidarr {status.get('version')} responde.")
            return
        except (urllib.error.URLError, ConnectionError, TimeoutError) as e:
            last = e
            time.sleep(5)
    sys.exit(f"Lidarr no responde en {URL} tras {seconds}s: {last}")


def leaf_allowed(item: dict) -> bool:
    return "FLAC" in item["quality"]["name"].upper()


def flac_only_items(items: list) -> list:
    out = []
    for item in items:
        item = dict(item)
        if item.get("items"):  # grupo de calidades
            children = []
            for child in item["items"]:
                child = dict(child)
                child["allowed"] = leaf_allowed(child)
                children.append(child)
            item["items"] = children
            item["allowed"] = any(c["allowed"] for c in children)
        else:
            item["allowed"] = leaf_allowed(item)
        out.append(item)
    return out


def item_id(item: dict) -> int:
    return item["id"] if item.get("items") else item["quality"]["id"]


def ensure_profile() -> int:
    profiles = api("GET", "/qualityprofile")
    existing = next((p for p in profiles if p["name"] == PROFILE_NAME), None)
    base = existing or next((p for p in profiles if p["name"].lower() == "lossless"), None)
    if base is None:
        base = next(p for p in profiles if any(leaf_allowed(i) for i in iter_leaves(p["items"])))

    profile = dict(base)
    profile["name"] = PROFILE_NAME
    profile["upgradeAllowed"] = True
    profile["items"] = flac_only_items(base["items"])
    allowed_top = [i for i in profile["items"] if i["allowed"]]
    if not allowed_top:
        sys.exit("No hay ninguna calidad FLAC en los perfiles de Lidarr; revisa Settings > Quality.")
    # La lista va de peor a mejor: el corte es la mejor calidad FLAC
    profile["cutoff"] = item_id(allowed_top[-1])

    if existing:
        api("PUT", f"/qualityprofile/{existing['id']}", profile)
        print(f"Perfil «{PROFILE_NAME}» actualizado (id {existing['id']}).")
        return existing["id"]
    profile.pop("id", None)
    created = api("POST", "/qualityprofile", profile)
    print(f"Perfil «{PROFILE_NAME}» creado (id {created['id']}) a partir de «{base['name']}».")
    return created["id"]


def iter_leaves(items: list):
    for item in items:
        if item.get("items"):
            yield from item["items"]
        else:
            yield item


def ensure_root_folder(quality_id: int) -> None:
    metadata = api("GET", "/metadataprofile")
    meta = next((m for m in metadata if m["name"].lower() == "standard"), metadata[0])
    wanted = {
        "name": "Música",
        "path": ROOT_PATH,
        "defaultQualityProfileId": quality_id,
        "defaultMetadataProfileId": meta["id"],
        "defaultMonitorOption": "all",
        "defaultNewItemMonitorOption": "all",
        "defaultTags": [],
    }
    roots = api("GET", "/rootfolder")
    existing = next((r for r in roots if r["path"].rstrip("/") == ROOT_PATH), None)
    if existing:
        merged = dict(existing)
        merged.update(wanted)
        api("PUT", f"/rootfolder/{existing['id']}", merged)
        print(f"Carpeta raíz {ROOT_PATH} actualizada.")
    else:
        api("POST", "/rootfolder", wanted)
        print(f"Carpeta raíz {ROOT_PATH} creada (perfil «{PROFILE_NAME}», metadatos «{meta['name']}»).")


def ensure_naming() -> None:
    naming = api("GET", "/config/naming")
    naming["renameTracks"] = True
    naming["replaceIllegalCharacters"] = True
    api("PUT", f"/config/naming/{naming['id']}", naming)
    print("Renombrado de pistas activado (formato por defecto de Lidarr).")


def main() -> None:
    wait_ready()
    try:
        quality_id = ensure_profile()
        ensure_root_folder(quality_id)
        ensure_naming()
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="replace")[:500]
        sys.exit(f"Lidarr respondió {e.code} en {e.url}: {detail}")


if __name__ == "__main__":
    main()
