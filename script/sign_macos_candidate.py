#!/usr/bin/env python3
"""Isolate Sparkle signing credentials; validate candidates without credentials."""
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import unittest
import xml.etree.ElementTree as ET

PUBLIC_KEY = "txWavHI0vv7xM5j0CrtW8pkoRWmChw8hHjUxa1BL1So="
NS = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
PREFIX = b"<!-- sparkle-signatures:\n"


class CandidateError(Exception):
    """Only fixed, non-sensitive diagnostics may be placed in this exception."""


def require(condition, message):
    if not condition:
        raise CandidateError(message)


def metadata(root):
    data = json.loads((root / "metadata.json").read_text())
    version, build = data["version"], data["build"]
    require(isinstance(version, str) and re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version), "Invalid candidate version")
    require(isinstance(build, str) and build.isascii() and build.isdigit() and int(build) > 16, "Invalid candidate build")
    name = f"CodexMeter-{version}-macos-CANDIDATE-ADHOC.dmg"
    require(data["archive"] == name, "Unexpected candidate filename")
    require(data["public_key"] == PUBLIC_KEY, "Candidate public key differs from approved identity")
    require(data["url"] == f"https://github.com/niujt/CodexMeter/releases/download/v{version}/{name}", "Unexpected planned download URL")
    archive = root / "output" / name
    require(archive.is_file() and not archive.is_symlink(), "Missing candidate archive")
    return data, archive


def signed_feed(data):
    # Sparkle 2.10.0 common_cli/Signing.swift appends this exact signing block.
    # Be stricter than the runtime parser: reject duplicates or trailing bytes.
    require(data.count(PREFIX) == 1, "Expected exactly one signed feed block")
    content, _, block = data.rpartition(PREFIX)
    match = re.fullmatch(rb"edSignature: ([A-Za-z0-9+/]{86}==)\nlength: ([0-9]+)\n-->\n", block)
    require(match is not None, "Malformed or trailing signed feed data")
    require(int(match[2]) == len(content), "Signed feed length mismatch")
    require(b"<!DOCTYPE" not in content.upper() and b"<!ENTITY" not in content.upper(), "External XML declarations are forbidden")
    return content, match[1].decode("ascii")


def enclosure(content, data, size):
    document = ET.fromstring(content)
    require(document.tag == "rss", "Expected an RSS appcast")
    items = document.findall("./channel/item")
    require(len(items) == 1, "Expected exactly one candidate item")
    item = items[0]
    require(item.findtext(NS + "channel") == "ci-candidate", "Refusing a stable-channel candidate feed")
    require(item.findtext(NS + "version") == data["build"], "Feed build differs from candidate")
    require(item.findtext(NS + "shortVersionString") == data["version"], "Feed version differs from candidate")
    require(item.findtext(NS + "minimumSystemVersion") == "15.0", "Unexpected minimum macOS version")
    require(not item.findall(NS + "releaseNotesLink"), "Unexpected external release notes")
    require(not item.findall(NS + "deltas"), "Delta updates are not allowed for this candidate")
    enclosures = item.findall("enclosure")
    require(len(enclosures) == 1, "Expected exactly one candidate archive")
    entry = enclosures[0]
    require(entry.get("url") == data["url"], "Feed archive URL mismatch")
    require(entry.get("length") == str(size), "Feed archive length mismatch")
    signature = entry.get(NS + "edSignature", "")
    require(re.fullmatch(r"[A-Za-z0-9+/]{86}==", signature), "Missing archive Ed25519 signature")
    return signature


def sign(root, generator):
    data, archive = metadata(root)
    require(not (root / "output/appcast.xml").exists(), "Refusing to overwrite an existing feed")
    require(list((root / "output").iterdir()) == [archive], "Signing directory must contain only the candidate DMG")
    secret = os.environ.pop("SPARKLE_PRIVATE_KEY", "").strip()
    require(bool(secret), "SPARKLE_PRIVATE_KEY is not configured; no signing occurred")
    try:
        decoded = base64.b64decode(secret, validate=True)
    except (ValueError, TypeError):
        raise CandidateError("SPARKLE_PRIVATE_KEY must contain the exported Sparkle base64 secret") from None
    # Official 2.10.0 common_cli/Secret.swift accepts a 32-byte seed or the legacy
    # 96-byte private/public representation. Never derive/export/log either here.
    require(len(decoded) in (32, 96), "SPARKLE_PRIVATE_KEY has an unsupported Sparkle key format")
    del decoded
    result = subprocess.run(
        [str(generator), "--ed-key-file", "-", "--maximum-deltas", "0",
         "--channel", "ci-candidate", "--download-url-prefix", data["url"].rsplit("/", 1)[0] + "/",
         "-o", str(root / "output/appcast.xml"), str(root / "output")],
        input=secret + "\n", text=True, capture_output=True, timeout=600,
        env=dict(os.environ), check=False,
    )
    del secret
    # Sparkle can echo invalid key input in error text. Never relay raw tool
    # stdout/stderr, even on success; neither stream is saved to an artifact.
    require(result.returncode == 0, "Official generate_appcast failed; raw output suppressed to protect signing material")
    del result
    require((root / "output/appcast.xml").is_file(), "Sparkle did not generate an appcast")
    print("Candidate signing step completed; independent public-key verification is still required")


