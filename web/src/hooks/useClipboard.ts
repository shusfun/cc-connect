import { useCallback } from 'react';

export function useClipboard() {
  return useCallback(async (value: string) => {
    if (!navigator.clipboard) throw new Error('当前浏览器不支持剪贴板写入');
    await navigator.clipboard.writeText(value);
  }, []);
}

export function useLinkBuilder() {
  return useCallback((path: string) => new URL(path, document.baseURI).toString(), []);
}
