#define _DARWIN_C_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

static volatile sig_atomic_t child_pid = -1;
static volatile sig_atomic_t stop_requested = 0;

static void handle_signal(int sig) {
  (void)sig;
  stop_requested = 1;
  if (child_pid > 0) {
    kill(-child_pid, SIGTERM);
  }
}

static void set_default_env(const char *key, const char *value) {
  if (!getenv(key) && value && value[0]) {
    setenv(key, value, 1);
  }
}

static void trim_newline(char *value) {
  size_t len = strlen(value);
  while (len > 0 && (value[len - 1] == '\n' || value[len - 1] == '\r')) {
    value[--len] = '\0';
  }
}

static void load_env_file(const char *path, int skip_source_version) {
  if (!path || !path[0]) {
    return;
  }

  FILE *fp = fopen(path, "r");
  if (!fp) {
    return;
  }

  char line[4096];
  while (fgets(line, sizeof(line), fp)) {
    trim_newline(line);
    if (line[0] == '\0' || line[0] == '#') {
      continue;
    }

    char *eq = strchr(line, '=');
    if (!eq) {
      continue;
    }

    *eq = '\0';
    char *key = line;
    char *value = eq + 1;
    if (skip_source_version && strcmp(key, "AG_SOURCE_VERSION") == 0) {
      continue;
    }
    if (key[0] && value[0] && !getenv(key)) {
      setenv(key, value, 1);
    }
  }

  fclose(fp);
}

static int is_primary_chromium_launch(int argc, char **argv) {
  const char *run_as_node = getenv("ELECTRON_RUN_AS_NODE");
  if (run_as_node && run_as_node[0]) {
    return 0;
  }
  for (int i = 1; i < argc; i++) {
    if (strncmp(argv[i], "--type=", 7) == 0 || strcmp(argv[i], "--type") == 0) {
      return 0;
    }
  }
  return 1;
}

static int has_arg_prefix(int argc, char **argv, const char *prefix) {
  size_t len = strlen(prefix);
  for (int i = 1; i < argc; i++) {
    if (strncmp(argv[i], prefix, len) == 0) {
      return 1;
    }
  }
  return 0;
}

static void build_chromium_proxy_url(char *buf, size_t buf_size) {
  if (!buf || buf_size == 0) {
    return;
  }
  buf[0] = '\0';

  const char *raw = getenv("HTTPS_PROXY");
  if (!raw || !raw[0]) {
    raw = getenv("HTTP_PROXY");
  }
  if (!raw || !raw[0]) {
    raw = getenv("ALL_PROXY");
  }
  if (!raw || !raw[0]) {
    raw = getenv("AG_PROXY");
  }
  if (!raw || !raw[0]) {
    return;
  }

  if (strncasecmp(raw, "socks5h://", 10) == 0) {
    snprintf(buf, buf_size, "socks5://%s", raw + 10);
  } else {
    snprintf(buf, buf_size, "%s", raw);
  }
}

static int dirname_inplace(char *path) {
  char *slash = strrchr(path, '/');
  if (!slash) {
    return -1;
  }
  *slash = '\0';
  return 0;
}

static int read_source_app_version(char *buf, size_t buf_size) {
  if (!buf || buf_size == 0) {
    return -1;
  }
  buf[0] = '\0';

  const char *plist_path = "/Applications/Antigravity.app/Contents/Info.plist";
  if (access(plist_path, R_OK) != 0) {
    return -1;
  }

  int pipefd[2];
  if (pipe(pipefd) != 0) {
    return -1;
  }

  pid_t pid = fork();
  if (pid < 0) {
    close(pipefd[0]);
    close(pipefd[1]);
    return -1;
  }

  if (pid == 0) {
    close(pipefd[0]);
    dup2(pipefd[1], STDOUT_FILENO);
    close(pipefd[1]);
    int devnull = open("/dev/null", O_WRONLY);
    if (devnull >= 0) {
      dup2(devnull, STDERR_FILENO);
      if (devnull > STDERR_FILENO) {
        close(devnull);
      }
    }
    execl("/usr/libexec/PlistBuddy", "PlistBuddy", "-c", "Print :CFBundleShortVersionString", plist_path, (char *)NULL);
    _exit(127);
  }

  close(pipefd[1]);
  size_t total = 0;
  while (total + 1 < buf_size) {
    ssize_t n = read(pipefd[0], buf + total, buf_size - 1 - total);
    if (n <= 0) {
      break;
    }
    total += (size_t)n;
  }
  buf[total] = '\0';
  close(pipefd[0]);

  int status = 0;
  if (waitpid(pid, &status, 0) < 0 || !WIFEXITED(status) || WEXITSTATUS(status) != 0) {
    buf[0] = '\0';
    return -1;
  }

  trim_newline(buf);
  return buf[0] ? 0 : -1;
}

