# 第 3 站:nice 值、权重表与负载计算

## 学习目标

- 理解 Linux nice 值的范围和语义
- 掌握 nice → 权重的映射表 `sched_prio_to_weight[40]`
- 看懂"1.25 公比"设计如何保证 ±1 nice = ±10% CPU
- 理解 `__calc_delta()` 把除法变乘法的技巧

## 源码定位

| 内容 | 文件 | 行号 |
| --- | --- | --- |
| `sched_prio_to_weight[40]` 权重表 | `kernel/sched/core.c` | 7044 |
| `sched_prio_to_wmult[40]` 反权重表 | `kernel/sched/core.c` | 7062 |
| `set_load_weight()` 设置实体权重 | `kernel/sched/core.c` | 712 附近 |
| `__calc_delta()` 通用乘除运算 | `kernel/sched/fair.c` | 218 |
| `calc_delta_fair()` 实际时间→虚拟时间 | `kernel/sched/fair.c` | 627 |
| `NICE_0_LOAD` 等宏 | `include/linux/sched/prio.h` 等 | grep 即得 |

## 原理图解

### 1. nice 值的语义

Linux 提供 nice 值供用户调整任务"友善度":

- 范围:`[-20, +19]`,共 40 档
- nice 越**小**优先级越**高**(越不友善 ≈ 越霸道)
- 内核内部映射到 priority `[100, 139]`,即 `prio = nice + 120`(`MAX_RT_PRIO`)
- 普通用户只能调高 nice(让出 CPU);需要 `CAP_SYS_NICE` 才能降低

只有 nice 是 CFS 用户可见的旋钮,但 CFS 内部实际使用的是 nice 经过查表后得到
的 **weight**(权重)。

### 2. 权重表 `sched_prio_to_weight[40]`

`kernel/sched/core.c:7044`:

```c
const int sched_prio_to_weight[40] = {
 /* -20 */     88761,     71755,     56483,     46273,     36291,
 /* -15 */     29154,     23254,     18705,     14949,     11916,
 /* -10 */      9548,      7620,      6100,      4904,      3906,
 /*  -5 */      3121,      2501,      1991,      1586,      1277,
 /*   0 */      1024,       820,       655,       526,       423,
 /*   5 */       335,       272,       215,       172,       137,
 /*  10 */       110,        87,        70,        56,        45,
 /*  15 */        36,        29,        23,        18,        15,
};
```

注意三点:

- **nice=0 → weight=1024**,这就是宏 `NICE_0_LOAD` 的来源。
- 相邻两档**约**是 1.25 倍:`820 × 1.25 ≈ 1025`,`1024 / 1.25 ≈ 819`。
- 表是非线性的,nice 越小,绝对值跳跃越大(从 1024 跳到 88761,差 86 倍)。

### 3. 为什么是 1.25?

`kernel/sched/core.c:7029` 上方的注释解释了这个常数的物理意义:

> The "10% effect" of adjusting the nice value: ... if a task goes up by ~10%
> and another task goes down by ~10% then the relative distance between them
> is ~25%.

设想两个普通任务都是 nice=0,各占 50% CPU。把其中一个的 nice 加 1:
新的相对权重为 `820 : 1024 ≈ 44.5% : 55.5%`,即"亏的那个少了 10%,赚的那个多了
10%"。这就是用户感知的"nice 改 1 影响约 10% CPU"。

公比 = `(1 + 0.10) / (1 - 0.10) ≈ 1.222`,内核取 1.25 是为了让计算友好。

### 4. CPU 时间的分配公式

设 `cfs_rq->load.weight = W_total`,任务 i 的权重为 `w_i`,调度周期为 P,则:

```
任务 i 的目标时间片  s_i = P × w_i / W_total
```

实现见 `sched_slice()`(`kernel/sched/fair.c:657`):

```c
static u64 sched_slice(struct cfs_rq *cfs_rq, struct sched_entity *se)
{
    u64 slice = __sched_period(cfs_rq->nr_running + !se->on_rq);

    for_each_sched_entity(se) {
        struct load_weight *load = &cfs_rq->load;
        ...
        slice = __calc_delta(slice, se->load.weight, load);
    }
    return slice;
}
```

