# Tailscale ACL（強烈建議）

`adb tcpip 5555` 會讓 adbd listen 在 `0.0.0.0:5555` —— **包含 Tailscale 介面在內的所有介面**。
預設的 tailnet ACL 是全通的，意思是 tailnet 裡任何一台裝置都能連你手機的 adb，
而 adb 等於完整的裝置控制權。

請到 admin console（https://login.tailscale.com/admin/acls）限制成只有你的開發機能碰 5555。

## 步驟

1. 幫手機打上 tag。在 ACL 檔加入：

```json
{
  "tagOwners": {
    "tag:phone": ["autogroup:admin"]
  }
}
```

然後在 admin console 的機器列表把手機設成 `tag:phone`
（或在手機上 `tailscale up --advertise-tags=tag:phone`）。

2. 加上 ACL 規則：

```json
{
  "tagOwners": {
    "tag:phone": ["autogroup:admin"]
  },
  "acls": [
    {
      "action": "accept",
      "src": ["<你的電腦>"],
      "dst": ["tag:phone:5555"]
    }
  ]
}
```

`<你的電腦>` 可以是：

- 你的 Tailscale 帳號：`"your-email@example.com"`（該帳號下所有裝置）
- 特定裝置的 tag：`"tag:devbox"`
- 特定裝置名稱：`"macbook"`

多支手機都打同一個 `tag:phone` 就好，規則不用改。

3. 記得 ACL 一旦寫了 `acls` 區塊就變成白名單，其他原本能通的流量會被擋掉。
   如果你 tailnet 裡還有別的服務，要一併補上規則，例如：

```json
{
  "tagOwners": {
    "tag:phone": ["autogroup:admin"]
  },
  "acls": [
    { "action": "accept", "src": ["autogroup:member"], "dst": ["autogroup:self:*"] },
    { "action": "accept", "src": ["<你的電腦>"],        "dst": ["tag:phone:5555"] }
  ]
}
```

改完按 **Preview** 確認沒把自己鎖在外面，再 Save。
