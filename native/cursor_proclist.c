/*
 * Linux implementation of Cursor's cursor_proclist native API.
 *
 * The Windows/macOS addon is private. The JavaScript wrapper
 * (dist/deps/cursor-proclist/index.js) documents the contract:
 *
 *   cursor_proclist_scan_async(roots?: number[])
 *     -> Promise<Array<[pid, ppid, name, extensionId, cpuTimeMs,
 *                       memoryMB, argv, ownerAgentId, requestId]>>
 *
 *   cursor_proclist_system_memory()
 *     -> { totalBytes, availableBytes, pressureLevel? } | null
 *
 * The /proc walk runs on the libuv thread pool so a scan never blocks the
 * Electron main process; only building the result array happens on the
 * JavaScript thread.
 */

#include <ctype.h>
#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <node_api.h>

#define MAX_ROOTS 64
#define CMDLINE_MAX 16384

typedef struct {
  int pid;
  int ppid;
  char name[256];
  unsigned long long utime;
  unsigned long long stime;
  unsigned long rss_pages;
  char *argv; /* heap, NUL-terminated, may be "" */
  signed char keep; /* -1 unknown, 0 no, 1 yes */
} proc_row;

typedef struct {
  napi_async_work work;
  napi_deferred deferred;
  int roots[MAX_ROOTS];
  int nroots;
  proc_row *rows;
  size_t nrows;
  int failed;
} scan_job;

static int read_file(const char *path, char *buf, size_t buflen) {
  FILE *f = fopen(path, "r");
  if (!f) {
    return -1;
  }
  size_t n = fread(buf, 1, buflen - 1, f);
  fclose(f);
  buf[n] = '\0';
  return (int)n;
}

static int parse_stat(int pid, proc_row *row) {
  char path[64];
  char buf[4096];
  snprintf(path, sizeof(path), "/proc/%d/stat", pid);
  if (read_file(path, buf, sizeof(buf)) < 0) {
    return -1;
  }

  char *rparen = strrchr(buf, ')');
  char *lparen = strchr(buf, '(');
  if (!rparen || !lparen || lparen >= rparen) {
    return -1;
  }

  size_t namelen = (size_t)(rparen - lparen - 1);
  if (namelen >= sizeof(row->name)) {
    namelen = sizeof(row->name) - 1;
  }
  memcpy(row->name, lparen + 1, namelen);
  row->name[namelen] = '\0';

  /* After ")": state ppid ... utime stime ... rss (field 24) */
  int ppid = 0;
  unsigned long long utime = 0;
  unsigned long long stime = 0;
  unsigned long rss = 0;
  if (sscanf(rparen + 2,
             "%*c %d %*d %*d %*d %*d %*u %*u %*u %*u %*u %llu %llu %*d %*d "
             "%*d %*d %*d %*d %*u %*u %lu",
             &ppid, &utime, &stime, &rss) < 4) {
    return -1;
  }

  row->pid = pid;
  row->ppid = ppid;
  row->utime = utime;
  row->stime = stime;
  row->rss_pages = rss;
  return 0;
}

/* Full command line with NUL separators turned into spaces. */
static char *read_cmdline(int pid) {
  char path[64];
  snprintf(path, sizeof(path), "/proc/%d/cmdline", pid);
  char *buf = malloc(CMDLINE_MAX);
  if (!buf) {
    return NULL;
  }
  int n = read_file(path, buf, CMDLINE_MAX);
  if (n <= 0) {
    buf[0] = '\0';
    return buf;
  }
  for (int i = 0; i < n; i++) {
    if (buf[i] == '\0') {
      buf[i] = ' ';
    }
  }
  while (n > 0 && buf[n - 1] == ' ') {
    buf[--n] = '\0';
  }
  return buf;
}

static int cmp_pid(const void *a, const void *b) {
  int pa = ((const proc_row *)a)->pid;
  int pb = ((const proc_row *)b)->pid;
  return (pa > pb) - (pa < pb);
}

static proc_row *find_row(proc_row *rows, size_t nrows, int pid) {
  proc_row key;
  key.pid = pid;
  return bsearch(&key, rows, nrows, sizeof(proc_row), cmp_pid);
}

static int is_root(const scan_job *job, int pid) {
  for (int i = 0; i < job->nroots; i++) {
    if (job->roots[i] == pid) {
      return 1;
    }
  }
  return 0;
}

