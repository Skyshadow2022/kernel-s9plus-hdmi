/*
 * hdmi_mirror - root userspace mirror: phone UI → /dev/graphics/fb1 (DP/HDMI)
 *
 * Captures the primary display via screencap (raw RGBA) and scales into fb1.
 * Requires KernelSU/root and prefer_live / bist sysfs from the custom kernel.
 */
#include <errno.h>
#include <fcntl.h>
#include <linux/fb.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>

#define FB1_PATH "/dev/graphics/fb1"
#define PIDFILE "/data/local/tmp/hdmi_mirror.pid"
#define LOGFILE "/data/local/tmp/hdmi_mirror.log"

static volatile sig_atomic_t g_run = 1;

static void on_sig(int sig)
{
	(void)sig;
	g_run = 0;
}

static void logmsg(const char *msg)
{
	FILE *f = fopen(LOGFILE, "a");
	if (f) {
		fprintf(f, "%s\n", msg);
		fclose(f);
	}
	fprintf(stderr, "%s\n", msg);
}

static int write_sysfs(const char *path, const char *val)
{
	int fd = open(path, O_WRONLY);
	if (fd < 0)
		return -1;
	ssize_t n = write(fd, val, strlen(val));
	close(fd);
	return n < 0 ? -1 : 0;
}

static int dp_connected(void)
{
	char buf[64] = {0};
	int fd = open("/sys/class/extcon/extcon0/state", O_RDONLY);
	if (fd < 0)
		return 0;
	read(fd, buf, sizeof(buf) - 1);
	close(fd);
	return strstr(buf, "DP=1") != NULL;
}

static int prepare_dp_live(void)
{
	/*
	 * NEXT: prefer_live defaults on and HPD already BIST→kick.
	 * Still force the path for older builds / late start.
	 */
	write_sysfs("/sys/class/dp_sec/prefer_live", "1\n");
	write_sysfs("/sys/class/graphics/fb1/blank", "0\n");
	usleep(200000);
	write_sysfs("/sys/class/dp_sec/bist", "0\n");
	usleep(400000);
	return 0;
}

/* Nearest-neighbor scale RGBA src → dst (same stride = width*4) */
static void scale_rgba(const uint8_t *src, int sw, int sh,
		       uint8_t *dst, int dw, int dh)
{
	for (int y = 0; y < dh; y++) {
		int sy = (int)((int64_t)y * sh / dh);
		const uint8_t *srow = src + (size_t)sy * sw * 4;
		uint8_t *drow = dst + (size_t)y * dw * 4;
		for (int x = 0; x < dw; x++) {
			int sx = (int)((int64_t)x * sw / dw);
			memcpy(drow + x * 4, srow + sx * 4, 4);
		}
	}
}

/* Rotate portrait RGBA 90° CW → landscape (phone upright → TV landscape) */
static uint8_t *rotate_rgba_90cw(const uint8_t *src, int sw, int sh)
{
	uint8_t *dst = malloc((size_t)sh * sw * 4);
	int x, y;

	if (!dst)
		return NULL;
	for (y = 0; y < sh; y++) {
		for (x = 0; x < sw; x++) {
			int dx = sh - 1 - y;
			int dy = x;
			memcpy(dst + ((size_t)dy * sh + dx) * 4,
			       src + ((size_t)y * sw + x) * 4, 4);
		}
	}
	return dst;
}

