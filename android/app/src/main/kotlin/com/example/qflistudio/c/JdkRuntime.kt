package com.azurekiln.qfli.jvmx

import android.content.Context
import android.system.Os
import org.json.JSONObject
import java.io.File
import java.nio.file.Files
import java.util.zip.ZipInputStream

internal class JdkRuntime(private val context: Context) {
    fun prepare(): Map<String, String> {
        val nativeDir = context.applicationInfo.nativeLibraryDir
        val abi = "arm64-v8a"
        val manifest = context.assets.open("jdk-$abi.json").bufferedReader().use { JSONObject(it.readText()) }
        check(manifest.getInt("version") == 1) { "Unsupported JDK layout" }
        val home = File(context.filesDir, "usr")
        val marker = File(home, ".qfli-jdk-id")
        val id = manifest.getString("id")
        if (!marker.isFile || marker.readText() != id || !File(home, "lib/modules").isFile) {
            val staging = File(context.filesDir, "usr-install")
            staging.deleteRecursively()
            check(staging.mkdirs()) { "Cannot create JDK directory" }
            try {
                ZipInputStream(context.assets.open("jdk-$abi.zip")).use { zip ->
                    var entry = zip.nextEntry
                    while (entry != null) {
                        val file = File(staging, entry.name)
                        check(file.canonicalPath.startsWith(staging.canonicalPath + File.separator)) { "Invalid JDK archive path" }
                        if (entry.isDirectory) {
                            file.mkdirs()
                        } else {
                            file.parentFile!!.mkdirs()
                            file.outputStream().use { zip.copyTo(it) }
                        }
                        zip.closeEntry()
                        entry = zip.nextEntry
                    }
                }
                check(File(staging, "lib/modules").isFile) { "JDK modules are missing" }
                File(staging, ".qfli-jdk-id").writeText(id)
                check(!home.exists() || home.deleteRecursively()) { "Cannot replace JDK directory" }
                check(staging.renameTo(home)) { "Cannot install JDK data" }
            } finally {
                staging.deleteRecursively()
            }
        }
        val libraries = manifest.getJSONArray("libraries")
        for (index in 0 until libraries.length()) {
            val item = libraries.getJSONObject(index)
            val target = File(nativeDir, item.getString("library"))
            check(target.isFile) { "JDK library is missing: ${target.name}" }
            val link = File(home, item.getString("path"))
            link.parentFile!!.mkdirs()
            Files.deleteIfExists(link.toPath())
            Os.symlink(target.path, link.path)
        }
        File(home, "tmp").mkdirs()
        val java = File(nativeDir, "libqfli_java.so")
        val javac = File(nativeDir, "libqfli_javac.so")
        check(java.canExecute() && javac.canExecute()) { "JDK launchers are not executable" }
        return mapOf("home" to home.path, "java" to java.path, "javac" to javac.path, "libraryDirectory" to nativeDir)
    }
}
