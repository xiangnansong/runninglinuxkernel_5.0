#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/sched.h>
#include <linux/sched/signal.h>
#include <linux/timer.h>
#include <linux/proc_fs.h>
#include <linux/seq_file.h>
#include <linux/slab.h>
#include <linux/uaccess.h>
#include <linux/cputime.h>
#include <linux/ktime.h>
#include <linux/jiffies.h>
#include <linux/mutex.h>
#include <linux/hashtable.h>
#include <linux/sort.h>

#define MODULE_NAME "cpuloading_monitor"
#define DEFAULT_SAMPLE_INTERVAL_MS 1000
#define MAX_PROCESSES 4096
#define MAX_COMM_LEN 16

struct process_sample {
    int pid;
    char comm[MAX_COMM_LEN];
    u64 utime;
    u64 stime;
    u64 total_time;
    u64 timestamp_ms;
    u64 cpu_usage_percent;
    struct hlist_node hnode;
    struct list_head list;
};

struct sample_record {
    int pid;
    char comm[MAX_COMM_LEN];
    u64 timestamp_ms;
    u64 cpu_usage_percent;
    u64 utime_delta;
    u64 stime_delta;
    struct list_head list;
};

static int sample_interval_ms = DEFAULT_SAMPLE_INTERVAL_MS;
module_param(sample_interval_ms, int, 0644);
MODULE_PARM_DESC(sample_interval_ms, "Sampling interval in milliseconds");

static int monitor_pid = -1;
module_param(monitor_pid, int, 0644);
MODULE_PARM_DESC(monitor_pid, "Specific PID to monitor (-1 for all processes)");

static int max_records = 100000;
module_param(max_records, int, 0644);
MODULE_PARM_DESC(max_records, "Maximum number of sample records to keep");

static struct timer_list sample_timer;
static DEFINE_MUTEX(data_mutex);

static DECLARE_HASHTABLE(process_hash, 12);
static struct process_sample *process_data[MAX_PROCESSES];
static int process_count = 0;

static LIST_HEAD(sample_records);
static int record_count = 0;

static u64 last_sample_jiffies = 0;
static u64 total_sample_time_ms = 0;

static struct proc_dir_entry *proc_entry;
static struct proc_dir_entry *proc_entry_raw;
static struct proc_dir_entry *proc_entry_json;
static struct proc_dir_entry *proc_entry_csv;
static struct proc_dir_entry *proc_entry_clear;
static struct proc_dir_entry *proc_dir;

static u64 get_time_ms(void)
{
    return ktime_to_ms(ktime_get_real());
}

static u64 get_delta_time_ms(void)
{
    u64 now = jiffies;
    u64 delta;
    
    if (last_sample_jiffies == 0) {
        last_sample_jiffies = now;
        return sample_interval_ms;
    }
    
    delta = jiffies_to_msecs(now - last_sample_jiffies);
    last_sample_jiffies = now;
    
    return delta > 0 ? delta : sample_interval_ms;
}

static struct process_sample *find_or_create_process(int pid)
{
    struct process_sample *ps;
    unsigned int bucket = hash_min(pid, HASH_BITS(process_hash));
    
    hash_for_each_possible(process_hash, ps, hnode, bucket) {
        if (ps->pid == pid)
            return ps;
    }
    
    if (process_count >= MAX_PROCESSES)
        return NULL;
    
    ps = kzalloc(sizeof(*ps), GFP_ATOMIC);
    if (!ps)
        return NULL;
    
    ps->pid = pid;
    hash_add(process_hash, &ps->hnode, pid);
    process_data[process_count++] = ps;
    
    return ps;
}

static void add_sample_record(int pid, const char *comm, u64 timestamp_ms,
                              u64 cpu_usage, u64 utime_delta, u64 stime_delta)
{
    struct sample_record *rec;
    
    if (record_count >= max_records) {
        struct sample_record *old;
        if (!list_empty(&sample_records)) {
            old = list_first_entry(&sample_records, struct sample_record, list);
            list_del(&old->list);
            kfree(old);
            record_count--;
        }
    }
    
    rec = kzalloc(sizeof(*rec), GFP_ATOMIC);
    if (!rec)
        return;
    
    rec->pid = pid;
    strncpy(rec->comm, comm, MAX_COMM_LEN - 1);
    rec->timestamp_ms = timestamp_ms;
    rec->cpu_usage_percent = cpu_usage;
    rec->utime_delta = utime_delta;
    rec->stime_delta = stime_delta;
    
    list_add_tail(&rec->list, &sample_records);
    record_count++;
}

