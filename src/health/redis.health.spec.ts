import { Test, TestingModule } from '@nestjs/testing';
import { HealthCheckError } from '@nestjs/terminus';
import { ConfigService } from '@nestjs/config';
import { RedisHealthIndicator } from './redis.health';

// Mock ioredis so no real Redis connection is made
const mockRedisInstance = {
  connect: jest.fn().mockResolvedValue(undefined),
  ping: jest.fn().mockResolvedValue('PONG'),
  disconnect: jest.fn(),
};
jest.mock('ioredis', () => jest.fn().mockImplementation(() => mockRedisInstance));

describe('RedisHealthIndicator', () => {
  let indicator: RedisHealthIndicator;

  const buildModule = async (redisUrl: string | undefined) => {
    const module: TestingModule = await Test.createTestingModule({
      providers: [
        RedisHealthIndicator,
        {
          provide: ConfigService,
          useValue: { get: jest.fn().mockReturnValue(redisUrl) },
        },
      ],
    }).compile();
    return module.get<RedisHealthIndicator>(RedisHealthIndicator);
  };

  beforeEach(async () => {
    jest.clearAllMocks();
    indicator = await buildModule('redis://localhost:6379');
  });

  it('should be defined', () => {
    expect(indicator).toBeDefined();
  });

  it('should return healthy status when Redis responds PONG', async () => {
    const result = await indicator.isHealthy('redis');
    expect(result).toEqual({ redis: { status: 'up' } });
  });

  it('should throw HealthCheckError when REDIS_URL is not configured', async () => {
    const unconfigured = await buildModule(undefined);
    await expect(unconfigured.isHealthy('redis')).rejects.toBeInstanceOf(HealthCheckError);
  });

  it('should throw HealthCheckError when Redis ping fails', async () => {
    mockRedisInstance.ping.mockRejectedValueOnce(new Error('Connection refused'));
    await expect(indicator.isHealthy('redis')).rejects.toBeInstanceOf(HealthCheckError);
  });

  it('should always disconnect the client even on failure', async () => {
    mockRedisInstance.ping.mockRejectedValueOnce(new Error('timeout'));
    await indicator.isHealthy('redis').catch(() => null);
    expect(mockRedisInstance.disconnect).toHaveBeenCalled();
  });
});
