package main

import (
	"context"
	"fmt"
	"log"
	"net"
	"os"
	"os/signal"
	"syscall"
	"time"

	traffic "github.com/amsjavan/nad/proto"
	"google.golang.org/grpc"
)

// SinkServer implements the gRPC server for receiving traffic events
type SinkServer struct {
	traffic.UnimplementedTrafficServiceServer
}

// SendConnectionEvents receives a stream of connection batches
func (s *SinkServer) SendConnectionEvents(stream traffic.TrafficService_SendConnectionEventsServer) error {
	for {
		batch, err := stream.Recv()
		if err != nil {
			log.Printf("Error receiving batch: %v", err)
			return err
		}

		log.Printf("📦 Received batch from node: %s with %d events", batch.Events[0].NodeId, len(batch.Events))

		for _, event := range batch.Events {
			timestamp := time.Unix(0, int64(event.Timestamp))

			// Log the connection event
			log.Printf("🌐 %s | %s:%d → %s:%d | PID:%d | %s | %s",
				timestamp.Format("15:04:05"),
				intToIP(event.Saddr), event.Sport,
				intToIP(event.Daddr), event.Dport,
				event.Pid,
				event.ProcessName,
				getProtocolName(event.Protocol),
			)
		}

		// Send response
		response := &traffic.ConnectionResponse{
			Message: "OK",
			BatchId: "batch_" + time.Now().Format("20060102150405"),
		}
		if err := stream.SendAndClose(response); err != nil {
			log.Printf("Error sending response: %v", err)
			return err
		}
		return nil // Close stream after processing one batch
	}
}

// HealthCheck implements a simple health check
func (s *SinkServer) HealthCheck(ctx context.Context, req *traffic.HealthRequest) (*traffic.HealthResponse, error) {
	return &traffic.HealthResponse{
		Status:  "healthy",
		Message: "Traffic Sink is running",
	}, nil
}

func main() {
	// Get configuration
	listenAddr := getEnv("LISTEN_ADDRESS", ":9090")

	log.Printf("🚀 Traffic Sink starting on %s", listenAddr)

	// Create gRPC server
	server := grpc.NewServer()
	sinkServer := &SinkServer{}

	// Register service
	traffic.RegisterTrafficServiceServer(server, sinkServer)

	// Start listening
	lis, err := net.Listen("tcp", listenAddr)
	if err != nil {
		log.Fatalf("Failed to listen: %v", err)
	}

	// Start serving in a goroutine
	go func() {
		if err := server.Serve(lis); err != nil {
			log.Fatalf("Failed to serve: %v", err)
		}
	}()

	log.Println("📡 Traffic Sink ready to receive connections...")

	// Handle graceful shutdown
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	<-sigCh
	log.Println("🛑 Shutting down...")

	// Graceful shutdown
	server.GracefulStop()
	log.Println("✅ Traffic Sink stopped")
}

// Helper to get environment variable or default value
func getEnv(key, defaultVal string) string {
	if val, exists := os.LookupEnv(key); exists {
		return val
	}
	return defaultVal
}

// intToIP converts a uint32 to net.IP
func intToIP(ipNum uint32) net.IP {
	ip := make(net.IP, 4)
	ip[0] = byte(ipNum >> 24)
	ip[1] = byte(ipNum >> 16)
	ip[2] = byte(ipNum >> 8)
	ip[3] = byte(ipNum)
	return ip
}

// getProtocolName returns the protocol name for a given number
func getProtocolName(proto uint32) string {
	switch proto {
	case 6:
		return "TCP"
	case 17:
		return "UDP"
	case 1:
		return "ICMP"
	default:
		return fmt.Sprintf("UNKNOWN (%d)", proto)
	}
}