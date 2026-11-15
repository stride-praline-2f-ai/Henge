#!/usr/bin/env python3
"""Build-time experiments only. Normal builds do not change gaming metadata or entitlements."""
import argparse, fnmatch, plistlib, subprocess
from pathlib import Path

def validate_sustained(profile, bundle, existing):
    ent = profile.get('Entitlements', {})
    allowed = ent.get('application-identifier', '')
    if not allowed or not fnmatch.fnmatchcase(bundle, allowed.split('.', 1)[-1]):
        raise ValueError('Provisioning profile does not match this bundle identifier')
    if ent.get('com.apple.developer.sustained-execution') is not True:
        raise ValueError('Provisioning profile does not authorize sustained execution')
    for k,v in existing.items():
        if k not in ent or ent[k] != v:
            raise ValueError('Profile does not authorize existing entitlement: '+k)
    return {**existing, 'com.apple.developer.sustained-execution': True}

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--info',type=Path,required=True)
    ap.add_argument('--game-mode',action='store_true')
    ap.add_argument('--sustained-profile',type=Path)
    ap.add_argument('--entitlements',type=Path)
    ap.add_argument('--out-entitlements',type=Path)
    a=ap.parse_args(); info=plistlib.loads(a.info.read_bytes())
    if a.sustained_profile:
        if not a.entitlements or not a.out_entitlements:ap.error('Explicit input/output entitlement files are required')
        profile=plistlib.loads(subprocess.check_output(['security','cms','-D','-i',str(a.sustained_profile)]))
        out=validate_sustained(profile,info['CFBundleIdentifier'],plistlib.loads(a.entitlements.read_bytes()))
        if a.out_entitlements.resolve()==a.entitlements.resolve():ap.error('Do not overwrite the normal signing file')
        a.out_entitlements.write_bytes(plistlib.dumps(out))
        print('Profile authorizes requested keys; actual signing/install and device support still require validation')
    if a.game_mode:
        info['LSSupportsGameMode']=True
        a.info.write_bytes(plistlib.dumps(info))
        print('Game Mode availability opt-in added; recognition, activation and energy effect are not established')
if __name__=='__main__':main()
