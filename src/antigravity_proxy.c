#define _DARWIN_C_SOURCE

#include <arpa/inet.h>
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <sys/time.h>
#include <unistd.h>

#ifndef SO_NOSIGPIPE
#define SO_NOSIGPIPE 0x1022
#endif

#define FAKE_NET_START 0xC6120001u
#define FAKE_NET_END   0xC613FFFEu
#define MAX_MAPS 4096
#define MAX_HOST 255
#define MAX_BYPASS_RULES 64
#define DEFAULT_NO_PROXY_LIST "localhost,127.0.0.1,::1,127.0.0.0/8,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,*.local,<local>"

struct host_map {
  uint32_t ip_be;
  char host[MAX_HOST + 1];
};

struct cidr_rule {
  uint32_t net_host_order;
  uint32_t mask_host_order;
};

static pthread_once_t config_once = PTHREAD_ONCE_INIT;
static pthread_mutex_t map_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t owned_ai_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t serv_lock = PTHREAD_MUTEX_INITIALIZER;
static int log_enabled;
static int timeout_ms = 15000;
static char proxy_host[MAX_HOST + 1] = "127.0.0.1";
static int proxy_port = 7890;
static uint32_t next_fake_host_order = FAKE_NET_START;
static struct host_map maps[MAX_MAPS];
static size_t map_count;
static size_t map_next;

static struct addrinfo **owned_ai_ptrs = NULL;
static size_t owned_ai_count = 0;
static size_t owned_ai_cap = 0;
static _Thread_local int in_getaddrinfo_bypass = 0;

static int proxy_addr_family = AF_UNSPEC;
static struct in_addr proxy_addr_v4;
static struct in6_addr proxy_addr_v6;

static struct cidr_rule cidr_rules[MAX_BYPASS_RULES];
static size_t cidr_rule_count;
static char bypass_domains[MAX_BYPASS_RULES][MAX_HOST + 1];
static size_t bypass_domain_count;
static struct in6_addr bypass_ips_v6[MAX_BYPASS_RULES];
static size_t bypass_ip_v6_count;
static int bypass_local_unqualified;
static int bypass_all;

#define MAX_BYPASS_IPS 256
static uint32_t bypass_resolved_v4[MAX_BYPASS_IPS];
static size_t bypass_resolved_v4_count;
static size_t bypass_resolved_v4_next;
static struct in6_addr bypass_resolved_v6[MAX_BYPASS_IPS];
static size_t bypass_resolved_v6_count;
static size_t bypass_resolved_v6_next;
static pthread_mutex_t bypass_ip_lock = PTHREAD_MUTEX_INITIALIZER;

static void record_bypass_addrinfo(const struct addrinfo *res) {
  pthread_mutex_lock(&bypass_ip_lock);
  for (const struct addrinfo *cur = res; cur != NULL; cur = cur->ai_next) {
    if (cur->ai_family == AF_INET && cur->ai_addr && cur->ai_addrlen >= sizeof(struct sockaddr_in)) {
      uint32_t ip_be = ((const struct sockaddr_in *)cur->ai_addr)->sin_addr.s_addr;
      int exists = 0;
      for (size_t i = 0; i < bypass_resolved_v4_count; i++) {
        if (bypass_resolved_v4[i] == ip_be) {
          exists = 1;
          break;
        }
      }
      if (!exists) {
        bypass_resolved_v4[bypass_resolved_v4_next] = ip_be;
        bypass_resolved_v4_next = (bypass_resolved_v4_next + 1) % MAX_BYPASS_IPS;
        if (bypass_resolved_v4_count < MAX_BYPASS_IPS) {
          bypass_resolved_v4_count++;
        }
      }
    } else if (cur->ai_family == AF_INET6 && cur->ai_addr && cur->ai_addrlen >= sizeof(struct sockaddr_in6)) {
      const struct in6_addr *ip6 = &((const struct sockaddr_in6 *)cur->ai_addr)->sin6_addr;
      int exists = 0;
      for (size_t i = 0; i < bypass_resolved_v6_count; i++) {
        if (memcmp(&bypass_resolved_v6[i], ip6, sizeof(*ip6)) == 0) {
          exists = 1;
          break;
        }
      }
      if (!exists) {
        bypass_resolved_v6[bypass_resolved_v6_next] = *ip6;
        bypass_resolved_v6_next = (bypass_resolved_v6_next + 1) % MAX_BYPASS_IPS;
        if (bypass_resolved_v6_count < MAX_BYPASS_IPS) {
          bypass_resolved_v6_count++;
        }
      }
    }
  }
  pthread_mutex_unlock(&bypass_ip_lock);
}

