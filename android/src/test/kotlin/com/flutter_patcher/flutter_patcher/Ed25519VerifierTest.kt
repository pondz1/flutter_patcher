package com.flutter_patcher.flutter_patcher

import java.security.KeyPairGenerator
import java.security.Signature
import java.io.File
import android.util.Base64
import android.util.Log
import org.mockito.Mockito
import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlin.test.assertEquals

class Ed25519VerifierTest {
    @Test
    fun configuredKeyRejectsMissingAuthenticationButUnconfiguredLegacyModeStillWorks() {
        val pair = KeyPairGenerator.getInstance("Ed25519").generateKeyPair()
        val publicKey = java.util.Base64.getEncoder().encodeToString(pair.public.encoded)
        val file = File.createTempFile("signature-policy", ".zip")
        try {
            file.writeText("package bytes")
            Mockito.mockStatic(Log::class.java).use {
                assertFalse(SignatureVerifier.verifySignatureOnly("0".repeat(32), "", publicKey))
                assertFalse(SignatureVerifier.verifySignatureOnly("0".repeat(32), "null", publicKey, false))
                assertEquals(SignatureVerifier.VerifyResult.SIGNATURE_INVALID,
                    SignatureVerifier.verifyDetailed(file, "", "", publicKey))
                assertTrue(SignatureVerifier.verifySignatureOnly("0".repeat(32), "", ""))
                assertEquals(SignatureVerifier.VerifyResult.OK,
                    SignatureVerifier.verifyDetailed(file, "", "", ""))
            }
        } finally { file.delete() }
    }

    @Test
    fun publicVerificationPathAuthenticatesOnPre33AndNeverDowngradesInvalidSignatures() {
        val pair = KeyPairGenerator.getInstance("Ed25519").generateKeyPair()
        val md5 = "0123456789abcdef0123456789abcdef"
        val signer = Signature.getInstance("Ed25519")
        signer.initSign(pair.private)
        signer.update(md5.toByteArray())
        val signature = java.util.Base64.getEncoder().encodeToString(signer.sign())
        val publicKey = java.util.Base64.getEncoder().encodeToString(pair.public.encoded)
        Mockito.mockStatic(Base64::class.java).use { base64 ->
            base64.`when`<ByteArray> {
                Base64.decode(Mockito.anyString(), Mockito.anyInt())
            }.thenAnswer { invocation ->
                java.util.Base64.getDecoder().decode(invocation.getArgument<String>(0))
            }
            Mockito.mockStatic(Log::class.java).use {
                // The JVM android.jar exposes SDK_INT=0: this exercises the old
                // pre-33 rejection/downgrade path without an Android provider.
                assertTrue(SignatureVerifier.verifySignatureOnly(md5, signature, publicKey, true))
                assertFalse(SignatureVerifier.verifySignatureOnly("0".repeat(32), signature, publicKey, true))
                assertFalse(SignatureVerifier.verifySignatureOnly("0".repeat(32), signature, publicKey, false))
            }
        }
    }

    @Test
    fun verifiesRealJcaEd25519SignatureWithoutAndroidPlatformProvider() {
        val pair = KeyPairGenerator.getInstance("Ed25519").generateKeyPair()
        val message = "d41d8cd98f00b204e9800998ecf8427e".toByteArray()
        val signer = Signature.getInstance("Ed25519")
        signer.initSign(pair.private)
        signer.update(message)
        val signature = signer.sign()

        assertTrue(Ed25519Verifier.verify(message, signature, pair.public.encoded))
        assertFalse(Ed25519Verifier.verify("tampered".toByteArray(), signature, pair.public.encoded))
        signature[0] = (signature[0].toInt() xor 1).toByte()
        assertFalse(Ed25519Verifier.verify(message, signature, pair.public.encoded))
    }

    @Test
    fun rejectsWrongKeyMalformedSpkiAndWrongSignatureLengths() {
        val first = KeyPairGenerator.getInstance("Ed25519").generateKeyPair()
        val second = KeyPairGenerator.getInstance("Ed25519").generateKeyPair()
        val message = "0123456789abcdef0123456789abcdef".toByteArray()
        val signer = Signature.getInstance("Ed25519")
        signer.initSign(first.private)
        signer.update(message)
        val signature = signer.sign()

        assertFalse(Ed25519Verifier.verify(message, signature, second.public.encoded))
        assertFalse(Ed25519Verifier.verify(message, signature, first.public.encoded.copyOfRange(12, 44)))
        assertFalse(Ed25519Verifier.verify(message, signature.copyOf(63), first.public.encoded))
        val badSpki = first.public.encoded.copyOf()
        badSpki[8] = 0x71
        assertFalse(Ed25519Verifier.verify(message, signature, badSpki))
    }
}