static int should_show_startup_tip(int argc, char **argv) {
  if (getenv("AG_PROXY_LAUNCHED") ||
      getenv("AG_PROXY_LAUNCHER_DRY_RUN") ||
      getenv("AG_PROXY_NO_PROMPT") ||
      getenv("ELECTRON_RUN_AS_NODE")) {
    return 0;
  }

  for (int i = 1; i < argc; i++) {
    if (strncmp(argv[i], "--type=", 7) == 0 || strcmp(argv[i], "--type") == 0) {
      return 0;
    }
  }
  return 1;
}

static void spawn_startup_tip_async(void) {
  pid_t p1 = fork();
  if (p1 < 0) {
    return;
  }

  if (p1 == 0) {
    pid_t p2 = fork();
    if (p2 < 0) {
      _exit(1);
    }
    if (p2 > 0) {
      _exit(0);
    }

    setsid();
    unsetenv("DYLD_INSERT_LIBRARIES");
    int devnull = open("/dev/null", O_RDWR);
    if (devnull >= 0) {
      dup2(devnull, STDIN_FILENO);
      dup2(devnull, STDOUT_FILENO);
      dup2(devnull, STDERR_FILENO);
      if (devnull > STDERR_FILENO) {
        close(devnull);
      }
    }

    const char *ag_proxy = getenv("AG_PROXY");
    const char *built_ver = getenv("AG_SOURCE_VERSION");
    const char *app_lang = getenv("AG_APP_LANG");
    if (!app_lang || !app_lang[0]) {
      const char *sys_lang = getenv("LANG");
      if (sys_lang && (strncmp(sys_lang, "zh_TW", 5) == 0 || strncmp(sys_lang, "zh_HK", 5) == 0 ||
                       strncmp(sys_lang, "zh_MO", 5) == 0 || strncmp(sys_lang, "zh-Hant", 7) == 0)) {
        app_lang = "zh-Hant";
      } else if (sys_lang && strncmp(sys_lang, "zh", 2) == 0) {
        app_lang = "zh-Hans";
      } else if (sys_lang && strncmp(sys_lang, "ru", 2) == 0) {
        app_lang = "ru";
      } else {
        app_lang = "en";
      }
    }
    if (!ag_proxy || !ag_proxy[0]) {
      ag_proxy = "socks5://127.0.0.1:7890";
    }

    char current_ver[128];
    int has_current_ver = (read_source_app_version(current_ver, sizeof(current_ver)) == 0);
    int needs_refresh = (built_ver && built_ver[0] && has_current_ver && strcmp(built_ver, current_ver) != 0);

    if (!needs_refresh) {
      _exit(0);
    }

    char subtitle[512];
    char notify_msg[1024];
    char dialog_msg[2048];
    const char *ok_btn = "OK";

    int is_zh_hans = (strcmp(app_lang, "zh-Hans") == 0);
    int is_zh_hant = (strcmp(app_lang, "zh-Hant") == 0);
    int is_ru = (strcmp(app_lang, "ru") == 0);

    if (is_zh_hant) {
      ok_btn = "知道了";
      snprintf(subtitle, sizeof(subtitle), "偵測到原版 Antigravity 已更新（%s → %s）", built_ver, current_ver);
      snprintf(notify_msg, sizeof(notify_msg),
               "請開啟 Antigravity Pilot 重建代理副本以同步新版。");
      snprintf(dialog_msg, sizeof(dialog_msg),
               "偵測到原版 Antigravity 已更新（%s → %s）。\n\n"
               "請結束目前視窗後開啟 /Applications/Antigravity Pilot.app 重建代理副本以同步最新版本。\n"
               "（目前代理：%s）",
               built_ver, current_ver, ag_proxy);
    } else if (is_zh_hans) {
      ok_btn = "知道了";
      snprintf(subtitle, sizeof(subtitle), "检测到原版 Antigravity 已更新（%s → %s）", built_ver, current_ver);
      snprintf(notify_msg, sizeof(notify_msg),
               "请打开 Antigravity Pilot 重建代理副本以同步新版。");
      snprintf(dialog_msg, sizeof(dialog_msg),
               "检测到原版 Antigravity 已更新（%s → %s）。\n\n"
               "请退出当前窗口后打开 /Applications/Antigravity Pilot.app 重建代理副本以同步最新版本。\n"
               "（当前代理：%s）",
               built_ver, current_ver, ag_proxy);
    } else if (is_ru) {
      ok_btn = "Понятно";
      snprintf(subtitle, sizeof(subtitle), "Оригинальный Antigravity обновлён (%s → %s)", built_ver, current_ver);
      snprintf(notify_msg, sizeof(notify_msg),
               "Откройте Antigravity Pilot, чтобы пересобрать копию.");
      snprintf(dialog_msg, sizeof(dialog_msg),
               "Оригинальный Antigravity обновлён (%s → %s).\n\n"
               "Закройте это окно и откройте /Applications/Antigravity Pilot.app, чтобы пересобрать копию.\n"
               "(Текущий прокси: %s)",
               built_ver, current_ver, ag_proxy);
    } else {
      ok_btn = "OK";
      snprintf(subtitle, sizeof(subtitle), "Original Antigravity updated (%s → %s)", built_ver, current_ver);
      snprintf(notify_msg, sizeof(notify_msg),
               "Open Antigravity Pilot to rebuild the runtime copy.");
      snprintf(dialog_msg, sizeof(dialog_msg),
               "Original Antigravity has been updated (%s → %s).\n\n"
               "Quit this window and open /Applications/Antigravity Pilot.app to rebuild the runtime copy.\n"
               "(Current proxy: %s)",
               built_ver, current_ver, ag_proxy);
    }

    const char *script =
        "on run argv\n"
        "  set tipTitle to item 1 of argv\n"
        "  set tipSub to item 2 of argv\n"
        "  set tipNotify to item 3 of argv\n"
        "  set tipDialog to item 4 of argv\n"
        "  set okLabel to item 5 of argv\n"
        "  try\n"
        "    display notification tipNotify with title tipTitle subtitle tipSub\n"
        "  end try\n"
        "  try\n"
        "    display dialog tipDialog with title tipTitle buttons {okLabel} default button okLabel giving up after 4\n"
        "  end try\n"
        "end run\n";

    execl("/usr/bin/osascript", "osascript", "-e", script,
          "Antigravity Pilot", subtitle, notify_msg, dialog_msg, ok_btn, (char *)NULL);
    _exit(127);
  }

  (void)waitpid(p1, NULL, 0);
}