static int is_recorded_bypass_v4(uint32_t ip_be) {
  int found = 0;
  pthread_mutex_lock(&bypass_ip_lock);
  for (size_t i = 0; i < bypass_resolved_v4_count; i++) {
    if (bypass_resolved_v4[i] == ip_be) {
      found = 1;
      break;
    }
  }
  pthread_mutex_unlock(&bypass_ip_lock);
  return found;
}

static int is_recorded_bypass_v6(const struct in6_addr *ip6) {
  int found = 0;
  pthread_mutex_lock(&bypass_ip_lock);
  for (size_t i = 0; i < bypass_resolved_v6_count; i++) {
    if (memcmp(&bypass_resolved_v6[i], ip6, sizeof(*ip6)) == 0) {
      found = 1;
      break;
    }
  }
  pthread_mutex_unlock(&bypass_ip_lock);
  return found;
}

struct interpose_entry {
  const void *replacement;
  const void *replacee;
};

static void log_msg(const char *fmt, ...) {
  if (!log_enabled) {
    return;
  }

  va_list ap;
  va_start(ap, fmt);
  fprintf(stderr, "[ag-proxy] ");
  vfprintf(stderr, fmt, ap);
  fprintf(stderr, "\n");
  va_end(ap);
}

static int register_owned_addrinfo(struct addrinfo *ai) {
  if (!ai) {
    return 0;
  }
  int ok = 0;
  pthread_mutex_lock(&owned_ai_lock);
  if (owned_ai_count == owned_ai_cap) {
    size_t new_cap = owned_ai_cap == 0 ? 256 : owned_ai_cap * 2;
    struct addrinfo **grown = realloc(owned_ai_ptrs, new_cap * sizeof(*owned_ai_ptrs));
    if (grown) {
      owned_ai_ptrs = grown;
      owned_ai_cap = new_cap;
    }
  }
  if (owned_ai_count < owned_ai_cap) {
    owned_ai_ptrs[owned_ai_count++] = ai;
    ok = 1;
  }
  pthread_mutex_unlock(&owned_ai_lock);
  return ok;
}

static int unregister_owned_addrinfo(struct addrinfo *ai) {
  if (!ai) {
    return 0;
  }
  int found = 0;
  pthread_mutex_lock(&owned_ai_lock);
  for (size_t i = 0; i < owned_ai_count; i++) {
    if (owned_ai_ptrs[i] == ai) {
      owned_ai_ptrs[i] = owned_ai_ptrs[owned_ai_count - 1];
      owned_ai_count--;
      found = 1;
      break;
    }
  }
  pthread_mutex_unlock(&owned_ai_lock);
  return found;
}

static void str_tolower_copy(char *dst, size_t dst_size, const char *src) {
  size_t i = 0;
  while (src[i] && i + 1 < dst_size) {
    dst[i] = (char)tolower((unsigned char)src[i]);
    i++;
  }
  dst[i] = '\0';
}

static int parse_ipv4_host_order(const char *ip_str, uint32_t *out_host_order) {
  struct in_addr a4;
  if (!ip_str || inet_pton(AF_INET, ip_str, &a4) != 1) {
    return 0;
  }
  *out_host_order = ntohl(a4.s_addr);
  return 1;
}

static void parse_no_proxy_list(const char *raw) {
  cidr_rule_count = 0;
  bypass_domain_count = 0;
  bypass_ip_v6_count = 0;
  bypass_local_unqualified = 0;
  bypass_all = 0;

  if (!raw || !raw[0]) {
    return;
  }

  char *copy = strdup(raw);
  if (!copy) {
    return;
  }

  char *saveptr = NULL;
  for (char *tok = strtok_r(copy, ",; \t\r\n", &saveptr); tok != NULL;
       tok = strtok_r(NULL, ",; \t\r\n", &saveptr)) {
    char lower[MAX_HOST + 32];
    str_tolower_copy(lower, sizeof(lower), tok);
    if (!lower[0]) {
      continue;
    }
    if (!strcmp(lower, "*")) {
      bypass_all = 1;
      continue;
    }
    if (!strcmp(lower, "<local>") || !strcmp(lower, "<-loopback>")) {
      bypass_local_unqualified = 1;
      continue;
    }

    char *slash = strchr(lower, '/');
    if (slash) {
      *slash = '\0';
      char *end = NULL;
      long prefix = strtol(slash + 1, &end, 10);
      uint32_t net_ip = 0;
      if (end && *end == '\0' && prefix >= 0 && prefix <= 32 &&
          parse_ipv4_host_order(lower, &net_ip)) {
        if (cidr_rule_count < MAX_BYPASS_RULES) {
          uint32_t mask = prefix == 0 ? 0u : (0xFFFFFFFFu << (32 - (unsigned)prefix));
          cidr_rules[cidr_rule_count].net_host_order = net_ip & mask;
          cidr_rules[cidr_rule_count].mask_host_order = mask;
          cidr_rule_count++;
        }
      }
      continue;
    }

    char *pattern = lower;
    if (pattern[0] == '[') {
      char *close_br = strchr(pattern, ']');
      if (close_br) {
        *close_br = '\0';
        pattern++;
      }
    } else {
      char *first_colon = strchr(pattern, ':');
      char *last_colon = strrchr(pattern, ':');
      if (first_colon && first_colon == last_colon &&
          first_colon > pattern && isdigit((unsigned char)first_colon[1])) {
        *first_colon = '\0';
      }
    }

    struct in6_addr single_ip6;
    if (inet_pton(AF_INET6, pattern, &single_ip6) == 1) {
      if (bypass_ip_v6_count < MAX_BYPASS_RULES) {
        bypass_ips_v6[bypass_ip_v6_count++] = single_ip6;
      }
      continue;
    }

    if (pattern[0] == '*' && pattern[1] == '.') {
      pattern += 1;
    }
    if (pattern[0] == '.' && pattern[1] != '\0') {
      pattern += 1;
    }

    uint32_t single_ip = 0;
    if (parse_ipv4_host_order(pattern, &single_ip)) {
      if (cidr_rule_count < MAX_BYPASS_RULES) {
        cidr_rules[cidr_rule_count].net_host_order = single_ip;
        cidr_rules[cidr_rule_count].mask_host_order = 0xFFFFFFFFu;
        cidr_rule_count++;
      }
      continue;
    }

    if (pattern[0] && bypass_domain_count < MAX_BYPASS_RULES) {
      snprintf(bypass_domains[bypass_domain_count], MAX_HOST + 1, "%s", pattern);
      bypass_domain_count++;
    }
  }

  free(copy);
}

