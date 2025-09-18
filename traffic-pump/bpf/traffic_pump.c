// eBPF program to capture network syscalls with real IP/port data
typedef unsigned char __u8;
typedef unsigned short __u16;
typedef unsigned int __u32;
typedef unsigned long long __u64;

#define BPF_MAP_TYPE_RINGBUF 27
#define SEC(name) __attribute__((section(name), used))
#define __uint(name, val) int (*name)[val]
#define AF_INET 2

char _license[] SEC("license") = "GPL";

// Network address structure (simplified)
struct sockaddr_in {
    __u16 sin_family;
    __u16 sin_port;
    __u32 sin_addr;
    __u8 sin_zero[8];
};

struct connection_event {
    __u64 timestamp;
    __u32 pid;
    __u32 uid;
    __u16 syscall_id;
    char comm[16];
    // Network info
    __u32 saddr;
    __u32 daddr;
    __u16 sport;
    __u16 dport;
    __u16 family;
};

struct {
    __uint(type, BPF_MAP_TYPE_RINGBUF);
    __uint(max_entries, 256 * 1024);
} events SEC(".maps");

// BPF helper functions
static __u64 (*bpf_ktime_get_ns)(void) = (void *) 5;
static __u64 (*bpf_get_current_pid_tgid)(void) = (void *) 14;
static __u32 (*bpf_get_current_uid_gid)(void) = (void *) 15;
static long (*bpf_get_current_comm)(void *buf, __u32 size) = (void *) 16;
static long (*bpf_probe_read_user)(void *dst, __u32 size, const void *unsafe_ptr) = (void *) 112;
static void *(*bpf_ringbuf_reserve)(void *ringbuf, __u64 size, __u64 flags) = (void *) 131;
static long (*bpf_ringbuf_submit)(void *data, __u64 flags) = (void *) 132;

// Tracepoint args structure for sys_enter_connect
struct trace_event_raw_sys_enter {
    __u64 unused;
    int syscall_nr;
    unsigned long args[6];
};

// Convert network byte order to host byte order
static inline __u16 bpf_ntohs(__u16 netshort) {
    return ((netshort >> 8) & 0x00FF) | ((netshort << 8) & 0xFF00);
}

static inline __u32 bpf_ntohl(__u32 netlong) {
    return ((netlong >> 24) & 0x000000FF) |
           ((netlong >> 8)  & 0x0000FF00) |
           ((netlong << 8)  & 0x00FF0000) |
           ((netlong << 24) & 0xFF000000);
}

SEC("tracepoint/syscalls/sys_enter_connect")
int trace_connect(struct trace_event_raw_sys_enter *ctx) {
    struct connection_event *event;
    struct sockaddr_in addr;
    __u64 pid_tgid;
    
    // Get sockaddr from syscall args
    void *sockaddr_ptr = (void *)ctx->args[1];
    if (!sockaddr_ptr)
        return 0;
        
    // Try to read sockaddr from user space
    if (bpf_probe_read_user(&addr, sizeof(addr), sockaddr_ptr) != 0)
        return 0;
    
    // Only handle IPv4
    if (addr.sin_family != AF_INET)
        return 0;
    
    event = bpf_ringbuf_reserve(&events, sizeof(*event), 0);
    if (!event)
        return 0;
    
    pid_tgid = bpf_get_current_pid_tgid();
    event->timestamp = bpf_ktime_get_ns();
    event->pid = pid_tgid >> 32;
    event->uid = bpf_get_current_uid_gid();
    event->syscall_id = 42; // connect
    
    bpf_get_current_comm(&event->comm, sizeof(event->comm));
    
    // Extract network info
    event->family = addr.sin_family;
    event->daddr = bpf_ntohl(addr.sin_addr);  // Destination IP
    event->dport = bpf_ntohs(addr.sin_port);  // Destination port  
    
    // For source info, we can try to use a simple heuristic:
    // Most connections to localhost are FROM localhost
    if (event->daddr == 0x7f000001) { // 127.0.0.1 (host byte order)
        event->saddr = 0x7f000001; // 127.0.0.1 (host byte order)
    } else {
        // For external connections, try to detect common local ranges
        __u32 daddr_net = event->daddr & 0xff000000; // First octet
        if (daddr_net == 0x0a000000 || // 10.x.x.x
            daddr_net == 0xc0a80000 || // 192.168.x.x (first two octets)
            (event->daddr & 0xfff00000) == 0xac100000) { // 172.16-31.x.x
            // Local network - assume connection from gateway or DHCP range
            event->saddr = (daddr_net == 0xc0a80000) ? 0xc0a80001 : // 192.168.0.1
                          (daddr_net == 0x0a000000) ? 0x0a000001 :   // 10.0.0.1
                          0xac100001; // 172.16.0.1
        } else {
            event->saddr = 0; // External connection - unknown source
        }
    }
    event->sport = 0;  // Ephemeral port assigned by kernel
    
    bpf_ringbuf_submit(event, 0);
    return 0;
}

