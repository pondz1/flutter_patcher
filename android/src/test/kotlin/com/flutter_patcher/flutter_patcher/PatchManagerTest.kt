package com.flutter_patcher.flutter_patcher

import android.content.Context
import android.content.SharedPreferences
import android.content.pm.ApplicationInfo
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.util.Base64
import android.util.Log
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import java.io.File
import java.security.KeyPairGenerator
import java.security.Signature
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import io.flutter.plugin.common.StandardMessageCodec
import org.json.JSONArray
import org.json.JSONObject
import org.mockito.Mockito

class PatchManagerTest {
    @Test
    fun signedAssetPackageColdStartChecksMergedDirectoryManifestAndLoadedArchive() {
        for (tamper in listOf("none", "overlay", "base", "manifest", "archive", "asset-flag")) {
            val root = tempDir()
            val key = KeyPairGenerator.getInstance("Ed25519").generateKeyPair()
            val context = authenticatedContext(root,
                java.util.Base64.getEncoder().encodeToString(key.public.encoded))
            val baseManifest = codecBufferToByteArray(StandardMessageCodec.INSTANCE
                .encodeMessage(linkedMapOf("base.txt" to listOf(mapOf("asset" to "base.txt"))))!!)
            fun writeZip(file: File, entries: Map<String, ByteArray>) {
                ZipOutputStream(file.outputStream()).use { zip ->
                    for ((path, bytes) in entries) {
                        zip.putNextEntry(ZipEntry(path)); zip.write(bytes); zip.closeEntry()
                    }
                }
            }
            writeZip(File(root, "host.apk"), mapOf(
                "assets/flutter_assets/AssetManifest.bin" to baseManifest,
                "assets/flutter_assets/base.txt" to "trusted base".toByteArray()))
            val library = "library".toByteArray()
            val overlay = "new image".toByteArray()
            fun md5(bytes: ByteArray) = java.security.MessageDigest.getInstance("MD5")
                .digest(bytes).joinToString("") { "%02x".format(it) }
            val assets = JSONObject().put("mode", "overlay").put("prefix", "assets/")
                .put("manifestPatch", "manifest_patch.json").put("files", JSONArray().put(
                    JSONObject().put("path", "new.txt").put("md5", md5(overlay)).put("size", overlay.size)))
            val manifest = JSONObject().put("schemaVersion", 2).put("version", "assets-1")
                .put("targetVersionCode", 42).put("assets", assets).put("lib", JSONObject().put("arm64-v8a",
                    JSONObject().put("path", "lib/arm64-v8a/libapp.so").put("md5", md5(library))))
            val operation = JSONObject().put("schemaVersion", 1).put("manifestFormat", "bin")
                .put("baseManifestSize", baseManifest.size).put("operations", JSONArray().put(
                    JSONObject().put("op", "upsert").put("key", "new.txt")
                        .put("variants", JSONArray().put(JSONObject().put("asset", "new.txt")))))
            val payload = File(root, "source.zip")
            writeZip(payload, mapOf("manifest.json" to manifest.toString().toByteArray(),
                "lib/arm64-v8a/libapp.so" to library, "assets/new.txt" to overlay,
                "manifest_patch.json" to operation.toString().toByteArray()))
            val digest = SignatureVerifier.md5(payload)
            val signer = Signature.getInstance("Ed25519")
            signer.initSign(key.private); signer.update(digest.toByteArray())
            val signature = java.util.Base64.getEncoder().encodeToString(signer.sign())
            try {
                Mockito.mockStatic(Base64::class.java).use { base64 ->
                    base64.`when`<ByteArray> { Base64.decode(Mockito.anyString(), Mockito.anyInt()) }
                        .thenAnswer { java.util.Base64.getDecoder().decode(it.getArgument<String>(0)) }
                    Mockito.mockStatic(Log::class.java).use {
                        val manager = PatchManager(context, supportedAbis = arrayOf("arm64-v8a"))
                        assertNull(invokePrivate(manager, "installPackagePatch", payload,
                            "assets-1", digest, digest, signature, 42L))
                        val patchDir = File(root, PatcherConfig.PATCH_DIR)
                        when (tamper) {
                            "overlay" -> File(patchDir, "flutter_assets/new.txt").writeText("forged")
                            "base" -> File(patchDir, "flutter_assets/base.txt").writeText("forged")
                            "manifest" -> File(patchDir, "flutter_assets/AssetManifest.bin").writeText("forged")
                            "archive" -> File(patchDir, "flutter_assets.apk").writeText("forged")
                            "asset-flag" -> {
                                val metadata = File(patchDir, PatcherConfig.META_FILENAME)
                                metadata.writeText(JSONObject(metadata.readText()).put("hasAssets", false).toString())
                            }
                        }
                        val cold = PatchManager(context, supportedAbis = arrayOf("arm64-v8a"))
                        if (tamper == "none") assertTrue(cold.getValidPatch() != null)
                        else assertNull(cold.getValidPatch(), "must reject $tamper tampering")
                    }
                }
            } finally { root.deleteRecursively() }
        }
    }