static int ip_matches_no_proxy_cidr(uint32_t ip_host_order) {
  for (size_t i = 0; i < cidr_rule_count; i++) {
    if ((ip_host_order & cidr_rules[i].mask_host_order) == cidr_rules[i].net_host_order) {
      return 1;
    }
  }
  return 0;
}

static int ip6_matches_no_proxy(const struct in6_addr *ip6) {
  static const struct in6_addr loopback = IN6ADDR_LOOPBACK_INIT;
  if (memcmp(ip6, &loopback, sizeof(loopback)) == 0) {
    return 1;
  }
  /* Link-local fe80::/10 and Unique Local fc00::/7 */
  if ((ip6->s6_addr[0] == 0xfe && (ip6->s6_addr[1] & 0xc0) == 0x80) ||
      (ip6->s6_addr[0] & 0xfe) == 0xfc) {
    return 1;
  }
  for (size_t i = 0; i < bypass_ip_v6_count; i++) {
    if (memcmp(&bypass_ips_v6[i], ip6, sizeof(*ip6)) == 0) {
      return 1;
    }
  }
  return 0;
}

static int host_matches_no_proxy(const char *host) {
  if (!host || !host[0]) {
    return 0;
  }
  if (bypass_all) {
    return 1;
  }

  char lower[MAX_HOST + 1];
  str_tolower_copy(lower, sizeof(lower), host);
  size_t host_len = strlen(lower);
  while (host_len > 0 && lower[host_len - 1] == '.') {
    lower[--host_len] = '\0';
  }
  if (!host_len) {
    return 0;
  }

  uint32_t ip_ho = 0;
  if (parse_ipv4_host_order(lower, &ip_ho)) {
    if ((ip_ho & 0xFFFF0000u) == 0xA9FE0000u) {
      return 1;
    }
    return ip_matches_no_proxy_cidr(ip_ho);
  }

  struct in6_addr ip6;
  if (inet_pton(AF_INET6, lower, &ip6) == 1) {
    return ip6_matches_no_proxy(&ip6);
  }

  if (bypass_local_unqualified && !strchr(lower, '.') && !strchr(lower, ':')) {
    return 1;
  }

  for (size_t i = 0; i < bypass_domain_count; i++) {
    const char *pat = bypass_domains[i];
    size_t pat_len = strlen(pat);
    if (!strcmp(lower, pat)) {
      return 1;
    }
    if (host_len > pat_len &&
        lower[host_len - pat_len - 1] == '.' &&
        !strcmp(lower + host_len - pat_len, pat)) {
      return 1;
    }
  }
  return 0;
}

static int direct_connect(int fd, const struct sockaddr *addr, socklen_t len) {
  return (int)syscall(SYS_connect, fd, addr, len);
}

