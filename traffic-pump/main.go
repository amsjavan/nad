package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"os/signal"
	"syscall"
	"time"
	"unsafe"

	traffic "github.com/amsjavan/nad/proto"
	"github.com/cilium/ebpf"
	"github.com/cilium/ebpf/link"
	"github.com/cilium/ebpf/ringbuf"
	"github.com/cilium/ebpf/rlimit"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
)

const (
	TaskCommLen = 16
)

// Connection event from eBPF (must match C struct)
type ConnectionEvent struct {
	Timestamp uint64
	PID       uint32
	UID       uint32
	SyscallID uint16
	Comm      [TaskCommLen]byte
	SAddr     uint32
	DAddr     uint32
	SPort     uint16
	DPort     uint16
	Family    uint16
}

func main() {
	// Check if running as root
	if os.Geteuid() != 0 {
		log.Fatal("Must run as root for eBPF")
	}

	// Get configuration from environment
	nodeID := getEnv("NODE_ID", getHostname())
	sinkAddr := getEnv("SINK_ADDRESS", "localhost:9090")
	bpfPath := getEnv("BPF_OBJECT", "/app/traffic_pump.o")

	log.Printf("Traffic Pump starting - Node: %s, Sink: %s", nodeID, sinkAddr)

	// Remove memory limits for eBPF
	if err := rlimit.RemoveMemlock(); err != nil {
		log.Fatal("Failed to remove memory lock:", err)
	}

	// Load eBPF program
	spec, err := ebpf.LoadCollectionSpec(bpfPath)
	if err != nil {
		log.Fatal("Failed to load eBPF spec:", err)
	}

	coll, err := ebpf.NewCollection(spec)
	if err != nil {
		log.Fatal("Failed to create eBPF collection:", err)
	}
	defer coll.Close()

	// Attach eBPF programs - Updated API
	var links []link.Link

	// Attach connect tracepoint
	if prog, exists := coll.Programs["trace_connect"]; exists {
		l, err := link.Tracepoint("syscalls", "sys_enter_connect", prog, nil)
		if err != nil {
			log.Printf("Warning: Failed to attach connect tracepoint: %v", err)
		} else {
			links = append(links, l)
			log.Println("Attached connect tracepoint")
		}
	}

	// Attach accept tracepoint for incoming connections
	if prog, exists := coll.Programs["trace_accept"]; exists {
		l, err := link.Tracepoint("syscalls", "sys_enter_accept", prog, nil)
		if err != nil {
			log.Printf("Warning: Failed to attach accept tracepoint: %v", err)
		} else {
			links = append(links, l)
			log.Println("Attached accept tracepoint")
		}
	}

	// Attach accept4 tracepoint for incoming connections  
	if prog, exists := coll.Programs["trace_accept4"]; exists {
		l, err := link.Tracepoint("syscalls", "sys_enter_accept4", prog, nil)
		if err != nil {
			log.Printf("Warning: Failed to attach accept4 tracepoint: %v", err)
		} else {
			links = append(links, l)
			log.Println("Attached accept4 tracepoint")
		}
	}

	// Attach tcp_v4_connect kprobe for better socket info
	if prog, exists := coll.Programs["kprobe_tcp_v4_connect"]; exists {
		l, err := link.Kprobe("tcp_v4_connect", prog, nil)
		if err != nil {
			log.Printf("Warning: Failed to attach tcp_v4_connect kprobe: %v", err)
		} else {
			links = append(links, l)
			log.Println("Attached tcp_v4_connect kprobe")
		}
	}

	if len(links) == 0 {
		log.Fatal("No eBPF programs could be attached")
	}

	// Open ring buffer
	eventsMap := coll.Maps["events"]
	reader, err := ringbuf.NewReader(eventsMap)
	if err != nil {
		log.Fatal("Failed to create ring buffer reader:", err)
	}
	defer reader.Close()

	// Connect to sink
	conn, err := grpc.Dial(sinkAddr, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		log.Fatal("Failed to connect to sink:", err)
	}
	defer conn.Close()

	client := traffic.NewTrafficServiceClient(conn)

	// Handle signals
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)

	log.Println("Traffic pump started, monitoring network connections...")

	// Event batch
	var events []*traffic.ConnectionEvent
	ticker := time.NewTicker(5 * time.Second) // Send every 5 seconds
	defer ticker.Stop()

	// Main loop
	for {
		select {
		case <-sigCh:
			log.Println("Shutting down...")
			// Close links
			for _, l := range links {
				l.Close()
			}
			return

		case <-ticker.C:
			// Send batch if we have events
			if len(events) > 0 {
				sendBatch(client, events, nodeID)
				events = events[:0] // Clear batch
			}

		default:
			// Read events (with short timeout)
			record, err := reader.Read()
			if err != nil {
				time.Sleep(100 * time.Millisecond)
				continue
			}

			if len(record.RawSample) < int(unsafe.Sizeof(ConnectionEvent{})) {
				continue
			}

			// Parse event
			event := (*ConnectionEvent)(unsafe.Pointer(&record.RawSample[0]))
			protoEvent := convertEvent(event, nodeID)
			if protoEvent != nil {
				events = append(events, protoEvent)

				// Send immediately if batch is full
				if len(events) >= 50 {
					sendBatch(client, events, nodeID)
					events = events[:0]
				}
			}
		}
	}
}

// Convert eBPF event to proto event
func convertEvent(raw *ConnectionEvent, nodeID string) *traffic.ConnectionEvent {
	// Extract process name
	processName := string(raw.Comm[:])
	for i, b := range raw.Comm {
		if b == 0 {
			processName = string(raw.Comm[:i])
			break
		}
	}

	// Determine syscall type
	syscallType := "unknown"
	switch raw.SyscallID {
	case 42:
		syscallType = "connect"
	case 43:
		syscallType = "accept"
	case 288:
		syscallType = "accept4"
	case 142:
		syscallType = "tcp_connect"
	}

	return &traffic.ConnectionEvent{
		NodeId:      nodeID,
		Timestamp:   raw.Timestamp,
		Pid:         raw.PID,
		ProcessName: fmt.Sprintf("%s [%s]", processName, syscallType),
		Saddr:       raw.SAddr,
		Daddr:       raw.DAddr,
		Sport:       uint32(raw.SPort),
		Dport:       uint32(raw.DPort),
		Protocol:    6, // TCP protocol number
	}
}

// Send batch to sink
func sendBatch(client traffic.TrafficServiceClient, events []*traffic.ConnectionEvent, nodeID string) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	// Create stream to send batch
	stream, err := client.SendConnectionEvents(ctx)
	if err != nil {
		log.Printf("Failed to create stream: %v", err)
		return
	}

	batch := &traffic.ConnectionBatch{
		Events: events,
	}

	err = stream.Send(batch)
	if err != nil {
		log.Printf("Failed to send batch: %v", err)
		return
	}

	resp, err := stream.CloseAndRecv()
	if err != nil {
		log.Printf("Failed to receive response: %v", err)
		return
	}

	log.Printf("Sent %d events, response: %s", len(events), resp.Message)
}

// Convert uint32 IP to string
func intToIP(ip uint32) string {
	return fmt.Sprintf("%d.%d.%d.%d",
		(ip>>24)&0xff,
		(ip>>16)&0xff,
		(ip>>8)&0xff,
		ip&0xff)
}

// Helper functions
func getEnv(key, defaultVal string) string {
	if val := os.Getenv(key); val != "" {
		return val
	}
	return defaultVal
}

func getHostname() string {
	hostname, err := os.Hostname()
	if err != nil {
		return "unknown"
	}
	return hostname
}
