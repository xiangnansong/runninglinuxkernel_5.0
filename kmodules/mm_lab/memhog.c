/*
 * memhog - 内存压力发生器，用于观察 Linux 页面回收(page reclaim)行为
 *
 * 用法:
 *   memhog <总大小MB> [持有秒数] [每步MB]
 *
 * 行为:
 *   以 "每步MB" 为粒度分配匿名内存并逐页写入(触发缺页分配真实物理页),
 *   分配完成后 sleep "持有秒数",然后释放退出。
 *
 * 说明:
 *   - 使用 mmap(MAP_ANONYMOUS) 而不是 malloc,避免 glibc arena 复用带来的干扰
 *   - 每页只写 1 个字节即可让内核分配物理页 (page fault -> alloc_pages)
 *   - 分步分配可以让 kswapd 有机会介入,从而同时观察到后台回收和直接回收
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>

int main(int argc, char *argv[])
{
	long total_mb, hold_sec = 5, step_mb = 8;
	long page = sysconf(_SC_PAGESIZE);
	long done_mb = 0;
	char **chunks;
	int nr_chunks, i;

	if (argc < 2) {
		fprintf(stderr, "usage: %s <total_MB> [hold_sec] [step_MB]\n", argv[0]);
		return 1;
	}

	total_mb = atol(argv[1]);
	if (argc >= 3)
		hold_sec = atol(argv[2]);
	if (argc >= 4)
		step_mb = atol(argv[3]);
	if (total_mb <= 0 || step_mb <= 0)
		return 1;

	nr_chunks = (total_mb + step_mb - 1) / step_mb;
	chunks = calloc(nr_chunks, sizeof(char *));
	if (!chunks)
		return 1;

	printf("[memhog] pid=%d target=%ldMB step=%ldMB hold=%lds\n",
	       getpid(), total_mb, step_mb, hold_sec);
	fflush(stdout);

	for (i = 0; i < nr_chunks; i++) {
		long this_mb = (total_mb - done_mb) < step_mb ?
					(total_mb - done_mb) : step_mb;
		size_t len = (size_t)this_mb * 1024 * 1024;
		char *p, *q;

		p = mmap(NULL, len, PROT_READ | PROT_WRITE,
			 MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
		if (p == MAP_FAILED) {
			perror("[memhog] mmap");
			break;
		}

		/* 逐页写入,强制内核真正分配物理页 */
		for (q = p; q < p + len; q += page)
			*q = 0x5a;

		chunks[i] = p;
		done_mb += this_mb;
		printf("[memhog] allocated %ld MB\n", done_mb);
		fflush(stdout);
	}

	printf("[memhog] hold %ld sec ...\n", hold_sec);
	fflush(stdout);
	sleep(hold_sec);

	for (i = 0; i < nr_chunks; i++)
		if (chunks[i])
			munmap(chunks[i], (size_t)step_mb * 1024 * 1024);

	printf("[memhog] done, freed %ld MB\n", done_mb);
	return 0;
}