static void parse_proxy_url(const char *value) {
  const char *p = value;
  const char *scheme = strstr(p, "://");
  if (scheme) {
    p = scheme + 3;
  }

  const char *at = strrchr(p, '@');
  if (at) {
    p = at + 1;
  }

  char host_port[512];
  size_t len = strcspn(p, "/");
  if (len >= sizeof(host_port)) {
    len = sizeof(host_port) - 1;
  }
  memcpy(host_port, p, len);
  host_port[len] = '\0';

  char *host_part = host_port;
  char *port_str = NULL;
  if (host_part[0] == '[') {
    char *close_br = strchr(host_part, ']');
    if (!close_br || close_br[1] != ':' || !close_br[2]) {
      return;
    }
    *close_br = '\0';
    host_part++;
    port_str = close_br + 2;
  } else {
    char *colon = strrchr(host_part, ':');
    if (!colon || !colon[1]) {
      return;
    }
    *colon = '\0';
    port_str = colon + 1;
  }

  char *end = NULL;
  long port = strtol(port_str, &end, 10);
  if (!end || *end != '\0' || port <= 0 || port > 65535 || host_part[0] == '\0') {
    return;
  }

  if (strcasecmp(host_part, "localhost") == 0) {
    snprintf(proxy_host, sizeof(proxy_host), "127.0.0.1");
  } else {
    snprintf(proxy_host, sizeof(proxy_host), "%s", host_part);
  }
  proxy_port = (int)port;
}

static void load_config_impl(void) {
  const char *proxy = getenv("AG_PROXY");
  if (!proxy || !proxy[0]) {
    proxy = getenv("ALL_PROXY");
  }
  if (!proxy || !proxy[0]) {
    proxy = getenv("all_proxy");
  }
  if (proxy && proxy[0]) {
    parse_proxy_url(proxy);
  }

  if (inet_pton(AF_INET, proxy_host, &proxy_addr_v4) == 1) {
    proxy_addr_family = AF_INET;
  } else if (inet_pton(AF_INET6, proxy_host, &proxy_addr_v6) == 1) {
    proxy_addr_family = AF_INET6;
  } else {
    proxy_addr_family = AF_UNSPEC;
  }

  const char *no_proxy = getenv("NO_PROXY");
  if (!no_proxy) {
    no_proxy = getenv("no_proxy");
  }
  if (!no_proxy) {
    no_proxy = DEFAULT_NO_PROXY_LIST;
  }
  parse_no_proxy_list(no_proxy);

  const char *log = getenv("AG_PROXY_LOG");
  log_enabled = log && (!strcmp(log, "1") || !strcasecmp(log, "true"));

  const char *timeout = getenv("AG_PROXY_TIMEOUT_MS");
  if (timeout && timeout[0]) {
    int parsed = atoi(timeout);
    if (parsed >= 1000 && parsed <= 120000) {
      timeout_ms = parsed;
    }
  }

  log_msg("loaded proxy %s:%d (cidr=%zu domains=%zu v6=%zu)", proxy_host, proxy_port, cidr_rule_count, bypass_domain_count, bypass_ip_v6_count);
}

static void load_config(void) {
  pthread_once(&config_once, load_config_impl);
}

static int is_localhost_name(const char *host) {
  if (!host) {
    return 0;
  }
  return !strcasecmp(host, "localhost") || !strcmp(host, "127.0.0.1") || !strcmp(host, "::1");
}

static int is_numeric_host(const char *host) {
  struct in_addr a4;
  struct in6_addr a6;
  return inet_pton(AF_INET, host, &a4) == 1 || inet_pton(AF_INET6, host, &a6) == 1;
}

static int is_scoped_ipv6_host(const char *host) {
  if (!host) {
    return 0;
  }
  const char *pct = strchr(host, '%');
  if (!pct || pct == host) {
    return 0;
  }
  size_t prefix_len = (size_t)(pct - host);
  if (prefix_len >= INET6_ADDRSTRLEN) {
    return 0;
  }
  char prefix[INET6_ADDRSTRLEN];
  memcpy(prefix, host, prefix_len);
  prefix[prefix_len] = '\0';
  struct in6_addr a6;
  return inet_pton(AF_INET6, prefix, &a6) == 1;
}

static int is_fake_ip_be(uint32_t ip_be) {
  uint32_t ip = ntohl(ip_be);
  return ip >= FAKE_NET_START && ip <= FAKE_NET_END;
}

static int lookup_host_by_ip(uint32_t ip_be, char *out_host, size_t out_size) {
  int found = 0;
  pthread_mutex_lock(&map_lock);
  for (size_t i = 0; i < map_count; i++) {
    if (maps[i].ip_be == ip_be) {
      snprintf(out_host, out_size, "%s", maps[i].host);
      found = 1;
      break;
    }
  }
  pthread_mutex_unlock(&map_lock);
  return found;
}

