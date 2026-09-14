# JITTestApp

A standalone iOS diagnostic application for validating **Just-In-Time (JIT) compilation** and dynamic code execution on Apple Silicon (ARM64) devices across iOS 15 through iOS 26.

---

## Overview

Modern iOS versions restrict dynamic code generation via kernel-level code-signing enforcements and memory protection flags. `JITTestApp` performs a dual-stage diagnostic verification to deterministically confirm whether JIT execution has been enabled (e.g., via SideStore, AltStore, or a remote `debugserver`/`debug_proxy` bridge).

---

## Verification Methodology

`JITTestApp` uses a two-step validation pipeline:

### 1. Kernel Code-Signing Status (`csops`)
Queries the XNU kernel using the `csops` syscall (`CS_OPS_STATUS = 0`) to check if the current process has the `CS_DEBUGGED` flag (`0x10000000`) active:
```swift
var flags: UInt32 = 0
let csResult = csops(getpid(), 0, &flags, MemoryLayout<UInt32>.size)
let isCsDebugged = (csResult == 0) && ((flags & 0x10000000) != 0)
```

### 2. Dynamic RWX Machine Code Execution
Validates real-world dynamic machine code generation:
1. **Allocate Memory**: Allocates an anonymous memory page via `mmap(PROT_READ | PROT_WRITE)`.
2. **Emit ARM64 Instructions**: Writes binary opcodes for `mov x0, #42` (`0xd2800540`) followed by `ret` (`0xd65f03c0`).
3. **Change Protection (W^X transition)**: Calls `mprotect(PROT_READ | PROT_EXEC)`. If JIT is disabled, this fails with `EACCES` / `EPERM`.
4. **Execute**: Casts the executable page pointer to a `@convention(c) () -> Int` function pointer, invokes it, and validates the expected return value (`42`).

---

## Building Locally

### Prerequisites
- macOS with Xcode 15+ (tested on Xcode 16 / 26)
- iOS 15.0+ physical device or simulator

### Setup Code Signing

1. Copy the sample configuration:
   ```bash
   cp CodeSigning.xcconfig.sample CodeSigning.xcconfig
   ```
2. Open `CodeSigning.xcconfig` and enter your Apple Developer Team ID and preferred Bundle ID prefix:
   ```xcconfig
   DEVELOPMENT_TEAM = YOUR_TEAM_ID
   ORG_IDENTIFIER = com.yourdomain
   ```
   *(Note: `CodeSigning.xcconfig` is git-ignored to prevent accidental commits of personal credentials).*

### CLI Build (`build.sh`)
To produce an unsigned or ad-hoc signed IPA:
```bash
# Build release IPA
./build.sh

# Clean build with custom output
./build.sh --clean --output JITTestApp_v1.0.0.ipa
```

---

## Sideloading via SideStore

1. Download or build `JITTestApp.ipa`.
2. Transfer and install `JITTestApp.ipa` using **SideStore**.
3. Open `JITTestApp` and tap **Verify JIT Status** (status will show as *JIT Inactive*).
4. Return to SideStore, open the **My Apps** tab, hold down `JITTestApp`, and select **Enable JIT**.
5. Switch back to `JITTestApp` — the status will update to **JIT Enabled** with verified ARM64 machine execution.

---

## Disclaimer

This tool is provided for **educational and diagnostic testing purposes only**.

---

## License

`JITTestApp` is licensed under the **GNU Affero General Public License v3.0 (AGPLv3)**.

Copyright © 2026 Magesh K. All rights reserved.
