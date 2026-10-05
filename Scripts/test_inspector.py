#!/usr/bin/env python3
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from lab_inspect import inspect


def be(n, width=4):
    return n.to_bytes(width, "big")


def atom(kind, payload):
    return be(8 + len(payload)) + kind.encode("ascii") + payload


def movie(duration=1200, count=60, composition=None, version=0, truncated=False, fast=True, fragmented=False):
    mvhd = (bytes([1, 0, 0, 0]) + bytes(16) + be(600) + be(duration, 8)) if version else bytes(12) + be(600) + be(duration)
    tkhd = atom("tkhd", bytes(20) + be(1200))
    mdhd = atom("mdhd", bytes(12) + be(600) + be(1200))
    hdlr = atom("hdlr", bytes(8) + b"vide")
    stsd = atom("stsd", be(0) + be(1) + be(8) + b"avc1")
    stts = atom("stts", be(0) + be(1) + be(count) + be(20))
    stsz = atom("stsz", be(0) + be(0 if truncated else 1) + be(60))
    tables = stsd + stts + stsz
    if composition is not None:
        tables += atom("ctts", be(0) + be(1) + be(composition) + be(0))
    trak = atom("trak", tkhd + atom("mdia", mdhd + hdlr + atom("minf", atom("stbl", tables))))
    moov = atom("moov", atom("mvhd", mvhd) + trak + (atom("mvex", b"") if fragmented else b""))
    mdat = atom("mdat", bytes([42]) * 60)
    return atom("ftyp", b"isom" + be(0) + b"isom") + (moov + mdat if fast else mdat + moov)


class InspectorTests(unittest.TestCase):
    def scan(self, data):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "fixture.mp4"
            path.write_bytes(data)
            before = hashlib.sha256(path.read_bytes()).hexdigest()
            # Synthetic tables test structural logic, not AV decoding.
            with patch("lab_inspect.shutil.which", return_value=None):
                result = inspect(path)
            self.assertEqual(before, hashlib.sha256(path.read_bytes()).hexdigest())
            return result

    def test_valid(self):
        r = self.scan(movie())
        self.assertEqual(r["seconds"], 2)
        self.assertEqual(r["tracks"][0]["averageFPS"], 30)
        self.assertEqual(r["tracks"][0]["codec"], "avc1")
        self.assertEqual(r["warnings"], [])

    def test_zero_duration(self):
        self.assertTrue(any("0:00" in w for w in self.scan(movie(duration=0))["warnings"]))

    def test_unknown_durations(self):
        for version, duration in [(0, 2**32-1), (1, 2**64-1)]:
            r = self.scan(movie(duration=duration, version=version))
            self.assertIsNone(r["seconds"])
            self.assertTrue(r["movieDurationUnknown"])

    def test_version_one(self):
        self.assertEqual(self.scan(movie(version=1))["seconds"], 2)

    def test_phantom_samples(self):
        r = self.scan(movie(count=5455))
        self.assertTrue(any("sample count mismatch" in w for w in r["warnings"]))
        self.assertTrue(any("differs from mdhd" in w for w in r["warnings"]))

    def test_composition_mismatch(self):
        self.assertTrue(any("ctts" in w for w in self.scan(movie(composition=61))["warnings"]))

    def test_truncated_table(self):
        with self.assertRaises(ValueError):
            self.scan(movie(truncated=True))

    def test_fast_start(self):
        self.assertFalse(self.scan(movie(fast=False))["fastStart"])

    def test_fragmented(self):
        r = self.scan(movie(count=1, fragmented=True))
        self.assertTrue(r["fragmented"])
        self.assertFalse(any("sample count mismatch" in w for w in r["warnings"]))

    def test_trailing_garbage(self):
        r = self.scan(movie() + be(4) + bytes(8))
        self.assertEqual(r["trailingUnparsedBytes"], 12)
        self.assertEqual(len(r["tracks"]), 1)

    def test_broken_atom(self):
        for data in [b"abc", be(1000) + b"moov" + b"x", atom("ftyp", b"isom")]:
            with self.assertRaises(ValueError):
                self.scan(data)

    def test_large_and_zero_size_atoms(self):
        r = self.scan(be(1) + b"free" + be(20, 8) + bytes(4) + movie() + be(0) + b"free" + bytes(4))
        self.assertEqual(r["atoms"][0]["headerSize"], 16)
        self.assertEqual(r["atoms"][-1]["size"], 12)

    def test_media_hash(self):
        a, b = self.scan(movie()), self.scan(movie(duration=0))
        self.assertEqual(a["mediaSHA256"], b["mediaSHA256"])
        c = self.scan(movie()[:-1] + bytes([43]))
        self.assertNotEqual(a["mediaSHA256"], c["mediaSHA256"])

    def test_real_h264_60fps_with_audio(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "real.mp4"
            subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=180x320:rate=60:duration=1", "-f", "lavfi", "-i", "sine=frequency=1000:sample_rate=48000:duration=1", "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", "-c:a", "aac", "-movflags", "+faststart", "-shortest", str(path)], check=True)
            r = inspect(path)
            self.assertEqual(r["warnings"], [])
            video = next(t for t in r["tracks"] if t["kind"] == "vide")
            audio = next(t for t in r["tracks"] if t["kind"] == "soun")
            self.assertEqual(video["averageFPS"], 60)
            self.assertEqual(audio["timescale"], 48000)
            probe_video = next(t for t in r["ffprobe"]["streams"] if t["codec_type"] == "video")
            self.assertEqual(video["sampleCount"], int(probe_video["nb_frames"]))

    def test_cli_protects_input(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "video.mp4"
            path.write_bytes(movie())
            original = path.read_bytes()
            result = subprocess.run(["python3", str(Path(__file__).with_name("lab_inspect.py")), str(path), "--output", str(path)], capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(path.read_bytes(), original)


if __name__ == "__main__":
    unittest.main(verbosity=2)
