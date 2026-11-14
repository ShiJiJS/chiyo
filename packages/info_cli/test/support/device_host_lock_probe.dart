import 'dart:io';

// A separate process is necessary: POSIX record locks are process-scoped.
// Never emits a private path or record contents, and does not alter the file.
Future<void> main(List<String> arguments) async {
  RandomAccessFile? lock;
  try {
    lock = await File(arguments.single).open(mode: FileMode.append);
    await lock.lock(FileLock.exclusive);
  } on FileSystemException {
    exitCode = 2;
  } finally {
    await lock?.close();
  }
}
