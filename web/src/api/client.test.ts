import { afterEach, describe, expect, it, vi } from 'vitest';
import { ApiClient, ApiError } from './client';

describe('ApiClient', () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it('将反代返回的 HTML 错误转换为明确的 HTTP 错误', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response('<html><h1>Bad Gateway</h1></html>', {
      status: 502,
      statusText: 'Bad Gateway',
      headers: { 'Content-Type': 'text/html' },
    })));

    const request = new ApiClient().get('/deploy/dashboard');

    await expect(request).rejects.toEqual(expect.objectContaining<ApiError>({
      name: 'ApiError',
      message: 'HTTP 502 Bad Gateway',
      status: 502,
    }));
  });
});
