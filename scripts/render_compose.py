#!/usr/bin/env python3
"""Merge a platform compose base with optional overlays. Stdlib only."""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

TOP_KEY = re.compile(r"^([A-Za-z0-9_-]+):\s*(#.*)?$")
SVC_KEY = re.compile(r"^  ([A-Za-z0-9_-]+):\s*(#.*)?$")
VOL_KEY = re.compile(r"^  ([A-Za-z0-9_-]+):\s*(#.*)?$")


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def split_top(text: str) -> list[tuple[str, str]]:
    lines = text.splitlines(keepends=True)
    blocks: list[tuple[str, str]] = []
    i = 0
    preamble: list[str] = []
    while i < len(lines):
        m = TOP_KEY.match(lines[i].rstrip("\n"))
        if not m:
            preamble.append(lines[i])
            i += 1
            continue
        key = m.group(1)
        chunk = [lines[i]]
        i += 1
        while i < len(lines) and not TOP_KEY.match(lines[i].rstrip("\n")):
            chunk.append(lines[i])
            i += 1
        blocks.append((key, "".join(chunk)))
    if preamble:
        blocks.insert(0, ("__preamble__", "".join(preamble)))
    return blocks


def inner_map(block: str, key_re: re.Pattern[str]) -> tuple[str, list[tuple[str, str]]]:
    """Split a top-level `services:` / `volumes:` block into header + child maps."""
    lines = block.splitlines(keepends=True)
    if not lines:
        return "", []
    header = lines[0]
    rest = lines[1:]
    items: list[tuple[str, str]] = []
    i = 0
    while i < len(rest):
        raw = rest[i]
        if raw.strip() == "" or raw.lstrip().startswith("#"):
            # keep comments/blank glued to the next real key
            lead = [raw]
            i += 1
            while i < len(rest) and (rest[i].strip() == "" or rest[i].lstrip().startswith("#")):
                lead.append(rest[i])
                i += 1
            if i >= len(rest):
                items.append(("", "".join(lead)))
                break
            m = key_re.match(rest[i].rstrip("\n"))
            if not m:
                items.append(("", "".join(lead) + rest[i]))
                i += 1
                continue
            name = m.group(1)
            chunk = lead + [rest[i]]
            i += 1
            while i < len(rest) and not key_re.match(rest[i].rstrip("\n")):
                chunk.append(rest[i])
                i += 1
            items.append((name, "".join(chunk)))
            continue
        m = key_re.match(raw.rstrip("\n"))
        if not m:
            items.append(("", raw))
            i += 1
            continue
        name = m.group(1)
        chunk = [raw]
        i += 1
        while i < len(rest) and not key_re.match(rest[i].rstrip("\n")):
            chunk.append(rest[i])
            i += 1
        items.append((name, "".join(chunk)))
    return header, items


def rebuild_map(header: str, items: list[tuple[str, str]]) -> str:
    return header + "".join(body for _, body in items)


def strip_named(items: list[tuple[str, str]], names: set[str]) -> list[tuple[str, str]]:
    return [(n, b) for n, b in items if n not in names]


def overlay_items(path: Path, section: str) -> list[tuple[str, str]]:
    blocks = {k: v for k, v in split_top(read(path))}
    if section not in blocks:
        return []
    key_re = SVC_KEY if section == "services" else VOL_KEY
    _, items = inner_map(blocks[section], key_re)
    return [(n, b) for n, b in items if n]


def merge(base_text: str, overlays: list[Path], strip_services: set[str], strip_volumes: set[str]) -> str:
    blocks = split_top(base_text)
    by_key = {k: v for k, v in blocks}

    svc_header, svc_items = inner_map(by_key.get("services", "services:\n"), SVC_KEY)
    vol_header, vol_items = inner_map(by_key.get("volumes", "volumes:\n"), VOL_KEY)

    if strip_services:
        svc_items = strip_named(svc_items, strip_services)
    if strip_volumes:
        vol_items = strip_named(vol_items, strip_volumes)

    existing_svc = {n for n, _ in svc_items if n}
    existing_vol = {n for n, _ in vol_items if n}

    for ov in overlays:
        for name, body in overlay_items(ov, "services"):
            if name in existing_svc:
                svc_items = [(n, body if n == name else b) for n, b in svc_items]
            else:
                svc_items.append((name, body if body.endswith("\n") else body + "\n"))
                existing_svc.add(name)
        for name, body in overlay_items(ov, "volumes"):
            if name in existing_vol:
                continue
            vol_items.append((name, body if body.endswith("\n") else body + "\n"))
            existing_vol.add(name)

    out: list[str] = []
    seen_volumes = False
    for key, block in blocks:
        if key == "__preamble__":
            out.append(block)
            continue
        if key == "services":
            body = rebuild_map(svc_header, svc_items)
            if not body.endswith("\n"):
                body += "\n"
            out.append(body)
            continue
        if key == "volumes":
            seen_volumes = True
            body = rebuild_map(vol_header, vol_items)
            if not body.endswith("\n"):
                body += "\n"
            out.append(body)
            continue
        out.append(block)
    if not seen_volumes and vol_items:
        out.append(rebuild_map("volumes:\n", vol_items))
    text = "".join(out)
    if not text.endswith("\n"):
        text += "\n"
    return text


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--base", required=True, type=Path)
    p.add_argument("--overlay", action="append", default=[], type=Path)
    p.add_argument("--strip-service", action="append", default=[])
    p.add_argument("--strip-volume", action="append", default=[])
    p.add_argument("--output", required=True, type=Path)
    args = p.parse_args()
    if not args.base.is_file():
        print(f"base compose not found: {args.base}", file=sys.stderr)
        return 1
    for ov in args.overlay:
        if not ov.is_file():
            print(f"overlay not found: {ov}", file=sys.stderr)
            return 1
    text = merge(
        read(args.base),
        args.overlay,
        set(args.strip_service),
        set(args.strip_volume),
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(text, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
