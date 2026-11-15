# Extracted source validation

The tested code is pinned in `manifest.json`. Later receipt commits change documentation only. This is review staging, not an IPA release gate.

| Check | Result | Evidence |
| --- | --- | --- |
| Standalone engine extraction | Pass: checked groups, precise faults/reference policy, MMU, JIT publication, ring, IJC eviction, retention and branch-site regressions | [43724598061](https://github.com/stride-praline-2f-ai/henge-/actions/runs/43724598061) |
| Complete app from preserved upstream source | Pass: unsigned Release compilation; no IPA generated | [43724794272, app job](https://github.com/stride-praline-2f-ai/henge-/actions/runs/43724794272) |
| Native combined suite | Failed strict saved half-float render-archive hit assertion at `test_pvg_lifecycle.m:118`; normal compilation recovered | Same run, native job |
| Independent API, input, Link, USB and disk checks | Passed; raw public Metal independently missed saved render/compute functions while all four pipelines executed via fallback | [43725203923](https://github.com/stride-praline-2f-ai/henge-/actions/runs/43725203923) |
| ASan/UBSan, TSan and primitive checks | All checks executed; production GPU lifecycle also passed on this worker. One statistics invocation lacked the regular fixture in this isolated job | Same followup; the failure is retained in its result |
| Statistics lifecycle, scans off/on | Pass after explicitly building the required fixture | [43725962234](https://github.com/stride-praline-2f-ai/henge-/actions/runs/43725962234) |

No assertion was removed or relaxed. The archive-hit failure remains unresolved for the review gate: the independent cloud-adapter failure is concrete evidence of a platform limitation, but does not prove every possible cache integration issue absent. Do not label the combined suite green or claim universal persistent pipeline hits. Actual physical M4/Duo archive behavior still needs checking.

The full source preserves current upstream translation-layer files, legacy iOS17 library compatibility and the original deployment target. Older-device behavior has compiled but has not run on a physical iOS17 device. Compiler deprecation/concurrency warnings remain for review; successful compilation is not a warning-free or physical-device validation claim.

Direct PR creation in `Leviidev/Henge` returned HTTP403. All twelve PR numbers in this series belong to `stride-praline-2f-ai/Henge`. Its `main` remains the clean upstream baseline. Upstream submission links and dependencies are in each draft. No release branch, version, bundle identity or IPA artifact was replaced.
