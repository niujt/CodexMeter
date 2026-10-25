#!/usr/bin/env python3
import plistlib
import unittest
from pathlib import Path

from validate_widget_version import validate


class WidgetVersionTests(unittest.TestCase):
    def test_rejects_previous_layout_that_produced_successful_but_unusable_timelines(self):
        app = {"CFBundleShortVersionString": "1.0.19", "CFBundleVersion": "29"}
        self.assertIn("Widget CFBundleVersion must match its registered short version", validate(app, app))

    def test_widget_registration_and_app_update_order_use_independent_versions(self):
        for build in ["30", "31"]:
            app = {"CFBundleShortVersionString": "1.0.20", "CFBundleVersion": build}
            widget = {"CFBundleShortVersionString": "1.0.20", "CFBundleVersion": "1.0.20"}
            self.assertEqual(validate(app, widget), [])

    def test_mismatched_marketing_version_and_non_monotonic_app_build_are_rejected(self):
        app = {"CFBundleShortVersionString": "1.0.20", "CFBundleVersion": "1.0.20"}
        widget = {"CFBundleShortVersionString": "1.0.19", "CFBundleVersion": "1.0.19"}
        self.assertEqual(len(validate(app, widget)), 3)

    def test_release_sources_satisfy_version_contract(self):
        resources = Path(__file__).resolve().parents[1] / "Resources"
        app = plistlib.loads((resources / "Info.plist").read_bytes())
        widget = plistlib.loads((resources / "WidgetInfo.plist").read_bytes())
        self.assertEqual(validate(app, widget), [])


if __name__ == "__main__":
    unittest.main()
