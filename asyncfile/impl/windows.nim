# This file is based on the Windows parts of the Nim standard library's
# std/asyncfile module. It has been modified to work with Chronos.
#
#
#            Nim's Runtime Library
#        (c) Copyright 2015 Dominik Picheta
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

import pkg/chronos/[
  osdefs,
  osutils,
]
from std/winlean import
  getFileSize, setFilePointer, setEndOfFile,
  CREATE_ALWAYS, OPEN_ALWAYS,
  INVALID_FILE_SIZE, INVALID_SET_FILE_POINTER,
  FILE_ATTRIBUTE_NORMAL,
  ERROR_HANDLE_EOF, NO_ERROR

func newCustom(): RefCustomOverlapped {.raises: [].} =
  result = RefCustomOverlapped()
  GC_ref(result)

proc getDesiredAccess(mode: FileMode): uint32 =
  case mode
  of fmRead:
    result = GENERIC_READ
  of fmWrite, fmAppend:
    result = GENERIC_WRITE
  of fmReadWrite, fmReadWriteExisting:
    result = GENERIC_READ or GENERIC_WRITE

proc getCreationDisposition(mode: FileMode, filename: string): uint32 =
  case mode
  of fmRead, fmReadWriteExisting:
    OPEN_EXISTING
  of fmReadWrite, fmWrite:
    CREATE_ALWAYS.uint32
  of fmAppend:
    OPEN_ALWAYS.uint32

proc getFileSize(f: AsyncFile): int64 =
  var high: winlean.DWORD
  let low = getFileSize(winlean.Handle(f.fd), addr high)
  if low == INVALID_FILE_SIZE:
    raiseOSError(osLastError())
  result = (high shl 32) or low

template openAsyncImpl(filename: string, mode: FileMode): AsyncFile =
  var f: AsyncFile = nil

  let flags = FILE_FLAG_OVERLAPPED or FILE_ATTRIBUTE_NORMAL.uint32
  let desiredAccess = getDesiredAccess(mode)
  let creationDisposition = getCreationDisposition(mode, filename)
  # chronos's createFile is createFileW...
  let fd = createFile(filename.toWideString.tryGet, desiredAccess,
      FILE_SHARE_READ,
      nil, creationDisposition, flags, HANDLE(0))
  if fd == INVALID_HANDLE_VALUE:
    raiseOSError(osLastError())

  f = newAsyncFile(fd.AsyncFD)
  if mode == fmAppend:
    f.offset = getFileSize(f)
  f

when HasPath:
  proc openAsync(filename: Path, mode: FileMode): AsyncFile =
    openAsyncImpl(string(filename), mode)

proc openAsync(filename: string, mode: FileMode): AsyncFile =
  openAsyncImpl(filename, mode)

proc readBuffer(f: AsyncFile, buf: pointer, size: int): Future[int] =
  var retFuture = newFuture[int]("asyncfile.readBuffer")
  var ol = newCustom()

  proc cb(_: pointer) =
    let
      bytesCount = ol.data.bytesCount
      errCode = ol.data.errCode
    if not retFuture.finished:
      if errCode == OSErrorCode(-1):
        assert bytesCount > 0
        assert bytesCount.int <= size
        f.offset.inc bytesCount.int
        retFuture.complete(bytesCount.int)
      else:
        if errCode.int32 == ERROR_HANDLE_EOF:
          retFuture.complete(0)
        else:
          retFuture.fail(newException(OSError, osErrorMsg(errCode)))

  ol.data = CompletionData(cb: CallbackFunc(cb))
  ol.offset = DWORD(f.offset and 0xffffffff)
  ol.offsetHigh = DWORD(f.offset shr 32)

  # According to MSDN we're supposed to pass nil to lpNumberOfBytesRead.
  let ret = readFile(f.fd.Handle, buf, size.DWORD, nil,
                      cast[POVERLAPPED](ol))
  if not ret.bool:
    let err = osLastError()
    if err != ERROR_IO_PENDING:
      GC_unref(ol)
      if err.int32 == ERROR_HANDLE_EOF:
        # This happens in Windows Server 2003
        retFuture.complete(0)
      else:
        retFuture.fail(newException(OSError, osErrorMsg(err)))
  else:
    # Request completed immediately.
    var bytesRead: DWORD
    let overlappedRes = getOverlappedResult(f.fd.Handle,
        cast[POVERLAPPED](ol), bytesRead, false.WINBOOL)
    if not overlappedRes.bool:
      let err = osLastError()
      if err.int32 == ERROR_HANDLE_EOF:
        retFuture.complete(0)
      else:
        retFuture.fail(newException(OSError, osErrorMsg(osLastError())))
    else:
      assert bytesRead > 0
      assert bytesRead.int <= size
      f.offset.inc bytesRead.int
      retFuture.complete(bytesRead.int)

  return retFuture