    @Test
    fun signedPackageSurvivesColdStartAndRejectsTamperedRetainedPayloadAndLibrary() {
        for (tamper in listOf("none", "library", "payload", "metadata")) {
            val root = tempDir()
            val key = KeyPairGenerator.getInstance("Ed25519").generateKeyPair()
            val publicKey = java.util.Base64.getEncoder().encodeToString(key.public.encoded)
            val context = authenticatedContext(root, publicKey)
            val payload = File(root, "source.zip")
            val lib = "real fixture library bytes".toByteArray()
            val libMd5 = java.security.MessageDigest.getInstance("MD5").digest(lib)
                .joinToString("") { "%02x".format(it) }
            val manifest = JSONObject().put("schemaVersion", 2).put("version", "signed-1")
                .put("targetVersionCode", 42).put("lib", JSONObject().put("arm64-v8a",
                    JSONObject().put("path", "lib/arm64-v8a/libapp.so").put("md5", libMd5)))
            ZipOutputStream(payload.outputStream()).use { zip ->
                zip.putNextEntry(ZipEntry("manifest.json")); zip.write(manifest.toString().toByteArray()); zip.closeEntry()
                zip.putNextEntry(ZipEntry("lib/arm64-v8a/libapp.so")); zip.write(lib); zip.closeEntry()
            }
            val md5 = SignatureVerifier.md5(payload)
            val signer = Signature.getInstance("Ed25519")
            signer.initSign(key.private); signer.update(md5.toByteArray())
            val signature = java.util.Base64.getEncoder().encodeToString(signer.sign())
            try {
                Mockito.mockStatic(Base64::class.java).use { base64 ->
                    base64.`when`<ByteArray> { Base64.decode(Mockito.anyString(), Mockito.anyInt()) }
                        .thenAnswer { java.util.Base64.getDecoder().decode(it.getArgument<String>(0)) }
                    Mockito.mockStatic(Log::class.java).use {
                        val manager = PatchManager(context, supportedAbis = arrayOf("arm64-v8a"))
                        assertNull(invokePrivate(manager, "installPackagePatch", payload,
                            "signed-1", md5, md5, signature, 42L))
                        val patchDir = File(root, PatcherConfig.PATCH_DIR)
                        if (tamper == "library") File(patchDir, PatcherConfig.PATCH_FILENAME).writeText("tampered")
                        if (tamper == "payload") File(patchDir, "authenticated/$md5.zip").writeText("tampered")
                        if (tamper == "metadata") {
                            val metadata = File(patchDir, PatcherConfig.META_FILENAME)
                            val json = JSONObject(metadata.readText()).put("effectiveMd5", libMd5).put("version", "forged")
                            metadata.writeText(json.toString())
                        }
                        val coldStart = PatchManager(context, supportedAbis = arrayOf("arm64-v8a"))
                        if (tamper == "none") assertTrue(coldStart.getValidPatch() != null)
                        else assertNull(coldStart.getValidPatch(), "must reject $tamper tampering")
                    }
                }
            } finally { root.deleteRecursively() }
        }
    }

