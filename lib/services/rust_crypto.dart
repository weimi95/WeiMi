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

  // ==================== LANDrop v2 加密原语 ====================
  //
  // 对应 rust_crypto/src/landrop.rs，全部经 libsodium 官方实现对拍。
  // Dart 侧（landrop_service.dart）负责 UDP 发现/TCP 握手/帧/文件流，
  // 这里只做无状态原语调用，nonce 由调用方持有并按记录递增。

  /// calloc 复制（空列表也保底 1 字节，避免 malloc(0) 返回 null 触发 Rust 侧空指针保护）
  static ffi.Pointer<ffi.Uint8> _ldBytes(Uint8List list) {
    final ptr = calloc<ffi.Uint8>(list.isEmpty ? 1 : list.length);
    for (var i = 0; i < list.length; i++) {
      ptr[i] = list[i];
    }
    return ptr;
  }

  /// 单记录明文上限（LANDrop maxBlockSize = 65518）
  static int get landropMaxBlockSize {
    _loadLibrary();
    final f = _lib!.lookupFunction<ffi.Size Function(), int Function()>(
        'landrop_max_block_size');
    return f();
  }

  /// BLAKE2b 任意输出（outLen 1..=64）
  static Uint8List landropBlake2b(int outLen, Uint8List data) {
    _loadLibrary();
    final f = _lib!.lookupFunction<
        ffi.Int32 Function(
            ffi.Pointer<ffi.Uint8> outPtr,
            ffi.Size outLen,
            ffi.Pointer<ffi.Uint8> dataPtr,
            ffi.Size dataLen),
        int Function(ffi.Pointer<ffi.Uint8> outPtr, int outLen,
            ffi.Pointer<ffi.Uint8> dataPtr, int dataLen)>('landrop_blake2b');
    final out = calloc<ffi.Uint8>(outLen);
    final dataPtr = _ldBytes(data);
    try {
      final rc = f(out, outLen, dataPtr, data.length);
      if (rc != 0) throw Exception('landrop_blake2b failed: $rc');
      return Uint8List.fromList(out.asTypedList(outLen)); // 拷贝，calloc 内存随后释放
    } finally {
      calloc.free(out);
      calloc.free(dataPtr);
    }
  }

  /// 生成 X25519 密钥对：返回 (pk, sk)
  static ({Uint8List pk, Uint8List sk}) landropKxKeypair() {
    _loadLibrary();
    final f = _lib!.lookupFunction<
        ffi.Int32 Function(ffi.Pointer<ffi.Uint8> pk, ffi.Pointer<ffi.Uint8> sk),
        int Function(ffi.Pointer<ffi.Uint8> pk, ffi.Pointer<ffi.Uint8> sk)>(
        'landrop_kx_keypair');
    final pk = calloc<ffi.Uint8>(32);
    final sk = calloc<ffi.Uint8>(32);
    try {
      final rc = f(pk, sk);
      if (rc != 0) throw Exception('landrop_kx_keypair failed: $rc');
      return (pk: Uint8List.fromList(pk.asTypedList(32)),
              sk: Uint8List.fromList(sk.asTypedList(32)));
    } finally {
      calloc.free(pk);
      calloc.free(sk);
    }
  }

  /// 计算 kx 会话密钥。isClient=true 表示本方是连接发起方。
  /// 返回 (rx, tx)：rx 用于解密收到的记录，tx 用于加密发出的记录。
  static ({Uint8List rx, Uint8List tx}) landropKxSessionKeys({
    required bool isClient,
    required Uint8List ownSk,
    required Uint8List ownPk,
    required Uint8List peerPk,
  }) {
    _loadLibrary();
    final f = _lib!.lookupFunction<
        ffi.Int32 Function(
            ffi.Bool isClient,
            ffi.Pointer<ffi.Uint8> ownSk,
            ffi.Pointer<ffi.Uint8> ownPk,
            ffi.Pointer<ffi.Uint8> peerPk,
            ffi.Pointer<ffi.Uint8> rx,
            ffi.Pointer<ffi.Uint8> tx),
        int Function(
            bool isClient,
            ffi.Pointer<ffi.Uint8> ownSk,
            ffi.Pointer<ffi.Uint8> ownPk,
            ffi.Pointer<ffi.Uint8> peerPk,
            ffi.Pointer<ffi.Uint8> rx,
            ffi.Pointer<ffi.Uint8> tx)>('landrop_kx_session_keys');
    final skPtr = _ldBytes(ownSk);
    final pkPtr = _ldBytes(ownPk);
    final peerPtr = _ldBytes(peerPk);
    final rx = calloc<ffi.Uint8>(32);
    final tx = calloc<ffi.Uint8>(32);
    try {
      final rc = f(isClient, skPtr, pkPtr, peerPtr, rx, tx);
      if (rc == -1) throw Exception('landrop_kx_session_keys: weak peer key');
      if (rc != 0) throw Exception('landrop_kx_session_keys failed: $rc');
      return (rx: Uint8List.fromList(rx.asTypedList(32)),
              tx: Uint8List.fromList(tx.asTypedList(32)));
    } finally {
      calloc.free(skPtr);
      calloc.free(pkPtr);
      calloc.free(peerPtr);
      calloc.free(rx);
      calloc.free(tx);
    }
  }

  /// 6 位 verifCode（TOFU 核对用）。kSc/kCs 按角色：client 的 kSc=rx/kCs=tx；server 反之。
  static String landropVerifCode({
    required Uint8List kSc,
    required Uint8List kCs,
  }) {
    _loadLibrary();
    final f = _lib!.lookupFunction<
        ffi.Int32 Function(
            ffi.Pointer<ffi.Uint8> kSc,
            ffi.Pointer<ffi.Uint8> kCs,
            ffi.Pointer<ffi.Char> out),
        int Function(ffi.Pointer<ffi.Uint8> kSc, ffi.Pointer<ffi.Uint8> kCs,
            ffi.Pointer<ffi.Char> out)>('landrop_verif_code');
    final kScPtr = _ldBytes(kSc);
    final kCsPtr = _ldBytes(kCs);
    final out = calloc<ffi.Char>(7); // 6 位 + NUL
    try {
      final rc = f(kScPtr, kCsPtr, out);
      if (rc != 0) throw Exception('landrop_verif_code failed: $rc');
      return out.cast<Utf8>().toDartString();
    } finally {
      calloc.free(kScPtr);
      calloc.free(kCsPtr);
      calloc.free(out);
    }
  }

  /// 生成 secp256k1 身份密钥对：返回 (pk 压缩33B, sk 32B)
  static ({Uint8List pk, Uint8List sk}) landropSecpKeypair() {
    _loadLibrary();
    final f = _lib!.lookupFunction<
        ffi.Int32 Function(ffi.Pointer<ffi.Uint8> pk, ffi.Pointer<ffi.Uint8> sk),
        int Function(ffi.Pointer<ffi.Uint8> pk, ffi.Pointer<ffi.Uint8> sk)>(
        'landrop_secp_keypair');
    final pk = calloc<ffi.Uint8>(33);
    final sk = calloc<ffi.Uint8>(32);
    try {
      final rc = f(pk, sk);
      if (rc != 0) throw Exception('landrop_secp_keypair failed: $rc');
      return (pk: Uint8List.fromList(pk.asTypedList(33)),
              sk: Uint8List.fromList(sk.asTypedList(32)));
    } finally {
      calloc.free(pk);
      calloc.free(sk);
    }
  }

  /// 由 sk 恢复压缩公钥（信任列表按公钥持久化，启动时反查）
  static Uint8List landropSecpPkFromSk(Uint8List sk) {
    _loadLibrary();
    final f = _lib!.lookupFunction<
        ffi.Int32 Function(ffi.Pointer<ffi.Uint8> sk, ffi.Pointer<ffi.Uint8> pk),
        int Function(ffi.Pointer<ffi.Uint8> sk, ffi.Pointer<ffi.Uint8> pk)>(
        'landrop_secp_pk_from_sk');
    final skPtr = _ldBytes(sk);
    final pk = calloc<ffi.Uint8>(33);
    try {
      final rc = f(skPtr, pk);
      if (rc != 0) throw Exception('landrop_secp_pk_from_sk failed: $rc');
      return Uint8List.fromList(pk.asTypedList(33));
    } finally {
      calloc.free(skPtr);
      calloc.free(pk);
    }
  }

  /// secp256k1 签名（内部先 blake2b-256(msg)），返回 64B compact（低 S）
  static Uint8List landropSecpSign(Uint8List msg, Uint8List sk) {
    _loadLibrary();
    final f = _lib!.lookupFunction<
        ffi.Int32 Function(ffi.Pointer<ffi.Uint8> msg, ffi.Size msgLen,
            ffi.Pointer<ffi.Uint8> sk, ffi.Pointer<ffi.Uint8> sig),
        int Function(ffi.Pointer<ffi.Uint8> msg, int msgLen,
            ffi.Pointer<ffi.Uint8> sk, ffi.Pointer<ffi.Uint8> sig)>(
        'landrop_secp_sign');
    final msgPtr = _ldBytes(msg);
    final skPtr = _ldBytes(sk);
    final sig = calloc<ffi.Uint8>(64);
    try {
      final rc = f(msgPtr, msg.length, skPtr, sig);
      if (rc != 0) throw Exception('landrop_secp_sign failed: $rc');
      return Uint8List.fromList(sig.asTypedList(64));
    } finally {
      calloc.free(msgPtr);
      calloc.free(skPtr);
      calloc.free(sig);
    }
  }

  /// secp256k1 验签（内部 blake2b-256 + normalize_s，兼容高 S）
  static bool landropSecpVerify(Uint8List sig, Uint8List msg, Uint8List pk) {
    _loadLibrary();
    final f = _lib!.lookupFunction<
        ffi.Int32 Function(ffi.Pointer<ffi.Uint8> sig, ffi.Pointer<ffi.Uint8> msg,
            ffi.Size msgLen, ffi.Pointer<ffi.Uint8> pk),
        int Function(ffi.Pointer<ffi.Uint8> sig, ffi.Pointer<ffi.Uint8> msg,
            int msgLen, ffi.Pointer<ffi.Uint8> pk)>('landrop_secp_verify');
    final sigPtr = _ldBytes(sig);
    final msgPtr = _ldBytes(msg);
    final pkPtr = _ldBytes(pk);
    try {
      final rc = f(sigPtr, msgPtr, msg.length, pkPtr);
      if (rc == 0) return true;
      if (rc == -1) return false;
      throw Exception('landrop_secp_verify failed: $rc');
    } finally {
      calloc.free(sigPtr);
      calloc.free(msgPtr);
      calloc.free(pkPtr);
    }
  }

  /// ChaCha20-Poly1305-IETF 加密。返回 ct || tag（长度 = pt.len + 16）。
  static Uint8List landropSeal(
      Uint8List key, Uint8List nonce, Uint8List plaintext) {
    _loadLibrary();
    final f = _lib!.lookupFunction<
        ffi.Int32 Function(
            ffi.Pointer<ffi.Uint8> key,
            ffi.Pointer<ffi.Uint8> nonce,
            ffi.Pointer<ffi.Uint8> pt,
            ffi.Size ptLen,
            ffi.Pointer<ffi.Uint8> out,
            ffi.Pointer<ffi.Size> outLen),
        int Function(
            ffi.Pointer<ffi.Uint8> key,
            ffi.Pointer<ffi.Uint8> nonce,
            ffi.Pointer<ffi.Uint8> pt,
            int ptLen,
            ffi.Pointer<ffi.Uint8> out,
            ffi.Pointer<ffi.Size> outLen)>('landrop_seal');
    final keyPtr = _ldBytes(key);
    final noncePtr = _ldBytes(nonce);
    final ptPtr = _ldBytes(plaintext);
    final outLen = calloc<ffi.Size>();
    try {
      // 第一次调用取长度
      var rc = f(keyPtr, noncePtr, ptPtr, plaintext.length, ffi.nullptr, outLen);
      if (rc != 0) throw Exception('landrop_seal failed: $rc');
      final len = outLen.value;
      final out = calloc<ffi.Uint8>(len);
      try {
        rc = f(keyPtr, noncePtr, ptPtr, plaintext.length, out, outLen);
        if (rc != 0) throw Exception('landrop_seal failed: $rc');
        return Uint8List.fromList(out.asTypedList(len));
      } finally {
        calloc.free(out);
      }
    } finally {
      calloc.free(keyPtr);
      calloc.free(noncePtr);
      calloc.free(ptPtr);
      calloc.free(outLen);
    }
  }

  /// ChaCha20-Poly1305-IETF 解密。认证失败抛异常。
  static Uint8List landropOpen(
      Uint8List key, Uint8List nonce, Uint8List ciphertext) {
    _loadLibrary();
    final f = _lib!.lookupFunction<
        ffi.Int32 Function(
            ffi.Pointer<ffi.Uint8> key,
            ffi.Pointer<ffi.Uint8> nonce,
            ffi.Pointer<ffi.Uint8> ct,
            ffi.Size ctLen,
            ffi.Pointer<ffi.Uint8> out,
            ffi.Pointer<ffi.Size> outLen),
        int Function(
            ffi.Pointer<ffi.Uint8> key,
            ffi.Pointer<ffi.Uint8> nonce,
            ffi.Pointer<ffi.Uint8> ct,
            int ctLen,
            ffi.Pointer<ffi.Uint8> out,
            ffi.Pointer<ffi.Size> outLen)>('landrop_open');
    final keyPtr = _ldBytes(key);
    final noncePtr = _ldBytes(nonce);
    final ctPtr = _ldBytes(ciphertext);
    final outLen = calloc<ffi.Size>();
    try {
      var rc = f(keyPtr, noncePtr, ctPtr, ciphertext.length, ffi.nullptr, outLen);
      if (rc != 0) throw Exception('landrop_open failed: $rc');
      final len = outLen.value;
      final out = calloc<ffi.Uint8>(len);
      try {
        rc = f(keyPtr, noncePtr, ctPtr, ciphertext.length, out, outLen);
        if (rc == -2) throw Exception('landrop_open: auth failed');
        if (rc != 0) throw Exception('landrop_open failed: $rc');
        return Uint8List.fromList(out.asTypedList(len));
      } finally {
        calloc.free(out);
      }
    } finally {
      calloc.free(keyPtr);
      calloc.free(noncePtr);
      calloc.free(ctPtr);
      calloc.free(outLen);
    }
  }

  /// 12B 小端 nonce +1（sodium_increment 语义），原地修改
  static void landropNonceIncrement(Uint8List nonce12) {
    _loadLibrary();
    final f = _lib!.lookupFunction<
        ffi.Void Function(ffi.Pointer<ffi.Uint8> nonce),
        void Function(ffi.Pointer<ffi.Uint8> nonce)>('landrop_nonce_increment');
    final ptr = _ldBytes(nonce12);
    try {
      f(ptr);
      nonce12.setAll(0, ptr.asTypedList(12));
    } finally {
      calloc.free(ptr);
    }
  }
}
