/// The deferred patch unit. Its label must change between gate revisions to
/// prove a swapped/recompiled unit actually executes.
String tinyLabel() => 'tiny-v1 (1 + 2 = ${1 + 2})';

/// Generic tear-off bait carried on the unit side (sdk#64162 Case B).
T echo<T>(T x) => x;
