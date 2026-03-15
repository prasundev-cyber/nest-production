# ============================================================
#  Multi-stage Dockerfile — NestJS Production
#  Result: lean ~150MB image, non-root, read-only FS
# ============================================================

# ── Stage 1: Dependencies ────────────────────────────────────
FROM node:22-alpine AS deps
RUN apk add --no-cache libc6-compat
WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci --only=production && cp -r node_modules /tmp/prod_modules
RUN npm ci && npm cache clean --force

# ── Stage 2: Builder ─────────────────────────────────────────
FROM node:22-alpine AS builder
WORKDIR /app

COPY package*.json ./
RUN npm ci
COPY . .

RUN npm run build

# ── Stage 3: Production Runtime ──────────────────────────────
FROM node:22-alpine AS production

# Security: create a non-root user
RUN addgroup --system --gid 1001 nodejs \
  && adduser --system --uid 1001 nestjs

WORKDIR /app

# Copy only production artifacts
COPY --from=deps --chown=nestjs:nodejs /tmp/prod_modules ./node_modules
COPY --from=builder --chown=nestjs:nodejs /app/dist ./dist
COPY --from=builder --chown=nestjs:nodejs /app/package.json ./

# Drop to non-root
USER nestjs

EXPOSE 3000

ENV NODE_ENV=production \
    NODE_OPTIONS="--max-old-space-size=384"

# Graceful shutdown support
STOPSIGNAL SIGTERM

HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
  CMD wget -qO- http://127.0.0.1:3000/api/v1/health/live || exit 1

CMD ["node", "dist/main.js"]
