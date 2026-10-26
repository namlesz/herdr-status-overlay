import Darwin

/// Nanoseconds of `mach_continuous_time`, which keeps counting during sleep.
public enum MonotonicClock {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    public static func now() -> UInt64 {
        let ticks = mach_continuous_time()
        let numer = UInt64(timebase.numer), denom = UInt64(timebase.denom)
        // Divide before multiplying so the conversion cannot overflow.
        return ticks / denom * numer + ticks % denom * numer / denom
    }
}

public func seconds(_ value: Double) -> UInt64 { UInt64(value * 1_000_000_000) }

/// Elapsed time that never underflows when timestamps arrive out of order.
func elapsed(since start: UInt64, now: UInt64) -> UInt64 { now >= start ? now - start : 0 }
