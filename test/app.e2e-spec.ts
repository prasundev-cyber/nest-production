import { Test, TestingModule } from '@nestjs/testing';
import { INestApplication, VersioningType } from '@nestjs/common';
import request = require('supertest');
import {
  HealthCheckService,
  TypeOrmHealthIndicator,
  MemoryHealthIndicator,
  DiskHealthIndicator,
} from '@nestjs/terminus';
import { HealthController } from '../src/health/health.controller';
import { RedisHealthIndicator } from '../src/health/redis.health';

/**
 * E2E smoke tests run against a real NestJS application instance.
 * Endpoints that depend on external services (DB, Redis) are tested
 * via /health/live which has no external dependencies.
 */
describe('Health endpoints (e2e)', () => {
  let app: INestApplication;

  beforeAll(async () => {
    const HEALTH_RESULT = { status: 'ok', info: {}, error: {}, details: {} };

    const moduleFixture: TestingModule = await Test.createTestingModule({
      controllers: [HealthController],
      providers: [
        { provide: HealthCheckService, useValue: { check: jest.fn().mockResolvedValue(HEALTH_RESULT) } },
        { provide: TypeOrmHealthIndicator, useValue: { pingCheck: jest.fn() } },
        { provide: MemoryHealthIndicator, useValue: { checkHeap: jest.fn(), checkRSS: jest.fn() } },
        { provide: DiskHealthIndicator, useValue: { checkStorage: jest.fn() } },
        { provide: RedisHealthIndicator, useValue: { isHealthy: jest.fn() } },
      ],
    }).compile();

    app = moduleFixture.createNestApplication();
    app.setGlobalPrefix('api');
    app.enableVersioning({ type: VersioningType.URI, defaultVersion: '1' });
    await app.init();
  });

  afterAll(async () => {
    await app.close();
  });

  it('GET /api/v1/health/live returns 200 with ok status', () => {
    return request(app.getHttpServer())
      .get('/api/v1/health/live')
      .expect(200)
      .expect((res: request.Response) => {
        expect(res.body.status).toBe('ok');
        expect(res.body.timestamp).toBeDefined();
      });
  });

  it('GET /api/v1/health/ready returns 200', () => {
    return request(app.getHttpServer())
      .get('/api/v1/health/ready')
      .expect(200);
  });

  it('GET /api/v1/health returns 200', () => {
    return request(app.getHttpServer())
      .get('/api/v1/health')
      .expect(200);
  });
});
