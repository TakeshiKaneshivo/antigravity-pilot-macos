#!/usr/bin/env python3
import argparse
import hashlib
import json
import plistlib
from pathlib import Path


def read_u32(data: bytes, offset: int) -> int:
    return int.from_bytes(data[offset : offset + 4], "little")


def write_u32(value: int) -> bytes:
    return int(value).to_bytes(4, "little")


def integrity_for(data: bytes, block_size: int = 4 * 1024 * 1024) -> dict:
    blocks = [
        hashlib.sha256(data[i : i + block_size]).hexdigest()
        for i in range(0, len(data), block_size)
    ]
    if not blocks:
        blocks = [hashlib.sha256(b"").hexdigest()]
    return {
        "algorithm": "SHA256",
        "hash": hashlib.sha256(data).hexdigest(),
        "blockSize": block_size,
        "blocks": blocks,
    }


def iter_files(files: dict, prefix: str = ""):
    for name, entry in files.items():
        path = f"{prefix}/{name}" if prefix else name
        if "files" in entry:
            yield from iter_files(entry["files"], path)
        else:
            yield path, entry


def update_info_plist_integrity(info_plist: Path, header_hash: str) -> None:
    if not info_plist.exists():
        return
    with info_plist.open("rb") as fp:
        plist = plistlib.load(fp)
    integrity = plist.get("ElectronAsarIntegrity")
    if isinstance(integrity, dict) and isinstance(integrity.get("Resources/app.asar"), dict):
        integrity["Resources/app.asar"]["algorithm"] = "SHA256"
        integrity["Resources/app.asar"]["hash"] = header_hash
        with info_plist.open("wb") as fp:
            plistlib.dump(plist, fp)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--asar", required=True, type=Path)
    parser.add_argument("--icon", required=True, type=Path)
    parser.add_argument("--info-plist", type=Path, default=None)
    args = parser.parse_args()

    original = args.asar.read_bytes()
    if len(original) < 16:
        raise SystemExit("asar file is too small")

    header_pickle_size = read_u32(original, 4)
    json_size = read_u32(original, 12)
    header_start = 16
    header_end = header_start + json_size
    data_start = 8 + header_pickle_size
    if header_pickle_size < 8 or header_end > data_start or data_start > len(original):
        raise SystemExit("invalid asar header size")

    header = json.loads(original[header_start:header_end].decode("utf-8"))
    icon_data = args.icon.read_bytes()

    file_blobs: list[bytes] = []
    found_icon = False
    offset = 0

    for path, entry in iter_files(header["files"]):
        if entry.get("unpacked") or "link" in entry:
            continue

        if path == "icon.png":
            blob = icon_data
            found_icon = True
            entry["size"] = len(blob)
            block_size = entry.get("integrity", {}).get("blockSize", 4 * 1024 * 1024)
            entry["integrity"] = integrity_for(blob, block_size)
        else:
            size = int(entry["size"])
            old_offset = int(entry["offset"])
            blob = original[data_start + old_offset : data_start + old_offset + size]

        entry["offset"] = str(offset)
        file_blobs.append(blob)
        offset += len(blob)

    if not found_icon:
        raise SystemExit("icon.png not found in app.asar")

    header_json = json.dumps(header, separators=(",", ":")).encode("utf-8")
    unpadded_size = len(header_json)
    header_hash = hashlib.sha256(header_json).hexdigest()
    padding = (4 - (unpadded_size % 4)) % 4
    aligned_size = unpadded_size + padding

    # Electron asar uses Chromium Pickle framing:
    # 4, aligned_size + 8, aligned_size + 4, unpadded_size, json, NUL padding.
    prefix = b"".join(
        [
            write_u32(4),
            write_u32(aligned_size + 8),
            write_u32(aligned_size + 4),
            write_u32(unpadded_size),
        ]
    )
    args.asar.write_bytes(prefix + header_json + (b"\x00" * padding) + b"".join(file_blobs))

    if args.info_plist is not None:
        update_info_plist_integrity(args.info_plist, header_hash)


if __name__ == "__main__":
    main()
