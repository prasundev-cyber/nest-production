import { Module } from '@nestjs/common';
import { ConfigModule } from '@nestjs/config';
import { TerminusModule } from '@nestjs/terminus';

import { HealthController } from './health/health.controller';
import { RedisHealthIndicator } from './health/redis.health';
import { MetricsModule } from './metrics/metrics.module';

@Module({
  imports: [ConfigModule.forRoot({ isGlobal: true }), TerminusModule, MetricsModule],
  controllers: [HealthController],
  providers: [RedisHealthIndicator],
})
export class AppModule {}
