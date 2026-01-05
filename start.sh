#!/bin/bash

# Start All Servers Script
# This script starts all backend services in the background with ngrok integration

# Don't exit on error - we handle errors gracefully
set +e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Get the script directory (absolute path)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGS_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOGS_DIR"

# Detect docker compose command (v1 or v2)
if command -v docker &> /dev/null && docker compose version &> /dev/null; then
    DOCKER_COMPOSE_CMD="docker compose"
elif command -v docker-compose &> /dev/null; then
    DOCKER_COMPOSE_CMD="docker-compose"
else
    DOCKER_COMPOSE_CMD=""
fi

echo -e "${GREEN}🔥 === Starting All Servers === 🔥${NC}\n"

# Function to kill all processes on a port
kill_port() {
    local port=$1
    local pids=$(lsof -ti :$port 2>/dev/null)
    if [ -n "$pids" ]; then
        echo -e "${YELLOW}Killing processes on port $port (PIDs: $pids)...${NC}"
        echo "$pids" | xargs kill -9 2>/dev/null || true
        sleep 1
        # Verify they're killed
        local remaining=$(lsof -ti :$port 2>/dev/null)
        if [ -n "$remaining" ]; then
            echo -e "${RED}Failed to kill all processes on port $port, remaining PIDs: $remaining${NC}"
            # Try one more time with force
            echo "$remaining" | xargs kill -9 2>/dev/null || true
            sleep 1
            if lsof -ti :$port >/dev/null 2>&1; then
                echo -e "${RED}⚠ Port $port still in use after force kill${NC}"
                return 1
            fi
        fi
        echo -e "${GREEN}✓ Port $port is now free${NC}"
        return 0
    else
        echo -e "${GREEN}✓ Port $port is already free${NC}"
        return 0
    fi
}

# Kill processes on all ports used by services
echo -e "${GREEN}[0/6] Killing existing processes on service ports...${NC}"
kill_port 3000  # operator/be-operator
kill_port 3003  # provider/be-back-office
kill_port 3005  # provider/be-wallet-service
kill_port 3008  # provider/be-ledger-service
kill_port 3009  # utility/be-upload-service
echo ""

# Function to wait for PostgreSQL to be ready
wait_for_postgres() {
    local host=${1:-localhost}
    local port=${2:-5432}
    local max_attempts=30
    local attempt=0
    
    echo -e "${YELLOW}Waiting for PostgreSQL to be ready on $host:$port...${NC}"
    while [ $attempt -lt $max_attempts ]; do
        if command -v pg_isready &> /dev/null; then
            if pg_isready -h "$host" -p "$port" -U postgres >/dev/null 2>&1; then
                echo -e "${GREEN}✓ PostgreSQL is ready${NC}"
                sleep 2  # Give it a moment to fully initialize
                return 0
            fi
        else
            # Fallback: try to connect using psql or nc
            if command -v nc &> /dev/null; then
                if nc -z "$host" "$port" 2>/dev/null; then
                    echo -e "${GREEN}✓ PostgreSQL port is open${NC}"
                    sleep 2
                    return 0
                fi
            fi
        fi
        attempt=$((attempt + 1))
        sleep 1
    done
    echo -e "${YELLOW}⚠ PostgreSQL may not be ready yet (timeout after ${max_attempts}s)${NC}"
    return 1
}

# Function to wait for service to be ready
wait_for_service() {
    local port=$1
    local service_name=$2
    local max_attempts=30
    local attempt=0
    
    echo -e "${YELLOW}Waiting for $service_name to be ready on port $port...${NC}"
    while [ $attempt -lt $max_attempts ]; do
        if lsof -Pi :$port -sTCP:LISTEN -t >/dev/null 2>&1 ; then
            echo -e "${GREEN}✓ $service_name is ready${NC}"
            sleep 2  # Give it a moment to fully initialize
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 1
    done
    echo -e "${YELLOW}⚠ $service_name may not be ready yet (timeout after ${max_attempts}s)${NC}"
    return 1
}