/*
 * Mark every row that is a root or descends from one. Each row is decided
 * once: walk up until a decided ancestor (or a root, or the top), then
 * write the answer back down the walked chain. Linear in the process count.
 */
static void mark_descendants(scan_job *job) {
  size_t chain_cap = 64;
  size_t *chain = malloc(chain_cap * sizeof(size_t));
  if (!chain) {
    job->failed = 1;
    return;
  }
  for (size_t i = 0; i < job->nrows; i++) {
    size_t depth = 0;
    proc_row *cur = &job->rows[i];
    signed char verdict = 0;
    while (cur) {
      if (cur->keep >= 0) {
        verdict = cur->keep;
        break;
      }
      if (is_root(job, cur->pid)) {
        cur->keep = 1;
        verdict = 1;
        break;
      }
      if (depth == chain_cap) {
        size_t *grown = realloc(chain, chain_cap * 2 * sizeof(size_t));
        if (!grown) {
          job->failed = 1;
          free(chain);
          return;
        }
        chain = grown;
        chain_cap *= 2;
      }
      chain[depth++] = (size_t)(cur - job->rows);
      if (cur->ppid <= 0 || cur->ppid == cur->pid) {
        break;
      }
      cur = find_row(job->rows, job->nrows, cur->ppid);
    }
    for (size_t d = 0; d < depth; d++) {
      job->rows[chain[d]].keep = verdict;
    }
  }
  free(chain);
}

static void ScanExecute(napi_env env, void *data) {
  (void)env;
  scan_job *job = data;
  DIR *dir = opendir("/proc");
  if (!dir) {
    return;
  }
  size_t cap = 1024;
  job->rows = calloc(cap, sizeof(proc_row));
  if (!job->rows) {
    job->failed = 1;
    closedir(dir);
    return;
  }
  struct dirent *ent;
  while ((ent = readdir(dir)) != NULL) {
    if (!isdigit((unsigned char)ent->d_name[0])) {
      continue;
    }
    int pid = atoi(ent->d_name);
    if (pid <= 0) {
      continue;
    }
    if (job->nrows == cap) {
      proc_row *grown = realloc(job->rows, cap * 2 * sizeof(proc_row));
      if (!grown) {
        job->failed = 1;
        break;
      }
      job->rows = grown;
      cap *= 2;
    }
    proc_row *row = &job->rows[job->nrows];
    memset(row, 0, sizeof(*row));
    if (parse_stat(pid, row) == 0) {
      row->argv = read_cmdline(pid);
      row->keep = job->nroots > 0 ? -1 : 1;
      job->nrows++;
    }
  }
  closedir(dir);
  if (job->failed) {
    return;
  }
  qsort(job->rows, job->nrows, sizeof(proc_row), cmp_pid);
  if (job->nroots > 0) {
    mark_descendants(job);
  }
}

static void free_job(scan_job *job) {
  if (job->rows) {
    for (size_t i = 0; i < job->nrows; i++) {
      free(job->rows[i].argv);
    }
    free(job->rows);
  }
  free(job);
}

static void ScanComplete(napi_env env, napi_status status, void *data) {
  scan_job *job = data;
  if (status != napi_ok || job->failed) {
    napi_value msg, err;
    napi_create_string_utf8(env, "cursor_proclist: scan failed",
                            NAPI_AUTO_LENGTH, &msg);
    napi_create_error(env, NULL, msg, &err);
    napi_reject_deferred(env, job->deferred, err);
    napi_delete_async_work(env, job->work);
    free_job(job);
    return;
  }

  long hz = sysconf(_SC_CLK_TCK);
  if (hz <= 0) {
    hz = 100;
  }
  long page = sysconf(_SC_PAGESIZE);
  if (page <= 0) {
    page = 4096;
  }

  napi_value result;
  napi_create_array(env, &result);
  uint32_t out_i = 0;
  for (size_t i = 0; i < job->nrows; i++) {
    proc_row *r = &job->rows[i];
    if (r->keep != 1) {
      continue;
    }
    napi_value tuple, v;
    napi_create_array_with_length(env, 9, &tuple);
    napi_create_int32(env, r->pid, &v);
    napi_set_element(env, tuple, 0, v);
    napi_create_int32(env, r->ppid, &v);
    napi_set_element(env, tuple, 1, v);
    napi_create_string_utf8(env, r->name, NAPI_AUTO_LENGTH, &v);
    napi_set_element(env, tuple, 2, v);
    napi_create_string_utf8(env, "", NAPI_AUTO_LENGTH, &v);
    napi_set_element(env, tuple, 3, v);
    napi_create_double(env, (double)(r->utime + r->stime) * 1000.0 / (double)hz,
                       &v);
    napi_set_element(env, tuple, 4, v);
    napi_create_double(
        env, (double)r->rss_pages * (double)page / (1024.0 * 1024.0), &v);
    napi_set_element(env, tuple, 5, v);
    napi_create_string_utf8(env, r->argv ? r->argv : "", NAPI_AUTO_LENGTH, &v);
    napi_set_element(env, tuple, 6, v);
    napi_get_null(env, &v);
    napi_set_element(env, tuple, 7, v);
    napi_set_element(env, tuple, 8, v);
    napi_set_element(env, result, out_i++, tuple);
  }
  napi_resolve_deferred(env, job->deferred, result);
  napi_delete_async_work(env, job->work);
  free_job(job);
}

