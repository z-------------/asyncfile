## Asynchronous file reading and writing.
##
## When `asyncBackend` is undefined or set to `"asyncdispatch"`, simply
## re-exports std/asyncfile. When `asyncBackend` is `"chronos"`, implements the
## same API for Chronos.

const asyncBackend {.strdefine.} = "asyncdispatch"

when asyncBackend == "asyncdispatch":
  import std/asyncfile
  export asyncfile
elif asyncBackend == "chronos":
  import pkg/chronos
  when (NimMajor, NimMinor) >= (1, 9):
    const HasPath = true
    import std/paths
  else:
    const HasPath = false

  type
    AsyncFile* = ref object
      fd: AsyncFD
      offset: int64

  proc close*(f: AsyncFile) {.raises: [OSError].}
    ## Closes the file specified.

  proc getFilePos*(f: AsyncFile): int64 {.raises: [].} =
    ## Retrieves the current position of the file pointer that is used to read
    ## from the specified file. The file's first byte has the index zero.
    f.offset

  proc getFileSize*(f: AsyncFile): int64 {.raises: [OSError].}
    ## Retrieves the specified file's size.

  proc newAsyncFile*(fd: AsyncFD): AsyncFile {.raises: [OSError].} =
    ## Creates `AsyncFile` with a previously opened file descriptor `fd`.
    new result
    result.fd = fd
    register(fd)

  when HasPath:
    proc openAsync*(filename: Path; mode = fmRead): AsyncFile {.raises: [OSError].}
      ## Opens a file specified by the path in `filename` using the specified
      ## FileMode `mode` asynchronously.

  proc openAsync*(filename: string; mode = fmRead): AsyncFile {.raises: [OSError].}
    ## Opens a file specified by the path in `filename` using the specified
    ## FileMode `mode` asynchronously.

  proc read*(f: AsyncFile; size: Natural): Future[string] {.gcsafe.}
    ## Read `size` bytes from the specified file asynchronously starting at the
    ## current position of the file pointer.
    ##
    ## If the file pointer is past the end of the file then an empty string is
    ## returned.

  proc readAll*(f: AsyncFile): Future[string] {.async.} =
    ## Reads all data from the specified file.
    result = ""
    while true:
      let data = await read(f, 4000)
      if data.len == 0:
        return
      result.add data

  proc readBuffer*(f: AsyncFile; buf: pointer; size: int): Future[int]
    ## Read `size` bytes from the specified file asynchronously starting at the
    ## current position of the file pointer.
    ##
    ## If the file pointer is past the end of the file then zero is returned
    ## and no bytes are read into `buf`.

  proc readLine*(f: AsyncFile): Future[string] {.async.} =
    ## Reads a single line from the specified file asynchronously.
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

  # TODO
  #proc readToStream*(f: AsyncFile, fs: FutureStream[string]) {.async.} =
  #  ## Writes data to the specified future stream as the file is read.
  #  while true:
  #    let data = await read(f, 4000)
  #    if data.len == 0:
  #      break
  #    await fs.write(data)
  #
  #  fs.complete()

  proc setFilePos*(f: AsyncFile; pos: int64) {.raises: [OSError].}
    ## Sets the position of the file pointer that is used for read/write operations. The file's first byte has the index zero.

  proc setFileSize*(f: AsyncFile; length: int64) {.raises: [OSError].}
    ## Set a file length.

  proc write*(f: AsyncFile; data: string): Future[void]
    ## Writes `data` to the file specified asynchronously.
    ##
    ## The returned Future will complete once all data has been written to the specified file.

  proc writeBuffer*(f: AsyncFile; buf: pointer; size: int): Future[void] {.gcsafe.}
    ## Writes `size` bytes from `buf` to the file specified asynchronously.
    ##
    ## The returned Future will complete once all data has been written to the specified file.

  proc writeFromStream*(f: AsyncFile, fs: AsyncStreamReader) {.async.} =
    ## Reads data from the specified future stream until it is completed.
    var buf = default array[AsyncStreamDefaultBufferSize, byte]
    while not fs.atEof:
      let count = await fs.readOnce(addr buf[0], buf.len)
      await f.writeBuffer(addr buf[0], count)

  when defined(windows):
    include ./asyncfile/impl/windows
  else:
    include ./asyncfile/impl/posix
