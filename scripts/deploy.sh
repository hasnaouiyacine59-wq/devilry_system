#!/bin/bash
# FastFood System Deployment Script

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Load environment variables
if [ -f .env ]; then
    export $(cat .env | grep -v '^#' | xargs)
else
    echo -e "${RED}Error: .env file not found${NC}"
    echo -e "Copy .env.example to .env and configure it first"
    exit 1
fi

log() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"
}

success() {
    echo -e "${GREEN}✓${NC} $1"
}

error() {
    echo -e "${RED}✗${NC} $1"
}

warning() {
    echo -e "${YELLOW}!${NC} $1"
}

# Check Docker and Docker Compose
check_dependencies() {
    log "Checking dependencies..."
    
    if ! command -v docker &> /dev/null; then
        error "Docker is not installed"
        echo "Install Docker: https://docs.docker.com/get-docker/"
        exit 1
    fi
    
    if ! docker info &> /dev/null; then
        error "Docker daemon is not running"
        echo "Start Docker service: sudo systemctl start docker"
        exit 1
    fi
    
    if ! command -v docker-compose &> /dev/null; then
        # Try docker compose v2
        if ! docker compose version &> /dev/null; then
            error "Docker Compose is not installed"
            echo "Install Docker Compose: https://docs.docker.com/compose/install/"
            exit 1
        else
            DOCKER_COMPOSE_CMD="docker compose"
        fi
    else
        DOCKER_COMPOSE_CMD="docker-compose"
    fi
    
    success "Dependencies checked"
    echo "Using Docker Compose command: $DOCKER_COMPOSE_CMD"
}

# Generate SSL certificates
generate_ssl() {
    if [ ! -f "./nginx/ssl/fastfood.crt" ] || [ ! -f "./nginx/ssl/fastfood.key" ]; then
        log "Generating SSL certificates..."
        mkdir -p ./nginx/ssl
        
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout ./nginx/ssl/fastfood.key \
            -out ./nginx/ssl/fastfood.crt \
            -subj "/C=US/ST=State/L=City/O=FastFood/CN=localhost" \
            2>/dev/null
        
        if [ $? -eq 0 ]; then
            success "SSL certificates generated"
            
            # Set proper permissions
            chmod 600 ./nginx/ssl/fastfood.key
            chmod 644 ./nginx/ssl/fastfood.crt
        else
            error "Failed to generate SSL certificates"
            exit 1
        fi
    else
        warning "SSL certificates already exist"
    fi
}

# Check if ports are available
check_ports() {
    log "Checking if required ports are available..."
    
    local ports=("80" "443" "5000" "5432" "6379" "5050")
    
    for port in "${ports[@]}"; do
        if ss -tuln | grep -q ":$port "; then
            error "Port $port is already in use"
            echo "Please free up port $port or change it in .env file"
            exit 1
        fi
    done
    
    success "All required ports are available"
}

# Build images
build_images() {
    log "Building Docker images..."
    
    # Build database image
    log "Building database image..."
    $DOCKER_COMPOSE_CMD build postgres
    
    # Build web application image
    log "Building application image..."
    $DOCKER_COMPOSE_CMD build web
    
    # Build nginx image
    log "Building nginx image..."
    $DOCKER_COMPOSE_CMD build nginx
    
    success "All Docker images built successfully"
}

