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
    /// How far apart the lips are: the inner-lip outline's height as a fraction of the
    /// face box (nil when Vision found no lips). Kept raw so `mouth` can be retuned
    /// without decoding the frames again.
    public var lips: Double?
    /// The face that was scored, if one was found near the box.
    public var face: FaceBox?

    public init(t: Seconds, quality: Double, eyes: Double, lips: Double?, face: FaceBox?) {
        self.t = t
        self.quality = quality
        self.eyes = eyes
        self.lips = lips
        self.face = face
    }

    /// How closed the mouth is (1 closed, 0 mid-word or wide open; 0.5 when unknown).
    public var mouth: Double { lips.map(Self.closedness) ?? 0.5 }

    /// Lip gap → closedness. Measured on three speakers' faces (Taitano, Pugh, Guo):
    /// closed lips read 0.003–0.025 (it varies a lot by face: lip shape, a resting
    /// smile), slightly parted 0.03–0.035, open mid-word 0.04 and up. Half at 0.027.
    public static func closedness(_ lips: Double) -> Double { 1 / (1 + exp((lips - 0.027) / 0.004)) }

    /// The overall score: a closed-eyed or mid-word frame loses however sharp it is.
    public var total: Double { face == nil ? 0 : quality * eyes * (0.25 + 0.75 * mouth) }
}

/// Scores exact frames of a video (Vision, in FaceTrack).
public protocol StillScorer: Sendable {
    /// One score per request, in order: the frame at `t`, judged on the face nearest `near`
    /// (or the largest face when `near` is nil).
    func score(video: URL, _ requests: [(t: Seconds, near: FaceBox?)]) async throws -> [StillScore]
}
