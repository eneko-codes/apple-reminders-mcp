import Foundation

/// Fixed limits used across the tool layer.
///
/// This server is plug and play: the owner's rule is that nothing here is configurable
/// beyond Claude Desktop's own per-tool allow/ask/prohibit switches, so what used to be
/// `user_config` settings are constants instead.
public enum Configuration {
    /// Default page size for `reminders_search`. The tool's own `limit` still wins.
    public static let searchLimit = 50

    public static let searchLimitRange = 1...200

    /// Paging ceiling. Declared here so the advertised schema and the enforced clamp
    /// cannot drift: both read this one value.
    public static let offsetRange = 0...10_000
}
