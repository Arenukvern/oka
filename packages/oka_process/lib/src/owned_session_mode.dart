/// p1 launcher `--mode` (only `owned` is defined in the contract).
enum OwnedSessionMode {
  owned('owned');

  const OwnedSessionMode(this.wireName);

  final String wireName;
}
