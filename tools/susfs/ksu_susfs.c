/*
 * ksu_susfs - minimal freestanding userspace tool for SUSFS v2.2.0 (non-GKI)
 * on KernelSU-Next with manual hooks.
 *
 * The official ksu_susfs from the susfs4ksu repo speaks the prctl channel
 * (prctl(0xDEADBEEF, CMD, ...)), which KernelSU-Next v3.x does not hook.
 * This kernel's SUSFS dispatcher lives in ksu_handle_sys_reboot, so commands
 * travel on the reboot syscall instead:
 *
 *     syscall(142 __NR_reboot, 0xDEADBEEF, 0xFAFAFAFA, CMD, user_ptr)
 *
 * The call returns -EINVAL from the reboot validation itself - EXPECTED and
 * irrelevant. The reply lands in the struct the user pointer refers to (every
 * struct ends in int err). Check err, not the return value.
 *
 * Compiled -nostdlib -static: no libc on this build host, and the tool only
 * needs write/exit/reboot anyway. Struct layouts must match
 * kernel_source/include/linux/susfs.h byte for byte.
 */

typedef unsigned int  u32;
typedef long          s64;
typedef unsigned long u64;

#define KSU_INSTALL_MAGIC1 0xDEADBEEF
#define SUSFS_MAGIC        0xFAFAFAFA

#define CMD_SUSFS_SHOW_VERSION           0x555e1
#define CMD_SUSFS_SHOW_ENABLED_FEATURES  0x555e2
#define CMD_SUSFS_SHOW_VARIANT           0x555e3
#define CMD_SUSFS_SET_UNAME              0x55590
#define CMD_SUSFS_ADD_SUS_PATH           0x55550
#define CMD_SUSFS_SET_CMDLINE_OR_BOOTCONFIG 0x555b0
#define CMD_SUSFS_ENABLE_AVC_LOG_SPOOFING 0x60010

#define SUSFS_MAX_LEN_PATHNAME 256
#define SUSFS_FAKE_CMDLINE_SIZE 8192

#define __NEW_UTS_LEN 64
#define FEATS_SIZE    8192

struct st_susfs_version { char susfs_version[16]; int err; };
struct st_susfs_variant { char susfs_variant[16]; int err; };
struct st_susfs_uname {
	char release[__NEW_UTS_LEN + 1];
	char version[__NEW_UTS_LEN + 1];
	int err;
};
struct st_susfs_enabled_features { char enabled_features[FEATS_SIZE]; int err; };
struct st_susfs_sus_path { char target_pathname[256]; int err; };
struct st_susfs_spoof_cmdline { char fake_cmdline_or_bootconfig[8192]; int err; };
struct st_susfs_avc_log_spoofing { unsigned char enabled; int err; };

static s64 sys3(u64 n, u64 a, u64 b, u64 c)
{
	register u64 x8 __asm__("x8") = n;
	register u64 x0 __asm__("x0") = a;
	register u64 x1 __asm__("x1") = b;
	register u64 x2 __asm__("x2") = c;
	__asm__ volatile ("svc 0"
			  : "+r"(x0)
			  : "r"(x8), "r"(x0), "r"(x1), "r"(x2)
			  : "memory", "cc");
	return (s64)x0;
}

static s64 sys5(u64 n, u64 a, u64 b, u64 c, u64 d, u64 e)
{
	register u64 x8 __asm__("x8") = n;
	register u64 x0 __asm__("x0") = a;
	register u64 x1 __asm__("x1") = b;
	register u64 x2 __asm__("x2") = c;
	register u64 x3 __asm__("x3") = d;
	register u64 x4 __asm__("x4") = e;
	__asm__ volatile ("svc 0"
			  : "+r"(x0)
			  : "r"(x8), "r"(x0), "r"(x1), "r"(x2), "r"(x3), "r"(x4)
			  : "memory", "cc");
	return (s64)x0;
}

#define sys_write(fd, buf, n) sys3(64, (u64)(fd), (u64)(buf), (u64)(n))
#define sys_exit(code)        sys3(93, (u64)(code), 0, 0)
/* reboot syscall ABI: x0=magic1, x1=magic2, x2=cmd, x3=arg */
#define susfs_cmd(cmd, info)  sys5(142, (u64)KSU_INSTALL_MAGIC1, \
				   (u64)SUSFS_MAGIC, (u64)(cmd), \
				   (u64)(info), 0)

static s64 sys1(u64 n, u64 a)
{
	register u64 x8 __asm__("x8") = n;
	register u64 x0 __asm__("x0") = a;
	__asm__ volatile ("svc 0" : "+r"(x0) : "r"(x8), "r"(x0) : "memory", "cc");
	return (s64)x0;
}

#define sys_getuid() sys1(174, 0)

static u64 slen(const char *s) { u64 n = 0; while (s[n]) n++; return n; }

void *memset(void *dst, int c, u64 n)
{
	unsigned char *d = dst;
	while (n--) *d++ = (unsigned char)c;
	return dst;
}

static void out(const char *s) { sys_write(1, s, slen(s)); }

static void out_num(int v)
{
	char buf[12];
	int i = 0;
	unsigned u = v < 0 ? (unsigned)(-(long)v) : (unsigned)v;
	if (v < 0) { char m = '-'; sys_write(1, &m, 1); }
	if (!u) { sys_write(1, "0", 1); return; }
	while (u) { buf[i++] = '0' + u % 10; u /= 10; }
	while (i) sys_write(1, &buf[--i], 1);
}

static void out_str_field(const char *field, const char *v)
{
	out(field);
	sys_write(1, v, slen(v));
	out("\n");
}

static u64 slen_max(const char *s, u64 max)
{
	u64 n = 0;
	while (n < max && s[n]) n++;
	return n;
}

