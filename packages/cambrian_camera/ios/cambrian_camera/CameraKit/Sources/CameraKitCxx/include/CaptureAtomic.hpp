#pragma once
#include <atomic>
#include <stdbool.h>

// C++ std::atomic<bool> capture-in-flight guard.
// Invariant 7 (capture-in-flight) now owned by the C++ side; CAS semantics
// are identical to the retired Swift-side ManagedAtomic<Bool>.
// Exposed via C-ABI declared in PixelSinkCallbacks.h (capture_atomic_*).

struct CaptureAtomicImpl {
    std::atomic<bool> flag{false};
};
