import { Test, TestingModule } from '@nestjs/testing';
import {
  HealthCheckService,
  TypeOrmHealthIndicator,
  MemoryHealthIndicator,
  DiskHealthIndicator,
} from '@nestjs/terminus';
import { HealthController } from './health.controller';
import { RedisHealthIndicator } from './redis.health';

const HEALTH_RESULT = { status: 'ok', info: {}, error: {}, details: {} };

describe('HealthController', () => {
  let controller: HealthController;
  let healthService: jest.Mocked<HealthCheckService>;

  beforeEach(async () => {
    const module: TestingModule = await Test.createTestingModule({
      controllers: [HealthController],
      providers: [
        {
          provide: HealthCheckService,
          useValue: { check: jest.fn().mockResolvedValue(HEALTH_RESULT) },
        },
        {
          provide: TypeOrmHealthIndicator,
          useValue: {
            pingCheck: jest.fn().mockResolvedValue({ database: { status: 'up' } }),
          },
        },
        {
          provide: MemoryHealthIndicator,
          useValue: {
            checkHeap: jest.fn().mockResolvedValue({ memory_heap: { status: 'up' } }),
            checkRSS: jest.fn().mockResolvedValue({ memory_rss: { status: 'up' } }),
          },
        },
        {
          provide: DiskHealthIndicator,
          useValue: { checkStorage: jest.fn() },
        },
        {
          provide: RedisHealthIndicator,
          useValue: {
            isHealthy: jest.fn().mockResolvedValue({ redis: { status: 'up' } }),
          },
        },
      ],
    }).compile();

    controller = module.get<HealthController>(HealthController);
    healthService = module.get(HealthCheckService);
  });

  it('should be defined', () => {
    expect(controller).toBeDefined();
  });

  describe('check()', () => {
    it('should delegate to HealthCheckService with an array of indicators', async () => {
      const result = await controller.check();
      expect(healthService.check).toHaveBeenCalledWith(
        expect.arrayContaining([expect.any(Function)]),
      );
      expect(result).toEqual(HEALTH_RESULT);
    });
  });

  describe('readiness()', () => {
    it('should call HealthCheckService for db readiness', async () => {
      const result = await controller.readiness();
      expect(healthService.check).toHaveBeenCalled();
      expect(result).toEqual(HEALTH_RESULT);
    });
  });

  describe('liveness()', () => {
    it('should return ok status with an ISO timestamp', () => {
      const result = controller.liveness();
      expect(result.status).toBe('ok');
      expect(new Date(result.timestamp).toISOString()).toBe(result.timestamp);
    });
  });
});
