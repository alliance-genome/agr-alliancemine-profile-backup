#!/bin/bash

# Setup .pgpass file for password-less connections
# This is more secure than storing passwords in environment variables

PGPASS_FILE="$HOME/.pgpass"

echo "Setting up .pgpass file for secure authentication..."

# Create .pgpass entry
# Format: hostname:port:database:username:password
read -p "Enter database host: " db_host
read -p "Enter database port (default 5432): " db_port
db_port=${db_port:-5432}
read -p "Enter database name: " db_name  
read -p "Enter username: " db_user
read -s -p "Enter password: " db_password
echo

# Add entry to .pgpass
echo "$db_host:$db_port:$db_name:$db_user:$db_password" >> "$PGPASS_FILE"

# Set proper permissions
chmod 600 "$PGPASS_FILE"

echo "✅ .pgpass file configured successfully!"
echo "You can now remove PGPASSWORD from backup_config.env"
