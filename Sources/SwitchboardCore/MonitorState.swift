/// Picture-by-picture state of the LG DualUp, as read back on the video cable (VCP 0xD7:
/// 0 = on, 1 = off). `unknown` means the code could not be read; it never means "changed".
public enum PBPState: String, Codable, Sendable, Hashable {
    case on
    case off
    case unknown
}

/// The DualUp's main input (VCP 0xF5: 1 = HDMI 1, 2 = HDMI 2). Flips on a main/sub swap.
public enum MainInput: String, Codable, Sendable, Hashable {
    case hdmi1
    case hdmi2
    case unknown
}