### 5. `__calc_delta()`:用乘法代替除法

`kernel/sched/fair.c:218`:

```c
/*
 * delta_exec * weight / lw.weight
 *   OR
 * (delta_exec * (weight * lw->inv_weight)) >> WMULT_SHIFT
 */
static u64 __calc_delta(u64 delta_exec, unsigned long weight,
                        struct load_weight *lw)
{
    u64 fact = scale_load_down(weight);
    int shift = WMULT_SHIFT;     /* 32 */

    __update_inv_weight(lw);
    ...
    fact = (u64)(u32)fact * lw->inv_weight;
    ...
    return mul_u64_u32_shr(delta_exec, fact, shift);
}
```

要算 `delta_exec × weight / lw.weight`,内核预先把 `1/lw.weight` 近似为
`inv_weight = 2^32 / lw.weight`,然后变成
`(delta_exec × weight × inv_weight) >> 32`。
ARM64 上整数除法需要数十周期,而 `mul_u64_u32_shr()` 只用一次 64×32 乘法+移位,
**性能上百倍提升**。

### 6. 设置权重:`set_load_weight()`

`kernel/sched/core.c:727`:

```c
load->weight     = scale_load(sched_prio_to_weight[prio]);
load->inv_weight = sched_prio_to_wmult[prio];
p->se.runnable_weight = load->weight;
```

也就是说 nice 改变时只是查表赋值,没有任何运行时除法。

### 7. `scale_load()` 与精度

`include/linux/sched/prio.h` 周边定义了:

```c
#ifdef CONFIG_64BIT
# define SCHED_FIXEDPOINT_SHIFT  10
# define scale_load(w)           ((w) << SCHED_FIXEDPOINT_SHIFT)
# define scale_load_down(w)      ((w) >> SCHED_FIXEDPOINT_SHIFT)
#else
# define scale_load(w)           (w)
# define scale_load_down(w)      (w)
#endif
```

64 位平台上 weight 被放大 1024 倍以提升组调度时的精度;32 位平台则不放大。
这就是 `NICE_0_LOAD` 在 64 位上等于 `1024 << 10 = 1048576` 的原因。

## 思考题

1. **公比验证**:用 Python 或计算器,计算 `sched_prio_to_weight[]` 表中相邻
   两项的比值,看看是不是严格的 1.25?偏差从哪里来?这会不会影响"±1 nice = ±10%
   CPU"的承诺?

2. **极端 nice**:若两个任务 A(nice=-20)、B(nice=19)同时跑,A 应当获得多少
   倍于 B 的 CPU?用权重表算一下,再用如下命令在 QEMU 中验证:
   ```bash
   # 启动两个 yes 进程,分别设置 nice
   nice -n -20 yes > /dev/null &
   nice -n 19  yes > /dev/null &
   top -d 1   # 观察两者的 %CPU 比例
   ```

3. **`inv_weight` 偏差**:对 nice=0,`weight=1024`,精确反值是 `2^32/1024 = 4194304`,
   表中也是 4194304(精确)。对 nice=-20,精确反值是 `2^32/88761 ≈ 48391.7`,
   表中是 48388。这个 3.7 的误差对最终时间分配影响是否可接受?写出最坏情况估算。

4. **`__calc_delta` 的右移**:当 fact 大于 2^32 时,代码会循环右移并递减 shift,
   最终调用 `mul_u64_u32_shr(delta_exec, fact, shift)`。如果 weight 极大(比如
   组调度场景下达到几百万),shift 会不会被减到负数?(提示:阅读注释中给的
   "shift >= 22" 的论证)

5. **改表实验**:如果你把 `sched_prio_to_weight[20]`(对应 nice=0)从 1024 改成
   2048,会发生什么?提示:这会破坏 `NICE_0_LOAD` 这个内核默认假设。grep
   `NICE_0_LOAD` 看有多少处依赖它。

6. **为什么不用浮点**:权重和虚拟时间为什么坚持用整数?(提示:内核态默认不
   保存 FPU 状态,且不同架构 FPU 行为不一致。)

---

⬅️ [上一站:核心数据结构](02_data_structures.md) ｜ ➡️ [下一站:vruntime](04_vruntime.md)
