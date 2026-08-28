import { Routes, Route, Navigate } from 'react-router-dom';
import { useAuthStore } from '@/store/auth';
import Layout from '@/components/Layout/Layout';
import Login from '@/pages/Login';
import WorkspaceChat from '@/pages/Chat/WorkspaceChat';
import SystemConfig from '@/pages/System/Config';
import Operations from '@/pages/Operations';
import SetupWizard from '@/pages/SetupWizard';
import Profile from '@/pages/Profile';
import GlobalSettings from '@/pages/System/GlobalSettings';
import SettingsLayout from '@/pages/Settings/SettingsLayout';
import Appearance from '@/pages/Settings/Appearance';
import Scheduled from '@/pages/Codex/Scheduled';
import Plugins from '@/pages/Codex/Plugins';
import ArchivedTasks from '@/pages/Settings/ArchivedTasks';
import FeishuSettings from '@/pages/Settings/FeishuSettings';
import { useTranslation } from 'react-i18next';

function ProtectedRoute({ children }: { children: React.ReactNode }) {
  const { t } = useTranslation();
  const isAuthenticated = useAuthStore((s) => s.isAuthenticated);
  const phase = useAuthStore((s) => s.phase);
  if (phase === 'loading') return <div className="h-screen grid place-items-center text-sm text-gray-500">{t('common.loading')}</div>;
  if (!isAuthenticated) return <Navigate to="/login" replace />;
  return <>{children}</>;
}

export default function App() {
  const isAuthenticated = useAuthStore((s) => s.isAuthenticated);

  return (
    <Routes>
      <Route path="/login" element={isAuthenticated ? <Navigate to="/" replace /> : <Login />} />
      <Route path="setup" element={<ProtectedRoute><SetupWizard /></ProtectedRoute>} />
      <Route element={<ProtectedRoute><Layout /></ProtectedRoute>}>
		<Route index element={<WorkspaceChat />} />
		<Route path="tasks/:deviceID/:projectID/:taskID" element={<WorkspaceChat />} />
        <Route path="scheduled" element={<Scheduled />} />
        <Route path="plugins" element={<Plugins />} />
		<Route path="*" element={<Navigate to="/" replace />} />
      </Route>
      <Route path="settings" element={<ProtectedRoute><SettingsLayout /></ProtectedRoute>}>
		  <Route index element={<Navigate to="general" replace />} />
		  <Route path="general" element={<GlobalSettings />} />
		  <Route path="devices" element={<Operations view="devices" />} />
		  <Route path="feishu" element={<FeishuSettings />} />
		  <Route path="updates" element={<Operations view="updates" />} />
          <Route path="appearance" element={<Appearance />} />
          <Route path="runtime" element={<SystemConfig />} />
          <Route path="account" element={<Profile />} />
          <Route path="archived" element={<ArchivedTasks />} />
      </Route>
      <Route path="*" element={<Navigate to="/" replace />} />
    </Routes>
  );
}
