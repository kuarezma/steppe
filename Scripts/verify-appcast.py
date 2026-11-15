#!/usr/bin/env python3
"""Verify Sparkle appcast.xml against release archive, version, Ed25519 signature, and notes."""

from __future__ import annotations

import argparse
import base64
import binascii
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
MIN_MONOTONIC_BUILD = 11  # Live v0.1.10 shipped build 11; newer builds must be strictly greater.
DEFAULT_PUBLIC_KEY = Path(__file__).resolve().parent.parent / "Config" / "sparkle_public_key.txt"

_SWIFT_VERIFY_SCRIPT = """
import CryptoKit
import Foundation

let args = CommandLine.arguments
guard args.count == 4,
      let pubData = Data(base64Encoded: args[1]),
      let sigData = Data(base64Encoded: args[2]) else {
    exit(2)
}
let payload = try Data(contentsOf: URL(fileURLWithPath: args[3]), options: .mappedIfSafe)
let key = try Curve25519.Signing.PublicKey(rawRepresentation: pubData)
exit(key.isValidSignature(sigData, for: payload) ? 0 : 1)
"""


def _sparkle_tag(name: str) -> str:
    return f"{{{SPARKLE_NS}}}{name}"


def _sparkle_field(item: ET.Element, enclosure: ET.Element, name: str) -> str | None:
    attr = enclosure.attrib.get(_sparkle_tag(name))
    if attr is not None:
        return attr.strip()
    child = item.find(_sparkle_tag(name))
    if child is not None and child.text:
        return child.text.strip()
    return None


def _load_public_key(public_key_path: Path) -> bytes:
    if not public_key_path.is_file():
        raise ValueError(f"Sparkle public key file not found: {public_key_path}")
    raw_b64 = public_key_path.read_text(encoding="utf-8").strip()
    if not raw_b64:
        raise ValueError(f"Sparkle public key file is empty: {public_key_path}")
    try:
        pub_bytes = base64.b64decode(raw_b64, validate=True)
    except (binascii.Error, ValueError) as exc:
        raise ValueError(f"invalid base64 Sparkle public key: {exc}") from exc
    if len(pub_bytes) != 32:
        raise ValueError(f"Sparkle public key decoded to {len(pub_bytes)} bytes, expected 32")
    return pub_bytes


def _verify_ed25519_signature(pub_bytes: bytes, sig_bytes: bytes, zip_path: Path) -> None:
    try:
        from cryptography.exceptions import InvalidSignature
        from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
    except ImportError:
        pub_b64 = base64.b64encode(pub_bytes).decode("ascii")
        sig_b64 = base64.b64encode(sig_bytes).decode("ascii")
        try:
            proc = subprocess.run(
                ["swift", "-", pub_b64, sig_b64, str(zip_path)],
                input=_SWIFT_VERIFY_SCRIPT,
                text=True,
                capture_output=True,
            )
        except OSError as exc:
            raise ValueError(f"Ed25519 verifier unavailable (no cryptography module or swift): {exc}") from exc
        if proc.returncode != 0:
            detail = proc.stderr.strip() or f"exit {proc.returncode}"
            raise ValueError(f"Ed25519 signature verification failed against public key ({detail})")
        return

    try:
        key = Ed25519PublicKey.from_public_bytes(pub_bytes)
        key.verify(sig_bytes, zip_path.read_bytes())
    except InvalidSignature as exc:
        raise ValueError("Ed25519 signature verification failed against Sparkle public key") from exc


