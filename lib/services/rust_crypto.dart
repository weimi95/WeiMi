import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as path;

class RustCrypto {
  static ffi.DynamicLibrary? _lib;

  /// 供其他服务复用动态库（自动加载，已加载直接返回）
  static ffi.DynamicLibrary ensureLib() {
    _loadLibrary();
    return _lib!;
  }

  static void _loadLibrary() {
    if (_lib != null) return;
    
    if (Platform.isWindows) {
      final exePath = Platform.resolvedExecutable;
      final exeDir = path.dirname(exePath);
      final dllPath = path.join(exeDir, 'rust_crypto.dll');
      _lib = ffi.DynamicLibrary.open(dllPath);
    } else if (Platform.isLinux) {
      _lib = ffi.DynamicLibrary.open('rust_crypto/target/release/librust_crypto.so');
    } else if (Platform.isMacOS) {
      final exePath = Platform.resolvedExecutable;
      final exeDir = path.dirname(exePath);
      final dylibPath = path.join(exeDir, '..', 'Resources', 'librust_crypto.dylib');
      _lib = ffi.DynamicLibrary.open(dylibPath);
    } else if (Platform.isAndroid) {
      _lib = ffi.DynamicLibrary.open('librust_crypto.so');
    } else if (Platform.isIOS) {
      _lib = ffi.DynamicLibrary.process();
    } else {
      throw UnsupportedError('Unsupported platform');
    }
  }

  static Uint8List encryptData(Uint8List data, Uint8List password, Uint8List nonce) {
    _loadLibrary();
    
    final encryptFunc = _lib!.lookupFunction<
      ffi.Int32 Function(
        ffi.Pointer<ffi.Uint8> dataPtr,
        ffi.Size dataLen,
        ffi.Pointer<ffi.Uint8> passwordPtr,
        ffi.Size passwordLen,
        ffi.Pointer<ffi.Uint8> noncePtr,
        ffi.Pointer<ffi.Uint8> outputPtr,
        ffi.Pointer<ffi.Size> outputLen,
      ),
      int Function(
        ffi.Pointer<ffi.Uint8> dataPtr,
        int dataLen,
        ffi.Pointer<ffi.Uint8> passwordPtr,
        int passwordLen,
        ffi.Pointer<ffi.Uint8> noncePtr,
        ffi.Pointer<ffi.Uint8> outputPtr,
        ffi.Pointer<ffi.Size> outputLen,
      )
    >('encrypt_data');

    final dataPtr = _allocateUint8List(data);
    final passwordPtr = _allocateUint8List(password);
    final noncePtr = _allocateUint8List(nonce);
    final outputLenPtr = calloc<ffi.Size>();

    try {
      var result = encryptFunc(
        dataPtr,
        data.length,
        passwordPtr,
        password.length,
        noncePtr,
        ffi.nullptr,
        outputLenPtr,
      );

      if (result != 0) {
        throw Exception('Encryption failed with code: $result');
      }

      final outputLen = outputLenPtr.value;
      final outputPtr = calloc<ffi.Uint8>(outputLen);

      try {
        result = encryptFunc(
          dataPtr,
          data.length,
          passwordPtr,
          password.length,
          noncePtr,
          outputPtr,
          outputLenPtr,
        );

        if (result != 0) {
          throw Exception('Encryption failed with code: $result');
        }

        return Uint8List.fromList(
          outputPtr.asTypedList(outputLen),
        );
      } finally {
        calloc.free(outputPtr);
      }
    } finally {
      calloc.free(dataPtr);
      calloc.free(passwordPtr);
      calloc.free(noncePtr);
      calloc.free(outputLenPtr);
    }
  }

