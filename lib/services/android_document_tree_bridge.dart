import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

@immutable
class PickedDocumentTreeDirectory {
  const PickedDocumentTreeDirectory({
    required this.treeUri,
    required this.displayName,
  });

  final String treeUri;
  final String displayName;

  factory PickedDocumentTreeDirectory.fromMap(Map<Object?, Object?> map) {
    return PickedDocumentTreeDirectory(
      treeUri: (map['treeUri'] as String?)?.trim() ?? '',
      displayName: (map['displayName'] as String?)?.trim() ?? '',
    );
  }
}

@immutable
class DocumentTreeDirectoryResolution {
  const DocumentTreeDirectoryResolution({
    required this.basePath,
    required this.rootPath,
    required this.isWritable,
    this.errorMessage = '',
  });

  final String basePath;
  final String rootPath;
  final bool isWritable;
  final String errorMessage;

  factory DocumentTreeDirectoryResolution.fromMap(Map<Object?, Object?> map) {
    return DocumentTreeDirectoryResolution(
      basePath: (map['basePath'] as String?)?.trim() ?? '',
      rootPath: (map['rootPath'] as String?)?.trim() ?? '',
      isWritable: (map['isWritable'] as bool?) ?? false,
      errorMessage: (map['errorMessage'] as String?)?.trim() ?? '',
    );
  }
}

@immutable
class DocumentTreeEntry {
  const DocumentTreeEntry({
    required this.relativePath,
    required this.name,
    required this.uri,
    required this.isDirectory,
    this.size = 0,
    this.lastModifiedMillis = 0,
  });

  final String relativePath;
  final String name;
  final String uri;
  final bool isDirectory;
  final int size;
  final int lastModifiedMillis;

  bool get isFile => !isDirectory;

  factory DocumentTreeEntry.fromMap(Map<Object?, Object?> map) {
    return DocumentTreeEntry(
      relativePath: (map['relativePath'] as String?)?.trim() ?? '',
      name: (map['name'] as String?)?.trim() ?? '',
      uri: (map['uri'] as String?)?.trim() ?? '',
      isDirectory: (map['isDirectory'] as bool?) ?? false,
      size: ((map['size'] as num?) ?? 0).round(),
      lastModifiedMillis: ((map['lastModifiedMillis'] as num?) ?? 0).round(),
    );
  }
}

class AndroidDocumentTreeBridge {
  AndroidDocumentTreeBridge({MethodChannel? methodChannel})
    : _methodChannel =
          methodChannel ??
          const MethodChannel('easy_copy/download_storage/methods');

  static final AndroidDocumentTreeBridge instance = AndroidDocumentTreeBridge();

  final MethodChannel _methodChannel;

  bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<PickedDocumentTreeDirectory?> pickDirectory() async {
    if (!isSupported) {
      return null;
    }
    final Map<Object?, Object?>? rawResult = await _methodChannel
        .invokeMapMethod<Object?, Object?>('pickDirectory');
    if (rawResult == null) {
      return null;
    }
    return PickedDocumentTreeDirectory.fromMap(rawResult);
  }

  Future<DocumentTreeDirectoryResolution> resolveDirectory({
    required String treeUri,
    String relativePath = '',
    bool verifyWritable = true,
  }) async {
    final Map<Object?, Object?>? rawResult = await _methodChannel
        .invokeMapMethod<Object?, Object?>(
          'resolveDirectory',
          <String, Object?>{
            'treeUri': treeUri,
            'relativePath': relativePath,
            'verifyWritable': verifyWritable,
          },
        );
    return DocumentTreeDirectoryResolution.fromMap(
      rawResult ?? const <Object?, Object?>{},
    );
  }

  Future<void> writeBytes({
    required String treeUri,
    required String relativePath,
    required Uint8List bytes,
  }) async {
    await _methodChannel.invokeMethod<void>('writeBytes', <String, Object?>{
      'treeUri': treeUri,
      'relativePath': relativePath,
      'bytes': bytes,
    });
  }

  Future<void> writeText({
    required String treeUri,
    required String relativePath,
    required String text,
  }) async {
    await _methodChannel.invokeMethod<void>('writeText', <String, Object?>{
      'treeUri': treeUri,
      'relativePath': relativePath,
      'text': text,
    });
  }

  Future<String> readText({
    required String treeUri,
    required String relativePath,
  }) async {
    final String? rawText = await _methodChannel.invokeMethod<String>(
      'readText',
      <String, Object?>{'treeUri': treeUri, 'relativePath': relativePath},
    );
    return rawText ?? '';
  }

  Future<Uint8List> readBytes({
    required String treeUri,
    required String relativePath,
  }) async {
    final Uint8List? rawBytes = await _methodChannel.invokeMethod<Uint8List>(
      'readBytes',
      <String, Object?>{'treeUri': treeUri, 'relativePath': relativePath},
    );
    return rawBytes ?? Uint8List(0);
  }

  Future<Uint8List> readBytesFromUri(String documentUri) async {
    final Uint8List? rawBytes = await _methodChannel.invokeMethod<Uint8List>(
      'readBytesFromUri',
      <String, Object?>{'documentUri': documentUri},
    );
    return rawBytes ?? Uint8List(0);
  }

  Future<List<DocumentTreeEntry>> listEntries({
    required String treeUri,
    String relativePath = '',
    bool recursive = false,
  }) async {
    final List<Object?> rawEntries =
        await _methodChannel.invokeListMethod<Object?>(
          'listEntries',
          <String, Object?>{
            'treeUri': treeUri,
            'relativePath': relativePath,
            'recursive': recursive,
          },
        ) ??
        const <Object?>[];
    return rawEntries
        .whereType<Map<Object?, Object?>>()
        .map(DocumentTreeEntry.fromMap)
        .toList(growable: false);
  }

  Future<bool> exists({
    required String treeUri,
    required String relativePath,
  }) async {
    return await _methodChannel.invokeMethod<bool>('exists', <String, Object?>{
          'treeUri': treeUri,
          'relativePath': relativePath,
        }) ??
        false;
  }

  Future<bool> deletePath({
    required String treeUri,
    required String relativePath,
  }) async {
    return await _methodChannel.invokeMethod<bool>(
          'deletePath',
          <String, Object?>{'treeUri': treeUri, 'relativePath': relativePath},
        ) ??
        false;
  }
}
