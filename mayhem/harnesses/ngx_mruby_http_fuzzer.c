// Drives ngx_mruby's own nginx module (src/http/*.c, src/stream/*.c, linked with nginx and the embedded mruby)
// in-process. LLVMFuzzerInitialize does what nginx's main() does in single-process mode (parse the
// configuration in mayhem/harnesses/ngx_mruby_http.conf, run every module's init_process). Each fuzz input is
// then sent as raw bytes over a unix socket to nginx's own listener and nginx's event loop is run until the
// connection closes, so the bytes go through nginx's request parser into the mruby handlers of the config.
#include <ngx_config.h>
#include <ngx_core.h>
#include <ngx_event.h>
#include <ngx_http.h>

#include <errno.h>
#include <fcntl.h>
#include <ftw.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#ifndef CONF_TEMPLATE
#error "build.sh passes -DCONF_TEMPLATE=<path of ngx_mruby_http.conf>"
#endif

#define MAX_REQUEST_BYTES (32 * 1024)
#define MAX_LOOPS 64

extern char **environ;
char **ngx_os_environ;

static ngx_cycle_t init_cycle;
static ngx_cycle_t *cycle;
static char workdir[256];
static char sockpath[300];

static int rm_cb(const char *p, const struct stat *sb, int flag, struct FTW *ftw) {
  (void)sb; (void)flag; (void)ftw;
  remove(p);
  return 0;
}

static void cleanup(void) {
  if (workdir[0]) nftw(workdir, rm_cb, 8, FTW_DEPTH | FTW_PHYS);
}

static int write_conf(const char *conf_path) {
  FILE *in = fopen(CONF_TEMPLATE, "r");
  if (!in) return -1;
  FILE *out = fopen(conf_path, "w");
  if (!out) { fclose(in); return -1; }
  char line[4096];
  while (fgets(line, sizeof line, in)) {
    char *p = line, *at;
    while ((at = strstr(p, "@PREFIX@"))) {
      fwrite(p, 1, (size_t)(at - p), out);
      fputs(workdir, out);
      p = at + strlen("@PREFIX@");
    }
    fputs(p, out);
  }
  fclose(in);
  fclose(out);
  return 0;
}

static ngx_str_t dup_str(const char *s, int trailing_slash) {
  size_t len = strlen(s) + (trailing_slash ? 1 : 0);
  ngx_str_t r = {len, ngx_pnalloc(init_cycle.pool, len + 1)};
  if (!r.data) exit(1);
  memcpy(r.data, s, strlen(s));
  if (trailing_slash) r.data[len - 1] = '/';
  r.data[len] = '\0';
  return r;
}

int LLVMFuzzerInitialize(int *argc, char ***argv) {
  const char *tmp = getenv("TMPDIR");
  snprintf(workdir, sizeof workdir, "%s/ngx_mruby_fuzz.XXXXXX", tmp && *tmp ? tmp : "/tmp");
  if (!mkdtemp(workdir)) { perror("mkdtemp"); exit(1); }
  atexit(cleanup);
  signal(SIGPIPE, SIG_IGN);

  char path[400];
  snprintf(path, sizeof path, "%s/html", workdir);
  mkdir(path, 0700);
  snprintf(path, sizeof path, "%s/nginx.conf", workdir);
  if (write_conf(path) != 0) { fprintf(stderr, "cannot write %s from %s\n", path, CONF_TEMPLATE); exit(1); }
  snprintf(sockpath, sizeof sockpath, "%s/ngx.sock", workdir);

  ngx_log_t *log;
  ngx_strerror_init();
  ngx_max_sockets = -1;
  ngx_time_init();
  ngx_regex_init();
  ngx_pid = ngx_getpid();
  ngx_parent = ngx_getppid();
  log = ngx_log_init((u_char *)workdir, (u_char *)"/dev/null");
  if (!log) exit(1);

  ngx_memzero(&init_cycle, sizeof init_cycle);
  init_cycle.log = log;
  ngx_cycle = &init_cycle;
  init_cycle.pool = ngx_create_pool(1024, log);
  if (!init_cycle.pool) exit(1);

  ngx_os_argv = *argv;
  ngx_argc = *argc;
  ngx_argv = *argv;
  ngx_os_environ = environ;

  init_cycle.prefix = dup_str(workdir, 1);
  init_cycle.conf_prefix = init_cycle.prefix;
  init_cycle.conf_file = dup_str(path, 0);
  ngx_str_set(&init_cycle.error_log, "stderr");

  if (ngx_os_init(log) != NGX_OK) exit(1);
  if (ngx_crc32_table_init() != NGX_OK) exit(1);
  ngx_slab_sizes_init();
  if (ngx_preinit_modules() != NGX_OK) exit(1);

  cycle = ngx_init_cycle(&init_cycle);
  if (!cycle) { fprintf(stderr, "ngx_init_cycle failed\n"); exit(1); }
  ngx_cycle = cycle;
  ngx_use_stderr = 0;

  for (ngx_uint_t i = 0; cycle->modules[i]; i++) {
    if (cycle->modules[i]->init_process && cycle->modules[i]->init_process(cycle) == NGX_ERROR) exit(2);
  }
  return 0;
}

static int drain(int fd) {
  char buf[4096];
  for (;;) {
    ssize_t n = recv(fd, buf, sizeof buf, MSG_DONTWAIT);
    if (n > 0) continue;
    if (n == 0) return 1;
    return 0;
  }
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  if (size > MAX_REQUEST_BYTES) return -1;

  int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_NONBLOCK, 0);
  if (fd < 0) return 0;
  struct sockaddr_un sa;
  memset(&sa, 0, sizeof sa);
  sa.sun_family = AF_UNIX;
  strncpy(sa.sun_path, sockpath, sizeof sa.sun_path - 1);
  if (connect(fd, (struct sockaddr *)&sa, sizeof sa) != 0) { close(fd); return 0; }

  size_t off = 0;
  while (off < size) {
    ssize_t n = send(fd, data + off, size - off, MSG_NOSIGNAL);
    if (n <= 0) break;
    off += (size_t)n;
  }
  shutdown(fd, SHUT_WR);

  for (int i = 0; i < MAX_LOOPS; i++) {
    ngx_process_events_and_timers(cycle);
    if (drain(fd)) break;
  }
  close(fd);
  return 0;
}