    private fun authenticatedContext(root: File, publicKey: String): Context {
        val context = mockContext(root)
        val prefs = Mockito.mock(SharedPreferences::class.java)
        Mockito.`when`(context.getSharedPreferences(PatcherConfig.PREFS_NAME, Context.MODE_PRIVATE)).thenReturn(prefs)
        Mockito.`when`(prefs.getString("public_key_base64", "")).thenReturn(publicKey)
        Mockito.`when`(prefs.getBoolean("strict_signature", true)).thenReturn(true)
        val packages = Mockito.mock(PackageManager::class.java)
        Mockito.`when`(context.packageManager).thenReturn(packages)
        Mockito.`when`(context.packageName).thenReturn("example.host")
        val info = PackageInfo(); info.versionCode = 42
        Mockito.`when`(packages.getPackageInfo("example.host", 0)).thenReturn(info)
        val application = ApplicationInfo()
        application.sourceDir = File(root, "host.apk").path
        Mockito.`when`(context.applicationInfo).thenReturn(application)
        return context
    }

    @Test
    fun validatePatchArgsAcceptsValidFullPatch() {
        val result = PatchManager.validatePatchArgs(
            version = "1.0.0-h1",
            url = "https://example.com/libapp.so",
            md5 = "0123456789abcdef0123456789abcdef",
            mode = "full",
            targetVersionCode = 100,
            currentVersionCode = 100
        )

        assertNull(result)
    }

    @Test
    fun validatePatchArgsRejectsInvalidMd5BeforeDownload() {
        val result = PatchManager.validatePatchArgs(
            version = "1.0.0-h1",
            url = "https://example.com/libapp.so",
            md5 = "bad-md5",
            mode = "full",
            targetVersionCode = 100,
            currentVersionCode = 100
        )

        assertEquals(ApplyErrorCode.INVALID_ARGS, result?.errorCode)
    }

    @Test
    fun validatePatchArgsRejectsTargetVersionCodeMismatch() {
        val result = PatchManager.validatePatchArgs(
            version = "1.0.0-h1",
            url = "https://example.com/libapp.so",
            md5 = "0123456789abcdef0123456789abcdef",
            mode = "full",
            targetVersionCode = 101,
            currentVersionCode = 100
        )

        assertEquals(ApplyErrorCode.INVALID_ARGS, result?.errorCode)
    }

    @Test
    fun validatePatchArgsRejectsUnsupportedMode() {
        val result = PatchManager.validatePatchArgs(
            version = "1.0.0-h1",
            url = "https://example.com/app.patch",
            md5 = "0123456789abcdef0123456789abcdef",
            mode = "delta",
            targetVersionCode = 100,
            currentVersionCode = 100
        )

        assertEquals(ApplyErrorCode.INVALID_ARGS, result?.errorCode)
    }

    @Test
    fun validatePatchArgsAcceptsBlankMd5() {
        val result = PatchManager.validatePatchArgs(
            version = "1.0.0-h1",
            url = "https://example.com/libapp.so",
            md5 = "",
            mode = "full",
            targetVersionCode = 100,
            currentVersionCode = 100
        )

        assertNull(result)
    }

