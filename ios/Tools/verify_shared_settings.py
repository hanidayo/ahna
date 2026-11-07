"""Check actual Mac-signed shared Keychain configuration. Does not prove runtime access."""
import json
import plistlib
import subprocess
import sys
from pathlib import Path

def check(app):
    content = app / 'Contents' if (app / 'Contents').is_dir() else app
    bundles = [app, content / 'PlugIns/AhnaShare.appex']
    records = []
    for bundle in bundles:
        info_path = bundle / 'Contents/Info.plist' if (bundle / 'Contents').is_dir() else bundle / 'Info.plist'
        info = plistlib.loads(info_path.read_bytes())
        group = info.get('AhnaKeychainGroup', '')
        if not group or '$(' in group:
            raise ValueError(f'{bundle.name}: unresolved shared group in Info.plist')
        result = subprocess.run(['/usr/bin/codesign', '-d', '--entitlements', ':-', str(bundle)], capture_output=True, check=True)
        entitlements = plistlib.loads(result.stdout)
        if group not in entitlements.get('keychain-access-groups', []):
            raise ValueError(f'{bundle.name}: signed entitlements do not grant the configured shared group')
        records.append(dict(bundle=bundle.name, group=group, identifier=info['CFBundleIdentifier'], version=info['CFBundleShortVersionString']))
    if records[0]['group'] != records[1]['group']:
        raise ValueError('Containing app and share extension do not use the same shared group')
    return dict(groupsMatch=True, signedEntitlementsInspected=True, runtimeKeychainAccessTested=False, bundles=records)

if __name__ == '__main__':
    print(json.dumps(check(Path(sys.argv[1])), ensure_ascii=False, indent=2))