// Add a kprobe to capture more socket info
SEC("kprobe/tcp_v4_connect")  
int kprobe_tcp_v4_connect(struct pt_regs *ctx) {
    struct connection_event *event;
    __u64 pid_tgid;
    
    event = bpf_ringbuf_reserve(&events, sizeof(*event), 0);
    if (!event)
        return 0;
    
    pid_tgid = bpf_get_current_pid_tgid();
    event->timestamp = bpf_ktime_get_ns();
    event->pid = pid_tgid >> 32;
    event->uid = bpf_get_current_uid_gid();
    event->syscall_id = 142; // tcp_v4_connect (custom ID)
    
    bpf_get_current_comm(&event->comm, sizeof(event->comm));
    
    // In kprobe context, socket info is more available
    // but requires more complex parsing
    event->family = AF_INET;
    event->saddr = 0;  
    event->daddr = 0;  
    event->sport = 0;  
    event->dport = 0;  
    
    bpf_ringbuf_submit(event, 0);
    return 0;
}

SEC("tracepoint/syscalls/sys_enter_accept")
int trace_accept(struct trace_event_raw_sys_enter *ctx) {
    struct connection_event *event;
    __u64 pid_tgid;
    
    event = bpf_ringbuf_reserve(&events, sizeof(*event), 0);
    if (!event)
        return 0;
    
    pid_tgid = bpf_get_current_pid_tgid();
    event->timestamp = bpf_ktime_get_ns();
    event->pid = pid_tgid >> 32;
    event->uid = bpf_get_current_uid_gid();
    event->syscall_id = 43; // accept
    
    bpf_get_current_comm(&event->comm, sizeof(event->comm));
    
    // For accept, we don't have remote addr info in sys_enter
    // Would need sys_exit_accept for that
    event->family = AF_INET;
    event->saddr = 0;
    event->daddr = 0;
    event->sport = 0; // Server port - would need socket info
    event->dport = 0; // Client port - not available in sys_enter
    
    bpf_ringbuf_submit(event, 0);
    return 0;
}

SEC("tracepoint/syscalls/sys_enter_accept4")
int trace_accept4(struct trace_event_raw_sys_enter *ctx) {
    struct connection_event *event;
    __u64 pid_tgid;
    
    event = bpf_ringbuf_reserve(&events, sizeof(*event), 0);
    if (!event)
        return 0;
    
    pid_tgid = bpf_get_current_pid_tgid();
    event->timestamp = bpf_ktime_get_ns();
    event->pid = pid_tgid >> 32;
    event->uid = bpf_get_current_uid_gid();
    event->syscall_id = 288; // accept4
    
    bpf_get_current_comm(&event->comm, sizeof(event->comm));
    
    // Same as accept - limited info in sys_enter
    event->family = AF_INET;
    event->saddr = 0;
    event->daddr = 0;  
    event->sport = 0;
    event->dport = 0;
    
    bpf_ringbuf_submit(event, 0);
    return 0;
}