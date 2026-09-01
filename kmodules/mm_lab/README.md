# 用 ftrace 观察 Linux 内存回收(page reclaim)

> 环境: 本仓库的 Linux 5.0 内核 + QEMU + BusyBox(`run_busybox.sh arm64_mm`)
> 目标: 把"内存不够了内核怎么办"这件事,从 tracepoint 一条条打出来看清楚
> 复验: 2026-07-27 在 `arm64_mm` 下重新跑通实验 0–4(水位线 / 文件页 / 匿名页+swap /
> stacktrace / function tracer),输出与下文一致;实验 5–6 的脚本与结论此前同环境已验证。

本教程里的所有命令和输出都在这套环境里实际跑过,文中贴的输出是真实抓到的,
包括几个**会失败的坑**(比如 function_graph 会把内核打崩),也一并写在里面。

---

## 目录

- [一、原理速览:内存回收到底在干什么](#一原理速览内存回收到底在干什么)
- [二、实验环境搭建](#二实验环境搭建)
- [三、实验 0:先看懂水位线](#三实验-0先看懂水位线)
- [四、实验 1:文件页回收(kswapd 主场)](#四实验-1文件页回收kswapd-主场)
- [五、实验 2:匿名页回收与换出(swap)](#五实验-2匿名页回收与换出swap)
- [六、实验 3:谁触发了直接回收(stacktrace 触发器)](#六实验-3谁触发了直接回收stacktrace-触发器)
- [七、实验 4:回收路径的函数调用关系(function tracer)](#七实验-4回收路径的函数调用关系function-tracer)
- [八、实验 5:swappiness 到底影响了什么](#八实验-5swappiness-到底影响了什么)
- [九、实验 6:回收失败之后 —— OOM](#九实验-6回收失败之后--oom)
- [十、tracepoint 字段速查表](#十tracepoint-字段速查表)
- [十一、踩坑记录(重要)](#十一踩坑记录重要)
- [十二、文件清单](#十二文件清单)

---

## 一、原理速览:内存回收到底在干什么

### 1.1 三条水位线决定"什么时候回收"

每个 zone 有三条水位线(单位是页),内核用它们判断内存紧张程度:

```
free 内存
  ↑
  │  ........ high  ← kswapd 回收到这里就可以睡了
  │  ........ low   ← 分配时发现 free < low,唤醒 kswapd(后台异步回收)
  │  ........ min   ← free < min,分配者自己下场同步回收(direct reclaim)
  └──────────────── 0   ← 回收也拿不到页 → OOM
```

- **后台回收(kswapd)**:`wakeup_kswapd()` 把 `kswapd0` 内核线程叫醒,
  它跑 `balance_pgdat()` 一直回收到 free > high 再睡。应用程序不阻塞。
- **直接回收(direct reclaim)**:分配路径 `__alloc_pages_nodemask()` 拿不到页,
  只能在**申请者自己的上下文里**调 `__perform_reclaim() → try_to_free_pages()` 同步回收。
  这条路径会让应用卡住,是延迟毛刺的常见来源,也是我们重点要观察的对象。

对应源码(本仓库 5.0 内核):

```3937:3972:mm/vmscan.c
void wakeup_kswapd(struct zone *zone, gfp_t gfp_flags, int order,
		   enum zone_type classzone_idx)
{
	pg_data_t *pgdat;
	...
	/* Hopeless node, leave it to direct reclaim if possible */
	if (pgdat->kswapd_failures >= MAX_RECLAIM_RETRIES ||
	    (pgdat_balanced(pgdat, order, classzone_idx) &&
	     !pgdat_watermark_boosted(pgdat, classzone_idx))) {
		...
		return;
	}

	trace_mm_vmscan_wakeup_kswapd(pgdat->node_id, classzone_idx, order,
				      gfp_flags);
	wake_up_interruptible(&pgdat->kswapd_wait);
}
```

### 1.2 回收谁:四条 LRU 链表

内核把可回收页挂在每个 node 的 LRU 链表上,一共四条(外加一条 unevictable):

| LRU | 内容 | 怎么回收 |
| --- | --- | --- |
| `inactive_file` / `active_file` | page cache、文件映射页 | 干净页直接丢弃;脏页先 `pageout()` 回写 |
| `inactive_anon` / `active_anon` | 堆、栈、匿名 mmap、tmpfs | 必须先写到 swap(没有 swap 就回收不了) |

回收总是**从 inactive 链表尾部**下手;active 链表上的页要先被"降级"(deactivate)
到 inactive 才有机会被回收 —— 这就是 `mm_vmscan_lru_shrink_active` 事件和
vmstat 里 `pgdeactivate`/`pgrefill` 的含义。

除了 LRU,还有 **slab shrinker**(dentry/inode 等内核对象缓存),
由 `shrink_slab()` 驱动,对应 `mm_shrink_slab_start/end` 事件。

### 1.3 调用链全景

这张图是**实验 4 用 ftrace 实测出来的**(不是照着源码抄的):

```
                    ┌── 后台回收 ────────────────────────────┐
kswapd()                                                     │
  └─ balance_pgdat()                                         │
       └─ kswapd_shrink_node()                               │
            └─ shrink_node() ───────────────┐                │
                                            │                │
                    ┌── 直接回收 ───────────┤                │
__alloc_pages_nodemask()                    │                │
  └─ __perform_reclaim()                    │                │
       └─ try_to_free_pages()               │                │
            └─ do_try_to_free_pages()       │                │
                 └─ shrink_zones()          │                │
                      └─ shrink_node() ─────┘                │
                                            │                │
                                            ▼                │
                          shrink_node_memcg()                │
                            ├─ get_scan_count()   ← swappiness 在这里起作用
                            └─ shrink_list()                 │
                                 ├─ shrink_active_list()  (降级 active → inactive)
                                 └─ shrink_inactive_list()
                                      └─ shrink_page_list()  ← 真正干活的地方
                                           ├─ __remove_mapping()  (从 page cache 摘掉)
                                           └─ pageout()           (脏页回写 / 换出)
                          shrink_slab() ──────────────────────┘
                            └─ do_shrink_slab()  (dentry/inode 等)
```

源码位置(`mm/vmscan.c`): `balance_pgdat():3534`、`kswapd_shrink_node():3486`、
`shrink_node():2691`、`shrink_node_memcg():2485`、`get_scan_count():2282`、
`shrink_inactive_list()`、`shrink_page_list():1100`、`pageout():804`、
`__remove_mapping():879`、`shrink_slab():680`。
直接回收入口在 `mm/page_alloc.c:3920 __perform_reclaim()`。

### 1.4 内核给我们准备好的 tracepoint

```
/sys/kernel/debug/tracing/events/vmscan/
├── mm_vmscan_wakeup_kswapd            谁把 kswapd 叫醒了
├── mm_vmscan_kswapd_wake              kswapd 开始干活
├── mm_vmscan_kswapd_sleep             kswapd 回去睡觉(说明已经回收到 high 水位)
├── mm_vmscan_direct_reclaim_begin     进入直接回收(应用被卡住的起点)
├── mm_vmscan_direct_reclaim_end       退出直接回收,带回收了多少页
├── mm_vmscan_lru_isolate              从 LRU 摘了多少页下来准备回收
├── mm_vmscan_lru_shrink_inactive      inactive 链表回收结果(最有信息量的事件)
├── mm_vmscan_lru_shrink_active        active 链表降级结果
├── mm_vmscan_inactive_list_is_low     判断 inactive 是否太短(要不要从 active 补)
├── mm_vmscan_writepage                回收时把页写出去(脏文件页回写 / 匿名页换出)
├── mm_shrink_slab_start / _end        slab shrinker 的每一次调用
```

---

## 二、实验环境搭建

### 2.1 为什么要专门加一个 `arm64_mm` 模式

默认的 `./run_busybox.sh arm64` 有两个问题,导致**根本抓不到回收**:

1. rootfs 是编进内核的 initramfs(tmpfs),没有块设备 → 没有文件页可回收;
2. 没有 swap → 匿名页也回收不了。

结果就是 kswapd 被叫醒后扫一圈发现无页可回收,立刻又睡了,trace 里只有孤零零三条:

```
memhog-131  mm_vmscan_wakeup_kswapd: nid=0 zid=0 order=0 gfp_flags=none
kswapd0-32  mm_vmscan_kswapd_wake: nid=0 zid=0 order=0
kswapd0-32  mm_vmscan_kswapd_sleep: nid=0
```

所以 `run_busybox.sh` 里新增了 `arm64_mm` 模式,相对默认模式多了三样东西:

| 项目 | 值 | 作用 |
| --- | --- | --- |
| 内存 | `-m 256`(实际可用约 210MB) | 刻意压小,几十 MB 负载就能压到水位线 |
| `/dev/vda` | 512MB 数据盘(`mm_data.img`) | 格式化 ext4,放大文件 → 产生 page cache |
| `/dev/vdb` | 256MB swap 盘(`mm_swap.img`) | `mkswap`+`swapon` → 匿名页才能被换出 |

两块盘都带 `serial=`(`mmdata`/`mmswap`),脚本按 serial 认盘,
不依赖 `vda`/`vdb` 的枚举顺序(virtio-mmio 上这个顺序是会变的)。

### 2.2 宿主机:编译 memhog 并启动虚拟机

```bash
cd /home/doula/project/runninglinuxkernel_5.0

# 交叉编译内存压力工具(静态链接,VM 里没有 gcc)
cd kmodules/mm_lab && make && cd ../..
# aarch64-linux-gnu-gcc -static -O2 -o memhog memhog.c

# 启动内存实验专用虚拟机(第一次会自动创建两个磁盘镜像)
./run_busybox.sh arm64_mm
```

`kmodules/` 会通过 9p 挂到 VM 的 `/mnt`,所以 `memhog` 和脚本在 VM 里就是
`/mnt/mm_lab/memhog`、`/mnt/mm_lab/scripts/*.sh`,改完宿主机文件立即生效,不用重编内核。

退出 QEMU:`Ctrl+A` 然后按 `X`。

### 2.3 虚拟机内:一次性初始化

```sh
sh /mnt/mm_lab/scripts/mm_setup.sh
```

它做三件事:确认 tracefs → 把数据盘格式化成 ext4 并生成 192MB 的 `/data/bigfile`
→ 把 swap 盘 `mkswap` + `swapon`。输出:

```
data disk = /dev/vda , swap disk = /dev/vdb
=== [1/3] mount tracefs ===
tracefs ready: /sys/kernel/debug/tracing
=== [2/3] prepare data disk (/dev/vda -> /data) ===
生成 192MB 测试文件 /data/bigfile ...
201326592 bytes (192.0MB) copied, 3.616897 seconds, 53.1MB/s
=== [3/3] prepare swap (/dev/vdb) ===
Filename        Type       Size    Used  Priority
/dev/vdb        partition  262140  0     -2

=== 环境就绪 ===
              total        used        free      shared  buff/cache   available
Mem:         215564       27140      184440        3844        3984      186680
Swap:        262140           0      262140
```

> 磁盘镜像和 `/data/bigfile` 会保留在宿主机的 `mm_data.img` 里,
> 重启 VM 后再跑一次 `mm_setup.sh` 只需要几秒(检测到已格式化就跳过)。

---

## 三、实验 0:先看懂水位线

```sh
sh /mnt/mm_lab/scripts/show_watermark.sh
```

```
page size = 4096 bytes

Node 0, zone DMA32    free=46077    min=382     low=477     high=572      (充足)

--- /proc/meminfo 关键项 ---
MemTotal:         215564 kB
MemFree:          184260 kB
Cached:             3844 kB
Active(anon):       2704 kB
Inactive(anon):     1336 kB
Active(file):        148 kB
Inactive(file):        4 kB
SwapTotal:        262140 kB

--- kswapd 状态 ---
pid=32 state=S  (S=睡眠 R=运行 D=不可中断)
```

**怎么读**:本机只有一个 `DMA32` zone,min/low/high = 382/477/572 页
(约 1.5MB / 1.9MB / 2.2MB)。空闲 46077 页远高于 high,所以 `kswapd0` 处于 `S`(睡眠)。
后面每个实验都可以回来跑一次这个脚本,对照"free 掉到哪条线以下"和"kswapd 是不是在跑"。

> 小知识:水位线由 `min_free_kbytes` 推导。想让回收更早触发,可以
> `echo 8192 > /proc/sys/vm/min_free_kbytes` 再看这三个值的变化。

---

## 四、实验 1:文件页回收(kswapd 主场)

### 4.1 做什么

顺序读一个比内存还大的文件(192MB 文件 vs 210MB 内存,加上内核自己的占用必然放不下)。
读进来的都是**干净的文件页**,是最容易回收的一类:直接从 page cache 摘掉就行,不用写盘。

### 4.2 命令

```sh
sh /mnt/mm_lab/scripts/drop_caches.sh                                    # 回到干净起点
sh /mnt/mm_lab/scripts/trace_reclaim.sh "cat /data/bigfile > /dev/null" /tmp/exp1.trace
```

`trace_reclaim.sh` 做的事情等价于手工敲:

```sh
cd /sys/kernel/debug/tracing
echo nop > current_tracer          # 不用函数追踪器,只要事件
echo > trace                       # 清空 ring buffer
echo 4096 > buffer_size_kb         # 每 CPU 4MB,防止事件被冲掉
echo 1 > events/vmscan/enable      # 打开 vmscan 这一整组 tracepoint
echo 1 > tracing_on
cat /data/bigfile > /dev/null      # 负载
echo 0 > tracing_on
cp trace /tmp/exp1.trace
echo 0 > events/enable
```

### 4.3 实测结果

```
=== ftrace 事件统计 (/tmp/exp1.trace) ===
mm_shrink_slab_end                       96
mm_shrink_slab_start                     96
mm_vmscan_direct_reclaim_begin            4
mm_vmscan_direct_reclaim_end              4
mm_vmscan_inactive_list_is_low          170
mm_vmscan_kswapd_wake                    15
mm_vmscan_lru_isolate                   232
mm_vmscan_lru_shrink_inactive           232
mm_vmscan_wakeup_kswapd                  14

=== 回收统计口径 (/proc/vmstat 差值) ===
allocstall_normal                          +1
pgactivate                                +19
pgsteal_kswapd                          +5603
pgsteal_direct                           +238
pgscan_kswapd                           +5608
pgscan_direct                            +238
slabs_scanned                           +1301
kswapd_low_wmark_hit_quickly              +11
kswapd_high_wmark_hit_quickly              +3
```

### 4.4 逐条解读

**结论先行**:共回收 5841 页(约 23MB),其中 **96% 是 kswapd 后台干的**
(`pgsteal_kswapd 5603` vs `pgsteal_direct 238`)。这正是健康系统该有的样子 ——
应用几乎没被阻塞。具体页数每次会随启动时机波动,但"kswapd 占绝对主力"这条结论稳定。

`pgscan_kswapd ≈ pgsteal_kswapd`(5608 vs 5603):**回收效率接近 100%**。
因为负载主要是干净文件页,`shrink_page_list()` 摘掉就完事。
后面实验 2 你会看到这个比值明显变差。

再看几条原始事件(来自本次抓到的 `/tmp/exp1.trace`):

```
cat-189     [000] d... 10.544914: mm_vmscan_wakeup_kswapd: nid=0 zid=1 order=1
                                  gfp_flags=GFP_NOWAIT|__GFP_NOWARN|__GFP_NORETRY|__GFP_COMP|__GFP_RECLAIMABLE
kswapd0-32  [001] .... 10.547856: mm_vmscan_kswapd_wake: nid=0 zid=1 order=1
```

`cat` 进程在分配页时发现 free 掉到 low 以下 → 唤醒 kswapd。
注意**唤醒者是应用进程,回收者是 kswapd**,两条记录的 TASK 列不一样,这就是"异步"。

```
kswapd0-32  [001] d... 10.557115: mm_vmscan_lru_isolate: isolate_mode=0 classzone=1 order=0
                                  nr_requested=13 nr_scanned=13 nr_skipped=0 nr_taken=13
                                  lru=inactive_file
kswapd0-32  [001] .... 10.557341: mm_vmscan_lru_shrink_inactive: nid=0 nr_scanned=13
                                  nr_reclaimed=13 nr_dirty=0 nr_writeback=0 nr_congested=0
                                  nr_immediate=0 nr_activate=0 nr_ref_keep=0 nr_unmap_fail=0
                                  priority=11 flags=RECLAIM_WB_FILE|RECLAIM_WB_ASYNC
```

- `lru=inactive_file`:回收对象是 inactive 文件页链表,符合预期。
- `nr_scanned=13 / nr_reclaimed=13`:扫 13 个回收 13 个。
- `nr_dirty=0 nr_writeback=0`:没有脏页,不用等回写 —— 干净页回收的典型特征。
- `priority=11`:从默认的 `DEF_PRIORITY=12` 已经往下降了一档。
  内存越紧张 priority 越往 0 降,扫描力度指数级放大。**看到 priority 变小 = 系统在挣扎**。
  本次 trace 里后续还能看到 priority 一路降到 8。
- `flags=RECLAIM_WB_FILE|RECLAIM_WB_ASYNC`:文件页、异步回收。

```
kswapd0-32  [001] .... 10.556230: mm_shrink_slab_start: super_cache_scan+0x0/0x2f8 :
                                  nid: 0 objects to shrink 42 gfp_flags GFP_KERNEL
                                  cache items 87 delta 43 total_scan 85 priority 12
```

顺带回收 slab:`super_cache_scan` 是文件系统的 dentry/inode 缓存 shrinker,
`cache items 87`、本轮打算扫 `total_scan 85` 个对象。`slabs_scanned +1301` 与之对应。

### 4.5 动手改一改

- 把 `cat` 换成 `dd if=/data/bigfile of=/dev/null bs=1M count=64`,只读 64MB,
  看看 free 够的时候是不是**一条事件都抓不到**(这很重要,见踩坑第 1 条)。
- 边跑负载边在另一个终端 `watch -n1 sh /mnt/mm_lab/scripts/show_watermark.sh`,
  看 free 在 low/high 之间来回震荡、kswapd 在 `S`/`R` 之间跳。

---

## 五、实验 2:匿名页回收与换出(swap)

### 5.1 做什么

匿名页(malloc 出来的内存)没有后备文件,回收前必须先写进 swap。
用 `memhog` 分批申请 150MB 匿名内存,同时 page cache 里还压着刚读进来的文件页,
逼内核在两类页之间做取舍,并把匿名页真的换出去。

`memhog` 的关键设计(见 `memhog.c`):用 `mmap(MAP_ANONYMOUS)` 分配,
然后**逐页写 1 个字节**。不写不会触发缺页异常,内核不会真的给物理页,
只申请不写等于什么都没发生 —— 这是新手写内存压测最容易犯的错。

### 5.2 命令

```sh
sh /mnt/mm_lab/scripts/fill_cache.sh                                  # 先把 page cache 灌满
sh /mnt/mm_lab/scripts/trace_reclaim.sh "/mnt/mm_lab/memhog 150 3 16" /tmp/exp2.trace
#                                          分配150MB ↑  ↑持有3秒 ↑每步16MB
```

### 5.3 实测结果

```
=== ftrace 事件统计 ===
mm_shrink_slab_end                     3693
mm_shrink_slab_start                   3693
mm_vmscan_direct_reclaim_begin          206      ← 直接回收从个位数涨到 206 次
mm_vmscan_direct_reclaim_end            206
mm_vmscan_inactive_list_is_low         2724
mm_vmscan_kswapd_sleep                    1
mm_vmscan_kswapd_wake                    16
mm_vmscan_lru_isolate                  3777
mm_vmscan_lru_shrink_active             922      ← active 链表开始被降级
mm_vmscan_lru_shrink_inactive          2855
mm_vmscan_wakeup_kswapd                  11
mm_vmscan_writepage                   12196      ← 有页被写出去了

=== 回收统计口径 (/proc/vmstat 差值) ===
nr_vmscan_write                        +12196
pswpout                                +12194    ← 约 47MB 匿名页换出到 swap
pswpin                                   +177    ← 还换回来 177 页
pgpgout                                +48784
allocstall_normal                        +197    ← 直接回收次数,和事件数对得上
pgdeactivate                           +24638    ← active → inactive 降级
pgrefill                               +24667    ← 扫描 active 链表的页数
pgsteal_kswapd                         +44068
pgsteal_direct                          +9428
pgscan_kswapd                          +52724
pgscan_direct                          +13110
kswapd_low_wmark_hit_quickly               +8
kswapd_high_wmark_hit_quickly              +7
```

### 5.4 逐条解读

**和实验 1 最大的三个区别**:

1. **出现了 `mm_vmscan_writepage` / `pswpout`**。匿名页被写进了 swap
   (`pswpout +12194`,约 47MB):

```
# 配套的降级事件(本次 trace),flags 已是 RECLAIM_WB_ANON:
kswapd0-32  [000] .... 13.031693: mm_vmscan_lru_shrink_active: nid=0 nr_taken=32
                                  nr_active=0 nr_deactivated=32 nr_referenced=32
                                  priority=12 flags=RECLAIM_WB_ANON|RECLAIM_WB_ASYNC
```

`RECLAIM_WB_ANON` 表明走的是匿名页路径(文件页回写会是 `RECLAIM_WB_FILE`)。
`pswpin +177` 说明换出去的页又被访问到、换了回来 —— 这就是 swap 抖动的雏形。

2. **`mm_vmscan_lru_shrink_active` 出现了 922 次**,`pgdeactivate` 高达 24638:

`nr_taken=32` 摘了 32 个,`nr_deactivated=32` 全部降级到 inactive。
`nr_referenced=32` 说明这些页最近还被访问过(PTE 的 Accessed 位是 1),
但**匿名页即使被引用过,第一次扫描也只是降级而不是留在 active** —— 这是二次机会算法。
实验 1 里 inactive 文件页管够,压根不需要动 active 链表,所以一次都没出现。

3. **直接回收暴涨到 206 次**(`allocstall_normal +197`),
   而且 `pgscan_kswapd 52724 > pgsteal_kswapd 44068`:扫了 52724 页只回收到 44068 页,
   **回收效率约 84%**,不再是接近 100%。差的那部分就是"扫到了但回收不掉"的页
   (正在回写、被引用、被锁住、还在等 swap I/O)。

`mm_vmscan_kswapd_sleep` 出现 1 次 + `kswapd_high_wmark_hit_quickly +7`:
kswapd 有若干次很快摸到 high 水位,最后成功睡下 —— 说明这次压力最终被扛住了。

### 5.5 动手改一改

- `swapoff -a` 之后再跑一遍,`pswpout` 会变成 0,直接回收次数暴涨,
  最后大概率触发 OOM(那就是实验 6)。
- 把 `memhog 150 3 16` 改成 `memhog 150 3 150`(一次性申请),
  对比"分批申请"和"一次申请"下 kswapd 有没有机会插手。

---

## 六、实验 3:谁触发了直接回收(stacktrace 触发器)

### 6.1 做什么

前面只知道"发生了直接回收",但不知道**是哪条代码路径把系统逼到这一步的**。
ftrace 的 **event trigger** 可以在事件命中时顺带打一份内核栈,开销远小于函数追踪器。

### 6.2 命令

```sh
sh /mnt/mm_lab/scripts/fill_cache.sh
sh /mnt/mm_lab/scripts/trace_stack.sh mm_vmscan_direct_reclaim_begin \
   "/mnt/mm_lab/memhog 160 1 16 >/dev/null" /tmp/exp3.stack
```

手工等价命令:

```sh
cd /sys/kernel/debug/tracing
echo stacktrace > events/vmscan/mm_vmscan_direct_reclaim_begin/trigger
echo 1 > events/vmscan/mm_vmscan_direct_reclaim_begin/enable
echo 1 > tracing_on
/mnt/mm_lab/memhog 160 1 16 > /dev/null
echo 0 > tracing_on
cat trace
echo '!stacktrace' > events/vmscan/mm_vmscan_direct_reclaim_begin/trigger   # 记得摘掉
```

### 6.3 实测结果

```
=== 第一条 mm_vmscan_direct_reclaim_begin 的调用栈 ===
 => try_to_free_pages
 => __perform_reclaim
 => __alloc_pages_nodemask
 => alloc_pages_vma
 => do_anonymous_page
 => handle_pte_fault
 => __handle_mm_fault
 => handle_mm_fault
 => __do_page_fault
 => do_page_fault
 => do_translation_fault
 => do_mem_abort
 => el0_da

=== 命中次数: 203 ===
```

### 6.4 解读

这份栈把**用户态一次简单的内存写操作**如何一路走到内存回收,完整串起来了:

| 栈帧 | 含义 |
| --- | --- |
| `el0_da` | ARM64 从 EL0(用户态)进入的 data abort 异常入口 |
| `do_mem_abort` / `do_translation_fault` | ARM64 异常分发,判定是缺页 |
| `do_page_fault` → `handle_mm_fault` | 进入通用缺页处理 |
| `handle_pte_fault` → `do_anonymous_page` | 这是一次**匿名页**缺页(memhog 写自己的 mmap 区) |
| `alloc_pages_vma` → `__alloc_pages_nodemask` | 伙伴系统分配物理页 |
| `__perform_reclaim` → `try_to_free_pages` | 快路径拿不到页,**在缺页上下文里同步回收** |

所以"应用只是写了一个字节,却卡了几毫秒"这件事,根因就在这条栈上。
203 次命中意味着 memhog 在这次运行中被内存回收拦下 203 回。

把事件名换掉可以问不同的问题:

```sh
sh /mnt/mm_lab/scripts/trace_stack.sh mm_vmscan_writepage    "..."   # 谁在换页出去
sh /mnt/mm_lab/scripts/trace_stack.sh mm_vmscan_wakeup_kswapd "..."  # 谁在叫醒 kswapd
```

---

## 七、实验 4:回收路径的函数调用关系(function tracer)

### 7.1 做什么

用函数追踪器把 `mm/vmscan.c` 里那十几个核心函数的调用次数和调用关系实测出来。

**这里有个大坑,先说结论**:本内核用 `-O0` 编译(顶层 `Makefile` 里强制加的,
为了 GDB 调试时不出现 `<optimized out>`),导致

1. 不加过滤直接 `echo function_graph > current_tracer`,插桩点太多,
   QEMU(TCG 纯软件模拟)会被拖到**几分钟没有任何输出**,基本等于死机;
2. 即使用 `set_ftrace_filter` 把范围缩到十几个函数,只要回收路径真的被执行到,
   arm64 上的 `function_graph` **返回钩子会踩崩内核**:

```
Unable to handle kernel NULL pointer dereference at virtual address 0000000000000000
Internal error: Oops: 86000004 [#4] SMP
pc :           (null)
lr :           (null)
Call trace:
           (null)
Code: bad PC value
---[ end trace ... ]---
Fixing recursive fault but reboot is needed!
```

这个崩溃在本环境里**可稳定复现**。所以本实验改用 `function` 追踪器:
它只在函数入口打点、不改写返回地址,没有返回栈可以踩坏,并且输出里自带
`被调用者 <-调用者`,一样能还原调用关系。

### 7.2 命令

```sh
sh /mnt/mm_lab/scripts/fill_cache.sh
sh /mnt/mm_lab/scripts/trace_func.sh "/mnt/mm_lab/memhog 160 1 16 >/dev/null" /tmp/exp4.func
```

关键是**先缩小插桩范围,再切 tracer**,顺序反了就会卡死:

```sh
cd /sys/kernel/debug/tracing
echo nop > current_tracer
echo > set_ftrace_filter
for f in balance_pgdat kswapd_shrink_node shrink_node shrink_node_memcg \
         get_scan_count shrink_list shrink_active_list shrink_inactive_list \
         shrink_page_list pageout __remove_mapping shrink_slab \
         __perform_reclaim try_to_free_pages do_try_to_free_pages \
         shrink_zones wakeup_kswapd; do
        echo $f >> set_ftrace_filter
done
echo function > current_tracer      # ← 一定在设完 filter 之后
echo 1 > tracing_on
...负载...
echo 0 > tracing_on
echo nop > current_tracer; echo > set_ftrace_filter   # 用完立刻复位
```

### 7.3 实测结果

```
=== 各函数调用次数 ===
__remove_mapping                40319
wakeup_kswapd                   14588
shrink_list                      1648
shrink_page_list                 1632
shrink_inactive_list             1632
shrink_slab                       598
shrink_node_memcg                 598
shrink_node                       598
get_scan_count                    598
shrink_zones                      534
shrink_active_list                425
try_to_free_pages                 128
do_try_to_free_pages              128
__perform_reclaim                 128
kswapd_shrink_node                 64
balance_pgdat                       3

=== 调用关系(被调用者 <- 调用者)===
  40319 __remove_mapping <-shrink_page_list
  14584 wakeup_kswapd <-wake_all_kswapds
   1648 shrink_list <-shrink_node_memcg
   1632 shrink_page_list <-shrink_inactive_list
   1632 shrink_inactive_list <-shrink_list
    598 shrink_slab <-shrink_node
    598 shrink_node_memcg <-shrink_node
    598 get_scan_count <-shrink_node_memcg
    534 shrink_zones <-do_try_to_free_pages
    534 shrink_node <-shrink_zones
    351 shrink_active_list <-shrink_node_memcg
    128 try_to_free_pages <-__perform_reclaim
    128 do_try_to_free_pages <-try_to_free_pages
    128 __perform_reclaim <-__alloc_pages_nodemask
     64 shrink_node <-kswapd_shrink_node
     64 kswapd_shrink_node <-balance_pgdat
     60 shrink_active_list <-age_active_anon
     14 shrink_active_list <-shrink_list
      4 wakeup_kswapd <-get_page_from_freelist
      3 balance_pgdat <-kswapd
```

### 7.4 解读

这张表就是第 1.3 节那张调用链图的**实测版本**,几个值得琢磨的点:

- **`shrink_node` 有两个上游**:`shrink_zones`(直接回收)534 次
  vs `kswapd_shrink_node`(后台回收)64 次。两条路最终汇合到同一个 `shrink_node()`,
  区别只在于 `scan_control` 的参数和执行上下文。
- **`__remove_mapping` 40319 次**远超其它函数:它是把页从 page cache/swap cache
  真正摘下来的那一步,每回收一页就调一次,所以次数 ≈ 回收页数。
- **`pageout` 在本次过滤列表里调用次数为 0**(未出现在统计中):说明这次绝大部分页
  要么是干净文件页(直接丢),要么走的是 swap 批量写路径,真正走 `pageout()` 逐页回写的很少。
- **`shrink_active_list` 有三个调用者**:`shrink_node_memcg`(常规降级)351 次、
  `age_active_anon`(专门给匿名页做老化)60 次、`shrink_list` 14 次。
  `age_active_anon` 的存在解释了"为什么没人回收匿名页时,active_anon 也会被扫"。
- **`wakeup_kswapd` 14588 次**看着吓人,其实是 `wake_all_kswapds()` 在
  分配慢路径里对每个 zone 都喊一嗓子,`wakeup_kswapd()` 内部会判断
  已经均衡就直接返回(见 1.1 节源码),真正产生 tracepoint 的只有少数几次。
  **这是个很好的提醒:函数被调用 ≠ 真的干活了,要结合 tracepoint 一起看。**

---

## 八、实验 5:swappiness 到底影响了什么

### 8.1 原理

`get_scan_count()`(`mm/vmscan.c:2282`)决定这一轮扫描里
anon 和 file 两条 LRU 各扫多少页,`vm.swappiness` 就是这里的权重:

```2297:2313:mm/vmscan.c
	/* If we have no swap space, do not bother scanning anon pages. */
	if (!sc->may_swap || mem_cgroup_get_nr_swap_pages(memcg) <= 0) {
		scan_balance = SCAN_FILE;
		goto out;
	}

	/*
	 * Global reclaim will swap to prevent OOM even with no
	 * swappiness, but memcg users want to use this knob to
	 * disable swapping for individual groups completely when
	 * using the memory controller's swap limit feature would be
	 * too expensive.
	 */
	if (!global_reclaim(sc) && !swappiness) {
		scan_balance = SCAN_FILE;
		goto out;
	}
```

注意注释里那句 **"Global reclaim will swap to prevent OOM even with no swappiness"**:
全局回收下 `swappiness=0` 只是"尽量别换",不是"绝对不换"。下面就来验证这句话。

### 8.2 负载怎么设计(这一步比命令重要)

第一版实验我直接跑 `memhog`,三种 swappiness 下 `pswpout` 全是 **0**,毫无区别。
原因是文件页管够,内核**根本不需要动匿名页**,swappiness 就没有用武之地。

必须制造**匿名页常驻 + 同时还有文件页需求**的竞争场面:后台 `memhog` 长时间持有
160MB 匿名内存,前台反复读 192MB 大文件抢内存,内核才被迫在两类页之间做选择。

### 8.3 命令与结果

```sh
sh /mnt/mm_lab/scripts/swappiness_test.sh 160
```

```
=========== vm.swappiness = 0 ===========
  pswpout        (换出匿名页) : 2934 页
  pgsteal_kswapd (后台回收)   : 143597 页
  pgsteal_direct (直接回收)   : 7138 页

=========== vm.swappiness = 100 ===========
  pswpout        (换出匿名页) : 4718 页
  pgsteal_kswapd (后台回收)   : 141375 页
  pgsteal_direct (直接回收)   : 9454 页
```

### 8.4 解读

- `swappiness` 从 0 提到 100,换出的匿名页从 2934 涨到 4718(**+61%**),
  方向和预期一致:值越大越倾向于换匿名页而不是丢文件页。
- 但 `swappiness=0` 时 `pswpout` **并不是 0**。这正好印证了源码注释:
  全局回收在文件页不够用时照样会动 swap,以避免 OOM。
  想要"绝对不换",只能 `swapoff`,或者在 memcg 里设 `swappiness=0`。
- 总回收量(pgsteal 之和)两种配置差不多,说明 swappiness **改变的是回收的构成,
  不是回收的总量** —— 内存该腾出来还得腾,只是从哪儿腾的区别。

想看得更细,可以在跑的同时开 `mm_vmscan_lru_isolate` 事件,
统计 `lru=inactive_anon` 与 `lru=inactive_file` 的条数比例:

```sh
grep -c 'lru=inactive_anon' /tmp/reclaim.trace
grep -c 'lru=inactive_file' /tmp/reclaim.trace
```

---

## 九、实验 6:回收失败之后 —— OOM

### 9.1 命令

```sh
sh /mnt/mm_lab/scripts/trace_oom.sh 400
```

它会 `swapoff -a`(匿名页彻底无处可去)→ 灌满 page cache → 申请 400MB(必然失败)。

### 9.2 实测结果(节选自 dmesg)

```
Node 0 active_anon:160280kB inactive_anon:9528kB active_file:12kB inactive_file:20kB
       ... all_unreclaimable? yes
Node 0 DMA32 free:1664kB min:3576kB low:3956kB high:4336kB ...
Free swap  = 0kB
Total swap = 0kB

Tasks state (memory values in pages):
[  pid  ]   uid  tgid total_vm      rss pgtables_bytes swapents oom_score_adj name
[    120]     0   120      573       56          40960        5             0 sh
[    376]     0   376    41155    39679         356352        0             0 memhog

oom-kill:constraint=CONSTRAINT_NONE,nodemask=(null),task=memhog,pid=376,uid=0
Out of memory: Kill process 376 (memhog) score 737 or sacrifice child
Killed process 376 (memhog) total-vm:164620kB, anon-rss:158708kB, file-rss:8kB
oom_reaper: reaped process 376 (memhog), now anon-rss:0kB
```

配套的统计:

```
allocstall_normal 1185      ← 直接回收被调用了上千次
allocstall_movable 580
pgsteal_direct 80139
回收事件条数: 3749
```

### 9.3 解读

- `free:1664kB` 已经**低于 min:3576kB**,分配路径必然走直接回收。
- `active_file:12kB inactive_file:20kB`:文件页已经被榨干,一滴不剩。
- `all_unreclaimable? yes` 是关键判断:**扫遍所有 LRU 也回收不出东西了**。
  内核这时才放弃重试,调 `out_of_memory()`。
- OOM 选人靠 `score`:`memhog` 的 RSS 是 39679 页,分数 737(满分 1000),
  远高于 `sh` 的 56 页,所以被选中。这就是 `oom_score_adj` 能干预的那个分数。
- `oom_reaper` 是异步回收被杀进程内存的内核线程,把 anon-rss 直接清零,
  避免被杀进程卡在退出路径上导致内存迟迟放不出来。

**跑完记得恢复 swap**,否则后续实验结果会不对:

```sh
for d in /sys/block/vd*; do
        [ "$(cat $d/serial)" = mmswap ] && swapon /dev/$(basename $d)
done
```

---

## 十、tracepoint 字段速查表

| 事件 | 关键字段 | 怎么用 |
| --- | --- | --- |
| `mm_vmscan_wakeup_kswapd` | `nid` `zid` `order` `gfp_flags` | 看是谁、为哪个 zone、申请多大的 order 叫醒了 kswapd |
| `mm_vmscan_kswapd_wake` / `_sleep` | `nid` `zid` `order` | 两条之间的时间差 = kswapd 本轮工作时长 |
| `mm_vmscan_direct_reclaim_begin` | `order` `may_writepage` `gfp_flags` `classzone_idx` | 直接回收起点;`may_writepage=1` 表示允许回写脏页 |
| `mm_vmscan_direct_reclaim_end` | `nr_reclaimed` | 与 begin 配对:**时间差 = 应用被卡住的时长** |
| `mm_vmscan_lru_isolate` | `nr_requested` `nr_scanned` `nr_skipped` `nr_taken` `lru` | `lru=` 区分 anon/file、active/inactive;`nr_skipped` 大说明目标 zone 不匹配 |
| `mm_vmscan_lru_shrink_inactive` | `nr_scanned` `nr_reclaimed` `nr_dirty` `nr_writeback` `nr_congested` `nr_immediate` `nr_activate` `nr_ref_keep` `priority` | 回收主战场。`nr_dirty`/`nr_writeback` 大 = 卡在回写;`nr_activate` 大 = 页太热被送回 active;`priority` 变小 = 越来越吃力 |
| `mm_vmscan_lru_shrink_active` | `nr_taken` `nr_deactivated` `nr_referenced` | active → inactive 的降级情况 |
| `mm_vmscan_writepage` | `pfn` `flags` | `RECLAIM_WB_ANON` = 换出到 swap;`RECLAIM_WB_FILE` = 脏文件页回写 |
| `mm_vmscan_inactive_list_is_low` | `nid` `reclaim_idx` `total_inactive` `inactive` `total_active` `active` `ratio` | inactive 太短时要从 active 补货的判断依据 |
| `mm_shrink_slab_start` / `_end` | shrinker 函数名 `cache items` `delta` `total_scan` `priority` / `unused scan count` `last shrinker return val` | 看是哪个 slab shrinker 在被调用、扫了多少对象 |

配套的 `/proc/vmstat` 计数器:

| 计数器 | 含义 |
| --- | --- |
| `pgscan_kswapd` / `pgscan_direct` | 分别由 kswapd / 直接回收扫描的页数 |
| `pgsteal_kswapd` / `pgsteal_direct` | 实际回收到的页数。**`pgsteal/pgscan` 就是回收效率** |
| `allocstall_*` | 直接回收发生的次数(按 zone 分),**这个值涨 = 应用在被拖慢** |
| `pswpout` / `pswpin` | 换出 / 换入的页数,swap 抖动看这两个 |
| `pgrefill` | 扫描 active 链表的页数 |
| `pgdeactivate` / `pgactivate` | active↔inactive 之间的迁移量 |
| `kswapd_low_wmark_hit_quickly` | kswapd 刚睡下又被低水位叫醒的次数,值大说明压力持续 |
| `nr_vmscan_write` | 回收过程中写出的页数 |

---

## 十一、踩坑记录(重要)

### 1. 抓不到任何回收事件

**最常见的问题,原因几乎都是内存还够用,内核压根不需要回收。**
本环境有 210MB 可用内存,你申请 100MB 是不会触发回收的。判断方法:

```sh
free                                                   # free 那一列还很大 = 不会回收
grep -E 'pgsteal_kswapd|pgsteal_direct' /proc/vmstat   # 跑前跑后没变化 = 确实没回收
```

解决:先 `sh /mnt/mm_lab/scripts/fill_cache.sh` 把 page cache 灌满,
再让负载申请超过剩余空闲的内存量。

### 2. function_graph 会把内核打崩

见第七节。现象是 `pc/lr = null` 的 Oops + `Fixing recursive fault but reboot is needed`。
根因是这个内核被强制 `-O0` 编译(`Makefile` 里 `KBUILD_CFLAGS += -O0`),
arm64 的 function_graph 返回地址钩子在回收路径下会踩坏返回栈。
**用 `function` 追踪器 + `set_ftrace_filter`,或者用 tracepoint 的 stacktrace 触发器代替。**

### 3. 切 tracer 之前一定要先设 filter

`echo function_graph > current_tracer` 或 `echo function > current_tracer` **不加过滤**,
在 -O0 内核 + QEMU TCG 下会让整机卡到几分钟无响应(实测等了 7 分钟仍无输出)。
顺序永远是:`set_ftrace_filter` → `current_tracer` → `tracing_on`。
用完立刻 `echo nop > current_tracer` 复位。

### 4. 事件太多把 ring buffer 冲掉了

`trace` 文件头部会写明:

```
# entries-in-buffer/entries-written: 35269/35269   #P:2
```

两个数字不相等就是丢事件了。解决:`echo 8192 > buffer_size_kb`(每 CPU 8MB),
或者缩短负载时间、只打开需要的那几个事件而不是 `events/vmscan/enable`。

### 5. 磁盘顺序不是固定的

virtio-mmio 上 `-device` 的先后顺序和 `/dev/vdX` 的编号**是反的**,
第一次调试时 512MB 的数据盘变成了 `/dev/vdb`。
脚本改成按 `/sys/block/vdX/serial` 认盘就不会错了。

### 6. 内核太慢导致时间读数失真

`-O0` 编译 + QEMU TCG 软件模拟,内核函数执行比真机慢一到两个数量级。
trace 里的**绝对耗时没有参考价值**,但事件的**顺序、次数、比例**是完全真实的。
要测真实延迟,请在物理机或 KVM 加速的环境上做。

---

## 十二、文件清单

宿主机 `kmodules/mm_lab/`(= VM 里的 `/mnt/mm_lab/`):

| 文件 | 作用 |
| --- | --- |
| `memhog.c` / `Makefile` | 内存压力工具,`make` 交叉编译出静态的 `memhog` |
| `scripts/mm_setup.sh` | 开机后一次性初始化:tracefs / 数据盘 / swap |
| `scripts/show_watermark.sh` | 打印 zone 水位线、meminfo 关键项、kswapd 状态 |
| `scripts/drop_caches.sh` | 清空 page cache,回到干净起点 |
| `scripts/fill_cache.sh` | 用大文件灌满 page cache,制造内存紧张 |
| `scripts/trace_reclaim.sh` | **主力脚本**:开 vmscan 事件跑负载,输出事件统计 + vmstat 差值 |
| `scripts/trace_stack.sh` | 给指定事件挂 stacktrace 触发器,抓触发回收的调用栈 |
| `scripts/trace_func.sh` | function tracer,统计回收路径的函数调用关系 |
| `scripts/swappiness_test.sh` | 对比 swappiness=0/100 下匿名页与文件页的取舍 |
| `scripts/trace_oom.sh` | 关 swap,观察回收失败到 OOM 的全过程 |
| `scripts/run_lab_host.py` | 可选:宿主机串口自动化,批量跑实验 0–4 并落盘日志 |

一次完整流程:

```bash
# 宿主机
cd /home/doula/project/runninglinuxkernel_5.0
(cd kmodules/mm_lab && make)
./run_busybox.sh arm64_mm
```

```sh
# 虚拟机内
sh /mnt/mm_lab/scripts/mm_setup.sh
sh /mnt/mm_lab/scripts/show_watermark.sh
sh /mnt/mm_lab/scripts/drop_caches.sh
sh /mnt/mm_lab/scripts/trace_reclaim.sh "cat /data/bigfile > /dev/null"       # 实验1
sh /mnt/mm_lab/scripts/fill_cache.sh
sh /mnt/mm_lab/scripts/trace_reclaim.sh "/mnt/mm_lab/memhog 150 3 16"         # 实验2
sh /mnt/mm_lab/scripts/trace_stack.sh mm_vmscan_direct_reclaim_begin \
   "/mnt/mm_lab/memhog 160 1 16 >/dev/null"                                   # 实验3
sh /mnt/mm_lab/scripts/trace_func.sh "/mnt/mm_lab/memhog 160 1 16 >/dev/null" # 实验4
sh /mnt/mm_lab/scripts/swappiness_test.sh 160                                 # 实验5
sh /mnt/mm_lab/scripts/trace_oom.sh 400                                       # 实验6
```

想把 trace 拿回宿主机分析,直接拷到 9p 共享目录即可:

```sh
cp /tmp/exp1.trace /mnt/mm_lab/     # 宿主机上就是 kmodules/mm_lab/exp1.trace
```
