# Tabletop

Коллекция из пяти настольных игр с одним игровым движком на Swift и тремя нативными интерфейсами:

- **macOS:** AppKit + SceneKit, Apple-like дизайн;
- **Windows:** WinUI 3, Fluent Design;
- **Linux:** GTK4 + libadwaita, GNOME-style.

Пасьянс, покер, блэкджек, дурак и бильярд используют одни и те же Swift-правила, ботов и физику. Windows- и Linux-оболочки общаются с headless Swift engine через JSON по стандартным потокам. Состояние партий сохраняется локально.

## Сборка

### macOS

```bash
./build.sh
```

Готовое приложение появится в `build/Tabletop.app`.

### Windows

Требуются Swift 6.2.3+ и .NET 10 с Windows App SDK:

```powershell
swift build -c release --build-path .build-windows
dotnet publish platforms/windows/Tabletop/Tabletop.csproj -c Release -r win-x64 --self-contained true -p:Platform=x64 -o release/ui
```

Скопируйте `.build-windows/release/Tabletop.exe` в `release/ui/engine/`, а Swift runtime DLL из установленного toolchain — в `release/ui/`. CI вкладывает их в архив автоматически. Перед запуском полностью распакуйте ZIP: `Tabletop.exe` нельзя запускать отдельно от остальных файлов. Запуск: `release/ui/Tabletop.exe`.

### Linux

Требуются Swift 5.9+, GTK4, libadwaita, json-glib и Meson:

```bash
swift build -c release --build-path .build-linux
meson setup platforms/linux/build platforms/linux
ninja -C platforms/linux/build
mkdir -p release/engine
cp .build-linux/release/Tabletop release/engine/
cp platforms/linux/build/tabletop-ui release/
TABLETOP_ENGINE="$PWD/release/engine/Tabletop" release/tabletop-ui
```

## Проверка движка

```bash
python3 Tools/engine-smoke.py .build-linux/release/Tabletop
```

Тест проверяет все пять игр и replay физики бильярда. GitHub Actions собирает и проверяет каждую платформу на её нативном runner.
