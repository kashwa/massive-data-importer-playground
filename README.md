# mysql-bulk-importer

This bash script is a Product Import Testing Playground - a comprehensive testing framework designed to test and benchmark high-volume product import pipelines. It is a Docker‐based, MySQL-only bulk import and upsert toolkit for product data.  
It uses a staging (`temp_products`) table, `LOAD DATA INFILE`, and an `INSERT … ON DUPLICATE KEY UPDATE` merge to efficiently ingest and update millions of records.

## Problem It Solves
Modern e-commerce platforms, ERP systems, and marketplaces often need to import and update millions of product records quickly and reliably—whether it's syncing vendor catalogs, integrating third-party data feeds, or batch-updating prices and stock.
These bulk import operations, however, come with significant challenges:

### The Core Challenges
- **Performance Bottlenecks**: Traditional row-by-row inserts or ORM-based imports are too slow and inefficient for large datasets.
- **Data Integrity**: Merging (upserting) new and existing product data without corrupting or duplicating records is complex.
- **Operational Friction**: Spinning up a realistic import environment for testing is usually painful and not easily reproducible.
- **Lack of Observability**: Many import tools act as black boxes with little to no visibility into performance or import accuracy.


## Features

- **Pure MySQL**: No MongoDB or external stores—everything lives in InnoDB.
- **Dockerized**: Spin up a MySQL 8 container with a single script.
- **Bulk staging**: Fast `LOAD DATA INFILE` import into a temporary table.
- **Upsert merge**: Insert new rows and update existing ones in one pass.
- **Tunable**: Session-level optimizations (`unique_checks`, `foreign_key_checks`, `sql_log_bin`, `autocommit`).
- **Scalable**: Tested at 1 M rows in ~1 min; projected sub-10 min for 7 M rows.
- **Self-contained**: Includes data generator, import scripts, and cleanup.

## Prerequisites

- Docker (v20.10+)
- Docker Compose plugin (`docker compose`)
- Bash shell

## Getting Started

1. **Clone the repo**  
   ```bash
   git clone https://github.com/your-org/mysql-bulk-importer.git
   cd mysql-bulk-importer
2. **Configure (optional)**
   - Edit test-playground.sh to adjust:
      - `MYSQL_PORT` (default 33306)
      - `MYSQL_ROOT_PASSWORD` (for production you may set a password)
      - test_data.csv path, batch size, etc.
      - Review import_products.sh for staging/merge SQL and tuning flags.

3. **Setup the environment**
   ```
   ./test-playground.sh setup
   ```
   - Creates directories, docker-compose.yml, MySQL config, and starts the container.
   - Cleans any old volumes to ensure a fresh, password-free MySQL init.
4. **Generate Test Data**
   ```
   ./test-playground.sh generate --size 1000000
   ```
5. **Run the Import**
   ```
   ./test-playground.sh run-test --file data/test_data_1000000.csv
   ```
   - Loads into temp_products, merges into products, and prints timing metrics.


## Directory Structure

```
.
├── data/                       # generated CSV test files
├── logs/                       # import & error logs
├── mysql-conf/                 # custom MySQL settings (my.cnf)
├── product_import_test/        # Docker Compose project root
│   ├── docker-compose.yml
│   └── ...
├── import_products.sh          # bulk‐import logic
├── test-playground.sh          # orchestration script (setup/generate/run-test)
└── README.md
```

## Import Process Flow

- **Load to Temp Table:** CSV data is bulk-loaded into temp_products table
- **Insert New Products:** Products not in main table are inserted
- **Update Existing:** Existing products get price/stock updates
- **Metrics Collection:** Performance data and statistics are recorded

 ## Performance Monitoring
 
- Tracks timing for each operation phase
- Generates detailed metrics in JSON format
- Logs all operations with timestamps
- Records statistics like records loaded, new products created, existing products updated

## Performance Tuning
- **InnoDB Buffer Pool:** Increase innodb_buffer_pool_size in mysql-conf/my.cnf to a large fraction of RAM.
- **Redo Log Size:** innodb_redo_log_capacity can be set to 1–2 GB for large batches.
- **Parallel Upserts:** For extreme scale, split merge by hash slice and run multiple import processes.

## Troubleshooting
- Healthcheck failures: Ensure you’re connecting via 127.0.0.1, not localhost.
- Permission errors: Grant SYSTEM_VARIABLES_ADMIN and FILE to your import user, or wrap tuning commands with || true.
- Missing metrics: Switch from .tmp files to inline shell variables for counts.

## License
MIT © Awfar Inc.