    @Test
    fun validatePatchArgsRejectsBlankVersionOrUrl() {
        val r1 = PatchManager.validatePatchArgs(
            version = "",
            url = "https://example.com/libapp.so",
            md5 = "",
            mode = "full",
            targetVersionCode = 100,
            currentVersionCode = 100
        )
        val r2 = PatchManager.validatePatchArgs(
            version = "1.0.0-h1",
            url = "",
            md5 = "",
            mode = "full",
            targetVersionCode = 100,
            currentVersionCode = 100
        )
        assertEquals(ApplyErrorCode.INVALID_ARGS, r1?.errorCode)
        assertEquals(ApplyErrorCode.INVALID_ARGS, r2?.errorCode)
    }

    @Test
    fun isSameInstalledPatchMatchesByVersionWhenMd5Blank() {
        val installed = "1.0.0-h1" to "0123456789abcdef0123456789abcdef"
        // 入参 md5 为空 → 仅按 version 判等
        assertTrue(PatchManager.isSameInstalledPatch(installed, "1.0.0-h1", ""))
        assertFalse(PatchManager.isSameInstalledPatch(installed, "1.0.0-h2", ""))
    }

    @Test
    fun isSameInstalledPatchRequiresVersionAndMd5Match() {
        val installed = "1.0.0-h1" to "0123456789abcdef0123456789abcdef"

        assertTrue(
            PatchManager.isSameInstalledPatch(
                installed,
                "1.0.0-h1",
                "0123456789ABCDEF0123456789ABCDEF"
            )
        )
        assertFalse(
            PatchManager.isSameInstalledPatch(
                installed,
                "1.0.0-h1",
                "ffffffffffffffffffffffffffffffff"
            )
        )
        assertFalse(
            PatchManager.isSameInstalledPatch(
                installed,
                "1.0.0-h2",
                "0123456789abcdef0123456789abcdef"
            )
        )
    }

    @Test
    fun isZipPayloadDetectsZipMagic() {
        val zip = File.createTempFile("flutter_patcher", ".zip")
        val so = File.createTempFile("flutter_patcher", ".so")
        try {
            zip.writeBytes(byteArrayOf(0x50, 0x4b, 0x03, 0x04, 0x00))
            so.writeBytes(byteArrayOf(0x7f, 0x45, 0x4c, 0x46))

            assertTrue(PatchManager.isZipPayload(zip))
            assertFalse(PatchManager.isZipPayload(so))
        } finally {
            zip.delete()
            so.delete()
        }
    }

    @Test
    fun isDartOnlyAssetsTreatsMissingOrEmptyFilesAsDartOnly() {
        // null block → Dart-only patch.zip (pack omits the assets key entirely)
        assertTrue(PatchManager.isDartOnlyAssets(null))
        // present but no files key
        assertTrue(PatchManager.isDartOnlyAssets(JSONObject()))
        // present with empty files array
        assertTrue(
            PatchManager.isDartOnlyAssets(
                JSONObject().put("files", JSONArray())
            )
        )
        // present with at least one overlay file → real asset patch
        assertFalse(
            PatchManager.isDartOnlyAssets(
                JSONObject().put(
                    "files",
                    JSONArray().put(JSONObject().put("path", "hero.png"))
                )
            )
        )
    }

    @Test
    fun selectPackageAbiUsesDevicePriorityOrder() {
        val lib = org.json.JSONObject()
            .put("armeabi-v7a", org.json.JSONObject().put("path", "lib/armeabi-v7a/libapp.so"))
            .put("arm64-v8a", org.json.JSONObject().put("path", "lib/arm64-v8a/libapp.so"))

        assertEquals(
            "arm64-v8a",
            PatchManager.selectPackageAbi(lib, arrayOf("arm64-v8a", "armeabi-v7a"))
        )
        assertNull(PatchManager.selectPackageAbi(lib, arrayOf("x86_64")))
    }

    @Test
    fun codecBufferToByteArrayRewindsEncodedManifest() {
        val manifest = linkedMapOf(
            "assets/patch_demo.png" to listOf(mapOf("asset" to "assets/patch_demo.png"))
        )
        val encoded = StandardMessageCodec.INSTANCE.encodeMessage(manifest)!!
        val bytes = codecBufferToByteArray(encoded)

        assertTrue(bytes.isNotEmpty())
        assertEquals(
            manifest,
            StandardMessageCodec.INSTANCE.decodeMessage(java.nio.ByteBuffer.wrap(bytes))
        )
    }

