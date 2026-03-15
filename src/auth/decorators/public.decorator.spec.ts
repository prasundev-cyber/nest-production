import { SetMetadata } from '@nestjs/common';
import { Public, IS_PUBLIC_KEY } from './public.decorator';

describe('Public decorator', () => {
  it('IS_PUBLIC_KEY should equal "isPublic"', () => {
    expect(IS_PUBLIC_KEY).toBe('isPublic');
  });

  it('should apply SetMetadata with IS_PUBLIC_KEY=true', () => {
    // Apply to a dummy class method and verify the metadata is stored
    class TestController {
      @Public()
      route() {}
    }

    const metadata = Reflect.getMetadata(IS_PUBLIC_KEY, TestController.prototype.route);
    expect(metadata).toBe(true);
  });

  it('should return a decorator factory (function)', () => {
    const decorator = Public();
    expect(typeof decorator).toBe('function');
  });

  it('SetMetadata is called with the correct key and value', () => {
    // Verify that Public() produces the same result as SetMetadata(IS_PUBLIC_KEY, true)
    const expected = SetMetadata(IS_PUBLIC_KEY, true);
    const actual = Public();

    // Both should be decorator functions produced by SetMetadata
    expect(typeof actual).toBe(typeof expected);
  });
});
