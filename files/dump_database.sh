#!/bin/bash
#
# PostgreSQL Database Dump Wrapper
#
# This script standardizes PostgreSQL dumps by wrapping pg_dump with sensible
# defaults, input validation, and convenience features.
#
# Value it provides:
# - Splits output into two files: schema (DDL) and data (INSERTs).
# - Automatic timestamped filenames to avoid overwrites.
# - Ensures consistent defaults: lock timeout, column inserts, row batching.
# - Allows configurable --rows-per-insert for efficient restore performance.
# - Detects PostgreSQL version and adjusts --quote-all-identifiers flag safely.
# - Applies umask 0007 so dump files are not world-readable (protecting data).
# - Provides clear CLI options (-q quiet, -R rows per insert, -h help).
# - Fails fast on errors, unset variables, or broken pipes.
#
# Intended use:
# - IT Ops and Dev teams can use this in place of raw pg_dump to ensure
#   consistent database dumps across environments, reducing human error
#   and improving reproducibility.
#
set -euo pipefail  # Exit on errors, undefined variables, or pipe failures

# Default settings
QUIET=false
ROWS_PER_INSERT=1000

usage() {
    local exit_code="$1"

    if [ "$exit_code" -ne 0 ]; then
        # If exit_code is non-zero (error), output to stderr
        exec 1>&2
    fi

    echo "Usage: [PGUSER=<user>] [PGHOST=<host>] $0 [-q|--quiet] [-h|--help] [-R|--rows-per-insert <rows>] <database_name>" >&2
    echo "  -h, --help      Show this help message and exit" >&2
    echo "  -q, --quiet     Suppress normal output (errors still shown)" >&2
    echo "  -R, --rows-per-insert <rows>   Set the number of rows per insert (positive integer)" >&2

    exit "$exit_code"
}

# Parse arguments
POSITIONAL_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -q|--quiet)
            QUIET=true
            shift
            ;;
        -R|--rows-per-insert)
            ROWS_PER_INSERT="$2"
            # Validate the ROWS_PER_INSERT value
            if [[ ! "$ROWS_PER_INSERT" =~ ^[0-9]+$ ]] || [ "$ROWS_PER_INSERT" -le 0 ]; then
                echo "Error: Invalid value for rows per insert. Please provide a positive integer." >&2
                exit 1
            fi
            shift 2
            ;;
        -h|--help)
            usage 0
            ;;
        -*)
            echo "Error: Unknown option '$1'" >&2
            usage 1
            ;;
        *)
            POSITIONAL_ARGS+=("$1") # Collect positional arguments
            shift
            ;;
    esac
done

# Restore positional arguments
set -- "${POSITIONAL_ARGS[@]:-}"

# Ensure exactly one argument (database name) is provided
if [[ $# -ne 1 || -z "$1" ]]; then
    echo "Error: Missing required database name." >&2
    usage 1
fi

DATABASE="$1"



# Get PostgreSQL version
PG_VERSION=$(psql -tAc "SHOW server_version;" || echo "0.0")

# Check if pg_dump compatibility exists
if [[ "$(printf '%s\n' "9.3" "$PG_VERSION" | sort -V | head -n1)" == "9.3" ]]; then
    echo "Warning: PostgreSQL version $PG_VERSION does not support --quote-all-identifiers flag" >&2
    QUOTE_FLAG=""
else
    QUOTE_FLAG="--quote-all-identifiers"
fi

# Check if the database exists
if ! psql -tAc "SELECT 1 FROM pg_database WHERE datname = '$DATABASE'" | grep -q 1; then
    echo "Error: Database '$DATABASE' does not exist." >&2
    exit 1
fi

# Get timestamp in UTC
TIMESTAMP=$(date -u +"%Y-%m-%d_%H%M%SZ")

# Define filenames
DDLFILE="${DATABASE}-drop_create_${TIMESTAMP}.sql"
DATAFILE="${DATABASE}-data_${TIMESTAMP}.sql"

# Set umask to ensure the dump files are created with proper permissions (rw-rw----)
umask 0007

# Dump schema (DDL)
pg_dump "$DATABASE" --lock-wait-timeout=500 \
    --schema-only --create --clean --if-exists \
    $QUOTE_FLAG -f "$DDLFILE"

# Dump data
pg_dump "$DATABASE" --lock-wait-timeout=500 \
    --data-only --column-inserts --rows-per-insert="$ROWS_PER_INSERT" \
    $QUOTE_FLAG -f "$DATAFILE"

# Print output unless quiet mode is enabled
if ! $QUIET; then
    echo "Dump completed: $DDLFILE and $DATAFILE"
fi
