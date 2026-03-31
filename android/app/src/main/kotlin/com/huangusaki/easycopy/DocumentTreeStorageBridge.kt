package com.huangusaki.easycopy

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import android.webkit.MimeTypeMap
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts
import androidx.documentfile.provider.DocumentFile
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.FileNotFoundException
import java.io.IOException

class DocumentTreeStorageBridge(
    private val activity: ComponentActivity,
    binaryMessenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {
    private val methodChannel =
        MethodChannel(binaryMessenger, CHANNEL_NAME).also {
            it.setMethodCallHandler(this)
        }

    private var pendingPickResult: MethodChannel.Result? = null

    private val openDocumentTreeLauncher =
        activity.registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
            val pendingResult = pendingPickResult ?: return@registerForActivityResult
            pendingPickResult = null
            if (result.resultCode != Activity.RESULT_OK) {
                pendingResult.success(null)
                return@registerForActivityResult
            }

            val data = result.data
            val treeUri = data?.data
            if (treeUri == null) {
                pendingResult.success(null)
                return@registerForActivityResult
            }

            try {
                val grantedFlags =
                    (data.flags and
                        (Intent.FLAG_GRANT_READ_URI_PERMISSION or
                            Intent.FLAG_GRANT_WRITE_URI_PERMISSION))
                activity.contentResolver.takePersistableUriPermission(
                    treeUri,
                    if (grantedFlags == 0) {
                        Intent.FLAG_GRANT_READ_URI_PERMISSION or
                            Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                    } else {
                        grantedFlags
                    },
                )
                pendingResult.success(
                    mapOf(
                        "treeUri" to treeUri.toString(),
                        "displayName" to buildDisplayPath(treeUri),
                    ),
                )
            } catch (error: Throwable) {
                pendingResult.error(
                    "pick_directory_failed",
                    error.message ?: "Failed to open directory picker.",
                    null,
                )
            }
        }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "pickDirectory" -> handlePickDirectory(call, result)
                "resolveDirectory" -> handleResolveDirectory(call, result)
                "writeBytes" -> handleWriteBytes(call, result)
                "writeText" -> handleWriteText(call, result)
                "readText" -> handleReadText(call, result)
                "readBytes" -> handleReadBytes(call, result)
                "readBytesFromUri" -> handleReadBytesFromUri(call, result)
                "listEntries" -> handleListEntries(call, result)
                "exists" -> handleExists(call, result)
                "deletePath" -> handleDeletePath(call, result)
                else -> result.notImplemented()
            }
        } catch (error: Throwable) {
            result.error(
                "document_tree_error",
                error.message ?: error.toString(),
                null,
            )
        }
    }

    fun dispose() {
        pendingPickResult?.error(
            "pick_directory_cancelled",
            "Directory picker was cancelled.",
            null,
        )
        pendingPickResult = null
        methodChannel.setMethodCallHandler(null)
    }

    private fun handlePickDirectory(call: MethodCall, result: MethodChannel.Result) {
        if (pendingPickResult != null) {
            result.error(
                "pick_directory_busy",
                "Another directory picker request is already running.",
                null,
            )
            return
        }
        pendingPickResult = result
        val intent =
            Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
                addFlags(Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
            }
        openDocumentTreeLauncher.launch(intent)
    }

    private fun handleResolveDirectory(call: MethodCall, result: MethodChannel.Result) {
        val treeUri = call.requireString("treeUri")
        val relativePath = call.argument<String>("relativePath")?.trim().orEmpty()
        val verifyWritable = call.argument<Boolean>("verifyWritable") ?: true
        val tree = requireTree(treeUri)
        val basePath = buildDisplayPath(Uri.parse(treeUri)).ifBlank { treeUri }
        val rootDirectory =
            if (relativePath.isEmpty()) {
                tree
            } else {
                ensureDirectory(tree, splitRelativePath(relativePath))
            }
        val rootPath =
            if (relativePath.isBlank()) {
                basePath
            } else {
                "$basePath/$relativePath"
            }
        var errorMessage = ""
        var isWritable = rootDirectory.canWrite()

        if (verifyWritable) {
            try {
                writeProbe(rootDirectory)
                isWritable = true
            } catch (error: Throwable) {
                isWritable = false
                errorMessage = error.message ?: error.toString()
            }
        }

        result.success(
            mapOf(
                "basePath" to basePath,
                "rootPath" to rootPath,
                "isWritable" to isWritable,
                "errorMessage" to errorMessage,
            ),
        )
    }

    private fun handleWriteBytes(call: MethodCall, result: MethodChannel.Result) {
        val treeUri = call.requireString("treeUri")
        val relativePath = call.requireString("relativePath")
        val bytes = call.argument<ByteArray>("bytes") ?: ByteArray(0)
        writeBytes(treeUri, relativePath, bytes)
        result.success(null)
    }

    private fun handleWriteText(call: MethodCall, result: MethodChannel.Result) {
        val treeUri = call.requireString("treeUri")
        val relativePath = call.requireString("relativePath")
        val text = call.argument<String>("text") ?: ""
        writeBytes(treeUri, relativePath, text.toByteArray(Charsets.UTF_8))
        result.success(null)
    }

    private fun handleReadText(call: MethodCall, result: MethodChannel.Result) {
        val treeUri = call.requireString("treeUri")
        val relativePath = call.requireString("relativePath")
        val document = requireDocument(treeUri, relativePath)
        val text =
            activity.contentResolver.openInputStream(document.uri)?.bufferedReader(Charsets.UTF_8)?.use {
                it.readText()
            } ?: throw FileNotFoundException("Document not found: $relativePath")
        result.success(text)
    }

    private fun handleReadBytes(call: MethodCall, result: MethodChannel.Result) {
        val treeUri = call.requireString("treeUri")
        val relativePath = call.requireString("relativePath")
        val document = requireDocument(treeUri, relativePath)
        val bytes =
            activity.contentResolver.openInputStream(document.uri)?.use { input ->
                input.readBytes()
            } ?: throw FileNotFoundException("Document not found: $relativePath")
        result.success(bytes)
    }

    private fun handleReadBytesFromUri(call: MethodCall, result: MethodChannel.Result) {
        val documentUri = call.requireString("documentUri")
        val bytes =
            activity.contentResolver.openInputStream(Uri.parse(documentUri))?.use { input ->
                input.readBytes()
            } ?: throw FileNotFoundException("Document not found: $documentUri")
        result.success(bytes)
    }

    private fun handleListEntries(call: MethodCall, result: MethodChannel.Result) {
        val treeUri = call.requireString("treeUri")
        val relativePath = call.argument<String>("relativePath")?.trim().orEmpty()
        val recursive = call.argument<Boolean>("recursive") ?: false
        val tree = requireTree(treeUri)
        val baseDocument = resolveDocument(tree, splitRelativePath(relativePath))
        if (baseDocument == null || !baseDocument.exists()) {
            result.success(emptyList<Map<String, Any?>>())
            return
        }

        val baseSegments = splitRelativePath(relativePath)
        val results = mutableListOf<Map<String, Any?>>()
        if (baseDocument.isDirectory) {
            collectEntries(
                directory = baseDocument,
                prefixSegments = baseSegments,
                recursive = recursive,
                results = results,
            )
        } else {
            results.add(entryMap(relativePath = baseSegments.joinToString("/"), document = baseDocument))
        }
        result.success(results)
    }

    private fun handleExists(call: MethodCall, result: MethodChannel.Result) {
        val treeUri = call.requireString("treeUri")
        val relativePath = call.requireString("relativePath")
        val tree = requireTree(treeUri)
        val document = resolveDocument(tree, splitRelativePath(relativePath))
        result.success(document?.exists() == true)
    }

    private fun handleDeletePath(call: MethodCall, result: MethodChannel.Result) {
        val treeUri = call.requireString("treeUri")
        val relativePath = call.requireString("relativePath")
        if (relativePath.isBlank()) {
            result.success(false)
            return
        }
        val tree = requireTree(treeUri)
        val document = resolveDocument(tree, splitRelativePath(relativePath))
        result.success(document?.delete() == true)
    }

    private fun writeBytes(treeUri: String, relativePath: String, bytes: ByteArray) {
        val tree = requireTree(treeUri)
        val segments = splitRelativePath(relativePath)
        require(segments.isNotEmpty()) { "relativePath must not be empty." }
        val parent =
            ensureDirectory(
                tree,
                if (segments.size == 1) {
                    emptyList()
                } else {
                    segments.dropLast(1)
                },
            )
        val fileName = segments.last()
        val existing = parent.findFile(fileName)
        require(existing == null || existing.isFile) {
            "Target path is not a file: $relativePath"
        }
        val file =
            existing
                ?: parent.createFile(detectMimeType(fileName), fileName)
                ?: throw IOException("Failed to create document: $relativePath")
        activity.contentResolver.openOutputStream(file.uri, "rwt")?.use { output ->
            output.write(bytes)
            output.flush()
        } ?: throw IOException("Failed to open document for writing: $relativePath")
    }

    private fun requireTree(treeUri: String): DocumentFile {
        val documentFile =
            DocumentFile.fromTreeUri(activity, Uri.parse(treeUri))
                ?: throw FileNotFoundException("Invalid tree URI: $treeUri")
        require(documentFile.exists()) { "Storage location is no longer available." }
        require(documentFile.isDirectory) { "Selected storage location is not a directory." }
        return documentFile
    }

    private fun requireDocument(treeUri: String, relativePath: String): DocumentFile {
        val tree = requireTree(treeUri)
        return resolveDocument(tree, splitRelativePath(relativePath))
            ?: throw FileNotFoundException("Document not found: $relativePath")
    }

    private fun ensureDirectory(root: DocumentFile, segments: List<String>): DocumentFile {
        var current = root
        for (segment in segments) {
            val child = current.findFile(segment)
            current =
                when {
                    child == null ->
                        current.createDirectory(segment)
                            ?: throw IOException("Failed to create directory: $segment")
                    child.isDirectory -> child
                    else -> throw IOException("Path segment is not a directory: $segment")
                }
        }
        return current
    }

    private fun resolveDocument(root: DocumentFile, segments: List<String>): DocumentFile? {
        var current = root
        for ((index, segment) in segments.withIndex()) {
            val child = current.findFile(segment) ?: return null
            current = child
            if (index < segments.lastIndex && !current.isDirectory) {
                return null
            }
        }
        return current
    }

    private fun collectEntries(
        directory: DocumentFile,
        prefixSegments: List<String>,
        recursive: Boolean,
        results: MutableList<Map<String, Any?>>,
    ) {
        for (child in directory.listFiles()) {
            val childName = child.name?.trim().orEmpty()
            if (childName.isEmpty()) {
                continue
            }
            val relativeSegments = prefixSegments + childName
            val relativePath = relativeSegments.joinToString("/")
            results.add(entryMap(relativePath = relativePath, document = child))
            if (recursive && child.isDirectory) {
                collectEntries(child, relativeSegments, true, results)
            }
        }
    }

    private fun entryMap(relativePath: String, document: DocumentFile): Map<String, Any?> {
        return mapOf(
            "relativePath" to relativePath,
            "name" to (document.name ?: ""),
            "uri" to document.uri.toString(),
            "isDirectory" to document.isDirectory,
            "size" to document.length(),
            "lastModifiedMillis" to document.lastModified(),
        )
    }

    private fun writeProbe(rootDirectory: DocumentFile) {
        val probeName = ".storage_probe_${System.currentTimeMillis()}"
        val probe =
            rootDirectory.createFile("application/octet-stream", probeName)
                ?: throw IOException("Failed to create probe file.")
        try {
            activity.contentResolver.openOutputStream(probe.uri, "rwt")?.use { output ->
                output.write(byteArrayOf(1))
                output.flush()
            } ?: throw IOException("Failed to write probe file.")
        } finally {
            probe.delete()
        }
    }

    private fun splitRelativePath(relativePath: String): List<String> {
        return relativePath
            .replace('\\', '/')
            .split('/')
            .map { it.trim() }
            .filter { it.isNotEmpty() }
    }

    private fun buildDisplayPath(treeUri: Uri): String {
        val documentFile = DocumentFile.fromTreeUri(activity, treeUri)
        val name = documentFile?.name?.trim().orEmpty()
        if (name.isNotEmpty()) {
            return name
        }

        val documentId =
            runCatching { DocumentsContract.getTreeDocumentId(treeUri) }.getOrNull().orEmpty()
        if (documentId.equals("primary:", ignoreCase = true) || documentId.equals("primary", ignoreCase = true)) {
            return "内部存储"
        }
        if (documentId.startsWith("primary:", ignoreCase = true)) {
            val suffix = documentId.substringAfter(':').trim()
            return if (suffix.isEmpty()) "内部存储" else "内部存储/$suffix"
        }
        return if (documentId.isNotEmpty()) documentId else treeUri.toString()
    }

    private fun detectMimeType(fileName: String): String {
        val extension = fileName.substringAfterLast('.', "").lowercase()
        if (extension.isBlank()) {
            return "application/octet-stream"
        }
        return MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension)
            ?: when (extension) {
                "json" -> "application/json"
                "txt" -> "text/plain"
                else -> "application/octet-stream"
            }
    }

    private fun MethodCall.requireString(name: String): String {
        return argument<String>(name)?.trim().orEmpty().also { value ->
            require(value.isNotEmpty()) { "Missing argument: $name" }
        }
    }

    companion object {
        private const val CHANNEL_NAME = "easy_copy/download_storage/methods"
    }
}
