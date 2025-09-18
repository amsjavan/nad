# Traffic Pump Dockerfile
FROM golang:1.21-alpine AS builder

# Install build dependencies including eBPF tools
RUN apk add --no-cache protobuf-dev protoc git clang llvm linux-headers

WORKDIR /app

# Copy source
COPY go.mod go.sum ./
RUN go mod download

# Install compatible protoc plugins
RUN go install google.golang.org/protobuf/cmd/protoc-gen-go@v1.31.0
RUN go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@v1.3.0

# Copy all source code
COPY . .

# Build Go binary (eBPF object should be pre-built)
RUN cd /app/traffic-pump && CGO_ENABLED=0 GOOS=linux go build -o traffic-pump .

# Final stage - minimal image with eBPF runtime requirements
FROM alpine:latest

# Install runtime dependencies
RUN apk --no-cache add ca-certificates

WORKDIR /app

# Copy binaries and eBPF object file
COPY --from=builder /app/traffic-pump/traffic-pump .
COPY --from=builder /app/traffic-pump/bpf/traffic_pump.o .

# Default environment variables
ENV NODE_ID="docker-node"
ENV SINK_ADDRESS="traffic-sink:9090"
ENV BPF_OBJECT="/app/traffic_pump.o"

CMD ["./traffic-pump"]