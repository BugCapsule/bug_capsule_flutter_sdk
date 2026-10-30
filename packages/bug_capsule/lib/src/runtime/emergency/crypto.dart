import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/api.dart' show PublicKeyParameter;
import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/ecc/api.dart';
import 'package:pointycastle/ecc/curves/secp256r1.dart';
import 'package:pointycastle/signers/ecdsa_signer.dart';

/// Primitives of emergency-client-v1 §2 and §4: unpadded base64url, P-256
/// SubjectPublicKeyInfo, DER ECDSA signatures, SHA-256. Every parser here is
/// strict and returns null (or false) on malformed input instead of throwing.

final RegExp _base64UrlChars = RegExp(r'^[A-Za-z0-9_-]*={0,2}$');

/// Decodes RFC 4648 §5 base64url, with or without `=` padding. Null for
/// characters outside the URL-safe alphabet, an impossible length, or
/// padding that does not match the length.
Uint8List? decodeBase64Url(String input) {
  if (!_base64UrlChars.hasMatch(input)) return null;
  final unpadded = input.replaceAll('=', '');
  final padding = input.length - unpadded.length;
  final rem = unpadded.length % 4;
  if (rem == 1) return null;
  final needed = rem == 0 ? 0 : 4 - rem;
  if (padding != 0 && padding != needed) return null;
  try {
    return base64Url.decode(unpadded + '=' * needed);
  } on FormatException {
    return null;
  }
}

/// Unpadded base64url.
String encodeBase64Url(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

Uint8List sha256(List<int> bytes) =>
    SHA256Digest().process(Uint8List.fromList(bytes));

final ECCurve_secp256r1 _p256 = ECCurve_secp256r1();

/// The prime of the P-256 field (FIPS 186-4 D.1.2.3).
final BigInt _p256FieldPrime = BigInt.parse(
  'ffffffff00000001000000000000000000000000ffffffffffffffffffffffff',
  radix: 16,
);

/// DER of `SEQUENCE { SEQUENCE { id-ecPublicKey, prime256v1 }, BIT STRING`
/// with a 66-byte bit string (no unused bits, then the 65-byte point). Every
/// P-256 SubjectPublicKeyInfo with an uncompressed point starts this way.
const List<int> p256SpkiPrefix = [
  0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, //
  0x01, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03,
  0x42, 0x00,
];

/// A P-256 public key that can verify ES256 signatures.
final class P256PublicKey {
  P256PublicKey._(this._key);

  final ECPublicKey _key;

  /// Parses a DER SubjectPublicKeyInfo: the fixed P-256 prefix followed by
  /// an uncompressed point that lies on the curve. Null otherwise.
  static P256PublicKey? fromSpki(List<int> der) {
    if (der.length != p256SpkiPrefix.length + 65) return null;
    for (var i = 0; i < p256SpkiPrefix.length; i++) {
      if (der[i] != p256SpkiPrefix[i]) return null;
    }
    final point = der.sublist(p256SpkiPrefix.length);
    if (point[0] != 0x04) return null;
    final x = _unsigned(point.sublist(1, 33));
    final y = _unsigned(point.sublist(33, 65));
    if (!_onCurve(x, y)) return null;
    try {
      final q = _p256.curve.decodePoint(point);
      if (q == null || q.isInfinity) return null;
      return P256PublicKey._(ECPublicKey(q, _p256));
    } catch (_) {
      return null;
    }
  }

  /// `y² = x³ − 3x + b (mod p)` with both coordinates in the field.
  static bool _onCurve(BigInt x, BigInt y) {
    final p = _p256FieldPrime;
    final b = _p256.curve.b!.toBigInteger()!;
    if (x >= p || y >= p) return false;
    final lhs = (y * y) % p;
    final rhs = (x * x * x - BigInt.from(3) * x + b) % p;
    return lhs == rhs;
  }

  /// ECDSA P-256 / SHA-256 over [message] with a DER signature. False for a
  /// signature that is not strict DER or has `r`/`s` out of range.
  bool verify(List<int> message, List<int> derSignature) {
    final sig = parseDerSignature(derSignature);
    if (sig == null) return false;
    try {
      final signer = ECDSASigner(SHA256Digest())
        ..init(false, PublicKeyParameter<ECPublicKey>(_key));
      return signer.verifySignature(
        Uint8List.fromList(message),
        ECSignature(sig.r, sig.s),
      );
    } catch (_) {
      return false;
    }
  }
}

/// `r` and `s` of a DER `SEQUENCE { INTEGER r, INTEGER s }`, in strict DER:
/// definite minimal lengths, positive minimal integers of at most 32
/// significant bytes, and nothing after the sequence. Null otherwise.
({BigInt r, BigInt s})? parseDerSignature(List<int> der) {
  var pos = 0;

  int? length() {
    if (pos >= der.length) return null;
    final first = der[pos++];
    if (first < 0x80) return first;
    if (first != 0x81 || pos >= der.length) return null;
    final value = der[pos++];
    return value < 0x80 ? null : value; // 0x81 only for lengths >= 128
  }

  BigInt? integer() {
    if (pos >= der.length || der[pos++] != 0x02) return null;
    final len = length();
    if (len == null || len == 0 || pos + len > der.length) return null;
    final bytes = der.sublist(pos, pos + len);
    pos += len;
    if (bytes[0] & 0x80 != 0) return null; // negative
    if (bytes.length > 1 && bytes[0] == 0 && bytes[1] & 0x80 == 0) {
      return null; // non-minimal leading zero
    }
    final significant = bytes[0] == 0 ? bytes.length - 1 : bytes.length;
    if (significant > 32) return null;
    return _unsigned(bytes);
  }

  if (der.isEmpty || der[pos++] != 0x30) return null;
  final seqLen = length();
  if (seqLen == null || pos + seqLen != der.length) return null;
  final r = integer();
  if (r == null) return null;
  final s = integer();
  if (s == null || pos != der.length) return null;
  final n = _p256.n;
  if (r < BigInt.one || r >= n || s < BigInt.one || s >= n) return null;
  return (r: r, s: s);
}

BigInt _unsigned(List<int> bytes) {
  var v = BigInt.zero;
  for (final b in bytes) {
    v = (v << 8) | BigInt.from(b);
  }
  return v;
}