def verify(root, verifier):
    require("SPARKLE_PRIVATE_KEY" not in os.environ, "Public verification must not receive a private key")
    data, archive = metadata(root)
    feed = root / "output/appcast.xml"
    require(feed.is_file() and not feed.is_symlink(), "Missing signed candidate feed")
    content, feed_signature = signed_feed(feed.read_bytes())
    archive_signature = enclosure(content, data, archive.stat().st_size)
    verification = root / "public-verification"
    verification.mkdir(exist_ok=False)
    content_path = verification / "feed-content.xml"
    content_path.write_bytes(content)
    for path, signature in ((content_path, feed_signature), (archive, archive_signature)):
        result = subprocess.run([str(verifier), str(path), signature], capture_output=True, check=False)
        require(result.returncode == 0, "Candidate signature does not match the approved public key")
        altered = bytearray(base64.b64decode(signature))
        altered[0] ^= 1
        invalid = base64.b64encode(altered).decode("ascii")
        result = subprocess.run([str(verifier), str(path), invalid], capture_output=True, check=False)
        require(result.returncode != 0, "Verifier accepted a tampered signature")
    output = root / "output"
    hashes = [f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}\n" for path in (archive, feed)]
    (output / "SHA256SUMS.txt").write_text("".join(hashes))
    (output / "VALIDATION.txt").write_text(
        f"TEST CANDIDATE ONLY: Codex Health {data['version']} (build {data['build']})\n"
        "Ad-hoc code signatures; NOT Apple Development or Developer ID signed; NOT notarized.\n"
        "PASS: universal app/Widget/Sparkle structure, matching ad-hoc App Groups, nested codesign verification, DMG layout.\n"
        "PASS: DMG and feed Ed25519 signatures verified with the approved fixed public key; tampered signatures rejected.\n"
        "Feed is restricted to ci-candidate; its download URL is planned, not a published release.\n"
        "NOT PROVEN: Gatekeeper acceptance, Widget registration, existing App Group data access, settings/data preservation, installation or restart.\n"
        "A development-signed existing Widget may use a different Team-prefixed container. No user data was moved or deleted.\n"
        "Version 1.0.8 has no updater and requires one manual migration installation.\n"
        "Do not publish this candidate as the stable feed or claim it is release-ready.\n"
    )
    print("PASS: signed feed and DMG match the approved public key; tamper checks passed")


def self_test():
    class FeedTests(unittest.TestCase):
        def test_valid_and_invalid_blocks(self):
            content = b'<rss version="2.0"/>'
            signature = base64.b64encode(bytes(64))
            block = PREFIX + b'edSignature: ' + signature + b'\nlength: ' + str(len(content)).encode() + b'\n-->\n'
            self.assertEqual(signed_feed(content + block), (content, signature.decode()))
            for invalid in (content, content + block + b'extra', content + block + block,
                            content + block.replace(str(len(content)).encode(), b'999')):
                with self.assertRaises(CandidateError):
                    signed_feed(invalid)

        def test_channel_url_version_and_signature_guards(self):
            signature = base64.b64encode(bytes(64)).decode()
            data = dict(build='17', version='1.0.9', url='https://example.invalid/candidate.dmg')
            xml = f'''<rss xmlns:sparkle="{NS[1:-1]}"><channel><item>
              <sparkle:channel>ci-candidate</sparkle:channel><sparkle:version>17</sparkle:version>
              <sparkle:shortVersionString>1.0.9</sparkle:shortVersionString><sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
              <enclosure url="{data['url']}" length="10" sparkle:edSignature="{signature}"/>
              </item></channel></rss>'''
            self.assertEqual(enclosure(xml.encode(), data, 10), signature)
            for old, new in [('ci-candidate', 'stable'), ('>17<', '>18<'), ('>1.0.9<', '>1.1.0<'),
                             ('>15.0<', '>26.0<'), ('length="10"', 'length="11"'),
                             (data['url'], 'https://example.invalid/other.dmg'), (signature, 'missing')]:
                with self.assertRaises(CandidateError):
                    enclosure(xml.replace(old, new).encode(), data, 10)
    result = unittest.TextTestRunner().run(unittest.defaultTestLoader.loadTestsFromTestCase(FeedTests))
    require(result.wasSuccessful(), "Candidate parser self-tests failed")


if __name__ == "__main__":
    try:
        if sys.argv[1:] == ["--self-test"]:
            self_test()
        else:
            require(len(sys.argv) == 4 and sys.argv[1] in ("sign", "verify"), "usage: sign_macos_candidate.py sign|verify ROOT TOOL (or --self-test)")
            root, tool = Path(sys.argv[2]).resolve(), Path(sys.argv[3]).resolve()
            (sign if sys.argv[1] == "sign" else verify)(root, tool)
    except CandidateError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        sys.exit(1)
    except Exception:
        # Do not display exceptions that might retain subprocess output or keys.
        print("ERROR: Candidate processing failed; sensitive diagnostics suppressed", file=sys.stderr)
        sys.exit(1)
