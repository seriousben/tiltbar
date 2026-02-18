# AGENTS.md

## TiltClient Async/Concurrency Guidelines

The watch loop in `TiltClient.swift` has been a source of recurring bugs. Follow these rules strictly.

### Never block Swift's cooperative thread pool

`Task {}` and `Task.detached {}` run on Swift's cooperative thread pool, which has a small fixed number of threads (≈ CPU core count). Blocking any of them (e.g., with `Process.waitUntilExit()`) can starve async continuations like `Task.sleep`, causing the watch loop retry to silently freeze.

- **Use `DispatchQueue.global().async`** for any work that calls blocking APIs (`waitUntilExit()`, `readDataToEndOfFile()`, synchronous network calls).
- **Use `Task.detached`** only for purely async work with no blocking calls.

### Pipe buffer deadlock

When using `Process` with `Pipe` for stdout/stderr, always call `readDataToEndOfFile()` **before** `waitUntilExit()`. If the process outputs >64KB, the pipe buffer fills, the process blocks on write, and `waitUntilExit()` waits forever.

```swift
// ✅ Correct: read drains pipe while process runs
try process.run()
let data = pipe.fileHandleForReading.readDataToEndOfFile()
process.waitUntilExit()

// ❌ Wrong: deadlocks if output > 64KB
try process.run()
process.waitUntilExit()
let data = pipe.fileHandleForReading.readDataToEndOfFile()
```

### Task.sleep error handling

Never use `try?` with `Task.sleep` — it silently swallows `CancellationError`, hiding why the retry loop stopped. Use explicit `do/catch` and log the error.

```swift
// ✅ Correct
do {
    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
} catch {
    tiltLog("Sleep interrupted (isCancelled: \(Task.isCancelled)): \(error)")
    if Task.isCancelled { break }
}

// ❌ Wrong: silent failure
try? await Task.sleep(for: .seconds(delay))
```