static void sample_processes(struct timer_list *t)
{
    struct task_struct *task;
    u64 delta_ms;
    u64 wall_time;
    u64 total_delta;
    u64 usage;
    
    mutex_lock(&data_mutex);
    
    delta_ms = get_delta_time_ms();
    total_sample_time_ms += delta_ms;
    wall_time = get_time_ms();
    
    for_each_process(task) {
        struct process_sample *ps;
        u64 utime, stime, total;
        u64 utime_delta, stime_delta, total_delta_task;
        u64 cpu_usage;
        
        if (monitor_pid != -1 && task->pid != monitor_pid)
            continue;
        
        ps = find_or_create_process(task->pid);
        if (!ps)
            continue;
        
        utime = task->utime;
        stime = task->stime;
        total = utime + stime;
        
        total_delta_task = total - ps->total_time;
        utime_delta = utime - ps->utime;
        stime_delta = stime - ps->stime;
        
        if (delta_ms > 0 && total_delta_task > 0) {
            cpu_usage = div64_u64(total_delta_task * 100000, delta_ms * 1000);
            if (cpu_usage > 100000)
                cpu_usage = 100000;
        } else {
            cpu_usage = 0;
        }
        
        if (ps->total_time > 0) {
            add_sample_record(task->pid, task->comm, wall_time,
                            cpu_usage, utime_delta, stime_delta);
        }
        
        ps->utime = utime;
        ps->stime = stime;
        ps->total_time = total;
        ps->timestamp_ms = wall_time;
        ps->cpu_usage_percent = cpu_usage;
        
        if (monitor_pid != -1)
            break;
    }
    
    mutex_unlock(&data_mutex);
    
    mod_timer(&sample_timer, jiffies + msecs_to_jiffies(sample_interval_ms));
}

static int cpuloading_show(struct seq_file *m, void *v)
{
    struct sample_record *rec;
    u64 sample_count = 0;
    u64 avg_cpu = 0;
    u64 max_cpu = 0;
    int target_pid = monitor_pid;
    
    mutex_lock(&data_mutex);
    
    seq_printf(m, "=== CPU Loading Monitor Statistics ===\n");
    seq_printf(m, "Sample interval: %d ms\n", sample_interval_ms);
    seq_printf(m, "Monitored PID: %d %s\n", target_pid, 
               target_pid == -1 ? "(all processes)" : "");
    seq_printf(m, "Total sample time: %llu ms\n", total_sample_time_ms);
    seq_printf(m, "Total records: %d\n", record_count);
    seq_printf(m, "Process count: %d\n", process_count);
    seq_printf(m, "\n");
    
    if (target_pid != -1) {
        seq_printf(m, "=== Process PID %d Statistics ===\n", target_pid);
        list_for_each_entry(rec, &sample_records, list) {
            if (rec->pid == target_pid) {
                sample_count++;
                avg_cpu += rec->cpu_usage_percent;
                if (rec->cpu_usage_percent > max_cpu)
                    max_cpu = rec->cpu_usage_percent;
            }
        }
        if (sample_count > 0) {
            avg_cpu = div64_u64(avg_cpu, sample_count);
            seq_printf(m, "Sample count: %llu\n", sample_count);
            seq_printf(m, "Average CPU: %llu.%02llu%%\n", 
                      avg_cpu / 1000, (avg_cpu % 1000) / 10);
            seq_printf(m, "Max CPU: %llu.%02llu%%\n", 
                      max_cpu / 1000, (max_cpu % 1000) / 10);
        }
    } else {
        seq_printf(m, "=== Top 10 CPU Usage Processes ===\n");
        seq_printf(m, "%-8s %-16s %10s %10s %10s\n", 
                  "PID", "COMM", "AVG_CPU%", "MAX_CPU%", "SAMPLES");
        
        {
            int i;
            for (i = 0; i < process_count && i < 10; i++) {
                struct process_sample *ps = process_data[i];
                if (ps) {
                    seq_printf(m, "%-8d %-16s %9llu.%02llu%% %9llu.%02llu%% %10d\n",
                              ps->pid, ps->comm,
                              ps->cpu_usage_percent / 1000,
                              (ps->cpu_usage_percent % 1000) / 10,
                              ps->cpu_usage_percent / 1000,
                              (ps->cpu_usage_percent % 1000) / 10,
                              0);
                }
            }
        }
    }
    
    mutex_unlock(&data_mutex);
    return 0;
}