  static Uint8List decryptData(
    Uint8List encrypted,
    Uint8List password,
    Uint8List nonce,
  ) {
    _loadLibrary();
    
    final decryptFunc = _lib!.lookupFunction<
      ffi.Int32 Function(
        ffi.Pointer<ffi.Uint8> encryptedPtr,
        ffi.Size encryptedLen,
        ffi.Pointer<ffi.Uint8> passwordPtr,
        ffi.Size passwordLen,
        ffi.Pointer<ffi.Uint8> noncePtr,
        ffi.Pointer<ffi.Uint8> outputPtr,
        ffi.Pointer<ffi.Size> outputLen,
      ),
      int Function(
        ffi.Pointer<ffi.Uint8> encryptedPtr,
        int encryptedLen,
        ffi.Pointer<ffi.Uint8> passwordPtr,
        int passwordLen,
        ffi.Pointer<ffi.Uint8> noncePtr,
        ffi.Pointer<ffi.Uint8> outputPtr,
        ffi.Pointer<ffi.Size> outputLen,
      )
    >('decrypt_data');

    final encryptedPtr = _allocateUint8List(encrypted);
    final passwordPtr = _allocateUint8List(password);
    final noncePtr = _allocateUint8List(nonce);
    final outputLenPtr = calloc<ffi.Size>();

    try {
      var result = decryptFunc(
        encryptedPtr,
        encrypted.length,
        passwordPtr,
        password.length,
        noncePtr,
        ffi.nullptr,
        outputLenPtr,
      );

      if (result != 0) {
        throw Exception('Decryption failed with code: $result');
      }

      final outputLen = outputLenPtr.value;
      final outputPtr = calloc<ffi.Uint8>(outputLen);

      try {
        result = decryptFunc(
          encryptedPtr,
          encrypted.length,
          passwordPtr,
          password.length,
          noncePtr,
          outputPtr,
          outputLenPtr,
        );

        if (result != 0) {
          throw Exception('Decryption failed with code: $result');
        }

        return Uint8List.fromList(
          outputPtr.asTypedList(outputLen),
        );
      } finally {
        calloc.free(outputPtr);
      }
    } finally {
      calloc.free(encryptedPtr);
      calloc.free(passwordPtr);
      calloc.free(noncePtr);
      calloc.free(outputLenPtr);
    }
  }

  static Uint8List deriveKey(Uint8List password) {
    _loadLibrary();
    
    final deriveKeyFunc = _lib!.lookupFunction<
      ffi.Int32 Function(
        ffi.Pointer<ffi.Uint8> passwordPtr,
        ffi.Size passwordLen,
        ffi.Pointer<ffi.Uint8> outputPtr,
      ),
      int Function(
        ffi.Pointer<ffi.Uint8> passwordPtr,
        int passwordLen,
        ffi.Pointer<ffi.Uint8> outputPtr,
      )
    >('derive_key_ffi');

    final passwordPtr = _allocateUint8List(password);
    final outputPtr = calloc<ffi.Uint8>(32);

    try {
      final result = deriveKeyFunc(passwordPtr, password.length, outputPtr);

      if (result != 0) {
        throw Exception('Key derivation failed with code: $result');
      }

      return Uint8List.fromList(outputPtr.asTypedList(32));
    } finally {
      calloc.free(passwordPtr);
      calloc.free(outputPtr);
    }
  }

  static ffi.Pointer<ffi.Uint8> _allocateUint8List(Uint8List list) {
    final ptr = calloc<ffi.Uint8>(list.length);
    for (var i = 0; i < list.length; i++) {
      ptr[i] = list[i];
    }
    return ptr;
  }