static napi_value ScanAsync(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1];
  napi_get_cb_info(env, info, &argc, argv, NULL, NULL);

  scan_job *job = calloc(1, sizeof(scan_job));
  if (!job) {
    napi_throw_error(env, NULL, "out of memory");
    return NULL;
  }
  if (argc >= 1) {
    bool is_array = false;
    napi_is_array(env, argv[0], &is_array);
    if (is_array) {
      uint32_t len = 0;
      napi_get_array_length(env, argv[0], &len);
      if (len > MAX_ROOTS) {
        len = MAX_ROOTS;
      }
      for (uint32_t i = 0; i < len; i++) {
        napi_value item;
        int32_t pid = 0;
        napi_get_element(env, argv[0], i, &item);
        if (napi_get_value_int32(env, item, &pid) == napi_ok && pid > 0) {
          job->roots[job->nroots++] = pid;
        }
      }
    }
  }

  napi_value promise, name;
  if (napi_create_promise(env, &job->deferred, &promise) != napi_ok) {
    free(job);
    return NULL;
  }
  napi_create_string_utf8(env, "cursor_proclist_scan", NAPI_AUTO_LENGTH, &name);
  if (napi_create_async_work(env, NULL, name, ScanExecute, ScanComplete, job,
                             &job->work) != napi_ok ||
      napi_queue_async_work(env, job->work) != napi_ok) {
    napi_throw_error(env, NULL, "cursor_proclist: could not queue scan");
    return NULL;
  }
  return promise;
}

static napi_value SystemMemory(napi_env env, napi_callback_info info) {
  (void)info;
  FILE *f = fopen("/proc/meminfo", "r");
  if (!f) {
    napi_value n;
    napi_get_null(env, &n);
    return n;
  }
  unsigned long long total_kb = 0;
  unsigned long long avail_kb = 0;
  char line[256];
  while (fgets(line, sizeof(line), f)) {
    if (sscanf(line, "MemTotal: %llu kB", &total_kb) == 1) {
      continue;
    }
    if (sscanf(line, "MemAvailable: %llu kB", &avail_kb) == 1) {
      continue;
    }
  }
  fclose(f);

  napi_value result, v_total, v_avail;
  napi_create_object(env, &result);
  napi_create_double(env, (double)total_kb * 1024.0, &v_total);
  napi_create_double(env, (double)avail_kb * 1024.0, &v_avail);
  napi_set_named_property(env, result, "totalBytes", v_total);
  napi_set_named_property(env, result, "availableBytes", v_avail);
  if (total_kb > 0 && avail_kb * 100 / total_kb < 10) {
    napi_value pressure;
    napi_create_string_utf8(env, "critical", NAPI_AUTO_LENGTH, &pressure);
    napi_set_named_property(env, result, "pressureLevel", pressure);
  }
  return result;
}

static napi_value Init(napi_env env, napi_value exports) {
  napi_value fn_scan;
  napi_value fn_mem;
  napi_create_function(env, "cursor_proclist_scan_async", NAPI_AUTO_LENGTH,
                       ScanAsync, NULL, &fn_scan);
  napi_create_function(env, "cursor_proclist_system_memory", NAPI_AUTO_LENGTH,
                       SystemMemory, NULL, &fn_mem);
  napi_set_named_property(env, exports, "cursor_proclist_scan_async", fn_scan);
  napi_set_named_property(env, exports, "cursor_proclist_system_memory",
                          fn_mem);
  return exports;
}

NAPI_MODULE(cursor_proclist, Init)
