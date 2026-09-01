# 第 5 站:红黑树与就绪队列管理

## 学习目标

- 理解 CFS 为什么选红黑树而不是堆或其他平衡树
- 看懂 `__enqueue_entity()` 的插入流程及 leftmost 维护
- 知道 `rb_root_cached` 把"取最小"变成 O(1) 的代价
- 区分"在树上"与"是 curr"两种实体状态

## 源码定位

| 函数 | 文件 | 行号 |
| --- | --- | --- |
| `__enqueue_entity()` | `kernel/sched/fair.c` | 530 |
| `__dequeue_entity()` | `kernel/sched/fair.c` | 560 |
| `__pick_first_entity()` | `kernel/sched/fair.c` | 565 |
| `__pick_next_entity()` | `kernel/sched/fair.c` | 575 |
| `__pick_last_entity()` | `kernel/sched/fair.c` | 586 |
| `entity_before()` | `kernel/sched/fair.c` | 489 |
| `rb_root_cached` 定义 | `include/linux/rbtree.h` | grep `rb_root_cached` |
| `rb_insert_color_cached()` | `include/linux/rbtree_augmented.h` 等 | grep |

## 原理图解

### 1. 为什么是红黑树

CFS 对就绪队列的需求:

| 操作 | 需求频率 | 红黑树性能 |
| --- | --- | --- |
| 取最小 vruntime | **极高**(每次调度) | O(1)(用 cached leftmost) |
| 插入新实体 | 高(每次唤醒) | O(log N) |
| 删除指定实体 | 高(每次出队) | O(log N) |
| 修改 key | 中等(随 vruntime 推进) | 等价于先删后插 |

候选数据结构对比:

| 候选 | 取最小 | 插入 | 任意删除 | 缺点 |
| --- | --- | --- | --- | --- |
| 二叉堆 | O(1) | O(log N) | **O(N)**(找位置) | 无法 O(log N) 任意删除 |
| AVL 树 | O(log N) → cached O(1) | O(log N) | O(log N) | 旋转更频繁,写多场景慢 |
| 红黑树 | cached O(1) | O(log N) | O(log N) | 平衡性比 AVL 略差但可接受 |
| 跳表 | O(1) | O(log N) | O(log N) | 内存开销大,无锁版本复杂 |

CFS 频繁删除任意位置的实体(被睡眠/被迁移),所以放弃了堆;红黑树常数因子
比 AVL 小,Linux 已有成熟的 rbtree 实现,因此成为唯一选项。

### 2. 红黑树的 key 是 vruntime

每个 `sched_entity` 通过内嵌的 `run_node` 挂在树上。比较函数就是 `entity_before`:

```c
/* fair.c:489 */
static inline int entity_before(struct sched_entity *a, struct sched_entity *b)
{
    return (s64)(a->vruntime - b->vruntime) < 0;
}
```

vruntime 越小越靠左。**最左节点 = 下一个最该跑的任务**。

### 3. `__enqueue_entity()` 详解

`kernel/sched/fair.c:530`:

```c
static void __enqueue_entity(struct cfs_rq *cfs_rq, struct sched_entity *se)
{
    struct rb_node **link = &cfs_rq->tasks_timeline.rb_root.rb_node;
    struct rb_node *parent = NULL;
    struct sched_entity *entry;
    bool leftmost = true;

    /* Find the right place in the rbtree: */
    while (*link) {
        parent = *link;
        entry = rb_entry(parent, struct sched_entity, run_node);
        /*
         * We dont care about collisions. Nodes with
         * the same key stay together.
         */
        if (entity_before(se, entry)) {
            link = &parent->rb_left;
        } else {
            link = &parent->rb_right;
            leftmost = false;     /* 一旦走右侧,就不可能成为最左了 */
        }
    }

    rb_link_node(&se->run_node, parent, link);
    rb_insert_color_cached(&se->run_node,
                           &cfs_rq->tasks_timeline, leftmost);
}
```

**关键点**:

- 标准的 BST 下行查找,vruntime 小的去左、大的去右
- 用一个布尔变量 `leftmost` 跟踪"一路是否始终走左",作为是否要更新缓存的提示
- `rb_insert_color_cached()` 内部既做颜色调整(平衡),又根据 `leftmost`
  原子地更新 `tasks_timeline.rb_leftmost`

