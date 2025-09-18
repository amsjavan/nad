#pragma once

// Basic types
typedef unsigned char __u8;
typedef unsigned short __u16;
typedef unsigned int __u32;
typedef unsigned long long __u64;

typedef signed char __s8;
typedef signed short __s16;
typedef signed int __s32;
typedef signed long long __s64;

typedef __u16 sa_family_t;
typedef __u32 __be32;
typedef __u16 __be16;

#define AF_INET 2
#define IPPROTO_TCP 6
#define IPPROTO_UDP 17

// Network structures
struct sockaddr {
    sa_family_t sa_family;
    char sa_data[14];
};

struct in_addr {
    __be32 s_addr;
};

struct sockaddr_in {
    sa_family_t sin_family;
    __be16 sin_port;
    struct in_addr sin_addr;
    unsigned char sin_zero[8];
};

// BPF map types
enum bpf_map_type {
    BPF_MAP_TYPE_UNSPEC = 0,
    BPF_MAP_TYPE_HASH,
    BPF_MAP_TYPE_ARRAY,
    BPF_MAP_TYPE_RINGBUF = 27,
};

// Tracing structures (simplified)
struct trace_event_raw_sys_enter {
    struct {
        __u16 common_type;
        __u8 common_flags;
        __u8 common_preempt_count;
        __s32 common_pid;
    } ent;
    
    long id;
    unsigned long args[6];
};

// Simplified pt_regs for x86_64
struct pt_regs {
    unsigned long r15;
    unsigned long r14;
    unsigned long r13;
    unsigned long r12;
    unsigned long bp;
    unsigned long bx;
    unsigned long r11;
    unsigned long r10;
    unsigned long r9;
    unsigned long r8;
    unsigned long ax;
    unsigned long cx;
    unsigned long dx;
    unsigned long si;
    unsigned long di;
    unsigned long orig_ax;
    unsigned long ip;
    unsigned long cs;
    unsigned long flags;
    unsigned long sp;
    unsigned long ss;
};

// Standard definitions
#define true 1
#define false 0
typedef _Bool bool;