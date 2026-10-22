#!/usr/bin/env python3
"""Exercise the actual signing step in macOS Bash without keys, packages or network."""
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import textwrap
import unittest


class SigningWorkflowTests(unittest.TestCase):
    def arguments(self, release_tag):
        workflow = (Path(__file__).resolve().parent.parent /
                    '.github/workflows/macos-public-update-config.yml').read_text()
        step = workflow.split('      - name: Reuse the configured signing Secret and export public files only\n', 1)[1]
        script = textwrap.dedent(step.split('        run: |\n', 1)[1].split('\n      - ', 1)[0])
        stub = ('python3() { ' + shlex.quote(sys.executable) +
                ' -c \'import json,sys; print(json.dumps(sys.argv[1:]))\' "$@"; }\n')
        env = dict(PATH=os.defpath, RUNNER_TEMP='/synthetic/with spaces', RELEASE_TAG=release_tag,
                   RELEASE_VERSION='1.0.14', RELEASE_BUILD='23', PACKAGE_SHA256='synthetic-digest')
        result = subprocess.run(['/bin/bash', '-c', stub + script], env=env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_configuration_only_signing_has_no_empty_array_expansion(self):
        arguments = self.arguments('')
        self.assertEqual(arguments[0], 'script/export_macos_update_config.py')
        self.assertNotIn('--package', arguments)
        self.assertNotIn('--release-tag', arguments)
        self.assertEqual(arguments[arguments.index('--output') + 1], '/synthetic/with spaces/macos-update-public')

    def test_package_signing_preserves_all_reviewed_package_arguments(self):
        arguments = self.arguments('macos-v1.0.14')
        self.assertEqual(arguments[arguments.index('--release-tag') + 1], 'macos-v1.0.14')
        self.assertEqual(arguments[arguments.index('--package') + 1],
                         '/synthetic/with spaces/release-package/CodexMeter-1.0.14-macos.dmg')
        self.assertEqual(arguments[arguments.index('--version') + 1], '1.0.14')
        self.assertEqual(arguments[arguments.index('--build') + 1], '23')
        self.assertEqual(arguments[arguments.index('--expected-sha256') + 1], 'synthetic-digest')


if __name__ == '__main__':
    unittest.main()
