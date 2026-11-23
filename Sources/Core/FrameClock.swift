import Foundation

/// Names exact frames of the source recording, for picking stills by eye.
public enum FrameClock {
    /// The index of the frame on screen at source time `t` (frame n shows from n/fps
    /// until (n+1)/fps). A hair of slack absorbs times that land a rounding error
    /// before a frame's start, as seeks to a frame's start do.
    public static func frame(at t: Seconds, fps: Double) -> Int {
        guard fps > 0 else { return 0 }
        return max(Int((t * fps + 1e-3).rounded(.down)), 0)
    }

    /// A source time inside frame `n`, in whole milliseconds: its middle, so the
    /// millisecond rounding `still=` keeps can't slip onto the neighbouring frame.
    public static func time(ofFrame n: Int, fps: Double) -> Seconds {
        guard fps > 0 else { return 0 }
        return ((Double(n) + 0.5) / fps * 1000).rounded() / 1000
    }

    /// `hh:mm:ss.mmm`, the form `still=` takes.
    public static func timestamp(_ t: Seconds) -> String {
        let ms = Int((max(t, 0) * 1000).rounded())
        return String(format: "%02d:%02d:%02d.%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000)
    }
}