static int cpuloading_raw_show(struct seq_file *m, void *v)
{
    struct sample_record *rec;
    
    mutex_lock(&data_mutex);
    
    seq_printf(m, "# timestamp_ms pid comm cpu_usage_percent utime_delta stime_delta\n");
    
    list_for_each_entry(rec, &sample_records, list) {
        seq_printf(m, "%llu %d %s %llu %llu %llu\n",
                  rec->timestamp_ms, rec->pid, rec->comm,
                  rec->cpu_usage_percent,
                  rec->utime_delta, rec->stime_delta);
    }
    
    mutex_unlock(&data_mutex);
    return 0;
}

static int cpuloading_json_show(struct seq_file *m, void *v)
{
    struct sample_record *rec;
    int first = 1;
    
    mutex_lock(&data_mutex);
    
    seq_printf(m, "{\n");
    seq_printf(m, "  \"sample_interval_ms\": %d,\n", sample_interval_ms);
    seq_printf(m, "  \"monitor_pid\": %d,\n", monitor_pid);
    seq_printf(m, "  \"total_sample_time_ms\": %llu,\n", total_sample_time_ms);
    seq_printf(m, "  \"record_count\": %d,\n", record_count);
    seq_printf(m, "  \"samples\": [\n");
    
    list_for_each_entry(rec, &sample_records, list) {
        if (!first)
            seq_printf(m, ",\n");
        first = 0;
        
        seq_printf(m, "    {\"timestamp_ms\": %llu, \"pid\": %d, \"comm\": \"%s\", "
                  "\"cpu_usage_percent\": %llu.%02llu, \"utime_delta\": %llu, "
                  "\"stime_delta\": %llu}",
                  rec->timestamp_ms, rec->pid, rec->comm,
                  rec->cpu_usage_percent / 1000,
                  (rec->cpu_usage_percent % 1000) / 10,
                  rec->utime_delta, rec->stime_delta);
    }
    
    seq_printf(m, "\n  ]\n");
    seq_printf(m, "}\n");
    
    mutex_unlock(&data_mutex);
    return 0;
}

static int cpuloading_csv_show(struct seq_file *m, void *v)
{
    struct sample_record *rec;
    
    mutex_lock(&data_mutex);
    
    seq_printf(m, "timestamp_ms,pid,comm,cpu_usage_percent,utime_delta,stime_delta\n");
    
    list_for_each_entry(rec, &sample_records, list) {
        seq_printf(m, "%llu,%d,%s,%llu.%02llu,%llu,%llu\n",
                  rec->timestamp_ms, rec->pid, rec->comm,
                  rec->cpu_usage_percent / 1000,
                  (rec->cpu_usage_percent % 1000) / 10,
                  rec->utime_delta, rec->stime_delta);
    }
    
    mutex_unlock(&data_mutex);
    return 0;
}

static ssize_t cpuloading_clear_write(struct file *file, const char __user *buf,
                                      size_t count, loff_t *ppos)
{
    struct sample_record *rec, *tmp;
    
    mutex_lock(&data_mutex);
    
    list_for_each_entry_safe(rec, tmp, &sample_records, list) {
        list_del(&rec->list);
        kfree(rec);
    }
    record_count = 0;
    total_sample_time_ms = 0;
    last_sample_jiffies = 0;
    
    mutex_unlock(&data_mutex);
    
    pr_info("%s: Records cleared\n", MODULE_NAME);
    return count;
}

static int cpuloading_open(struct inode *inode, struct file *file)
{
    return single_open(file, cpuloading_show, NULL);
}

static int cpuloading_raw_open(struct inode *inode, struct file *file)
{
    return single_open(file, cpuloading_raw_show, NULL);
}

