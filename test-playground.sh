#!/bin/bash

###############################################################################
# Product Import Testing Playground
# ================================
#
# This script creates a testing environment for the high-volume product import
# pipeline, including:
#
# 1. A sample data generator for creating test files of various sizes
# 2. A Docker-based MySQL environment for testing
# 3. Test runner for measuring performance
#
# Usage:
#   ./test-playground.sh [command] [options]
#
# Commands:
#   setup       - Set up the testing environment
#   generate    - Generate test data
#   run-test    - Run an import test
#   cleanup     - Clean up test environment
#
# Examples:
#   ./test-playground.sh setup
#   ./test-playground.sh generate --size 10000
#   ./test-playground.sh run-test --file test_data_10000.csv
#   ./test-playground.sh cleanup
###############################################################################

# Configuration variables
TEST_DIR="$(pwd)/product_import_test"
DATA_DIR="${TEST_DIR}/data"
LOG_DIR="${TEST_DIR}/logs"
SCRIPT_DIR="${TEST_DIR}/scripts"
DOCKER_COMPOSE_FILE="${TEST_DIR}/docker-compose.yml"

# Docker/MySQL settings
MYSQL_ROOT_PASSWORD="test_password"
MYSQL_DATABASE="product_import_test"
MYSQL_USER="test_user"
MYSQL_PASSWORD="test_password"
MYSQL_PORT=33306  # Using a non-standard port to avoid conflicts

# Display help information
show_help() {
  cat << EOF
Usage: ${0} [command] [options]

Commands:
  setup                   Set up the testing environment
  generate [options]      Generate test data
  run-test [options]      Run an import test
  cleanup                 Clean up test environment
  help                    Show this help message

Generate options:
  --size SIZE             Number of records to generate (default: 10000)
  --file FILENAME         Output filename (default: test_data_SIZE.csv)

Run-test options:
  --file FILENAME         Input data file to use for testing
  --batch-size SIZE       Batch size for processing (default: 1000)

Examples:
  ${0} setup
  ${0} generate --size 10000
  ${0} run-test --file test_data_10000.csv
  ${0} cleanup
EOF
}

# Function to create directories
create_directories() {
  echo "Creating test directories..."
  mkdir -p "${TEST_DIR}"
  mkdir -p "${DATA_DIR}"
  mkdir -p "${LOG_DIR}"
  mkdir -p "${SCRIPT_DIR}"
  echo "Directories created successfully."
}

# Function to create Docker Compose configuration
create_docker_compose() {
  echo "Creating Docker Compose configuration..."
  cat > "${DOCKER_COMPOSE_FILE}" << EOF
version: '3'

services:
  mysql:
    image: mysql:8.0
    container_name: product_import_test_mysql
    ports:
      - "${MYSQL_PORT}:3306"
    volumes:
      - mysql_data:/var/lib/mysql
      - ./mysql-conf:/etc/mysql/conf.d
    command: --local-infile=1
    environment: 
      MYSQL_ALLOW_EMPTY_PASSWORD: "yes"
    healthcheck:
      test: "mysqladmin ping -h localhost -u root -p"
      interval: 5s
      timeout: 5s
      retries: 10
      start_period: 10s

volumes:
  mysql_data:
EOF

  # Create MySQL configuration
  mkdir -p "${TEST_DIR}/mysql-conf"
  cat > "${TEST_DIR}/mysql-conf/my.cnf" << EOF
[mysqld]
# Enable local infile loading
local_infile=1

# Buffer Pool Settings
innodb_buffer_pool_size=512M
innodb_buffer_pool_instances=2

# Log File Settings (MySQL 8.0+ style)
innodb_redo_log_capacity=512M
innodb_log_buffer_size=32M

# I/O Settings
innodb_flush_log_at_trx_commit=2
innodb_write_io_threads=8
innodb_read_io_threads=8

# Temp table settings
tmp_table_size=256M
max_heap_table_size=256M

# Buffer settings
sort_buffer_size=8M
join_buffer_size=8M
EOF

  echo "Docker Compose configuration created successfully."
}


