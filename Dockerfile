# Stage 1 (deps): install all packages once, cache for future builds
FROM node:18-alpine AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN --mount=type=cache,target=/root/.npm \
    npm ci && npm install ts-node

# Stage 2 (builder): compile Next.js — reuses deps, no second npm install
FROM node:18-alpine AS builder
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY . .
ENV NODE_ENV=production NEXT_TELEMETRY_DISABLED=1
RUN npm run build

# Stage 3 (runner): minimal production image with non-root user
FROM node:18-alpine AS runner
WORKDIR /app
ENV NODE_ENV=production NEXT_TELEMETRY_DISABLED=1
RUN addgroup --system --gid 1001 nodejs && \
    adduser --system --uid 1001 nextjs

COPY --from=builder /app/public ./public
COPY --from=builder --chown=nextjs:nodejs /app/.next ./.next
COPY --from=builder /app/next.config.mjs \
                    /app/package.json \
                    /app/knexfile.ts \
                    /app/tsconfig.knex.json ./
COPY --from=builder /app/database ./database
COPY --from=deps    /app/node_modules ./node_modules
COPY --chown=nextjs:nodejs docker/entrypoint.sh ./entrypoint.sh
RUN chmod +x ./entrypoint.sh

USER nextjs
EXPOSE 3000
ENV PORT=3000 HOSTNAME=0.0.0.0
ENTRYPOINT ["./entrypoint.sh"]
CMD ["node_modules/.bin/next", "start"]
