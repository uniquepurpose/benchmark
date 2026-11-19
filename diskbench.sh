#!/usr/bin/env bash
# diskbench.sh - Linux equivalent of DiskBenchmark.ps1
# Benchmarks IOPS/throughput/latency/burst on a folder or mountpoint.
# Requires a C compiler (cc/gcc/clang). Produces the same CSV schema as the
# PowerShell version: Workload,BlockSize,Mode,QD,IopsMin,IopsAvg,IopsMax,
# MBpsMin,MBpsAvg,MBpsMax,LatMinMs,LatAvgMs,LatP50Ms,LatP95Ms,LatP99Ms,LatMaxMs,
# BurstMinIops,BurstMaxIops
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: ./diskbench.sh <directory-or-mountpoint> [options]

Options:
  --size-gb N       Test file size in GiB (default 8)
  --runs N          Runs per workload (default 3)
  --seconds N       Seconds per run (default 10, min 3)
  --qd-random N     Queue depth for random workloads (default 32)
  --qd-seq N        Queue depth for sequential workloads (default 8)
  --mixed-write N   Write percentage in mixed workloads (default 30)
  --file NAME       Test file name (default diskbenchmark.tmp)
  --csv PATH        Also write results as CSV to PATH
  --keep            Keep the test file afterwards
  -h, --help        Show this help

Example:
  ./diskbench.sh /mnt/data --size-gb 8 --runs 3 --seconds 10 --csv /tmp/linux.csv
EOF
}

TARGET="" SIZE_GB=8 RUNS=3 SECONDS=10 QD_RANDOM=32 QD_SEQ=8 MIXED_WRITE=30
CSV_OUT="" KEEP=0 FILE_NAME="diskbenchmark.tmp"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --size-gb)     SIZE_GB="$2"; shift 2;;
    --runs)        RUNS="$2"; shift 2;;
    --seconds)     SECONDS="$2"; shift 2;;
    --qd-random)   QD_RANDOM="$2"; shift 2;;
    --qd-seq)      QD_SEQ="$2"; shift 2;;
    --mixed-write) MIXED_WRITE="$2"; shift 2;;
    --csv)         CSV_OUT="$2"; shift 2;;
    --file)        FILE_NAME="$2"; shift 2;;
    --keep)        KEEP=1; shift;;
    -h|--help)     usage; exit 0;;
    -*)            echo "unknown option: $1" >&2; usage; exit 1;;
    *)             if [[ -z "$TARGET" ]]; then TARGET="$1"; shift; else echo "unexpected argument: $1" >&2; usage; exit 1; fi;;
  esac
done

is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }
[[ -z "$TARGET" ]] && { echo "error: target directory/mountpoint required" >&2; usage; exit 1; }
for v in "$SIZE_GB" "$RUNS" "$SECONDS" "$QD_RANDOM" "$QD_SEQ" "$MIXED_WRITE"; do
  is_uint "$v" || { echo "error: numeric value expected, got '$v'" >&2; exit 1; }
done
(( RUNS >= 1 ))      || { echo "error: --runs must be >= 1" >&2; exit 1; }
(( SECONDS >= 3 ))   || { echo "error: --seconds must be >= 3" >&2; exit 1; }
(( SIZE_GB >= 1 ))   || { echo "error: --size-gb must be >= 1" >&2; exit 1; }
(( MIXED_WRITE >= 0 && MIXED_WRITE <= 100 )) || { echo "error: --mixed-write must be 0..100" >&2; exit 1; }

[[ -d "$TARGET" ]] || { echo "error: '$TARGET' is not a directory" >&2; exit 1; }
[[ -w "$TARGET" ]] || { echo "error: '$TARGET' is not writable" >&2; exit 1; }
TARGET=$(cd "$TARGET" && pwd)
TEST_FILE="$TARGET/$FILE_NAME"
FILE_SIZE=$((SIZE_GB * 1073741824))