static int cpuloading_json_open(struct inode *inode, struct file *file)
{
    return single_open(file, cpuloading_json_show, NULL);
}

static int cpuloading_csv_open(struct inode *inode, struct file *file)
{
    return single_open(file, cpuloading_csv_show, NULL);
}

static const struct proc_ops cpuloading_fops = {
    .proc_open = cpuloading_open,
    .proc_read = seq_read,
    .proc_lseek = seq_lseek,
    .proc_release = single_release,
};

static const struct proc_ops cpuloading_raw_fops = {
    .proc_open = cpuloading_raw_open,
    .proc_read = seq_read,
    .proc_lseek = seq_lseek,
    .proc_release = single_release,
};

static const struct proc_ops cpuloading_json_fops = {
    .proc_open = cpuloading_json_open,
    .proc_read = seq_read,
    .proc_lseek = seq_lseek,
    .proc_release = single_release,
};

static const struct proc_ops cpuloading_csv_fops = {
    .proc_open = cpuloading_csv_open,
    .proc_read = seq_read,
    .proc_lseek = seq_lseek,
    .proc_release = single_release,
};

static const struct proc_ops cpuloading_clear_fops = {
    .proc_write = cpuloading_clear_write,
};

static void cleanup_data(void)
{
    struct sample_record *rec, *tmp;
    int i;
    
    list_for_each_entry_safe(rec, tmp, &sample_records, list) {
        list_del(&rec->list);
        kfree(rec);
    }
    
    for (i = 0; i < process_count; i++) {
        if (process_data[i]) {
            hash_del(&process_data[i]->hnode);
            kfree(process_data[i]);
            process_data[i] = NULL;
        }
    }
    
    process_count = 0;
    record_count = 0;
}

static int __init cpuloading_init(void)
{
    pr_info("%s: Initializing CPU loading monitor\n", MODULE_NAME);
    pr_info("%s: Sample interval: %d ms\n", MODULE_NAME, sample_interval_ms);
    pr_info("%s: Monitor PID: %d\n", MODULE_NAME, monitor_pid);
    
    hash_init(process_hash);
    
    proc_dir = proc_mkdir("cpuloading", NULL);
    if (!proc_dir) {
        pr_err("%s: Failed to create /proc/cpuloading directory\n", MODULE_NAME);
        return -ENOMEM;
    }
    
    proc_entry = proc_create("stats", 0444, proc_dir, &cpuloading_fops);
    proc_entry_raw = proc_create("raw", 0444, proc_dir, &cpuloading_raw_fops);
    proc_entry_json = proc_create("json", 0444, proc_dir, &cpuloading_json_fops);
    proc_entry_csv = proc_create("csv", 0444, proc_dir, &cpuloading_csv_fops);
    proc_entry_clear = proc_create("clear", 0222, proc_dir, &cpuloading_clear_fops);
    
    if (!proc_entry || !proc_entry_raw || !proc_entry_json || 
        !proc_entry_csv || !proc_entry_clear) {
        pr_err("%s: Failed to create proc entries\n", MODULE_NAME);
        remove_proc_subtree("cpuloading", NULL);
        return -ENOMEM;
    }
    
    timer_setup(&sample_timer, sample_processes, 0);
    mod_timer(&sample_timer, jiffies + msecs_to_jiffies(sample_interval_ms));
    
    pr_info("%s: Module loaded successfully\n", MODULE_NAME);
    pr_info("%s: Access data via /proc/cpuloading/\n", MODULE_NAME);
    
    return 0;
}

static void __exit cpuloading_exit(void)
{
    pr_info("%s: Unloading CPU loading monitor\n", MODULE_NAME);
    
    del_timer_sync(&sample_timer);
    
    mutex_lock(&data_mutex);
    cleanup_data();
    mutex_unlock(&data_mutex);
    
    remove_proc_subtree("cpuloading", NULL);
    
    pr_info("%s: Module unloaded\n", MODULE_NAME);
}

module_init(cpuloading_init);
module_exit(cpuloading_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("Kernel Developer");
MODULE_DESCRIPTION("CPU Loading Monitor - Track process CPU usage over time");
MODULE_VERSION("1.0");
