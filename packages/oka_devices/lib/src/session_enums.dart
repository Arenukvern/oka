/// Session ownership and start posture — names match UA `LeaseOwnership` /
/// `StartMode` so `.name` serialization round-trips.
library;

/// Who owns the device process for this session.
enum LeaseOwnership { owned, borrowed }

/// Whether the session starts the device or attaches to an existing one.
enum StartMode { start, attach }