static uint32_t fake_ip_for_host(const char *host) {
  uint32_t result = 0;

  pthread_mutex_lock(&map_lock);
  for (size_t i = 0; i < map_count; i++) {
    if (!strcasecmp(maps[i].host, host)) {
      result = maps[i].ip_be;
      break;
    }
  }

  if (!result) {
    if (next_fake_host_order > FAKE_NET_END) {
      next_fake_host_order = FAKE_NET_START;
    }
    size_t slot;
    if (map_count < MAX_MAPS) {
      slot = map_count++;
    } else {
      slot = map_next;
      map_next = (map_next + 1) % MAX_MAPS;
    }
    result = htonl(next_fake_host_order++);
    maps[slot].ip_be = result;
    str_tolower_copy(maps[slot].host, sizeof(maps[slot].host), host);
  }
  pthread_mutex_unlock(&map_lock);

  return result;
}

static int parse_service_port(const char *service) {
  if (!service || !service[0]) {
    return 0;
  }
  char *end = NULL;
  long value = strtol(service, &end, 10);
  if (end && *end == '\0' && value >= 0 && value <= 65535) {
    return (int)value;
  }
  if (!strcmp(service, "http")) {
    return 80;
  }
  if (!strcmp(service, "https")) {
    return 443;
  }
  int resolved = 0;
  pthread_mutex_lock(&serv_lock);
  struct servent *se = getservbyname(service, "tcp");
  if (se) {
    resolved = ntohs((uint16_t)se->s_port);
  }
  pthread_mutex_unlock(&serv_lock);
  return resolved;
}

static int make_addrinfo_v4(const char *canon, uint32_t ip_be, int port, const struct addrinfo *hints, struct addrinfo **res) {
  struct addrinfo *ai = calloc(1, sizeof(*ai));
  struct sockaddr_in *sa = calloc(1, sizeof(*sa));
  if (!ai || !sa) {
    free(ai);
    free(sa);
    return EAI_MEMORY;
  }

  sa->sin_family = AF_INET;
  sa->sin_port = htons((uint16_t)port);
  sa->sin_addr.s_addr = ip_be;

  ai->ai_family = AF_INET;
  ai->ai_socktype = hints ? hints->ai_socktype : 0;
  ai->ai_protocol = hints ? hints->ai_protocol : 0;
  ai->ai_addrlen = sizeof(*sa);
  ai->ai_addr = (struct sockaddr *)sa;

  if (canon && hints && (hints->ai_flags & AI_CANONNAME)) {
    ai->ai_canonname = strdup(canon);
    if (!ai->ai_canonname) {
      free(sa);
      free(ai);
      return EAI_MEMORY;
    }
  }

  if (!register_owned_addrinfo(ai)) {
    free(ai->ai_canonname);
    free(sa);
    free(ai);
    return EAI_MEMORY;
  }
  *res = ai;
  return 0;
}

static int make_fake_addrinfo(const char *node, const char *service, const struct addrinfo *hints, struct addrinfo **res) {
  if (hints && hints->ai_family == AF_INET6) {
    return EAI_NONAME;
  }

  uint32_t ip_be = fake_ip_for_host(node);
  if (!ip_be) {
    return EAI_MEMORY;
  }

  int rc = make_addrinfo_v4(node, ip_be, parse_service_port(service), hints, res);
  if (rc != 0) {
    return rc;
  }

  struct in_addr fake;
  fake.s_addr = ip_be;
  char fake_str[INET_ADDRSTRLEN];
  if (inet_ntop(AF_INET, &fake, fake_str, sizeof(fake_str))) {
    log_msg("dns %s -> %s", node, fake_str);
  }
  return 0;
}

static int set_blocking(int fd, int *old_flags) {
  *old_flags = fcntl(fd, F_GETFL, 0);
  if (*old_flags < 0) {
    return -1;
  }
  if ((*old_flags & O_NONBLOCK) == 0) {
    return 0;
  }
  return fcntl(fd, F_SETFL, *old_flags & ~O_NONBLOCK);
}

static void restore_flags(int fd, int old_flags) {
  if (old_flags >= 0) {
    (void)fcntl(fd, F_SETFL, old_flags);
  }
}

static void set_socket_timeout(int fd) {
  struct timeval tv;
  tv.tv_sec = timeout_ms / 1000;
  tv.tv_usec = (timeout_ms % 1000) * 1000;
  (void)setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
  (void)setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
  int yes = 1;
  (void)setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
}

static ssize_t send_all(int fd, const void *buf, size_t len) {
  const uint8_t *p = (const uint8_t *)buf;
  size_t sent = 0;
  while (sent < len) {
    ssize_t n = send(fd, p + sent, len - sent, 0);
    if (n < 0) {
      if (errno == EINTR) {
        continue;
      }
      return -1;
    }
    if (n == 0) {
      errno = ECONNRESET;
      return -1;
    }
    sent += (size_t)n;
  }
  return (ssize_t)sent;
}

static ssize_t recv_all(int fd, void *buf, size_t len) {
  uint8_t *p = (uint8_t *)buf;
  size_t got = 0;
  while (got < len) {
    ssize_t n = recv(fd, p + got, len - got, 0);
    if (n < 0) {
      if (errno == EINTR) {
        continue;
      }
      return -1;
    }
    if (n == 0) {
      errno = ECONNRESET;
      return -1;
    }
    got += (size_t)n;
  }
  return (ssize_t)got;
}

