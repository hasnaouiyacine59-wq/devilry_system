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
        exit 1
    fi
    
    if ! command -v docker-compose &> /dev/null; then
        error "Docker Compose is not installed"
        exit 1
    fi
    
    success "Dependencies checked"
}

# Generate SSL certificates
generate_ssl() {
    if [ ! -f "./nginx/ssl/fastfood.crt" ]; then
        log "Generating SSL certificates..."
        mkdir -p ./nginx/ssl
        
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout ./nginx/ssl/fastfood.key \
            -out ./nginx/ssl/fastfood.crt \
            -subj "/C=US/ST=State/L=City/O=FastFood/CN=localhost"
        
        success "SSL certificates generated"
    else
        warning "SSL certificates already exist"
    fi
}

# Build images
build_images() {
    log "Building Docker images..."
    docker-compose build --no-cache
    success "Docker images built"
}

# Start services
start_services() {
    log "Starting services..."
    docker-compose up -d
    success "Services started"
    
    # Wait for services to be healthy
    log "Waiting for services to be healthy..."
    sleep 10
    
    # Check if web service is healthy
    if docker-compose ps | grep -q "fastfood-app.*Up (healthy)"; then
        success "All services are healthy"
    else
        error "Some services are not healthy"
        docker-compose logs web
        exit 1
    fi
}

# Create admin user
create_admin() {
    log "Creating admin user..."
    
    # Wait for database to be ready
    until docker-compose exec -T postgres pg_isready -U $DB_USER -d $DB_NAME > /dev/null 2>&1; do
        sleep 2
    done
    
    # Check if admin exists
    ADMIN_EXISTS=$(docker-compose exec -T postgres psql -U $DB_USER -d $DB_NAME -tAc "SELECT 1 FROM users WHERE username='admin'")
    
    if [ "$ADMIN_EXISTS" != "1" ]; then
        # Create admin user
        docker-compose exec -T web python3 -c "
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
"
        success "Admin user created: admin / Admin@123"
    else
        warning "Admin user already exists"
    fi
}

# Show deployment info
show_info() {
    echo -e "\n${GREEN}========================================${NC}"
    echo -e "${GREEN}    FastFood System Deployed!            ${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo -e "\n${BLUE}Access URLs:${NC}"
    echo -e "  Application:  https://localhost"
    echo -e "  API:          https://localhost/api"
    echo -e "  PGAdmin:      http