# Start services
start_services() {
    log "Starting services..."
    
    # Create network if not exists
    docker network create fastfood-network 2>/dev/null || true
    
    # Start services in correct order
    $DOCKER_COMPOSE_CMD up -d postgres redis
    
    # Wait for database to be ready
    log "Waiting for PostgreSQL to be ready..."
    local max_attempts=30
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        if $DOCKER_COMPOSE_CMD exec -T postgres pg_isready -U $DB_USER -d $DB_NAME > /dev/null 2>&1; then
            success "PostgreSQL is ready"
            break
        fi
        
        if [ $attempt -eq $max_attempts ]; then
            error "PostgreSQL failed to start within timeout"
            $DOCKER_COMPOSE_CMD logs postgres
            exit 1
        fi
        
        echo -n "."
        sleep 2
        ((attempt++))
    done
    echo ""
    
    # Wait for Redis to be ready
    log "Waiting for Redis to be ready..."
    attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        if $DOCKER_COMPOSE_CMD exec -T redis redis-cli -a $REDIS_PASS ping | grep -q "PONG"; then
            success "Redis is ready"
            break
        fi
        
        if [ $attempt -eq $max_attempts ]; then
            error "Redis failed to start within timeout"
            $DOCKER_COMPOSE_CMD logs redis
            exit 1
        fi
        
        echo -n "."
        sleep 2
        ((attempt++))
    done
    echo ""
    
    # Start web application
    log "Starting web application..."
    $DOCKER_COMPOSE_CMD up -d web
    
    # Start remaining services
    log "Starting remaining services..."
    $DOCKER_COMPOSE_CMD up -d nginx pgadmin
    
    success "All services started successfully"
    
    # Wait for web service to be healthy
    log "Waiting for web service to be healthy..."
    attempt=1
    
    while [ $attempt -le 20 ]; do
        if curl -s -f http://localhost:5000/health > /dev/null 2>&1; then
            success "Web service is healthy"
            break
        fi
        
        if [ $attempt -eq 20 ]; then
            error "Web service failed to become healthy within timeout"
            $DOCKER_COMPOSE_CMD logs web
            exit 1
        fi
        
        echo -n "."
        sleep 3
        ((attempt++))
    done
    echo ""
}

# Create admin user
create_admin() {
    log "Creating admin user..."
    
    # Check if admin exists
    ADMIN_EXISTS=$($DOCKER_COMPOSE_CMD exec -T postgres psql -U $DB_USER -d $DB_NAME -tAc "SELECT 1 FROM users WHERE username='admin'" 2>/dev/null || echo "0")
    
    if [ "$ADMIN_EXISTS" != "1" ]; then
        log "Creating admin user..."
        
        $DOCKER_COMPOSE_CMD exec -T web python3 -c "
import os
import sys
sys.path.append('/app')
from app import create_app, db
from app.models import User, Restaurant
from flask_bcrypt import generate_password_hash

app = create_app()
with app.app_context():
    # Create restaurant if not exists
    if not Restaurant.query.first():
        restaurant = Restaurant(
            restaurant_id='REST-001',
            name='Burger Palace',
            address='123 Main St',
            phone='+1234567890'
        )
        db.session.add(restaurant)
        db.session.commit()
        print('Default restaurant created')
    
    # Create admin user
    admin = User(
        username='admin',
        email='admin@fastfood.com',
        password_hash=generate_password_hash('Admin@123').decode('utf-8'),
        role='admin',
        restaurant_id='REST-001',
        is_active=True
    )
    db.session.add(admin)
    db.session.commit()
    print('Admin user created successfully')
" 2>/dev/null
        
        if [ $? -eq 0 ]; then
            success "Admin user created: admin / Admin@123"
            warning "IMPORTANT: Change the admin password immediately!"
        else
            error "Failed to create admin user"
        fi
    else
        warning "Admin user already exists"
    fi
}