# Function to create the import script
create_import_script() {
  echo "Creating import script..."
  cat > "${SCRIPT_DIR}/import_products.sh" << 'EOF'
#!/bin/bash

###############################################################################
# Product Import Script (Test Version)
###############################################################################

# Configuration
MYSQL_HOST="localhost"
MYSQL_PORT="33306"
MYSQL_USER="test_user"
MYSQL_PASS="test_password"
MYSQL_DB="product_import_test"

# Paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$(dirname "${SCRIPT_DIR}")"
DATA_DIR="${TEST_DIR}/data"
LOG_DIR="${TEST_DIR}/logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BATCH_ID="${TIMESTAMP}_$(openssl rand -hex 4)"
INPUT_FILE="${1:-${DATA_DIR}/test_data.csv}"
LOG_FILE="${LOG_DIR}/import_${TIMESTAMP}.log"
ERROR_LOG="${LOG_DIR}/import_errors_${TIMESTAMP}.log"
METRICS_FILE="${LOG_DIR}/metrics_${TIMESTAMP}.json"
BATCH_SIZE="${2:-1000}"

# Logging function
log() {
  local level="INFO"
  if [[ $# -gt 1 ]]; then
    level="$1"
    shift
  fi
  echo "[$(date +"%Y-%m-%d %H:%M:%S")] [${level}] $*" | tee -a "${LOG_FILE}"
}

# Error logging function
error() {
  log "ERROR" "$*"
  echo "[$(date +"%Y-%m-%d %H:%M:%S")] $*" >> "${ERROR_LOG}"
}

# Performance tracking functions
start_timer() {
  local metric_name="$1"
  echo "$metric_name:$(date +%s.%N)" >> "${TEST_DIR}/timers.tmp"
}

end_timer() {
  local metric_name="$1"
  local start_time=$(grep "${metric_name}:" "${TEST_DIR}/timers.tmp" | cut -d':' -f2)
  local end_time=$(date +%s.%N)
  local elapsed=$(echo "${end_time} - ${start_time}" | bc)
  echo "${metric_name}: ${elapsed} seconds" | tee -a "${LOG_FILE}"
  # Store in metrics file for analysis
  echo "\"${metric_name}\": ${elapsed}," >> "${METRICS_FILE}.tmp"
}

# Function to execute SQL and handle errors
execute_sql() {
  local sql="$1"
  local description="$2"
  local output_file="${3:-/dev/null}"
  
  log "Executing: ${description}"
  
  # Execute SQL and capture exit code
  mysql --host="${MYSQL_HOST}" --port="${MYSQL_PORT}" \
    --user="${MYSQL_USER}" --password="${MYSQL_PASS}" \
    --default-character-set=utf8mb4 "${MYSQL_DB}" \
    -e "${sql}" > "${output_file}" 2>> "${ERROR_LOG}"
  
  local exit_code=$?
  
  if [ ${exit_code} -ne 0 ]; then
    error "Failed: ${description} (Exit code: ${exit_code})"
    return ${exit_code}
  else
    log "Success: ${description}"
    return 0
  fi
}

# Cleanup function to run on exit
cleanup() {
  log "Cleaning up temporary files"
  
  # Restore MySQL settings if they were changed
  execute_sql "
    SET GLOBAL unique_checks=1;
    SET GLOBAL foreign_key_checks=1;
    SET GLOBAL sql_log_bin=1;
  " "Restoring MySQL settings"
  
  # Finalize metrics JSON file
  if [ -f "${METRICS_FILE}.tmp" ]; then
    echo "{" > "${METRICS_FILE}"
    cat "${METRICS_FILE}.tmp" >> "${METRICS_FILE}"
    # Add total time
    if [ -f "${TEST_DIR}/timers.tmp" ]; then
      local start_time=$(grep "total:" "${TEST_DIR}/timers.tmp" | cut -d':' -f2)
      local end_time=$(date +%s.%N)
      local total_elapsed=$(echo "${end_time} - ${start_time}" | bc)
      echo "\"total_time\": ${total_elapsed}" >> "${METRICS_FILE}"
    fi
    echo "}" >> "${METRICS_FILE}"
    rm "${METRICS_FILE}.tmp"
  fi
  
  # Clean up other temp files
  rm -f "${TEST_DIR}/timers.tmp"
  
  log "Cleanup completed"
}

# Set up trap to call cleanup function on exit
trap cleanup EXIT INT TERM

# Setup database schema
setup_database_schema() {
  log "Setting up database schema"
  
  # Check if temp_products table exists, create if it doesn't
  local create_temp_table_sql="
  CREATE TABLE IF NOT EXISTS temp_products (
    barcode VARCHAR(50) PRIMARY KEY,
    price DECIMAL(10, 2) NOT NULL,
    stock INT NOT NULL,
    name VARCHAR(255),
    description TEXT,
    import_batch VARCHAR(32) NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_import_batch (import_batch)
  ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
  "
  
  # Check if products table exists, create if it doesn't
  local create_products_table_sql="
  CREATE TABLE IF NOT EXISTS products (
    id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    barcode VARCHAR(50) NOT NULL UNIQUE,
    price DECIMAL(10, 2) NOT NULL,
    stock INT NOT NULL,
    name VARCHAR(255),
    description TEXT,
    created_at TIMESTAMP NULL,
    updated_at TIMESTAMP NULL,
    INDEX idx_barcode (barcode)
  ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
  "
  
  # Execute the SQL to create tables
  execute_sql "${create_temp_table_sql}" "Creating temp_products table if it doesn't exist"
  execute_sql "${create_products_table_sql}" "Creating products table if it doesn't exist"
}

# Load data to temp table
load_data_to_temp() {
  log "Loading data to temporary table"
  start_timer "load_temp_table"
  
  # Optimize MySQL settings for bulk insert
  execute_sql "
    SET GLOBAL unique_checks=0;
    SET GLOBAL foreign_key_checks=0;
    SET GLOBAL sql_log_bin=0;
  " "Setting MySQL for bulk import"
  
  # Truncate or delete previous data with the same batch ID if exists
  execute_sql "
    DELETE FROM temp_products WHERE import_batch='${BATCH_ID}';
  " "Cleaning previous data with same batch ID"
  
  # Load data from CSV into temp_products table
  log "Loading CSV data into temp_products table using LOAD DATA INFILE"
  
  # Using LOAD DATA INFILE for fastest possible import
  local load_data_sql="
    LOAD DATA LOCAL INFILE '${INPUT_FILE}'
    INTO TABLE temp_products
    FIELDS TERMINATED BY ','
    ENCLOSED BY '\"'
    LINES TERMINATED BY '\n'
    IGNORE 1 LINES
    (barcode, price, stock, name, description)
    SET import_batch = '${BATCH_ID}';
  "
  
  # Execute the load command
  mysql --host="${MYSQL_HOST}" --port="${MYSQL_PORT}" \
    --user="${MYSQL_USER}" --password="${MYSQL_PASS}" \
    --local-infile=1 "${MYSQL_DB}" \
    -e "${load_data_sql}" 2>> "${ERROR_LOG}"
  
  local exit_code=$?
  
  if [ ${exit_code} -ne 0 ]; then
    error "Failed to load data using LOAD DATA INFILE (Exit code: ${exit_code})"
    exit 1
  fi
  
  # Count how many records were inserted
  local count_sql="SELECT COUNT(*) FROM temp_products WHERE import_batch='${BATCH_ID}';"
  local count_output="${TEST_DIR}/count_output.tmp"
  
  execute_sql "${count_sql}" "Counting imported records" "${count_output}"
  local records_loaded=$(cat "${count_output}" | tail -n 1)
  rm -f "${count_output}"
  
  log "Successfully loaded ${records_loaded} records into temp_products table"
  echo "\"records_loaded\": ${records_loaded}," >> "${METRICS_FILE}.tmp"
  
  end_timer "load_temp_table"
}

# Update main table
update_main_table() {
  log "Updating main products table from temp data"
  start_timer "update_main_table"
  
  # Create metrics output file for recording results
  local metrics_output="${TEST_DIR}/metrics_output.tmp"
  
  # Step 1: Insert new products that don't exist in main table
  local insert_sql="
    INSERT INTO products (barcode, price, stock, name, description, created_at, updated_at)
    SELECT t.barcode, t.price, t.stock, t.name, t.description, NOW(), NOW()
    FROM temp_products t
    LEFT JOIN products p ON t.barcode = p.barcode
    WHERE p.id IS NULL
    AND t.import_batch = '${BATCH_ID}';
  "
  
  execute_sql "${insert_sql}" "Inserting new products"
  
  # Count new records
  local new_count_sql="
    SELECT ROW_COUNT() AS new_records;
  "
  
  execute_sql "${new_count_sql}" "Counting new products" "${metrics_output}"
  local new_records=$(cat "${metrics_output}" | tail -n 1)
  log "Inserted ${new_records} new products"
  echo "\"new_products_created\": ${new_records}," >> "${METRICS_FILE}.tmp"
  
  # Step 2: Update existing products (only price and stock)
  local update_sql="
    UPDATE products p
    JOIN temp_products t ON p.barcode = t.barcode
    SET 
        p.price = t.price,
        p.stock = t.stock,
        p.updated_at = NOW()
    WHERE t.import_batch = '${BATCH_ID}'
    AND (p.price != t.price OR p.stock != t.stock);
  "
  
  execute_sql "${update_sql}" "Updating existing products"
  
  # Count updated records
  local update_count_sql="
    SELECT ROW_COUNT() AS updated_records;
  "
  
  execute_sql "${update_count_sql}" "Counting updated products" "${metrics_output}"
  local updated_records=$(cat "${metrics_output}" | tail -n 1)
  log "Updated ${updated_records} existing products"
  echo "\"existing_products_updated\": ${updated_records}," >> "${METRICS_FILE}.tmp"
  
  # Calculate total affected records
  local total_affected=$((new_records + updated_records))
  log "Total affected records: ${total_affected}"
  echo "\"total_affected_records\": ${total_affected}," >> "${METRICS_FILE}.tmp"
  
  # Step 3: Calculate update ratio for metrics
  local count_sql="
    SELECT 
      (SELECT COUNT(*) FROM temp_products WHERE import_batch='${BATCH_ID}') AS total_records,
      ${new_records} AS new_records,
      ${updated_records} AS updated_records,
      ${total_affected} AS total_affected;
  "
  
  execute_sql "${count_sql}" "Calculating update statistics" "${metrics_output}"
  cat "${metrics_output}" >> "${LOG_FILE}"
  
  # Clean up metrics output
  rm -f "${metrics_output}"
  
  end_timer "update_main_table"
}

# Main process
main() {
  # Start tracking total execution time
  start_timer "total"
  
  # Initialize metrics file
  echo "" > "${METRICS_FILE}.tmp"
  
  log "======================================="
  log "Starting product import process"
  log "Batch ID: ${BATCH_ID}"
  log "Input File: ${INPUT_FILE}"
  log "Timestamp: $(date)"
  log "======================================="
  
  # Check if input file exists
  if [ ! -f "${INPUT_FILE}" ]; then
    error "Input file does not exist: ${INPUT_FILE}"
    exit 1
  fi
  
  # Print file info
  local file_size=$(stat -c%s "${INPUT_FILE}")
  local line_count=$(wc -l < "${INPUT_FILE}")
  log "Input file size: ${file_size} bytes, ${line_count} lines"
  
  # Setup database schema
  setup_database_schema
  
  # Load data to temp table
  load_data_to_temp
  
  # Update main products table
  update_main_table
  
  log "======================================="
  log "Import process completed successfully"
  log "======================================="
  
  # Cleanup is handled by the trap function
  return 0
}

# Execute main function
main

exit 0
EOF

  chmod +x "${SCRIPT_DIR}/import_products.sh"
  echo "Import script created successfully."
}

# Function to create data generator script
create_data_generator() {
  echo "Creating data generator script..."
  cat > "${SCRIPT_DIR}/generate_test_data.sh" << 'EOF'
#!/bin/bash

# This script generates test product data in CSV format
# Usage: ./generate_test_data.sh SIZE OUTPUT_FILE

# Default values
SIZE=${1:-10000}
OUTPUT_FILE=${2:-"test_data_${SIZE}.csv"}

echo "Generating ${SIZE} test records to ${OUTPUT_FILE}..."

# Create header
echo "barcode,price,stock,name,description" > "${OUTPUT_FILE}"

# Generate data
for ((i=1; i<=${SIZE}; i++)); do
  # Generate random price between $1.00 and $1000.00
  PRICE=$(awk -v min=100 -v max=100000 'BEGIN{srand(); print int(min+rand()*(max-min+1))/100}')
  
  # Generate random stock between 0 and 1000
  STOCK=$((RANDOM % 1001))
  
  # Generate barcode
  BARCODE="BC$(printf %010d "${i}")"
  
  # Generate product name and description
  NAME="Test Product ${i}"
  DESCRIPTION="This is a description for product ${i}. It includes details about features and specifications."
  
  # Write to CSV file
  echo "${BARCODE},${PRICE},${STOCK},\"${NAME}\",\"${DESCRIPTION}\"" >> "${OUTPUT_FILE}"
  
  # Show progress every 10% or 100,000 records, whichever comes first
  if [ $((i % (SIZE / 10 > 100000 ? 100000 : SIZE / 10 > 0 ? SIZE / 10 : 1) )) -eq 0 ]; then
    PCT=$((i * 100 / SIZE))
    echo "${PCT}% complete (${i}/${SIZE})"
  fi
done

echo "Data generation complete: ${SIZE} records written to ${OUTPUT_FILE}"
FILE_SIZE=$(stat -c%s "${OUTPUT_FILE}")
echo "File size: ${FILE_SIZE} bytes"
EOF

  chmod +x "${SCRIPT_DIR}/generate_test_data.sh"
  echo "Data generator script created successfully."
}

# Function to start Docker containers
start_docker() {
  echo "Starting Docker containers..."
  cd "${TEST_DIR}"
  docker compose up -d
  
  # Wait for MySQL to be ready
  echo "Waiting for MySQL to be ready..."
  for i in {1..30}; do
    if docker compose exec mysql mysqladmin ping -h localhost -u root -p"${MYSQL_ROOT_PASSWORD}" --silent > /dev/null 2>&1; then
      echo "MySQL is ready!"
      return 0
    fi
    echo "Waiting for MySQL to start... ${i}/30"
    sleep 2
  done
  
  echo "Error: MySQL failed to start within the timeout period."
  return 1
}

# Function to set up the testing environment
setup_environment() {
  create_directories
  create_docker_compose
  create_import_script
  create_data_generator

  echo "Cleaning old MySQL volume (if any)..."
  docker volume rm product_import_test_mysql_data > /dev/null 2>&1 || true
  
  start_docker
  
  echo "Testing environment setup complete!"
  echo "To generate test data, run: ./test-playground.sh generate --size 10000"
  echo "To run a test, run: ./test-playground.sh run-test --file test_data_10000.csv"
}

# Function to generate test data
generate_test_data() {
  local size=10000
  local file=""
  
  # Parse command line arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --size)
        size="$2"
        shift 2
        ;;
      --file)
        file="$2"
        shift 2
        ;;
      *)
        echo "Unknown option: $1"
        show_help
        exit 1
        ;;
    esac
  done
  
  # Set default filename if not provided
  if [ -z "${file}" ]; then
    file="${DATA_DIR}/test_data_${size}.csv"
  else
    # If path is not absolute, prepend DATA_DIR
    if [[ "${file}" != /* ]]; then
      file="${DATA_DIR}/${file}"
    fi
  fi
  
  echo "Generating ${size} test records to ${file}..."
  "${SCRIPT_DIR}/generate_test_data.sh" "${size}" "${file}"
}

# Function to run an import test
run_test() {
  local file=""
  local batch_size=1000
  
  # Parse command line arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --file)
        file="$2"
        shift 2
        ;;
      --batch-size)
        batch_size="$2"
        shift 2
        ;;
      *)
        echo "Unknown option: $1"
        show_help
        exit 1
        ;;
    esac
  done
  
  # Check if file was provided
  if [ -z "${file}" ]; then
    echo "Error: No file specified. Use --file to specify a test data file."
    show_help
    exit 1
  fi
  
  # If path is not absolute, prepend DATA_DIR
  if [[ "${file}" != /* ]]; then
    file="${DATA_DIR}/${file}"
  fi
  
  # Check if file exists
  if [ ! -f "${file}" ]; then
    echo "Error: File not found: ${file}"
    exit 1
  fi
  
  echo "Running test with file ${file} and batch size ${batch_size}..."
  "${SCRIPT_DIR}/import_products.sh" "${file}" "${batch_size}"
  
  # Show the most recent metrics file
  latest_metrics=$(ls -t "${LOG_DIR}/metrics_"*.json | head -1)
  if [ -n "${latest_metrics}" ]; then
    echo "Latest metrics:"
    cat "${latest_metrics}"
  fi
}

# Function to clean up the testing environment
cleanup_environment() {
  echo "Cleaning up testing environment..."
  
  # Stop Docker containers
  if [ -f "${DOCKER_COMPOSE_FILE}" ]; then
    cd "${TEST_DIR}"
    docker compose down -v
  fi
  
  # Ask for confirmation before deleting files
  read -p "Do you want to delete all test files? (y/N) " confirm
  if [[ "${confirm}" =~ ^[Yy]$ ]]; then
    rm -rf "${TEST_DIR}"
    echo "Test environment deleted."
  else
    echo "Test files preserved."
  fi
}

# Main function
main() {
  # No arguments provided
  if [ $# -eq 0 ]; then
    show_help
    exit 0
  fi
  
  # Parse command
  command="$1"
  shift
  
  case "${command}" in
    setup)
      setup_environment
      ;;
    generate)
      generate_test_data "$@"
      ;;
    run-test)
      run_test "$@"
      ;;
    cleanup)
      cleanup_environment
      ;;
    help)
      show_help
      ;;
    *)
      echo "Unknown command: ${command}"
      show_help
      exit 1
      ;;
  esac
}

# Execute main function
main "$@"
