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

docker-build: build-bpf ## Build all Docker images
	@echo "🔨 Building Docker images..."
	@docker build -f traffic-pump/Dockerfile -t traffic-pump:latest .
	@docker build -f traffic-sink/Dockerfile -t traffic-sink:latest .
	@echo "✅ Docker images built"

docker-single: docker-build ## Start single pump setup
	@echo "🚀 Starting single pump setup..."
	@cd deploy/docker && docker-compose up -d
	@echo "✅ NAD running: http://localhost:9090"
	@echo "📊 Logs: make docker-logs"

docker-multi: docker-build ## Start multi-pump test setup  
	@echo "🚀 Starting multi-pump test setup..."
	@cd deploy/docker && docker-compose --profile multi up -d
	@echo "✅ Multi-node NAD running with test client"
	@echo "📊 Logs: make docker-logs"

docker-logs: ## View logs from all containers
	@echo "=== Sink Logs ==="
	@docker logs nad-sink --tail 10 2>/dev/null || echo "Sink not running"
	@echo ""
	@echo "=== Pump Logs ==="
	@docker logs nad-pump --tail 10 2>/dev/null || docker logs nad-pump1 --tail 5 2>/dev/null || echo "No pump running"
	@docker logs nad-pump2 --tail 5 2>/dev/null || echo ""

docker-stop: ## Stop all NAD containers
	@echo "🛑 Stopping NAD containers..."
	@cd deploy/docker && docker-compose down 2>/dev/null || true
	@cd deploy/docker && docker-compose --profile multi down 2>/dev/null || true
	@echo "✅ Stopped"

docker-clean: docker-stop ## Clean Docker environment
	@docker system prune -f
	@echo "🧹 Docker cleaned"

docker-save: docker-build ## Save Docker images for Vagrant
	@echo "💾 Saving Docker images..."
	@docker save traffic-sink:latest -o traffic-sink-image.tar
	@docker save traffic-pump:latest -o traffic-pump-image.tar
	@echo "✅ Images saved to *.tar files"

##@ Vagrant Testing

vagrant-up: ## Start Vagrant VMs (3 VMs with Docker)
	@echo "🚀 Starting Vagrant environment..."
	@make docker-save  # Save images for VMs
	@cd deploy/vagrant && vagrant up
	@echo "✅ Vagrant VMs running"
	@echo "🌐 Sink: http://localhost:39090"

vagrant-logs: ## View logs from Vagrant VMs
	@echo "=== Sink VM ==="
	@cd deploy/vagrant && vagrant ssh sink -c "docker logs nad-sink --tail 10" 2>/dev/null || true
	@echo ""
	@echo "=== Pump1 VM ==="  
	@cd deploy/vagrant && vagrant ssh pump1 -c "docker logs nad-pump --tail 5" 2>/dev/null || true
	@echo "=== Pump2 VM ==="
	@cd deploy/vagrant && vagrant ssh pump2 -c "docker logs nad-pump --tail 5" 2>/dev/null || true

vagrant-test: ## Generate test traffic in Vagrant VMs
	@echo "🧪 Generating test traffic..."
	@cd deploy/vagrant && vagrant ssh pump1 -c "curl -s google.com > /dev/null & nslookup github.com > /dev/null"
	@cd deploy/vagrant && vagrant ssh pump2 -c "curl -s example.com > /dev/null & ping -c 2 8.8.8.8 > /dev/null"
	@sleep 5
	@$(MAKE) vagrant-logs

vagrant-status: ## Show Vagrant VM status
	@cd deploy/vagrant && vagrant status

vagrant-destroy: ## Destroy Vagrant VMs
	@cd deploy/vagrant && vagrant destroy -f
	@echo "🧹 Vagrant VMs destroyed"

##@ Cleanup

clean: ## Clean all built binaries and generated files
	rm -f traffic-pump/traffic-pump
	rm -f traffic-sink/traffic-sink
	rm -f traffic-pump/bpf/*.o
	rm -f proto/*.pb.go
	@echo "🧹 Cleaned all build artifacts"