  static List<Uint8List> encryptDataParallel(
    List<Uint8List> chunks,
    Uint8List password,
    List<Uint8List> nonces,
  ) {
    _loadLibrary();

    if (chunks.isEmpty || chunks.length != nonces.length) {
      throw ArgumentError('Chunks and nonces must have the same length');
    }

    final encryptFunc = _lib!.lookupFunction<
      ffi.Int32 Function(
        ffi.Pointer<ffi.Pointer<ffi.Uint8>> chunksPtr,
        ffi.Pointer<ffi.Size> chunkLens,
        ffi.Size numChunks,
        ffi.Pointer<ffi.Uint8> passwordPtr,
        ffi.Size passwordLen,
        ffi.Pointer<ffi.Uint8> noncesPtr,
        ffi.Pointer<ffi.Pointer<ffi.Uint8>> outputsPtr,
        ffi.Pointer<ffi.Size> outputLens,
      ),
      int Function(
        ffi.Pointer<ffi.Pointer<ffi.Uint8>> chunksPtr,
        ffi.Pointer<ffi.Size> chunkLens,
        int numChunks,
        ffi.Pointer<ffi.Uint8> passwordPtr,
        int passwordLen,
        ffi.Pointer<ffi.Uint8> noncesPtr,
        ffi.Pointer<ffi.Pointer<ffi.Uint8>> outputsPtr,
        ffi.Pointer<ffi.Size> outputLens,
      )
    >('encrypt_data_parallel');

    final numChunks = chunks.length;
    final chunkPtrs = calloc<ffi.Pointer<ffi.Uint8>>(numChunks);
    final chunkLens = calloc<ffi.Size>(numChunks);
    final passwordPtr = _allocateUint8List(password);
    
    final totalNonceSize = nonces.length * 12;
    final noncesPtr = calloc<ffi.Uint8>(totalNonceSize);
    for (var i = 0; i < nonces.length; i++) {
      for (var j = 0; j < 12; j++) {
        noncesPtr[i * 12 + j] = nonces[i][j];
      }
    }

    for (var i = 0; i < numChunks; i++) {
      chunkPtrs[i] = _allocateUint8List(chunks[i]);
      chunkLens[i] = chunks[i].length;
    }

    final outputPtrs = calloc<ffi.Pointer<ffi.Uint8>>(numChunks);
    final outputLens = calloc<ffi.Size>(numChunks);

    for (var i = 0; i < numChunks; i++) {
      outputPtrs[i] = ffi.nullptr;
    }

    try {
      var result = encryptFunc(
        chunkPtrs,
        chunkLens,
        numChunks,
        passwordPtr,
        password.length,
        noncesPtr,
        outputPtrs,
        outputLens,
      );

      if (result != 0) {
        throw Exception('Parallel encryption failed with code: $result');
      }

      for (var i = 0; i < numChunks; i++) {
        final len = outputLens[i];
        outputPtrs[i] = calloc<ffi.Uint8>(len);
      }

      result = encryptFunc(
        chunkPtrs,
        chunkLens,
        numChunks,
        passwordPtr,
        password.length,
        noncesPtr,
        outputPtrs,
        outputLens,
      );

      if (result != 0) {
        throw Exception('Parallel encryption failed with code: $result');
      }

      final results = <Uint8List>[];
      for (var i = 0; i < numChunks; i++) {
        final len = outputLens[i];
        results.add(Uint8List.fromList(outputPtrs[i].asTypedList(len)));
      }

      return results;
    } finally {
      for (var i = 0; i < numChunks; i++) {
        calloc.free(chunkPtrs[i]);
        if (outputPtrs[i] != ffi.nullptr) {
          calloc.free(outputPtrs[i]);
        }
      }
      calloc.free(chunkPtrs);
      calloc.free(chunkLens);
      calloc.free(passwordPtr);
      calloc.free(noncesPtr);
      calloc.free(outputPtrs);
      calloc.free(outputLens);
    }
  }

