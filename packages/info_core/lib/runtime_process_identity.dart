import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';

/// Holds a Windows process handle so PID reuse cannot change this identity while
/// the executor drains pipes and reports the final result. No capability or
/// credential is stored here.
class CredentialProcessIdentity {
  CredentialProcessIdentity._(this.value,this._handle);
  final String value;
  int? _handle;
  static CredentialProcessIdentity? capture(int processId) {
    if(Platform.isWindows) {
      final handle=_openProcess(0x1000,0,processId);
      if(handle==0)return null;
      final times=calloc<Uint64>(4);
      try {
        if(_getProcessTimes(handle,times,times.elementAt(1),times.elementAt(2),times.elementAt(3))==0){_closeHandle(handle);return null;}
        return CredentialProcessIdentity._('windows:${times.value}',handle);
      }finally {calloc.free(times);}
    }
    if(Platform.isLinux) {
      try {
        final stat=File('/proc/$processId/stat').readAsStringSync();
        final fields=stat.substring(stat.lastIndexOf(')')+2).trim().split(RegExp(r'\s+'));
        final boot=File('/proc/sys/kernel/random/boot_id').readAsStringSync().trim();
        return CredentialProcessIdentity._('linux:$boot:${fields[19]}',null);
      } on Object {return null;}
    }
    return null;
  }
  void close(){final handle=_handle;_handle=null;if(handle!=null)_closeHandle(handle);}
  @override String toString()=>'CredentialProcessIdentity($value)';
}

final _kernel=Platform.isWindows?DynamicLibrary.open('kernel32.dll'):null;
final _openProcess=_kernel?.lookupFunction<IntPtr Function(Uint32,Int32,Uint32),int Function(int,int,int)>('OpenProcess')??_unavailableOpen;
int _unavailableOpen(int _,int _,int _)=>0;
final _getProcessTimes=_kernel?.lookupFunction<Int32 Function(IntPtr,Pointer<Uint64>,Pointer<Uint64>,Pointer<Uint64>,Pointer<Uint64>),int Function(int,Pointer<Uint64>,Pointer<Uint64>,Pointer<Uint64>,Pointer<Uint64>)>('GetProcessTimes')??_unavailableTimes;
int _unavailableTimes(int _,Pointer<Uint64> _,Pointer<Uint64> _,Pointer<Uint64> _,Pointer<Uint64> _)=>0;
final _closeHandle=_kernel?.lookupFunction<Int32 Function(IntPtr),int Function(int)>('CloseHandle')??_unavailableClose;
int _unavailableClose(int _)=>0;
