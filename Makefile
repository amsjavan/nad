# Network Activity Detector (NAD) Makefile
# Real-time network monitoring with eBPF and Go

.DEFAULT_GOAL := help

.PHONY: help proto build-pump build-sink build-bpf docker-pump docker-sink clean dev-sink dev-pump dev-start dev-logs dev-logs-sink dev-logs-pump dev-stop dev-status

##@ Help

help: ## Show this help message
	@echo "Network Activity Detector (NAD) - eBPF Network Monitoring"
	@echo ""
	@echo "Usage: make [TARGET]"
	@echo ""
	@awk 'BEGIN {FS = ":.*##"; printf "\033[36m\033[0m"} /^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)
	@echo ""
	@echo "Quick Start:"
	@echo "  make dev-start     # Start both services"
	@echo "  make dev-logs      # View logs"  
	@echo "  curl localhost:8081 # Test (will show in logs!)"
	@echo "  make dev-stop      # Stop services"

##@ Development (Native - No Docker)

proto: ## Generate protobuf Go code from .proto files
	@echo "Generating protobuf files..."
	@rm -f proto/*.pb.go
	protoc --plugin=$(HOME)/go/bin/protoc-gen-go --plugin=$(HOME)/go/bin/protoc-gen-go-grpc --go_out=. --go-grpc_out=. proto/traffic.proto
	@echo "✓ Protobuf files generated successfully"

build-bpf: ## Build eBPF program with BTF support
	@echo "Building eBPF program..."
	cd traffic-pump/bpf && ./build.sh

build-pump: proto build-bpf ## Build traffic-pump Go binary (agent)
	@echo "Building traffic-pump..."
	cd traffic-pump && go build -o traffic-pump .

build-sink: proto ## Build traffic-sink Go binary (server)
	@echo "Building traffic-sink..."
	cd traffic-sink && go build -o traffic-sink .

build: build-pump build-sink ## Build both Go binaries

dev-start: dev-sink ## Start both traffic-sink and traffic-pump services
	@sleep 2
	@$(MAKE) dev-pump
	@echo "🎉 Both services started!"
	@echo "🧪 Test: curl localhost:8081"
	@echo "📊 Logs: make dev-logs"

dev-sink: build-sink ## Start traffic-sink server in background
	@echo "🚀 Starting traffic-sink..."
	@-pkill -f traffic-sink 2>/dev/null
	@sleep 1
	@./traffic-sink/traffic-sink > sink.log 2>&1 &
	@echo "✓ Traffic-sink started in background"
	@echo "📊 View logs: make dev-logs-sink"

dev-pump: build-pump ## Start traffic-pump agent with eBPF (requires sudo)
	@echo "🚀 Starting traffic-pump..."
	@-sudo pkill -f traffic-pump 2>/dev/null
	@sleep 1
	@echo "Starting eBPF agent (requires sudo)..."
	@sudo env BPF_OBJECT="$(PWD)/traffic-pump/bpf/traffic_pump.o" \
		NODE_ID="dev-local" \
		SINK_ADDRESS="localhost:9090" \
		nohup ./traffic-pump/traffic-pump > pump.log 2>&1 & 
	@echo "✓ Traffic-pump started with eBPF"
	@echo "🔍 View logs: make dev-logs-pump"

dev-stop: ## Stop all running services
	@echo "🛑 Stopping services..."
	@-pkill -f traffic-sink 2>/dev/null
	@-sudo pkill -f traffic-pump 2>/dev/null
	@echo "✅ Services stopped"

dev-status: ## Show status of running services
	@echo "=== Service Status ==="
	@echo "Traffic-sink:"
	@ps aux | grep traffic-sink | grep -v grep || echo "  Not running"
	@echo "Traffic-pump:"  
	@ps aux | grep traffic-pump | grep -v grep || echo "  Not running"

dev-logs: ## View logs from both services
	@$(MAKE) dev-logs-sink
	@echo ""
	@$(MAKE) dev-logs-pump

dev-logs-sink: ## View traffic-sink logs
	@echo "=== Traffic Sink Logs ==="
	@tail -20 sink.log 2>/dev/null || echo "No sink logs yet"

dev-logs-pump: ## View traffic-pump logs
	@echo "=== Traffic Pump Logs ==="
	@tail -20 pump.log 2>/dev/null || echo "No pump logs yet"

##@ Docker Deployment

docker-pump: build-bpf ## Build traffic-pump Docker image
	docker build -f traffic-pump/Dockerfile -t traffic-pump:latest .

docker-sink: ## Build traffic-sink Docker image
	docker build -f traffic-sink/Dockerfile -t traffic-sink:latest .

docker: docker-pump docker-sink ## Build both Docker images

docker-test: docker-test-sink ## Start complete Docker test environment
	@sleep 2
	@$(MAKE) docker-test-pump
	@echo "🚀 Docker test environment started!"
	@echo "📊 View sink logs: make docker-logs-sink"
	@echo "🔍 View pump logs: make docker-logs-pump"

docker-test-sink: docker-sink docker-test-network ## Start traffic-sink container
	@echo "Starting traffic-sink container..."
	@docker stop nad-sink 2>/dev/null || true
	@docker rm nad-sink 2>/dev/null || true
	docker run -d --name nad-sink --network nad-test -p 9090:9090 traffic-sink:latest

docker-test-pump: docker-pump docker-test-network ## Start traffic-pump container (requires privileged mode)
	@echo "Starting traffic-pump container..."
	@docker stop nad-pump 2>/dev/null || true
	@docker rm nad-pump 2>/dev/null || true
	docker run -d --name nad-pump --network nad-test --privileged --pid host \
		-v /sys/fs/bpf:/sys/fs/bpf:rw \
		-v /sys/kernel/debug:/sys/kernel/debug:ro \
		-v /sys/kernel/tracing:/sys/kernel/tracing:ro \
		-e NODE_ID="test-node" \
		-e SINK_ADDRESS="nad-sink:9090" \
		traffic-pump:latest

docker-logs-sink: ## View traffic-sink container logs
	docker logs nad-sink

docker-logs-pump: ## View traffic-pump container logs
	docker logs nad-pump

docker-stop: ## Stop Docker test containers
	@docker stop nad-pump nad-sink 2>/dev/null || true
	@docker rm nad-pump nad-sink 2>/dev/null || true
	@echo "🛑 Docker test environment stopped"

docker-clean: docker-stop ## Clean up Docker test environment
	@docker network rm nad-test 2>/dev/null || true
	@echo "🧹 Docker test environment cleaned"

docker-test-network: ## Create Docker test network
	@docker network ls | grep nad-test || docker network create nad-test

##@ Cleanup

clean: ## Clean all built binaries and generated files
	rm -f traffic-pump/traffic-pump
	rm -f traffic-sink/traffic-sink
	rm -f traffic-pump/bpf/*.o
	rm -f proto/*.pb.go
	@echo "🧹 Cleaned all build artifacts"
