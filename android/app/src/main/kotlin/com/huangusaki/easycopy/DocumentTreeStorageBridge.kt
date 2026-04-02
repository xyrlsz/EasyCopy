package com.huangusaki.easycopy

import android.app.Activity
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.net.Uri
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.DocumentsContract
import android.util.Log
import android.webkit.MimeTypeMap
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts
import androidx.documentfile.provider.DocumentFile
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.FileNotFoundException
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.util.concurrent.Executors

class DocumentTreeStorageBridge(
    private val activity: ComponentActivity,
    binaryMessenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {
    private val methodChannel =
        MethodChannel(binaryMessenger, CHANNEL_NAME).also {
            it.setMethodCallHandler(this)
        }
    private val mainHandler = Handler(Looper.getMainLooper())
    private val foregroundIoExecutor =
        Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "easycopy-document-tree-foreground")
        }
    private val transferIoExecutor =
        Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "easycopy-document-tree-transfer")
        }
    private val debugLoggingEnabled =
        (activity.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0

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
                "importDirectoryFromPath" -> handleImportDirectoryFromPath(call, result)
                "exportDirectoryToPath" -> handleExportDirectoryToPath(call, result)
                "copyDirectoryToTree" -> handleCopyDirectoryToTree(call, result)
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
        foregroundIoExecutor.shutdown()
        transferIoExecutor.shutdown()
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
        runAsyncLogged(
            method = "resolveDirectory",
            result = result,
            relativePath = relativePath,
            recursive = false,
            extra = "verifyWritable=$verifyWritable",
        ) {
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

            mapOf(
                "basePath" to basePath,
                "rootPath" to rootPath,
                "isWritable" to isWritable,
                "errorMessage" to errorMessage,
            )
        }
    }

    private fun handleWriteBytes(call: MethodCall, result: MethodChannel.Result) {
        val treeUri = call.requireString("treeUri")
        val relativePath = call.requireString("relativePath")
        val bytes = call.argument<ByteArray>("bytes") ?: ByteArray(0)
        runAsyncLogged(
            method = "writeBytes",
            result = result,
            relativePath = relativePath,
            recursive = false,
            extra = "byteCount=${bytes.size}",
        ) {
            writeBytes(treeUri, relativePath, bytes)
            null
        }
    }

    private fun handleWriteText(call: MethodCall, result: MethodChannel.Result) {
        val treeUri = call.requireString("treeUri")
        val relativePath = call.requireString("relativePath")
        val text = call.argument<String>("text") ?: ""
        runAsyncLogged(
            method = "writeText",
            result = result,
            relativePath = relativePath,
            recursive = false,
            extra = "charCount=${text.length}",
        ) {
            writeBytes(treeUri, relativePath, text.toByteArray(Charsets.UTF_8))
            null
        }
    }

    private fun handleImportDirectoryFromPath(call: MethodCall, result: MethodChannel.Result) {
        runAsyncLogged(
            method = "importDirectoryFromPath",
            result = result,
            executor = transferIoExecutor,
            relativePath = call.argument<String>("relativePath")?.trim().orEmpty(),
            recursive = true,
            extra = "operationId=${call.argument<String>("operationId")?.trim().orEmpty()}",
        ) {
            val treeUri = call.requireString("treeUri")
            val sourcePath = call.requireString("sourcePath")
            val relativePath = call.argument<String>("relativePath")?.trim().orEmpty()
            val operationId = call.argument<String>("operationId")?.trim().orEmpty()
            val sourceDirectory = File(sourcePath)
            require(sourceDirectory.exists()) { "Source directory does not exist: $sourcePath" }
            require(sourceDirectory.isDirectory) { "Source path is not a directory: $sourcePath" }
            val targetRoot = resolveTargetDirectory(treeUri, relativePath)
            ensureNonOverlappingMigrationRoots(sourceDirectory, targetRoot)
            val progressReporter =
                ProgressReporter(
                    operationId = operationId,
                    totalCount = countMigratableFilesInDirectory(sourceDirectory),
                )
            progressReporter.dispatch(force = true)
            copyFileSystemDirectoryToDocumentTree(sourceDirectory, targetRoot, progressReporter)
            progressReporter.complete()
            null
        }
    }

    private fun handleExportDirectoryToPath(call: MethodCall, result: MethodChannel.Result) {
        runAsyncLogged(
            method = "exportDirectoryToPath",
            result = result,
            executor = transferIoExecutor,
            relativePath = call.argument<String>("relativePath")?.trim().orEmpty(),
            recursive = true,
            extra = "operationId=${call.argument<String>("operationId")?.trim().orEmpty()}",
        ) {
            val treeUri = call.requireString("treeUri")
            val destinationPath = call.requireString("destinationPath")
            val relativePath = call.argument<String>("relativePath")?.trim().orEmpty()
            val operationId = call.argument<String>("operationId")?.trim().orEmpty()
            val sourceRoot = resolveSourceDirectory(treeUri, relativePath)
            val destinationDirectory = File(destinationPath)
            destinationDirectory.mkdirs()
            require(destinationDirectory.exists()) {
                "Destination directory could not be created: $destinationPath"
            }
            require(destinationDirectory.isDirectory) {
                "Destination path is not a directory: $destinationPath"
            }
            ensureNonOverlappingMigrationRoots(sourceRoot, destinationDirectory)
            val progressReporter =
                ProgressReporter(
                    operationId = operationId,
                    totalCount = countMigratableFilesInDocumentTree(sourceRoot),
                )
            progressReporter.dispatch(force = true)
            copyDocumentTreeDirectoryToFileSystem(sourceRoot, destinationDirectory, progressReporter)
            progressReporter.complete()
            null
        }
    }

    private fun handleCopyDirectoryToTree(call: MethodCall, result: MethodChannel.Result) {
        runAsyncLogged(
            method = "copyDirectoryToTree",
            result = result,
            executor = transferIoExecutor,
            relativePath = call.argument<String>("sourceRelativePath")?.trim().orEmpty(),
            recursive = true,
            extra = "operationId=${call.argument<String>("operationId")?.trim().orEmpty()}",
        ) {
            val sourceTreeUri = call.requireString("sourceTreeUri")
            val targetTreeUri = call.requireString("targetTreeUri")
            val sourceRelativePath =
                call.argument<String>("sourceRelativePath")?.trim().orEmpty()
            val targetRelativePath =
                call.argument<String>("targetRelativePath")?.trim().orEmpty()
            val operationId = call.argument<String>("operationId")?.trim().orEmpty()
            val sourceRoot = resolveSourceDirectory(sourceTreeUri, sourceRelativePath)
            val targetRoot = resolveTargetDirectory(targetTreeUri, targetRelativePath)
            ensureNonOverlappingMigrationRoots(sourceRoot, targetRoot)
            val progressReporter =
                ProgressReporter(
                    operationId = operationId,
                    totalCount = countMigratableFilesInDocumentTree(sourceRoot),
                )
            progressReporter.dispatch(force = true)
            copyDocumentTreeDirectoryToDocumentTree(sourceRoot, targetRoot, progressReporter)
            progressReporter.complete()
            null
        }
    }

    private fun handleReadText(call: MethodCall, result: MethodChannel.Result) {
        val treeUri = call.requireString("treeUri")
        val relativePath = call.requireString("relativePath")
        runAsyncLogged(
            method = "readText",
            result = result,
            relativePath = relativePath,
            recursive = false,
        ) {
            val document = requireDocument(treeUri, relativePath)
            activity.contentResolver.openInputStream(document.uri)?.bufferedReader(
                Charsets.UTF_8,
            )?.use {
                it.readText()
            } ?: throw FileNotFoundException("Document not found: $relativePath")
        }
    }

    private fun handleReadBytes(call: MethodCall, result: MethodChannel.Result) {
        val treeUri = call.requireString("treeUri")
        val relativePath = call.requireString("relativePath")
        runAsyncLogged(
            method = "readBytes",
            result = result,
            relativePath = relativePath,
            recursive = false,
        ) {
            val document = requireDocument(treeUri, relativePath)
            activity.contentResolver.openInputStream(document.uri)?.use { input ->
                input.readBytes()
            } ?: throw FileNotFoundException("Document not found: $relativePath")
        }
    }

    private fun handleReadBytesFromUri(call: MethodCall, result: MethodChannel.Result) {
        val documentUri = call.requireString("documentUri")
        runAsyncLogged(
            method = "readBytesFromUri",
            result = result,
            relativePath = "",
            recursive = false,
            extra = "documentUri=${summarizeForLog(documentUri)}",
        ) {
            activity.contentResolver.openInputStream(Uri.parse(documentUri))?.use { input ->
                input.readBytes()
            } ?: throw FileNotFoundException("Document not found: $documentUri")
        }
    }

    private fun handleListEntries(call: MethodCall, result: MethodChannel.Result) {
        val treeUri = call.requireString("treeUri")
        val relativePath = call.argument<String>("relativePath")?.trim().orEmpty()
        val recursive = call.argument<Boolean>("recursive") ?: false
        runAsyncLogged(
            method = "listEntries",
            result = result,
            relativePath = relativePath,
            recursive = recursive,
        ) {
            val tree = requireTree(treeUri)
            val baseDocument = resolveDocument(tree, splitRelativePath(relativePath))
            if (baseDocument == null || !baseDocument.exists()) {
                return@runAsyncLogged emptyList<Map<String, Any?>>()
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
                results.add(
                    entryMap(
                        relativePath = baseSegments.joinToString("/"),
                        document = baseDocument,
                    ),
                )
            }
            results
        }
    }

    private fun handleExists(call: MethodCall, result: MethodChannel.Result) {
        val treeUri = call.requireString("treeUri")
        val relativePath = call.requireString("relativePath")
        runAsyncLogged(
            method = "exists",
            result = result,
            relativePath = relativePath,
            recursive = false,
        ) {
            val tree = requireTree(treeUri)
            val document = resolveDocument(tree, splitRelativePath(relativePath))
            document?.exists() == true
        }
    }

    private fun handleDeletePath(call: MethodCall, result: MethodChannel.Result) {
        val operationId = call.argument<String>("operationId")?.trim().orEmpty()
        runAsyncLogged(
            method = "deletePath",
            result = result,
            executor = if (operationId.isBlank()) foregroundIoExecutor else transferIoExecutor,
            relativePath = call.argument<String>("relativePath")?.trim().orEmpty(),
            recursive = false,
            extra = "operationId=$operationId",
        ) {
            val treeUri = call.requireString("treeUri")
            val relativePath = call.requireString("relativePath")
            if (relativePath.isBlank()) {
                return@runAsyncLogged false
            }
            val tree = requireTree(treeUri)
            val document = resolveDocument(tree, splitRelativePath(relativePath))
            if (document == null || !document.exists()) {
                return@runAsyncLogged false
            }
            if (operationId.isBlank()) {
                return@runAsyncLogged document.delete()
            }
            val progressReporter =
                ProgressReporter(
                    operationId = operationId,
                    totalCount = countFilesForDeletion(document),
                )
            progressReporter.dispatch(force = true)
            val deleted = deleteDocumentRecursively(document, relativePath, progressReporter)
            progressReporter.complete()
            deleted
        }
    }

    private inline fun <T> runAsyncLogged(
        method: String,
        result: MethodChannel.Result,
        executor: java.util.concurrent.Executor = foregroundIoExecutor,
        relativePath: String = "",
        recursive: Boolean = false,
        extra: String = "",
        crossinline block: () -> T,
    ) {
        executor.execute {
            val startedAt = SystemClock.elapsedRealtime()
            val threadName = Thread.currentThread().name
            try {
                val value = block()
                postSuccess(result, value)
                logAsyncOperation(
                    method = method,
                    relativePath = relativePath,
                    recursive = recursive,
                    elapsedMs = SystemClock.elapsedRealtime() - startedAt,
                    threadName = threadName,
                    success = true,
                    extra = extra,
                )
            } catch (error: Throwable) {
                postError(result, error)
                logAsyncOperation(
                    method = method,
                    relativePath = relativePath,
                    recursive = recursive,
                    elapsedMs = SystemClock.elapsedRealtime() - startedAt,
                    threadName = threadName,
                    success = false,
                    extra = extra,
                    error = error,
                )
            }
        }
    }

    private fun postSuccess(result: MethodChannel.Result, value: Any?) {
        mainHandler.post { result.success(value) }
    }

    private fun postError(result: MethodChannel.Result, error: Throwable) {
        mainHandler.post {
            result.error(
                "document_tree_error",
                error.message ?: error.toString(),
                null,
            )
        }
    }

    private fun logAsyncOperation(
        method: String,
        relativePath: String,
        recursive: Boolean,
        elapsedMs: Long,
        threadName: String,
        success: Boolean,
        extra: String = "",
        error: Throwable? = null,
    ) {
        if (!debugLoggingEnabled) {
            return
        }
        val message =
            buildString {
                append("method=").append(method)
                append(" relativePath=").append(quoteLogValue(relativePath))
                append(" recursive=").append(recursive)
                append(" elapsedMs=").append(elapsedMs)
                append(" threadName=").append(quoteLogValue(threadName))
                append(" status=").append(if (success) "ok" else "error")
                if (extra.isNotBlank()) {
                    append(' ').append(extra)
                }
                if (error != null) {
                    append(" error=").append(quoteLogValue(error.javaClass.simpleName))
                    append(" message=").append(quoteLogValue(error.message ?: error.toString()))
                }
            }
        if (success) {
            Log.d(TAG, message)
        } else {
            Log.w(TAG, message)
        }
    }

    private fun quoteLogValue(value: String): String {
        return "\"${value.replace("\"", "\\\"").replace("\n", " ").replace("\r", " ")}\""
    }

    private fun summarizeForLog(value: String, maxLength: Int = 80): String {
        val trimmed = value.trim().replace("\n", " ").replace("\r", " ")
        return if (trimmed.length <= maxLength) {
            trimmed
        } else {
            "${trimmed.take(maxLength - 3)}..."
        }
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

    private fun resolveTargetDirectory(treeUri: String, relativePath: String): DocumentFile {
        val tree = requireTree(treeUri)
        return if (relativePath.isBlank()) {
            tree
        } else {
            ensureDirectory(tree, splitRelativePath(relativePath))
        }
    }

    private fun resolveSourceDirectory(treeUri: String, relativePath: String): DocumentFile {
        val tree = requireTree(treeUri)
        val document =
            if (relativePath.isBlank()) {
                tree
            } else {
                resolveDocument(tree, splitRelativePath(relativePath))
            }
        require(document != null && document.exists()) {
            "Source directory is no longer available."
        }
        require(document.isDirectory) { "Source path is not a directory." }
        return document
    }

    private fun copyFileSystemDirectoryToDocumentTree(
        source: File,
        target: DocumentFile,
        progressReporter: ProgressReporter,
        relativePath: String = "",
    ) {
        val children = source.listFiles()?.sortedBy { it.name.lowercase() } ?: emptyList()
        for (child in children) {
            if (shouldSkipMigrationFile(child.name)) {
                continue
            }
            val childRelativePath =
                if (relativePath.isEmpty()) {
                    child.name
                } else {
                    "$relativePath/${child.name}"
                }
            if (child.isDirectory) {
                val targetDirectory = ensureChildDirectory(target, child.name)
                copyFileSystemDirectoryToDocumentTree(
                    child,
                    targetDirectory,
                    progressReporter,
                    childRelativePath,
                )
                continue
            }
            if (child.isFile) {
                copyFileToDocumentTree(child, target)
                progressReporter.advance(childRelativePath)
            }
        }
    }

    private fun copyDocumentTreeDirectoryToFileSystem(
        source: DocumentFile,
        target: File,
        progressReporter: ProgressReporter,
        relativePath: String = "",
    ) {
        val children = source.listFiles().sortedBy { it.name?.lowercase().orEmpty() }
        for (child in children) {
            val childName = child.name?.trim().orEmpty()
            if (childName.isEmpty() || shouldSkipMigrationFile(childName)) {
                continue
            }
            val childRelativePath =
                if (relativePath.isEmpty()) {
                    childName
                } else {
                    "$relativePath/$childName"
                }
            if (child.isDirectory) {
                val targetDirectory = File(target, childName)
                targetDirectory.mkdirs()
                copyDocumentTreeDirectoryToFileSystem(
                    child,
                    targetDirectory,
                    progressReporter,
                    childRelativePath,
                )
                continue
            }
            copyDocumentTreeFileToFileSystem(child, File(target, childName))
            progressReporter.advance(childRelativePath)
        }
    }

    private fun copyDocumentTreeDirectoryToDocumentTree(
        source: DocumentFile,
        target: DocumentFile,
        progressReporter: ProgressReporter,
        relativePath: String = "",
    ) {
        val children = source.listFiles().sortedBy { it.name?.lowercase().orEmpty() }
        for (child in children) {
            val childName = child.name?.trim().orEmpty()
            if (childName.isEmpty() || shouldSkipMigrationFile(childName)) {
                continue
            }
            val childRelativePath =
                if (relativePath.isEmpty()) {
                    childName
                } else {
                    "$relativePath/$childName"
                }
            if (child.isDirectory) {
                val targetDirectory = ensureChildDirectory(target, childName)
                copyDocumentTreeDirectoryToDocumentTree(
                    child,
                    targetDirectory,
                    progressReporter,
                    childRelativePath,
                )
                continue
            }
            copyDocumentTreeFileToDocumentTree(child, target)
            progressReporter.advance(childRelativePath)
        }
    }

    private fun copyFileToDocumentTree(source: File, targetDirectory: DocumentFile) {
        val targetFile = ensureChildFile(targetDirectory, source.name)
        FileInputStream(source).use { input ->
            activity.contentResolver.openOutputStream(targetFile.uri, "rwt")?.use { output ->
                copyStreams(input, output)
            } ?: throw IOException("Failed to open destination document: ${source.name}")
        }
    }

    private fun copyDocumentTreeFileToFileSystem(source: DocumentFile, target: File) {
        target.parentFile?.mkdirs()
        activity.contentResolver.openInputStream(source.uri)?.use { input ->
            FileOutputStream(target, false).use { output ->
                copyStreams(input, output)
            }
        } ?: throw IOException("Failed to open source document: ${source.name ?: source.uri}")
    }

    private fun copyDocumentTreeFileToDocumentTree(
        source: DocumentFile,
        targetDirectory: DocumentFile,
    ) {
        val sourceName = source.name?.trim().orEmpty()
        require(sourceName.isNotEmpty()) { "Source document name is empty." }
        val targetFile = ensureChildFile(targetDirectory, sourceName)
        activity.contentResolver.openInputStream(source.uri)?.use { input ->
            activity.contentResolver.openOutputStream(targetFile.uri, "rwt")?.use { output ->
                copyStreams(input, output)
            } ?: throw IOException("Failed to open destination document: $sourceName")
        } ?: throw IOException("Failed to open source document: $sourceName")
    }

    private fun ensureChildDirectory(parent: DocumentFile, name: String): DocumentFile {
        val existing = parent.findFile(name)
        return when {
            existing == null ->
                parent.createDirectory(name)
                    ?: throw IOException("Failed to create directory: $name")
            existing.isDirectory -> existing
            else -> throw IOException("Path segment is not a directory: $name")
        }
    }

    private fun ensureChildFile(parent: DocumentFile, fileName: String): DocumentFile {
        val existing = parent.findFile(fileName)
        return when {
            existing == null ->
                parent.createFile(detectMimeType(fileName), fileName)
                    ?: throw IOException("Failed to create document: $fileName")
            existing.isFile -> existing
            else -> throw IOException("Target path is not a file: $fileName")
        }
    }

    private fun copyStreams(input: InputStream, output: OutputStream) {
        val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
        while (true) {
            val read = input.read(buffer)
            if (read <= 0) {
                break
            }
            output.write(buffer, 0, read)
        }
        output.flush()
    }

    private fun ensureNonOverlappingMigrationRoots(sourceDirectory: File, targetDirectory: DocumentFile) {
        ensureNonOverlappingMigrationRoots(
            sourceComparablePath = comparableFilePath(sourceDirectory),
            targetComparablePath = comparableDocumentPath(targetDirectory),
        )
    }

    private fun ensureNonOverlappingMigrationRoots(sourceDirectory: DocumentFile, targetDirectory: File) {
        ensureNonOverlappingMigrationRoots(
            sourceComparablePath = comparableDocumentPath(sourceDirectory),
            targetComparablePath = comparableFilePath(targetDirectory),
        )
    }

    private fun ensureNonOverlappingMigrationRoots(
        sourceDirectory: DocumentFile,
        targetDirectory: DocumentFile,
    ) {
        ensureNonOverlappingMigrationRoots(
            sourceComparablePath = comparableDocumentPath(sourceDirectory),
            targetComparablePath = comparableDocumentPath(targetDirectory),
        )
    }

    private fun ensureNonOverlappingMigrationRoots(
        sourceComparablePath: String?,
        targetComparablePath: String?,
    ) {
        if (sourceComparablePath.isNullOrBlank() || targetComparablePath.isNullOrBlank()) {
            return
        }
        require(
            !isNestedComparablePath(sourceComparablePath, targetComparablePath) &&
                !isNestedComparablePath(targetComparablePath, sourceComparablePath),
        ) {
            "目标缓存目录不能位于当前缓存目录内部，也不能包含当前缓存目录。"
        }
    }

    private fun comparableFilePath(directory: File): String? {
        return runCatching { normalizeComparablePath(directory.canonicalFile.absolutePath) }.getOrNull()
    }

    private fun comparableDocumentPath(document: DocumentFile): String? {
        val documentId =
            runCatching { DocumentsContract.getDocumentId(document.uri) }
                .getOrElse {
                    runCatching { DocumentsContract.getTreeDocumentId(document.uri) }.getOrNull()
                }?.trim().orEmpty()
        if (documentId.isEmpty()) {
            return null
        }
        return comparablePathFromDocumentId(documentId)
    }

    private fun comparablePathFromDocumentId(documentId: String): String? {
        val normalizedId = documentId.trim()
        if (normalizedId.isEmpty()) {
            return null
        }
        if (normalizedId.startsWith("raw:", ignoreCase = true)) {
            return normalizeComparablePath(normalizedId.substringAfter(':'))
        }
        val volumeId = normalizedId.substringBefore(':').trim()
        val relativePath =
            normalizedId
                .substringAfter(':', "")
                .trim()
                .replace('\\', '/')
        if (volumeId.isEmpty()) {
            return null
        }
        val basePath =
            when {
                volumeId.equals("primary", ignoreCase = true) ->
                    Environment.getExternalStorageDirectory().absolutePath
                volumeId.equals("home", ignoreCase = true) ->
                    File(Environment.getExternalStorageDirectory(), "Documents").path
                else -> File("/storage/$volumeId").path
            }
        val combinedPath =
            if (relativePath.isEmpty()) {
                basePath
            } else {
                File(basePath, relativePath.replace('/', File.separatorChar)).path
            }
        return normalizeComparablePath(combinedPath)
    }

    private fun normalizeComparablePath(path: String): String {
        return path
            .trim()
            .replace('\\', '/')
            .trimEnd('/')
            .lowercase()
    }

    private fun isNestedComparablePath(candidate: String, parent: String): Boolean {
        return candidate == parent || candidate.startsWith("$parent/")
    }

    private fun countMigratableFilesInDirectory(directory: File): Int {
        var count = 0
        val children = directory.listFiles() ?: return 0
        for (child in children) {
            if (shouldSkipMigrationFile(child.name)) {
                continue
            }
            count +=
                when {
                    child.isDirectory -> countMigratableFilesInDirectory(child)
                    child.isFile -> 1
                    else -> 0
                }
        }
        return count
    }

    private fun countMigratableFilesInDocumentTree(directory: DocumentFile): Int {
        var count = 0
        for (child in directory.listFiles()) {
            val childName = child.name?.trim().orEmpty()
            if (childName.isEmpty() || shouldSkipMigrationFile(childName)) {
                continue
            }
            count +=
                when {
                    child.isDirectory -> countMigratableFilesInDocumentTree(child)
                    child.isFile -> 1
                    else -> 0
                }
        }
        return count
    }

    private fun countFilesForDeletion(document: DocumentFile): Int {
        if (document.isFile) {
            return 1
        }
        var count = 0
        for (child in document.listFiles()) {
            val childName = child.name?.trim().orEmpty()
            if (childName.isEmpty()) {
                continue
            }
            count += countFilesForDeletion(child)
        }
        return count
    }

    private fun deleteDocumentRecursively(
        document: DocumentFile,
        relativePath: String,
        progressReporter: ProgressReporter,
    ): Boolean {
        if (document.isDirectory) {
            for (child in document.listFiles()) {
                val childName = child.name?.trim().orEmpty()
                if (childName.isEmpty()) {
                    continue
                }
                val childRelativePath =
                    if (relativePath.isEmpty()) {
                        childName
                    } else {
                        "$relativePath/$childName"
                    }
                if (!deleteDocumentRecursively(child, childRelativePath, progressReporter)) {
                    return false
                }
            }
            return document.delete()
        }

        val deleted = document.delete()
        if (deleted) {
            progressReporter.advance(relativePath)
        }
        return deleted
    }

    private fun shouldSkipMigrationFile(fileName: String): Boolean {
        val normalized = fileName.trim().lowercase()
        if (normalized.isEmpty()) {
            return false
        }
        return normalized.endsWith(".part") ||
            normalized.endsWith(".migrate_tmp") ||
            normalized.startsWith(".storage_probe_")
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

    private inner class ProgressReporter(
        private val operationId: String,
        private val totalCount: Int,
    ) {
        private var completedCount = 0
        private var lastDispatchedAtMillis = 0L
        private var lastDispatchedCompletedCount = 0

        fun advance(currentItemPath: String) {
            completedCount += 1
            dispatch(currentItemPath)
        }

        fun complete() {
            if (completedCount < totalCount) {
                completedCount = totalCount
            }
            dispatch(force = true)
        }

        fun dispatch(currentItemPath: String = "", force: Boolean = false) {
            if (operationId.isBlank()) {
                return
            }
            val now = SystemClock.uptimeMillis()
            val dispatchStep =
                when {
                    totalCount >= 4096 -> 320
                    totalCount >= 1024 -> 192
                    totalCount >= 256 -> 96
                    else -> 24
                }
            val dispatchIntervalMillis =
                when {
                    totalCount >= 1024 -> 900L
                    totalCount >= 256 -> 600L
                    else -> 320L
                }
            val shouldDispatch =
                force ||
                    completedCount >= totalCount ||
                    completedCount <= 1 ||
                    completedCount - lastDispatchedCompletedCount >= dispatchStep ||
                    now - lastDispatchedAtMillis >= dispatchIntervalMillis
            if (!shouldDispatch) {
                return
            }
            lastDispatchedAtMillis = now
            lastDispatchedCompletedCount = completedCount
            emitProgress(
                operationId = operationId,
                completedCount = completedCount,
                totalCount = totalCount,
                currentItemPath = currentItemPath,
            )
        }
    }

    private fun emitProgress(
        operationId: String,
        completedCount: Int,
        totalCount: Int,
        currentItemPath: String,
    ) {
        mainHandler.post {
            methodChannel.invokeMethod(
                "documentTreeProgress",
                mapOf(
                    "operationId" to operationId,
                    "completedCount" to completedCount,
                    "totalCount" to totalCount,
                    "currentItemPath" to currentItemPath.replace('\\', '/'),
                ),
            )
        }
    }

    companion object {
        private const val CHANNEL_NAME = "easy_copy/download_storage/methods"
        private const val TAG = "DocumentTreeStorageBridge"
    }
}
