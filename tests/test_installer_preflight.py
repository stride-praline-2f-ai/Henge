"""Exercise production start/busy/Phase code with suspended Boot ROM preflight.
The surrounding platform/download operations are fixtures; no install is made.
Run on a Mac with Swift. --emit writes the fixture for source inspection only.
"""
from pathlib import Path
import subprocess, tempfile, sys
root=Path(__file__).resolve().parents[1]
source=(root/'ios/Henge/Installer.swift').read_text()
def member(token):
    a=source.index(token);b=source.index('{',a);depth=1;e=b+1
    while depth:
        depth += (source[e]=='{')-(source[e]=='}');e+=1
    return source[a:e]
harness=r'''
import Foundation
struct MacOSRelease: Sendable { let name="fixture" }
struct VirtualMac { var osName=""; let directory=URL(fileURLWithPath:"/unused-henge-test") }
enum FixtureError: Error { case failed }
enum HengeLog { static func log(_ group:String,_ message:String) {} }
func henge_vm_state()->Int { 1 }
@MainActor final class UIApplication {
 static let shared=UIApplication(); var isIdleTimerDisabled=false
 func beginBackgroundTask(withName name:String,expirationHandler:@escaping ()->Void)->Int { 1 }
}
@MainActor enum BootROM {
 static var calls=0
 static var waiter: CheckedContinuation<URL,Error>?
 static func file() async throws -> URL {
  calls+=1; return try await withCheckedThrowingContinuation { waiter=$0 }
 }
}
@MainActor final class Harness {
 static let shared=Harness()
 ENUM
 var phase=Phase.idle, machineName="", grace=0
 var downloads=0, installs=0
 BUSY
 func endGrace() { grace=0 }
 func checkSpace(_ release:MacOSRelease) throws {}
 func download(_ release:MacOSRelease) async throws ->URL { downloads+=1;return URL(fileURLWithPath:"/unused-henge-test") }
 func prepare(name:String,ramMB:Int,rom:URL) throws ->VirtualMac { VirtualMac() }
 func install(_ mac:VirtualMac,ipsw:URL,cpus:Int) async throws { installs+=1 }
 START
}
typealias Installer = Harness
@main struct Check {
 @MainActor static func until(_ condition:()->Bool) async throws {
  for _ in 0..<2000 { if condition(){return};try await Task.sleep(nanoseconds:1_000_000) }
  fatalError("Installer fixture timed out")
 }
 @MainActor static func main() async throws {
  let h=Harness(), release=MacOSRelease()
  h.start(release,name:"first",ramMB:8192,cpus:4,keepImage:true)
  precondition(h.busy && h.phase == .checking)
  h.start(release,name:"duplicate",ramMB:8192,cpus:4,keepImage:true)
  precondition(h.machineName=="first")
  try await until { BootROM.waiter != nil }
  precondition(BootROM.calls==1 && h.downloads==0)
  let first=BootROM.waiter!;BootROM.waiter=nil;first.resume(throwing:FixtureError.failed)
  try await until { !h.busy }
  precondition(!UIApplication.shared.isIdleTimerDisabled && h.installs==0)
  h.start(release,name:"retry",ramMB:8192,cpus:4,keepImage:true)
  try await until { BootROM.waiter != nil }
  precondition(BootROM.calls==2 && h.busy)
  let second=BootROM.waiter!;BootROM.waiter=nil;second.resume(returning:URL(fileURLWithPath:"/unused-rom-fixture"))
  try await until { !h.busy }
  precondition(h.downloads==1 && h.installs==1 && !UIApplication.shared.isIdleTimerDisabled)
  print("installer: production preflight blocks duplicate starts, failure releases busy state, retry installs once")
 }
}
'''
harness=harness.replace(' ENUM',member('enum Phase:')).replace(' BUSY',member('var busy:')).replace(' START',member('func start('))
if len(sys.argv)>1 and sys.argv[1]=='--emit':
    print(harness)
else:
    with tempfile.TemporaryDirectory(prefix='henge-install-preflight-') as tmp:
        p=Path(tmp);(p/'fixture.swift').write_text(harness)
        subprocess.run(['swiftc','-parse-as-library','-swift-version','6',str(p/'fixture.swift'),'-o',str(p/'check')],check=True)
        subprocess.run([str(p/'check')],check=True,timeout=10)