# Function to start ngrok in background
start_ngrok_background() {
    local port=$1
    local ngrok_url=$2
    local service_name=$3
    local log_file="$LOGS_DIR/ngrok-${service_name}.log"
    local pid_file="$LOGS_DIR/ngrok-${service_name}.pid"
    
    # Kill existing ngrok for this service if running
    if [ -f "$pid_file" ]; then
        local old_pid=$(cat "$pid_file" 2>/dev/null)
        if ps -p "$old_pid" > /dev/null 2>&1; then
            echo -e "${YELLOW}Killing existing ngrok for $service_name (PID: $old_pid)...${NC}"
            kill "$old_pid" 2>/dev/null || true
            sleep 1
        fi
        rm -f "$pid_file"
    fi
    
    # Start ngrok in background
    cd "$SCRIPT_DIR"
    nohup ngrok http --url="$ngrok_url" "$port" > "$log_file" 2>&1 &
    local ngrok_pid=$!
    echo "$ngrok_pid" > "$pid_file"
    
    echo -e "${GREEN}✓ ngrok started in background for $service_name (PID: $ngrok_pid, log: $log_file)${NC}"
    return 0
}

# Start Docker Compose services (databases)
echo -e "${GREEN}[1/6] Starting Docker Compose services...${NC}"
if [ -n "$DOCKER_COMPOSE_CMD" ]; then
    if [ -f "$SCRIPT_DIR/provider/be-back-office/docker-compose.yml" ]; then
        cd "$SCRIPT_DIR/provider/be-back-office"
        $DOCKER_COMPOSE_CMD up -d 2>&1 | tee "$LOGS_DIR/docker-compose-back-office.log" || echo -e "${YELLOW}⚠ Docker Compose for be-back-office failed or already running${NC}"
        cd "$SCRIPT_DIR"
    fi
    if [ -f "$SCRIPT_DIR/operator/be-operator/docker-compose.yml" ]; then
        cd "$SCRIPT_DIR/operator/be-operator"
        $DOCKER_COMPOSE_CMD up -d 2>&1 | tee "$LOGS_DIR/docker-compose-operator.log" || echo -e "${YELLOW}⚠ Docker Compose for be-operator failed or already running${NC}"
        cd "$SCRIPT_DIR"
    fi
    if [ -f "$SCRIPT_DIR/provider/be-wallet-service/docker-compose.yml" ]; then
        cd "$SCRIPT_DIR/provider/be-wallet-service"
        $DOCKER_COMPOSE_CMD up -d 2>&1 | tee "$LOGS_DIR/docker-compose-wallet-service.log" || echo -e "${YELLOW}⚠ Docker Compose for be-wallet-service failed or already running${NC}"
        cd "$SCRIPT_DIR"
    fi
else
    echo -e "${YELLOW}⚠ Docker Compose not found, skipping database setup${NC}"
fi
echo -e "${GREEN}✓ Docker Compose services checked${NC}\n"

# Wait for databases to be ready
echo -e "${GREEN}Waiting for databases to be ready...${NC}"
wait_for_postgres localhost 5432
wait_for_postgres localhost 5434
echo ""

# Start operator/be-operator (NestJS)
echo -e "${GREEN}[2/6] Starting operator/be-operator (NestJS)...${NC}"
osascript -e "tell application \"Terminal\" to do script \"cd '$SCRIPT_DIR/operator/be-operator' && yarn start:dev\"" > /dev/null 2>&1
echo -e "${GREEN}✓ operator/be-operator terminal opened${NC}"

# Start ngrok for operator
wait_for_service 3000 "operator/be-operator"
echo -e "${GREEN}Starting ngrok for operator/be-operator...${NC}"
start_ngrok_background 3000 "operator-gateway.ngrok.dev" "operator"
echo ""

# Start provider/be-back-office (Java/Gradle)
echo -e "${GREEN}[3/6] Starting provider/be-back-office (Java/Gradle)...${NC}"
osascript -e "tell application \"Terminal\" to do script \"cd '$SCRIPT_DIR/provider/be-back-office' && export SERVER_PORT=3003 && ./gradlew bootRun\"" > /dev/null 2>&1
echo -e "${GREEN}✓ provider/be-back-office terminal opened (port 3003)${NC}"

