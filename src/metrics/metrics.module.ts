// src/metrics/metrics.module.ts
import { Module } from '@nestjs/common';
import {
  PrometheusModule,
  makeCounterProvider,
  makeHistogramProvider,
  makeGaugeProvider,
} from '@willsoto/nestjs-prometheus';

export const HTTP_REQUESTS_TOTAL = 'http_requests_total';
export const HTTP_REQUEST_DURATION = 'http_request_duration_seconds';
export const ACTIVE_CONNECTIONS = 'active_connections';

@Module({
  imports: [
    PrometheusModule.register({
      path: '/metrics',
      defaultMetrics: {
        enabled: true,
        config: {
          prefix: 'nestjs_',
        },
      },
    }),
  ],
  providers: [
    makeCounterProvider({
      name: HTTP_REQUESTS_TOTAL,
      help: 'Total number of HTTP requests',
      labelNames: ['method', 'route', 'status'],
    }),
    makeHistogramProvider({
      name: HTTP_REQUEST_DURATION,
      help: 'HTTP request duration in seconds',
      labelNames: ['method', 'route', 'status'],
      buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5],
    }),
    makeGaugeProvider({
      name: ACTIVE_CONNECTIONS,
      help: 'Number of active connections',
    }),
  ],
  exports: [PrometheusModule],
})
export class MetricsModule {}

// ─────────────────────────────────────────────
// src/metrics/metrics.interceptor.ts
// ─────────────────────────────────────────────
import {
  Injectable,
  NestInterceptor,
  ExecutionContext,
  CallHandler,
} from '@nestjs/common';
import { InjectMetric } from '@willsoto/nestjs-prometheus';
import { Counter, Histogram } from 'prom-client';
import { Observable } from 'rxjs';
import { tap } from 'rxjs/operators';

@Injectable()
export class MetricsInterceptor implements NestInterceptor {
  constructor(
    @InjectMetric(HTTP_REQUESTS_TOTAL)
    private readonly counter: Counter<string>,
    @InjectMetric(HTTP_REQUEST_DURATION)
    private readonly histogram: Histogram<string>,
  ) {}

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  intercept(context: ExecutionContext, next: CallHandler): Observable<any> {
    const req = context.switchToHttp().getRequest();
    const { method, route } = req;
    const routePath = route?.path ?? req.url;
    const timer = this.histogram.startTimer();

    return next.handle().pipe(
      tap({
        next: () => {
          const res = context.switchToHttp().getResponse();
          const status = res.statusCode.toString();
          timer({ method, route: routePath, status });
          this.counter.inc({ method, route: routePath, status });
        },
        error: (err) => {
          const status = (err.status ?? 500).toString();
          timer({ method, route: routePath, status });
          this.counter.inc({ method, route: routePath, status });
        },
      }),
    );
  }
}