proc read(f: AsyncFile, size: Natural): Future[string] =
  var retFuture = newFuture[string]("asyncfile.read")
  var buffer = alloc0(size)

  var ol = newCustom()

  proc cb(_: pointer) =
    let
      bytesCount = ol.data.bytesCount
      errCode = ol.data.errCode
    if not retFuture.finished:
      if errCode == OSErrorCode(-1):
        assert bytesCount > 0
        assert bytesCount.int <= size
        var data = newString(bytesCount)
        copyMem(addr data[0], buffer, bytesCount)
        f.offset.inc bytesCount.int
        retFuture.complete($data)
      else:
        if errCode.int == ERROR_HANDLE_EOF:
          retFuture.complete("")
        else:
          retFuture.fail(newException(OSError, osErrorMsg(errCode)))
    if buffer != nil:
      dealloc buffer
      buffer = nil

  ol.data = CompletionData(cb: CallbackFunc(cb))
  ol.offset = DWORD(f.offset and 0xffffffff)
  ol.offsetHigh = DWORD(f.offset shr 32)

  # According to MSDN we're supposed to pass nil to lpNumberOfBytesRead.
  let ret = readFile(f.fd.Handle, buffer, size.DWORD, nil,
                      cast[POVERLAPPED](ol))
  if not ret.bool:
    let err = osLastError()
    if err != ERROR_IO_PENDING:
      if buffer != nil:
        dealloc buffer
        buffer = nil
      GC_unref(ol)

      if err.int32 == ERROR_HANDLE_EOF:
        # This happens in Windows Server 2003
        retFuture.complete("")
      else:
        retFuture.fail(newException(OSError, osErrorMsg(err)))
  else:
    # Request completed immediately.
    var bytesRead: DWORD
    let overlappedRes = getOverlappedResult(f.fd.Handle,
        cast[POVERLAPPED](ol), bytesRead, false.WINBOOL)
    if not overlappedRes.bool:
      let err = osLastError()
      if err.int32 == ERROR_HANDLE_EOF:
        retFuture.complete("")
      else:
        retFuture.fail(newException(OSError, osErrorMsg(osLastError())))
    else:
      assert bytesRead > 0
      assert bytesRead.int <= size
      var data = newString(bytesRead)
      copyMem(addr data[0], buffer, bytesRead)
      f.offset.inc bytesRead.int
      retFuture.complete($data)

  return retFuture

proc setFilePos(f: AsyncFile, pos: int64) =
  f.offset = pos

proc writeBuffer(f: AsyncFile, buf: pointer, size: int): Future[void] =
  var retFuture = newFuture[void]("asyncfile.writeBuffer")
  var ol = newCustom()

  proc cb(_: pointer) =
    let
      bytesCount = ol.data.bytesCount
      errCode = ol.data.errCode
    if not retFuture.finished:
      if errCode == OSErrorCode(-1):
        assert bytesCount.int == size
        retFuture.complete()
      else:
        retFuture.fail(newException(OSError, osErrorMsg(errCode)))

  ol.data = CompletionData(cb: CallbackFunc(cb))
  # passing -1 here should work according to MSDN, but doesn't. For more
  # information see
  # http://stackoverflow.com/questions/33650899/does-asynchronous-file-appending-in-windows-preserve-order
  ol.offset = DWORD(f.offset and 0xffffffff)
  ol.offsetHigh = DWORD(f.offset shr 32)
  f.offset.inc(size)

  # According to MSDN we're supposed to pass nil to lpNumberOfBytesWritten.
  let ret = writeFile(f.fd.Handle, buf, size.DWORD, nil,
                      cast[POVERLAPPED](ol))
  if not ret.bool:
    let err = osLastError()
    if err != ERROR_IO_PENDING:
      GC_unref(ol)
      retFuture.fail(newException(OSError, osErrorMsg(err)))
  else:
    # Request completed immediately.
    var bytesWritten: DWORD
    let overlappedRes = getOverlappedResult(f.fd.Handle,
        cast[POVERLAPPED](ol), bytesWritten, false.WINBOOL)
    if not overlappedRes.bool:
      retFuture.fail(newException(OSError, osErrorMsg(osLastError())))
    else:
      assert bytesWritten.int == size
      retFuture.complete()
  return retFuture

proc write(f: AsyncFile, data: string): Future[void] =
  var retFuture = newFuture[void]("asyncfile.write")
  var copy = data
  var buffer = alloc0(data.len)
  copyMem(buffer, copy.cstring, data.len)

  var ol = newCustom()

  proc cb(_: pointer) =
    let
      bytesCount = ol.data.bytesCount
      errCode = ol.data.errCode
    if not retFuture.finished:
      if errCode == OSErrorCode(-1):
        assert bytesCount.int == data.len
        retFuture.complete()
      else:
        retFuture.fail(newException(OSError, osErrorMsg(errCode)))
    if buffer != nil:
      dealloc buffer
      buffer = nil

  ol.data = CompletionData(cb: CallbackFunc(cb))
  ol.offset = DWORD(f.offset and 0xffffffff)
  ol.offsetHigh = DWORD(f.offset shr 32)
  f.offset.inc(data.len)

  # According to MSDN we're supposed to pass nil to lpNumberOfBytesWritten.
  let ret = writeFile(f.fd.Handle, buffer, data.len.DWORD, nil,
                      cast[POVERLAPPED](ol))
  if not ret.bool:
    let err = osLastError()
    if err != ERROR_IO_PENDING:
      if buffer != nil:
        dealloc buffer
        buffer = nil
      GC_unref(ol)
      retFuture.fail(newException(OSError, osErrorMsg(err)))
  else:
    # Request completed immediately.
    var bytesWritten: DWORD
    let overlappedRes = getOverlappedResult(f.fd.Handle,
        cast[POVERLAPPED](ol), bytesWritten, false.WINBOOL)
    if not overlappedRes.bool:
      retFuture.fail(newException(OSError, osErrorMsg(osLastError())))
    else:
      assert bytesWritten.int == data.len
      retFuture.complete()
  return retFuture

proc setFileSize(f: AsyncFile, length: int64) =
  var
    high = (length shr 32).LONG
  let
    low = (length and 0xffffffff).LONG
    status = setFilePointer(winlean.Handle(f.fd), low, addr high, 0)
    lastErr = osLastError()
  if (status == INVALID_SET_FILE_POINTER and lastErr.int32 != NO_ERROR) or
      (setEndOfFile(winlean.Handle(f.fd)) == 0):
    raiseOSError(osLastError())

proc close(f: AsyncFile) =
  unregister(f.fd)
  if not closeHandle(f.fd.Handle).bool:
    raiseOSError(osLastError())