# Start ngrok for be-back-office
wait_for_service 3003 "provider/be-back-office"
echo -e "${GREEN}Starting ngrok for provider/be-back-office...${NC}"
start_ngrok_background 3003 "game-provider.ngrok.dev" "back-office"
echo ""

# Start provider/be-wallet-service (Java/Gradle)
echo -e "${GREEN}[4/6] Starting provider/be-wallet-service (Java/Gradle)...${NC}"
osascript -e "tell application \"Terminal\" to do script \"cd '$SCRIPT_DIR/provider/be-wallet-service' && ./gradlew bootRun\"" > /dev/null 2>&1
echo -e "${GREEN}✓ provider/be-wallet-service terminal opened (port 3005)${NC}"

# Start ngrok for be-wallet-service
wait_for_service 3005 "provider/be-wallet-service"
echo -e "${GREEN}Starting ngrok for provider/be-wallet-service...${NC}"
start_ngrok_background 3005 "wallet-service.ngrok.dev" "wallet-service"
echo ""

# Start provider/be-ledger-service (Java/Gradle)
echo -e "${GREEN}[5/6] Starting provider/be-ledger-service (Java/Gradle)...${NC}"
osascript -e "tell application \"Terminal\" to do script \"cd '$SCRIPT_DIR/provider/be-ledger-service' && ./gradlew bootRun\"" > /dev/null 2>&1
echo -e "${GREEN}✓ provider/be-ledger-service terminal opened${NC}"

# Start ngrok for be-ledger-service
wait_for_service 3008 "provider/be-ledger-service"
echo -e "${GREEN}Starting ngrok for provider/be-ledger-service...${NC}"
start_ngrok_background 3008 "game-log-service.ngrok.dev" "ledger"
echo ""

# Start utility/be-upload-service (Java/Gradle)
echo -e "${GREEN}[6/6] Starting utility/be-upload-service (Java/Gradle)...${NC}"
osascript -e "tell application \"Terminal\" to do script \"cd '$SCRIPT_DIR/utility/be-upload-service' && ./gradlew bootRun\"" > /dev/null 2>&1
echo -e "${GREEN}✓ utility/be-upload-service terminal opened${NC}"

# Start ngrok for be-upload-service
wait_for_service 3009 "utility/be-upload-service"
echo -e "${GREEN}Starting ngrok for utility/be-upload-service...${NC}"
start_ngrok_background 3009 "upload-image-service.ngrok.dev" "upload"
echo ""

echo -e "${GREEN}🔥 === All Servers Started === 🔥${NC}\n"
echo -e "Log files are located in: ${GREEN}$LOGS_DIR${NC}"
echo -e "\n🔥 Service Ports:"
echo -e "  🔥 operator/be-operator:        ${GREEN}http://localhost:3000${NC} | ${GREEN}http://172.10.10.8:3000${NC} | ${GREEN}https://operator-gateway.ngrok.dev${NC}"
echo -e "  🔥 provider/be-back-office:     ${GREEN}http://localhost:3003${NC} | ${GREEN}http://172.10.10.8:3003${NC} | ${GREEN}https://game-provider.ngrok.dev${NC}"
echo -e "  🔥 provider/be-wallet-service:  ${GREEN}http://localhost:3005${NC} | ${GREEN}http://172.10.10.8:3005${NC} | ${GREEN}https://wallet-service.ngrok.dev${NC}"
echo -e "  🔥 provider/be-ledger-service:  ${GREEN}http://localhost:3008${NC} | ${GREEN}http://172.10.10.8:3008${NC} | ${GREEN}https://game-log-service.ngrok.dev${NC}"
echo -e "  🔥 utility/be-upload-service:   ${GREEN}http://localhost:3009${NC} | ${GREEN}http://172.10.10.8:3009${NC} | ${GREEN}https://upload-image-service.ngrok.dev${NC}"
echo -e "\nAll services are running in separate Terminal windows."
echo -e "Ngrok tunnels are running in the background (check logs in $LOGS_DIR)."
echo -e "You can see the output directly in each Terminal window."
echo -e "\nTo stop all services:"
echo -e "  Close the Terminal windows or run: ./stop-all.sh"
echo ""
