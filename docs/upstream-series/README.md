# Custom Henge contribution series

Source fork: `stride-praline-2f-ai/Henge`. Build repository: `stride-praline-2f-ai/henge-`. Upstream baseline: `e98920ce3b108d17f98acaff87f74e5a477ec4b2`.

These are fork-local extraction drafts. Direct PR creation in `Leviidev/Henge` returned HTTP403 `Resource not accessible by integration`. They are not upstream PR numbers.

Each PR targets the preceding topic branch so its diff stays focused. The final app integration supplies the shared native/Swift/build activation. Intermediate extraction checkpoints are not independently complete applications; review the full dependency chain before merging. Do not merge these into the fork main merely to submit upstream.

| Draft | Topic | Review base |
| --- | --- | --- |
| [#1](https://github.com/stride-praline-2f-ai/Henge/pull/1) | Engine: checked memory reuse and selective JIT cache eviction | `main` |
| [#2](https://github.com/stride-praline-2f-ai/Henge/pull/2) | VM: event-driven idle, lifecycle, audio and network recovery | `contribute/engine-memory-jit` |
| [#3](https://github.com/stride-praline-2f-ai/Henge/pull/3) | Instant Resume: coordinated pause, validated saves and recovery | `contribute/vm-lifecycle-idle` |
| [#4](https://github.com/stride-praline-2f-ai/Henge/pull/4) | Storage: scattered I/O, coherent DMA and recoverable disk growth | `contribute/instant-resume` |
| [#5](https://github.com/stride-praline-2f-ai/Henge/pull/5) | Graphics: native Metal replay, Metal4, caching and demand-driven presentation | `contribute/storage-io-growth` |
| [#6](https://github.com/stride-praline-2f-ai/Henge/pull/6) | Display: Retina geometry, iPad fitting and Duo/external-screen transitions | `contribute/native-metal-presentation` |
| [#7](https://github.com/stride-praline-2f-ai/Henge/pull/7) | Input: USB native touch, Pencil and reliable keyboard/trackpad transitions | `contribute/display-layout` |
| [#8](https://github.com/stride-praline-2f-ai/Henge/pull/8) | Controls: virtual gamepad, sensitivity, touchpad and gyro steering | `contribute/native-touch-input` |
| [#9](https://github.com/stride-praline-2f-ai/Henge/pull/9) | Henge Link: encrypted display streaming and wireless controller mode | `contribute/virtual-gamepad` |
| [#10](https://github.com/stride-praline-2f-ai/Henge/pull/10) | Sharing: acknowledged clipboard delivery and companion recovery | `contribute/henge-link-wireless` |
| [#11](https://github.com/stride-praline-2f-ai/Henge/pull/11) | Performance: device-aware defaults, memory budgets and useful diagnostics | `contribute/clipboard-sharing` |
| [#12](https://github.com/stride-praline-2f-ai/Henge/pull/12) | App: integrate controls, recovery and settings into the session UI | `contribute/device-policy-diagnostics` |

## Validation boundaries

The shipped custom aggregate passed native, sanitizer and Release app checks in [43719589751](https://github.com/stride-praline-2f-ai/henge-/actions/runs/43719589751). That historical result does not validate this extraction: current upstream Mac Apps code and legacy iOS17 library loading are retained here. Exact extracted-engine and full-series checks run separately in the build repository; consult their actual results before marking drafts ready.

Cloud arm64 Macs do not verify physical M4/Duo energy, folding, Pencil behavior, radio reconnects, Metal4 availability or every macOS game. No hardware FPS/heat claim is implied. No IPA or release action is added by this series.

## Provenance

Retain upstream ownership when reconciling: engine ring/sysregs #186 and shared-region #157 (Oliver Ames); network batching #176; stopped-Mac disk growth #139; Duo display #108 (itsAllexB); earlier kesku native-touch work and reviewed USB successor `385a4f6e4c60916ccff70ef736eda9d6cabe2932`. The individual drafts identify related open PRs. Imported groundwork is not claimed as original work.

Historical personal-device log captures, build-wrapper patches, IPA/Drive automation and release branding are deliberately excluded. New upstream translation-layer files, upstream workflows, bundle identity and supported deployment target remain intact.
