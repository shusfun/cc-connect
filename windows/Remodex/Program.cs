using Microsoft.Win32;
using QRCoder;
using System.Text.Json.Nodes;

namespace Remodex;

internal static class Program
{
    [STAThread]
    static void Main()
    {
        using var mutex = new Mutex(true, "Local\\Remodex.Desktop", out var created);
        if (!created) { MessageBox.Show("Remodex 已在托盘运行。", "Remodex"); return; }
        ApplicationConfiguration.Initialize();
        try { Application.Run(new DeviceForm()); }
        catch (Exception error) { MessageBox.Show(error.Message, "Remodex 无法启动", MessageBoxButtons.OK, MessageBoxIcon.Error); }
    }
}

internal sealed class DeviceForm : Form
{
    private readonly DeviceAccess access = new();
    private readonly BridgeOwner bridge = new();
    private readonly CancellationTokenSource lifetime = new();
    private readonly NotifyIcon tray = new();
    private readonly System.Windows.Forms.Timer refreshTimer = new() { Interval = 5000 };
    private readonly FlowLayoutPanel layout = new() { Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown, WrapContents = false, AutoScroll = true, Padding = new Padding(20) };
    private readonly TextBox relay = new() { Width = 480, AccessibleName = "Relay 地址" };
    private readonly TextBox remark = new() { Width = 480, AccessibleName = "设备备注" };
    private readonly Label status = new() { AutoSize = true, MaximumSize = new Size(480, 0), Text = "未登录" };
    private string? qrText;
    private readonly PictureBox qr = new() { Width = 300, Height = 300, BackColor = Color.White, SizeMode = PictureBoxSizeMode.CenterImage, AccessibleName = "手机配对二维码" };
    private readonly FlowLayoutPanel requests = new() { Width = 480, AutoSize = true, FlowDirection = FlowDirection.TopDown };
    private JsonNode? device;
    private bool busy;
    private bool exiting;
    public DeviceForm()
    {
        Text = "Remodex · 设备管理"; Width = 560; Height = 820; MinimumSize = new Size(530, 600); AutoScaleMode = AutoScaleMode.Dpi;
        Controls.Add(layout); AddLabel("Remodex", 22); layout.Controls.Add(status);
        AddLabel("Relay 服务地址"); relay.Text = access.Relay; layout.Controls.Add(relay);
        AddButton("使用 GitHub 登录并激活", async () => { if (access.Activated) throw new AccessException("请先退出当前登录"); access.PrepareIdentity(relay.Text.Trim()); await access.Activate(message => status.Text = message, lifetime.Token); bridge.Start(access); await RefreshState(); });
        AddLabel("设备备注"); layout.Controls.Add(remark);
        AddButton("保存备注", async () => { if (device is null) throw new AccessException("请先刷新设备状态"); await access.Request("/v1/access/device/remark", new JsonObject { ["remark"] = remark.Text, ["revision"] = device["revision"]!.DeepClone() }); await RefreshState(); });
        AddButton("启动 Bridge", () => { bridge.Start(access); return Task.CompletedTask; });
        AddButton("停止 Bridge", () => { bridge.Dispose(); status.Text = "Bridge 已停止，设备登录保留"; return Task.CompletedTask; });
        AddButton("重启并刷新二维码", () => { bridge.Dispose(); bridge.Start(access); return Task.CompletedTask; });
        layout.Controls.Add(qr); layout.Controls.Add(requests);
        AddButton("刷新配对码", () => { bridge.RefreshPairing(); status.Text = "正在申请新配对码…"; return Task.CompletedTask; });
        AddButton("复制配对码", () => { if (qrText is not null) Clipboard.SetText(qrText); return Task.CompletedTask; });
        var startup = new CheckBox { Text = "登录 Windows 时启动", AutoSize = true, MinimumSize = new Size(0, 44) };
        using (var registry = Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run")) startup.Checked = registry.GetValue("Remodex") is not null;
        startup.CheckedChanged += (_, _) => { using var registry = Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run"); if (startup.Checked) registry.SetValue("Remodex", $"\"{Application.ExecutablePath}\""); else registry.DeleteValue("Remodex", false); };
        layout.Controls.Add(startup);
        AddLabel("关闭显示器不会主动停止服务；Windows 进入系统睡眠后远程不可达。");
        AddButton("打开电源设置", () => { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("ms-settings:powersleep") { UseShellExecute = true }); return Task.CompletedTask; });
        AddButton("退出登录", async () => { if (MessageBox.Show("将撤销本设备与手机配对，不影响其他设备或代码文件。继续？", "退出登录", MessageBoxButtons.YesNo) != DialogResult.Yes) return; bridge.Dispose(); try { await access.Logout(); status.Text = "本机已退出"; } catch { status.Text = "本机已退出，远端撤销未完成，请在后台撤销。"; } qr.Image?.Dispose(); qr.Image = null; });
        AddButton("退出程序", () => { exiting = true; Close(); return Task.CompletedTask; });
        tray.Icon = SystemIcons.Application; tray.Text = "Remodex"; tray.Visible = true;
        tray.DoubleClick += (_, _) => { Show(); WindowState = FormWindowState.Normal; Activate(); };
        tray.ContextMenuStrip = new ContextMenuStrip(); tray.ContextMenuStrip.Items.Add("显示设备管理", null, (_, _) => { Show(); Activate(); }); tray.ContextMenuStrip.Items.Add("退出 Remodex", null, (_, _) => { exiting = true; Close(); });
        FormClosing += (_, eventArgs) => { if (!exiting && eventArgs.CloseReason == CloseReason.UserClosing) { eventArgs.Cancel = true; Hide(); return; } lifetime.Cancel(); refreshTimer.Stop(); bridge.Dispose(); tray.Dispose(); };
        refreshTimer.Tick += async (_, _) => { if (busy) return; await Run(RefreshState); };
        Shown += async (_, _) => { await Run(async () => { if (access.Activated) bridge.Start(access); await RefreshState(); }); refreshTimer.Start(); };
    }
    private void AddLabel(string text, float size = 10) => layout.Controls.Add(new Label { Text = text, AutoSize = true, MaximumSize = new Size(480, 0), Font = new Font(Font.FontFamily, size), Margin = new Padding(0, 10, 0, 6) });
    private void AddButton(string text, Func<Task> action, FlowLayoutPanel? panel = null)
    {
        var button = new Button { Text = text, AutoSize = true, MinimumSize = new Size(160, 44), AccessibleName = text };
        button.Click += async (_, _) => { if (busy) return; await Run(action); }; (panel ?? layout).Controls.Add(button);
    }
    private async Task Run(Func<Task> action)
    {
        busy = true;
        try { await action(); } catch (OperationCanceledException) { } catch (Exception error) { status.Text = error.Message; }
        finally { busy = false; }
    }
    private async Task RefreshState()
    {
        if (!access.Activated) return;
        var result = await access.Request("/v1/access/device", cancellation: lifetime.Token);
        device = result["device"]!.DeepClone(); access.State["credential"]!["device"] = device.DeepClone(); access.Save();
        if (!remark.Focused) remark.Text = device["remark"]!.GetValue<string>();
        status.Text = $"已激活 · {(bridge.Running ? "Bridge 运行中" : "Bridge 已停止")}";
        var pairingFile = Path.Combine(DeviceAccess.StateDirectory, "bridge", "pairing-session.json");
        var runtimeFile = Path.Combine(DeviceAccess.StateDirectory, "bridge", "bridge-status.json");
        var runtime = File.Exists(runtimeFile) ? JsonNode.Parse(await File.ReadAllTextAsync(runtimeFile, lifetime.Token)) : null;
        var connected = runtime?["connectionStatus"]?.GetValue<string>() == "connected" && runtime?["pid"]?.GetValue<int>() == bridge.ProcessId;
        if (File.Exists(pairingFile))
        {
            var session = JsonNode.Parse(await File.ReadAllTextAsync(pairingFile, lifetime.Token));
            var text = session?["qrText"]?.GetValue<string>();
            var expiry = session?["pairingPayload"]?["expiresAt"]?.GetValue<long>() ?? 0;
            if (!bridge.Running || !connected || expiry <= DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()) { qr.Image?.Dispose(); qr.Image = null; qrText = null; }
            else if (text is not null && text != qrText)
            {
                using var data = QRCodeGenerator.GenerateQrCode(text, QRCodeGenerator.ECCLevel.M);
                using var generator = new PngByteQRCode(data);
                var bytes = generator.GetGraphic(Math.Max(1, 300 / data.ModuleMatrix.Count));
                using var stream = new MemoryStream(bytes); using var image = Image.FromStream(stream);
                var previous = qr.Image; qr.Image = new Bitmap(image); previous?.Dispose(); qrText = text;
            }
        }
        requests.Controls.Clear();
        var pending = (await access.Request("/v1/access/pairing/pending", cancellation: lifetime.Token)).AsArray();
        foreach (var phone in pending)
        {
            var id = phone!["id"]!.GetValue<string>();
            requests.Controls.Add(new Label { Text = $"手机公钥：{phone["public_key"]}", AutoSize = true, MaximumSize = new Size(460, 0) });
            AddButton("确认配对", async () => { await access.Request("/v1/access/pairing/approve", new JsonObject { ["id"] = id, ["replace"] = false }); bridge.Dispose(); bridge.Start(access); await RefreshState(); }, requests);
            AddButton("替换旧手机", async () => { if (MessageBox.Show("旧手机将失去本设备访问权限。确认替换？", "替换手机", MessageBoxButtons.YesNo) != DialogResult.Yes) return; await access.Request("/v1/access/pairing/approve", new JsonObject { ["id"] = id, ["replace"] = true }); bridge.Dispose(); bridge.Start(access); await RefreshState(); }, requests);
        }
    }
}
