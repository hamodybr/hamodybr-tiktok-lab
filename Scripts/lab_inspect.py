#!/usr/bin/env python3
"""Read-only companion inspector; runs on Windows, macOS, Linux and A-Shell.

Usage: python3 lab_inspect.py ORIGINAL.mp4 [TIKTOK.mp4] --output report.json
No dependencies. ffprobe fields are added if ffprobe is available.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import struct
import subprocess

CONTAINERS = {"moov", "trak", "mdia", "minf", "stbl", "edts", "dinf", "mvex", "moof", "traf", "udta"}


def inspect(path):
    path = Path(path)
    size = path.stat().st_size
    atoms, tracks, warnings = [], [], []
    trailing_unparsed = 0
    with path.open("rb") as f:
        def read(offset, count):
            if offset < 0 or count < 0 or offset + count > size:
                raise ValueError("read beyond file boundary")
            f.seek(offset)
            data = f.read(count)
            if len(data) != count:
                raise ValueError("incomplete file")
            return data

        def uint(offset, width=4):
            return int.from_bytes(read(offset, width), "big")

        def require(a, n):
            if a["size"] - a["headerSize"] < n:
                raise ValueError(a["type"] + " table is truncated")

        def walk(start, end, depth=0, parent=""):
            nonlocal trailing_unparsed
            if depth > 16:
                raise ValueError("atom depth limit exceeded")
            p = start
            while p < end:
                if end - p < 8:
                    if depth == 0 and any(a["path"] == "moov" for a in atoms) and any(a["path"] == "mdat" for a in atoms):
                        trailing_unparsed = end - p
                        return
                    raise ValueError(f"truncated atom header at {p}")
                n = uint(p)
                kind = read(p + 4, 4).decode("ascii", errors="replace")
                header = 8
                if n == 1:
                    if end - p < 16:
                        raise ValueError("truncated extended atom header")
                    n, header = uint(p + 8, 8), 16
                elif n == 0:
                    n = end - p
                if kind == "uuid":
                    header += 16
                if len(atoms) >= 20_000:
                    raise ValueError("atom count limit exceeded")
                if n < header or n > end - p:
                    if depth == 0 and any(a["path"] == "moov" for a in atoms) and any(a["path"] == "mdat" for a in atoms):
                        trailing_unparsed = end - p
                        return
                    raise ValueError(f"invalid atom size at {p}")
                name = f"{parent}/{kind}" if parent else kind
                a = dict(type=kind, offset=p, size=n, headerSize=header, depth=depth, path=name, payload=p+header)
                atoms.append(a)
                if kind in CONTAINERS:
                    walk(p + header, p + n, depth + 1, name)
                p += n

        def duration(a, tkhd=False):
            require(a, 4)
            version = uint(a["payload"], 1)
            if version not in (0, 1):
                raise ValueError("unsupported duration version")
            width = 8 if version else 4
            scale_offset = 20 if version else 12
            ticks_offset = (28 if version else 20) if tkhd else scale_offset + 4
            require(a, ticks_offset + width)
            scale = 0 if tkhd else uint(a["payload"] + scale_offset)
            ticks = uint(a["payload"] + ticks_offset, width)
            unknown = ticks == (1 << (width * 8)) - 1
            return scale, ticks, unknown

        def table(a, composition=False):
            require(a, 8)
            count = uint(a["payload"] + 4)
            if count > 2_000_000 or count > (a["size"] - a["headerSize"] - 8) // 8:
                raise ValueError(a["type"] + " entry count exceeds table bounds or scan limit")
            samples, ticks, done = 0, 0, 0
            while done < count:
                batch = min(4096, count - done)
                data = read(a["payload"] + 8 + done * 8, batch * 8)
                for n, delta in struct.iter_unpack(">II", data):
                    samples += n
                    if not composition:
                        ticks += n * delta
                done += batch
            return samples, ticks

        walk(0, size)
        if trailing_unparsed:
            warnings.append(f"partial scan: {trailing_unparsed} unparsed trailing bytes; hash covers declared mdat only")
        if not any(a["path"] == "moov" for a in atoms):
            raise ValueError("no top-level moov found")
        fragmented = any(a["type"] in {"moof", "mvex"} for a in atoms)
        if fragmented:
            warnings.append("fragmented MP4: moov tables do not describe all samples; V1 does not inspect fragments")
        mvhd = next((a for a in atoms if a["path"] == "moov/mvhd"), None)
        scale, ticks, unknown = duration(mvhd) if mvhd else (0, 0, False)
        if not mvhd:
            warnings.append("missing mvhd")
        elif ticks == 0 or unknown:
            warnings.append("mvhd duration is zero or unknown; some players may show 0:00")
        if scale == 0:
            warnings.append("movie timescale is zero")
        for index, trak in enumerate(a for a in atoms if a["path"] == "moov/trak"):
            children = [a for a in atoms if trak["offset"] < a["offset"] < trak["offset"] + trak["size"]]
            def child(kind):
                return next((a for a in children if a["type"] == kind), None)
            t = dict(index=index + 1, kind="unknown", codec="unknown", timescale=0, mediaDuration=None,
                     headerDuration=None, sampleCount=None, timingSampleCount=None, timingDuration=None, compositionSampleCount=None)
            a = child("hdlr")
            if a:
                require(a, 12)
                t["kind"] = read(a["payload"]+8, 4).decode("ascii", errors="replace")
            a = child("mdhd")
            if a:
                ts, td, missing = duration(a)
                t.update(timescale=ts, mediaDuration=None if missing else td)
            a = child("tkhd")
            if a:
                _, td, missing = duration(a, tkhd=True)
                t["headerDuration"] = None if missing else td
            a = child("stsd")
            if a:
                require(a, 8)
                if uint(a["payload"]+4):
                    require(a, 16)
                    t["codec"] = read(a["payload"]+12, 4).decode("ascii", errors="replace")
            a = child("stsz")
            if a:
                require(a, 12)
                fixed, count = uint(a["payload"]+4), uint(a["payload"]+8)
                if fixed == 0 and count > (a["size"] - a["headerSize"] - 12) // 4:
                    raise ValueError("stsz sample count exceeds available size entries")
                t["sampleCount"] = count
            else:
                a = child("stz2")
                if a:
                    require(a, 12)
                    bits, count = uint(a["payload"]+7, 1), uint(a["payload"]+8)
                    if bits not in (4, 8, 16) or (bits * count + 7) // 8 > a["size"] - a["headerSize"] - 12:
                        raise ValueError("invalid stz2 table")
                    t["sampleCount"] = count
            a = child("stts")
            if a:
                t["timingSampleCount"], t["timingDuration"] = table(a)
            a = child("ctts")
            if a:
                t["compositionSampleCount"] = table(a, True)[0]
            if not fragmented:
                n, stts, ctts = t["sampleCount"], t["timingSampleCount"], t["compositionSampleCount"]
                if n is not None and stts is not None and n != stts:
                    warnings.append(f"track {index+1}: sample count mismatch: stsz/stz2={n}, stts={stts}")
                if n is not None and ctts is not None and n != ctts:
                    warnings.append(f"track {index+1}: ctts sample count mismatch: {ctts}")
                if t["timingDuration"] is not None and t["mediaDuration"] is not None and t["timingDuration"] != t["mediaDuration"]:
                    warnings.append(f"track {index+1}: stts duration differs from mdhd")
                if n is None or stts is None:
                    warnings.append(f"track {index+1}: missing sample or timing table")
            t["seconds"] = t["mediaDuration"] / t["timescale"] if t["timescale"] and t["mediaDuration"] is not None else None
            t["averageFPS"] = (t["timingSampleCount"] * t["timescale"] / t["timingDuration"]) if t["kind"] == "vide" and t["timingDuration"] and t["timingSampleCount"] is not None else None
            tracks.append(t)
        media = [a for a in atoms if a["depth"] == 0 and a["type"] == "mdat"]
        moov = next(a for a in atoms if a["path"] == "moov")
        fast_start = moov["offset"] < media[0]["offset"] if media else None
        if fast_start is False:
            warnings.append("moov follows mdat; network playback may start more slowly")
        if not tracks:
            warnings.append("no tracks in moov")
        sha = hashlib.sha256()
        for a in media:
            remaining = a["size"] - a["headerSize"]
            p = a["payload"]
            while remaining:
                count = min(1_048_576, remaining)
                sha.update(read(p, count))
                p, remaining = p + count, remaining - count
        result = dict(fileName=path.name, fileSize=size, atoms=atoms, tracks=tracks, warnings=warnings,
                      movieTimescale=scale, movieDuration=ticks, movieDurationUnknown=unknown,
                      seconds=ticks / scale if scale and not unknown else None, fragmented=fragmented,
                      trailingUnparsedBytes=trailing_unparsed,
                      fastStart=fast_start, mediaSHA256=sha.hexdigest() if media else None,
                      topLevelOrder=" → ".join(a["type"] for a in atoms if a["depth"] == 0))
    if shutil.which("ffprobe"):
        probe = subprocess.run(["ffprobe", "-v", "error", "-show_streams", "-show_format", "-of", "json", str(path)], capture_output=True, text=True, timeout=120)
        if probe.returncode == 0:
            result["ffprobe"] = json.loads(probe.stdout)
        else:
            result["ffprobeError"] = probe.stderr.strip()
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("original")
    parser.add_argument("tiktok", nargs="?")
    parser.add_argument("--output", default="HAMODYBR-report.json")
    args = parser.parse_args()
    try:
        original = inspect(args.original)
        tiktok = inspect(args.tiktok) if args.tiktok else None
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        parser.exit(1, f"Inspection failed: {error}\n")
    session = dict(app="HAMODYBR TikTok Lab / Python companion", version="0.1.0", original=original, tiktok=tiktok,
                   note="Metadata and hashes are not visual-quality measurements. No files were modified.")
    if tiktok:
        session["mediaPayloadsIdentical"] = original["mediaSHA256"] is not None and original["mediaSHA256"] == tiktok["mediaSHA256"]
    output = Path(args.output)
    inputs = [Path(args.original).resolve()] + ([Path(args.tiktok).resolve()] if args.tiktok else [])
    if output.resolve() in inputs:
        parser.exit(1, "Output must not overwrite an input video.\n")
    output.write_text(json.dumps(session, ensure_ascii=False, indent=2), encoding="utf-8")
    print("Report:", output)
    for r in [original, tiktok]:
        if r:
            print(r["fileName"], r["topLevelOrder"])
            for warning in r["warnings"]:
                print(" •", warning)


if __name__ == "__main__":
    main()