  static List<Uint8List> decryptDataParallel(
    List<Uint8List> chunks,
    Uint8List password,
    List<Uint8List> nonces,
  ) {
    _loadLibrary();

    if (chunks.isEmpty || chunks.length != nonces.length) {
      throw ArgumentError('Chunks and nonces must have the same length');
    }

    final decryptFunc = _lib!.lookupFunction<
      ffi.Int32 Function(
        ffi.Pointer<ffi.Pointer<ffi.Uint8>> chunksPtr,
        ffi.Pointer<ffi.Size> chunkLens,
        ffi.Size numChunks,
        ffi.Pointer<ffi.Uint8> passwordPtr,
        ffi.Size passwordLen,
        ffi.Pointer<ffi.Uint8> noncesPtr,
        ffi.Pointer<ffi.Pointer<ffi.Uint8>> outputsPtr,
        ffi.Pointer<ffi.Size> outputLens,
      ),
      int Function(
        ffi.Pointer<ffi.Pointer<ffi.Uint8>> chunksPtr,
        ffi.Pointer<ffi.Size> chunkLens,
        int numChunks,
        ffi.Pointer<ffi.Uint8> passwordPtr,
        int passwordLen,
        ffi.Pointer<ffi.Uint8> noncesPtr,
        ffi.Pointer<ffi.Pointer<ffi.Uint8>> outputsPtr,
        ffi.Pointer<ffi.Size> outputLens,
      )
    >('decrypt_data_parallel');

    final numChunks = chunks.length;
    final chunkPtrs = calloc<ffi.Pointer<ffi.Uint8>>(numChunks);
    final chunkLens = calloc<ffi.Size>(numChunks);
    final passwordPtr = _allocateUint8List(password);
    
    final totalNonceSize = nonces.length * 12;
    final noncesPtr = calloc<ffi.Uint8>(totalNonceSize);
    for (var i = 0; i < nonces.length; i++) {
      for (var j = 0; j < 12; j++) {
        noncesPtr[i * 12 + j] = nonces[i][j];
      }
    }

    for (var i = 0; i < numChunks; i++) {
      chunkPtrs[i] = _allocateUint8List(chunks[i]);
      chunkLens[i] = chunks[i].length;
    }

    final outputPtrs = calloc<ffi.Pointer<ffi.Uint8>>(numChunks);
    final outputLens = calloc<ffi.Size>(numChunks);

    for (var i = 0; i < numChunks; i++) {
      outputPtrs[i] = ffi.nullptr;
    }

    try {
      var result = decryptFunc(
        chunkPtrs,
        chunkLens,
        numChunks,
        passwordPtr,
        password.length,
        noncesPtr,
        outputPtrs,
        outputLens,
      );

      if (result != 0) {
        throw Exception('Parallel decryption failed with code: $result');
      }

      for (var i = 0; i < numChunks; i++) {
        final len = outputLens[i];
        outputPtrs[i] = calloc<ffi.Uint8>(len);
      }

      result = decryptFunc(
        chunkPtrs,
        chunkLens,
        numChunks,
        passwordPtr,
        password.length,
        noncesPtr,
        outputPtrs,
        outputLens,
      );

      if (result != 0) {
        throw Exception('Parallel decryption failed with code: $result');
      }

      final results = <Uint8List>[];
      for (var i = 0; i < numChunks; i++) {
        final len = outputLens[i];
        results.add(Uint8List.fromList(outputPtrs[i].asTypedList(len)));
      }

      return results;
    } finally {
      for (var i = 0; i < numChunks; i++) {
        calloc.free(chunkPtrs[i]);
        if (outputPtrs[i] != ffi.nullptr) {
          calloc.free(outputPtrs[i]);
        }
      }
      calloc.free(chunkPtrs);
      calloc.free(chunkLens);
      calloc.free(passwordPtr);
      calloc.free(noncesPtr);
      calloc.free(outputPtrs);
      calloc.free(outputLens);
    }
  }

  static void encryptFile(
    String inputPath,
    String outputPath,
    Uint8List password, {
    String? hint,
    bool isMobile = false,
  }) {
    _loadLibrary();

    final encryptFileFunc = _lib!.lookupFunction<
      ffi.Int32 Function(
        ffi.Pointer<ffi.Char> inputPathPtr,
        ffi.Pointer<ffi.Char> outputPathPtr,
        ffi.Pointer<ffi.Uint8> passwordPtr,
        ffi.Size passwordLen,
        ffi.Pointer<ffi.Char> hintPtr,
        ffi.Bool isMobile,
        ffi.Size cpuCores,
      ),
      int Function(
        ffi.Pointer<ffi.Char> inputPathPtr,
        ffi.Pointer<ffi.Char> outputPathPtr,
        ffi.Pointer<ffi.Uint8> passwordPtr,
        int passwordLen,
        ffi.Pointer<ffi.Char> hintPtr,
        bool isMobile,
        int cpuCores,
      )
    >('encrypt_file');

    final inputPathPtr = inputPath.toNativeUtf8().cast<ffi.Char>();
    final outputPathPtr = outputPath.toNativeUtf8().cast<ffi.Char>();
    final passwordPtr = _allocateUint8List(password);
    final hintPtr = hint != null 
        ? hint.toNativeUtf8().cast<ffi.Char>() 
        : ffi.nullptr;
    final cpuCores = Platform.numberOfProcessors;

    try {
      final result = encryptFileFunc(
        inputPathPtr,
        outputPathPtr,
        passwordPtr,
        password.length,
        hintPtr,
        isMobile,
        cpuCores,
      );

      if (result != 0) {
        throw Exception('File encryption failed with code: $result');
      }
    } finally {
      calloc.free(inputPathPtr);
      calloc.free(outputPathPtr);
      calloc.free(passwordPtr);
      if (hintPtr != ffi.nullptr) {
        calloc.free(hintPtr);
      }
    }
  }

