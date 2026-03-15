// src/main.ts — Production-hardened NestJS bootstrap

import { NestFactory } from '@nestjs/core';
import { ValidationPipe, VersioningType } from '@nestjs/common';
import { DocumentBuilder, SwaggerModule } from '@nestjs/swagger';
import { ConfigService } from '@nestjs/config';
import { WinstonModule } from 'nest-winston';
import * as winston from 'winston';
import helmet from 'helmet';
import compression from 'compression';
import { AppModule } from './app.module';

async function bootstrap() {
  // ── Logger ────────────────────────────────────────────────
  const logger = WinstonModule.createLogger({
    transports: [
      new winston.transports.Console({
        format: winston.format.combine(
          winston.format.timestamp(),
          process.env.NODE_ENV === 'production'
            ? winston.format.json()           // Structured JSON → Loki
            : winston.format.prettyPrint(),   // Human-readable in dev
        ),
      }),
    ],
  });

  // ── App Factory ───────────────────────────────────────────
  const app = await NestFactory.create(AppModule, {
    logger,
    // Disable NestJS default exception logging — let our interceptor handle it
    bufferLogs: true,
  });

  const config = app.get(ConfigService);
  const port = config.get<number>('PORT', 3000);
  const isProduction = config.get('NODE_ENV') === 'production';

  // ── Security Headers ──────────────────────────────────────
  app.use(helmet({
    contentSecurityPolicy: {
      directives: {
        defaultSrc: ["'self'"],
        scriptSrc: ["'self'"],
        styleSrc: ["'self'"],
        imgSrc: ["'self'", 'data:'],
        connectSrc: ["'self'"],
      },
    },
    hsts: {
      maxAge: 63072000,
      includeSubDomains: true,
      preload: true,
    },
  }));

  // ── CORS ─────────────────────────────────────────────────
  app.enableCors({
    origin: config.get('ALLOWED_ORIGINS', 'https://yourdomain.com').split(','),
    methods: ['GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'OPTIONS'],
    allowedHeaders: ['Content-Type', 'Authorization', 'X-Request-ID'],
    credentials: true,
    maxAge: 86400,
  });

  // ── Compression ───────────────────────────────────────────
  app.use(compression());

  // ── Global Prefix & Versioning ────────────────────────────
  app.setGlobalPrefix('api');
  app.enableVersioning({
    type: VersioningType.URI,
    defaultVersion: '1',
  });

  // ── Validation Pipeline ───────────────────────────────────
  app.useGlobalPipes(
    new ValidationPipe({
      whitelist: true,           // Strip unknown properties
      forbidNonWhitelisted: true, // Throw on unknown properties
      transform: true,           // Auto-transform types
      transformOptions: {
        enableImplicitConversion: true,
      },
      disableErrorMessages: isProduction, // Hide validation details in prod
    }),
  );

  // ── Shutdown Hooks ────────────────────────────────────────
  app.enableShutdownHooks();

  // ── Swagger (disable in production or protect behind auth) ─
  if (!isProduction) {
    const swaggerConfig = new DocumentBuilder()
      .setTitle('API')
      .setVersion('1.0')
      .addBearerAuth()
      .build();
    const document = SwaggerModule.createDocument(app, swaggerConfig);
    SwaggerModule.setup('docs', app, document);
  }

  // ── Listen ────────────────────────────────────────────────
  await app.listen(port, '0.0.0.0');
  logger.log(`Application running on port ${port}`, 'Bootstrap');
}

bootstrap().catch((err) => {
  console.error('Fatal: failed to bootstrap', err);
  process.exit(1);
});