# Create sample data for development
create_sample_data() {
    if [ "$FLASK_ENV" = "development" ]; then
        log "Creating sample data for development..."
        
        $DOCKER_COMPOSE_CMD exec -T web python3 -c "
import os
import sys
sys.path.append('/app')
from app import create_app, db
from app.models import User, Restaurant, Customer, MenuItem, Address
from flask_bcrypt import generate_password_hash
from datetime import datetime, timedelta

app = create_app()
with app.app_context():
    # Create sample customers
    if Customer.query.count() < 3:
        customers = [
            Customer(
                customer_id='CUST-001',
                name='John Smith',
                phone_number='+1234567001',
                email='john@example.com'
            ),
            Customer(
                customer_id='CUST-002',
                name='Emma Johnson',
                phone_number='+1234567002',
                email='emma@example.com'
            ),
            Customer(
                customer_id='CUST-003',
                name='Michael Brown',
                phone_number='+1234567003',
                email='michael@example.com'
            )
        ]
        for customer in customers:
            db.session.add(customer)
    
    # Create sample menu items
    if MenuItem.query.count() < 5:
        items = [
            MenuItem(
                item_id='ITEM-001',
                restaurant_id='REST-001',
                name='Classic Cheeseburger',
                description='Juicy beef patty with cheese, lettuce, tomato',
                price=8.99,
                category='Burgers',
                is_available=True
            ),
            MenuItem(
                item_id='ITEM-002',
                restaurant_id='REST-001',
                name='Bacon Deluxe',
                description='Double patty with bacon and special sauce',
                price=12.99,
                category='Burgers',
                is_available=True
            ),
            MenuItem(
                item_id='ITEM-003',
                restaurant_id='REST-001',
                name='French Fries',
                description='Crispy golden fries',
                price=3.99,
                category='Sides',
                is_available=True
            ),
            MenuItem(
                item_id='ITEM-004',
                restaurant_id='REST-001',
                name='Chocolate Milkshake',
                description='Creamy chocolate milkshake',
                price=4.99,
                category='Drinks',
                is_available=True
            ),
            MenuItem(
                item_id='ITEM-005',
                restaurant_id='REST-001',
                name='Chicken Nuggets (6pc)',
                description='Crispy chicken nuggets',
                price=5.99,
                category='Sides',
                is_available=True
            )
        ]
        for item in items:
            db.session.add(item)
    
    # Create sample employee users
    sample_users = [
        ('manager_jane', 'manager@fastfood.com', 'Manager@123', 'manager'),
        ('employee_tom', 'tom@fastfood.com', 'Employee@123', 'employee'),
        ('driver_mike', 'mike@fastfood.com', 'Driver@123', 'driver'),
        ('customer_sara', 'sara@customer.com', 'Customer@123', 'user')
    ]
    
    for username, email, password, role in sample_users:
        if not User.query.filter_by(username=username).first():
            user = User(
                username=username,
                email=email,
                password_hash=generate_password_hash(password).decode('utf-8'),
                role=role,
                restaurant_id='REST-001' if role != 'user' else None,
                is_active=True
            )
            db.session.add(user)
    
    db.session.commit()
    print('Sample data created successfully')
" 2>/dev/null
        
        if [ $? -eq 0 ]; then
            success "Sample data created"
            echo "Sample users:"
            echo "  - manager_jane / Manager@123 (Manager)"
            echo "  - employee_tom / Employee@123 (Employee)"
            echo "  - driver_mike / Driver@123 (Driver)"
            echo "  - customer_sara / Customer@123 (Customer)"
        fi
    fi
}

# Show deployment info
show_info() {
    echo -e "\n${GREEN}========================================${NC}"
    echo -e "${GREEN}    FastFood System Deployed Successfully! ${NC}"
    echo -e "${GREEN}========================================${NC}"
    
    echo -e "\n${BLUE}📊 Services Status:${NC}"
    $DOCKER_COMPOSE_CMD ps
    
    echo -e "\n${BLUE}🌐 Access URLs:${NC}"
    echo -e "  🔗 Web Application:  ${GREEN}https://localhost${NC}"
    echo -e "  📱 API Base URL:     ${GREEN}https://localhost/api${NC}"
    echo -e "  👑 Admin Panel:      ${GREEN}https://localhost/admin${NC}"
    echo -e "  🗄️  PGAdmin:         ${GREEN}http://localhost:5050${NC}"
    
    echo -e "\n${BLUE}🔐 Default Credentials:${NC}"
    echo -e "  👤 Admin Panel:      admin / Admin@123"
    echo -e "  🗄️  PGAdmin:         ${PGADMIN_EMAIL} / ${PGADMIN_PASSWORD}"
    
    echo -e "\n${BLUE}📦 Database Info:${NC}"
    echo -e "  🐘 PostgreSQL:      ${DB_HOST}:${DB_PORT}/${DB_NAME}"
    echo -e "  👤 DB User:         ${DB_USER}"
    echo -e "  🔑 DB Password:     ${DB_PASS}"
    
    echo -e "\n${BLUE}⚙️  Useful Commands:${NC}"
    echo -e "  📋 View logs:        docker-compose logs -f"
    echo -e "  🔄 Restart app:      docker-compose restart web"
    echo -e "  🛑 Stop all:         docker-compose down"
    echo -e "  🚀 Start all:        docker-compose up -d"
    echo -e "  📊 Check health:     curl https://localhost/health"
    
    echo -e "\n${YELLOW}⚠️  Important Notes:${NC}"
    echo -e "  1. Change default passwords immediately!"
    echo -e "  2. For production, use real SSL certificates"
    echo -e "  3. Regularly backup your database"
    echo -e "  4. Monitor logs for any issues"
    
    echo -e "\n${GREEN}✅ Deployment completed at: $(date)${NC}"
}

