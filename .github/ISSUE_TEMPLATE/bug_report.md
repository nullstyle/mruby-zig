---
name: Bug report
about: Something behaves incorrectly or crashes
title: ""
labels: bug
assignees: ""
---

**Build profile**
- Zig version (`zig version`):
- gem set (standard/minimal/custom `-Dwith-gems`/`-Dwithout-gems`):
- optimize mode, `-Dno-compiler`, sanitizer flags:

**Reproducer**
A minimal Zig (and Ruby, if guest code is involved) reproduction:

```zig
```

**Observed vs expected**
For worker/artifact failures, include the exact error classification
(e.g. `error.ProtocolMismatch`, `.limit = .process_cpu`) and not just
the message text.

