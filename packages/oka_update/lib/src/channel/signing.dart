/// Ed25519 signatures over canonical bytes (ADR-0037 G-AC5): the apply
/// channel is an RCE surface, so the pointer and every revision manifest
/// carry `signedBy {keyId, algorithm, signature}` — the signature covers
/// the canonical JSON of the object *without* its `signedBy` field. The
/// verifier is the client's embedded trust anchor (public key); an
/// install that carries one refuses unsigned or wrongly-signed channels.
library;

import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import 'channel_manifest.dart';

const String signingAlgorithm = 'ed25519';

/// A signing identity: the ed25519 key pair plus the derived key id
/// (sha256 of the public key, truncated) that receipts and channels name.
class ChannelSigner {
  ChannelSigner._(this._algorithm, this._keyPair, this.publicKeyHex)
      : keyId = sha256Hex(publicKeyHex.codeUnits).substring(0, 16);

  final Ed25519 _algorithm;
  final SimpleKeyPair _keyPair;

  /// hex-encoded public key — the trust anchor to embed in the app.
  final String publicKeyHex;

  /// Stable identifier for receipts and `signedBy.keyId`.
  final String keyId;

  static Future<ChannelSigner> generate() async {
    final algorithm = Ed25519();
    final pair = await algorithm.newKeyPair();
    return _fromPair(algorithm, pair);
  }

  /// Restores a signer from a hex seed (32 bytes) — the publisher's
  /// persisted key material.
  static Future<ChannelSigner> fromSeedHex(String seedHex) async {
    final seed = _hexToBytes(seedHex.trim());
    if (seed.length != 32) {
      throw ArgumentError.value(
          seedHex, 'seedHex', 'ed25519 seed must be 32 bytes (64 hex chars)');
    }
    final algorithm = Ed25519();
    final pair = await algorithm.newKeyPairFromSeed(seed);
    return _fromPair(algorithm, pair);
  }

  static Future<ChannelSigner> _fromPair(
      Ed25519 algorithm, SimpleKeyPair pair) async {
    final pub = await pair.extractPublicKey();
    return ChannelSigner._(
        algorithm, pair, _bytesToHex(pub.bytes));
  }

  /// The persisted key material (hex seed) for the publisher's key file.
  Future<String> keySeedHex() async =>
      _bytesToHex(await _keyPair.extractPrivateKeyBytes());

  /// Signs `json` (pointer or revision node): returns the same map with
  /// `signedBy` injected.
  Future<Map<String, Object?>> sign(Map<String, Object?> json) async {
    final payload =
        utf8.encode(canonicalJson(_withoutSignature(json)));
    final signature = await _algorithm.sign(payload, keyPair: _keyPair);
    return {
      ...json,
      'signedBy': {
        'keyId': keyId,
        'algorithm': signingAlgorithm,
        'publicKey': publicKeyHex,
        'signature': base64Encode(signature.bytes),
      },
    };
  }
}

/// The verdict of a verification.
class SignatureVerdict {
  const SignatureVerdict({required this.ok, this.reason});
  final bool ok;
  final String? reason;

  @override
  String toString() => ok ? 'signature OK' : 'signature REFUSED: $reason';
}

/// Verifies a signed pointer/manifest against the embedded trust anchor.
/// `signedBy.publicKey` (when present) must equal the anchor — the anchor
/// pins the key, so a channel signed by a *different* valid key refuses.
Future<SignatureVerdict> verifySignature(
  Map<String, Object?> json, {
  required String trustedPublicKeyHex,
}) async {
  final signedBy = json['signedBy'];
  if (signedBy is! Map) {
    return const SignatureVerdict(
        ok: false, reason: 'object is unsigned');
  }
  final meta = signedBy.cast<String, dynamic>();
  if (meta['algorithm'] != signingAlgorithm) {
    return SignatureVerdict(
        ok: false,
        reason: 'unsupported signature algorithm: ${meta['algorithm']}');
  }
  final claimedKey = meta['publicKey'] as String?;
  if (claimedKey == null) {
    return const SignatureVerdict(
        ok: false, reason: 'signedBy carries no public key');
  }
  if (claimedKey != trustedPublicKeyHex) {
    return SignatureVerdict(
        ok: false, reason: 'signed by an untrusted key (${meta['keyId']})');
  }
  final signatureBase64 = meta['signature'] as String?;
  if (signatureBase64 == null) {
    return const SignatureVerdict(
        ok: false, reason: 'signedBy carries no signature');
  }
  final payload =
      utf8.encode(canonicalJson(_withoutSignature(json)));
  final algorithm = Ed25519();
  final publicKey = SimplePublicKey(
      _hexToBytes(trustedPublicKeyHex), type: KeyPairType.ed25519);
  final ok = await algorithm.verify(
    payload,
    signature: Signature(
        base64Decode(signatureBase64), publicKey: publicKey),
  );
  return ok
      ? const SignatureVerdict(ok: true)
      : const SignatureVerdict(ok: false, reason: 'signature does not verify');
}

Map<String, Object?> _withoutSignature(Map<String, Object?> json) {
  final copy = {...json}..remove('signedBy');
  return copy;
}

String _bytesToHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

List<int> _hexToBytes(String hex) {
  final clean = hex.replaceAll('\n', '').replaceAll(' ', '');
  if (clean.length.isOdd) throw const FormatException('odd hex length');
  return [
    for (var i = 0; i < clean.length; i += 2)
      int.parse(clean.substring(i, i + 2), radix: 16),
  ];
}