  static void decryptFile(
    String inputPath,
    String outputPath,
    Uint8List password, {
    bool isMobile = false,
  }) {
    _loadLibrary();

    final decryptFileFunc = _lib!.lookupFunction<
      ffi.Int32 Function(
        ffi.Pointer<ffi.Char> inputPathPtr,
        ffi.Pointer<ffi.Char> outputPathPtr,
        ffi.Pointer<ffi.Uint8> passwordPtr,
        ffi.Size passwordLen,
        ffi.Bool isMobile,
        ffi.Size cpuCores,
      ),
      int Function(
        ffi.Pointer<ffi.Char> inputPathPtr,
        ffi.Pointer<ffi.Char> outputPathPtr,
        ffi.Pointer<ffi.Uint8> passwordPtr,
        int passwordLen,
        bool isMobile,
        int cpuCores,
      )
    >('decrypt_file');

    final inputPathPtr = inputPath.toNativeUtf8().cast<ffi.Char>();
    final outputPathPtr = outputPath.toNativeUtf8().cast<ffi.Char>();
    final passwordPtr = _allocateUint8List(password);
    final cpuCores = Platform.numberOfProcessors;

    try {
      final result = decryptFileFunc(
        inputPathPtr,
        outputPathPtr,
        passwordPtr,
        password.length,
        isMobile,
        cpuCores,
      );

      if (result != 0) {
        throw Exception('File decryption failed with code: $result');
      }
    } finally {
      calloc.free(inputPathPtr);
      calloc.free(outputPathPtr);
      calloc.free(passwordPtr);
    }
  }

  static Uint8List decryptFileToMemory(
    String inputPath,
    Uint8List password, {
    bool isMobile = false,
  }) {
    _loadLibrary();

    final decryptFileToMemoryFunc = _lib!.lookupFunction<
      ffi.Int32 Function(
        ffi.Pointer<ffi.Char> inputPathPtr,
        ffi.Pointer<ffi.Uint8> passwordPtr,
        ffi.Size passwordLen,
        ffi.Pointer<ffi.Uint8> outputPtr,
        ffi.Pointer<ffi.Size> outputLen,
        ffi.Bool isMobile,
        ffi.Size cpuCores,
      ),
      int Function(
        ffi.Pointer<ffi.Char> inputPathPtr,
        ffi.Pointer<ffi.Uint8> passwordPtr,
        int passwordLen,
        ffi.Pointer<ffi.Uint8> outputPtr,
        ffi.Pointer<ffi.Size> outputLen,
        bool isMobile,
        int cpuCores,
      )
    >('decrypt_file_to_memory');

    final inputPathPtr = inputPath.toNativeUtf8().cast<ffi.Char>();
    final passwordPtr = _allocateUint8List(password);
    final outputLenPtr = calloc<ffi.Size>();
    final cpuCores = Platform.numberOfProcessors;

    try {
      var result = decryptFileToMemoryFunc(
        inputPathPtr,
        passwordPtr,
        password.length,
        ffi.nullptr,
        outputLenPtr,
        isMobile,
        cpuCores,
      );

      if (result != 0) {
        throw Exception('File decryption to memory failed with code: $result');
      }

      final outputLen = outputLenPtr.value;
      final outputPtr = calloc<ffi.Uint8>(outputLen);

      try {
        result = decryptFileToMemoryFunc(
          inputPathPtr,
          passwordPtr,
          password.length,
          outputPtr,
          outputLenPtr,
          isMobile,
          cpuCores,
        );

        if (result != 0) {
          throw Exception('File decryption to memory failed with code: $result');
        }

        return Uint8List.fromList(outputPtr.asTypedList(outputLen));
      } finally {
        calloc.free(outputPtr);
      }
    } finally {
      calloc.free(inputPathPtr);
      calloc.free(passwordPtr);
      calloc.free(outputLenPtr);
    }
  }

  static String getHintFromFile(String inputPath) {
    _loadLibrary();

    final getHintFunc = _lib!.lookupFunction<
      ffi.Int32 Function(
        ffi.Pointer<ffi.Char> inputPathPtr,
        ffi.Pointer<ffi.Uint8> hintPtr,
        ffi.Pointer<ffi.Size> hintLen,
      ),
      int Function(
        ffi.Pointer<ffi.Char> inputPathPtr,
        ffi.Pointer<ffi.Uint8> hintPtr,
        ffi.Pointer<ffi.Size> hintLen,
      )
    >('get_hint_from_file');

    final inputPathPtr = inputPath.toNativeUtf8().cast<ffi.Char>();
    final hintLenPtr = calloc<ffi.Size>();

    try {
      var result = getHintFunc(
        inputPathPtr,
        ffi.nullptr,
        hintLenPtr,
      );

      if (result != 0) {
        throw Exception('Get hint failed with code: $result');
      }

      final hintLen = hintLenPtr.value;
      if (hintLen == 0) {
        return '';
      }

      final hintPtr = calloc<ffi.Uint8>(hintLen);

      try {
        result = getHintFunc(
          inputPathPtr,
          hintPtr,
          hintLenPtr,
        );

        if (result != 0) {
          throw Exception('Get hint failed with code: $result');
        }

        final hintBytes = Uint8List.fromList(hintPtr.asTypedList(hintLen));
        return String.fromCharCodes(hintBytes);
      } finally {
        calloc.free(hintPtr);
      }
    } finally {
      calloc.free(inputPathPtr);
      calloc.free(hintLenPtr);
    }
  }

