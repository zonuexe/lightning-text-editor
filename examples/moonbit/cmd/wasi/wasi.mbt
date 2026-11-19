///|
/// Pure WASI Preview 1 (`wasi_snapshot_preview1`) linear-memory bindings.
/// Zero external MoonBit dependencies so the compiled `.wasm` runs on any
/// standard WASI Preview 1 runtime (wasmtime, wasmer, browser_wasi_shim, etc.).

///|
#borrow(arr)
extern "wasm" fn fixed_bytes_ptr(arr : FixedArray[Byte]) -> Int32 =
  #|(func (param i32) (result i32) (local.get 0))

///|
#borrow(arr)
extern "wasm" fn bytes_ptr(arr : Bytes) -> Int32 =
  #|(func (param i32) (result i32) (local.get 0))

///|
#borrow(arr)
extern "wasm" fn keep_bytes_alive(arr : Bytes) -> Unit =
  #|(func (param i32))

///|
#borrow(arr)
extern "wasm" fn keep_fixed_bytes_alive(arr : FixedArray[Byte]) -> Unit =
  #|(func (param i32))

///|
#unsafe_skip_stub_check
#borrow(iovs, nread)
fn wasi_fd_read(
  fd : Int32,
  iovs : FixedArray[Int32],
  iovs_len : Int32,
  nread : FixedArray[Int32],
) -> Int32 = "wasi_snapshot_preview1" "fd_read"

///|
#unsafe_skip_stub_check
#borrow(iovs, nwritten)
fn wasi_fd_write(
  fd : Int32,
  iovs : FixedArray[Int32],
  iovs_len : Int32,
  nwritten : FixedArray[Int32],
) -> Int32 = "wasi_snapshot_preview1" "fd_write"

///|
#unsafe_skip_stub_check
#borrow(argc, argv_buf_size)
fn wasi_args_sizes_get(
  argc : FixedArray[Int32],
  argv_buf_size : FixedArray[Int32],
) -> Int32 = "wasi_snapshot_preview1" "args_sizes_get"

///|
#unsafe_skip_stub_check
#borrow(argv, argv_buf)
fn wasi_args_get(
  argv : FixedArray[Int32],
  argv_buf : FixedArray[Byte],
) -> Int32 = "wasi_snapshot_preview1" "args_get"

///|
#unsafe_skip_stub_check
#borrow(environc, environ_buf_size)
fn wasi_environ_sizes_get(
  environc : FixedArray[Int32],
  environ_buf_size : FixedArray[Int32],
) -> Int32 = "wasi_snapshot_preview1" "environ_sizes_get"

///|
#unsafe_skip_stub_check
#borrow(environ, environ_buf)
fn wasi_environ_get(
  environ : FixedArray[Int32],
  environ_buf : FixedArray[Byte],
) -> Int32 = "wasi_snapshot_preview1" "environ_get"

///|
#unsafe_skip_stub_check
#borrow(path, fd_out)
fn wasi_path_open(
  dirfd : Int32,
  dirflags : Int32,
  path : Bytes,
  path_len : Int32,
  oflags : Int32,
  fs_rights_base : Int64,
  fs_rights_inheriting : Int64,
  fdflags : Int32,
  fd_out : FixedArray[Int32],
) -> Int32 = "wasi_snapshot_preview1" "path_open"

///|
#unsafe_skip_stub_check
fn wasi_fd_close(fd : Int32) -> Int32 = "wasi_snapshot_preview1" "fd_close"

///|
/// Write all bytes of a UTF-8 `Bytes` buffer to a WASI file descriptor.
pub fn fd_write_all(fd : Int32, data : Bytes) -> Bool {
  let total = data.length()
  if total == 0 {
    return true
  }
  let base_ptr = bytes_ptr(data)
  let iovs : FixedArray[Int32] = [0, 0]
  let nwritten : FixedArray[Int32] = [0]
  let mut offset = 0
  while offset < total {
    iovs[0] = base_ptr + offset
    iovs[1] = total - offset
    nwritten[0] = 0
    let err = wasi_fd_write(fd, iovs, 1, nwritten)
    if err != 0 || nwritten[0] <= 0 {
      keep_bytes_alive(data)
      return false
    }
    offset += nwritten[0]
  }
  keep_bytes_alive(data)
  true
}

///|
/// Write a MoonBit `String` (encoded as UTF-8) to stdout (fd 1).
pub fn write_stdout(s : String) -> Unit {
  if s == "" {
    return
  }
  let utf8 = @utf8.encode(s)
  ignore(fd_write_all(1, utf8))
}

///|
/// Read up to `buf.length()` bytes from a WASI file descriptor.
pub fn fd_read_chunk(fd : Int32, buf : FixedArray[Byte]) -> Int32 {
  let ptr = fixed_bytes_ptr(buf)
  let iovs : FixedArray[Int32] = [ptr, buf.length()]
  let nread : FixedArray[Int32] = [0]
  let err = wasi_fd_read(fd, iovs, 1, nread)
  keep_fixed_bytes_alive(buf)
  if err != 0 {
    -1
  } else {
    nread[0]
  }
}

