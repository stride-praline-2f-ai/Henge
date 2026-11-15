import importlib.util
from pathlib import Path
p=Path(__file__).resolve().parents[1]/'tools/configure_gaming_experiments.py'
s=importlib.util.spec_from_file_location('gaming',p);m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
key='com.apple.developer.sustained-execution'
profile={'Entitlements':{'application-identifier':'TEAM.com.henge.*',key:True,'get-task-allow':True}}
assert m.validate_sustained(profile,'com.henge.app',{'get-task-allow':True})[key]
for bad in [{'Entitlements':{}},{'Entitlements':{'application-identifier':'TEAM.other.*',key:True}}, {'Entitlements':{'application-identifier':'TEAM.com.henge.*'}}]:
 try:m.validate_sustained(bad,'com.henge.app',{});raise AssertionError('accepted unauthorized profile')
 except ValueError:pass
try:m.validate_sustained(profile,'com.henge.app',{'dynamic-codesigning':True});raise AssertionError('removed signing requirement')
except ValueError:pass
print('gaming experiments: profile/bundle/key authorization and preservation of existing signing requirements passed (fixtures only)')

import tempfile,plistlib,subprocess,sys
with tempfile.TemporaryDirectory() as tmp:
 info=Path(tmp)/'Info.plist'; data=plistlib.dumps({'CFBundleIdentifier':'com.henge.app','Existing':'preserved'});info.write_bytes(data)
 subprocess.run([sys.executable,str(p),'--info',str(info)],check=True);assert info.read_bytes()==data
 subprocess.run([sys.executable,str(p),'--info',str(info),'--game-mode'],check=True)
 parsed=plistlib.loads(info.read_bytes());assert parsed['LSSupportsGameMode'] is True and parsed['Existing']=='preserved'
print('normal metadata unchanged and explicit Game Mode Boolean-only experiment passed')
