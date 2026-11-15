import Foundation

/// How good one exact video frame is as a title card's picture, for the face nearest
/// the box it was asked about. All scores are 0…1, higher is better.
public struct StillScore: Equatable, Sendable {
    /// Source time of the frame (as asked for).
    public var t: Seconds
    /// Vision's face capture quality: sharpness, lighting, pose, expression.
    public var quality: Double
    /// How open the eyes are (0 closed or not found, 1 wide open).
    public var eyes: Double
    /// How closed the mouth is (1 closed, 0 mid-word or wide open).
    public var mouth: Double
    /// The face that was scored, if one was found near the box.
    public var face: FaceBox?

    public init(t: Seconds, quality: Double, eyes: Double, mouth: Double, face: FaceBox?) {
        self.t = t
        self.quality = quality
        self.eyes = eyes
        self.mouth = mouth
        self.face = face
    }

    /// The overall score: a closed-eyed or mid-word frame loses however sharp it is.
    public var total: Double { face == nil ? 0 : quality * eyes * (0.25 + 0.75 * mouth) }
}

/// Scores exact frames of a video (Vision, in FaceTrack).
public protocol StillScorer: Sendable {
    /// One score per request, in order: the frame at `t`, judged on the face nearest `near`
    /// (or the largest face when `near` is nil).
    func score(video: URL, _ requests: [(t: Seconds, near: FaceBox?)]) async throws -> [StillScore]
}