static int connect_to_proxy(int fd) {
  struct sockaddr_storage storage;
  memset(&storage, 0, sizeof(storage));

  socklen_t len;
  struct sockaddr_in *sin = (struct sockaddr_in *)&storage;
  struct sockaddr_in6 *sin6 = (struct sockaddr_in6 *)&storage;

  if (inet_pton(AF_INET, proxy_host, &sin->sin_addr) == 1) {
    sin->sin_family = AF_INET;
    sin->sin_port = htons((uint16_t)proxy_port);
    len = sizeof(*sin);
  } else if (inet_pton(AF_INET6, proxy_host, &sin6->sin6_addr) == 1) {
    sin6->sin6_family = AF_INET6;
    sin6->sin6_port = htons((uint16_t)proxy_port);
    len = sizeof(*sin6);
  } else {
    log_msg("proxy host must be a numeric IP address: %s", proxy_host);
    errno = EINVAL;
    return -1;
  }

  log_msg("connecting to proxy %s:%d", proxy_host, proxy_port);
  if (direct_connect(fd, (struct sockaddr *)&storage, len) == 0) {
    log_msg("connected to proxy");
    return 0;
  }
  return -1;
}

static int socks5_read_reply_tail(int fd, uint8_t atyp) {
  uint8_t skip[258];
  size_t len;

  if (atyp == 0x01) {
    len = 4 + 2;
  } else if (atyp == 0x04) {
    len = 16 + 2;
  } else if (atyp == 0x03) {
    uint8_t name_len;
    if (recv_all(fd, &name_len, 1) != 1) {
      return -1;
    }
    len = (size_t)name_len + 2;
  } else {
    errno = EPROTO;
    return -1;
  }

  return recv_all(fd, skip, len) == (ssize_t)len ? 0 : -1;
}

static int socks5_connect_domain(int fd, const char *host, uint16_t port) {
  size_t host_len = strlen(host);
  if (host_len == 0 || host_len > 255) {
    errno = EINVAL;
    return -1;
  }

  uint8_t hello[] = {0x05, 0x01, 0x00};
  uint8_t hello_reply[2];
  if (send_all(fd, hello, sizeof(hello)) != (ssize_t)sizeof(hello) ||
      recv_all(fd, hello_reply, sizeof(hello_reply)) != (ssize_t)sizeof(hello_reply)) {
    return -1;
  }
  if (hello_reply[0] != 0x05 || hello_reply[1] != 0x00) {
    errno = ECONNREFUSED;
    return -1;
  }

  uint8_t req[4 + 1 + 255 + 2];
  size_t pos = 0;
  req[pos++] = 0x05;
  req[pos++] = 0x01;
  req[pos++] = 0x00;
  req[pos++] = 0x03;
  req[pos++] = (uint8_t)host_len;
  memcpy(req + pos, host, host_len);
  pos += host_len;
  req[pos++] = (uint8_t)(port >> 8);
  req[pos++] = (uint8_t)(port & 0xff);

  uint8_t reply[4];
  if (send_all(fd, req, pos) != (ssize_t)pos || recv_all(fd, reply, sizeof(reply)) != (ssize_t)sizeof(reply)) {
    return -1;
  }
  if (reply[0] != 0x05 || reply[1] != 0x00) {
    errno = ECONNREFUSED;
    return -1;
  }

  return socks5_read_reply_tail(fd, reply[3]);
}

static int socks5_connect_ip(int fd, const struct sockaddr *addr) {
  uint16_t port;
  uint8_t req[4 + 16 + 2];
  size_t pos = 0;

  req[pos++] = 0x05;
  req[pos++] = 0x01;
  req[pos++] = 0x00;

  if (addr->sa_family == AF_INET) {
    const struct sockaddr_in *sin = (const struct sockaddr_in *)addr;
    port = ntohs(sin->sin_port);
    req[pos++] = 0x01;
    memcpy(req + pos, &sin->sin_addr, 4);
    pos += 4;
  } else if (addr->sa_family == AF_INET6) {
    const struct sockaddr_in6 *sin6 = (const struct sockaddr_in6 *)addr;
    port = ntohs(sin6->sin6_port);
    req[pos++] = 0x04;
    memcpy(req + pos, &sin6->sin6_addr, 16);
    pos += 16;
  } else {
    errno = EAFNOSUPPORT;
    return -1;
  }

  uint8_t hello[] = {0x05, 0x01, 0x00};
  uint8_t hello_reply[2];
  if (send_all(fd, hello, sizeof(hello)) != (ssize_t)sizeof(hello) ||
      recv_all(fd, hello_reply, sizeof(hello_reply)) != (ssize_t)sizeof(hello_reply)) {
    return -1;
  }
  if (hello_reply[0] != 0x05 || hello_reply[1] != 0x00) {
    errno = ECONNREFUSED;
    return -1;
  }

  req[pos++] = (uint8_t)(port >> 8);
  req[pos++] = (uint8_t)(port & 0xff);

  uint8_t reply[4];
  if (send_all(fd, req, pos) != (ssize_t)pos || recv_all(fd, reply, sizeof(reply)) != (ssize_t)sizeof(reply)) {
    return -1;
  }
  if (reply[0] != 0x05 || reply[1] != 0x00) {
    errno = ECONNREFUSED;
    return -1;
  }

  return socks5_read_reply_tail(fd, reply[3]);
}