///|
fn read_cstr_from_buf(buf : FixedArray[Byte], start : Int32) -> String {
  let bytes : Array[Byte] = []
  let mut p = start
  while p >= 0 && p < buf.length() {
    let b = buf[p]
    if b == b'\x00' {
      break
    }
    bytes.push(b)
    p += 1
  }
  let raw = Bytes::makei(bytes.length(), fn(i) { bytes[i] })
  @utf8.decode_lossy(raw)
}

///|
/// Retrieve CLI arguments via WASI `args_sizes_get` + `args_get`.
pub fn get_args() -> Array[String] {
  let argc : FixedArray[Int32] = [0]
  let buf_size : FixedArray[Int32] = [0]
  if wasi_args_sizes_get(argc, buf_size) != 0 || argc[0] <= 0 {
    return []
  }
  let count = argc[0]
  let bsize = if buf_size[0] < 1 { 1 } else { buf_size[0] }
  let argv : FixedArray[Int32] = FixedArray::make(count, 0)
  let argv_buf : FixedArray[Byte] = FixedArray::make(bsize, b'\x00')
  let base = fixed_bytes_ptr(argv_buf)
  if wasi_args_get(argv, argv_buf) != 0 {
    return []
  }
  let out : Array[String] = []
  for i = 0; i < count; i = i + 1 {
    out.push(read_cstr_from_buf(argv_buf, argv[i] - base))
  }
  out
}

///|
/// Retrieve environment variable value by key via WASI `environ_get`.
pub fn get_env(key : String) -> String? {
  let envc : FixedArray[Int32] = [0]
  let buf_size : FixedArray[Int32] = [0]
  if wasi_environ_sizes_get(envc, buf_size) != 0 || envc[0] <= 0 {
    return None
  }
  let count = envc[0]
  let bsize = if buf_size[0] < 1 { 1 } else { buf_size[0] }
  let environ : FixedArray[Int32] = FixedArray::make(count, 0)
  let environ_buf : FixedArray[Byte] = FixedArray::make(bsize, b'\x00')
  let base = fixed_bytes_ptr(environ_buf)
  if wasi_environ_get(environ, environ_buf) != 0 {
    return None
  }
  let prefix = key + "="
  let mut found : String? = None
  for i = 0; i < count; i = i + 1 {
    let entry = read_cstr_from_buf(environ_buf, environ[i] - base)
    if entry.has_prefix(prefix) {
      found = Some(entry[prefix.length():].to_owned())
      break
    }
  }
  found
}

///|
/// Preopen directory fd 3 (standard first `--dir` in WASI runtimes).
const PREOPEN_DIR_FD : Int32 = 3

///|
/// Read a UTF-8 text file relative to the preopened directory (fd 3).
pub fn read_file_text(path : String) -> String? {
  let path_bytes = @utf8.encode(path)
  let fd_out : FixedArray[Int32] = [0]
  // rights: FD_READ (1<<1) | FD_SEEK (1<<2) | FD_FILESTAT_GET (1<<21)
  let rights : Int64 = (1L << 1) | (1L << 2) | (1L << 21)
  let err = wasi_path_open(
    PREOPEN_DIR_FD,
    1, // LOOKUP_SYMLINK_FOLLOW
    path_bytes,
    path_bytes.length(),
    0, // oflags = 0 (open existing)
    rights,
    rights,
    0,
    fd_out,
  )
  ignore(path_bytes.length())
  if err != 0 {
    return None
  }
  let fd = fd_out[0]
  let acc : Array[Byte] = []
  let chunk : FixedArray[Byte] = FixedArray::make(4096, b'\x00')
  while true {
    let n = fd_read_chunk(fd, chunk)
    if n <= 0 {
      break
    }
    for i = 0; i < n; i = i + 1 {
      acc.push(chunk[i])
    }
  }
  ignore(wasi_fd_close(fd))
  let all = Bytes::makei(acc.length(), fn(i) { acc[i] })
  Some(@utf8.decode_lossy(all))
}

///|
/// Write a UTF-8 text file relative to the preopened directory (fd 3).
pub fn write_file_text(path : String, content : String) -> Bool {
  let path_bytes = @utf8.encode(path)
  let fd_out : FixedArray[Int32] = [0]
  // oflags: O_CREAT (1) | O_TRUNC (8) = 9
  // rights: FD_WRITE (1<<6) | FD_SEEK (1<<2) | FD_FILESTAT_SET_SIZE (1<<22)
  let rights : Int64 = (1L << 6) | (1L << 2) | (1L << 22)
  let err = wasi_path_open(
    PREOPEN_DIR_FD,
    1,
    path_bytes,
    path_bytes.length(),
    9,
    rights,
    rights,
    0,
    fd_out,
  )
  ignore(path_bytes.length())
  if err != 0 {
    return false
  }
  let fd = fd_out[0]
  let ok = fd_write_all(fd, @utf8.encode(content))
  ignore(wasi_fd_close(fd))
  ok
}