    @Test
    fun isSafeZipPathRejectsTraversal() {
        assertTrue(PatchManager.isSafeZipPath("assets/images/hero.png"))
        assertFalse(PatchManager.isSafeZipPath("../hero.png"))
        assertFalse(PatchManager.isSafeZipPath("assets/../hero.png"))
        assertFalse(PatchManager.isSafeZipPath("/assets/hero.png"))
    }

    @Test
    fun recoverInterruptedInstallRestoresPreviousArtifacts() {
        val root = tempDir()
        try {
            val manager = PatchManager(mockContext(root))
            val patchDir = File(root, PatcherConfig.PATCH_DIR).apply { mkdirs() }

            File(patchDir, "installing").writeText("installing")
            File(patchDir, "${PatcherConfig.PATCH_FILENAME}.previous").writeText("old-so")
            File(patchDir, "${PatcherConfig.META_FILENAME}.previous").writeText("old-meta")
            File(patchDir, "flutter_assets.previous").apply {
                mkdirs()
                File(this, "AssetManifest.bin").writeText("old-assets")
            }
            File(patchDir, PatcherConfig.PATCH_FILENAME).writeText("new-so")
            File(patchDir, PatcherConfig.META_FILENAME).writeText("new-meta")
            File(patchDir, "flutter_assets").apply {
                mkdirs()
                File(this, "AssetManifest.bin").writeText("new-assets")
            }
            File(patchDir, "${PatcherConfig.PATCH_FILENAME}.pending").writeText("pending-so")

            invokePrivate(manager, "recoverInterruptedInstall")

            assertEquals("old-so", File(patchDir, PatcherConfig.PATCH_FILENAME).readText())
            assertEquals("old-meta", File(patchDir, PatcherConfig.META_FILENAME).readText())
            assertEquals(
                "old-assets",
                File(patchDir, "flutter_assets/AssetManifest.bin").readText()
            )
            assertFalse(File(patchDir, "installing").exists())
            assertFalse(File(patchDir, "${PatcherConfig.PATCH_FILENAME}.pending").exists())
            assertFalse(File(patchDir, "${PatcherConfig.PATCH_FILENAME}.previous").exists())
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun recoverInterruptedInstallWithPartialPreviousKeepsUnbackedCurrentMeta() {
        val root = tempDir()
        try {
            val manager = PatchManager(mockContext(root))
            val patchDir = File(root, PatcherConfig.PATCH_DIR).apply { mkdirs() }

            File(patchDir, "installing").writeText("installing")
            File(patchDir, "${PatcherConfig.PATCH_FILENAME}.previous").writeText("old-so")
            File(patchDir, PatcherConfig.META_FILENAME).writeText("old-meta")

            invokePrivate(manager, "recoverInterruptedInstall")

            assertEquals("old-so", File(patchDir, PatcherConfig.PATCH_FILENAME).readText())
            assertEquals("old-meta", File(patchDir, PatcherConfig.META_FILENAME).readText())
            assertFalse(File(patchDir, "installing").exists())
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun rollbackPreparedCommitRestoresPreviousPatchWhenNewPatchWasPromoted() {
        val root = tempDir()
        try {
            val manager = PatchManager(mockContext(root))
            val patchDir = File(root, PatcherConfig.PATCH_DIR).apply { mkdirs() }

            File(patchDir, PatcherConfig.PATCH_FILENAME).writeText("new-so")
            File(patchDir, PatcherConfig.META_FILENAME).writeText("new-meta")
            File(patchDir, "flutter_assets").apply {
                mkdirs()
                File(this, "AssetManifest.bin").writeText("new-assets")
            }
            File(patchDir, "${PatcherConfig.PATCH_FILENAME}.previous").writeText("old-so")
            File(patchDir, "${PatcherConfig.META_FILENAME}.previous").writeText("old-meta")
            File(patchDir, "flutter_assets.previous").apply {
                mkdirs()
                File(this, "AssetManifest.bin").writeText("old-assets")
            }

            invokePrivate(
                manager,
                "rollbackPreparedCommit",
                true,
                true,
                true,
                false,
                true,
                true,
                true,
                false,
            )

            assertEquals("old-so", File(patchDir, PatcherConfig.PATCH_FILENAME).readText())
            assertEquals("old-meta", File(patchDir, PatcherConfig.META_FILENAME).readText())
            assertEquals(
                "old-assets",
                File(patchDir, "flutter_assets/AssetManifest.bin").readText()
            )
            assertFalse(File(patchDir, "${PatcherConfig.PATCH_FILENAME}.previous").exists())
            assertFalse(File(patchDir, "flutter_assets.previous").exists())
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun installPackagePatchReturnsAssetPackageInvalidForMalformedZip() {
        val root = tempDir()
        try {
            val manager = PatchManager(mockContext(root))
            val malformed = File(root, "patch.zip")
            malformed.writeBytes(byteArrayOf(0x50, 0x4b, 0x03, 0x04, 0x00))

            val result = invokePrivate(
                manager,
                "installPackagePatch",
                malformed,
                "1.0.0-h1",
                "",
                "0123456789abcdef0123456789abcdef",
                "",
                100L,
            ) as ApplyResult

            assertFalse(result.ok)
            assertEquals(ApplyErrorCode.ASSET_PACKAGE_INVALID, result.errorCode)
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun finalizePatchLegacySuccessRemovesOldAssetsOnlyAfterCommit() {
        val root = tempDir()
        try {
            val manager = PatchManager(mockContext(root))
            val patchDir = File(root, PatcherConfig.PATCH_DIR).apply { mkdirs() }
            File(patchDir, PatcherConfig.PATCH_FILENAME).writeText("old-so")
            File(patchDir, PatcherConfig.META_FILENAME).writeText(
                JSONObject().put("version", "old").toString()
            )
            File(patchDir, "flutter_assets").apply {
                mkdirs()
                File(this, "AssetManifest.bin").writeText("old-assets")
            }
            File(patchDir, "flutter_assets.apk").writeText("old-asset-archive")

            val newSo = File(root, "new.so").apply { writeText("new-so") }
            val newMeta = JSONObject()
                .put("version", "new")
                .put("effectiveMd5", "0123456789abcdef0123456789abcdef")

            val result = invokePrivate(manager, "finalizePatch", newSo, null, null, newMeta)

            assertNull(result)
            assertEquals("new-so", File(patchDir, PatcherConfig.PATCH_FILENAME).readText())
            assertEquals("new", JSONObject(File(patchDir, PatcherConfig.META_FILENAME).readText())
                .getString("version"))
            assertFalse(File(patchDir, "flutter_assets").exists())
            assertFalse(File(patchDir, "flutter_assets.apk").exists())
            assertFalse(File(patchDir, "installing").exists())
        } finally {
            root.deleteRecursively()
        }
    }

    private fun mockContext(filesDir: File): Context {
        val context = Mockito.mock(Context::class.java)
        Mockito.`when`(context.filesDir).thenReturn(filesDir)
        return context
    }

    private fun tempDir(): File =
        File(System.getProperty("java.io.tmpdir"), "flutter_patcher_test_${System.nanoTime()}")
            .apply { mkdirs() }

    private fun invokePrivate(target: Any, name: String, vararg args: Any?): Any? {
        val method = target.javaClass.declaredMethods.first {
            it.name == name && it.parameterTypes.size == args.size
        }
        method.isAccessible = true
        return method.invoke(target, *args)
    }
}
