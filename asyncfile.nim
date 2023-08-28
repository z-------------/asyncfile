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

  proc getFilePos*(f: AsyncFile): int64 {.raises: [].}
    ## Retrieves the current position of the file pointer that is used to read
    ## from the specified file. The file's first byte has the index zero.

  proc getFileSize*(f: AsyncFile): int64 {.raises: [].}
    ## Retrieves the specified file's size.

  proc newAsyncFile*(fd: AsyncFD): AsyncFile {.raises: [OSError].}
    ## Creates `AsyncFile` with a previously opened file descriptor `fd`.

  when HasPath:
    proc openAsync*(filename: Path; mode = fmRead): AsyncFile {.raises: [OSError].}
      ## Opens a file specified by the path in `filename` using the specified
      ## FileMode `mode` asynchronously.

  proc openAsync*(filename: string; mode = fmRead): AsyncFile {.raises: [OSError].}
    ## Opens a file specified by the path in `filename` using the specified
    ## FileMode `mode` asynchronously.

  proc read*(f: AsyncFile; size: Natural): Future[string]
    ## Read `size` bytes from the specified file asynchronously starting at the
    ## current position of the file pointer.
    ##
    ## If the file pointer is past the end of the file then an empty string is
    ## returned.

  proc readAll*(f: AsyncFile): Future[string]
    ## Reads all data from the specified file.

  proc readBuffer*(f: AsyncFile; buf: pointer; size: int): Future[int]
    ## Read `size` bytes from the specified file asynchronously starting at the
    ## current position of the file pointer.
    ##
    ## If the file pointer is past the end of the file then zero is returned
    ## and no bytes are read into `buf`.

  proc readLine*(f: AsyncFile): Future[string]
    ## Reads a single line from the specified file asynchronously.

  # TODO
  #proc readToStream*(f: AsyncFile; fs: FutureStream[string]): Future[void]
  #  ## Writes data to the specified future stream as the file is read.

  proc setFilePos*(f: AsyncFile; pos: int64) {.raises: [OSError].}
    ## Sets the position of the file pointer that is used for read/write operations. The file's first byte has the index zero.

  proc setFileSize*(f: AsyncFile; length: int64) {.raises: [OSError].}
    ## Set a file length.

  proc write*(f: AsyncFile; data: string): Future[void]
    ## Writes `data` to the file specified asynchronously.
    ##
    ## The returned Future will complete once all data has been written to the specified file.

  proc writeBuffer*(f: AsyncFile; buf: pointer; size: int): Future[void]
    ## Writes `size` bytes from `buf` to the file specified asynchronously.
    ##
    ## The returned Future will complete once all data has been written to the specified file.

  # TODO
  #proc writeFromStream(f: AsyncFile; fs: FutureStream[string]): Future[void]
  #  ## Reads data from the specified future stream until it is completed. The data which is read is written to the file immediately and freed from memory.
  #  ##
  #  ## This procedure is perfect for saving streamed data to a file without wasting memory.

  when defined(windows):
    {.error: "Windows support is not implemented.".}
    include ./asyncfile/impl/windows
  else:
    include ./asyncfile/impl/posix
