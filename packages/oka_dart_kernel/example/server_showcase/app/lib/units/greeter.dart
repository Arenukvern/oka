/// The server's patch unit. Live-patch rule (ADR-0035): patch function
/// bodies — a `const` field's canonical value survives a kernel reload.
library;

String greet() => 'hello-v1';
