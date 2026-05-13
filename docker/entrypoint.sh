#!/bin/sh
set -e

echo "==> Running database migrations..."
npx knex migrate:latest --knexfile knexfile.ts --env production

echo "==> Starting application..."
exec "$@"