/* Letterbox fit preserving aspect into dw x dh, clear rest to black */
static void fit_rgba(const uint8_t *src, int sw, int sh,
		     uint8_t *dst, int dw, int dh, int dst_stride)
{
	const uint8_t *use = src;
	uint8_t *rot = NULL;
	int uw = sw, uh = sh;

	memset(dst, 0, (size_t)dst_stride * dh);
	if (sw <= 0 || sh <= 0 || dw <= 0 || dh <= 0)
		return;

	/* Phone portrait → sink landscape: rotate before letterbox */
	if (sw < sh && dw > dh) {
		rot = rotate_rgba_90cw(src, sw, sh);
		if (rot) {
			use = rot;
			uw = sh;
			uh = sw;
		}
	}

	double scale = (double)dw / uw;
	if (scale * uh > dh)
		scale = (double)dh / uh;
	int tw = (int)(uw * scale);
	int th = (int)(uh * scale);
	if (tw < 1)
		tw = 1;
	if (th < 1)
		th = 1;
	int ox = (dw - tw) / 2;
	int oy = (dh - th) / 2;

	uint8_t *tmp = malloc((size_t)tw * th * 4);
	if (!tmp) {
		free(rot);
		return;
	}
	scale_rgba(use, uw, uh, tmp, tw, th);
	for (int y = 0; y < th; y++) {
		uint8_t *d = dst + (size_t)(oy + y) * dst_stride + ox * 4;
		memcpy(d, tmp + (size_t)y * tw * 4, (size_t)tw * 4);
	}
	free(tmp);
	free(rot);
}

static uint8_t *capture_rgba(int *w, int *h)
{
	int pfd[2];
	if (pipe(pfd) < 0)
		return NULL;
	pid_t pid = fork();
	if (pid < 0) {
		close(pfd[0]);
		close(pfd[1]);
		return NULL;
	}
	if (pid == 0) {
		dup2(pfd[1], STDOUT_FILENO);
		close(pfd[0]);
		close(pfd[1]);
		execl("/system/bin/screencap", "screencap", (char *)NULL);
		_exit(127);
	}
	close(pfd[1]);

	uint32_t hdr[3];
	if (read(pfd[0], hdr, sizeof(hdr)) != (ssize_t)sizeof(hdr)) {
		close(pfd[0]);
		waitpid(pid, NULL, 0);
		return NULL;
	}
	*w = (int)hdr[0];
	*h = (int)hdr[1];
	/* hdr[2] = pixel format */
	size_t need = (size_t)(*w) * (*h) * 4;
	uint8_t *buf = malloc(need);
	if (!buf) {
		close(pfd[0]);
		waitpid(pid, NULL, 0);
		return NULL;
	}
	size_t got = 0;
	while (got < need) {
		ssize_t n = read(pfd[0], buf + got, need - got);
		if (n <= 0)
			break;
		got += (size_t)n;
	}
	close(pfd[0]);
	waitpid(pid, NULL, 0);
	if (got < need) {
		free(buf);
		return NULL;
	}
	return buf;
}