static int streq(const char *a, const char *b)
{
	while (*a && *a == *b) { a++; b++; }
	return *a == *b;
}

__attribute__((naked)) void _start(void)
{
	/* at ELF entry sp points to: [argc][argv0][argv1]...[NULL][envp...] */
	__asm__ volatile ("mov x0, sp\n\tb ksu_main");
}

void ksu_main(u64 *sp)
{
	u64 argc = sp[0];
	char **argv = (char **)(sp + 1);

	(void)argc;
	if (sys_getuid() != 0) {
		out("must run as root (uid 0)\n");
		sys_exit(2);
	}

	if (argc == 2 && streq(argv[1], "show")) {
		struct st_susfs_version v = {0};
		struct st_susfs_variant t = {0};
		susfs_cmd(CMD_SUSFS_SHOW_VERSION, &v);
		out("version: ");
		if (v.err) { out("error "); out_num(v.err); out("\n"); }
		else out_str_field("", v.susfs_version);
		susfs_cmd(CMD_SUSFS_SHOW_VARIANT, &t);
		out("variant: ");
		if (t.err) { out("error "); out_num(t.err); out("\n"); }
		else out_str_field("", t.susfs_variant);
		sys_exit(0);
	}
	if (argc == 2 && streq(argv[1], "version")) {
		struct st_susfs_version v = {0};
		susfs_cmd(CMD_SUSFS_SHOW_VERSION, &v);
		if (v.err) { out("error "); out_num(v.err); out("\n"); }
		else out_str_field("", v.susfs_version);
		sys_exit(0);
	}
	if (argc == 2 && streq(argv[1], "variant")) {
		struct st_susfs_variant t = {0};
		susfs_cmd(CMD_SUSFS_SHOW_VARIANT, &t);
		if (t.err) { out("error "); out_num(t.err); out("\n"); }
		else out_str_field("", t.susfs_variant);
		sys_exit(0);
	}
	if (argc == 3 && streq(argv[1], "path")) {
		struct st_susfs_sus_path p = {0};
		if (slen_max(argv[2], SUSFS_MAX_LEN_PATHNAME + 1) > SUSFS_MAX_LEN_PATHNAME - 1) {
			out("path max 255 chars\n");
			sys_exit(2);
		}
		for (u64 i = 0; i <= slen(argv[2]); i++) p.target_pathname[i] = argv[2][i];
		susfs_cmd(CMD_SUSFS_ADD_SUS_PATH, &p);
		if (p.err) { out("error "); out_num(p.err); out("\n"); sys_exit(1); }
		out("sus_path added: ");
		out(argv[2]);
		out("\n");
		sys_exit(0);
	}
	if (argc == 3 && streq(argv[1], "cmdline")) {
		struct st_susfs_spoof_cmdline c = {0};
		u64 n = slen(argv[2]);
		if (n >= SUSFS_FAKE_CMDLINE_SIZE) { out("cmdline max 8191 chars\n"); sys_exit(2); }
		for (u64 i = 0; i < n; i++) c.fake_cmdline_or_bootconfig[i] = argv[2][i];
		susfs_cmd(CMD_SUSFS_SET_CMDLINE_OR_BOOTCONFIG, &c);
		if (c.err) { out("error "); out_num(c.err); out("\n"); sys_exit(1); }
		out("fake cmdline set\n");
		sys_exit(0);
	}
	if (argc == 3 && streq(argv[1], "avcspoof")) {
		struct st_susfs_avc_log_spoofing a = {0};
		a.enabled = (argv[2][0] != '0');
		susfs_cmd(CMD_SUSFS_ENABLE_AVC_LOG_SPOOFING, &a);
		if (a.err) { out("error "); out_num(a.err); out("\n"); sys_exit(1); }
		out("avc log spoofing: ");
		out(a.enabled ? "on\n" : "off\n");
		sys_exit(0);
	}
	if (argc == 2 && streq(argv[1], "features")) {
		struct st_susfs_enabled_features f = {0};
		susfs_cmd(CMD_SUSFS_SHOW_ENABLED_FEATURES, &f);
		if (f.err) { out("error "); out_num(f.err); out("\n"); }
		else out_str_field("", f.enabled_features);
		sys_exit(0);
	}
	if (argc == 4 && streq(argv[1], "uname")) {
		struct st_susfs_uname u = {0};
		if (slen_max(argv[2], __NEW_UTS_LEN + 1) > __NEW_UTS_LEN ||
		    slen_max(argv[3], __NEW_UTS_LEN + 1) > __NEW_UTS_LEN) {
			out("release/version max 64 chars\n");
			sys_exit(2);
		}
		for (u64 i = 0; i <= slen(argv[2]); i++) u.release[i] = argv[2][i];
		for (u64 i = 0; i <= slen(argv[3]); i++) u.version[i] = argv[3][i];
		susfs_cmd(CMD_SUSFS_SET_UNAME, &u);
		if (u.err) { out("error "); out_num(u.err); out("\n"); }
		else {
			out("uname spoof set: release='");
			sys_write(1, u.release, slen(u.release));
			out("' version='");
			sys_write(1, u.version, slen(u.version));
			out("'\n");
		}
		sys_exit(0);
	}

	out("usage: ksu_susfs show | version | variant | features\n");
	out("       ksu_susfs uname <release> <version>  ('default' keeps current)\n");
	out("       ksu_susfs path <pathname>            (add sus_path)\n");
	out("       ksu_susfs cmdline <fake cmdline>     (spoof /proc/cmdline)\n");
	out("       ksu_susfs avcspoof <0|1>             (hide ksu avc denials)\n");
	sys_exit(2);
}
