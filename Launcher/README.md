# Лаунчер BT

Порт **8002** → `rojo serve` → Connect → Play.

## Режим Payload (по умолчанию)

`Config.LoadMode = "Payload"` — модули в `ReplicatedStorage.BT.Payload`, сборка `ToolBuilder`.

**Interfaces:** `Build/Building Tools by F3X.rbxmx` → `ReplicatedStorage.BT.Payload.Interfaces`

## Режим Remote (GitHub + кэш)

1. Залей репозиторий на GitHub (структура как в проекте).
2. `node scripts/generate-manifest.js` → закоммить `Launcher/manifest.lua`.
3. В `Launcher/Config.lua`:
   ```lua
   Config.LoadMode = "Remote"
   Config.RemoteBaseUrl = "https://raw.githubusercontent.com/utststs95/RBX-Building-Tools/refs/heads/development/"
   ```
4. Play через `BT_SoloRemote.client.lua` (нужен только `ReplicatedStorage.BT.Launcher`, **без Payload**).

Цепочка: **`loadstring(game:HttpGet(url, true))()`** → кэш → Tool в Backpack.

Везде один стиль: `Launcher/HttpLoad.lua`, `RemoteLoader`, `RemoteEntry`, `BT_SoloPastebin`.

## Один скрипт

`BT_SoloPastebin.client.lua`:

```lua
loadstring(game:HttpGet(ENTRY_URL, true))()
```

Поменяй `ENTRY_URL` и `BASE_URL` в `RemoteEntry.lua` на GitHub.

## Interfaces в Remote-режиме

GUI по-прежнему не в .lua — положи копию в `ReplicatedStorage.BT.Payload.Interfaces` (даже без остального Payload), лаунчер склонирует в Tool.
