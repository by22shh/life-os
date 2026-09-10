#!/usr/bin/env python3
"""Bundle build-declared capabilities; system authorization remains authoritative.

App Store packages do not contain embedded.mobileprovision. Use the same
entitlements input as code signing, expanding build variables before signing.
"""
import os
import pathlib
import plistlib
import re

source = pathlib.Path(os.environ['SRCROOT']) / os.environ['CODE_SIGN_ENTITLEMENTS']
text = source.read_text()
text = re.sub(r'\$\(([^)]+)\)', lambda match: os.environ.get(match[1], ''), text)
capabilities = plistlib.loads(text.encode())
destination = pathlib.Path(os.environ['TARGET_BUILD_DIR']) / os.environ['UNLOCALIZED_RESOURCES_FOLDER_PATH'] / 'RuntimeCapabilities.plist'
destination.parent.mkdir(parents=True, exist_ok=True)
destination.write_bytes(plistlib.dumps(capabilities))