def verify_appcast(
    appcast_path: Path,
    zip_path: Path,
    expected_version: str,
    *,
    public_key_path: Path | None = DEFAULT_PUBLIC_KEY,
    expected_build: int | None = None,
    url_prefix: str | None = None,
    require_notes: bool = False,
    min_build_exclusive: int = MIN_MONOTONIC_BUILD,
) -> None:
    if not appcast_path.is_file():
        raise ValueError(f"appcast not found: {appcast_path}")
    if not zip_path.is_file():
        raise ValueError(f"release archive not found: {zip_path}")
    if public_key_path is None:
        raise ValueError("public_key_path is required for signature verification")
    pub_bytes = _load_public_key(public_key_path)

    tree = ET.parse(appcast_path)
    root = tree.getroot()
    channel = root.find("channel")
    if channel is None:
        raise ValueError("appcast missing <channel>")

    items = channel.findall("item")
    if not items:
        raise ValueError("appcast contains no <item> entries")

    matched: tuple[ET.Element, ET.Element] | None = None
    for item in items:
        enc = item.find("enclosure")
        if enc is None:
            continue
        short_ver = _sparkle_field(item, enc, "shortVersionString")
        if short_ver == expected_version:
            matched = (item, enc)
            break

    if matched is None:
        raise ValueError(f"appcast has no item for version {expected_version!r}")

    item, enc = matched

    url = enc.attrib.get("url", "").strip()
    if not url.startswith("https://"):
        raise ValueError(f"enclosure url must use https://, got {url!r}")
    if url_prefix is not None:
        normalized_prefix = url_prefix.rstrip("/") + "/"
        expected_url = normalized_prefix + zip_path.name
        if url != expected_url:
            raise ValueError(f"enclosure url {url!r} != expected {expected_url!r}")

    raw_length = enc.attrib.get("length", "").strip()
    if not raw_length.isdigit():
        raise ValueError(f"invalid enclosure length {raw_length!r}")
    actual_size = zip_path.stat().st_size
    if int(raw_length) != actual_size:
        raise ValueError(f"enclosure length {raw_length} != archive size {actual_size}")

    sig = enc.attrib.get(_sparkle_tag("edSignature"), "").strip()
    if not sig:
        raise ValueError("missing sparkle:edSignature attribute on enclosure")
    try:
        decoded = base64.b64decode(sig, validate=True)
    except (binascii.Error, ValueError) as exc:
        raise ValueError(f"invalid base64 sparkle:edSignature: {exc}") from exc
    if len(decoded) != 64:
        raise ValueError(f"sparkle:edSignature decoded to {len(decoded)} bytes, expected 64")
    _verify_ed25519_signature(pub_bytes, decoded, zip_path)

    build_str = _sparkle_field(item, enc, "version")
    if not build_str or not build_str.isdigit():
        raise ValueError(f"invalid sparkle:version {build_str!r}")
    build_num = int(build_str)
    if expected_build is not None and build_num != expected_build:
        raise ValueError(f"sparkle:version {build_num} != expected build {expected_build}")
    if build_num <= min_build_exclusive:
        raise ValueError(f"sparkle:version {build_num} must be > {min_build_exclusive}")

    if require_notes:
        desc = item.find("description")
        text = "".join(desc.itertext()).strip() if desc is not None else ""
        if not text:
            raise ValueError("missing non-empty embedded <description> release notes")


_SELFTEST_PUB_B64 = "A6EHv/POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg="
_SELFTEST_SIG_B64 = "e+mTAn6HARwRsuJ+aCIPXNIqHytvDk/uPeedE5CXQqxpIVsf0jQ4awMG9Pe4eaa7zPhsUYGhGY8DUPTaxoJ2Dw=="


def _sample_xml(
    *,
    version: str = "0.1.11",
    build: int = 1011999,
    url: str = "https://github.com/kuarezma/steppe/releases/download/v0.1.11/Steppe-0.1.11.zip",
    length: int = 12,
    sig: str | None = _SELFTEST_SIG_B64,
    notes: str | None = "Bug fixes",
) -> str:
    sig_attr = f' sparkle:edSignature="{sig}"' if sig else ""
    desc = f"<description><![CDATA[{notes}]]></description>" if notes is not None else ""
    return f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Steppe</title>
    <item>
      <title>{version}</title>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      {desc}
      <enclosure url="{url}" length="{length}" type="application/octet-stream"{sig_attr} />
    </item>
  </channel>