static int count_windows_for_pid(pid_t pid) {
  char command[512];
  snprintf(command, sizeof(command),
           "osascript -e 'tell application \"System Events\" to count windows of (first process whose unix id is %ld)' 2>/dev/null",
           (long)pid);

  FILE *fp = popen(command, "r");
  if (!fp) {
    return -1;
  }

  char output[64];
  if (!fgets(output, sizeof(output), fp)) {
    pclose(fp);
    return -1;
  }

  int status = pclose(fp);
  if (status != 0) {
    return -1;
  }

  return atoi(output);
}

static void terminate_child_group(pid_t pid) {
  if (pid <= 0) {
    return;
  }

  kill(-pid, SIGTERM);
  for (int i = 0; i < 20; i++) {
    if (waitpid(pid, NULL, WNOHANG) == pid) {
      return;
    }
    usleep(100000);
  }
  kill(-pid, SIGKILL);
  (void)waitpid(pid, NULL, 0);
}

static int run_nested_with_monitor(const char *real_executable, char **child_argv) {
  signal(SIGTERM, handle_signal);
  signal(SIGINT, handle_signal);
  signal(SIGHUP, handle_signal);

  pid_t pid = fork();
  if (pid < 0) {
    fprintf(stderr, "AntigravityProxyLauncher: fork failed: %s\n", strerror(errno));
    return 1;
  }

  if (pid == 0) {
    setpgid(0, 0);
    execv(real_executable, child_argv);
    fprintf(stderr, "AntigravityProxyLauncher: execv %s failed: %s\n", real_executable, strerror(errno));
    _exit(127);
  }

  child_pid = pid;
  setpgid(pid, pid);

  int saw_window = 0;
  int zero_window_ticks = 0;

  while (!stop_requested) {
    int status;
    pid_t done = waitpid(pid, &status, WNOHANG);
    if (done == pid) {
      return WIFEXITED(status) ? WEXITSTATUS(status) : 0;
    }
    if (done < 0 && errno != EINTR) {
      return 1;
    }

    int windows = count_windows_for_pid(pid);
    if (windows > 0) {
      saw_window = 1;
      zero_window_ticks = 0;
    } else if (windows == 0 && saw_window) {
      zero_window_ticks++;
      if (zero_window_ticks >= 3) {
        terminate_child_group(pid);
        return 0;
      }
    }

    sleep(2);
  }

  terminate_child_group(pid);
  return 0;
}