static int target_is_proxy(const struct sockaddr *addr) {
  if (addr->sa_family == AF_INET) {
    const struct sockaddr_in *sin = (const struct sockaddr_in *)addr;
    if (ntohs(sin->sin_port) != proxy_port) {
      return 0;
    }
    if (proxy_addr_family == AF_INET && sin->sin_addr.s_addr == proxy_addr_v4.s_addr) {
      return 1;
    }
    uint32_t ip = ntohl(sin->sin_addr.s_addr);
    return proxy_addr_family == AF_UNSPEC && ip == 0x7F000001u;
  }
  if (addr->sa_family == AF_INET6) {
    const struct sockaddr_in6 *sin6 = (const struct sockaddr_in6 *)addr;
    if (ntohs(sin6->sin6_port) != proxy_port) {
      return 0;
    }
    if (proxy_addr_family == AF_INET6 && memcmp(&sin6->sin6_addr, &proxy_addr_v6, sizeof(proxy_addr_v6)) == 0) {
      return 1;
    }
    static const struct in6_addr loopback = IN6ADDR_LOOPBACK_INIT;
    return !memcmp(&sin6->sin6_addr, &loopback, sizeof(loopback));
  }
  return 0;
}

static int target_is_loopback(const struct sockaddr *addr) {
  if (addr->sa_family == AF_INET) {
    const struct sockaddr_in *sin = (const struct sockaddr_in *)addr;
    uint32_t ip = ntohl(sin->sin_addr.s_addr);
    return (ip & 0xFF000000u) == 0x7F000000u;
  }
  if (addr->sa_family == AF_INET6) {
    const struct sockaddr_in6 *sin6 = (const struct sockaddr_in6 *)addr;
    static const struct in6_addr loopback = IN6ADDR_LOOPBACK_INIT;
    return !memcmp(&sin6->sin6_addr, &loopback, sizeof(loopback));
  }
  return 0;
}

static int target_is_bypass_ip(const struct sockaddr *addr) {
  if (addr->sa_family == AF_INET) {
    const struct sockaddr_in *sin = (const struct sockaddr_in *)addr;
    if (is_fake_ip_be(sin->sin_addr.s_addr)) {
      return 0;
    }
    if (bypass_all) {
      return 1;
    }
    if (is_recorded_bypass_v4(sin->sin_addr.s_addr)) {
      return 1;
    }
    uint32_t ip = ntohl(sin->sin_addr.s_addr);
    if ((ip & 0xFFFF0000u) == 0xA9FE0000u) {
      return 1;
    }
    return ip_matches_no_proxy_cidr(ip);
  }
  if (addr->sa_family == AF_INET6) {
    if (bypass_all) {
      return 1;
    }
    const struct sockaddr_in6 *sin6 = (const struct sockaddr_in6 *)addr;
    if (is_recorded_bypass_v6(&sin6->sin6_addr)) {
      return 1;
    }
    return ip6_matches_no_proxy(&sin6->sin6_addr);
  }
  return 0;
}

static int socket_is_stream(int fd) {
  int type = 0;
  socklen_t len = sizeof(type);
  if (getsockopt(fd, SOL_SOCKET, SO_TYPE, &type, &len) != 0) {
    return 0;
  }
  return type == SOCK_STREAM;
}

static void save_socket_timeouts(int fd, struct timeval *old_rcv, int *has_rcv, struct timeval *old_snd, int *has_snd) {
  socklen_t len = sizeof(*old_rcv);
  *has_rcv = (getsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, old_rcv, &len) == 0 && len == sizeof(*old_rcv));
  len = sizeof(*old_snd);
  *has_snd = (getsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, old_snd, &len) == 0 && len == sizeof(*old_snd));
}

static void restore_socket_timeouts(int fd, const struct timeval *old_rcv, int has_rcv, const struct timeval *old_snd, int has_snd) {
  if (has_rcv) {
    (void)setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, old_rcv, sizeof(*old_rcv));
  }
  if (has_snd) {
    (void)setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, old_snd, sizeof(*old_snd));
  }
}

