# Traffic Sink Dockerfile
FROM golang:1.21-alpine AS builder

# Install build dependencies
RUN apk add --no-cache protobuf-dev protoc git

WORKDIR /app

# Copy source
COPY go.mod go.sum ./
RUN go mod download

# Install compatible protoc plugins
RUN go install google.golang.org/protobuf/cmd/protoc-gen-go@v1.31.0
RUN go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@v1.3.0

# Copy all source code
COPY . .

# Build Go binary
RUN cd /app/traffic-sink && CGO_ENABLED=0 GOOS=linux go build -o traffic-sink .

# Final stage - minimal image
FROM alpine:latest

# Install ca-certificates for HTTPS requests
RUN apk --no-cache add ca-certificates

WORKDIR /app

# Copy binary
COPY --from=builder /app/traffic-sink/traffic-sink .

# Default environment variables
ENV LISTEN_ADDRESS=":9090"

EXPOSE 9090

CMD ["./traffic-sink"]