int main(int argc, char **argv) {
  char executable[PATH_MAX];
  uint32_t size = sizeof(executable);

  extern int _NSGetExecutablePath(char *buf, uint32_t *bufsize);
  if (_NSGetExecutablePath(executable, &size) != 0) {
    fprintf(stderr, "AntigravityProxyLauncher: executable path is too long\n");
    return 1;
  }

  char macos_dir[PATH_MAX];
  strncpy(macos_dir, executable, sizeof(macos_dir) - 1);
  macos_dir[sizeof(macos_dir) - 1] = '\0';
  if (dirname_inplace(macos_dir) != 0) {
    fprintf(stderr, "AntigravityProxyLauncher: cannot resolve MacOS directory\n");
    return 1;
  }

  char contents_dir[PATH_MAX];
  strncpy(contents_dir, macos_dir, sizeof(contents_dir) - 1);
  contents_dir[sizeof(contents_dir) - 1] = '\0';
  if (dirname_inplace(contents_dir) != 0) {
    fprintf(stderr, "AntigravityProxyLauncher: cannot resolve Contents directory\n");
    return 1;
  }

  char resources_dir[PATH_MAX];
  snprintf(resources_dir, sizeof(resources_dir), "%s/Resources", contents_dir);

  const char *ext_override = getenv("AG_PROXY_EXTERNAL_ENV_FILE");
  if (ext_override && ext_override[0]) {
    load_env_file(ext_override, 1);
  } else {
    const char *home_dir = getenv("HOME");
    if (home_dir && home_dir[0]) {
      char ext_env_file[PATH_MAX];
      snprintf(ext_env_file, sizeof(ext_env_file),
               "%s/Library/Application Support/Antigravity Pilot/proxy.env", home_dir);
      if (access(ext_env_file, R_OK) == 0) {
        load_env_file(ext_env_file, 1);
      } else {
        char legacy_env_file[PATH_MAX];
        snprintf(legacy_env_file, sizeof(legacy_env_file),
                 "%s/Library/Application Support/Antigravity Proxy/proxy.env", home_dir);
        load_env_file(legacy_env_file, 1);
      }
    }
  }

  char env_file[PATH_MAX];
  snprintf(env_file, sizeof(env_file), "%s/proxy.env", resources_dir);
  load_env_file(env_file, 0);

  char real_executable[PATH_MAX];
  char nested_executable[PATH_MAX];
  snprintf(nested_executable, sizeof(nested_executable), "%s/Antigravity.app/Contents/MacOS/Antigravity", resources_dir);
  int is_nested = (access(nested_executable, X_OK) == 0);
  if (is_nested) {
    snprintf(real_executable, sizeof(real_executable), "%s", nested_executable);
  } else {
    snprintf(real_executable, sizeof(real_executable), "%s/Antigravity", macos_dir);
  }

  char dylib[PATH_MAX];
  snprintf(dylib, sizeof(dylib), "%s/libantigravity_proxy.dylib", resources_dir);

  set_default_env("AG_PROXY", "socks5://127.0.0.1:7890");
  set_default_env("AG_PROXY_LOG", "0");
  set_default_env("AG_PROXY_TIMEOUT_MS", "15000");
  set_default_env("HTTP_PROXY", "http://127.0.0.1:7890");
  set_default_env("HTTPS_PROXY", "http://127.0.0.1:7890");
  set_default_env("ALL_PROXY", "http://127.0.0.1:7890");
  set_default_env("http_proxy", getenv("HTTP_PROXY"));
  set_default_env("https_proxy", getenv("HTTPS_PROXY"));
  set_default_env("all_proxy", getenv("ALL_PROXY"));
  set_default_env("NO_PROXY", "localhost,127.0.0.1,::1,127.0.0.0/8,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,*.local,<local>");
  set_default_env("no_proxy", getenv("NO_PROXY"));
  set_default_env("NODE_USE_ENV_PROXY", "1");

  int show_tip = should_show_startup_tip(argc, argv);
  int primary_chromium = is_primary_chromium_launch(argc, argv);
  setenv("AG_PROXY_LAUNCHED", "1", 1);

  if (show_tip) {
    spawn_startup_tip_async();
  }

  setenv("DYLD_INSERT_LIBRARIES", dylib, 1);

  char chromium_proxy[1024];
  build_chromium_proxy_url(chromium_proxy, sizeof(chromium_proxy));
  const char *no_proxy_val = getenv("NO_PROXY");
  int add_proxy_server = primary_chromium && chromium_proxy[0] && !has_arg_prefix(argc, argv, "--proxy-server");
  int add_bypass_list = primary_chromium && add_proxy_server && no_proxy_val && no_proxy_val[0] && !has_arg_prefix(argc, argv, "--proxy-bypass-list");

  char **child_argv = calloc((size_t)argc + 4, sizeof(char *));
  if (!child_argv) {
    fprintf(stderr, "AntigravityProxyLauncher: calloc failed\n");
    return 1;
  }

  int out_argc = 0;
  child_argv[out_argc++] = real_executable;
  for (int i = 1; i < argc; i++) {
    child_argv[out_argc++] = argv[i];
  }

  char proxy_server_flag[1100];
  char bypass_list_flag[4200];
  if (add_proxy_server) {
    snprintf(proxy_server_flag, sizeof(proxy_server_flag), "--proxy-server=%s", chromium_proxy);
    child_argv[out_argc++] = proxy_server_flag;
  }
  if (add_bypass_list) {
    snprintf(bypass_list_flag, sizeof(bypass_list_flag), "--proxy-bypass-list=%s", no_proxy_val);
    child_argv[out_argc++] = bypass_list_flag;
  }
  child_argv[out_argc] = NULL;

  if (getenv("AG_PROXY_LAUNCHER_DRY_RUN")) {
    fprintf(stderr, "real_executable=%s\n", real_executable);
    fprintf(stderr, "DYLD_INSERT_LIBRARIES=%s\n", getenv("DYLD_INSERT_LIBRARIES"));
    fprintf(stderr, "AG_PROXY=%s\n", getenv("AG_PROXY"));
    fprintf(stderr, "HTTPS_PROXY=%s\n", getenv("HTTPS_PROXY"));
    fprintf(stderr, "NO_PROXY=%s\n", no_proxy_val ? no_proxy_val : "");
    fprintf(stderr, "NODE_USE_ENV_PROXY=%s\n", getenv("NODE_USE_ENV_PROXY") ? getenv("NODE_USE_ENV_PROXY") : "");
    fprintf(stderr, "AG_SOURCE_VERSION=%s\n", getenv("AG_SOURCE_VERSION") ? getenv("AG_SOURCE_VERSION") : "");
    for (int i = 0; i < out_argc; i++) {
      fprintf(stderr, "argv[%d]=%s\n", i, child_argv[i]);
    }
    free(child_argv);
    return 0;
  }

  if (is_nested) {
    return run_nested_with_monitor(real_executable, child_argv);
  }

  execv(real_executable, child_argv);
  fprintf(stderr, "AntigravityProxyLauncher: execv %s failed: %s\n", real_executable, strerror(errno));
  return 127;
}
