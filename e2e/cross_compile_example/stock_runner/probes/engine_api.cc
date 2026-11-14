// Every engine and registrant call `flutter create`'s Linux runner makes, with
// the includes it makes them through. Compiled and linked, never run.
#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

#include "flutter/generated_plugin_registrant.h"

int main(int argc, char** argv) {
  gtk_init(&argc, &argv);
  g_autoptr(FlDartProject) project = fl_dart_project_new();
  char* entrypoint_arguments[] = {nullptr};
  fl_dart_project_set_dart_entrypoint_arguments(project, entrypoint_arguments);
  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  fl_register_plugins(FL_PLUGIN_REGISTRY(view));
  return 0;
}
