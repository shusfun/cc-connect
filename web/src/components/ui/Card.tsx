import { cn } from '@/lib/utils';
import type { ReactNode } from 'react';

interface CardProps {
  children: ReactNode;
  className?: string;
  hover?: boolean;
}

export function Card({ children, className, hover }: CardProps) {
  return (
    <div
      className={cn(
        'rounded-lg border border-gray-200 bg-white p-5',
        'dark:border-white/[0.08] dark:bg-[#1a1a18]',
        hover &&
          'cursor-pointer hover:border-gray-300 hover:bg-gray-50 dark:hover:border-white/[0.14] dark:hover:bg-[#1e1e1c]',
        className
      )}
    >
      {children}
    </div>
  );
}

interface StatCardProps {
  label: string;
  value: string | number;
  accent?: boolean;
}

export function StatCard({ label, value, accent }: StatCardProps) {
  return (
    <Card hover>
      <p className="text-xs font-medium text-gray-500 dark:text-gray-400 uppercase">
        {label}
      </p>
      <p
        className={cn(
          'text-2xl font-bold mt-1',
          accent ? 'text-accent' : 'text-gray-900 dark:text-white'
        )}
      >
        {value}
      </p>
    </Card>
  );
}