  // ---- 归档容器（文件夹加密，magic WEMI_FARC）----

  /// 打包文件夹 → 单文件 .wemi 归档（逐文件 AES-256-GCM + 加密清单）。
  /// 返回码：0 成功；-1 参数；-2 IO/加密失败；-3 空文件夹；-4 源目录不存在。
  static void packFolder(
    String dirPath,
    String outputPath,
    Uint8List password, {
    String? hint,
    bool isMobile = false,
  }) {
    _loadLibrary();

    final packFunc = _lib!.lookupFunction<
      ffi.Int32 Function(
        ffi.Pointer<ffi.Char> dirPathPtr,
        ffi.Pointer<ffi.Char> outputPathPtr,
        ffi.Pointer<ffi.Uint8> passwordPtr,
        ffi.Size passwordLen,
        ffi.Pointer<ffi.Char> hintPtr,
        ffi.Bool isMobile,
      ),
      int Function(
        ffi.Pointer<ffi.Char> dirPathPtr,
        ffi.Pointer<ffi.Char> outputPathPtr,
        ffi.Pointer<ffi.Uint8> passwordPtr,
        int passwordLen,
        ffi.Pointer<ffi.Char> hintPtr,
        bool isMobile,
      )
    >('pack_folder');

    final dirPathPtr = dirPath.toNativeUtf8().cast<ffi.Char>();
    final outputPathPtr = outputPath.toNativeUtf8().cast<ffi.Char>();
    final passwordPtr = _allocateUint8List(password);
    final hintPtr = hint != null
        ? hint.toNativeUtf8().cast<ffi.Char>()
        : ffi.nullptr;

    try {
      final result = packFunc(
        dirPathPtr,
        outputPathPtr,
        passwordPtr,
        password.length,
        hintPtr,
        isMobile,
      );
      if (result != 0) {
        throw Exception('Folder packing failed with code: $result');
      }
    } finally {
      calloc.free(dirPathPtr);
      calloc.free(outputPathPtr);
      calloc.free(passwordPtr);
      if (hintPtr != ffi.nullptr) {
        calloc.free(hintPtr);
      }
    }
  }

  /// 解包整个归档到 outputDir。返回码语义同 packFolder（-2=密码错/损坏，-3=非归档）。
  static void unpackArchive(
    String archivePath,
    String outputDir,
    Uint8List password,
  ) {
    _loadLibrary();

    final unpackFunc = _lib!.lookupFunction<
      ffi.Int32 Function(
        ffi.Pointer<ffi.Char> archivePathPtr,
        ffi.Pointer<ffi.Char> outputDirPtr,
        ffi.Pointer<ffi.Uint8> passwordPtr,
        ffi.Size passwordLen,
        ffi.Bool isMobile,
      ),
      int Function(
        ffi.Pointer<ffi.Char> archivePathPtr,
        ffi.Pointer<ffi.Char> outputDirPtr,
        ffi.Pointer<ffi.Uint8> passwordPtr,
        int passwordLen,
        bool isMobile,
      )
    >('unpack_archive');

    final archivePathPtr = archivePath.toNativeUtf8().cast<ffi.Char>();
    final outputDirPtr = outputDir.toNativeUtf8().cast<ffi.Char>();
    final passwordPtr = _allocateUint8List(password);

    try {
      final result = unpackFunc(
        archivePathPtr,
        outputDirPtr,
        passwordPtr,
        password.length,
        false,
      );
      if (result != 0) {
        throw Exception('Archive unpacking failed with code: $result');
      }
    } finally {
      calloc.free(archivePathPtr);
      calloc.free(outputDirPtr);
      calloc.free(passwordPtr);
    }
  }

