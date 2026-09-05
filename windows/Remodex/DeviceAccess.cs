using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using NSec.Cryptography;

namespace Remodex;

internal sealed class AccessException(string code) : Exception($"授权操作未完成：{code}")
{
    public string AccessCode { get; } = code;
}

internal sealed class DeviceAccess
{
    public static readonly string StateDirectory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Remodex");
    private readonly string credentialPath = Path.Combine(StateDirectory, "device.dpapi");
    private readonly HttpClient http = new() { Timeout = TimeSpan.FromSeconds(15) };
    public JsonObject State { get; private set; }
    public bool Activated => State["credential"] is JsonObject;
    public string Relay => State["relay"]?.GetValue<string>() ?? "wss://cc.syggu.cn";
    public DeviceAccess()
    {
        Directory.CreateDirectory(StateDirectory);
        State = File.Exists(credentialPath)
            ? JsonNode.Parse(ProtectedData.Unprotect(File.ReadAllBytes(credentialPath), null, DataProtectionScope.CurrentUser))!.AsObject()
            : new JsonObject();
    }
    public void Save()
    {
        var bytes = ProtectedData.Protect(Encoding.UTF8.GetBytes(State.ToJsonString()), null, DataProtectionScope.CurrentUser);
        var temporary = credentialPath + ".next";
        File.WriteAllBytes(temporary, bytes);
        File.Move(temporary, credentialPath, true);
    }
    public void PrepareIdentity(string relay)
    {
        var uri = new Uri(relay);
        if (uri.Scheme != "wss" || !string.IsNullOrEmpty(uri.UserInfo) || !string.IsNullOrEmpty(uri.Query) || !string.IsNullOrEmpty(uri.Fragment)) throw new AccessException("需要有效的 wss:// 服务地址");
        if (Activated && Relay != relay) throw new AccessException("请先退出当前设备账号");
        if (State["privateKey"] is null)
        {
            using var key = Key.Create(SignatureAlgorithm.Ed25519, new KeyCreationParameters { ExportPolicy = KeyExportPolicies.AllowPlaintextExport });
            State["privateKey"] = Convert.ToBase64String(key.Export(KeyBlobFormat.RawPrivateKey));
            State["publicKey"] = Convert.ToBase64String(key.PublicKey.Export(KeyBlobFormat.RawPublicKey));
        }
        State["relay"] = relay;
        Save();
    }
    private static string Hash(byte[] data) => Convert.ToHexString(SHA256.HashData(data)).ToLowerInvariant();
    public async Task<JsonNode> Request(string path, JsonObject? body = null, string? token = null, CancellationToken cancellation = default)
    {
        token ??= State["credential"]?["token"]?.GetValue<string>() ?? "";
        var bytes = Encoding.UTF8.GetBytes((body ?? new JsonObject()).ToJsonString());
        var timestamp = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds().ToString(System.Globalization.CultureInfo.InvariantCulture);
        var nonce = Convert.ToHexString(RandomNumberGenerator.GetBytes(24));
        var transcript = string.Join('\n', "remodex-access-v1", "POST", path, Hash(bytes), timestamp, nonce, Hash(Encoding.UTF8.GetBytes(token)));
        using var key = Key.Import(SignatureAlgorithm.Ed25519, Convert.FromBase64String(State["privateKey"]!.GetValue<string>()), KeyBlobFormat.RawPrivateKey);
        var origin = new UriBuilder(Relay) { Scheme = "https", Path = path, Query = "", Fragment = "" };
        using var request = new HttpRequestMessage(HttpMethod.Post, origin.Uri);
        request.Content = new ByteArrayContent(bytes); request.Content.Headers.ContentType = new MediaTypeHeaderValue("application/json");
        request.Headers.TryAddWithoutValidation("Authorization", $"Bearer {token}");
        request.Headers.Add("x-remodex-key", State["publicKey"]!.GetValue<string>());
        request.Headers.Add("x-remodex-time", timestamp); request.Headers.Add("x-remodex-nonce", nonce);
        request.Headers.Add("x-remodex-signature", Convert.ToBase64String(SignatureAlgorithm.Ed25519.Sign(key, Encoding.UTF8.GetBytes(transcript))));
        using var response = await http.SendAsync(request, cancellation);
        var result = JsonNode.Parse(await response.Content.ReadAsStringAsync(cancellation)) ?? throw new AccessException("服务器响应无效");
        if (!response.IsSuccessStatusCode) throw new AccessException(result["code"]?.GetValue<string>() ?? "request_failed");
        return result;
    }
    public async Task Activate(Action<string> notify, CancellationToken cancellation)
    {
        var pending = await Request("/v1/access/activation/start", new JsonObject { ["publicKey"] = State["publicKey"]!.DeepClone(), ["platform"] = "windows", ["systemName"] = Environment.MachineName }, "", cancellation);
        notify($"请在浏览器核对：{pending["code"]}");
        System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(pending["approvalURL"]!.GetValue<string>()) { UseShellExecute = true });
        for (var attempt = 0; attempt < 100; attempt++)
        {
            cancellation.ThrowIfCancellationRequested();
            try
            {
                var credential = await Request("/v1/access/activation/redeem", new JsonObject { ["id"] = pending["id"]!.DeepClone(), ["token"] = pending["token"]!.DeepClone(), ["publicKey"] = State["publicKey"]!.DeepClone() }, pending["token"]!.GetValue<string>(), cancellation);
                State["credential"] = credential; Save(); return;
            }
            catch (AccessException error) when (error.AccessCode == "approval_pending") { }
            await Task.Delay(3000, cancellation);
        }
        throw new AccessException("激活请求已过期，请重新发起");
    }
    public async Task Logout()
    {
        var revocation = State["credential"]?["revocationToken"]?.GetValue<string>();
        State.Remove("credential"); State["pendingRevocation"] = revocation; Save();
        if (revocation is not null)
        {
            await Request("/v1/access/revoke", new JsonObject { ["revocationToken"] = revocation }, "");
            State.Remove("pendingRevocation"); Save();
        }
    }
}
