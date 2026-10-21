import 'dart:convert';
import 'package:cryptography/cryptography.dart';

/// Service responsible for Master Password key derivation (Argon2id)
/// and AES-256-GCM symmetric encryption/decryption of server credentials.
class CryptoVaultService {
  final AesGcm _aesGcm = AesGcm.with256bits();
  final Argon2id _argon2 = Argon2id(
    parallelism: 2,
    memory: 64 * 1024, // 64 MB
    iterations: 3,
    hashLength: 32,
  );

  /// Generates a cryptographic random salt (32 bytes) encoded as Base64.
  static String generateRandomSalt() {
    final secretKey = SecretKeyData.random(length: 32);
    return base64Encode(secretKey.bytes);
  }

  /// Derives an AES-256 SecretKey from a user password and Base64 salt.
  Future<SecretKey> deriveMasterKey(String masterPassword, String base64Salt) async {
    final saltBytes = base64Decode(base64Salt);
    final secretKey = SecretKey(utf8.encode(masterPassword));
    return await _argon2.deriveKey(
      secretKey: secretKey,
      nonce: saltBytes,
    );
  }

  /// Encrypts an arbitrary Map of credentials (password, privateKey, passphrase)
  /// using the derived Master Key. Returns a map with base64 ciphertext, nonce, and tag.
  Future<Map<String, String>> encryptPayload({
    required Map<String, dynamic> payload,
    required SecretKey masterKey,
  }) async {
    final plainBytes = utf8.encode(jsonEncode(payload));
    final secretBox = await _aesGcm.encrypt(
      plainBytes,
      secretKey: masterKey,
    );

    return {
      'nonce': base64Encode(secretBox.nonce),
      'tag': base64Encode(secretBox.mac.bytes),
      'ciphertext': base64Encode(secretBox.cipherText),
    };
  }

  /// Decrypts encrypted credentials payload using Master Key.
  Future<Map<String, dynamic>> decryptPayload({
    required Map<String, dynamic> encryptedData,
    required SecretKey masterKey,
  }) async {
    final nonce = base64Decode(encryptedData['nonce'] as String);
    final macBytes = base64Decode(encryptedData['tag'] as String);
    final cipherText = base64Decode(encryptedData['ciphertext'] as String);

    final secretBox = SecretBox(
      cipherText,
      nonce: nonce,
      mac: Mac(macBytes),
    );

    final decryptedBytes = await _aesGcm.decrypt(
      secretBox,
      secretKey: masterKey,
    );

    return jsonDecode(utf8.decode(decryptedBytes)) as Map<String, dynamic>;
  }
}
