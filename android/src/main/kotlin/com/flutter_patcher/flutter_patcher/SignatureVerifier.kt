package com.flutter_patcher.flutter_patcher

import android.util.Base64
import android.util.Log
import java.io.File
import java.security.MessageDigest

/**
 * 补丁文件完整性与签名校验。
 *
 * 策略：
 * - MD5 校验：始终执行（来自 [com.flutter_patcher.flutter_patcher.PatchInfo.md5]）
 * - Ed25519 签名：
 *   - publicKey 未配置且 signature 为空 → 兼容旧的无签名模式。
 *   - publicKey 已配置 → MD5 与签名均为必填项，缺失则拒绝。
 *   - signature 非空 → 使用 Bouncy Castle 轻量 Ed25519 API，支持所有 minSdk 设备。
 *     strictSignature 参数保留兼容性；不再因 Android 版本跳过验签。
 *
 * 签名的消息体约定为 **MD5 小写 hex 字符串的 UTF-8 字节**，
 * 与 Dart 侧 PatchInfo.signature 含义保持一致。
 */
internal object SignatureVerifier {

    private const val TAG = "FlutterPatcher/Sig"

    /** 计算文件 MD5（小写 hex）。 */
    fun md5(file: File): String {
        val digest = MessageDigest.getInstance("MD5")
        file.inputStream().use { input ->
            val buf = ByteArray(8192)
            while (true) {
                val n = input.read(buf)
                if (n <= 0) break
                digest.update(buf, 0, n)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    /**
     * 仅校验 Ed25519 签名（调用方已确认 MD5 匹配）。
     *
     * - signature 为空且公钥未配置 → 兼容旧模式返回 true
     * - signature 为空但公钥已配置 → 拒绝
     * - signature 非空但 publicKey 未配置 → 拒绝
     * - 所有支持的 Android API → 真实 Ed25519 验签，失败则拒绝。
     *
     * @param md5HexLower 已匹配并**小写化**的 md5 hex 字符串（作为签名消息体）
     */
    @Suppress("UNUSED_PARAMETER")
    fun verifySignatureOnly(
        md5HexLower: String,
        signatureBase64: String,
        publicKeyBase64: String,
        strictSignature: Boolean = true
    ): Boolean {
        val sig = signatureBase64.trim()
        if (sig.isEmpty() || sig.equals("null", ignoreCase = true)) {
            if (publicKeyBase64.isNotBlank()) {
                Log.w(TAG, "public key configured but signature missing, reject")
                return false
            }
            Log.d(TAG, "signature empty, skip Ed25519 check")
            return true
        }
        if (publicKeyBase64.isEmpty()) {
            Log.w(TAG, "signature present but no public key configured, reject")
            return false
        }

        return try {
            verifyEd25519(md5HexLower, sig, publicKeyBase64)
        } catch (e: Exception) {
            Log.e(TAG, "Ed25519 verify failed", e)
            false
        }
    }

    /**
     * [verify] 的细粒度结果。调用方据此可区分"被丢弃的具体原因"用于诊断上报，
     * 见 [BootDiagnosticStore.DROPPED_MD5_MISMATCH] / [BootDiagnosticStore.DROPPED_SIGNATURE_INVALID]。
     */
    enum class VerifyResult { OK, MD5_MISMATCH, SIGNATURE_INVALID }

    /**
     * 完整校验（细粒度版本）：MD5 + 可选 Ed25519。返回失败原因分类。
     *
     * 注意：[expectedMd5] 为空且公钥未配置时，兼容旧的无签名模式。
     * 公钥已配置时，[expectedMd5] 为空则拒绝。
     * 启动路径目前仍依赖 meta.effectiveMd5 非空，故启动期不会走到这条分支；
     * 该分支主要服务于 [PatchManager.applyPatch] 期间的重复使用。
     */
    fun verifyDetailed(
        file: File,
        expectedMd5: String,
        signatureBase64: String,
        publicKeyBase64: String,
        strictSignature: Boolean = true
    ): VerifyResult {
        if (expectedMd5.isEmpty()) {
            if (publicKeyBase64.isNotBlank() || signatureBase64.isNotBlank()) {
                Log.w(TAG, "authenticated patch requires expected md5, reject")
                return VerifyResult.SIGNATURE_INVALID
            }
            Log.w(TAG, "expected md5 empty, skip md5 & signature verify")
            return VerifyResult.OK
        }
        val actualMd5 = md5(file)
        if (!actualMd5.equals(expectedMd5, ignoreCase = true)) {
            Log.e(TAG, "md5 mismatch: expected=$expectedMd5, actual=$actualMd5")
            return VerifyResult.MD5_MISMATCH
        }
        return if (verifySignatureOnly(
                actualMd5.lowercase(),
                signatureBase64,
                publicKeyBase64,
                strictSignature
            )
        ) {
            VerifyResult.OK
        } else {
            VerifyResult.SIGNATURE_INVALID
        }
    }

    /**
     * 完整校验：MD5 + 可选 Ed25519。
     *
     * @param file             已下载的补丁文件
     * @param expectedMd5      manifest 中的预期 MD5（小写 hex）
     * @param signatureBase64  manifest 中的 Ed25519 签名（Base64，允许为空）
     * @param publicKeyBase64  X.509 SubjectPublicKeyInfo 的 Base64 公钥（允许为空）
     * @param strictSignature  保留兼容性；所有支持设备均真实验签。
     * @return 是否通过校验
     */
    fun verify(
        file: File,
        expectedMd5: String,
        signatureBase64: String,
        publicKeyBase64: String,
        strictSignature: Boolean = true
    ): Boolean = verifyDetailed(
        file, expectedMd5, signatureBase64, publicKeyBase64, strictSignature
    ) == VerifyResult.OK

    private fun verifyEd25519(
        md5Hex: String,
        signatureBase64: String,
        publicKeyBase64: String
    ): Boolean {
        val pkBytes = Base64.decode(publicKeyBase64, Base64.NO_WRAP)
        val sigBytes = Base64.decode(signatureBase64, Base64.NO_WRAP)
        return Ed25519Verifier.verify(md5Hex.toByteArray(Charsets.UTF_8), sigBytes, pkBytes)
    }
}
