import { fireEvent, render, screen } from '@testing-library/react';
import { MemoryRouter, Route, Routes } from 'react-router-dom';
import { beforeEach, describe, expect, it } from 'vitest';
import i18n from '@/i18n';
import Layout from './Layout';

function renderLayout() {
  render(
    <MemoryRouter>
      <Routes>
        <Route element={<Layout />}>
          <Route index element={<div>Dashboard content</div>} />
          <Route path="projects" element={<div>Projects content</div>} />
          <Route path="chat" element={<div>Chat content</div>} />
        </Route>
      </Routes>
    </MemoryRouter>,
  );
}

describe('Layout responsive navigation', () => {
  beforeEach(async () => {
    await i18n.changeLanguage('en');
  });

  it('keeps content full-width on mobile and exposes navigation as a closeable drawer', () => {
    renderLayout();

    const navigation = screen.getByRole('complementary', { name: 'Navigation' });
    const main = screen.getByRole('main');
    expect(navigation.className).toContain('-translate-x-full');
    expect(navigation.className).toContain('md:static');
    expect(navigation.className).toContain('md:translate-x-0');
    expect(main.className).toContain('overflow-y-auto');
    expect(main.firstElementChild?.className).toContain('max-w-6xl');
    expect(main.firstElementChild?.className).toContain('px-4');
    expect(screen.getByRole('link', { name: 'Settings' }).getAttribute('href')).toBe('/settings');

    fireEvent.click(screen.getByRole('button', { name: 'Open navigation' }));
    expect(navigation.className).toContain('translate-x-0');
    expect(navigation.className).not.toContain('-translate-x-full');

    fireEvent.click(screen.getByRole('button', { name: 'Close' }));
    expect(navigation.className).toContain('-translate-x-full');

    fireEvent.click(screen.getByRole('button', { name: 'Open navigation' }));
    fireEvent.click(screen.getByRole('link', { name: 'Projects' }));
    expect(navigation.className).toContain('-translate-x-full');
    expect(screen.getByText('Projects content')).toBeTruthy();
  });

  it('gives chat routes the full-height workspace without the content-page padding', () => {
    render(
      <MemoryRouter initialEntries={['/chat']}>
        <Routes>
          <Route element={<Layout />}>
            <Route path="chat" element={<div>Chat content</div>} />
          </Route>
        </Routes>
      </MemoryRouter>,
    );

    const main = screen.getByRole('main');
    expect(main.className).toContain('overflow-hidden');
    expect(main.firstElementChild?.className).not.toContain('max-w-6xl');
    expect(screen.getByText('Chat content')).toBeTruthy();
  });
});
