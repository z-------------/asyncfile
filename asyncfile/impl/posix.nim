# This file is based on the Posix parts of the Nim standard library's
# std/asyncfile module. It has been modified to work with Chronos.
#
#
#            Nim's Runtime Library
#        (c) Copyright 2015 Dominik Picheta
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

import std/posix

proc getPosixFlags(mode: FileMode): cint =
  case mode
  of fmRead:
    result = O_RDONLY
  of fmWrite:
    result = O_WRONLY or O_CREAT or O_TRUNC
  of fmAppend:
    result = O_WRONLY or O_CREAT or O_APPEND
  of fmReadWrite:
    result = O_RDWR or O_CREAT or O_TRUNC
  of fmReadWriteExisting:
    result = O_RDWR
  result = result or O_NONBLOCK

proc getFileSize(f: AsyncFile): int64 =
  let curPos = lseek(f.fd.cint, 0, SEEK_CUR)
  result = lseek(f.fd.cint, 0, SEEK_END)
  f.offset = lseek(f.fd.cint, curPos, SEEK_SET)
  assert(f.offset == curPos)

proc newAsyncFile(fd: AsyncFD): AsyncFile =
  new result
  result.fd = fd
  register(fd)

template openAsyncImpl(filename: string, mode: FileMode): AsyncFile =
  let flags = getPosixFlags(mode)
  # RW (Owner), RW (Group), R (Other)
  let perm = S_IRUSR or S_IWUSR or S_IRGRP or S_IWGRP or S_IROTH
  let fd = open(cstring(filename), flags, perm)
  if fd == -1:
    raiseOSError(osLastError())
  newAsyncFile(fd.AsyncFD)

when HasPath:
  proc openAsync(filename: Path; mode: FileMode): AsyncFile =
    openAsyncImpl(string(filename), mode)

proc openAsync(filename: string; mode: FileMode): AsyncFile =
  openAsyncImpl(filename, mode)

proc readBuffer(f: AsyncFile, buf: pointer, size: int): Future[int] =
  var retFuture = newFuture[int]("asyncfile.readBuffer")

  proc cb(fd: AsyncFD): bool {.closure, gcsafe.} =
    result = true
    let res = read(fd.cint, cast[cstring](buf), size.cint)
    if res < 0:
      let lastError = osLastError()
      if lastError.int32 != posix.EAGAIN:
        retFuture.fail(newException(OSError, osErrorMsg(lastError)))
      else:
        result = false # We still want this callback to be called.
    elif res == 0:
      # EOF
      retFuture.complete(0)
    else:
      f.offset.inc(res)
      retFuture.complete(res)

  proc cbf(arg: pointer) {.closure, gcsafe.} =
    let fd = cast[ptr AsyncFD](arg)[]
    if cb(fd):
      removeReader(fd)

  if not cb(f.fd):
    addReader(f.fd, CallbackFunc(cbf))

  return retFuture

proc read(f: AsyncFile, size: Natural): Future[string] =
  var retFuture = newFuture[string]("asyncfile.read")
  var readBuffer = newString(size)

  proc cb(fd: AsyncFD): bool {.closure, gcsafe.} =
    result = true
    let res = read(fd.cint, addr readBuffer[0], size.cint)
    if res < 0:
      let lastError = osLastError()
      if lastError.int32 != posix.EAGAIN:
        retFuture.fail(newException(OSError, osErrorMsg(lastError)))
      else:
        result = false # We still want this callback to be called.
    elif res == 0:
      # EOF
      f.offset = lseek(fd.cint, 0, SEEK_CUR)
      retFuture.complete("")
    else:
      readBuffer.setLen(res)
      f.offset.inc(res)
      retFuture.complete(readBuffer)

  proc cbf(arg: pointer) {.closure, gcsafe.} =
    let fd = cast[ptr AsyncFD](arg)[]
    if cb(fd):
      removeReader(fd)

  if not cb(f.fd):
    addReader(f.fd, CallbackFunc(cbf))

  return retFuture