**注意:同 vruntime 的实体不会合并**,它们按插入次序前后排列。这对边角场景
(批量唤醒、迁移)很重要。

### 4. `__dequeue_entity()` 与 leftmost 的更新

```c
static void __dequeue_entity(struct cfs_rq *cfs_rq, struct sched_entity *se)
{
    rb_erase_cached(&se->run_node, &cfs_rq->tasks_timeline);
}
```

只有一行!`rb_erase_cached()` 内部检查被删的是否是最左节点;若是,会把"它的
后继节点"提升为新的 leftmost,无需遍历整树。这就是 `rb_root_cached` 的价值。

### 5. `__pick_first_entity()` 是 O(1) 的

```c
struct sched_entity *__pick_first_entity(struct cfs_rq *cfs_rq)
{
    struct rb_node *left = rb_first_cached(&cfs_rq->tasks_timeline);
    if (!left) return NULL;
    return rb_entry(left, struct sched_entity, run_node);
}
```

`rb_first_cached()` 直接读 `tasks_timeline.rb_leftmost`,**不递归向左走**。
这是 CFS 调度路径的最热点函数之一。

### 6. "在树上" vs "是 curr" 的状态机

每个 sched_entity 在 CFS 中只可能处于以下三种状态之一:

```
                    enqueue_entity()
       NOT_ON_RQ ─────────────────────► ON_RQ_TREE  (在红黑树上,但不是 curr)
            ▲                               │
            │ dequeue_entity()              │ pick_next_entity()
            │                               ▼
            │            put_prev_entity()
            └─── ON_RQ_RUNNING ◄────────── ON_RQ_RUNNING
                  (curr,不在树上)
```

- `on_rq` 字段记录是否处于 ON_RQ_*(无论是树上还是 curr)
- `cfs_rq->curr` 字段记录是否正在跑
- `set_next_entity()`(`fair.c:4062`)从树上摘下并设为 curr
- `put_prev_entity()` 把 curr 重新插回树上

### 7. 树的形态举例

假设 cfs_rq 上有 5 个任务,vruntime 分别为 100、120、150、180、200:

```
           150 (黑)
          /      \
       120 (红)  180 (黑)
       /            \
     100 (黑)        200 (红)

leftmost(缓存)─────► 100
```

下次 `pick_next_entity()` 直接拿 100 这个节点,立即 `__dequeue_entity()`
摘掉,然后 `set_next_entity()` 设为 curr。整个过程 O(1)。

`__dequeue_entity` 后红黑树会自我调整,新的 leftmost 变成 120。

## 思考题

1. **leftmost 维护证明**:阅读 `__enqueue_entity()` 中 `leftmost` 变量的逻辑,
   证明:**"插入路径上一旦走过一次右子方向,就永远不可能成为新的最左节点"**。
   写出形式化论证。

2. **同 vruntime 处理**:如果 100 个任务同时被唤醒、且它们的 vruntime 完全相等,
   红黑树会变成什么形状?是不是退化成链表了?(提示:rbtree 里 `<` 和 `>=`
   分支不对称,即使 key 相等也会保持平衡。)

3. **删除最左节点的代价**:rbtree 删除最左节点之后,新 leftmost 总是它的右子?
   还是它父亲?画出几种情形(被删节点有/无右子)。

4. **改用堆?**:如果你强行把 CFS 的红黑树换成二叉堆,会破坏哪些功能?
   (提示:任务睡眠时如何 O(log N) 删除?任务迁移到其他 CPU 时如何处理?)

5. **GDB 观察树形**:在 `__enqueue_entity` 上设断点,用如下命令打印 cfs_rq 中的
   实体数量和 leftmost:
   ```gdb
   (gdb) p cfs_rq->nr_running
   (gdb) p ((struct sched_entity *)((char*)cfs_rq->tasks_timeline.rb_leftmost \
        - offsetof(struct sched_entity, run_node)))->vruntime
   ```
   持续 continue,观察 leftmost 如何随 vruntime 推进变化。

6. **缓存友好性**:`sched_entity` 在 `task_struct` 内嵌,而红黑树节点又嵌在
   `sched_entity` 中。这种"链式嵌入"对 CPU cache 友好吗?思考为什么内核
   不让 rbtree 节点指向独立分配的对象。

---

⬅️ [上一站:vruntime](04_vruntime.md) ｜ ➡️ [下一站:入队、出队、唤醒](06_enqueue_dequeue.md)
