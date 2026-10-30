#!/usr/bin/env python3
"""Extract the shared hot-water platform profile from the official public Beta 2 IPA.

The upstream release notes state that the public IPA carries the shared platform
parameters (no personal account, dorm or controller data). This copies only that
file, after checking the IPA's SHA-256 against the release's checksum file, into
private/distribution/WaterPlatformProfile.json (Git-ignored). Never commit or
share the output.
"""
from pathlib import Path
import hashlib
import io
import os
import sys
import urllib.request
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from stage_platform_profile import validate_profile  # noqa: E402

root = Path(__file__).resolve().parents[1]
output = root / 'private/distribution/WaterPlatformProfile.json'
base = 'https://github.com/JasonBeam/campus-daily/releases/download/v0.8.0-beta.2/'
ipa_name = 'CampusDaily-0.8.0-build36-unsigned.ipa'
member = 'Payload/CampusHotWater.app/CampusWaterPlatform.json'

if output.exists():
    raise SystemExit(f'{output.relative_to(root)} already exists; keep it, or delete it to fetch again.')


def fetch(url: str, limit: int) -> bytes:
    with urllib.request.urlopen(url, timeout=60) as response:
        data = response.read(limit + 1)
    if len(data) > limit:
        raise SystemExit('Download exceeds size limit.')
    return data


checksum = fetch(base + ipa_name + '.sha256', 4096).decode().split()[0].lower()
ipa = fetch(base + ipa_name, 50 * 1024 * 1024)
if hashlib.sha256(ipa).hexdigest() != checksum:
    raise SystemExit('SHA-256 mismatch; nothing was written.')
with zipfile.ZipFile(io.BytesIO(ipa)) as z:
    try:
        raw = z.read(member)
    except KeyError:
        raise SystemExit('The release IPA has no platform profile; nothing was written.')
try:
    value = validate_profile(raw)
except ValueError as error:
    raise SystemExit(f'Profile failed validation: {error}')

output.parent.mkdir(parents=True, exist_ok=True)
with os.fdopen(os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'w') as out:
    out.write(raw.decode() if raw.endswith(b'\n') else raw.decode() + '\n')
print('Shared platform profile saved to private/distribution/ (Git-ignored). Do not commit or share it.')
