import Foundation
final class State: @unchecked Sendable {
 let lock = NSLock()
 var writes = 0
 func bump() -> Bool { lock.lock(); defer { lock.unlock() }; writes += 1; return true }
 func count() -> Int { lock.lock(); defer { lock.unlock() }; return writes }
}
@main struct Test {
 static func main() {
  let q = PreviewWorkQueue(), s = State()
  for _ in 0..<1000 { q.save(path: "one", frame: { 10 }, write: { s.bump() }) }
  q.drain(); precondition(s.count() == 1)
  q.save(path: "one", frame: { 11 }, write: { s.bump() }); q.drain(); precondition(s.count() == 2)
  q.save(path: "two", frame: { 11 }, write: { s.bump() }); q.drain(); precondition(s.count() == 3)
  q.beginSession(); q.save(path: "two", frame: { 11 }, write: { s.bump() }); q.drain(); precondition(s.count() == 4)
  q.save(path: "two", frame: { 12 }, write: { false })
  q.save(path: "two", frame: { 12 }, write: { s.bump() }); q.drain(); precondition(s.count() == 5)
  q.save(path: "two", frame: { 13 }, write: { s.bump() })
  q.finish { precondition(s.count() == 6); return s.bump() }; precondition(s.count() == 7)
  print("preview queue: 1000 unchanged requests -> one write; changed frames, VM restart, failure retry and final-write ordering passed")
 }
}
