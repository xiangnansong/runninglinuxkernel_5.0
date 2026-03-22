import gdb
import sys

class BootTracer:
    def __init__(self):
        self.trace_file = open("boot_trace_gdb.txt", "w")
        self.call_depth = 0
        self.max_depth = 50

    def trace_function(self, event):
        if isinstance(event, gdb.BreakpointEvent):
            frame = gdb.selected_frame()
            func_name = frame.name()

            indent = "  " * self.call_depth
            self.trace_file.write(f"{indent}{func_name}()\n")
            self.trace_file.flush()

            # 打印调用栈
            if self.call_depth < 5:
                try:
                    bt = gdb.execute("backtrace 10", to_string=True)
                    self.trace_file.write(f"{indent}  Backtrace:\n")
                    for line in bt.split('\n')[:10]:
                        self.trace_file.write(f"{indent}    {line}\n")
                except:
                    pass

            self.call_depth += 1

            if self.call_depth < self.max_depth:
                gdb.execute("finish", to_string=True)
                self.call_depth -= 1
                gdb.execute("step", to_string=True)

    def close(self):
        self.trace_file.close()

class TraceBootCommand(gdb.Command):
    """追踪内核启动过程"""

    def __init__(self):
        super(TraceBootCommand, self).__init__("trace-boot", gdb.COMMAND_USER)

    def invoke(self, arg, from_tty):
        print("开始追踪内核启动...")

        # 设置关键断点
        breakpoints = [
            "start_kernel",
            "rest_init",
            "kernel_init",
            "kernel_init_freeable",
            "do_basic_setup",
            "do_initcalls",
            "do_one_initcall"
        ]

        for bp in breakpoints:
            try:
                gdb.execute(f"break {bp}")
                print(f"设置断点: {bp}")
            except:
                print(f"无法设置断点: {bp}")

        # 继续执行
        print("\n开始执行...")
        gdb.execute("continue")

# 注册命令
TraceBootCommand()

print("GDB 追踪脚本已加载")
print("使用 'trace-boot' 命令开始追踪")
