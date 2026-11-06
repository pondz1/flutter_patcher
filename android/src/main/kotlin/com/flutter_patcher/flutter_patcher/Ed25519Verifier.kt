package com.flutter_patcher.flutter_patcher

import org.bouncycastle.crypto.params.Ed25519PublicKeyParameters
import org.bouncycastle.crypto.signers.Ed25519Signer

/** Provider-independent Ed25519 verification, including Android API 24-32. */
internal object Ed25519Verifier {
    // RFC 8410 Ed25519 SubjectPublicKeyInfo, with absent algorithm parameters.
    private val prefix = byteArrayOf(0x30, 0x2a, 0x30, 0x05, 0x06, 0x03,
        0x2b, 0x65, 0x70, 0x03, 0x21, 0x00)

    fun verify(message: ByteArray, signature: ByteArray, spki: ByteArray): Boolean {
        if (signature.size != 64 || spki.size != 44 ||
            !spki.copyOfRange(0, prefix.size).contentEquals(prefix)) return false
        return try {
            val verifier = Ed25519Signer()
            verifier.init(false, Ed25519PublicKeyParameters(spki, prefix.size))
            verifier.update(message, 0, message.size)
            verifier.verifySignature(signature)
        } catch (_: Exception) {
            false
        }
    }
}