</rss>
"""


def _expect_fail(fn, label: str) -> None:
    try:
        fn()
    except ValueError:
        return
    raise AssertionError(f"expected ValueError for {label}")


def run_selftest() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        z = root / "Steppe-0.1.11.zip"
        z.write_bytes(b"PK\x03\x04testzip!")
        size = z.stat().st_size
        feed = root / "appcast.xml"
        pub = root / "pub.txt"
        pub.write_text(_SELFTEST_PUB_B64 + "\n", encoding="utf-8")
        other_pub = root / "other_pub.txt"
        other_pub.write_text(base64.b64encode(b"\x11" * 32).decode("ascii") + "\n", encoding="utf-8")
        prefix = "https://github.com/kuarezma/steppe/releases/download/v0.1.11/"

        feed.write_text(_sample_xml(length=size), encoding="utf-8")
        verify_appcast(
            feed, z, "0.1.11",
            public_key_path=pub, expected_build=1011999, url_prefix=prefix, require_notes=True
        )

        # Tampered archive or forged signature must fail cryptographic check.
        bad_sig = base64.b64encode(b"\x42" * 64).decode("ascii")
        feed.write_text(_sample_xml(length=size, sig=bad_sig), encoding="utf-8")
        _expect_fail(
            lambda: verify_appcast(feed, z, "0.1.11", public_key_path=pub, url_prefix=prefix),
            "forged signature",
        )

        # Valid signature signed by a different key must fail against expected public key.
        feed.write_text(_sample_xml(length=size), encoding="utf-8")
        _expect_fail(
            lambda: verify_appcast(feed, z, "0.1.11", public_key_path=other_pub, url_prefix=prefix),
            "wrong public key",
        )

        feed.write_text(_sample_xml(length=size, sig=""), encoding="utf-8")
        _expect_fail(
            lambda: verify_appcast(feed, z, "0.1.11", public_key_path=pub, url_prefix=prefix),
            "missing signature",
        )

        feed.write_text(_sample_xml(length=size + 1), encoding="utf-8")
        _expect_fail(
            lambda: verify_appcast(feed, z, "0.1.11", public_key_path=pub, url_prefix=prefix),
            "wrong length",
        )

        feed.write_text(_sample_xml(length=size, build=11), encoding="utf-8")
        _expect_fail(
            lambda: verify_appcast(feed, z, "0.1.11", public_key_path=pub, url_prefix=prefix),
            "non-monotonic build",
        )

        feed.write_text(
            _sample_xml(length=size, url="http://github.com/kuarezma/steppe/releases/download/v0.1.11/Steppe-0.1.11.zip"),
            encoding="utf-8",
        )
        _expect_fail(
            lambda: verify_appcast(feed, z, "0.1.11", public_key_path=pub, url_prefix=prefix),
            "http url",
        )

        feed.write_text(_sample_xml(length=size, notes=None), encoding="utf-8")
        _expect_fail(
            lambda: verify_appcast(feed, z, "0.1.11", public_key_path=pub, url_prefix=prefix, require_notes=True),
            "missing notes",
        )

    print("PASS verify-appcast selftest")


def main() -> int:
    parser = argparse.ArgumentParser(description="Verify Sparkle appcast.xml metadata and Ed25519 signature.")
    parser.add_argument("appcast", nargs="?", type=Path, help="Path to appcast.xml")
    parser.add_argument("--zip", dest="zip_path", type=Path, help="Path to Steppe-<version>.zip")
    parser.add_argument("--version", help="Expected sparkle:shortVersionString")
    parser.add_argument("--build", type=int, help="Expected integer sparkle:version")
    parser.add_argument("--public-key", type=Path, default=DEFAULT_PUBLIC_KEY, help="Path to base64 Ed25519 public key")
    parser.add_argument("--url-prefix", help="Required HTTPS URL prefix")
    parser.add_argument("--require-notes", action="store_true", help="Require non-empty <description>")
    parser.add_argument("--selftest", action="store_true", help="Run built-in unit checks")
    args = parser.parse_args()

    if args.selftest:
        run_selftest()
        return 0

    if not args.appcast or not args.zip_path or not args.version:
        parser.error("appcast, --zip, and --version are required unless --selftest is passed")

    try:
        verify_appcast(
            args.appcast,
            args.zip_path,
            args.version,
            public_key_path=args.public_key,
            expected_build=args.build,
            url_prefix=args.url_prefix,
            require_notes=args.require_notes,
        )
    except (ValueError, ET.ParseError) as exc:
        print(f"ERROR: appcast verification failed: {exc}", file=sys.stderr)
        return 1

    print(f"PASS verify-appcast: {args.appcast.name} ({args.version})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
