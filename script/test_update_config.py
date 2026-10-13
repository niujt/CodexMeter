#!/usr/bin/env python3
"""Synthetic checks for the release configuration gate; no secrets/network/user data."""
import base64
import unittest
from validate_update_config import FEED, validate


class UpdateConfigurationTests(unittest.TestCase):
    def info(self):
        return dict(SUFeedURL=FEED,
                    SUPublicEDKey=base64.b64encode(bytes([1]) * 32).decode(),
                    SURequireSignedFeed=True, SUVerifyUpdateBeforeExtraction=True,
                    SUSignedFeedFailureExpirationInterval=0, CFBundleVersion="17")

    def test_valid_configuration(self):
        self.assertEqual(validate(self.info()), [])

    def test_unconfigured_build_rejected(self):
        self.assertTrue(validate({}))

    def test_wrong_feed_rejected(self):
        for feed in (FEED.replace("https:", "http:"), FEED + "?token=x",
                     FEED.replace("macos", "windows"), FEED.replace("niujt", "other"), "$(FEED)"):
            with self.subTest(feed=feed):
                info = self.info()
                info["SUFeedURL"] = feed
                self.assertTrue(validate(info))

    def test_placeholder_keys_rejected(self):
        for key in ("", "REPLACE_ME", base64.b64encode(bytes(32)).decode(),
                    base64.b64encode(bytes([1]) * 31).decode()):
            info = self.info()
            info["SUPublicEDKey"] = key
            self.assertTrue(validate(info))

    def test_both_signature_checks_required(self):
        for setting in ("SURequireSignedFeed", "SUVerifyUpdateBeforeExtraction"):
            info = self.info()
            info[setting] = False
            self.assertTrue(validate(info))

    def test_signature_expiration_disabled(self):
        info = self.info()
        info["SUSignedFeedFailureExpirationInterval"] = 1728000
        self.assertTrue(validate(info))
        del info["SUSignedFeedFailureExpirationInterval"]
        self.assertTrue(validate(info))

    def test_build_number_required(self):
        for version in ("", "0", "1.0.0", "-1", "17beta"):
            info = self.info()
            info["CFBundleVersion"] = version
            self.assertTrue(validate(info))


if __name__ == "__main__":
    unittest.main()
