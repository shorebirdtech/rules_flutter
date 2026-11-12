// A runner of one's own (approach 3 of BUILD.bazel): a `cc_binary` over the
// engine's `CcInfo`, written against the engine's C API (`flutter_windows.h`)
// without the C++ client wrapper.
//
// It does what `flutter create`'s runner does, in one file: it creates a
// top-level window and makes the Flutter view a child of it, since the engine
// leaves parenting the view's window to the runner. It sizes the view with the
// window, gives the engine and plugins the window's messages, and registers
// the app's plugins.

#include <flutter/plugin_registry.h>
#include <windows.h>

#include <cstdlib>
#include <string>

#include "flutter_windows.h"
#include "windows_registrant/flutter/generated_plugin_registrant.h"

namespace {

constexpr wchar_t kWindowClass[] = L"DESKTOP_EXAMPLE_CUSTOM_RUNNER";

// The view controller, for the window procedure. Null outside the window's
// life.
FlutterDesktopViewControllerRef g_controller = nullptr;

// The engine as the generated registrant's `flutter::PluginRegistry`, which
// the client wrapper's `flutter::FlutterEngine` would otherwise be.
class EnginePluginRegistry : public flutter::PluginRegistry {
 public:
  explicit EnginePluginRegistry(FlutterDesktopEngineRef engine)
      : engine_(engine) {}

  FlutterDesktopPluginRegistrarRef GetRegistrarForPlugin(
      const std::string& plugin_name) override {
    return FlutterDesktopEngineGetPluginRegistrar(engine_,
                                                  plugin_name.c_str());
  }

 private:
  FlutterDesktopEngineRef engine_;
};

HWND ViewWindow() {
  return FlutterDesktopViewGetHWND(
      FlutterDesktopViewControllerGetView(g_controller));
}

// Fills `window`'s client area with the view.
void FitView(HWND window) {
  RECT frame;
  ::GetClientRect(window, &frame);
  ::MoveWindow(ViewWindow(), frame.left, frame.top, frame.right - frame.left,
               frame.bottom - frame.top, TRUE);
}

LRESULT CALLBACK WindowProc(HWND window, UINT message, WPARAM wparam,
                            LPARAM lparam) {
  if (g_controller) {
    LRESULT result;
    if (FlutterDesktopViewControllerHandleTopLevelWindowProc(
            g_controller, window, message, wparam, lparam, &result)) {
      return result;
    }
    switch (message) {
      case WM_SIZE:
        FitView(window);
        return 0;
      case WM_ACTIVATE:
        ::SetFocus(ViewWindow());
        return 0;
      case WM_FONTCHANGE:
        FlutterDesktopEngineReloadSystemFonts(
            FlutterDesktopViewControllerGetEngine(g_controller));
        break;
      case WM_DESTROY:
        // Before the view's window goes with this one, as its child.
        FlutterDesktopViewControllerDestroy(g_controller);
        g_controller = nullptr;
        ::PostQuitMessage(0);
        return 0;
    }
  }
  return ::DefWindowProcW(window, message, wparam, lparam);
}

}  // namespace

int WINAPI WinMain(HINSTANCE instance, HINSTANCE /*prev*/, LPSTR /*cmd_line*/,
                   int show_cmd) {
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  WNDCLASSW window_class = {};
  window_class.lpfnWndProc = WindowProc;
  window_class.hInstance = instance;
  window_class.hCursor = ::LoadCursor(nullptr, IDC_ARROW);
  window_class.lpszClassName = kWindowClass;
  ::RegisterClassW(&window_class);

  HWND window = ::CreateWindowW(kWindowClass, L"Desktop Example",
                                WS_OVERLAPPEDWINDOW, CW_USEDEFAULT,
                                CW_USEDEFAULT, 1280, 720, nullptr, nullptr,
                                instance, nullptr);
  if (!window) {
    return EXIT_FAILURE;
  }

  // Paths are relative to the executable, in the bundle's layout. The engine
  // reads `aot_library_path` only when it runs AOT code (a profile or release
  // engine) and ignores it otherwise, as `flutter::DartProject` relies on.
  FlutterDesktopEngineProperties properties = {};
  properties.assets_path = L"data\\flutter_assets";
  properties.icu_data_path = L"data\\icudtl.dat";
  properties.aot_library_path = L"data\\app.so";

  FlutterDesktopEngineRef engine = FlutterDesktopEngineCreate(&properties);
  if (!engine) {
    ::DestroyWindow(window);
    return EXIT_FAILURE;
  }

  // The size must match the client area, or the engine makes its surface
  // twice on the way up.
  RECT frame;
  ::GetClientRect(window, &frame);
  // The controller owns the engine from here, and destroys it if it fails.
  FlutterDesktopViewControllerRef controller =
      FlutterDesktopViewControllerCreate(frame.right - frame.left,
                                         frame.bottom - frame.top, engine);
  if (!controller) {
    ::DestroyWindow(window);
    return EXIT_FAILURE;
  }
  g_controller = controller;

  EnginePluginRegistry registry(
      FlutterDesktopViewControllerGetEngine(controller));
  RegisterPlugins(&registry);

  ::SetParent(ViewWindow(), window);
  FitView(window);
  ::ShowWindow(window, show_cmd);
  ::SetFocus(ViewWindow());

  MSG msg;
  while (::GetMessageW(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessageW(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