# Check health of all services
check_health() {
    echo -e "\n${BLUE}🩺 Health Check:${NC}"
    
    # Check web service
    if curl -s -f https://localhost/health > /dev/null 2>&1; then
        echo -e "  ✅ Web Application: Healthy"
    else
        echo -e "  ❌ Web Application: Unhealthy"
    fi
    
    # Check PostgreSQL
    if $DOCKER_COMPOSE_CMD exec -T postgres pg_isready -U $DB_USER -d $DB_NAME > /dev/null 2>&1; then
        echo -e "  ✅ PostgreSQL: Healthy"
    else
        echo -e "  ❌ PostgreSQL: Unhealthy"
    fi
    
    # Check Redis
    if $DOCKER_COMPOSE_CMD exec -T redis redis-cli -a $REDIS_PASS ping | grep -q "PONG"; then
        echo -e "  ✅ Redis: Healthy"
    else
        echo -e "  ❌ Redis: Unhealthy"
    fi
    
    # Check nginx
    if curl -s -f https://localhost > /dev/null 2>&1; then
        echo -e "  ✅ Nginx: Healthy"
    else
        echo -e "  ❌ Nginx: Unhealthy"
    fi
}

# Main deployment function
deploy() {
    echo -e "${GREEN}"
    echo "╔══════════════════════════════════════════╗"
    echo "║    FastFood System Deployment Script     ║"
    echo "╚══════════════════════════════════════════╝"
    echo -e "${NC}"
    
    # Check dependencies
    check_dependencies
    
    # Check ports
    check_ports
    
    # Generate SSL certificates
    generate_ssl
    
    # Build images
    build_images
    
    # Start services
    start_services
    
    # Create admin user
    create_admin
    
    # Create sample data (for development)
    if [ "$FLASK_ENV" = "development" ]; then
        create_sample_data
    fi
    
    # Health check
    sleep 5
    check_health
    
    # Show deployment info
    show_info
    
    # Save deployment info to file
    save_deployment_info
}

# Save deployment information
save_deployment_info() {
    cat > deployment_info.txt << EOF
========================================
FastFood System Deployment Information
========================================
Deployment Time: $(date)
Flask Environment: ${FLASK_ENV}

Services:
- Web Application: https://localhost
- API: https://localhost/api
- Admin Panel: https://localhost/admin
- PGAdmin: http://localhost:5050

Database:
- Host: ${DB_HOST}
- Port: ${DB_PORT}
- Name: ${DB_NAME}
- User: ${DB_USER}

Default Credentials:
- Admin Panel: admin / Admin@123
- PGAdmin: ${PGADMIN_EMAIL} / ${PGADMIN_PASSWORD}

Important Notes:
1. Change all default passwords immediately!
2. For production, replace SSL certificates
3. Enable firewall and security measures
4. Regular backups are essential

Container Information:
$(docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep fastfood)

EOF
    
    log "Deployment information saved to: deployment_info.txt"
}