static int mirror_loop(void)
{
	int fb = open(FB1_PATH, O_RDWR);
	if (fb < 0) {
		logmsg("open fb1 failed");
		return 1;
	}

	/*
	 * Live DECON first: kernel syncs fb1 var to sink and leaves DMA red.
	 * Pan-before-live flooded VIDEO FIFO_UNDER_FLOW on STABLE #29.
	 */
	prepare_dp_live();

	struct fb_var_screeninfo vinfo;
	struct fb_fix_screeninfo finfo;
	if (ioctl(fb, FBIOGET_VSCREENINFO, &vinfo) < 0 ||
	    ioctl(fb, FBIOGET_FSCREENINFO, &finfo) < 0) {
		logmsg("fb ioctl failed");
		close(fb);
		return 1;
	}

	/*
	 * Prefer sink geometry from kernel (post-kick sync). Only force FHD
	 * when var is still probe-sized and smem can hold it.
	 */
	{
		size_t need_fhd = (size_t)1920 * 1080 * 4 * 2;
		int tiny = (vinfo.xres < 1280 || vinfo.yres < 720);

		if (tiny && finfo.smem_len >= need_fhd) {
			vinfo.xres = 1920;
			vinfo.yres = 1080;
			vinfo.xres_virtual = 1920;
			vinfo.yres_virtual = 2160;
			vinfo.bits_per_pixel = 32;
			if (ioctl(fb, FBIOPUT_VSCREENINFO, &vinfo) == 0) {
				ioctl(fb, FBIOGET_VSCREENINFO, &vinfo);
				ioctl(fb, FBIOGET_FSCREENINFO, &finfo);
				logmsg("fb1 resized to FHD");
			}
		}
	}

	int stride = (int)finfo.line_length;
	size_t map_len = finfo.smem_len ? finfo.smem_len
					: (size_t)stride * vinfo.yres_virtual;
	if (!map_len) {
		logmsg("fb1 smem_len=0");
		close(fb);
		return 1;
	}

	int dw = (int)vinfo.xres;
	int dh = (int)vinfo.yres;
	if (stride <= 0)
		stride = dw * 4;
	if (dw < 1)
		dw = 1;
	if ((size_t)stride * (size_t)dh > map_len)
		dh = (int)(map_len / (size_t)stride);
	if (dh < 1)
		dh = 1;

	void *map = mmap(NULL, map_len, PROT_READ | PROT_WRITE, MAP_SHARED, fb, 0);
	if (map == MAP_FAILED) {
		logmsg("mmap fb1 failed");
		close(fb);
		return 1;
	}

	ioctl(fb, FBIOBLANK, FB_BLANK_UNBLANK);

	char msg[128];
	snprintf(msg, sizeof(msg), "mirror start fb1 %dx%d stride=%d", dw, dh, stride);
	logmsg(msg);

	/*
	 * ONE pan only to arm VGF1 DMA. Further FBIOPAN storms shadow/FIFO.
	 * Video-mode scanout + kernel live_trig re-reads the same fb buffer,
	 * so later frames are mmap writes only.
	 */
	{
		uint32_t *px = (uint32_t *)map;
		size_t npx = ((size_t)stride / 4) * (size_t)dh;
		size_t i;
		for (i = 0; i < npx; i++)
			px[i] = 0xFF0000FFu;
		vinfo.yoffset = 0;
		if (ioctl(fb, FBIOPAN_DISPLAY, &vinfo) < 0)
			logmsg("arm pan failed (staying on winmap red)");
		else
			logmsg("arm pan OK — mmap-only updates from here");
		usleep(200000);
	}

	while (g_run) {
		if (!dp_connected()) {
			logmsg("DP disconnected, stopping");
			break;
		}
		int sw = 0, sh = 0;
		uint8_t *cap = capture_rgba(&sw, &sh);
		if (!cap) {
			usleep(200000);
			continue;
		}
		fit_rgba(cap, sw, sh, map, dw, dh, stride);
		free(cap);
		/* No FBIOPAN — keep DMA pointed at this buffer */
		usleep(100000); /* ~10 fps capture */
	}

	munmap(map, map_len);
	close(fb);
	logmsg("mirror stopped");
	return 0;
}

static int write_pid(void)
{
	FILE *f = fopen(PIDFILE, "w");
	if (!f)
		return -1;
	fprintf(f, "%d\n", (int)getpid());
	fclose(f);
	return 0;
}

int main(int argc, char **argv)
{
	const char *cmd = argc > 1 ? argv[1] : "run";

	if (!strcmp(cmd, "stop")) {
		FILE *f = fopen(PIDFILE, "r");
		int pid = 0;
		if (f && fscanf(f, "%d", &pid) == 1 && pid > 1)
			kill(pid, SIGTERM);
		if (f)
			fclose(f);
		unlink(PIDFILE);
		/* Keep live path; do NOT restore BIST color bars */
		write_sysfs("/sys/class/dp_sec/prefer_live", "1\n");
		write_sysfs("/sys/class/dp_sec/bist", "0\n");
		return 0;
	}

	if (!strcmp(cmd, "status")) {
		printf("dp=%s\n", dp_connected() ? "1" : "0");
		FILE *f = fopen(PIDFILE, "r");
		int pid = 0;
		if (f && fscanf(f, "%d", &pid) == 1)
			printf("pid=%d\n", pid);
		else
			printf("pid=0\n");
		if (f)
			fclose(f);
		return 0;
	}

	if (!dp_connected()) {
		logmsg("DP not connected");
		return 2;
	}

	signal(SIGTERM, on_sig);
	signal(SIGINT, on_sig);
	write_pid();
	int rc = mirror_loop();
	unlink(PIDFILE);
	return rc;
}
