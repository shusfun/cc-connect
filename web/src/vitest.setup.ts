import { afterEach, vi } from 'vitest';
import { cleanup } from '@testing-library/react';

const storageValues = new Map<string, string>();
const localStorageMock: Storage = {
  get length() {
    return storageValues.size;
  },
  clear: () => storageValues.clear(),
  getItem: (key) => storageValues.get(key) ?? null,
  key: (index) => [...storageValues.keys()][index] ?? null,
  removeItem: (key) => storageValues.delete(key),
  setItem: (key, value) => storageValues.set(key, value),
};

Object.defineProperty(globalThis, 'localStorage', {
  configurable: true,
  value: localStorageMock,
});
Object.defineProperty(window, 'localStorage', {
  configurable: true,
  value: localStorageMock,
});

const i18n = (await import('@/i18n')).default;
await i18n.changeLanguage('zh');

afterEach(() => {
  cleanup();
  localStorage.clear();
	sessionStorage.clear();
});

Object.defineProperty(globalThis, 'ResizeObserver', {
	configurable: true,
	value: class ResizeObserver {
		constructor(private readonly callback: ResizeObserverCallback) {}
		observe(target: Element) {
			this.callback([{
				target,
				contentRect: { x: 0, y: 0, top: 0, right: 800, bottom: 600, left: 0, width: 800, height: 600, toJSON: () => ({}) },
				borderBoxSize: [], contentBoxSize: [], devicePixelContentBoxSize: [],
			} as unknown as ResizeObserverEntry], this as unknown as ResizeObserver);
		}
		unobserve() {}
		disconnect() {}
	},
});

Object.defineProperty(window, 'matchMedia', {
  configurable: true,
  value: vi.fn().mockImplementation((query: string) => ({
    matches: false,
    media: query,
    onchange: null,
    addListener: vi.fn(),
    removeListener: vi.fn(),
    addEventListener: vi.fn(),
    removeEventListener: vi.fn(),
    dispatchEvent: vi.fn(),
  })),
});

Object.defineProperty(Element.prototype, 'scrollIntoView', {
  configurable: true,
  value: vi.fn(),
});

Object.defineProperty(Element.prototype, 'scrollTo', {
	configurable: true,
	value: vi.fn(function (this: Element, options?: ScrollToOptions | number) {
		if (typeof options === 'object' && 'top' in options && typeof options.top === 'number') {
			Object.defineProperty(this, 'scrollTop', { configurable: true, writable: true, value: options.top });
		}
	}),
});