# Backup function
backup() {
    log "Starting backup..."
    
    # Create backup directory with timestamp
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_dir="backups/backup_$timestamp"
    mkdir -p "$backup_dir"
    
    # Backup database
    log "Backing up database..."
    $DOCKER_COMPOSE_CMD exec -T postgres pg_dump -U $DB_USER $DB_NAME | gzip > "$backup_dir/database.sql.gz"
    
    # Backup important files
    log "Backing up configuration files..."
    cp .env "$backup_dir/"
    cp docker-compose.yml "$backup_dir/"
    cp -r nginx/ssl "$backup_dir/" 2>/dev/null || true
    
    # Create backup info file
    cat > "$backup_dir/backup_info.txt" << EOF
Backup created: $(date)
Database: ${DB_NAME}
Files included:
- Database dump
- Environment configuration
- SSL certificates

Restore command:
./scripts/restore.sh $backup_dir
EOF
    
    success "Backup completed: $backup_dir"
    echo "Backup size: $(du -sh $backup_dir | cut -f1)"
}

# Restore function
restore() {
    if [ -z "$1" ]; then
        error "Please specify backup directory to restore"
        echo "Usage: $0 restore <backup_directory>"
        exit 1
    fi
    
    local backup_dir="$1"
    
    if [ ! -d "$backup_dir" ]; then
        error "Backup directory not found: $backup_dir"
        exit 1
    fi
    
    log "Restoring from backup: $backup_dir"
    
    # Stop services
    $DOCKER_COMPOSE_CMD down
    
    # Restore database
    if [ -f "$backup_dir/database.sql.gz" ]; then
        log "Restoring database..."
        gunzip -c "$backup_dir/database.sql.gz" | $DOCKER_COMPOSE_CMD exec -T postgres psql -U $DB_USER -d $DB_NAME
    fi
    
    # Restore configuration files
    if [ -f "$backup_dir/.env" ]; then
        log "Restoring environment configuration..."
        cp "$backup_dir/.env" ./
    fi
    
    # Restart services
    $DOCKER_COMPOSE_CMD up -d
    
    success "Restore completed"
}

# Show usage information
show_usage() {
    echo -e "${BLUE}Usage:${NC} $0 [command]"
    echo -e "\n${BLUE}Commands:${NC}"
    echo -e "  ${GREEN}deploy${NC}     - Deploy the entire system"
    echo -e "  ${GREEN}backup${NC}     - Create a backup of the system"
    echo -e "  ${GREEN}restore${NC}    - Restore from a backup"
    echo -e "  ${GREEN}status${NC}     - Show system status"
    echo -e "  ${GREEN}logs${NC}       - Show logs of all services"
    echo -e "  ${GREEN}stop${NC}       - Stop all services"
    echo -e "  ${GREEN}start${NC}      - Start all services"
    echo -e "  ${GREEN}restart${NC}    - Restart all services"
    echo -e "  ${GREEN}help${NC}       - Show this help message"
}

# Show status
show_status() {
    echo -e "${BLUE}System Status:${NC}"
    $DOCKER_COMPOSE_CMD ps
    
    echo -e "\n${BLUE}Resource Usage:${NC}"
    docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}\t{{.BlockIO}}" | grep fastfood
}

# Show logs
show_logs() {
    $DOCKER_COMPOSE_CMD logs -f
}

# Stop services
stop_services() {
    $DOCKER_COMPOSE_CMD down
    success "All services stopped"
}

# Start services
start_services_cmd() {
    $DOCKER_COMPOSE_CMD up -d
    success "All services started"
}

# Restart services
restart_services() {
    $DOCKER_COMPOSE_CMD restart
    success "All services restarted"
}

# Main script logic
case "$1" in
    "deploy")
        deploy
        ;;
    "backup")
        backup
        ;;
    "restore")
        restore "$2"
        ;;
    "status")
        show_status
        ;;
    "logs")
        show_logs
        ;;
    "stop")
        stop_services
        ;;
    "start")
        start_services_cmd
        ;;
    "restart")
        restart_services
        ;;
    "help"|"-h"|"--help"|"")
        show_usage
        ;;
    *)
        error "Unknown command: $1"
        show_usage
        exit 1
        ;;
esac

exit 0