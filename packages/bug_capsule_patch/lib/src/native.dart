import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

const opStatus = 1;
const opStage = 2;
const opChannel = 3;
const opKeyring = 4;
const opHealthy = 5;
const opFault = 6;
const opEval = 7;
const opAsset = 8;
const opReceipts = 9;
const opAck = 10;
const opCancel = 11;
const opLocalEval = 12;
const opSurface = 13;

const abiVersion = 1;

/// `BcpBuf` of the C ABI (spec/abi-v1.md).
final class BcpBuf extends Struct {
  external Pointer<Uint8> ptr;
  @Size()
  external int len;
}

typedef _OpenC = Int32 Function(Pointer<Uint8>, Size, Pointer<Pointer<Void>>, Pointer<BcpBuf>);
typedef _OpenD = int Function(Pointer<Uint8>, int, Pointer<Pointer<Void>>, Pointer<BcpBuf>);
typedef _CallC = Int32 Function(Pointer<Void>, Uint32, Pointer<Uint8>, Size, Pointer<Uint8>, Size, Uint64, Pointer<BcpBuf>);
typedef _CallD = int Function(Pointer<Void>, int, Pointer<Uint8>, int, Pointer<Uint8>, int, int, Pointer<BcpBuf>);
typedef _FreeC = Void Function(BcpBuf);
typedef _FreeD = void Function(BcpBuf);
typedef _CloseC = Void Function(Pointer<Void>);
typedef _CloseD = void Function(Pointer<Void>);
typedef _VersionC = Uint32 Function();
typedef _VersionD = int Function();

/// An error returned by the runtime.
final class NativeError implements Exception {
  NativeError(this.code, this.message);
  final String code;
  final String message;

  @override
  String toString() => 'NativeError($code: $message)';
}

/// The loaded runtime library. Loading only opens the binary inside the app.
final class Native {
  Native._(DynamicLibrary lib)
    : _open = lib.lookupFunction<_OpenC, _OpenD>('bcp_open'),
      _call = lib.lookupFunction<_CallC, _CallD>('bcp_call'),
      _free = lib.lookupFunction<_FreeC, _FreeD>('bcp_buf_free'),
      _close = lib.lookupFunction<_CloseC, _CloseD>('bcp_close'),
      version = lib.lookupFunction<_VersionC, _VersionD>('bcp_abi_version')();

  final _OpenD _open;
  final _CallD _call;
  final _FreeD _free;
  final _CloseD _close;
  final int version;

  /// Null when this build carries no runtime.
  static Native? load([String? path]) {
    try {
      return Native._(DynamicLibrary.open(path ?? _defaultPath()));
    } on Object {
      return null;
    }
  }

  static String _defaultPath() {
    if (Platform.isAndroid) return 'libbcpatch.so';
    if (Platform.isIOS) return 'BcpatchRuntime.framework/BcpatchRuntime';
    throw UnsupportedError('no patch runtime for this platform');
  }

  Pointer<Uint8> _copy(List<int> b, Allocator a) {
    final p = a<Uint8>(b.isEmpty ? 1 : b.length);
    p.asTypedList(b.isEmpty ? 1 : b.length).setRange(0, b.length, b);
    return p;
  }

  Uint8List _take(int status, Pointer<BcpBuf> out) {
    final buf = out.ref;
    final bytes = buf.ptr == nullptr ? Uint8List(0) : Uint8List.fromList(buf.ptr.asTypedList(buf.len));
    _free(buf);
    if (status != 0) {
      final e = jsonDecode(utf8.decode(bytes)) as Map<String, Object?>;
      throw NativeError(e['code']! as String, e['message']! as String);
    }
    return bytes;
  }

  Pointer<Void> open(List<int> config) => using((arena) {
    final handle = arena<Pointer<Void>>();
    final out = arena<BcpBuf>();
    final status = _open(_copy(config, arena), config.length, handle, out);
    _take(status, out);
    return handle.value;
  });

  Uint8List call(Pointer<Void> engine, int op, {List<int> a = const [], List<int> b = const [], int n = 0}) => using((arena) {
    final out = arena<BcpBuf>();
    final status = _call(engine, op, _copy(a, arena), a.length, _copy(b, arena), b.length, n, out);
    return _take(status, out);
  });

  void close(Pointer<Void> engine) => _close(engine);
}
