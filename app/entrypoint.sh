#!/bin/bash
set -e

# Wait for database
echo "Waiting for PostgreSQL..."
while ! nc -z $DB_HOST $DB_PORT; do
    sleep 1
done
echo "PostgreSQL is ready!"

# Wait for Redis
echo "Waiting for Redis..."
while ! nc -z $REDIS_HOST $REDIS_PORT; do
    sleep 1
done
echo "Redis is ready!"

# Run database migrations
echo "Running database migrations..."
flask db upgrade

# Create admin user if not exists
echo "Creating admin user if not exists..."
python3 -c "
from app import create_app, db
from app.models import User, Restaurant

app = create_app()
with app.app_context():
    # Create default restaurant if not exists
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
    
    # Create admin user if not exists
    if not User.query.filter_by(username='admin').first():
        from flask_bcrypt import generate_password_hash
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
        print('Admin user created: admin / Admin@123')
    
    # Create sample data for development
    if os.environ.get('FLASK_ENV') == 'development':
        from app.models import Customer, MenuItem
        if not Customer.query.first():
            customer = Customer(
                customer_id='CUST-001',
                name='John Doe',
                phone_number='+1234567899',
                email='john@example.com'
            )
            db.session.add(customer)
        
        if not MenuItem.query.first():
            items = [
                MenuItem(
                    item_id='ITEM-001',
                    restaurant_id='REST-001',
                    name='Classic Cheeseburger',
                    description='Juicy beef patty with cheese',
                    price=5.99,
                    category='burger'
                ),
                MenuItem(
                    item_id='ITEM-002',
                    restaurant_id='REST-001',
                    name='French Fries',
                    description='Crispy golden fries',
                    price=2.99,
                    category='sides'
                )
            ]
            for item in items:
                db.session.add(item)
        
        db.session.commit()
        print('Sample data created for development')
"

# Collect static files (if using Flask-Collect)
echo "Collecting static files..."
flask collect --verbose

# Clear expired sessions
echo "Cleaning up expired sessions..."
python3 -c "
from app import create_app, db
from app.models import UserSession
from datetime import datetime

app = create_app()
with app.app_context():
    expired = UserSession.query.filter(UserSession.expires_at < datetime.utcnow()).delete()
    db.session.commit()
    print(f'Cleaned up {expired} expired sessions')
"

# Start the application
echo "Starting FastFood Ordering System..."
exec "$@"