static int proxy_connect(int fd, const struct sockaddr *addr) {
  int old_flags = -1;
  int saved_errno;
  uint16_t port = 0;
  char fake_host_buf[MAX_HOST + 1];
  int has_fake_host = 0;
  struct timeval old_rcv, old_snd;
  int has_old_rcv = 0, has_old_snd = 0;

  if (!socket_is_stream(fd)) {
    errno = EPROTOTYPE;
    return -1;
  }

  log_msg("connect hook fd=%d family=%d", fd, addr->sa_family);

  if (set_blocking(fd, &old_flags) != 0) {
    return -1;
  }
  save_socket_timeouts(fd, &old_rcv, &has_old_rcv, &old_snd, &has_old_snd);
  set_socket_timeout(fd);

  if (connect_to_proxy(fd) != 0) {
    saved_errno = errno;
    restore_socket_timeouts(fd, &old_rcv, has_old_rcv, &old_snd, has_old_snd);
    restore_flags(fd, old_flags);
    errno = saved_errno;
    return -1;
  }

  if (addr->sa_family == AF_INET) {
    const struct sockaddr_in *sin = (const struct sockaddr_in *)addr;
    port = ntohs(sin->sin_port);
    if (is_fake_ip_be(sin->sin_addr.s_addr)) {
      has_fake_host = lookup_host_by_ip(sin->sin_addr.s_addr, fake_host_buf, sizeof(fake_host_buf));
    }
  }

  int rc;
  if (has_fake_host) {
    log_msg("connect %s:%u via %s:%d", fake_host_buf, port, proxy_host, proxy_port);
    rc = socks5_connect_domain(fd, fake_host_buf, port);
  } else {
    log_msg("connect ip via %s:%d", proxy_host, proxy_port);
    rc = socks5_connect_ip(fd, addr);
  }

  saved_errno = errno;
  restore_socket_timeouts(fd, &old_rcv, has_old_rcv, &old_snd, has_old_snd);
  restore_flags(fd, old_flags);
  errno = saved_errno;
  return rc;
}

static int ag_connect(int fd, const struct sockaddr *addr, socklen_t len) {
  load_config();

  if (!addr || (addr->sa_family != AF_INET && addr->sa_family != AF_INET6) ||
      target_is_proxy(addr) || target_is_loopback(addr) || target_is_bypass_ip(addr)) {
    return direct_connect(fd, addr, len);
  }
  if (!socket_is_stream(fd)) {
    return direct_connect(fd, addr, len);
  }

  int rc = proxy_connect(fd, addr);
  if (rc == 0) {
    return 0;
  }

  log_msg("proxy connect failed: %s", strerror(errno));
  return rc;
}

static int ag_getaddrinfo(const char *node, const char *service, const struct addrinfo *hints, struct addrinfo **res) {
  if (in_getaddrinfo_bypass) {
    return getaddrinfo(node, service, hints, res);
  }

  load_config();

  if (!res) {
    return EAI_FAIL;
  }
  *res = NULL;

  if (!node || !node[0] || is_localhost_name(node) || is_numeric_host(node) || is_scoped_ipv6_host(node)) {
    in_getaddrinfo_bypass = 1;
    int rc = getaddrinfo(node, service, hints, res);
    in_getaddrinfo_bypass = 0;
    return rc;
  }
  if (!strcasecmp(node, proxy_host)) {
    in_getaddrinfo_bypass = 1;
    int rc = getaddrinfo(node, service, hints, res);
    in_getaddrinfo_bypass = 0;
    if (rc == 0 && *res && !is_numeric_host(node)) {
      record_bypass_addrinfo(*res);
    }
    return rc;
  }
  if (host_matches_no_proxy(node)) {
    log_msg("dns bypass %s via system resolver", node);
    in_getaddrinfo_bypass = 1;
    int rc = getaddrinfo(node, service, hints, res);
    in_getaddrinfo_bypass = 0;
    if (rc == 0 && *res) {
      record_bypass_addrinfo(*res);
    }
    return rc;
  }

  return make_fake_addrinfo(node, service, hints, res);
}

static void ag_freeaddrinfo(struct addrinfo *res) {
  load_config();

  if (!res) {
    return;
  }
  if (!unregister_owned_addrinfo(res)) {
    freeaddrinfo(res);
    return;
  }

  while (res) {
    struct addrinfo *next = res->ai_next;
    free(res->ai_canonname);
    free(res->ai_addr);
    free(res);
    res = next;
  }
}

__attribute__((used)) static struct interpose_entry interposers[]
    __attribute__((section("__DATA,__interpose"))) = {
        {(const void *)ag_connect, (const void *)connect},
        {(const void *)ag_getaddrinfo, (const void *)getaddrinfo},
        {(const void *)ag_freeaddrinfo, (const void *)freeaddrinfo},
};
