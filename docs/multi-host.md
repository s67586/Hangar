# 多台電腦共用同一支手機

**關鍵：手機的 5555 一旦開著，第二台電腦不需要 USB，也不用再跑 `adb tcpip`。**
`adb tcpip` 是手機端的狀態，跟哪台電腦設定的無關。第二台電腦要的只有兩件事：
一份設定檔，以及手機對這台電腦的授權。

## 在第二台電腦上

```bash
# 1. 裝相依套件 + hangar
brew install --cask android-platform-tools
brew install scrcpy jq
git clone <這個 repo> && cd hangar && ./hangar_install.sh

# 2. 建立設定（不需要 USB）
hangar setup --existing pixel-4
```

第一次一定會停在這裡：

```
 xx  狀態 unauthorized
     這台電腦還沒被手機授權過（換電腦第一次連都會這樣，是正常的）。
     手機畫面上會跳出「允許 USB 偵錯」，勾「一律允許透過這台電腦」再按允許，
     然後重跑一次這個指令。
```

手機上按完「一律允許」，再跑一次 `hangar setup --existing pixel-4` 就好了。
之後這台電腦就跟第一台一樣用。

> 授權是綁在**每台電腦自己的 adb 金鑰**（`~/.android/adbkey`）上的，
> 所以每台電腦都要在手機上按一次允許。
> **不要把 `adbkey` 複製到別台電腦** —— 那等同於把手機的完整控制權複製過去。

## 也可以直接複製設定檔

**沒入伍過的** profile 就是幾行純文字、沒有祕密（IP、序號、MAC，沒有金鑰），
直接抄過去也行：

```bash
scp ~/.config/hangar/profiles/pixel-4.conf 另一台:~/.config/hangar/profiles/
```

一樣要在手機上授權那台電腦。

入伍過的手機（profile 裡有 `AGENT_TOKEN`）抄過去等於把 token 也給了對方 ——
那組 token 可以問這支手機的狀態、之後還能切偵錯。要給就是有意識地給，
不要因為「只是一個設定檔」就順手 `scp`。

## ACL 要記得加新電腦

如果你照 [Tailscale ACL](tailscale.md) 設了規則，`src` 只寫了第一台電腦的話，
第二台會連不上。
建議把電腦也打 tag：

```json
{
  "tagOwners": {
    "tag:phone":  ["autogroup:admin"],
    "tag:devbox": ["autogroup:admin"]
  },
  "acls": [
    { "action": "accept", "src": ["tag:devbox"], "dst": ["tag:phone:5555"] }
  ]
}
```

之後每台新電腦打上 `tag:devbox` 就好，ACL 不用再改。

## 在那台電腦上 build app 進手機

**hangar 不在 build 的路徑上，hub 也不在。** `adb tcpip 5555` 是手機端的狀態，
手機的 5555 開著之後，任何到得了它的電腦都可以直接 `adb connect`、直接安裝 ——
不需要經過設定這支手機的那台電腦，也不需要經過之後的 hub。

RD 那台要的東西跟投影完全一樣（網路到得了、手機授權過），差別只在最後要把
build 指向這支手機：

```bash
hangar status -p pixel-4                     # 先確認 adb 是 device
export ANDROID_SERIAL=100.x.y.z:5555         # 或區網的 192.168.1.77:5555
./gradlew installDebug
```

`ANDROID_SERIAL` 是 adb 自己的環境變數，Gradle 與 `adb install` 都吃它。
不設的話，同時連著多支手機時 Gradle 會不知道要裝哪一支而停下來。手機的
serial 就是 `hangar list` 裡的 IP 加 `:5555`，或直接從 `--json` 拿：

```bash
export ANDROID_SERIAL="$(hangar status --json -p pixel-4 2>/dev/null | jq -r '.devices[0].adb_serial')"
```

Android Studio 走的是它自己啟動的 adb server，要它看到這支手機，最省事的方式
是在開 Studio 之前先 `adb connect <ip>:5555`（`hangar status` 會順手做掉），
裝置選單裡就會出現。

幾個實際會踩到的：

- **手機重開機後 5555 會消失**，RD 那台自己救不回來 —— 要有人把手機接 USB 或在
  同區網重跑一次 `hangar setup`。這是[專案方向](../ROADMAP.md)裡 agent app 要解決的
  問題之一。
- **多個人同時裝同一支手機會互相蓋掉。** 目前沒有任何佔用／排隊機制，只能靠講。
- **QA 在測加固版時偵錯是關著的**，那時候誰都 build 不進去。這是 ROADMAP 的 M4。

## 幾件事先講清楚

| | |
|---|---|
| 可以同時投嗎 | 可以。adbd 支援多個連線，兩台電腦各開各的 scrcpy 視窗互不干擾 |
| build 要經過 hub 嗎 | 不用。adb 本來就是網路協定，RD 的電腦直接連手機的 5555 |
| 手機重開機後怎麼辦 | 只要**任一台**接得到 USB／同區網的電腦重跑 `hangar setup`，其他電腦就自動恢復（授權還在，不用再按一次） |
| 第二台電腦能自己救嗎 | 不行。`adb tcpip` 需要一條既有的 USB 或同區網連線，遠端做不到 |
| profile 名稱要一致嗎 | 不用。每台電腦各自取名，`--name` 想叫什麼都行 |