FREE=$(df -B1 --output=avail "$TARGET" | tail -1)
NEED=$((FILE_SIZE + 1073741824))
(( FREE >= NEED )) || { echo "error: not enough free space on $TARGET (need $((NEED / 1073741824)) GiB, have $((FREE / 1073741824)) GiB)" >&2; exit 1; }

CC_BIN=""
for c in cc gcc clang; do
  if command -v "$c" >/dev/null 2>&1; then CC_BIN="$c"; break; fi
done
[[ -z "$CC_BIN" ]] && { echo "error: no C compiler found; install one (e.g. 'apt install gcc' or 'yum install gcc')" >&2; exit 1; }

WORKDIR=$(mktemp -d /tmp/diskbench.XXXXXX)
cleanup() {
  if [[ $KEEP -eq 0 && -f "$TEST_FILE" ]]; then rm -f "$TEST_FILE"; fi
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

SRC="$WORKDIR/diskbench.c"
BIN="$WORKDIR/diskbench"
cat > "$SRC" <<'CEOF'
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <pthread.h>
#include <time.h>
#include <math.h>
#include <errno.h>
#include <sys/stat.h>
#include <sys/types.h>

typedef struct { const char *name; int block; int random; const char *mode; int qd; } Cfg;

typedef struct {
    long ops;
    long bytes;
    double elapsed;
    double *lats;
    size_t nlats;
    size_t cap;
    int error;
    long *per_second;
} RunOut;

typedef struct {
    int tid;
    const char *path;
    long filesize;
    int block;
    int random;
    const char *mode;
    int write_pct;
    int seconds;
    int use_odirect;
    double t0;
    long *per_second;
    RunOut *out;
} WArg;

static double now_sec(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

static int cmp_double(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}

static double pct(double *sorted, size_t n, double p) {
    if (n == 0) return 0;
    size_t i = (size_t)ceil(p / 100.0 * (double)n);
    if (i == 0) i = 1;
    if (i > n) i = n;
    return sorted[i - 1];
}

static void lat_push(RunOut *r, double v) {
    if (r->nlats == r->cap) {
        r->cap = r->cap ? r->cap * 2 : 4096;
        r->lats = realloc(r->lats, r->cap * sizeof(double));
    }
    r->lats[r->nlats++] = v;
}

static void *worker(void *p) {
    WArg *a = (WArg *)p;
    RunOut *out = a->out;
    unsigned seed = 1234567u + (unsigned)a->tid * 7919u;
    int flags = (strcmp(a->mode, "Read") == 0) ? O_RDONLY : O_RDWR;
    if (a->use_odirect) flags |= O_DIRECT;
    int fd = open(a->path, flags);
    if (fd < 0 && a->use_odirect) fd = open(a->path, flags & ~O_DIRECT);
    if (fd < 0) { out->error = errno; return NULL; }
    void *buf = NULL;
    if (posix_memalign(&buf, 4096, a->block) != 0) { out->error = ENOMEM; close(fd); return NULL; }
    long blocks = a->filesize / a->block;
    long seqpos = (long)a->tid * a->block * 64;
    long ops = 0, bytes = 0;
    while (now_sec() - a->t0 < a->seconds) {
        long off;
        if (a->random)
            off = (long)(((double)rand_r(&seed) / RAND_MAX) * blocks) * a->block;
        else {
            off = seqpos;
            seqpos += a->block;
            if (seqpos + a->block > a->filesize) seqpos = (long)a->tid * a->block;
        }
        int do_write = (strcmp(a->mode, "Write") == 0) ||
                       (strcmp(a->mode, "Mixed") == 0 && (rand_r(&seed) % 100) < a->write_pct);
        double s = now_sec();
        ssize_t done = 0;
        int failed = 0;
        while (done < a->block) {
            ssize_t r = do_write ? pwrite(fd, (char *)buf + done, a->block - done, off + done)
                                 : pread(fd, (char *)buf + done, a->block - done, off + done);
            if (r <= 0) { failed = 1; break; }
            done += r;
        }
        double e = now_sec();
        if (failed) break;
        lat_push(out, (e - s) * 1000.0);
        ops++;
        bytes += a->block;
        long sec = (long)(e - a->t0);
        if (sec >= 0 && sec < a->seconds + 2) __sync_fetch_and_add(&a->per_second[sec], 1);
    }
    out->ops = ops;
    out->bytes = bytes;
    free(buf);
    close(fd);
    return NULL;
}

static RunOut run_once(const char *path, long filesize, int block, int random, const char *mode,
                       int write_pct, int qd, int seconds, int use_odirect) {
    RunOut all;
    memset(&all, 0, sizeof(all));
    long *per_second = calloc((size_t)seconds + 2, sizeof(long));
    pthread_t *th = malloc((size_t)qd * sizeof(pthread_t));
    WArg *args = malloc((size_t)qd * sizeof(WArg));
    RunOut *outs = calloc((size_t)qd, sizeof(RunOut));
    double t0 = now_sec();
    for (int i = 0; i < qd; i++) {
        args[i].tid = i; args[i].path = path; args[i].filesize = filesize;
        args[i].block = block; args[i].random = random; args[i].mode = mode;
        args[i].write_pct = write_pct; args[i].seconds = seconds;
        args[i].use_odirect = use_odirect; args[i].t0 = t0;
        args[i].per_second = per_second; args[i].out = &outs[i];
        pthread_create(&th[i], NULL, worker, &args[i]);
    }
    for (int i = 0; i < qd; i++) pthread_join(th[i], NULL);
    all.elapsed = now_sec() - t0;
    size_t total = 0;
    for (int i = 0; i < qd; i++) {
        if (outs[i].error) { fprintf(stderr, "worker error: %s\n", strerror(outs[i].error)); exit(1); }
        all.ops += outs[i].ops;
        all.bytes += outs[i].bytes;
        total += outs[i].nlats;
    }
    all.lats = malloc((total ? total : 1) * sizeof(double));
    all.nlats = 0;
    for (int i = 0; i < qd; i++) {
        memcpy(all.lats + all.nlats, outs[i].lats, outs[i].nlats * sizeof(double));
        all.nlats += outs[i].nlats;
        free(outs[i].lats);
    }
    if (!use_odirect) {
        int fd = open(path, O_RDONLY);
        if (fd >= 0) { posix_fadvise(fd, 0, 0, POSIX_FADV_DONTNEED); close(fd); }
    }
    all.per_second = per_second;
    free(th); free(args); free(outs);
    return all;
}

int main(int argc, char **argv) {
    if (argc < 8) { fprintf(stderr, "usage: %s path filesize runs seconds qd_rand qd_seq mixed_write\n", argv[0]); return 2; }
    const char *path = argv[1];
    long filesize = atol(argv[2]);
    int runs = atoi(argv[3]), seconds = atoi(argv[4]);
    int qd_rand = atoi(argv[5]), qd_seq = atoi(argv[6]), mixed_w = atoi(argv[7]);

    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) { perror("create test file"); return 1; }
    if (ftruncate(fd, filesize) != 0) { perror("ftruncate"); close(fd); return 1; }
    close(fd);

    int probe = open(path, O_RDONLY | O_DIRECT);
    int use_odirect = probe >= 0;
    if (probe >= 0) close(probe);
    printf("#ODIRECT,%d\n", use_odirect ? 1 : 0);

    fprintf(stderr, "Warming up (2s sequential read)...\n");
    RunOut w = run_once(path, filesize, 1048576, 0, "Read", 0, qd_seq, 2, use_odirect);
    free(w.lats); free(w.per_second);

    char mixr[64], mixs[64];
    snprintf(mixr, sizeof(mixr), "Random 4K Mixed %dR/%dW", 100 - mixed_w, mixed_w);
    snprintf(mixs, sizeof(mixs), "Sequential 1M Mixed %dR/%dW", 100 - mixed_w, mixed_w);

    Cfg configs[7] = {
        {"Random 4K Read QD1", 4096, 1, "Read", 1},
        {"Random 4K Read", 4096, 1, "Read", qd_rand},
        {"Random 4K Write", 4096, 1, "Write", qd_rand},
        {mixr, 4096, 1, "Mixed", qd_rand},
        {"Sequential 1M Read", 1048576, 0, "Read", qd_seq},
        {"Sequential 1M Write", 1048576, 0, "Write", qd_seq},
        {mixs, 1048576, 0, "Mixed", qd_seq}
    };

    printf("Workload,BlockSize,Mode,QD,IopsMin,IopsAvg,IopsMax,MBpsMin,MBpsAvg,MBpsMax,LatMinMs,LatAvgMs,LatP50Ms,LatP95Ms,LatP99Ms,LatMaxMs,BurstMinIops,BurstMaxIops\n");

    long *trace = NULL;
    char trace_name[128] = "";
    int trace_qd = 0;

    for (int c = 0; c < 7; c++) {
        Cfg *cfg = &configs[c];
        double *iops = malloc((size_t)runs * sizeof(double));
        double *mbps = malloc((size_t)runs * sizeof(double));
        double *all_lats = NULL;
        size_t all_n = 0, all_cap = 0;
        double burst_min = -1, burst_max = 0;
        long *last_ps = NULL;
        for (int r = 0; r < runs; r++) {
            RunOut o = run_once(path, filesize, cfg->block, cfg->random, cfg->mode, mixed_w, cfg->qd, seconds, use_odirect);
            double io = o.ops / o.elapsed;
            double mb = o.bytes / o.elapsed / 1048576.0;
            iops[r] = io;
            mbps[r] = mb;
            if (all_n + o.nlats > all_cap) {
                all_cap = (all_n + o.nlats) * 2 + 1024;
                all_lats = realloc(all_lats, all_cap * sizeof(double));
            }
            memcpy(all_lats + all_n, o.lats, o.nlats * sizeof(double));
            all_n += o.nlats;
            free(o.lats);
            if (last_ps) free(last_ps);
            last_ps = o.per_second;
            for (int s = 1; s < seconds; s++) {
                if (o.per_second[s] > 0) {
                    if (o.per_second[s] > burst_max) burst_max = (double)o.per_second[s];
                    if (burst_min < 0 || o.per_second[s] < burst_min) burst_min = (double)o.per_second[s];
                }
            }
            fprintf(stderr, "  %s run %d/%d: %.0f IOPS, %.1f MB/s\n", cfg->name, r + 1, runs, io, mb);
        }
        qsort(all_lats, all_n, sizeof(double), cmp_double);
        double iops_min = 1e300, iops_max = 0, iops_sum = 0;
        double mbps_min = 1e300, mbps_max = 0, mbps_sum = 0;
        for (int r = 0; r < runs; r++) {
            if (iops[r] < iops_min) iops_min = iops[r];
            if (iops[r] > iops_max) iops_max = iops[r];
            iops_sum += iops[r];
            if (mbps[r] < mbps_min) mbps_min = mbps[r];
            if (mbps[r] > mbps_max) mbps_max = mbps[r];
            mbps_sum += mbps[r];
        }
        double lat_min = all_n ? all_lats[0] : 0;
        double lat_max = all_n ? all_lats[all_n - 1] : 0;
        double lat_sum = 0;
        for (size_t i = 0; i < all_n; i++) lat_sum += all_lats[i];
        double lat_avg = all_n ? lat_sum / (double)all_n : 0;
        printf("%s,%d,%s,%d,%.1f,%.1f,%.1f,%.2f,%.2f,%.2f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.1f,%.1f\n",
               cfg->name, cfg->block, cfg->mode, cfg->qd,
               iops_min, iops_sum / runs, iops_max,
               mbps_min, mbps_sum / runs, mbps_max,
               lat_min, lat_avg,
               pct(all_lats, all_n, 50), pct(all_lats, all_n, 95), pct(all_lats, all_n, 99), lat_max,
               burst_min < 0 ? 0.0 : burst_min, burst_max);
        if (c == 1) {
            trace = last_ps;
            snprintf(trace_name, sizeof(trace_name), "%s", cfg->name);
            trace_qd = cfg->qd;
        } else if (last_ps) {
            free(last_ps);
        }
        free(iops); free(mbps); free(all_lats);
    }
    if (trace) {
        printf("#PERSEC,%s,%d", trace_name, trace_qd);
        for (int s = 1; s <= seconds; s++) printf(",%ld", trace[s]);
        printf("\n");
        free(trace);
    }
    return 0;
}
CEOF

"$CC_BIN" -O2 -o "$BIN" "$SRC" -lpthread -lm

echo "Benchmarking $TARGET  test file: $TEST_FILE (${SIZE_GB} GiB)" >&2
echo "Runs: ${RUNS} x ${SECONDS}s per workload, QD random=${QD_RANDOM}, sequential=${QD_SEQ}" >&2
echo "Estimated duration: ~$(( (7 * RUNS * SECONDS + 2) / 60 )) minutes" >&2
echo >&2

CSV_TMP="$WORKDIR/results.csv"
"$BIN" "$TEST_FILE" "$FILE_SIZE" "$RUNS" "$SECONDS" "$QD_RANDOM" "$QD_SEQ" "$MIXED_WRITE" > "$CSV_TMP"

if grep -q '^#ODIRECT,0$' "$CSV_TMP"; then
  echo "warning: O_DIRECT not supported on $TARGET (tmpfs/overlayfs/9p etc.); used buffered I/O + fadvise(DONTNEED). Read numbers may be cache-influenced." >&2
fi

CLEAN="$WORKDIR/clean.csv"
grep -v '^#' "$CSV_TMP" > "$CLEAN"

echo "=== IOPS and throughput across ${RUNS} runs (min / avg / max) ==="
printf "%-30s %4s %10s %10s %10s %9s %9s %9s\n" "Workload" "QD" "IOPS min" "IOPS avg" "IOPS max" "MB/s min" "MB/s avg" "MB/s max"
awk -F, 'NR>1 {printf "%-30s %4d %10.0f %10.0f %10.0f %9.1f %9.1f %9.1f\n", $1,$4,$5,$6,$7,$8,$9,$10}' "$CLEAN"

echo
echo "=== Per-I/O latency in ms (min / avg / p50 / p95 / p99 / max) ==="
printf "%-30s %4s %8s %8s %8s %8s %8s %8s\n" "Workload" "QD" "min" "avg" "p50" "p95" "p99" "max"
awk -F, 'NR>1 {printf "%-30s %4d %8.3f %8.3f %8.3f %8.3f %8.3f %8.3f\n", $1,$4,$11,$12,$13,$14,$15,$16}' "$CLEAN"

echo
echo "=== Burst profile (per-second IOPS within a run, min / max) ==="
printf "%-30s %4s %18s %18s\n" "Workload" "QD" "burst min IOPS/s" "burst max IOPS/s"
awk -F, 'NR>1 {printf "%-30s %4d %18.0f %18.0f\n", $1,$4,$17,$18}' "$CLEAN"

PS_LINE=$(grep '^#PERSEC' "$CSV_TMP" | tail -1 || true)
if [[ -n "$PS_LINE" ]]; then
  IFS=, read -ra parts <<< "$PS_LINE"
  echo
  echo "Per-second IOPS of last '${parts[1]} QD${parts[2]}' run: ${parts[*]:3}"
fi

if [[ -n "$CSV_OUT" ]]; then
  cp "$CLEAN" "$CSV_OUT"
  echo
  echo "CSV written to $CSV_OUT"
fi