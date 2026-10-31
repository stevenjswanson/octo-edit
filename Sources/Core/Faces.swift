import Foundation

/// One detected face in one sampled frame. Coordinates are fractions of the frame,
/// origin top-left. No face fingerprints are kept: boxes and mouth shape only.
public struct FaceBox: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double
    /// Inner-lip height and outer-lip width as fractions of the face box; nil when
    /// the landmarks weren't found.
    public var mouthOpen: Double?
    public var mouthWidth: Double?

    public init(x: Double, y: Double, w: Double, h: Double, mouthOpen: Double? = nil, mouthWidth: Double? = nil) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
        self.mouthOpen = mouthOpen
        self.mouthWidth = mouthWidth
    }

    public var centerX: Double { x + w / 2 }
    public var centerY: Double { y + h / 2 }
}

/// The faces in one sampled frame, and how different the frame looks from the one
/// sampled before it (mean luma difference on a tiny thumbnail, 0–255): a large
/// difference is a cut in the source.
public struct FaceFrame: Equatable, Sendable {
    public var t: Seconds
    public var change: Double
    public var faces: [FaceBox]

    public init(t: Seconds, change: Double, faces: [FaceBox]) {
        self.t = t
        self.change = change
        self.faces = faces
    }
}

/// Faces through the video, sampled a few times a second. A regenerable cache.
public struct FaceTracks: Equatable, Sendable {
    /// The video frame in pixels (display orientation).
    public var width: Int
    public var height: Int
    public var frames: [FaceFrame]

    public init(width: Int, height: Int, frames: [FaceFrame]) {
        self.width = width
        self.height = height
        self.frames = frames
    }
}

/// Finds faces through a video.
public protocol FaceScanner: Sendable {
    func scan(video: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> FaceTracks
}
