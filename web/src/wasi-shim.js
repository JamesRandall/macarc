// The WASI preview 1 imports the Swift runtime asks for, for a host with no
// files, environment or arguments: a browser, a Web Worker, Node or workerd.
// The emulator never needs them to run a machine (ROMs and discs come in as
// bytes); Foundation's startup and stdout are all that call them. stdout and
// stderr go to the console; everything else reports "not supported".

const ERRNO_SUCCESS = 0;
const ERRNO_BADF = 8;
const ERRNO_NOSYS = 52;
const ERRNO_INVAL = 28;

export class ProcExit extends Error {
  constructor(code) { super(`proc_exit(${code})`); this.code = code; }
}

/**
 * @param {{ log?: (line: string) => void }} [options]
 * @returns {{ imports: WebAssembly.Imports, setMemory: (m: WebAssembly.Memory) => void }}
 */
export function createWasi(options = {}) {
  const log = options.log ?? ((s) => console.log(s));
  let memory = null;
  const view = () => new DataView(memory.buffer);
  const decoder = new TextDecoder();
  const pending = { 1: '', 2: '' };
  const start = typeof performance !== 'undefined' ? performance.now() : 0;

  const nosys = () => ERRNO_NOSYS;
  const badf = () => ERRNO_BADF;

  const wasi = {
    args_sizes_get(argc, bufSize) { view().setUint32(argc, 0, true); view().setUint32(bufSize, 0, true); return ERRNO_SUCCESS; },
    args_get() { return ERRNO_SUCCESS; },
    environ_sizes_get(count, bufSize) { view().setUint32(count, 0, true); view().setUint32(bufSize, 0, true); return ERRNO_SUCCESS; },
    environ_get() { return ERRNO_SUCCESS; },
    clock_res_get(_id, out) { view().setBigUint64(out, 1000n, true); return ERRNO_SUCCESS; },
    clock_time_get(id, _precision, out) {
      // Realtime for 0; monotonic otherwise. (The emulation never reads
      // either: guest time only moves when the host runs it.)
      const ms = id === 0 ? Date.now() : (typeof performance !== 'undefined' ? performance.now() - start : Date.now());
      view().setBigUint64(out, BigInt(Math.round(ms * 1e6)), true);
      return ERRNO_SUCCESS;
    },
    random_get(buf, len) {
      const bytes = new Uint8Array(memory.buffer, buf, len);
      for (let i = 0; i < len; i += 65536) crypto.getRandomValues(bytes.subarray(i, Math.min(len, i + 65536)));
      return ERRNO_SUCCESS;
    },
    fd_write(fd, iovs, iovsLen, nwritten) {
      if (fd !== 1 && fd !== 2) return ERRNO_BADF;
      const v = view();
      let total = 0;
      for (let i = 0; i < iovsLen; i++) {
        const ptr = v.getUint32(iovs + i * 8, true), len = v.getUint32(iovs + i * 8 + 4, true);
        pending[fd] += decoder.decode(new Uint8Array(memory.buffer, ptr, len));
        total += len;
      }
      let nl;
      while ((nl = pending[fd].indexOf('\n')) >= 0) { log(pending[fd].slice(0, nl)); pending[fd] = pending[fd].slice(nl + 1); }
      v.setUint32(nwritten, total, true);
      return ERRNO_SUCCESS;
    },
    fd_fdstat_get(fd, out) {
      if (fd > 2) return ERRNO_BADF;
      const v = view();
      v.setUint8(out, 2); // character device
      v.setUint16(out + 2, 0, true);
      v.setBigUint64(out + 8, 0n, true);
      v.setBigUint64(out + 16, 0n, true);
      return ERRNO_SUCCESS;
    },
    fd_prestat_get: badf, // no preopened directories
    fd_prestat_dir_name: badf,
    fd_close: badf,
    fd_fdstat_set_flags: badf,
    fd_filestat_get: badf,
    fd_filestat_set_size: badf,
    fd_filestat_set_times: badf,
    fd_pread: badf,
    fd_pwrite: badf,
    fd_read: badf,
    fd_readdir: badf,
    fd_seek: badf,
    fd_sync: badf,
    fd_tell: badf,
    path_create_directory: nosys,
    path_filestat_get: nosys,
    path_filestat_set_times: nosys,
    path_link: nosys,
    path_open: nosys,
    path_readlink: nosys,
    path_remove_directory: nosys,
    path_rename: nosys,
    path_symlink: nosys,
    path_unlink_file: nosys,
    poll_oneoff: () => ERRNO_INVAL,
    sched_yield: () => ERRNO_SUCCESS,
    proc_exit(code) { throw new ProcExit(code); },
  };

  return {
    imports: { wasi_snapshot_preview1: wasi },
    setMemory(m) { memory = m; },
  };
}