proc readLineImpl(f: AsyncFile): Future[string] {.async.} =
  result = ""
  while true:
    var c = await read(f, 1)
    if c[0] == '\c':
      c = await read(f, 1)
      break
    if c[0] == '\L' or c == "":
      break
    else:
      result.add(c)

proc readLine(f: AsyncFile): Future[string] =
  readLineImpl(f)

proc getFilePos(f: AsyncFile): int64 =
  f.offset

proc setFilePos(f: AsyncFile, pos: int64) =
  f.offset = pos
  let ret = lseek(f.fd.cint, pos.Off, SEEK_SET)
  if ret == -1:
    raiseOSError(osLastError())

proc readAllImpl(f: AsyncFile): Future[string] {.async.} =
  result = ""
  while true:
    let data = await read(f, 4000)
    if data.len == 0:
      return
    result.add data

proc readAll(f: AsyncFile): Future[string] =
  readAllImpl(f)

proc writeBuffer(f: AsyncFile, buf: pointer, size: int): Future[void] =
  var retFuture = newFuture[void]("asyncfile.writeBuffer")
  var written = 0

  proc cb(fd: AsyncFD): bool {.closure, gcsafe.} =
    result = true
    let remainderSize = size - written
    var cbuf = cast[cstring](buf)
    let res = write(fd.cint, addr cbuf[written], remainderSize.cint)
    if res < 0:
      let lastError = osLastError()
      if lastError.int32 != posix.EAGAIN:
        retFuture.fail(newException(OSError, osErrorMsg(lastError)))
      else:
        result = false # We still want this callback to be called.
    else:
      written.inc res
      f.offset.inc res
      if res != remainderSize:
        result = false # We still have data to write.
      else:
        retFuture.complete()

  proc cbf(arg: pointer) {.closure, gcsafe.} =
    let fd = cast[ptr AsyncFD](arg)[]
    if cb(fd):
      removeWriter(fd)

  if not cb(f.fd):
    addWriter(f.fd, CallbackFunc(cbf))
  return retFuture

proc write(f: AsyncFile, data: string): Future[void] =
  var retFuture = newFuture[void]("asyncfile.write")
  var copy = data
  var written = 0

  proc cb(fd: AsyncFD): bool {.closure, gcsafe.} =
    result = true

    let remainderSize = data.len - written

    let res =
      if data.len == 0:
        write(fd.cint, copy.cstring, 0)
      else:
        write(fd.cint, addr copy[written], remainderSize.cint)

    if res < 0:
      let lastError = osLastError()
      if lastError.int32 != posix.EAGAIN:
        retFuture.fail(newException(OSError, osErrorMsg(lastError)))
      else:
        result = false # We still want this callback to be called.
    else:
      written.inc res
      f.offset.inc res
      if res != remainderSize:
        result = false # We still have data to write.
      else:
        retFuture.complete()

  proc cbf(arg: pointer) {.closure, gcsafe.} =
    let fd = cast[ptr AsyncFD](arg)[]
    if cb(fd):
      removeWriter(fd)

  if not cb(f.fd):
    addWriter(f.fd, CallbackFunc(cbf))

  return retFuture

proc setFileSize(f: AsyncFile, length: int64) =
  # will truncate if Off is a 32-bit type!
  if ftruncate(f.fd.cint, length.Off) == -1:
    raiseOSError(osLastError())

proc close(f: AsyncFile) =
  unregister(f.fd)
  if close(f.fd.cint) == -1:
    raiseOSError(osLastError())

#proc writeFromStream(f: AsyncFile, fs: FutureStream[string]) {.async.} =
#  while true:
#    let (hasValue, value) = await fs.read()
#    if hasValue:
#      await f.write(value)
#    else:
#      break
#
#proc readToStream(f: AsyncFile, fs: FutureStream[string]) {.async.} =
#  while true:
#    let data = await read(f, 4000)
#    if data.len == 0:
#      break
#    await fs.write(data)
#
#  fs.complete()