  /// 输密码后列归档清单（Rust 侧返回 JSON，Dart 解析）。
  /// 返回 {'ok': true, 'entries': [{'p':..,'s':..}], 'dirs': [...], 'hint': ..}
  /// 或 {'ok': false, 'code': -2/-3}。
  static Map<String, dynamic> archiveList(
    String archivePath,
    Uint8List password,
  ) {
    _loadLibrary();

    final listFunc = _lib!.lookupFunction<
      ffi.Pointer<ffi.Char> Function(
        ffi.Pointer<ffi.Char> archivePathPtr,
        ffi.Pointer<ffi.Uint8> passwordPtr,
        ffi.Size passwordLen,
      ),
      ffi.Pointer<ffi.Char> Function(
        ffi.Pointer<ffi.Char> archivePathPtr,
        ffi.Pointer<ffi.Uint8> passwordPtr,
        int passwordLen,
      )
    >('archive_list');

    final archivePathPtr = archivePath.toNativeUtf8().cast<ffi.Char>();
    final passwordPtr = _allocateUint8List(password);

    try {
      final ptr = listFunc(archivePathPtr, passwordPtr, password.length);
      if (ptr == ffi.nullptr) {
        return {'ok': false, 'code': -99};
      }
      try {
        final json = ptr.cast<Utf8>().toDartString();
        return jsonDecode(json) as Map<String, dynamic>;
      } finally {
        archiveFreeString(ptr);
      }
    } finally {
      calloc.free(archivePathPtr);
      calloc.free(passwordPtr);
    }
  }

  /// 选择性解密：只抽取 paths 中的相对路径；空列表 = 全部。
  static void extractSelected(
    String archivePath,
    String outputDir,
    Uint8List password,
    List<String> paths,
  ) {
    _loadLibrary();

    final extractFunc = _lib!.lookupFunction<
      ffi.Int32 Function(
        ffi.Pointer<ffi.Char> archivePathPtr,
        ffi.Pointer<ffi.Char> outputDirPtr,
        ffi.Pointer<ffi.Uint8> passwordPtr,
        ffi.Size passwordLen,
        ffi.Pointer<ffi.Char> pathsJsonPtr,
      ),
      int Function(
        ffi.Pointer<ffi.Char> archivePathPtr,
        ffi.Pointer<ffi.Char> outputDirPtr,
        ffi.Pointer<ffi.Uint8> passwordPtr,
        int passwordLen,
        ffi.Pointer<ffi.Char> pathsJsonPtr,
      )
    >('extract_selected');

    final archivePathPtr = archivePath.toNativeUtf8().cast<ffi.Char>();
    final outputDirPtr = outputDir.toNativeUtf8().cast<ffi.Char>();
    final passwordPtr = _allocateUint8List(password);
    final pathsJson = jsonEncode(paths);
    final pathsJsonPtr = pathsJson.toNativeUtf8().cast<ffi.Char>();

    try {
      final result = extractFunc(
        archivePathPtr,
        outputDirPtr,
        passwordPtr,
        password.length,
        pathsJsonPtr,
      );
      if (result != 0) {
        throw Exception('Selective extraction failed with code: $result');
      }
    } finally {
      calloc.free(archivePathPtr);
      calloc.free(outputDirPtr);
      calloc.free(passwordPtr);
      calloc.free(pathsJsonPtr);
    }
  }

  /// 打包/解包进度（明文字节数）：done / total。total=0 表示未启动。
  static ({int done, int total}) archiveProgress() {
    _loadLibrary();
    final doneFunc = _lib!.lookupFunction<ffi.Int64 Function(), int Function()>(
        'archive_progress_done');
    final totalFunc = _lib!.lookupFunction<ffi.Int64 Function(), int Function()>(
        'archive_progress_total');
    return (done: doneFunc(), total: totalFunc());
  }

  /// 释放 Rust 侧分配的 C 字符串（archive_list 返回值）。
  static void archiveFreeString(ffi.Pointer<ffi.Char> ptr) {
    _loadLibrary();
    final freeFunc = _lib!.lookupFunction<
      ffi.Void Function(ffi.Pointer<ffi.Char> ptr),
      void Function(ffi.Pointer<ffi.Char> ptr)
    >('archive_free_string');
    freeFunc(ptr);
  }
}